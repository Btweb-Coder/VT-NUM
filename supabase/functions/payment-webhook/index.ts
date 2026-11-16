import { admin, ApiError, handle, json, paymentSecrets } from '../_shared/core.ts';
import { refreshPayment } from '../_shared/payments.ts';

/**
 * Fapshi calls this endpoint with ?gateway=fapshi.  The callback is only a
 * wake-up signal: refreshPayment performs the authoritative server-to-server
 * status check before any wallet credit.  Other gateways remain polling-only
 * until their signature contract is configured and tested.
 */
Deno.serve(handle(async request => {
  if (request.method === 'GET') return json({ok: true});
  if (request.method !== 'POST') throw new ApiError(405, 'METHOD_NOT_ALLOWED');
  const gateway = new URL(request.url).searchParams.get('gateway');
  if (gateway !== 'fapshi') throw new ApiError(404, 'UNSUPPORTED_WEBHOOK_GATEWAY');
  const secret = paymentSecrets('fapshi');
  const expected = typeof secret.webhookSecret === 'string' ? secret.webhookSecret : '';
  if (!expected || request.headers.get('x-wh-secret') !== expected) throw new ApiError(401, 'WEBHOOK_UNAUTHORIZED');
  const contentType = request.headers.get('content-type') ?? '';
  const payload = contentType.includes('application/json')
    ? await request.json().catch(() => ({}))
    : Object.fromEntries((await request.formData()).entries());
  const transactionId = typeof payload.transId === 'string' ? payload.transId : '';
  if (!transactionId) throw new ApiError(400, 'MISSING_TRANSACTION_ID');
  const db = admin();
  const {data: intent, error} = await db.from('payment_intents').select('id').eq('provider_transaction_id', transactionId).maybeSingle();
  if (error) throw error;
  if (!intent) return json({ok: true}); // Deliberately do not expose payment references.
  await refreshPayment(intent.id, true);
  return json({ok: true});
}));
