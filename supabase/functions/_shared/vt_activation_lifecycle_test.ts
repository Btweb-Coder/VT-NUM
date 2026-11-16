import { assertEquals } from 'jsr:@std/assert@1';
import {
  processVtActivationExpiry,
  VT_ACTIVATION_TIMEOUT_SECONDS,
  type VtExpiryDependencies,
  type VtProviderActivationStatus,
} from './vt_activation_lifecycle.ts';

function setup(
  statuses: VtProviderActivationStatus[],
  options: { claim?: boolean; authorize?: boolean; cancelThrows?: boolean; finalize?: boolean; smsSave?: boolean } = {},
) {
  const calls: string[] = [];
  let statusIndex = 0;
  const deps: VtExpiryDependencies = {
    claimCancellation: async () => { calls.push('claim'); return options.claim ?? true; },
    canRequestCancellation: async () => { calls.push('authorize'); return options.authorize ?? true; },
    getStatus: async () => { calls.push('getState'); return statuses[Math.min(statusIndex++, statuses.length - 1)]; },
    requestCancellation: async () => { calls.push('cancel'); if (options.cancelThrows) throw new Error('network timeout'); },
    recordSms: async (code) => { calls.push(`sms:${code ?? ''}`); return options.smsSave ?? true; },
    finalizeCancellation: async (status) => { calls.push(`finalize:${status}`); return options.finalize ?? true; },
    scheduleRetry: async (reason) => { calls.push(`retry:${reason}`); },
  };
  return { calls, deps };
}

const waiting: VtProviderActivationStatus = { ok: true, status: 'WAITING', raw: 'WAITING' };
const sms: VtProviderActivationStatus = { ok: true, status: 'SMS_RECEIVED', code: '123456', raw: 'SMS_RECEIVED' };

Deno.test('VT-NUM application timeout is fixed at 360 seconds', () => {
  assertEquals(VT_ACTIVATION_TIMEOUT_SECONDS, 360);
});

Deno.test('a no-SMS activation is cancelled and only finalized after terminal provider verification', async () => {
  const { calls, deps } = setup([waiting, { ok: true, status: 'CANCELLED', raw: 'CANCELLED' }]);
  const result = await processVtActivationExpiry(deps);
  assertEquals(result, { outcome: 'CANCELLED', providerStatus: 'CANCELLED' });
  assertEquals(calls, ['claim', 'getState', 'authorize', 'cancel', 'getState', 'finalize:CANCELLED']);
});

Deno.test('an SMS found before cancellation is persisted and prevents cancellation', async () => {
  const { calls, deps } = setup([sms]);
  const result = await processVtActivationExpiry(deps);
  assertEquals(result, { outcome: 'SMS_RECEIVED', code: '123456' });
  assertEquals(calls, ['claim', 'getState', 'sms:123456']);
});

Deno.test('an SMS arriving during the cancellation request prevents release', async () => {
  const { calls, deps } = setup([waiting, sms]);
  const result = await processVtActivationExpiry(deps);
  assertEquals(result, { outcome: 'SMS_RECEIVED', code: '123456' });
  assertEquals(calls, ['claim', 'getState', 'authorize', 'cancel', 'getState', 'sms:123456']);
  assertEquals(calls.some((call) => call.startsWith('finalize:')), false);
});

Deno.test('provider cancellation timeout is reconciled with a targeted status check', async () => {
  const { calls, deps } = setup([waiting, { ok: true, status: 'CANCELLED', raw: 'CANCELLED' }], { cancelThrows: true });
  const result = await processVtActivationExpiry(deps);
  assertEquals(result.outcome, 'CANCELLED');
  assertEquals(calls.filter((call) => call === 'getState').length, 2);
});

Deno.test('a protective or active provider response remains pending and retries', async () => {
  const { calls, deps } = setup([waiting, waiting]);
  const result = await processVtActivationExpiry(deps);
  assertEquals(result, { outcome: 'RETRY', reason: 'CANCELLATION_NOT_CONFIRMED' });
  assertEquals(calls.includes('finalize:CANCELLED'), false);
  assertEquals(calls.includes('retry:CANCELLATION_NOT_CONFIRMED'), true);
});

