import { admin, ApiError, attempt, event, handle, json } from '../_shared/core.ts';
import { cancel, status } from '../_shared/providers.ts';
import { processVtActivationExpiry } from '../_shared/vt_activation_lifecycle.ts';

const RETRY_SECONDS = 60;
const cron = (request: Request) => {
  if (request.headers.get('x-cron-secret') !== Deno.env.get('CRON_SECRET')) {
    throw new ApiError(401, 'CRON_UNAUTHORIZED');
  }
};

async function recordStatusAttempt(db: ReturnType<typeof admin>, order: any, provider: any, result: any) {
  const { error } = await db.from('provider_attempts').insert({
    order_id: order.id,
    provider_id: provider.id,
    action: 'STATUS',
    status: result.ok ? 'SUCCESS' : 'FAILED',
    metadata: { rawStatus: result.raw, mappedStatus: result.status, codeReceived: Boolean(result.code) },
    finished_at: new Date().toISOString(),
  });
  if (error) throw error;
}

async function recordProxnumStatusAttempt(db: ReturnType<typeof admin>, order: any, provider: any, result: any) {
  const { error } = await db.from('provider_attempts').insert({
    order_id: order.id,
    provider_id: provider.id,
    action: 'STATUS',
    status: result.ok ? 'SUCCESS' : 'FAILED',
    metadata: { rawStatus: result.raw, code: result.code },
    finished_at: new Date().toISOString(),
  });
  if (error) throw error;
}

async function recordCancelAttempt(db: ReturnType<typeof admin>, order: any, provider: any) {
  return await attempt(db, order.id, provider.id, 'CANCEL', async () => {
    try {
      const accepted = await cancel(provider, order.provider_activation_id);
      return accepted
        ? { status: 'SUCCESS', metadata: { accepted: true } }
        : { status: 'FAILED', errorCode: 'PROVIDER_CANCEL_NOT_ACCEPTED' };
    } catch (error) {
      return {
        status: 'FAILED',
        errorCode: 'PROVIDER_CANCEL_EXCEPTION',
        errorMessage: error instanceof Error ? error.message : 'UNKNOWN',
      };
    }
  });
}

async function recordProxnumCancelAttempt(db: ReturnType<typeof admin>, order: any, provider: any) {
  return await attempt(db, order.id, provider.id, 'CANCEL', async () => {
    try {
      return await cancel(provider, order.provider_activation_id)
        ? { status: 'SUCCESS' }
        : { status: 'FAILED', errorCode: 'PROVIDER_CANCEL_FAILED' };
    } catch (error) {
      return {
        status: 'FAILED',
        errorCode: 'PROVIDER_CANCEL_EXCEPTION',
        errorMessage: error instanceof Error ? error.message : 'UNKNOWN',
      };
    }
  });
}

async function persistSms(db: ReturnType<typeof admin>, order: any, provider: any, code: string | null) {
  const { data: recorded, error } = await db.rpc('vt_record_activation_sms_and_capture', {
    p_order_id: order.id,
    p_code: code,
  });
  if (error) throw error;
  if (recorded === true) {
    await event(db, order.id, order.user_id, 'ORDER_COMPLETED', provider.id, { codeReceived: Boolean(code) });
  }
  return recorded === true;
}

async function finalizeCancellation(db: ReturnType<typeof admin>, order: any, provider: any, statusValue: string) {
  const { data: finalized, error } = await db.rpc('vt_finalize_confirmed_activation_cancellation', {
    p_order_id: order.id,
    p_provider_status: statusValue,
  });
  if (error) throw error;
  if (finalized === true) {
    await event(db, order.id, order.user_id, 'ORDER_EXPIRED', provider.id, { providerStatus: statusValue });
  }
  return finalized === true;
}

async function scheduleRetry(db: ReturnType<typeof admin>, order: any, reason: string) {
  const { error } = await db.rpc('vt_schedule_activation_monitor_retry', {
    p_order_id: order.id,
    p_reason: reason,
    p_retry_seconds: RETRY_SECONDS,
  });
  if (error) throw error;
}

