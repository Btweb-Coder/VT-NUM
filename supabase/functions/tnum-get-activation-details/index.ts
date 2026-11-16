import { handler, json, provider, readJson, requireUser } from '../_shared/common.ts';
import { queryExactOperation } from '../_shared/tnum_provider_state.ts';

Deno.serve(handler(async (req) => {
  const { admin, userId } = await requireUser(req);
  const body = await readJson(req);
  const { id } = body;
  const refreshProvider = body.refresh_provider !== false;
  if (typeof id !== 'string' || !/^[0-9a-f-]{36}$/i.test(id)) {
    return json({ error: 'INVALID_ID' }, 400);
  }

  const { data: initial, error: initialError } = await admin.from('tnum_activations')
    .select(
      'id,user_id,status,provider_operation_id,provider_status,provider_time_remaining_seconds,last_provider_check_at,phone_number,service_slug,country_code',
    )
    .eq('user_id', userId).eq('id', id).single();
  if (initialError || !initial) return json({ error: 'ACTIVATION_NOT_FOUND' }, 404);

  let providerState: Record<string, unknown> | null = null;
  let providerRefreshError = false;
  const isTerminal = ['completed', 'expired', 'cancelled', 'failed'].includes(
    String(initial.status),
  );
  if (initial.provider_operation_id !== null && refreshProvider && !isTerminal) {
    try {
      const result = await queryExactOperation(
        (method, params) => provider(method, params),
        initial.provider_operation_id,
      );
      const operation = result.operation;
      if (operation) {
        const providerStatus = String(operation.response ?? '');
        for (const message of result.messages) {
          const { error } = await admin.rpc('tnum_save_activation_sms', {
            p_activation: id,
            p_provider_message_key: message.key,
            p_message_text: message.messageText,
            p_code: message.code,
            p_provider_status: providerStatus,
            p_sender: message.sender,
            p_provider_received_at: message.providerReceivedAt,
            p_provider_payload: message.payload,
          });
          if (error) throw error;
        }
        if (!result.messages.length && providerStatus === 'TZ_NUM_ANSWER') {
          const { error } = await admin.rpc('tnum_save_activation_sms', {
            p_activation: id,
            p_provider_message_key: null,
            p_message_text: null,
            p_code: null,
            p_provider_status: providerStatus,
            p_sender: null,
            p_provider_received_at: null,
            p_provider_payload: null,
          });
          if (error) throw error;
        }
        const { error: updateError } = await admin.from('tnum_activations').update({
          provider_status: providerStatus || initial.provider_status,
          provider_time_remaining_seconds: operation.time !== null &&
              operation.time !== undefined &&
              Number.isFinite(Number(operation.time))
            ? Math.max(0, Math.floor(Number(operation.time)))
            : null,
          phone_number: operation.number ?? initial.phone_number,
          last_provider_check_at: new Date().toISOString(),
        }).eq('id', id).not('status', 'in', '(completed,expired,cancelled,failed)');
        if (updateError) throw updateError;
        providerState = {
          tzid: String(operation.tzid),
          status: providerStatus,
          time: operation.time ?? null,
          number: operation.number ?? null,
          service: operation.service ?? null,
          country: operation.country ?? null,
        };
      } else {
        providerState = {
          tzid: String(initial.provider_operation_id),
          status: 'ERROR_NO_OPERATIONS',
          time: null,
        };
      }
    } catch (error) {
      providerRefreshError = true;
      console.warn(JSON.stringify({
        activation_id: id,
        event: 'details_provider_refresh_failed',
        reason: error instanceof Error ? error.message : 'PROVIDER_REFRESH_FAILED',
      }));
    }
  } else if (initial.provider_operation_id !== null) {
    providerState = {
      tzid: String(initial.provider_operation_id),
      status: initial.provider_status,
      time: initial.provider_time_remaining_seconds,
    };
  }

  const { data, error } = await admin.from('tnum_activations').select(
    '*,services:tnum_services(name),countries:tnum_countries(name,original),activation_sms:tnum_activation_sms(*),activation_status_events:tnum_activation_status_events(*)',
  ).eq('user_id', userId).eq('id', id).single();
  if (error) throw error;
  const {
    provider_price_cents: _providerPrice,
    pricing_markup_bps: _markup,
    pricing_fee_cents: _fee,
    accepted_quote_id: _quote,
    ...activation
  } = data;
  return json({
    activation,
    provider_state: providerState,
    provider_refresh_error: providerRefreshError,
  });
}));
