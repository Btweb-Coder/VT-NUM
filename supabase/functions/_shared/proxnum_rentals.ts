/**
 * Proxnum rental API adapter.
 *
 * Preparatory module: it makes no requests until one of these functions is called.
 * Do not connect it to customer-facing endpoints until rental persistence,
 * wallet accounting, idempotency and provider reconciliation are implemented.
 */
import { providerSecrets } from './core.ts';

type Provider = {
  slug: string;
  endpoint: string;
};

type JsonObject = Record<string, unknown>;
const RENTAL_LOG = '[PROXNUM-RENTALS-ADAPTER]';

function logRental(step: string, details: Record<string, unknown> = {}) {
  console.log(RENTAL_LOG, {
    timestamp: new Date().toISOString(),
    step,
    ...details,
  });
}

function logRentalError(step: string, details: Record<string, unknown> = {}) {
  console.error(RENTAL_LOG, {
    timestamp: new Date().toISOString(),
    step,
    ...details,
  });
}


export type RentalDuration = { hours: number; label: string };
export type RentalCatalogService = {
  code: string;
  name: string;
  icon?: string;
  price: number;
  stock: number | null;
};
export type RentalCatalog = {
  country: string;
  hours: number;
  durations: RentalDuration[];
  countries: Array<{ id: string; name: string }>;
  services: RentalCatalogService[];
  cancelWindowSeconds?: number;
};
export type RentalMessage = {
  id: string | number;
  sender?: string;
  text: string;
  code?: string;
  date?: string;
};
export type RentalStatus = {
  id: string | number;
  phone: string;
  status: 'active' | 'cancelling' | 'cancelled' | 'expired' | string;
  expiresAt?: string;
  canCancel?: boolean;
  cancelPending?: boolean;
  canExtend?: boolean;
  messages: RentalMessage[];
};
export type RentalExtensionOption = { hours: number; label: string; price: number };
export type ProviderRentalSummary = { id: string; phone: string; service: string; country: string; hours: number; price: number; status: string; purchasedAt?: string; expiresAt?: string };

export class ProxnumRentalError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly httpStatus?: number,
    readonly outcomeUncertain = false,
  ) {
    super(message);
    this.name = 'ProxnumRentalError';
  }
}

const asString = (v: unknown): string => typeof v === 'string' ? v : '';
const asObject = (v: unknown): JsonObject =>
  v && typeof v === 'object' && !Array.isArray(v) ? v as JsonObject : {};
const asNumber = (v: unknown): number | null =>
  typeof v === 'number' && Number.isFinite(v) ? v : null;
const providerErrorStatus=(code:string):number|undefined=>({no_numbers:409,price_changed:409,invalid_period:422,insufficient_funds:402,option_unavailable:422,window_closed:409,sms_received:409,extended:409,cancel_pending:409,not_active:409}[code]);

function proxnumBase(provider: Provider): string {
  if (provider.slug !== 'proxnum') throw new ProxnumRentalError('Unsupported provider', 'UNKNOWN_PROVIDER');
  return provider.endpoint.replace(/\/+$/, '');
}

async function rentalRequest(
  provider: Provider,
  path: string,
  init: RequestInit = {},
): Promise<JsonObject> {
  const method = (init.method ?? 'GET').toUpperCase();

logRental('REQUEST_STARTED', {
  method,
  path,
});
  const secrets = providerSecrets('proxnum');
  const token = asString(secrets.apiToken);
  if (!token) {
  logRentalError('REQUEST_TOKEN_MISSING', {
    method,
    path,
  });

  throw new ProxnumRentalError(
    'Provider token is not configured',
    'PROVIDER_NOT_CONFIGURED',
  );
}

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15000);
  let response: Response;

  try {
    response = await fetch(`${proxnumBase(provider)}${path}`, {
      ...init,
      signal: controller.signal,
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
        ...(init.headers ?? {}),
      },
    });
  } catch (error) {
    // For mutating requests this may mean Proxnum processed the request but
    // the response was lost. Callers must reconcile; do not retry a purchase.
    logRentalError('REQUEST_NETWORK_ERROR', {
  method,
  path,
  errorName: error instanceof Error ? error.name : 'UNKNOWN',
  outcomeUncertain: method === 'POST',
});
    throw new ProxnumRentalError(
      error instanceof Error && error.name === 'AbortError'
        ? 'Proxnum request timed out'
        : 'Proxnum network request failed',
      'PROVIDER_RESULT_UNCERTAIN',
      undefined,
      init.method?.toUpperCase() === 'POST',
    );
  } finally {
    clearTimeout(timeout);
  }

  const payload = asObject(await response.json().catch(() => ({})));
  logRental('RESPONSE_RECEIVED', {
  method,
  path,
  httpStatus: response.status,
  ok: response.ok,
});
  if (!response.ok) {
    logRentalError('RESPONSE_HTTP_ERROR', {
  method,
  path,
  httpStatus: response.status,
  providerErrorCode: asString(payload.error) || null,
});
    throw new ProxnumRentalError(
      asString(payload.message) || `Proxnum HTTP ${response.status}`,
      asString(payload.error) || `PROVIDER_HTTP_${response.status}`,
      response.status,
      init.method?.toUpperCase() === 'POST' && response.status >= 500,
    );
  }
  logRental('REQUEST_COMPLETED', {
  method,
  path,
  httpStatus: response.status,
});
  return payload;
}

