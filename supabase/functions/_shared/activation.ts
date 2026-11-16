import { admin, ApiError, attempt, event } from './core.ts';
import { cancel, purchase } from './providers.ts';

type Order = Record<string, any>;

export async function compensateUnfundedAllocation(db: ReturnType<typeof admin>, order: Order, reason: string) {
  await db.from('orders').update({status: 'CANCELLING', failure_code: reason}).eq('id', order.id);
  const provider = (await db.from('providers').select('id,slug,endpoint,config').eq('id', order.provider_id).single()).data;
  if (!provider || !order.provider_activation_id) return;
  const result = await attempt(db, order.id, provider.id, 'CANCEL', async () => {
    try {
      const confirmed = await cancel(provider, order.provider_activation_id);
      return confirmed ? {status: 'SUCCESS'} : {status: 'FAILED', errorCode: 'PROVIDER_CANCEL_FAILED'};
    } catch (error) { return {status: 'FAILED', errorCode: 'PROVIDER_CANCEL_EXCEPTION', errorMessage: error instanceof Error ? error.message : 'UNKNOWN'}; }
  });
  if (result.status === 'SUCCESS') {
    await db.from('orders').update({status: 'FAILED', provider_cancellation_confirmed: true}).eq('id', order.id).eq('status', 'CANCELLING');
    await event(db, order.id, order.user_id, 'PROVIDER_CANCELLED', provider.id, {reason});
  }
}

/** Purchases a provider allocation, then creates the exact wallet hold before exposing it as active. */
export async function fulfillActivation(db: ReturnType<typeof admin>, orderId: string, userId: string, source: string) {
  const {data: order, error: orderError} = await db.from('orders').select('*').eq('id', orderId).single();
  if (orderError || !order || order.user_id !== userId) throw new ApiError(404, 'ORDER_NOT_FOUND');
  const [{data: service}, {data: country}, {data: providers, error: providersError}] = await Promise.all([
    db.from('services').select('code,name,flag').eq('id', order.service_id).eq('active', true).single(),
    db.from('countries').select('code,name,flag').eq('id', order.country_id).eq('active', true).single(),
    db.from('providers').select('id,slug,endpoint,config,provider_service_mappings!inner(provider_code),provider_country_mappings!inner(provider_code)').eq('active', true).eq('provider_service_mappings.service_id', order.service_id).eq('provider_country_mappings.country_id', order.country_id).order('priority'),
  ]);
  if (!service || !country) throw new ApiError(400, 'INVALID_CATALOG_SELECTION');
  if (providersError) throw providersError;
  if (!providers?.length) throw new ApiError(503, 'SERVICE_TEMPORARILY_UNAVAILABLE');

  const { data: claimed, error: claimError } = await db.rpc(
  'claim_activation_fulfillment',
  {
    p_order_id: orderId,
    p_user_id: userId,
  },
);

if (claimError) throw claimError;

if (claimed !== true) {
  throw new ApiError(409, 'ORDER_ALREADY_PROCESSING');
}

  for (const provider of providers as any[]) {
    
    const serviceCode = provider.provider_service_mappings?.[0]?.provider_code;
    const countryCode = provider.provider_country_mappings?.[0]?.provider_code;
    const result = await attempt(db, orderId, provider.id, 'PURCHASE', async () => {
      try {
        const bought = await purchase(provider, serviceCode, countryCode);
        return bought.ok ? {status: 'SUCCESS', metadata: {providerActivationId: bought.activationId, phoneNumber: bought.phone, providerPrice: bought.price, currency: bought.currency}} : {status: bought.code === 'NO_NUMBERS' ? 'NO_NUMBERS' : 'FAILED', errorCode: bought.code, errorMessage: bought.message};
      } catch (error) { return {status: 'FAILED', errorCode: 'PROVIDER_EXCEPTION', errorMessage: error instanceof Error ? error.message : 'UNKNOWN'}; }
    });
    if (result.status !== 'SUCCESS') continue;
    const values = (result.metadata ?? {}) as Record<string, unknown>;
    const price = Number(values.providerPrice);
    if (!Number.isFinite(price) || price <= 0 || typeof values.providerActivationId !== 'string' || typeof values.phoneNumber !== 'string') continue;
    const expiresAt = new Date(Date.now() + 6 * 60 * 1000).toISOString();
    // PostgreSQL owns the calculation, snapshot, and hold so rounding and
    // balance checks cannot diverge from the durable ledger.
    const {data: priced, error: pricedError} = await db.rpc('assign_activation_and_create_hold', {
      p_order_id: orderId, p_provider_id: provider.id, p_provider_activation_id: values.providerActivationId,
      p_phone_number: values.phoneNumber, p_provider_price: price, p_currency: values.currency ?? 'USD',
      p_service_code: service.code, p_service_name: service.name, p_country_code: country.code,
      p_country_name: country.name, p_country_flag: country.flag, p_expires_at: expiresAt,
    }).single();
    if (pricedError || !priced) {
      await compensateUnfundedAllocation(db, {...order, provider_id: provider.id, provider_activation_id: values.providerActivationId, id: orderId}, 'WALLET_HOLD_FAILED');
      throw new ApiError(409, pricedError?.message ?? 'WALLET_HOLD_FAILED');
    }
    const priceSnapshot = priced as {customer_price: number | string; markup_type: string; markup_value: number | string};
    const customerPrice = Number(priceSnapshot.customer_price);
    await event(db, orderId, userId, 'WAITING_FOR_SMS', provider.id, {source});
    return {success: true, orderId, status: 'WAITING_FOR_SMS', providerId: provider.id, providerActivationId: values.providerActivationId, phoneNumber: values.phoneNumber, providerPrice: price, markupPercentage: priceSnapshot.markup_type === 'percentage' ? Number(priceSnapshot.markup_value) : 0, customerPrice, currency: values.currency ?? 'USD', expiresAt, reused: false};
  }
  await db.from('orders').update({status: 'FAILED', failure_code: 'NO_PROVIDER_AVAILABLE'}).eq('id', orderId);
  throw new ApiError(409, 'NO_NUMBERS_AVAILABLE');
}
