import { admin, ApiError, paymentSecrets } from './core.ts';

type Gateway = Record<string, any>;
type Verification = {state: 'SUCCESSFUL'|'FAILED'|'PENDING'|'REQUIRES_RECONCILIATION'; rawStatus: string; transactionId?: string; reason?: string};
const request = async (url: string, init: RequestInit = {}) => {
  const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 15_000);
  try { const response = await fetch(url, {...init, signal: controller.signal, headers: {'Content-Type': 'application/json', ...(init.headers ?? {})}}); const data = await response.json().catch(() => ({})); if (!response.ok) {
  const detail =
    typeof data.message === 'string'
      ? data.message
      : typeof data.error === 'string'
        ? data.error
        : 'NO_PROVIDER_ERROR_MESSAGE';

  throw new Error(
    `PAYMENT_GATEWAY_HTTP_${response.status}:${detail.slice(0, 300)}`,
  );
} return data as Record<string, any>; }
  finally { clearTimeout(timer); }
};
const config = (gateway: Gateway) => (gateway.config?.api ?? {}) as Record<string, any>;
const path = (gateway: Gateway, field: string) => { const value = config(gateway)[field]; if (typeof value !== 'string' || !value.startsWith('/')) throw new ApiError(503, `MISSING_${gateway.slug.toUpperCase()}_API_CONFIG`); return value; };
const number = (value: unknown) => typeof value === 'number' ? value : typeof value === 'string' ? Number(value) : NaN;

export function normalizePhone(gateway: string, input: string) {
  const digits = input.replace(/[\s+]/g, '');
  if (gateway === 'fapshi') { const local = digits.startsWith('237') ? digits.slice(3) : digits; if (!/^6\d{8}$/.test(local)) throw new ApiError(400, 'INVALID_CAMEROON_PHONE'); return local; }
  if (gateway === 'transfluo') { const local = digits.startsWith('237') ? digits.slice(3) : digits; if (!/^6\d{8}$/.test(local)) throw new ApiError(400, 'INVALID_CAMEROON_PHONE'); return `237${local}`; }
  if (!/^\d{8,16}$/.test(digits)) throw new ApiError(400, 'INVALID_PHONE'); return digits;
}

export async function initiatePayment(
  gateway: Gateway,
  intent: Record<string, any>,
  phone: string,
  email?: string,
  medium = 'mobile money',
) {
  const secret = paymentSecrets(gateway.slug); const api = config(gateway);
  if (gateway.slug === 'fapshi') {
  const data = await request(
    `${gateway.endpoint}${path(gateway, 'requestPath')}`,
    {
      method: 'POST',
      headers: {
        apiuser: String(secret.apiUser),
        apikey: String(secret.apiKey),
      },
      body: JSON.stringify({
        amount: intent.provider_amount,
        phone,
        medium,
        email,
        userId: intent.user_id,
        externalId: intent.id,
        message: `Wallet top-up ${intent.id}`,
      }),
    },
  );

  console.info('FAPSHI_INITIATION_DIAGNOSTIC', {
    transactionId: data.transId ?? null,
    status: data.status ?? null,
    code: data.code ?? null,
    responseKeys: Object.keys(data),
  });

  if (typeof data.transId !== 'string') {
    throw new Error('INVALID_GATEWAY_RESPONSE');
  }

  return {
    transactionId: data.transId,
    rawStatus: 'CREATED',
    checkoutUrl: null,
    referenceId: null,
  };
}
  if (gateway.slug === 'cinetpay') {
    const staticBody = api.initiateStaticBody && typeof api.initiateStaticBody === 'object' ? api.initiateStaticBody : {};
    const data = await request(`${gateway.endpoint}${path(gateway, 'initiatePath')}`, {method: 'POST', body: JSON.stringify({...staticBody, apikey: secret.apiKey, site_id: secret.siteId, transaction_id: intent.id, amount: intent.provider_amount, currency: intent.provider_currency, customer_phone_number: phone, customer_email: email, description: `Wallet top-up ${intent.id}`})});
    const checkoutUrl = data.data?.payment_url; if (String(data.code) !== '201' || typeof checkoutUrl !== 'string' || !checkoutUrl.startsWith('https://')) throw new Error(`CINETPAY_INITIATION_FAILED:${String(data.code ?? 'UNKNOWN')}`);
    return {transactionId: intent.id, rawStatus: String(data.message ?? 'CREATED'), checkoutUrl, referenceId: null};
  }
    if (gateway.slug === 'transfluo') {
    const data = await request(
      `${gateway.endpoint}${path(gateway, 'requestPath')}`,
      {
        method: 'POST',
        body: JSON.stringify({
          merchant_id: secret.merchantId,
          api_key: secret.apiKey,
          amount: intent.provider_amount,
          currency: 'XAF',
          customer: phone,
          order_id: intent.id,
        }),
      },
    );

    const rawStatus = String(data.status ?? 'PENDING').toUpperCase();

    if (
      typeof data.transaction_id !== 'string' ||
      !data.transaction_id ||
      ['FAILED', 'FAILURE', 'ERROR'].includes(rawStatus)
    ) {
      throw new Error(
        `TRANSFLUO_INITIATION_FAILED:${String(data.message ?? rawStatus)}`,
      );
    }

    return {
      transactionId: data.transaction_id,
      rawStatus,
      checkoutUrl: null,
      referenceId:
        typeof data.mtn_reference_id === 'string'
          ? data.mtn_reference_id
          : null,
    };
  }

  throw new Error(`UNSUPPORTED_PAYMENT_GATEWAY:${gateway.slug}`);
}

