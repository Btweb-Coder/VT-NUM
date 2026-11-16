import { handler, json, provider, readJson, requireUser } from '../_shared/common.ts';
import { queryExactOperation } from '../_shared/tnum_provider_state.ts';

Deno.serve(handler(async (req) => {
  const { admin, userId } = await requireUser(req);
  const { id } = await readJson(req);
  if (typeof id !== 'string' || !/^[0-9a-f-]{36}$/i.test(id)) {
    return json({ error: 'INVALID_ID' }, 400);
  }
  const { data: activation, error } = await admin.from('tnum_activations')
    .select('id,status,provider_operation_id').eq('user_id', userId).eq(
      'id',
      id,
    ).single();
  if (error || !activation) return json({ error: 'ACTIVATION_NOT_FOUND' }, 404);
  if (
    activation.status !== 'sms_received' || !activation.provider_operation_id
  ) {
    return json({ error: 'SMS_NOT_AVAILABLE' }, 409);
  }
  const { count } = await admin.from('tnum_activation_sms')
    .select('id', { count: 'exact', head: true }).eq('activation_id', id);
  if (!count) return json({ error: 'SMS_NOT_AVAILABLE' }, 409);
  const { data: claimed, error: claimError } = await admin.rpc(
    'tnum_claim_sms_revise',
    { p_activation: id },
  );
  if (claimError) throw claimError;
  if (claimed !== true) return json({ error: 'REQUEST_RATE_LIMIT' }, 429);
  await provider('setOperationRevise', {
    tzid: activation.provider_operation_id,
    lang: 'fr',
  });
  // Revise advances only the provider pointer. Read the same operation again
  // to retrieve and persist the full SMS and code.
  const result = await queryExactOperation(
    (method, params) => provider(method, params),
    activation.provider_operation_id,
  );
  const operation = result.operation;
  if (operation) {
    const providerStatus = String(operation.response ?? '');
    for (const message of result.messages) {
      const { error: saveError } = await admin.rpc('tnum_save_activation_sms', {
        p_activation: id,
        p_provider_message_key: message.key,
        p_message_text: message.messageText,
        p_code: message.code,
        p_provider_status: providerStatus,
        p_sender: message.sender,
        p_provider_received_at: message.providerReceivedAt,
        p_provider_payload: message.payload,
      });
      if (saveError) throw saveError;
    }
    if (!result.messages.length && providerStatus === 'TZ_NUM_ANSWER') {
      const { error: saveError } = await admin.rpc('tnum_save_activation_sms', {
        p_activation: id,
        p_provider_message_key: null,
        p_message_text: null,
        p_code: null,
        p_provider_status: providerStatus,
        p_sender: null,
        p_provider_received_at: null,
        p_provider_payload: null,
      });
      if (saveError) throw saveError;
    }
    const { error: updateError } = await admin.from('tnum_activations').update({
      provider_status: providerStatus,
      phone_number: operation.number ?? null,
      last_provider_check_at: new Date().toISOString(),
    }).eq('id', id).not('status', 'in', '(completed,expired,cancelled,failed)');
    if (updateError) throw updateError;
  }
  console.info(JSON.stringify({ activation_id: id, event: 'sms_revised' }));
  return json({ accepted: true, provider_status: operation?.response ?? 'ERROR_NO_OPERATIONS' });
}));
