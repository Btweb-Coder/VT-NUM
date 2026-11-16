import {
  type CancellationActivation,
  type CancellationDependencies,
  closeProtectionSeconds,
  processNoSmsCancellation,
} from './tnum_cancellation.ts';

const fixedNow = Date.parse('2026-11-03T12:00:00.000Z');

function operation(tzid: number, response: string, msg?: unknown, time = 500) {
  return [{ tzid, response, time, ...(msg === undefined ? {} : { msg }) }];
}

function fixture(
  providerResults: unknown[],
  options: {
    service?: string;
    startedSecondsAgo?: number;
    claim?: boolean;
    previousEvidence?: Record<string, unknown> | null;
  } = {},
) {
  const providerCalls: Array<
    { method: string; params: Record<string, string | number | boolean> }
  > = [];
  const savedSms: Array<{ status: string; count: number }> = [];
  const retries: Array<{ reason: string; evidence: Record<string, unknown> }> = [];
  const evidence: Record<string, unknown>[] = [];
    let previousEvidence = options.previousEvidence ?? null;
  let claimed = options.claim ?? true;
  let finalizeCount = 0;
  let captureCount = 0;
  const activation: CancellationActivation = {
    id: 'activation-id',
    provider_operation_id: 9001,
    service_slug: options.service ?? 'telegram',
    provider_requested_at: new Date(fixedNow - (options.startedSecondsAgo ?? 500) * 1000)
      .toISOString(),
    created_at: new Date(fixedNow - 600_000).toISOString(),
  };
  const dependencies: CancellationDependencies = {
    now: () => fixedNow,
    provider: async (method, params) => {
      providerCalls.push({ method, params });
      if (!providerResults.length) throw new Error('UNEXPECTED_PROVIDER_CALL');
      const next = providerResults.shift();
      if (next instanceof Error) throw next;
      return next;
    },
    claim: async () => {
      if (!claimed) return false;
      claimed = false;
      return true;
    },
        readEvidence: async () => previousEvidence,
    saveSms: async (_id, messages, status) => {
      savedSms.push({ status, count: messages.length });
      return true;
    },
    capture: async () => {
      captureCount++;
    },
       recordEvidence: async (_id, row) => {
      evidence.push(row);

      if (
        row.close_response === '1' &&
        row.close_tzid === String(row.tzid) &&
        row.precheck_no_messages === true &&
        ['TZ_INPOOL', 'TZ_NUM_WAIT'].includes(
          String(row.precheck_status ?? ''),
        )
      ) {
        previousEvidence = {
          confirmed_close: row,
        };
      }
    },
    finalize: async () => {
      finalizeCount++;
      return true;
    },
    retry: async (_id, reason, row) => {
      retries.push({ reason, evidence: row });
    },
  };
  return {
    activation,
    dependencies,
    providerCalls,
    savedSms,
    retries,
    evidence,
    get finalizeCount() {
      return finalizeCount;
    },
    get captureCount() {
      return captureCount;
    },
  };
}

Deno.test('a no-SMS activation closes only after exact precheck and postcheck', async () => {
  const f = fixture([
    operation(9001, 'TZ_NUM_WAIT'),
    { response: 1, tzid: 9001 },
    { response: 'ERROR_NO_OPERATIONS' },
  ]);
  const result = await processNoSmsCancellation(f.activation, f.dependencies);
  if (result !== 'expired_confirmed' || f.finalizeCount !== 1) {
    throw new Error('normal cancellation did not finalize');
  }
  if (
    f.providerCalls.length !== 3 || f.providerCalls[0].params.tzid !== 9001 ||
    f.providerCalls[2].params.tzid !== 9001
  ) {
    throw new Error('cancellation did not use exact operation lookups');
  }
  if ('ban' in f.providerCalls[1].params) throw new Error('generic ban parameter was sent');
});

Deno.test('an SMS received immediately before the close check prevents cancellation', async () => {
  const f = fixture([operation(9001, 'TZ_NUM_ANSWER', [{ id: 'm1', text: 'full SMS 4812' }])]);
  const result = await processNoSmsCancellation(f.activation, f.dependencies);
  if (result !== 'sms_received' || f.savedSms.length !== 1 || f.finalizeCount !== 0) {
    throw new Error('pre-close SMS did not win');
  }
  if (f.providerCalls.some((call) => call.method === 'setOperationOk')) {
    throw new Error('close was requested after SMS receipt');
  }
});

