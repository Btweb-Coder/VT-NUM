import { createClient } from 'npm:@supabase/supabase-js@2.57.0';
import { provider, providerKey } from './common.ts';
import { processNoSmsCancellation } from './tnum_cancellation.ts';
import {
  hasProviderSms,
  normalizeOperations,
  operationMessages,
  operationRemainingSeconds,
  responseCode,
  type TnumProviderMessage,
} from './tnum_provider_state.ts';

const admin = () =>
  createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
type ProviderParams = Record<string, string | number | boolean>;

async function saveSms(
  db: ReturnType<typeof admin>,
  activationId: string,
  messages: TnumProviderMessage[],
  providerStatus: string,
) {
  const rows: Array<TnumProviderMessage | null> = messages.length
    ? messages
    : providerStatus === 'TZ_NUM_ANSWER'
    ? [null]
    : [];

  for (const message of rows) {
    const { data, error } = await db.rpc('tnum_save_activation_sms', {
      p_activation: activationId,
      p_provider_message_key: message?.key ?? null,
      p_message_text: message?.messageText ?? null,
      p_code: message?.code ?? null,
      p_provider_status: providerStatus,
      p_sender: message?.sender ?? null,
      p_provider_received_at: message?.providerReceivedAt ?? null,
      p_provider_payload: message?.payload ?? null,
    });
    if (error) throw error;
    if (data !== true) {
      console.warn(JSON.stringify({
        activation_id: activationId,
        event: 'sms_persistence_rejected',
      }));
      return false;
    }
  }
  return true;
}

async function recordCancellationEvidence(
  db: ReturnType<typeof admin>,
  activationId: string,
  evidence: Record<string, unknown>,
) {
  const { error } = await db.rpc('tnum_record_cancellation_evidence', {
    p_activation: activationId,
    p_evidence: evidence,
  });
  if (error) throw error;
}

async function retryCancellation(
  db: ReturnType<typeof admin>,
  activationId: string,
  reason: string,
  evidence: Record<string, unknown>,
) {
  await recordCancellationEvidence(db, activationId, evidence);
  const { error } = await db.rpc('tnum_retry_activation_cancellation', {
    p_activation: activationId,
    p_error: reason.slice(0, 200),
  });
  if (error) throw error;
  console.warn(JSON.stringify({
    activation_id: activationId,
    event: 'cancellation_retry_scheduled',
    reason,
  }));
}

async function captureCompletedActivation(
  db: ReturnType<typeof admin>,
  activationId: string,
  providerStatus: string,
  now: string,
) {
  const { error: captureError } = await db.rpc(
    'tnum_capture_activation_reservation',
    { p_activation: activationId },
  );
  if (captureError) throw captureError;
  const { error: operationError } = await db.from('tnum_provider_operations')
    .update({ operation: 'close', state: 'confirmed', updated_at: now })
    .eq('activation_id', activationId);
  if (operationError) throw operationError;
  const { error: updateError } = await db.from('tnum_activations').update({
    status: 'completed',
    provider_status: providerStatus,
    provider_terminal_at: now,
    completed_at: now,
    last_provider_check_at: now,
  }).eq('id', activationId).in('status', [
    'active',
    'sms_received',
    'completion_pending',
    'expiration_pending',
  ]);
  if (updateError) throw updateError;
}

export async function runWorker(mode: 'monitor' | 'deadlines' = 'monitor') {
  providerKey();
  const db = admin();
  const { data: lease, error } = await db.rpc('tnum_claim_provider_worker');
  if (error) throw error;
  if (typeof lease !== 'string') {
    return { checked: 0, provider_operations: 0, skipped: 'worker_lease', mode };
  }

  try {
    return await runWorkerTask(mode);
  } finally {
    const { error: releaseError } = await db.rpc('tnum_release_provider_worker', {
      p_lease: lease,
    });
    if (releaseError) {
      console.error(JSON.stringify({ event: 'worker_lease_release_failed' }));
    }
  }
}