export async function getRentalCatalog(
  provider: Provider,
  countryCode?: string,
  hours?: number,
): Promise<RentalCatalog> {
  const params = new URLSearchParams();
  if (countryCode) params.set('country', countryCode);
  if (hours !== undefined) params.set('hours', String(hours));
  const query = params.size ? `?${params.toString()}` : '';
  const data = await rentalRequest(provider, `/api/v1/resell/rental/catalog${query}`, { method: 'GET' });
  console.log('[PROXNUM RENTALS] Requête catalogue :', {
  endpoint: `/api/v1/resell/rental/catalog${query}`,
  countryCode: countryCode ?? null,
  hours: hours ?? null,
});

console.log('[PROXNUM RENTALS] Réponse brute :', JSON.stringify(data));

console.log('[PROXNUM RENTALS] Nombre brut de pays :',
  Array.isArray(data.countries) ? data.countries.length : 'INVALIDE');

console.log('[PROXNUM RENTALS] Nombre brut de durées :',
  Array.isArray(data.durations) ? data.durations.length : 'INVALIDE');

console.log('[PROXNUM RENTALS] Nombre brut de services :',
  Array.isArray(data.services) ? data.services.length : 'INVALIDE');

  if (data.ok !== true || !Array.isArray(data.durations) || !Array.isArray(data.countries) || !Array.isArray(data.services)) {
    throw new ProxnumRentalError('Invalid rental catalog response', 'INVALID_PROVIDER_RESPONSE');
  }

  const durations: RentalDuration[] = data.durations.flatMap((item: unknown) => {
    const x = asObject(item);
    const durationHours = asNumber(x.hours);
    return durationHours !== null && durationHours > 0
      ? [{ hours: durationHours, label: asString(x.label) || `${durationHours} hours` }]
      : [];
  });

    const countries = data.countries.flatMap((item: unknown) => {
    const x = asObject(item);
    const id = x.id === undefined || x.id === null ? '' : String(x.id);
    const name = asString(x.name);

    return id && name ? [{ id, name }] : [];
  });

  console.log(
    '[PROXNUM RENTALS] Nombre de pays après conversion :',
    countries.length,
  );
  console.log(
    '[PROXNUM RENTALS] Pays après conversion :',
    JSON.stringify(countries),
  );
  console.log(
    '[PROXNUM RENTALS] Nombre de durées après conversion :',
    durations.length,
  );

  const services: RentalCatalogService[] = data.services.flatMap((item: unknown) => {
    const x = asObject(item);
    const code = asString(x.code);
    const name = asString(x.name);
    const price = asNumber(x.price);
    const stock = x.stock === null ? null : asNumber(x.stock);

    return code && name && price !== null && price > 0
      ? [{ code, name, icon: asString(x.icon) || undefined, price, stock }]
      : [];
  });

  console.log(
    '[PROXNUM RENTALS] Nombre de services après conversion :',
    services.length,
  );

  return {
    country: data.country === undefined ? '' : String(data.country),
    hours: asNumber(data.hours) ?? 0,
    durations,
    countries,
    services,
    cancelWindowSeconds: asNumber(data.cancel_window_seconds) ?? undefined,
  };
}