Deno.test('a database claim lost to an SMS at the six-minute deadline makes no provider call', async () => {
  const f = fixture([], { claim: false });
  const result = await processNoSmsCancellation(f.activation, f.dependencies);
  if (result !== 'claim_lost' || f.providerCalls.length !== 0 || f.finalizeCount !== 0) {
    throw new Error('an SMS/deadline race crossed the atomic claim boundary');
  }
});

Deno.test('an SMS arriving during close verification prevents release', async () => {
  const f = fixture([
    operation(9001, 'TZ_NUM_WAIT'),
    { response: 1, tzid: 9001 },
    operation(9001, 'TZ_NUM_ANSWER', [{ id: 'm2', text: 'Your code is 9921' }]),
  ]);
  const result = await processNoSmsCancellation(f.activation, f.dependencies);
  if (result !== 'sms_received' || f.finalizeCount !== 0 || f.savedSms.length !== 1) {
    throw new Error('SMS during close was not protected');
  }
});

Deno.test("WhatsApp's 300-second protection is respected", async () => {
  const f = fixture([operation(9001, 'TZ_NUM_WAIT')], {
    service: 'whatsapp',
    startedSecondsAgo: 200,
  });
  const result = await processNoSmsCancellation(f.activation, f.dependencies);
  if (
    result !== 'retry_scheduled' || f.providerCalls.some((call) => call.method === 'setOperationOk')
  ) {
    throw new Error('WhatsApp was closed before its protective interval');
  }
  if (closeProtectionSeconds('whatsapp') !== 300) throw new Error('WhatsApp interval is incorrect');
});

Deno.test('other services use the 120-second protection', () => {
  if (closeProtectionSeconds('telegram') !== 120) {
    throw new Error('other-service interval is incorrect');
  }
});

Deno.test('an operation may be closed at the exact 120-second provider protection boundary', async () => {
  const f = fixture([
    operation(9001, 'TZ_NUM_WAIT'),
    { response: 1, tzid: 9001 },
    operation(9001, 'TZ_OVER_EMPTY'),
  ], { startedSecondsAgo: 120 });
  const result = await processNoSmsCancellation(f.activation, f.dependencies);
  if (result !== 'expired_confirmed' || f.providerCalls[1]?.method !== 'setOperationOk') {
    throw new Error('the exact provider protection boundary was handled incorrectly');
  }
});

Deno.test('TZ_OVER_EMPTY is conclusive no-SMS evidence and skips another close', async () => {
  const f = fixture([operation(9001, 'TZ_OVER_EMPTY')]);
  const result = await processNoSmsCancellation(f.activation, f.dependencies);
  if (result !== 'expired_confirmed' || f.providerCalls.length !== 1 || f.finalizeCount !== 1) {
    throw new Error('TZ_OVER_EMPTY was not finalized from exact provider evidence');
  }
});

Deno.test('TZ_OVER_OK follows capture and is never treated as a no-SMS release', async () => {
  const f = fixture([operation(9001, 'TZ_OVER_OK')]);
  const result = await processNoSmsCancellation(f.activation, f.dependencies);
  if (result !== 'completed_captured' || f.captureCount !== 1 || f.finalizeCount !== 0) {
    throw new Error('TZ_OVER_OK took the no-SMS release path');
  }
});

Deno.test('ERROR_NO_OPERATIONS without a successful close remains unresolved', async () => {
  const f = fixture([{ response: 'ERROR_NO_OPERATIONS' }]);
  const result = await processNoSmsCancellation(f.activation, f.dependencies);
  if (result !== 'provider_state_unresolved' || f.finalizeCount !== 0 || f.retries.length !== 1) {
    throw new Error('operation disappearance released funds without evidence');
  }
});

Deno.test('unknown provider responses are logged and retried without release', async () => {
  const f = fixture([operation(9001, 'FUTURE_UNKNOWN_STATE')]);
  const result = await processNoSmsCancellation(f.activation, f.dependencies);
  if (result !== 'provider_state_unresolved' || f.finalizeCount !== 0 || f.retries.length !== 1) {
    throw new Error('unknown provider response was treated as a terminal outcome');
  }
});

