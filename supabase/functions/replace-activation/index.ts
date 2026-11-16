import { admin, authenticatedUser, body, event, handle, json, requiredString } from '../_shared/core.ts';
import { fulfillActivation } from '../_shared/activation.ts';

Deno.serve(handle(async request => {
  const user = await authenticatedUser(request);
  const payload = await body(request);
  const oldOrderId = requiredString(payload, 'orderId');
  const key = requiredString(payload, 'idempotencyKey');
  const db = admin();
  const {data: reservation, error} = await db.rpc('reserve_replacement_request', {p_user_id: user.id, p_old_order_id: oldOrderId, p_key: key}).single();
  if (error) throw error;
  const reserved = reservation as {order_id: string; is_new: boolean};
  const orderId = reserved.order_id;
  if (!reserved.is_new) {
    const {data: existing, error: existingError} = await db.from('orders').select('*').eq('id', orderId).single();
    if (existingError) throw existingError;
    return json({success: existing.status === 'WAITING_FOR_SMS', orderId, oldOrderId, status: existing.status, reused: true});
  }
  await event(db, oldOrderId, user.id, 'ORDER_REPLACED', undefined, {replacementOrderId: orderId, source: 'CUSTOMER'});
  await event(db, orderId, user.id, 'ORDER_CREATED', undefined, {replacedOrderId: oldOrderId, source: 'REPLACEMENT'});
  try {
    const response = await fulfillActivation(db, orderId, user.id, 'REPLACEMENT');
    await db.from('idempotency_keys').update({status: 'COMPLETED'}).eq('user_id', user.id).eq('operation', 'REPLACEMENT').eq('key', key);
    return json({...response, oldOrderId});
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : 'REPLACEMENT_FAILED';
    await db.rpc('fail_replacement_request', {p_old_order_id: oldOrderId, p_new_order_id: orderId, p_code: message, p_message: message});
    await db.from('idempotency_keys').update({status: 'FAILED'}).eq('user_id', user.id).eq('operation', 'REPLACEMENT').eq('key', key);
    throw cause;
  }
}));
