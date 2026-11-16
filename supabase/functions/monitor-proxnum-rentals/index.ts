import { admin, ApiError, handle, json } from '../_shared/core.ts';
import { getRentalStatus } from '../_shared/proxnum_rentals.ts';

const RENTAL_MONITOR_LOG = '[PROXNUM-RENTAL-MONITOR]';

function logMonitor(
  step: string,
  details: Record<string, unknown> = {},
) {
  console.log(RENTAL_MONITOR_LOG, {
    timestamp: new Date().toISOString(),
    step,
    ...details,
  });
}

function logMonitorError(
  step: string,
  details: Record<string, unknown> = {},
) {
  console.error(RENTAL_MONITOR_LOG, {
    timestamp: new Date().toISOString(),
    step,
    ...details,
  });
}

/**
 * Proxnum long-term rental monitor.
 *
 * Safety rules:
 * - Never infer a provider rental's identity from service/country/price/time.
 * - A rental without provider_rental_id remains unresolved and keeps its wallet
 *   hold. This monitor does not attempt a replacement purchase.
 * - Only reconcile provider state through an exact persisted provider rental ID.
 * - Never refund unless the provider status confirms cancellation.
 */
Deno.serve(handle(async (request) => {
  logMonitor('RUN_STARTED', {
  method: request.method,
});
  const cronSecret = Deno.env.get('CRON_SECRET');

if (
  !cronSecret ||
  request.headers.get('x-cron-secret') !== cronSecret
) {
  logMonitorError('CRON_AUTH_FAILED', {
    secretConfigured: Boolean(cronSecret),
    headerProvided: Boolean(request.headers.get('x-cron-secret')),
  });

  throw new ApiError(401, 'CRON_AUTH_REQUIRED');
}

logMonitor('CRON_AUTH_SUCCESS');

  const db = admin();
  const { data: provider, error: providerError } = await db.from('providers')
    .select('id,slug,endpoint,config')
    .eq('slug', 'proxnum')
    .eq('active', true)
    .single();

    logMonitor('PROVIDER_LOOKUP', {
  found: Boolean(provider),
  lookupError: Boolean(providerError),
  rentalNumbersEnabled:
    provider?.config?.features?.rental_numbers === true,
});

  if (providerError || !provider || provider.config?.features?.rental_numbers !== true) {
    logMonitor('MONITOR_SKIPPED', {
  reason: 'RENTALS_NOT_ENABLED',
});
    return json({ success: true, skipped: true, reason: 'RENTALS_NOT_ENABLED' });
  }

  const now = new Date();
  const staleBefore = new Date(now.getTime() - 2 * 60 * 1000).toISOString();

  // Mark abandoned operations for reconciliation, but never release a hold here.
  const { data: staleOperations, error: staleOperationsError } = await db
    .from('proxnum_rental_operations')
    .select('id,rental_id,operation,idempotency_key')
    .eq('status', 'STARTED')
    .lt('updated_at', staleBefore)
    .order('updated_at', { ascending: true })
    .limit(100);

  if (staleOperationsError) throw staleOperationsError;

  for (const op of staleOperations ?? []) {
    const { error: opUpdateError } = await db.from('proxnum_rental_operations')
      .update({ status: 'RECONCILIATION_REQUIRED', error_code: 'STALE_STARTED_OPERATION' })
      .eq('id', op.id)
      .eq('status', 'STARTED');

    if (opUpdateError) throw opUpdateError;

    if (op.operation === 'PURCHASE') {
      const { error: rentalUpdateError } = await db.from('proxnum_rentals')
        .update({ status: 'RECONCILIATION_REQUIRED', last_sync_error: 'STALE_PURCHASE_OPERATION' })
        .eq('id', op.rental_id)
        .is('provider_rental_id', null);

      if (rentalUpdateError) throw rentalUpdateError;
    }
  }

  const { data: staleRenewals, error: staleRenewalsError } = await db
    .from('proxnum_rental_renewals')
    .select('id')
    .eq('status', 'REQUESTED')
    .lt('updated_at', staleBefore)
    .order('updated_at', { ascending: true })
    .limit(100);

  if (staleRenewalsError) throw staleRenewalsError;

  for (const renewal of staleRenewals ?? []) {
    const { error: renewalUpdateError } = await db.from('proxnum_rental_renewals')
      .update({ status: 'RECONCILIATION_REQUIRED', failure_code: 'STALE_RENEWAL_OPERATION' })
      .eq('id', renewal.id)
      .eq('status', 'REQUESTED');

    if (renewalUpdateError) throw renewalUpdateError;
  }

  // IMPORTANT: rows without provider_rental_id are deliberately not matched
  // against the provider's list. There is no safe exact correlation key in the
  // currently supplied API contract. They remain held for manual reconciliation.
  // We still update retry/escalation metadata so they are visible operationally.
  const { data: unresolved, error: unresolvedError } = await db.from('proxnum_rentals')
    .select('id,sync_failures,status')
    .is('provider_rental_id', null)
    .in('status', ['PURCHASE_REQUESTED', 'RECONCILIATION_REQUIRED'])
    .or(`next_sync_at.is.null,next_sync_at.lte.${now.toISOString()}`)
    .order('last_sync_at', { ascending: true, nullsFirst: true })
    .order('created_at', { ascending: true })
    .limit(20);

  if (unresolvedError) throw unresolvedError;

  for (const local of unresolved ?? []) {
    const failures = (Number(local.sync_failures) || 0) + 1;
    const { error: unresolvedUpdateError } = await db.from('proxnum_rentals')
      .update({
        status: 'RECONCILIATION_REQUIRED',
        last_sync_at: now.toISOString(),
        next_sync_at: new Date(
          now.getTime() + Math.min(3600, 10 * 2 ** Math.min(failures - 1, 9)) * 1000,
        ).toISOString(),
        sync_failures: failures,
        last_sync_error: 'PROVIDER_ID_MISSING_MANUAL_RECONCILIATION_REQUIRED',
        reconciliation_escalated_at: failures >= 12 ? now.toISOString() : null,
        reconciliation_escalation_reason: failures >= 12
          ? 'PROVIDER_ID_MISSING_AFTER_RETRIES'
          : null,
      })
      .eq('id', local.id)
      .is('provider_rental_id', null);

    if (unresolvedUpdateError) throw unresolvedUpdateError;
  }

  const { data: rentals, error } = await db.from('proxnum_rentals')
    .select('id,provider_rental_id,status,sync_failures,expires_at,user_id,idempotency_key')
    .in('status', [
      'PURCHASE_REQUESTED',
      'ACTIVE',
      'CANCEL_PENDING',
      'CANCEL_REQUESTED',
      'RENEWAL_REQUESTED',
      'RECONCILIATION_REQUIRED',
    ])
    .not('provider_rental_id', 'is', null)
    .or(`next_sync_at.is.null,next_sync_at.lte.${now.toISOString()}`)
    .order('last_sync_at', { ascending: true, nullsFirst: true })
    .order('created_at', { ascending: true })
    .limit(20);

  if (error) throw error;

  let synced = 0;
  let failed = 0;

  for (const rental of rentals ?? []) {
    try {
      const s = await getRentalStatus(provider, String(rental.provider_rental_id));
      const status = s.status === 'active'
        ? (rental.status === 'RENEWAL_REQUESTED'
          ? 'RENEWAL_REQUESTED'
          : rental.status === 'RECONCILIATION_REQUIRED'
          ? 'RECONCILIATION_REQUIRED'
          : 'ACTIVE')
        : s.status === 'cancelling'
        ? 'CANCEL_PENDING'
        : s.status === 'cancelled'
        ? 'CANCELLED'
        : s.status === 'expired'
        ? 'EXPIRED'
        : rental.status;

      const syncedAt = new Date();
      const { error: updateError } = await db.from('proxnum_rentals').update({
        status,
        expires_at: s.expiresAt,
        can_cancel: s.canCancel,
        cancel_pending: s.cancelPending,
        can_extend: s.canExtend,
        last_provider_status: s.status,
        last_provider_payload: s,
        last_sync_at: syncedAt.toISOString(),
        next_sync_at: new Date(syncedAt.getTime() + 10000).toISOString(),
        sync_failures: 0,
        last_sync_error: null,
      }).eq('id', rental.id);

      if (updateError) throw updateError;

      for (const m of s.messages) {
        const { error: messageError } = await db.from('proxnum_rental_messages').upsert({
          rental_id: rental.id,
          provider_message_id: String(m.id),
          sender: m.sender ?? null,
          message_text: m.text,
          sms_code: m.code ?? null,
          message_at: m.date ?? null,
        }, { onConflict: 'rental_id,provider_message_id', ignoreDuplicates: true });

        if (messageError) throw messageError;
      }

      // Resolve a purchase only when the exact provider ID is already stored,
      // the purchase operation itself is unresolved, and its own hold is HELD.
      // Do not infer the cause of a generic rental RECONCILIATION_REQUIRED state:
      // it may instead represent a failed refund, cancellation, or renewal.
      if (s.status === 'active') {
        const { data: purchaseOperation, error: purchaseOperationError } = await db
          .from('proxnum_rental_operations')
          .select('id,status')
          .eq('rental_id', rental.id)
          .eq('operation', 'PURCHASE')
          .eq('idempotency_key', rental.idempotency_key)
          .maybeSingle();

        if (purchaseOperationError) throw purchaseOperationError;

        const { data: purchaseHold, error: holdLookupError } = await db
          .from('proxnum_rental_wallet_holds')
          .select('id,status')
          .eq('rental_id', rental.id)
          .eq('operation_key', `PURCHASE:${rental.idempotency_key}`)
          .maybeSingle();

        if (holdLookupError) throw holdLookupError;

        const purchaseNeedsResolution =
          purchaseOperation &&
          ['STARTED', 'PENDING', 'RECONCILIATION_REQUIRED'].includes(purchaseOperation.status) &&
          purchaseHold?.status === 'HELD';

        if (purchaseNeedsResolution) {
          const { error: captureError } = await db.rpc('finish_proxnum_rental_hold', {
            p_rental_id: rental.id,
            p_operation_key: `PURCHASE:${rental.idempotency_key}`,
            p_capture: true,
          });
          if (captureError) throw captureError;

          const { error: operationError } = await db.from('proxnum_rental_operations')
            .update({ status: 'SUCCEEDED', provider_payload: s, error_code: null })
            .eq('id', purchaseOperation.id)
            .in('status', ['STARTED', 'PENDING', 'RECONCILIATION_REQUIRED']);

          if (operationError) throw operationError;

          const { error: rentalStatusError } = await db.from('proxnum_rentals')
            .update({ status: 'ACTIVE', last_sync_error: null }).eq('id', rental.id);
          if (rentalStatusError) throw rentalStatusError;
        }
      }

      if (s.status === 'cancelled') {
        // Refund RPC independently checks local CANCELLED status and a captured
        // purchase hold. The status was just written from provider-confirmed data.
        const { error: refundError } = await db.rpc('refund_confirmed_proxnum_rental', {
          p_rental_id: rental.id,
        });

        if (refundError) {
          const { error: markError } = await db.from('proxnum_rentals').update({
            status: 'RECONCILIATION_REQUIRED',
            last_sync_error: 'REFUND_RECONCILIATION_REQUIRED',
          }).eq('id', rental.id);
          if (markError) throw markError;
          throw refundError;
        }

        const { error: operationError } = await db.from('proxnum_rental_operations')
          .update({ status: 'SUCCEEDED', provider_payload: s, error_code: null })
          .eq('rental_id', rental.id)
          .eq('operation', 'CANCEL')
          .in('status', ['STARTED', 'PENDING', 'RECONCILIATION_REQUIRED']);

        if (operationError) throw operationError;
      }

      if (s.status === 'cancelling') {
        const { error: operationError } = await db.from('proxnum_rental_operations')
          .update({ status: 'PENDING', provider_payload: s, error_code: null })
          .eq('rental_id', rental.id)
          .eq('operation', 'CANCEL')
          .in('status', ['STARTED', 'RECONCILIATION_REQUIRED']);

        if (operationError) throw operationError;
      }

      // A live ACTIVE provider status alone is not proof that an earlier
      // cancellation POST was rejected. Keep the cancellation pending for
      // manual/provider-supported reconciliation instead of declaring failure.
      if (
        s.status === 'active' &&
        ['CANCEL_PENDING', 'CANCEL_REQUESTED'].includes(rental.status)
      ) {
        const { error: operationError } = await db.from('proxnum_rental_operations')
          .update({
            status: 'RECONCILIATION_REQUIRED',
            error_code: 'CANCEL_OUTCOME_NOT_PROVEN',
            provider_payload: s,
          })
          .eq('rental_id', rental.id)
          .eq('operation', 'CANCEL')
          .in('status', ['STARTED', 'PENDING', 'RECONCILIATION_REQUIRED']);

        if (operationError) throw operationError;

        const { error: rentalStatusError } = await db.from('proxnum_rentals')
          .update({
            status: 'RECONCILIATION_REQUIRED',
            cancel_pending: false,
            can_cancel: s.canCancel === true,
            last_sync_error: 'CANCEL_OUTCOME_NOT_PROVEN',
          })
          .eq('id', rental.id);

        if (rentalStatusError) throw rentalStatusError;
      }
 // synced++;
      
if (
  s.status === 'active' &&
  rental.status === 'RENEWAL_REQUESTED' &&
  s.expiresAt &&
  rental.expires_at &&
  Date.parse(s.expiresAt) > Date.parse(rental.expires_at)
) {
  const { data: renewals, error: renewalLookupError } = await db
    .from('proxnum_rental_renewals')
    .select('id,idempotency_key,status,previous_expires_at')
    .eq('rental_id', rental.id)
    .in('status', ['REQUESTED', 'RECONCILIATION_REQUIRED'])
    .order('created_at', { ascending: false })
    .limit(2);

  if (renewalLookupError) throw renewalLookupError;

  // Never guess which renewal caused the provider expiry change.
  const matchingRenewals = (renewals ?? []).filter((n: {
  id: string;
  idempotency_key: string;
  status: string;
  previous_expires_at: string | null;
}) =>
    n.previous_expires_at &&
    Date.parse(n.previous_expires_at) === Date.parse(rental.expires_at!)
  );

  if (matchingRenewals.length !== 1) {
    const { error: markError } = await db
      .from('proxnum_rentals')
      .update({
        status: 'RECONCILIATION_REQUIRED',
        last_sync_error: 'EXPIRY_CHANGED_WITHOUT_UNIQUE_RENEWAL',
      })
      .eq('id', rental.id);

    if (markError) throw markError;
  } else {
    const renewal = matchingRenewals[0];

    const { error: finalizeError } = await db.rpc(
      'finalize_proxnum_rental_renewal',
      {
        p_rental_id: rental.id,
        p_renewal_id: renewal.id,
        p_expires_at: s.expiresAt,
        p_provider_payload: s,
        p_can_extend: s.canExtend,
        p_provider_status: s.status,
        p_status_payload: s,
      },
    );

    if (finalizeError) {
      const { error: markError } = await db
        .from('proxnum_rentals')
        .update({
          status: 'RECONCILIATION_REQUIRED',
          last_sync_error: 'RENEWAL_FINALIZATION_FAILED',
        })
        .eq('id', rental.id);

      if (markError) throw markError;
      throw finalizeError;
    }
  }
}


      synced++;
    } catch (error) {
      logMonitorError('RENTAL_SYNC_FAILED', {
  rentalId: rental.id,
  currentStatus: rental.status,
  error: error instanceof Error ? error.message : 'SYNC_FAILED',
});
      failed++;
      const failures = (Number(rental.sync_failures) || 0) + 1;
      const { error: failureUpdateError } = await db.from('proxnum_rentals').update({
        last_sync_at: new Date().toISOString(),
        next_sync_at: new Date(
          Date.now() + Math.min(3600, 10 * 2 ** Math.min(failures - 1, 9)) * 1000,
        ).toISOString(),
        sync_failures: failures,
        last_sync_error: error instanceof Error ? error.message : 'SYNC_FAILED',
      }).eq('id', rental.id);

      if (failureUpdateError) throw failureUpdateError;
    }
  }
logMonitor('RUN_COMPLETED', {
  synced,
  failed,
});
  return json({ success: true, synced, failed });
}));


// } catch (error) {
//  failed++;