Deno.test('provider timeout after a claimed attempt stays pending for retry', async () => {
  const f = fixture([new Error('PROVIDER_TIMEOUT')]);
  const result = await processNoSmsCancellation(f.activation, f.dependencies);
  if (
    result !== 'retry_scheduled' || f.finalizeCount !== 0 ||
    f.retries[0]?.reason !== 'PROVIDER_TIMEOUT'
  ) {
    throw new Error('uncertain request was not retried safely');
  }
});

Deno.test('a positive close followed by an active provider state is not finalized', async () => {
  const f = fixture([
    operation(9001, 'TZ_NUM_WAIT'),
    { response: 1, tzid: 9001 },
    operation(9001, 'TZ_NUM_WAIT'),
  ]);
  const result = await processNoSmsCancellation(f.activation, f.dependencies);
  if (result !== 'retry_scheduled' || f.finalizeCount !== 0) {
    throw new Error('positive close response bypassed provider postcheck');
  }
});

Deno.test('an operation claim lost to a concurrent worker causes no provider or financial action', async () => {
  const f = fixture([], { claim: false });
  const result = await processNoSmsCancellation(f.activation, f.dependencies);
  if (result !== 'claim_lost' || f.providerCalls.length || f.finalizeCount || f.captureCount) {
    throw new Error('lost claim performed side effects');
  }
});

Deno.test('only one concurrent attempt reaches the provider and finalizer', async () => {
  let claimAvailable = true;
  let finalizationCount = 0;
  const f = fixture([
    operation(9001, 'TZ_NUM_WAIT'),
    { response: 1, tzid: 9001 },
    { response: 'ERROR_NO_OPERATIONS' },
  ]);
  f.dependencies.claim = async () => {
    if (!claimAvailable) return false;
    claimAvailable = false;
    return true;
  };
  f.dependencies.finalize = async () => {
    if (finalizationCount > 0) return false;
    finalizationCount++;
    return true;
  };
  const outcomes = await Promise.all([
    processNoSmsCancellation(f.activation, f.dependencies),
    processNoSmsCancellation(f.activation, f.dependencies),
  ]);
  if (outcomes.filter((value) => value === 'expired_confirmed').length !== 1) {
    throw new Error('duplicate workers both finalized cancellation');
  }
  if (finalizationCount !== 1 || f.providerCalls.length !== 3) {
    throw new Error('provider or financial operation was duplicated');
  }
});

Deno.test('the local migration reclaims stale sending claims atomically and excludes SMS rows', async () => {
  const migration = await Deno.readTextFile(
    new URL('../../migrations/202611030002_tnum_lifecycle_reliability.sql', import.meta.url),
  );
  const recovery = migration.slice(
    migration.indexOf('create or replace function public.tnum_recover_stale_cancellation_claims()'),
    migration.indexOf('-- The claim remains one atomic operation'),
  );
  for (
    const required of [
      "o.state = 'sending'",
      "o.updated_at <= now() - interval '2 minutes'",
      'for update of a, o skip locked',
      'from public.tnum_activation_sms s',
      "cancellation_state = 'retry'",
    ]
  ) {
    if (!recovery.includes(required)) throw new Error(`stale-claim recovery lacks ${required}`);
  }
});

Deno.test('SQL serializes SMS persistence and cancellation finalization before release', async () => {
  const lifecycle = await Deno.readTextFile(
    new URL('../../migrations/202611030002_tnum_lifecycle_reliability.sql', import.meta.url),
  );
  const finance = await Deno.readTextFile(
    new URL('../../migrations/202611030001_tnum_shared_finance.sql', import.meta.url),
  );
  const smsRpc = lifecycle.slice(
    lifecycle.indexOf('create or replace function public.tnum_save_activation_sms('),
    lifecycle.indexOf('create or replace function public.tnum_record_cancellation_evidence('),
  );
  const finalizeRpc = lifecycle.slice(
    lifecycle.indexOf('create or replace function public.tnum_finalize_activation_cancellation('),
    lifecycle.indexOf('-- The worker is invoked once per minute'),
  );
  const releaseRpc = finance.slice(
    finance.indexOf('create or replace function public.tnum_release_activation_reservation('),
    finance.indexOf('create or replace function public.tnum_capture_activation_reservation('),
  );
  if (!smsRpc.includes('where id = p_activation for update')) {
    throw new Error('SMS persistence no longer locks the activation');
  }
  if (
    !finalizeRpc.includes('where id = p_activation for update') ||
    !finalizeRpc.includes('from public.tnum_activation_sms s')
  ) {
    throw new Error('finalization no longer checks SMS under the activation lock');
  }
  if (!releaseRpc.includes('if exists (select 1 from public.tnum_activation_sms')) {
    throw new Error('financial release no longer refuses recorded SMS');
  }
});


