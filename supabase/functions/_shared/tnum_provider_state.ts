export type TnumProviderMessage = {
  key: string;
  messageText: string;
  code: string | null;
  sender: string | null;
  providerReceivedAt: string | null;
  payload: Record<string, unknown>;
};

export type TnumProviderOperation = Record<string, unknown> & {
  tzid?: string | number;
  response?: string | number;
  time?: string | number;
  msg?: unknown;
};

export function responseCode(value: unknown): string {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return String((value as Record<string, unknown>).response ?? '');
  }
  return '';
}

export function isNoOperations(value: unknown): boolean {
  return responseCode(value) === 'ERROR_NO_OPERATIONS';
}

export function normalizeOperations(value: unknown): TnumProviderOperation[] {
  if (Array.isArray(value)) return value.filter(isRecord) as TnumProviderOperation[];
  if (!isRecord(value)) throw new Error('PROVIDER_INVALID_RESPONSE');
  if (isNoOperations(value)) return [];
  if (Array.isArray(value.response)) {
    return value.response.filter(isRecord) as TnumProviderOperation[];
  }
  const arrays = Object.values(value).filter(Array.isArray);
  if (arrays.length === 1) {
    return arrays[0].filter(isRecord) as TnumProviderOperation[];
  }
  if (typeof value.response === 'string' && value.response.startsWith('TZ_')) {
    return [value as TnumProviderOperation];
  }
  throw new Error('PROVIDER_INVALID_RESPONSE');
}

export function operationForTzid(
  value: unknown,
  tzid: string | number,
): TnumProviderOperation | null {
  const exactId = String(tzid);
  return normalizeOperations(value).find((row) => String(row.tzid ?? '') === exactId) ?? null;
}

export function operationMessages(
  value: unknown,
  operationId: string,
  codeOnlyValue?: unknown,
): TnumProviderMessage[] {
  if (!isRecord(value)) return [];
  const fullRows = messageRows(value.msg);
  const codeRows = isRecord(codeOnlyValue) ? messageRows(codeOnlyValue.msg) : [];
  return fullRows.map((message, index) => {
    const full = toRecord(message);
    const codeRow = toRecord(codeRows[index]);
    const text = textValue(
      full.text ?? full.message ?? full.body ?? full.msg ?? full.code ?? full.otp ?? message,
    ) || (Object.keys(full).length > 0 ? JSON.stringify(full) : '');
    const codeValue = full.code ?? full.otp ?? codeRow.code ?? codeRow.otp ?? codeRow.text ??
      codeRows[index];
    const receivedAt = parseProviderDate(
      full.received_at ?? full.receivedAt ?? full.time ?? full.date ?? full.timestamp,
    );
    const senderValue = full.sender ?? full.from ?? full.from_number ?? full.originator;
    const stableKey = textValue(
      full.id ?? full.message_id ?? full.time ?? full.date ?? full.timestamp ?? index,
    );
    return {
      key: `${operationId}:${stableKey}`,
      messageText: text,
      code: textValue(codeValue) || null,
      sender: textValue(senderValue) || null,
      providerReceivedAt: receivedAt,
      payload: full,
    };
  }).filter((message) => message.messageText.length > 0);
}

export function hasProviderSms(operation: unknown): boolean {
  return isRecord(operation) && messageRows(operation.msg).length > 0;
}

export function operationRemainingSeconds(value: unknown): number | null {
  if (!isRecord(value)) return null;
  const seconds = Number(value.time);
  return Number.isFinite(seconds) && seconds >= 0 ? Math.floor(seconds) : null;
}

export async function queryExactOperation(
  providerCall: (
    method: string,
    params: Record<string, string | number | boolean>,
  ) => Promise<unknown>,
  tzid: string | number,
  pause: (milliseconds: number) => Promise<void> = (ms) =>
    new Promise((resolve) => setTimeout(resolve, ms)),
): Promise<{
  fullResult: unknown;
  codeResult: unknown;
  operation: TnumProviderOperation | null;
  messages: TnumProviderMessage[];
}> {
  const id = String(tzid);
  const params = {
    tzid: Number(id),
    msg_list: 1,
    orderby: 'asc',
    lang: 'en',
  };
  const fullResult = await providerCall('getState', {
    ...params,
    message_to_code: 0,
  });
  await pause(1200);
  const codeResult = await providerCall('getState', {
    ...params,
    message_to_code: 1,
  });
  const operation = operationForTzid(fullResult, id);
  const codeOperation = operationForTzid(codeResult, id);
  return {
    fullResult,
    codeResult,
    operation,
    messages: operation ? operationMessages(operation, id, codeOperation) : [],
  };
}

function messageRows(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  if (typeof value === 'string' && value.trim()) return [value];
  if (isRecord(value)) return [value];
  return [];
}

function toRecord(value: unknown): Record<string, unknown> {
  if (isRecord(value)) return value;
  return typeof value === 'string' ? { text: value } : {};
}

function textValue(value: unknown): string {
  return value === undefined || value === null ? '' : String(value).trim();
}

function parseProviderDate(value: unknown): string | null {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value === 'number' || /^\d{10,13}$/.test(String(value))) {
    const numeric = Number(value);
    const milliseconds = String(value).length <= 10 ? numeric * 1000 : numeric;
    const date = new Date(milliseconds);
    return Number.isNaN(date.getTime()) ? null : date.toISOString();
  }
  const date = new Date(String(value));
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
