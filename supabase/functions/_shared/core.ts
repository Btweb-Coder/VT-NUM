import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

export const cors = {'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-cron-secret'};
export const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {status, headers: {...cors, 'Content-Type': 'application/json'}});
function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new ApiError(500, `MISSING_${name}`);
  return value;
}

export const admin = (): SupabaseClient => createClient(
  requiredEnv('SUPABASE_URL'),
  requiredEnv('SUPABASE_SERVICE_ROLE_KEY'),
  {auth: {persistSession: false}},
);

export async function authenticatedUser(request: Request, verified = true) {
  const token = request.headers.get('Authorization')?.replace(/^Bearer\s+/i, '');
  if (!token) throw new ApiError(401, 'AUTH_REQUIRED');
  const client = createClient(requiredEnv('SUPABASE_URL'), requiredEnv('SUPABASE_ANON_KEY'), {global: {headers: {Authorization: `Bearer ${token}`}}, auth: {persistSession: false}});
  const {data, error} = await client.auth.getUser();
  if (error || !data.user) throw new ApiError(401, 'AUTH_REQUIRED');
  if (verified && !data.user.email_confirmed_at) throw new ApiError(412, 'EMAIL_NOT_VERIFIED');
  return data.user;
}
export class ApiError extends Error { constructor(readonly status: number, message: string) { super(message); } }
export async function body(request: Request): Promise<Record<string, unknown>> { try { return await request.json(); } catch (_) { throw new ApiError(400, 'INVALID_JSON'); } }
export function requiredString(data: Record<string, unknown>, key: string) { const v = data[key]; if (typeof v !== 'string' || !v.trim()) throw new ApiError(400, `INVALID_${key.toUpperCase()}`); return v.trim(); }
export function handle(fn: (request: Request) => Promise<Response>) { return async (request: Request) => { if (request.method === 'OPTIONS') return new Response('ok', {headers: cors}); try { return await fn(request); } catch (e) { const err = e instanceof ApiError ? e : new ApiError(500, 'INTERNAL'); console.error(err); return json({error: err.message}, err.status); } }; }
function namedSecret(secretName: string, slug: string, errorCode: string): Record<string, unknown> {
  const raw = Deno.env.get(secretName);
  let all: Record<string, unknown>;
  try { all = raw ? JSON.parse(raw) as Record<string, unknown> : {}; }
  catch (_) { throw new ApiError(500, `INVALID_${secretName}`); }
  const secret = all[slug];
  if (!secret || typeof secret !== 'object' || Array.isArray(secret)) throw new ApiError(503, errorCode);
  return secret as Record<string, unknown>;
}
export function providerSecrets(slug: string): Record<string, unknown> { return namedSecret('PROVIDER_SECRETS', slug, 'PROVIDER_NOT_CONFIGURED'); }
export function paymentSecrets(slug: string): Record<string, unknown> { return namedSecret('PAYMENT_SECRETS', slug, 'PAYMENT_GATEWAY_NOT_CONFIGURED'); }
export async function event(client: SupabaseClient, orderId: string, userId: string, eventType: string, providerId?: string, metadata: Record<string, unknown> = {}) { await client.from('order_events').insert({order_id: orderId, user_id: userId, event_type: eventType, provider_id: providerId ?? null, metadata}); }
export async function attempt(client: SupabaseClient, orderId: string, providerId: string, action: string, run: () => Promise<{status: string; metadata?: Record<string, unknown>; errorCode?: string; errorMessage?: string}>) {
  const {data: row, error} = await client.from('provider_attempts').insert({order_id: orderId,provider_id: providerId,action,status: 'STARTED'}).select('id').single(); if(error) throw error;
  try { const result=await run(); await client.from('provider_attempts').update({status:result.status,metadata:result.metadata ?? {},error_code:result.errorCode ?? null,error_message:result.errorMessage ?? null,finished_at:new Date().toISOString()}).eq('id',row.id); return result; }
  catch(e) { await client.from('provider_attempts').update({status:'FAILED',error_code:'PROVIDER_EXCEPTION',error_message:e instanceof Error ? e.message : 'UNKNOWN',finished_at:new Date().toISOString()}).eq('id',row.id); throw e; }
}