async function runWorkerTask(mode: 'monitor' | 'deadlines') {
  providerKey();

  const db = admin();
  const now = new Date().toISOString();

  let lastProviderRequestAt = 0;

  const providerCall = async (
    method: string,
    params: ProviderParams = {},
  ): Promise<unknown> => {
    const wait = 2100 - (Date.now() - lastProviderRequestAt);

    if (lastProviderRequestAt > 0 && wait > 0) {
      await delay(wait);
    }

    lastProviderRequestAt = Date.now();

    return await provider(method, params);
  };

  // 1. Recover abandoned cancellation claims.
  const { data: recovered, error: recoveryError } = await db.rpc(
    'tnum_recover_stale_cancellation_claims',
  );

  if (recoveryError) throw recoveryError;

  // 2. Monitor activations fairly.
  // Least recently checked activations are processed first.
  const { data: activations, error } = await db
    .from('tnum_activations')
    .select(
      'id,user_id,status,provider_operation_id,provider_status,phone_number,created_at,provider_requested_at,deadline_at,service_slug,country_code,cancellation_state,next_retry_at,last_provider_check_at,activation_sms:tnum_activation_sms(id)',
    )
    .not('provider_operation_id', 'is', null)
    .not('status', 'in', '(completed,expired,cancelled,failed)')
    .order('last_provider_check_at', {
      ascending: true,
      nullsFirst: true,
    })
    .order('created_at', { ascending: true })
    .limit(100);

  if (error) throw error;

  // 3. Get the provider's global operation list once.
  const result = await providerCall('getState', {
    msg_list: 1,
    message_to_code: 0,
    orderby: 'asc',
    lang: 'en',
  });

  const providerOperations = normalizeOperations(result);

  const byId = new Map(
    providerOperations.map((row) => [
      String(row.tzid ?? ''),
      row,
    ]),
  );

  const smsDetected = new Set<string>();

  let smsPersisted = 0;
  let completed = 0;
  let expired = 0;

  for (const activation of activations ?? []) {
    const id = String(activation.id);
    const tzid = String(activation.provider_operation_id);

    const state = byId.get(tzid);

    const deadline = Date.parse(String(activation.deadline_at));
    const overdue = Number.isFinite(deadline) &&
      deadline <= Date.now();

    const persistedSms = Array.isArray(activation.activation_sms) &&
      activation.activation_sms.length > 0;

    let status = '';

    const metadata: Record<string, unknown> = {
      last_provider_check_at: now,
    };

    if (state) {
      status = String(state.response ?? '');

      const messages = operationMessages(state, id);

      const detectedSms =
        hasProviderSms(state) ||
        messages.length > 0 ||
        status === 'TZ_NUM_ANSWER';

      if (detectedSms) {
        // Never let an SMS detected in this run enter cancellation.
        smsDetected.add(id);

        const saved = await saveSms(db, id, messages, status);

        if (saved) {
          smsPersisted += messages.length;
        }
      }

      const providerTime = operationRemainingSeconds(state);

      metadata.provider_status =
        status || activation.provider_status;

      metadata.phone_number =
        state.number ?? activation.phone_number;

      if (providerTime !== null) {
        metadata.provider_time_remaining_seconds = providerTime;
      }
    }

    // Rotate the monitoring queue even if the provider omitted
    // this operation from its global response.
    const { error: metadataError } = await db
      .from('tnum_activations')
      .update(metadata)
      .eq('id', id)
      .not('status', 'in', '(completed,expired,cancelled,failed)');

    if (metadataError) throw metadataError;

    // A completed provider operation must be captured.
    if (status === 'TZ_OVER_OK') {
      await captureCompletedActivation(db, id, status, now);
      completed++;
      continue;
    }

    if (!overdue || persistedSms || smsDetected.has(id)) {
      continue;
    }

    // Only mark expiration. Actual cancellation is handled
    // by the independent round-robin queue below.
    const { error: pendingError } = await db
      .from('tnum_activations')
      .update({
        status: 'expiration_pending',
      })
      .eq('id', id)
      .in('status', [
        'active',
        'provider_outcome_uncertain',
        'expiration_pending',
      ]);

    if (pendingError) throw pendingError;

    expired++;
  }

  // 4. Fetch the next persistent round-robin cancellation batch.
  // The database cursor survives worker restarts.
  const { data: cancellationQueue, error: queueError } =
    await db.rpc('tnum_get_cancellation_batch', {
      p_limit: 4,
    });

  if (queueError) throw queueError;

  let targetedLookups = 0;
  let cancellationAttempts = 0;
  let unresolvedOperations = 0;
  let claimLost = 0;

  // 5. Process each selected activation.
  for (const activation of cancellationQueue ?? []) {
    const id = String(activation.id);
    const tzid = String(activation.provider_operation_id);

    // SMS detected during this monitoring pass always wins.
    if (smsDetected.has(id)) {
      continue;
    }

    if (!byId.has(tzid)) {
      targetedLookups++;
    }

    const outcome = await processNoSmsCancellation(
      {
        ...activation,
        id,
        provider_operation_id: activation.provider_operation_id,
      },
      {
        provider: providerCall,
        now: Date.now,

        claim: async (activationId) => {
          const { data, error: claimError } = await db.rpc(
            'tnum_claim_activation_cancellation',
            {
              p_activation: activationId,
            },
          );

          if (claimError) throw claimError;

          return data === true;
        },

        readEvidence: async (activationId) => {
  const { data, error } = await db
    .from('tnum_provider_operations')
    .select('provider_evidence')
    .eq('activation_id', activationId)
    .eq('operation', 'close')
    .maybeSingle();

  if (error) throw error;

  const stored = data?.provider_evidence as
    | Record<string, unknown>
    | null;

  return stored?.confirmed_close
    ? { confirmed_close: stored.confirmed_close }
    : null;
},

        saveSms: async (activationId, messages, status) =>
          await saveSms(db, activationId, messages, status),

        capture: async (activationId) =>
          await captureCompletedActivation(
            db,
            activationId,
            'TZ_OVER_OK',
            new Date().toISOString(),
          ),

        recordEvidence: async (activationId, evidence) =>
          await recordCancellationEvidence(
            db,
            activationId,
            evidence,
          ),

        finalize: async (activationId) => {
          const { data, error: finalizeError } = await db.rpc(
            'tnum_finalize_activation_cancellation',
            {
              p_activation: activationId,
            },
          );

          if (finalizeError) throw finalizeError;

          return data === true;
        },

        retry: async (activationId, reason, evidence) =>
          await retryCancellation(
            db,
            activationId,
            reason,
            evidence,
          ),
      },
    );

    if (outcome === 'claim_lost') {
      claimLost++;
      continue;
    }

    // Count only attempts that actually passed the atomic claim.
    cancellationAttempts++;

    if (outcome === 'provider_state_unresolved') {
      unresolvedOperations++;
    }
  }

  return {
    checked: activations?.length ?? 0,
    provider_operations: providerOperations.length,
    stale_claims_recovered: Number(recovered ?? 0),
    monitoring_rotated: activations?.length ?? 0,
    expired_detected: expired,
    completed,
    cancellation_candidates: cancellationQueue?.length ?? 0,
    cancellation_attempts: cancellationAttempts,
    claim_lost: claimLost,
    targeted_lookups: targetedLookups,
    sms_persisted: smsPersisted,
    unresolved_operations: unresolvedOperations,
    mode,
  };
}