/**
 * Starts a provider-side rental. maxPrice must be a provider-cost ceiling
 * obtained from a fresh catalog and must never be a client-trusted value.
 * This function does not reserve or charge the Online SIM customer wallet.
 */


export async function buyRental(
  provider: Provider,
  serviceCode: string,
  countryCode: string,
  hours: number,
  maxPrice: number,
): Promise<JsonObject> {
  if (
    !Number.isInteger(hours) ||
    hours <= 0 ||
    !Number.isFinite(maxPrice) ||
    maxPrice <= 0
  ) {
    throw new ProxnumRentalError(
      'Invalid rental purchase parameters',
      'INVALID_RENTAL_PARAMETERS',
    );
  }

  const data = await rentalRequest(
    provider,
    '/api/v1/resell/rental/buy',
    {
      method: 'POST',
      body: JSON.stringify({
        service: serviceCode,
        country: Number(countryCode),
        hours,
        max_price: maxPrice,
      }),
    },
  );

 if (data.ok !== true) {
  const code = asString(data.error) || 'PROVIDER_ERROR';

  throw new ProxnumRentalError(
    asString(data.message) || code,
    code,
    providerErrorStatus(code),
  );
}

  const rental = asObject(data.rental);

  const id =
    rental.id === undefined || rental.id === null
      ? ''
      : String(rental.id).trim();

  const phone = asString(rental.phone).trim();
  const amountPaid =
    asNumber(rental.amount_paid) ?? asNumber(data.price);
  const expiresAt = asString(rental.expires_at);

  // Sans identifiant exact, impossible de rapprocher l'achat
  // de façon sûre. Conserver le hold et demander une réconciliation.
  if (!id) {
    throw new ProxnumRentalError(
      'Purchase response has no rental ID; manual reconciliation required',
      'PROVIDER_RESULT_UNCERTAIN',
      undefined,
      true,
    );
  }

  // Retourner l'ID même si d'autres champs manquent.
  // L'Edge Function doit enregistrer cet ID avant toute autre
  // requête au fournisseur.
  return {
    rentalId: id,
    phone: phone || undefined,
    serviceCode: asString(rental.service) || serviceCode,
    countryCode:
      rental.country === undefined || rental.country === null
        ? countryCode
        : String(rental.country),
    status: asString(rental.status) || 'unknown',
    hours: asNumber(rental.hours) ?? hours,
    providerPrice:
      amountPaid !== null && amountPaid > 0
        ? amountPaid
        : undefined,
    currency: 'USD',
    purchasedAt: asString(rental.purchased_at) || undefined,
    expiresAt: expiresAt || undefined,
    canCancel: rental.can_cancel === true,
    cancelUntil: asString(rental.cancel_until) || undefined,
    canExtend: rental.can_extend === true,
    resultIncomplete:
      !phone ||
      amountPaid === null ||
      amountPaid <= 0 ||
      !expiresAt,
  };
}



export async function getRentalStatus(
  provider: Provider,
  rentalId: string,
): Promise<RentalStatus> {
  const data = await rentalRequest(
    provider,
    `/api/v1/resell/rental/${encodeURIComponent(rentalId)}/status`,
    { method: 'GET' },
  );
  if (data.ok !== true) {
    throw new ProxnumRentalError(asString(data.message) || 'Could not retrieve rental status', asString(data.error) || 'PROVIDER_STATUS_ERROR');
  }

  const rental = asObject(data.rental);
  const id = rental.id === undefined || rental.id === null ? rentalId : String(rental.id);
  const messages: RentalMessage[] = Array.isArray(rental.messages)
    ? rental.messages.flatMap((item: unknown) => {
      const x = asObject(item);
      const text = asString(x.text);
      if (!text) return [];
      const sender=asString(x.sender), date=asString(x.date);
      return [{
        id: typeof x.id === 'string' || typeof x.id === 'number' ? x.id : `${id}-${date}-${sender}-${text}`,
        sender: sender || undefined,
        text,
        code: asString(x.code) || undefined,
        date: date || undefined,
      }];
    })
    : [];

  return {
    id,
    phone: asString(rental.phone),
    status: asString(rental.status) || 'unknown',
    expiresAt: asString(rental.expires_at) || undefined,
    canCancel: rental.can_cancel === true,
    cancelPending: rental.cancel_pending === true,
    canExtend: rental.can_extend === true,
    messages,
  };
}

