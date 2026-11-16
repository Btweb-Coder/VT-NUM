import { providerSecrets } from './core.ts';

export type ProviderResult = {ok: true; activationId: string; phone: string; price: number; currency: string} | {ok: false; code: string; message?: string};
type Provider = {id:string; slug:string; endpoint:string; config:Record<string, unknown>};

const request = async (url: string, init: RequestInit) => {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), 15000);

  try {
    const r = await fetch(url, {
      ...init,
      signal: c.signal,
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        ...(init.headers ?? {}),
      },
    });

    const responseText = await r.text();

    let j: Record<string, unknown> = {};
    try {
      j = JSON.parse(responseText) as Record<string, unknown>;
    } catch {
      // La réponse n'est pas du JSON valide.
    }

    if (!r.ok) {
      console.error('PROXNUM_HTTP_ERROR', {
        status: r.status,
        body: responseText.slice(0, 500),
        url,
      });

      throw new Error(
        `PROVIDER_HTTP_${r.status}: ${responseText.slice(0, 500)}`,
      );
    }

    return j;
  } finally {
    clearTimeout(t);
  }
};

const str=(value:unknown)=>typeof value==='string'?value:'';
const nested=(data:Record<string,unknown>, path:string):unknown=>path.split('.').reduce<unknown>((v,k)=>v && typeof v==='object' ? (v as Record<string,unknown>)[k] : undefined,data);

export async function purchase(provider: Provider, serviceCode: string, countryCode: string): Promise<ProviderResult> {
 const secrets=providerSecrets(provider.slug);
 if(provider.slug==='proxnum') {
  const data=await request(`${provider.endpoint}/api/v1/resell/virtual/buy`,{method:'POST',headers:{Authorization:`Bearer ${str(secrets.apiToken)}`},body:JSON.stringify({service:serviceCode,country:Number(countryCode)})});
  const activation=data.activation as Record<string,unknown>|undefined; if(data.success!==true) return {ok:false,code:str(data.code)||'PROVIDER_ERROR',message:str(data.message)};
  const id=str(activation?.activation_id), phone=str(activation?.phone), price=activation?.amount_paid; return id&&phone&&typeof price==='number'?{ok:true,activationId:id,phone,price,currency:'USD'}:{ok:false,code:'INVALID_PROVIDER_RESPONSE'};
 }
 if(provider.slug==='codasms') {
  const api=(provider.config.api ?? {}) as Record<string,unknown>; const path=str(api.purchasePath); if(!path) throw new Error('MISSING_CODASMS_API_CONFIG');
  const data=await request(new URL(path,provider.endpoint).toString(),{method:str(api.purchaseMethod)||'POST',headers:{Authorization:`Bearer ${str(secrets.apiToken)}`},body:JSON.stringify({serviceId:serviceCode,countryId:countryCode,...(api.staticBody as Record<string,unknown> ?? {})})});
  if(nested(data,str(api.successField)||'success')!==true)return {ok:false,code:str(nested(data,str(api.errorCodeField)||'code'))||'PROVIDER_ERROR'};
  const id=nested(data,str(api.activationIdField)||'activation.id'),phone=nested(data,str(api.phoneNumberField)||'activation.phone'),price=nested(data,str(api.priceField)||'activation.price');
  return typeof id==='string'&&typeof phone==='string'&&typeof price==='number'?{ok:true,activationId:id,phone,price,currency:str(api.currency)||'USD'}:{ok:false,code:'INVALID_PROVIDER_RESPONSE'};
 }
 return {ok:false,code:'UNKNOWN_PROVIDER'};
}