export async function verifyPayment(gateway: Gateway, intent: Record<string, any>): Promise<Verification> {
  if (!intent.provider_transaction_id) return {state: 'REQUIRES_RECONCILIATION', rawStatus: 'MISSING_TRANSACTION_ID', reason: 'MISSING_TRANSACTION_ID'};
  const secret = paymentSecrets(gateway.slug); let raw = 'PENDING'; let amount = NaN; let currency: string|undefined; let transactionId = intent.provider_transaction_id; let reason: string|undefined;
  if (gateway.slug === 'fapshi') {
  const data = await request(
    `${gateway.endpoint}${path(gateway, 'checkPath')}/${encodeURIComponent(transactionId)}`,
    {
      method: 'GET',
      headers: {
        apiuser: String(secret.apiUser),
        apikey: String(secret.apiKey),
      },
    },
  );

  console.info('FAPSHI_VERIFY_DIAGNOSTIC', {
    transactionId,
    status: data.status ?? null,
    code: data.code ?? null,
    amount: data.amount ?? null,
    hasReason: typeof data.reason === 'string',
    hasMessage: typeof data.message === 'string',
    responseKeys: Object.keys(data),
  });

  raw = String(data.status ?? 'PENDING').toUpperCase();
  amount = number(data.amount);
  currency = gateway.provider_currency;

  transactionId =
    typeof data.transId === 'string'
      ? data.transId
      : transactionId;

  reason =
    typeof data.reason === 'string'
      ? data.reason
      : undefined;
}
  else if (gateway.slug === 'cinetpay') { const data=await request(`${gateway.endpoint}${path(gateway,'checkPath')}`, {method:'POST',body:JSON.stringify({apikey:secret.apiKey,site_id:secret.siteId,transaction_id:transactionId})}); const details=data.data&&typeof data.data==='object'?data.data:{}; raw=String(details.status ?? data.status ?? 'PENDING').toUpperCase(); amount=number(details.amount); currency=typeof details.currency==='string'?details.currency:undefined; reason=typeof data.message==='string'?data.message:undefined; }

  else if (gateway.slug === 'transfluo') {
    const data = await request(
      `${gateway.endpoint}${path(gateway, 'checkPath')}?transaction_id=${encodeURIComponent(transactionId)}`,
      { method: 'GET' },
    );

    raw = String(data.status ?? 'PENDING').toUpperCase();

    amount = number(data.amount ?? data.paid_amount);

    currency =
      typeof data.currency === 'string'
        ? data.currency.toUpperCase()
        : undefined;

    transactionId =
      typeof data.transaction_id === 'string'
        ? data.transaction_id
        : transactionId;

    reason =
      typeof data.reason === 'string'
        ? data.reason
        : typeof data.message === 'string'
          ? data.message
          : undefined;

    // Transfluo's trusted Laravel reference credits only SUCCESSFUL.
    if (raw === 'SUCCESSFUL') {
      const hasAmount = Number.isFinite(amount);
      const hasCurrency = Boolean(currency);

      // If the provider supplies either field, validate both.
      if (
        (hasAmount || hasCurrency) &&
        (
          amount !== Number(intent.provider_amount) ||
          currency !== String(intent.provider_currency).toUpperCase()
        )
      ) {
        return {
          state: 'REQUIRES_RECONCILIATION',
          rawStatus: raw,
          transactionId,
          reason: 'PAYMENT_AMOUNT_OR_CURRENCY_MISMATCH',
        };
      }

      return {
        state: 'SUCCESSFUL',
        rawStatus: raw,
        transactionId,
        reason,
      };
    }

    if (
      ['FAILED', 'FAILURE', 'REFUSED', 'CANCELLED', 'EXPIRED', 'ERROR'].includes(raw)
    ) {
      return { state: 'FAILED', rawStatus: raw, transactionId, reason };
    }

    return { state: 'PENDING', rawStatus: raw, transactionId, reason };
  }
  else {
    const data = await request(
      `${gateway.endpoint}${path(gateway, 'checkPath')}?transaction_id=${encodeURIComponent(transactionId)}`,
      { method: 'GET' },
    );

    raw = String(data.status ?? 'PENDING').toUpperCase();
    amount = number(data.amount ?? data.paid_amount);
    currency =
      typeof data.currency === 'string'
        ? data.currency.toUpperCase()
        : undefined;
    transactionId =
      typeof data.transaction_id === 'string'
        ? data.transaction_id
        : transactionId;
    reason =
      typeof data.reason === 'string'
        ? data.reason
        : typeof data.message === 'string'
          ? data.message
          : undefined;
  }

    if (['FAILED','FAILURE','REFUSED','CANCELLED','EXPIRED','ERROR'].includes(raw)) {
    return {state:'FAILED',rawStatus:raw,transactionId,reason};
  }

  if (!['SUCCESSFUL','SUCCESS','SUCCES','ACCEPTED'].includes(raw)) {
    return {state:'PENDING',rawStatus:raw,transactionId,reason};
  }

  if (
    amount !== Number(intent.provider_amount) ||
    currency?.toUpperCase() !== String(intent.provider_currency).toUpperCase()
  ) {
    return {
      state:'REQUIRES_RECONCILIATION',
      rawStatus:raw,
      transactionId,
      reason:'PAYMENT_AMOUNT_OR_CURRENCY_MISMATCH',
    };
  }

  return {state:'SUCCESSFUL',rawStatus:raw,transactionId,reason};
}

