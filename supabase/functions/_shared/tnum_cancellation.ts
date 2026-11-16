import {
  hasProviderSms,
  operationForTzid,
  operationMessages,
  operationRemainingSeconds,
  responseCode,
  type TnumProviderMessage,
} from './tnum_provider_state.ts';

export type CancellationActivation = Record<string, unknown> & {
  id: string;
  provider_operation_id: string | number;
  service_slug?: string;
  provider_requested_at?: string | null;
  created_at?: string | null;
};

export type CancellationEvidence = Record<string, unknown>;

export type CancellationDependencies = {
  now?: () => number;
  provider: (method: string, params: Record<string, string | number | boolean>) => Promise<unknown>;
  claim: (activationId: string) => Promise<boolean>;
    readEvidence: (
    activationId: string,
  ) => Promise<CancellationEvidence | null>;
  saveSms: (
    activationId: string,
    messages: TnumProviderMessage[],
    providerStatus: string,
  ) => Promise<boolean>;
  capture: (activationId: string) => Promise<void>;
  recordEvidence: (activationId: string, evidence: CancellationEvidence) => Promise<void>;
  finalize: (activationId: string) => Promise<boolean>;
  retry: (activationId: string, reason: string, evidence: CancellationEvidence) => Promise<void>;
};

export type CancellationOutcome =
  | 'not_eligible'
  | 'claim_lost'
  | 'sms_received'
  | 'expired_confirmed'
  | 'completed_captured'
  | 'retry_scheduled'
  | 'provider_state_unresolved';

const CLOSE_ELIGIBLE = new Set(['TZ_INPOOL', 'TZ_NUM_WAIT']);

export function closeProtectionSeconds(serviceSlug: unknown): number {
  return String(serviceSlug ?? '').trim().toLowerCase() === 'whatsapp' ? 300 : 120;
}

export function providerElapsedSeconds(
  activation: CancellationActivation,
  nowMs: number,
): number | null {
  const startedAt = activation.provider_requested_at ?? activation.created_at;
  if (!startedAt) return null;
  const startedMs = Date.parse(startedAt);
  if (!Number.isFinite(startedMs)) return null;
  return Math.max(0, Math.floor((nowMs - startedMs) / 1000));
}

