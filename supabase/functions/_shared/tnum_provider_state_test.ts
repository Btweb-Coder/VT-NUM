import {
  hasProviderSms,
  normalizeOperations,
  operationForTzid,
  operationMessages,
  operationRemainingSeconds,
  queryExactOperation,
} from './tnum_provider_state.ts';

Deno.test('getState accepts arrays and wrapped operation responses', () => {
  const array = normalizeOperations([{ tzid: 42, response: 'TZ_NUM_WAIT' }]);
  const wrapped = normalizeOperations({ response: [{ tzid: 43, response: 'TZ_INPOOL' }] });
  if (array[0].tzid !== 42 || wrapped[0].tzid !== 43) {
    throw new Error('operation shape was not normalized');
  }
});

Deno.test('an exact tzid lookup never selects a different operation', () => {
  const result = operationForTzid([
    { tzid: 51, response: 'TZ_NUM_WAIT' },
    { tzid: 52, response: 'TZ_NUM_ANSWER' },
  ], 52);
  if (String(result?.tzid) !== '52') throw new Error('wrong operation was selected');
  if (operationForTzid([{ tzid: 51, response: 'TZ_NUM_WAIT' }], 52) !== null) {
    throw new Error('a nonmatching provider operation was accepted');
  }
});

Deno.test('full SMS, code, sender, provider timestamp, and payload are retained', () => {
  const operation = {
    tzid: 60,
    response: 'TZ_NUM_ANSWER',
    msg: [{
      id: 'm-1',
      text: 'Your verification code is 482913',
      time: 1790000000,
      from: 'Example',
    }],
  };
  if (!hasProviderSms(operation)) throw new Error('provider SMS was not detected');
  const messages = operationMessages(operation, 'activation-1', {
    tzid: 60,
    response: 'TZ_NUM_ANSWER',
    msg: ['482913'],
  });
  const message = messages[0];
  if (!message || message.messageText !== 'Your verification code is 482913') {
    throw new Error('full message was lost');
  }
  if (message.code !== '482913') throw new Error('code-only response was not paired');
  if (message.sender !== 'Example') throw new Error('sender was lost');
  if (message.providerReceivedAt !== new Date(1790000000 * 1000).toISOString()) {
    throw new Error('provider timestamp was lost');
  }
  if (message.payload.id !== 'm-1') throw new Error('provider payload was not retained');
});

Deno.test('provider SMS with an unfamiliar object shape still blocks cancellation', () => {
  const operation = { tzid: 61, response: 'TZ_NUM_WAIT', msg: [{ payload: 'opaque' }] };
  const messages = operationMessages(operation, 'activation-2');
  if (!hasProviderSms(operation) || messages.length !== 1 || !messages[0].messageText) {
    throw new Error('unfamiliar SMS payload was dropped');
  }
});

Deno.test('remaining provider time accepts only nonnegative numeric values', () => {
  if (operationRemainingSeconds({ time: '513' }) !== 513) {
    throw new Error('remaining time was not parsed');
  }
  if (operationRemainingSeconds({ time: '-1' }) !== null) {
    throw new Error('negative time was accepted');
  }
  if (operationRemainingSeconds({}) !== null) throw new Error('missing time was accepted');
});

Deno.test('detail lookup requests full SMS and code for the same exact tzid', async () => {
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const result = await queryExactOperation(
    async (method, params) => {
      calls.push({ method, params });
      return [{
        tzid: 70,
        response: 'TZ_NUM_ANSWER',
        time: 99,
        msg: [
          method === 'getState' && params.message_to_code === 0
            ? { time: 'm1', text: 'Full body' }
            : '1234',
        ],
      }];
    },
    70,
    async () => {},
  );
  if (calls.length !== 2 || calls.some((call) => call.method !== 'getState')) {
    throw new Error('expected two state requests');
  }
  if (
    calls.some((call) =>
      call.params.tzid !== 70 || call.params.msg_list !== 1 || call.params.orderby !== 'asc'
    )
  ) {
    throw new Error('state request did not use the exact operation and message-list parameters');
  }
  if (calls[0].params.message_to_code !== 0 || calls[1].params.message_to_code !== 1) {
    throw new Error('full and code-only modes were not requested');
  }
  if (result.messages[0]?.messageText !== 'Full body' || result.messages[0]?.code !== '1234') {
    throw new Error('full message and code were not merged');
  }
});
