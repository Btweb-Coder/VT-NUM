import { admin, authenticatedUser, body, handle, json, paymentSecrets, requiredString, ApiError } from '../_shared/core.ts';
import { initiatePayment, normalizePhone } from '../_shared/payments.ts';

Deno.serve(handle(async request => {
  const user=await authenticatedUser(request); const data=await body(request); const slug=requiredString(data,'gateway'); const key=requiredString(data,'idempotencyKey'); const rawAmount=data.amount;
  if (!['fapshi','cinetpay','transfluo'].includes(slug) || typeof rawAmount !== 'number' || !Number.isSafeInteger(rawAmount) || rawAmount<=0) throw new ApiError(400,'INVALID_TOPUP_REQUEST');
  const phone = normalizePhone(slug, requiredString(data, 'phone'));

const medium =
  slug === 'fapshi'
    ? requiredString(data, 'medium')
    : 'mobile money';

if (
  slug === 'fapshi' &&
  !['mobile money', 'orange money'].includes(medium)
) {
  throw new ApiError(400, 'INVALID_FAPSHI_MEDIUM');
}

const db = admin();
  const {data: gateway,error:gatewayError}=await db.from('payment_gateways').select('*').eq('slug',slug).eq('active',true).single(); if(gatewayError||!gateway) throw new ApiError(503,'PAYMENT_GATEWAY_UNAVAILABLE');
  
const {
  data: feeRow,
  error: feeError,
} = await db
  .from('payment_fee_config')
  .select('fee_percent, min_topup_amount, max_topup_amount')
  .eq('id', true)
  .single();

if (feeError || !feeRow) {
  throw new ApiError(503, 'TOPUP_CONFIG_UNAVAILABLE');
}

const minTopup = Number(feeRow.min_topup_amount);
const maxTopup = Number(feeRow.max_topup_amount);

if (
  !Number.isFinite(minTopup) ||
  !Number.isFinite(maxTopup) ||
  minTopup <= 0 ||
  maxTopup < minTopup
) {
  throw new ApiError(503, 'INVALID_TOPUP_LIMIT_CONFIG');
}

if (rawAmount < minTopup) {
  throw new ApiError(400, 'TOPUP_AMOUNT_TOO_LOW');
}

if (rawAmount > maxTopup) {
  throw new ApiError(400, 'TOPUP_AMOUNT_TOO_HIGH');
}

const feePercent = Number(feeRow.fee_percent);

if (!Number.isFinite(feePercent) || feePercent < 0 || feePercent > 1) {
  throw new ApiError(503, 'INVALID_TOPUP_FEE_CONFIG');
}

const fee =
  Math.round(rawAmount * feePercent * 100) / 100;

const exchangeRate = Number(gateway.exchange_rate);

if (!Number.isFinite(exchangeRate) || exchangeRate <= 0) {
  throw new ApiError(503, 'INVALID_EXCHANGE_RATE');
}

const providerAmount = Math.ceil(
  (rawAmount + fee) * exchangeRate,
);

if (providerAmount < Number(gateway.min_provider_amount)) {
  throw new ApiError(400, 'TOPUP_AMOUNT_TOO_LOW');
}

  const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(phone)); const phoneHash=[...new Uint8Array(digest)].map(value=>value.toString(16).padStart(2,'0')).join('');
  const {data: existing}=await db.from('payment_intents').select('*,payment_gateways(slug)').eq('user_id',user.id).eq('idempotency_key',key).maybeSingle(); if(existing) return json({intentId:existing.id,status:existing.status,gateway:existing.payment_gateways?.slug,amount:existing.amount,providerAmount:existing.provider_amount,fee:existing.fee,currency:existing.currency,providerCurrency:existing.provider_currency,checkoutUrl:existing.checkout_url,failureCode:existing.failure_code});
  const {data: active}=await db.from('payment_intents').select('*,payment_gateways(slug)').eq('user_id',user.id).in('status',['INITIATED','PENDING','REQUIRES_RECONCILIATION']).maybeSingle(); if(active) return json({intentId:active.id,status:active.status,gateway:active.payment_gateways?.slug,amount:active.amount,providerAmount:active.provider_amount,fee:active.fee,currency:active.currency,providerCurrency:active.provider_currency,checkoutUrl:active.checkout_url,failureCode:active.failure_code});
  const {data: intent,error:insertError}=await db.from('payment_intents').insert({user_id:user.id,gateway_id:gateway.id,gateway_slug:gateway.slug,idempotency_key:key,amount:rawAmount,fee,provider_amount:providerAmount,provider_currency:gateway.provider_currency,exchange_rate:gateway.exchange_rate,phone_last4:phone.slice(-4),phone_hash:phoneHash}).select().single();
  if(insertError) throw insertError;
  try { paymentSecrets(slug); const started = await initiatePayment(
  gateway,
  intent,
  phone,
  user.email,
  medium,
); await db.from('payment_intents').update({status:'PENDING',provider_transaction_id:started.transactionId,provider_reference_id:started.referenceId,provider_status:started.rawStatus,checkout_url:started.checkoutUrl,initiated_at:new Date().toISOString(),next_poll_at:new Date(Date.now()+30_000).toISOString()}).eq('id',intent.id); return json({intentId:intent.id,status:'PENDING',gateway:slug,amount:rawAmount,providerAmount,fee,currency:'USD',providerCurrency:gateway.provider_currency,checkoutUrl:started.checkoutUrl}); }
  catch(cause) { await db.from('payment_intents').update({status:'REQUIRES_RECONCILIATION',start_error:cause instanceof Error?cause.message:'UNKNOWN',reconciliation_required_at:new Date().toISOString()}).eq('id',intent.id); throw cause; }
}));