export async function processNoSmsCancellation(
  activation: CancellationActivation,
  dependencies: CancellationDependencies,
): Promise<CancellationOutcome> {
  const id = String(activation.id);
  const tzid = String(activation.provider_operation_id);
  const now = dependencies.now ?? Date.now;

const claimed = await dependencies.claim(id);
if (!claimed) return 'claim_lost';

let evidence: CancellationEvidence = {
  tzid,
  claimed_at: new Date(now()).toISOString(),
};

try {
  const previousEvidence = await dependencies.readEvidence(id);

  const confirmedClose = previousEvidence?.confirmed_close as
    | Record<string, unknown>
    | undefined;
    const precheckResult = await dependencies.provider('getState', {
      tzid: Number(tzid),
      message_to_code: 0,
      msg_list: 1,
      orderby: 'asc',
      lang: 'en',
    });

    const precheck = operationForTzid(precheckResult, tzid);
    const precheckCode = responseCode(precheckResult);
    evidence = {
      ...evidence,
      precheck_code: precheckCode || null,
      precheck_status: precheck ? String(precheck.response ?? '') : null,
      precheck_tzid: precheck ? String(precheck.tzid) : null,
      precheck_no_messages: true,
      precheck_time_remaining: operationRemainingSeconds(precheck),
      precheck_at: new Date(now()).toISOString(),
    };
    await dependencies.recordEvidence(id, evidence);

   if (!precheck) {
const elapsedSeconds = Number(confirmedClose?.elapsed_seconds);
const protectionSeconds = Number(confirmedClose?.protection_seconds);

const previousCloseIsValid =
  precheckCode === 'ERROR_NO_OPERATIONS' &&
  confirmedClose !== undefined &&
  String(confirmedClose.tzid) === tzid &&
  String(confirmedClose.close_response) === '1' &&
  String(confirmedClose.close_tzid) === tzid &&
  confirmedClose.precheck_no_messages === true &&
  ['TZ_INPOOL', 'TZ_NUM_WAIT'].includes(
    String(confirmedClose.precheck_status ?? ''),
  ) &&
  Number.isFinite(elapsedSeconds) &&
  Number.isFinite(protectionSeconds) &&
  elapsedSeconds >= protectionSeconds;

  if (previousCloseIsValid) {
evidence = {
  ...evidence,
  ...confirmedClose,
  precheck_tzid: tzid,
  precheck_no_messages: true,
  no_sms_confirmed: true,
  postcheck_code: 'ERROR_NO_OPERATIONS',
  postcheck_tzid: tzid,
  reconciliation_at: new Date(now()).toISOString(),
  reconciliation_code: 'ERROR_NO_OPERATIONS',
  terminal_status: 'CLOSED_AFTER_CONFIRMED_REQUEST',
};

    await dependencies.recordEvidence(id, evidence);

    return await dependencies.finalize(id)
      ? 'expired_confirmed'
      : 'provider_state_unresolved';
  }

  await dependencies.retry(
    id,
    'TARGETED_OPERATION_NOT_FOUND',
    evidence,
  );

  return 'provider_state_unresolved';
}

    const status = String(precheck.response ?? '');
    const messages = operationMessages(precheck, id);
    if (hasProviderSms(precheck) || messages.length || status === 'TZ_NUM_ANSWER') {
      evidence = { ...evidence, precheck_no_messages: false };
      await dependencies.recordEvidence(id, evidence);
      await dependencies.saveSms(id, messages, status);
      return 'sms_received';
    }

    if (status === 'TZ_OVER_OK') {
      await dependencies.capture(id);
      return 'completed_captured';
    }

    if (status === 'TZ_OVER_EMPTY') {
      evidence = {
        ...evidence,
        no_sms_confirmed: true,
        terminal_status: status,
        verified_at: new Date(now()).toISOString(),
      };
      await dependencies.recordEvidence(id, evidence);
      return await dependencies.finalize(id) ? 'expired_confirmed' : 'provider_state_unresolved';
    }

    if (!CLOSE_ELIGIBLE.has(status)) {
      console.warn(JSON.stringify({
        activation_id: id,
        event: 'unknown_provider_state_during_cancellation',
        provider_status: status,
      }));
      await dependencies.retry(id, `UNKNOWN_PROVIDER_STATE_${status || 'EMPTY'}`, evidence);
      return 'provider_state_unresolved';
    }

    const elapsed = providerElapsedSeconds(activation, now());
    const protection = closeProtectionSeconds(activation.service_slug);
    if (elapsed === null || elapsed < protection) {
      evidence = {
        ...evidence,
        elapsed_seconds: elapsed,
        protection_seconds: protection,
      };
      await dependencies.retry(id, 'PROVIDER_PROTECTIVE_INTERVAL', evidence);
      return 'retry_scheduled';
    }

    const closeResult = await dependencies.provider('setOperationOk', {
      tzid: Number(tzid),
      lang: 'en',
    });
    const closeResponse = responseCode(closeResult) || String(closeResult ?? '');
    evidence = {
      ...evidence,
      elapsed_seconds: elapsed,
      protection_seconds: protection,
      close_response: closeResponse,
      close_tzid: String((closeResult as Record<string, unknown> | null)?.tzid ?? tzid),
      close_at: new Date(now()).toISOString(),
    };
    await dependencies.recordEvidence(id, evidence);

    if (closeResponse !== '1' || evidence.close_tzid !== tzid) {
      await dependencies.retry(
        id,
        `PROVIDER_CLOSE_UNCONFIRMED_${closeResponse || 'EMPTY'}`,
        evidence,
      );
      return 'retry_scheduled';
    }

    // The close response is necessary but not sufficient; always verify the
    // same persisted operation ID again before a release can be finalized.
    const verifyResult = await dependencies.provider('getState', {
      tzid: Number(tzid),
      message_to_code: 0,
      msg_list: 1,
      orderby: 'asc',
      lang: 'en',
    });
    const verified = operationForTzid(verifyResult, tzid);
    const verifyCode = responseCode(verifyResult);
    const verifyStatus = verified ? String(verified.response ?? '') : verifyCode;
    evidence = {
      ...evidence,
      postcheck_code: verifyCode || null,
      postcheck_status: verifyStatus || null,
      postcheck_tzid: verified
        ? String(verified.tzid)
        : (verifyCode === 'ERROR_NO_OPERATIONS' ? tzid : null),
      postcheck_time_remaining: operationRemainingSeconds(verified),
      postcheck_at: new Date(now()).toISOString(),
    };
    await dependencies.recordEvidence(id, evidence);

    if (verified) {
      const verifiedMessages = operationMessages(verified, id);
      if (hasProviderSms(verified) || verifiedMessages.length || verifyStatus === 'TZ_NUM_ANSWER') {
        await dependencies.saveSms(id, verifiedMessages, verifyStatus);
        return 'sms_received';
      }
      if (verifyStatus === 'TZ_OVER_OK') {
        await dependencies.capture(id);
        return 'completed_captured';
      }
      if (verifyStatus === 'TZ_OVER_EMPTY') {
        evidence = { ...evidence, no_sms_confirmed: true, terminal_status: verifyStatus };
        await dependencies.recordEvidence(id, evidence);
        return await dependencies.finalize(id) ? 'expired_confirmed' : 'provider_state_unresolved';
      }
      await dependencies.retry(
        id,
        `PROVIDER_CLOSE_NOT_TERMINAL_${verifyStatus || 'EMPTY'}`,
        evidence,
      );
      return 'retry_scheduled';
    }

    if (verifyCode === 'ERROR_NO_OPERATIONS' && closeResponse === '1') {
      evidence = {
        ...evidence,
        no_sms_confirmed: true,
        terminal_status: 'CLOSED_AFTER_CONFIRMED_REQUEST',
      };
      await dependencies.recordEvidence(id, evidence);
      return await dependencies.finalize(id) ? 'expired_confirmed' : 'provider_state_unresolved';
    }

    await dependencies.retry(
      id,
      `PROVIDER_POSTCHECK_UNRESOLVED_${verifyCode || 'EMPTY'}`,
      evidence,
    );
    return 'provider_state_unresolved';
  } catch (error) {
    const reason = error instanceof Error ? error.message : 'PROVIDER_CANCELLATION_UNKNOWN_ERROR';
    await dependencies.retry(id, reason, evidence);
    return 'retry_scheduled';
  }
}