Deno.test('T-NUM reserves a fixed 360-second application deadline', async () => {
  const migration = await Deno.readTextFile(
    new URL('../../migrations/20261104110000_tnum_fixed_application_deadline.sql', import.meta.url),
  );
  const reservation = await Deno.readTextFile(
    new URL('../../migrations/202611030001_tnum_shared_finance.sql', import.meta.url),
  );
  if (!migration.includes('check (activation_timeout_seconds = 360)')) {
    throw new Error('T-NUM runtime timeout is not fixed at 360 seconds');
  }
  if (!reservation.includes("now() + interval '6 minutes'")) {
    throw new Error('T-NUM reserve RPC does not persist a six-minute deadline');
  }
});

Deno.test('previously confirmed close plus ERROR_NO_OPERATIONS reconciles and finalizes', async () => {
  const previousClose = {
    tzid: '9001',
    close_response: '1',
    close_tzid: '9001',
    close_at: '2026-11-03T11:58:00.000Z',
    precheck_status: 'TZ_NUM_WAIT',
    precheck_no_messages: true,
    elapsed_seconds: 392,
    protection_seconds: 120,
  };

  const f = fixture(
    [{ response: 'ERROR_NO_OPERATIONS' }],
    { previousEvidence: { confirmed_close: previousClose } },
  );

  const result = await processNoSmsCancellation(f.activation, f.dependencies);

  if (
    result !== 'expired_confirmed' ||
    f.finalizeCount !== 1 ||
    f.providerCalls.length !== 1 ||
    f.providerCalls[0].method !== 'getState'
  ) {
    throw new Error('previously confirmed close was not reconciled');
  }
});

Deno.test('ERROR_NO_OPERATIONS without previous close evidence never finalizes', async () => {
  const f = fixture(
    [{ response: 'ERROR_NO_OPERATIONS' }],
    { previousEvidence: null },
  );

  const result = await processNoSmsCancellation(f.activation, f.dependencies);

  if (
    result !== 'provider_state_unresolved' ||
    f.finalizeCount !== 0 ||
    f.retries.length !== 1
  ) {
    throw new Error('missing close evidence incorrectly finalized');
  }
});

Deno.test('previous close evidence for another TZID never finalizes', async () => {
  const f = fixture(
    [{ response: 'ERROR_NO_OPERATIONS' }],
    {
      previousEvidence: {
        confirmed_close: {
          tzid: '9999',
          close_response: '1',
          close_tzid: '9999',
          precheck_status: 'TZ_NUM_WAIT',
          precheck_no_messages: true,
        },
      },
    },
  );

  const result = await processNoSmsCancellation(f.activation, f.dependencies);

  if (
    result !== 'provider_state_unresolved' ||
    f.finalizeCount !== 0
  ) {
    throw new Error('different TZID evidence incorrectly finalized');
  }
});

Deno.test('SMS evidence prevents reconciliation even after a confirmed close', async () => {
  const previousClose = {
    tzid: '9001',
    close_response: '1',
    close_tzid: '9001',
    precheck_status: 'TZ_NUM_WAIT',
    precheck_no_messages: true,
  };

  const f = fixture(
    [
      operation(
        9001,
        'TZ_NUM_ANSWER',
        [{ id: 'm3', text: 'Your code is 1234' }],
      ),
    ],
    { previousEvidence: { confirmed_close: previousClose } },
  );

  const result = await processNoSmsCancellation(f.activation, f.dependencies);

  if (
    result !== 'sms_received' ||
    f.finalizeCount !== 0 ||
    f.savedSms.length !== 1
  ) {
    throw new Error('SMS protection failed during reconciliation');
  }
});
