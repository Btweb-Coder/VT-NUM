import { admin, authenticatedUser, body, event, handle, json, requiredString } from '../_shared/core.ts';
import { fulfillActivation } from '../_shared/activation.ts';

Deno.serve(handle(async request => {
  const user = await authenticatedUser(request);
  const data = await body(request);
  const serviceId = requiredString(data, 'serviceId');
  const countryId = requiredString(data, 'countryId');
  const key = requiredString(data, 'idempotencyKey');
  const db = admin();
  const {data: reservation, error} = await db.rpc('reserve_activation_request', {p_user_id: user.id, p_service_id: serviceId, p_country_id: countryId, p_key: key}).single();
  if (error) throw error;
  const reserved = reservation as {order_id: string; is_new: boolean};
  const orderId = reserved.order_id;
  if (!reserved.is_new) {
    const {data: existing, error: existingError} = await db.from('orders').select('*').eq('id', orderId).single();
    if (existingError) throw existingError;
    return json({success: existing.status === 'WAITING_FOR_SMS', orderId, status: existing.status, providerId: existing.provider_id, providerActivationId: existing.provider_activation_id, phoneNumber: existing.phone_number, providerPrice: existing.provider_price, markupPercentage: existing.markup_percentage, customerPrice: existing.customer_price, currency: existing.currency, expiresAt: existing.expires_at, reused: true});
  }
  await event(db, orderId, user.id, 'ORDER_CREATED', undefined, {serviceId, countryId});
  try {
    const response = await fulfillActivation(db, orderId, user.id, 'CUSTOMER');
    await db.from('idempotency_keys').update({status: 'COMPLETED'}).eq('user_id', user.id).eq('operation', 'ACTIVATION').eq('key', key);
    return json(response);
  } catch (cause) {
    await db.from('idempotency_keys').update({status: 'FAILED'}).eq('user_id', user.id).eq('operation', 'ACTIVATION').eq('key', key);
    throw cause;
  }
}));