Deno.test('an unknown response is never interpreted as cancellation confirmation', async () => {
  const { calls, deps } = setup([{ ok: true, status: 'UNKNOWN', raw: 'UNRECOGNIZED' }]);
  const result = await processVtActivationExpiry(deps);
  assertEquals(result.outcome, 'RETRY');
  assertEquals(calls.includes('cancel'), false);
  assertEquals(calls.some((call) => call.startsWith('finalize:')), false);
});

Deno.test('a lost atomic claim makes no provider or financial call', async () => {
  const { calls, deps } = setup([waiting], { claim: false });
  assertEquals(await processVtActivationExpiry(deps), { outcome: 'SKIPPED' });
  assertEquals(calls, ['claim']);
});

Deno.test('concurrent workers can issue only one cancellation and one finalization', async () => {
  let claimed = false;
  let cancellations = 0;
  let finalizations = 0;
  const deps: VtExpiryDependencies = {
    claimCancellation: async () => {
      if (claimed) return false;
      claimed = true;
      return true;
    },
    canRequestCancellation: async () => true,
    getStatus: async () => cancellations === 0
      ? { ok: true, status: 'WAITING', raw: 'WAITING' }
      : { ok: true, status: 'CANCELLED', raw: 'CANCELLED' },
    requestCancellation: async () => { cancellations++; },
    recordSms: async () => true,
    finalizeCancellation: async () => { finalizations++; return true; },
    scheduleRetry: async () => {},
  };
  const results = await Promise.all([
    processVtActivationExpiry(deps),
    processVtActivationExpiry(deps),
  ]);
  assertEquals(results.filter((result) => result.outcome === 'CANCELLED').length, 1);
  assertEquals(results.filter((result) => result.outcome === 'SKIPPED').length, 1);
  assertEquals(cancellations, 1);
  assertEquals(finalizations, 1);
});

Deno.test('an SMS committed after the initial status read blocks the cancellation request', async () => {
  const { calls, deps } = setup([waiting], { authorize: false });
  const result = await processVtActivationExpiry(deps);
  assertEquals(result, { outcome: 'RETRY', reason: 'CANCELLATION_GUARD_REJECTED' });
  assertEquals(calls.includes('cancel'), false);
});

Deno.test('a failed SMS persistence or finalization remains retryable', async () => {
  const smsSetup = setup([sms], { smsSave: false });
  assertEquals((await processVtActivationExpiry(smsSetup.deps)).outcome, 'RETRY');
  const cancelSetup = setup([waiting, { ok: true, status: 'EXPIRED', raw: 'EXPIRED' }], { finalize: false });
  assertEquals((await processVtActivationExpiry(cancelSetup.deps)).outcome, 'RETRY');
  assertEquals(cancelSetup.calls.some((call) => call.startsWith('retry:')), true);
});

Deno.test('migration clamps persisted deadlines, serializes SMS and release, and excludes Proxnum', async () => {
  const migration = await Deno.readTextFile(new URL('../../migrations/20261104100000_vt_activation_deadline_and_cancellation.sql', import.meta.url));
  assertEquals(migration.includes("interval '360 seconds'"), true);
  assertEquals(migration.includes("v_order.sms_received_at is not null"), true);
  assertEquals(migration.includes("v_order.code is not null"), true);
  assertEquals(migration.includes("perform public.release_wallet_hold(p_order_id)"), true);
  assertEquals(migration.includes("v_slug = 'proxnum'"), true);
  assertEquals(migration.includes("next_monitor_at = now() + interval '120 seconds'"), true);
  assertEquals(migration.includes('vt_authorize_activation_cancellation_request'), true);
  assertEquals(migration.includes("'online-sim-monitor-activations', v_schedule"), true);
  assertEquals(migration.includes("v_schedule := '10 seconds'"), true);
  assertEquals(migration.includes("'x-cron-secret'"), true);
  assertEquals(migration.includes("'online-sim-monitor-topups'"), false);
  assertEquals(migration.includes("pa.metadata->>'mappedStatus'"), true);
});