export async function refreshPayment(intentId: string, manual: boolean) {
  const db = admin(); const {data: claimed, error} = await db.rpc('claim_payment_intent', {p_intent_id:intentId,p_manual:manual}).maybeSingle(); if (error) throw error;
  if (!claimed) { const {data: current,error:readError}=await db.from('payment_intents').select('*,payment_gateways(slug)').eq('id',intentId).single(); if(readError) throw readError; return current; }
  const {data: intent,error:intentError}=await db.from('payment_intents').select('*').eq('id',intentId).single(); if(intentError) throw intentError;
  const {data: gateway,error:gatewayError}=await db.from('payment_gateways').select('*').eq('id',intent.gateway_id).single(); if(gatewayError || !gateway) throw gatewayError ?? new Error('PAYMENT_GATEWAY_NOT_FOUND');
  try {
    const result=await verifyPayment(gateway,intent); const base={provider_status:result.rawStatus,provider_transaction_id:result.transactionId ?? intent.provider_transaction_id,poll_lease_id:null,poll_lease_until:null,last_poll_error:null};
    if(result.state==='SUCCESSFUL') { const {error:creditError}=await db.rpc('credit_payment_intent',{p_intent_id:intent.id,p_provider_status:result.rawStatus,p_provider_transaction_id:result.transactionId ?? intent.provider_transaction_id}); if(creditError) throw creditError; await db.from('payment_intents').update(base).eq('id',intent.id); }
    else if(result.state==='FAILED') await db.from('payment_intents').update({...base,status:'FAILED',failure_code:result.reason ?? 'PAYMENT_FAILED',failed_at:new Date().toISOString()}).eq('id',intent.id);
    else if(result.state==='REQUIRES_RECONCILIATION') await db.from('payment_intents').update({...base,status:'REQUIRES_RECONCILIATION',failure_code:result.reason ?? 'PAYMENT_RECONCILIATION_REQUIRED',reconciliation_required_at:new Date().toISOString()}).eq('id',intent.id);
    else await db.from('payment_intents').update({...base,next_poll_at:new Date(Date.now()+60_000).toISOString()}).eq('id',intent.id);
  } catch (cause) { await db.from('payment_intents').update({poll_lease_id:null,poll_lease_until:null,last_poll_error:cause instanceof Error?cause.message:'UNKNOWN',next_poll_at:new Date(Date.now()+60_000).toISOString()}).eq('id',intent.id); throw cause; }
  const {data: final,error:finalError}=await db.from('payment_intents').select('*,payment_gateways(slug)').eq('id',intentId).single(); if(finalError) throw finalError; return final;
}