// Proxnum virtual activations still follow their pre-existing monitor path.
// This branch is intentionally unchanged by the VT-NUM lifecycle correction.
async function monitorProxnum(db: ReturnType<typeof admin>, order: any, provider: any, now: string) {
  if (order.status === 'WAITING_FOR_SMS' && new Date(order.expires_at).getTime() > Date.now()) {
    const result = await status(provider, order.provider_activation_id);
    await recordProxnumStatusAttempt(db, order, provider, result);
    if (result.ok && result.status === 'SMS_RECEIVED' && result.code) {
      await db.from('orders').update({ status: 'SMS_RECEIVED', code: result.code, sms_received_at: now }).eq('id', order.id).eq('status', 'WAITING_FOR_SMS');
      const { error } = await db.rpc('capture_wallet_hold', { p_order_id: order.id });
      if (error) throw error;
      await db.from('orders').update({ status: 'COMPLETED', financial_status: 'CAPTURED', completed_at: now }).eq('id', order.id).eq('status', 'SMS_RECEIVED');
      await event(db, order.id, order.user_id, 'ORDER_COMPLETED', provider.id, { codeReceived: true });
      return;
    }
  }
  if (order.status === 'WAITING_FOR_SMS' && new Date(order.expires_at).getTime() <= Date.now()) {
    await db.from('orders').update({ status: 'EXPIRING' }).eq('id', order.id).eq('status', 'WAITING_FOR_SMS');
  }
  const { data: latest } = await db.from('orders').select('*').eq('id', order.id).single();
  if (!latest || !['EXPIRING', 'CANCELLING'].includes(latest.status)) return;
  await db.from('orders').update({ status: 'CANCELLING' }).eq('id', order.id).in('status', ['EXPIRING', 'CANCELLING']);
  let confirmed = latest.provider_cancellation_confirmed === true;
  if (!confirmed) {
    const result = await recordProxnumCancelAttempt(db, order, provider);
    confirmed = result.status === 'SUCCESS';
    if (confirmed) await db.from('orders').update({ provider_cancellation_confirmed: true }).eq('id', order.id);
  }
  if (confirmed) {
    if (latest.financial_status === 'HOLDING') {
      const { error } = await db.rpc('release_wallet_hold', { p_order_id: order.id });
      if (error) throw error;
      await db.from('orders').update({ status: 'EXPIRED', financial_status: 'RELEASED', expired_at: now }).eq('id', order.id).eq('status', 'CANCELLING');
      await event(db, order.id, order.user_id, 'ORDER_EXPIRED', provider.id, {});
    } else {
      await db.from('orders').update({ status: 'FAILED' }).eq('id', order.id).eq('status', 'CANCELLING');
    }
  }
}

Deno.serve(handle(async (request) => {
  cron(request);
  const db = admin();
  const { data: lease, error: leaseError } = await db.rpc('claim_background_job', { p_job_name: 'monitor-activations' });
  if (leaseError) throw leaseError;
  if (!lease) return json({ skipped: true, reason: 'LEASE_HELD' });

  let failure: string | undefined;
  let processed = 0;
  try {
    const now = new Date().toISOString();
    const { data: orders, error } = await db.from('orders')
      .select('*,providers(*)')
      .in('status', ['WAITING_FOR_SMS', 'EXPIRING', 'CANCELLING'])
      .or(`next_monitor_at.is.null,next_monitor_at.lte.${now}`)
      .order('next_monitor_at', { ascending: true, nullsFirst: true })
      .limit(100);
    if (error) throw error;

    for (const order of orders ?? []) {
      const provider = order.providers;
      if (!provider || !order.provider_activation_id) continue;
      processed++;
      try {
        if (provider.slug === 'proxnum') {
          await monitorProxnum(db, order, provider, now);
          continue;
        }
        const isDue = !order.expires_at || new Date(order.expires_at).getTime() <= Date.now();

        if (order.status === 'WAITING_FOR_SMS' && !isDue) {
          const current = await status(provider, order.provider_activation_id);
          await recordStatusAttempt(db, order, provider, current);
          if (current.ok && (current.status === 'SMS_RECEIVED' || Boolean(current.code?.trim()))) {
            await persistSms(db, order, provider, current.code?.trim() || null);
          } else {
            await scheduleRetry(db, order, current.ok ? 'ACTIVATION_STILL_WAITING' : 'STATUS_QUERY_UNCONFIRMED');
          }
          continue;
        }

        const api = (provider.config?.api ?? {}) as Record<string, unknown>;
        const configuredWaiting = Array.isArray(api.waitingStatuses)
          ? api.waitingStatuses.map((value) => String(value).trim().toUpperCase())
          : ['WAITING', 'PENDING', 'WAITING_FOR_SMS', 'IN_PROGRESS', 'ACTIVE'];
        const lifecycle = await processVtActivationExpiry({
          claimCancellation: async () => {
            const { data, error: rpcError } = await db.rpc('vt_claim_expired_activation_cancellation', { p_order_id: order.id });
            if (rpcError) throw rpcError;
            return data === true;
          },
          canRequestCancellation: async () => {
            const { data, error: rpcError } = await db.rpc('vt_authorize_activation_cancellation_request', { p_order_id: order.id });
            if (rpcError) throw rpcError;
            return data === true;
          },
          getStatus: async () => {
            const result = await status(provider, order.provider_activation_id);
            await recordStatusAttempt(db, order, provider, result);
            const raw = String(result.raw ?? '').trim().toUpperCase();
            if (result.ok && result.code?.trim()) {
              return { ...result, status: 'SMS_RECEIVED' };
            }
            if (result.ok && result.status === 'WAITING' && !configuredWaiting.includes(raw)) {
              return { ...result, status: 'UNKNOWN' };
            }
            return result;
          },
          requestCancellation: async () => { await recordCancelAttempt(db, order, provider); },
          recordSms: (code) => persistSms(db, order, provider, code),
          finalizeCancellation: (providerStatus) => finalizeCancellation(db, order, provider, providerStatus),
          scheduleRetry: (reason) => scheduleRetry(db, order, reason),
        });
        if (lifecycle.outcome === 'CANCELLED' || lifecycle.outcome === 'SMS_RECEIVED') continue;
      } catch (error) {
        console.error('VT activation monitor failure', order.id, error);
        await scheduleRetry(db, order, error instanceof Error ? error.message : 'UNKNOWN_MONITOR_ERROR');
      }
    }
    return json({ processed });
  } catch (error) {
    failure = error instanceof Error ? error.message : 'UNKNOWN';
    throw error;
  } finally {
    await db.rpc('finish_background_job', { p_job_name: 'monitor-activations', p_lease_id: lease, p_error: failure ?? null });
  }
}));