export async function status(provider: Provider, activationId: string) {
  const secrets = providerSecrets(provider.slug);

  if (provider.slug === 'proxnum') {
    const d = await request(
      `${provider.endpoint}/api/v1/resell/virtual/${encodeURIComponent(activationId)}/status`,
      {
        headers: {
          Authorization: `Bearer ${str(secrets.apiToken)}`,
        },
      },
    );

    const raw = str(d.status).trim().toUpperCase();
    const topCode = str(d.code).trim().toUpperCase();

    const activation = d.activation as
      | Record<string, unknown>
      | undefined;

    const activationCode = str(activation?.code).trim();
    const activationCodeUpper = activationCode.toUpperCase();
    const activationStatus = str(activation?.status)
      .trim()
      .toUpperCase();

    console.log('PROXNUM_STATUS_RAW_RESPONSE', {
      activationId,
      response: d,
    });

    if (d.success !== true) {
      return {
        ok: false,
        status: 'WAITING',
        code: '',
        raw,
      };
    }

    // Priorité aux statuts explicites : EXPIRED.
    if (
      raw === 'EXPIRED' ||
      topCode === 'EXPIRED' ||
      activationCodeUpper === 'EXPIRED'
    ) {
      return {
        ok: true,
        status: 'EXPIRED',
        code: '',
        raw: 'EXPIRED',
      };
    }

    // Priorité aux statuts explicites : CANCELLED.
    if (
      raw === 'CANCELLED' ||
      raw === 'CANCELED' ||
      topCode === 'CANCELLED' ||
      topCode === 'CANCELED' ||
      activationCodeUpper === 'CANCELLED' ||
      activationCodeUpper === 'CANCELED'
    ) {
      return {
        ok: true,
        status: 'CANCELLED',
        code: '',
        raw: 'CANCELLED',
      };
    }

    // "completed" seul ne prouve pas qu'un SMS a été reçu.
    if (
      raw === 'COMPLETED' ||
      activationStatus === 'COMPLETED'
    ) {
      const statusValues = [
        '',
        'EXPIRED',
        'CANCELLED',
        'CANCELED',
        'COMPLETED',
        'PENDING',
        'WAITING',
      ];

      // Un véritable code SMS doit être distingué des statuts.
      if (!statusValues.includes(activationCodeUpper)) {
        return {
          ok: true,
          status: 'SMS_RECEIVED',
          code: activationCode,
          raw: 'COMPLETED',
        };
      }

      // Le cycle est terminé, mais la réception d'un SMS
      // n'est pas établie par les champs disponibles.
      return {
        ok: true,
        status: 'COMPLETED',
        code: '',
        raw: 'COMPLETED',
      };
    }

    return {
      ok: true,
      status: 'WAITING',
      code: '',
      raw,
    };
  }

  // Traitement des autres fournisseurs : inchangé.
  const api = (provider.config.api ?? {}) as Record<string, unknown>;
  const path = str(api.statusPath);

  const d = await request(new URL(path, provider.endpoint).toString(), {
    method: str(api.statusMethod) || 'POST',
    headers: {
      Authorization: `Bearer ${str(secrets.apiToken)}`,
    },
    body: JSON.stringify({
      providerActivationId: activationId,
    }),
  });

  const raw = str(
    nested(d, str(api.statusField) || 'status'),
  ).toUpperCase();

  return {
    ok: nested(d, str(api.successField) || 'success') === true,
    status: [
      'SMS_RECEIVED',
      'COMPLETED',
      'CANCELLED',
      'EXPIRED',
    ].includes(raw)
      ? raw
      : 'WAITING',
    code: str(nested(d, str(api.codeField) || 'code')),
    raw,
  };
}



export async function cancel(
  provider: Provider,
  activationId: string,
) {
  const secrets = providerSecrets(provider.slug);

  if (provider.slug === 'proxnum') {
    let d: Record<string, unknown>;

    try {
      d = await request(
        `${provider.endpoint}/api/v1/resell/virtual/cancel`,
        {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${str(secrets.apiToken)}`,
          },
          body: JSON.stringify({
            activation_id: activationId,
          }),
        },
      );
    } catch (error) {
      const message = error instanceof Error
        ? error.message
        : String(error);

      const alreadyProcessed =
        message.includes('PROVIDER_HTTP_409:') &&
        message.includes('already_processed');

      if (!alreadyProcessed) {
        throw error;
      }

      console.warn('PROXNUM_ALREADY_PROCESSED', {
        activationId,
        message,
      });

      // Proxnum dit que le numéro a déjà été traité.
      // Vérifions son statut avant de confirmer l'annulation.
      const current = await status(provider, activationId);

      console.log('PROXNUM_CANCEL_STATUS_CHECK', {
        activationId,
        result: current,
      });

      if (
        current.ok &&
        (
          current.status === 'CANCELLED' ||
          current.status === 'EXPIRED'
        )
      ) {
        console.info('PROXNUM_CANCELLATION_CONFIRMED', {
          activationId,
          providerStatus: current.status,
          reason: 'ALREADY_PROCESSED',
        });

        return true;
      }

      // Statut inconnu, incomplet ou incompatible :
      // ne pas déclarer l'annulation confirmée.
      return false;
    }

    // Réponse normale : seule l'acceptation explicite
    // de Proxnum confirme la demande d'annulation.
    if (
      d.success === true &&
      d.code === 'cancel_accepted'
    ) {
      return true;
    }

    if (
      d.success === false &&
      d.code === 'cancel_rejected'
    ) {
      return false;
    }

    throw new Error('PROVIDER_CANCEL_UNCERTAIN');
  }

  // Traitement des autres fournisseurs : inchangé.
  const api = (provider.config.api ?? {}) as Record<string, unknown>;
  const path = str(api.cancelPath);

  if (!path) {
    throw new Error('MISSING_PROVIDER_CANCEL_CONFIG');
  }

  const d = await request(
    new URL(path, provider.endpoint).toString(),
    {
      method: str(api.cancelMethod) || 'POST',
      headers: {
        Authorization: `Bearer ${str(secrets.apiToken)}`,
      },
      body: JSON.stringify({
        providerActivationId: activationId,
      }),
    },
  );

  return nested(d, str(api.successField) || 'success') === true;
}