export async function listProviderRentals(provider: Provider, page=1, perPage=100): Promise<ProviderRentalSummary[]> {
  const params=new URLSearchParams({page:String(Math.max(1,page)),per_page:String(Math.min(100,Math.max(1,perPage)))});
  const data=await rentalRequest(provider,`/api/v1/resell/rentals?${params}`,{method:'GET'});
  if(data.ok!==true||!Array.isArray(data.data)) throw new ProxnumRentalError('Invalid rentals list response','INVALID_PROVIDER_RESPONSE');
  return data.data.flatMap((item:unknown)=>{
    const r=asObject(item), id=r.id===undefined||r.id===null?'':String(r.id), phone=asString(r.phone), service=asString(r.service), country=r.country===undefined?'':String(r.country), hours=asNumber(r.hours), price=asNumber(r.amount_paid);
    return id&&phone&&service&&country&&hours!==null&&price!==null?[{id,phone,service,country,hours,price,status:asString(r.status),purchasedAt:asString(r.purchased_at)||undefined,expiresAt:asString(r.expires_at)||undefined}]:[];
  });
}

export async function getRentalExtensionOptions(
  provider: Provider,
  rentalId: string,
): Promise<RentalExtensionOption[]> {
  const data = await rentalRequest(
    provider,
    `/api/v1/resell/rental/${encodeURIComponent(rentalId)}/extend-options`,
    { method: 'GET' },
  );
  if (data.ok !== true || !Array.isArray(data.options)) {
    throw new ProxnumRentalError(asString(data.message) || 'Invalid extension options response', asString(data.error) || 'INVALID_PROVIDER_RESPONSE');
  }

  return data.options.flatMap((item: unknown) => {
    const x = asObject(item);
    const hours = asNumber(x.hours);
    const price = asNumber(x.price);
    return hours !== null && hours > 0 && price !== null && price > 0
      ? [{ hours, label: asString(x.label) || `${hours} hours`, price }]
      : [];
  });
}

export async function cancelRental(provider: Provider, rentalId: string): Promise<{status: string; pending: boolean}> {
  const data = await rentalRequest(provider, '/api/v1/resell/rental/cancel', {
    method: 'POST', body: JSON.stringify({ id: Number(rentalId) || rentalId }),
  });
  if (data.ok !== true) throw new ProxnumRentalError(asString(data.message) || 'Cancellation rejected', asString(data.error) || 'CANCEL_REJECTED', 409);
  const rental = asObject(data.rental);
  return { status: asString(rental.status) || (data.pending === true ? 'cancelling' : 'cancelled'), pending: data.pending === true || rental.cancel_pending === true };
}

/**
 * Extends an existing rental. maxPrice must come from freshly fetched
 * provider extension options and be checked against the customer's quoted price.
 */
export async function extendRental(
  provider: Provider,
  rentalId: string,
  hours: number,
  maxPrice: number,
): Promise<JsonObject> {
  if (!Number.isInteger(hours) || hours <= 0 || !Number.isFinite(maxPrice) || maxPrice <= 0) {
    throw new ProxnumRentalError('Invalid extension parameters', 'INVALID_RENTAL_PARAMETERS');
  }

  const data = await rentalRequest(
    provider,
    `/api/v1/resell/rental/${encodeURIComponent(rentalId)}/extend`,
    { method: 'POST', body: JSON.stringify({ hours, max_price: maxPrice }) },
  );

  if (data.ok !== true) {
    const code = asString(data.error) || 'PROVIDER_ERROR';
    throw new ProxnumRentalError(asString(data.message) || code, code, providerErrorStatus(code));
  }

  const rental = asObject(data.rental);
  const expiresAt = asString(rental.expires_at);
  const price = asNumber(data.price);
  if (!expiresAt || price === null || price <= 0) {
    throw new ProxnumRentalError(
      'Extension may have succeeded but its response is incomplete; reconcile with Proxnum',
      'PROVIDER_RESULT_UNCERTAIN',
      undefined,
      true,
    );
  }

  return {
    rentalId,
    status: asString(rental.status) || 'active',
    expiresAt,
    providerPrice: price,
    currency: 'USD',
    canCancel: rental.can_cancel === true,
  };
}


// if (!token) throw new ProxnumRentalError('Provider token is not configured', 'PROVIDER_NOT_CONFIGURED');
// if (!response.ok) {