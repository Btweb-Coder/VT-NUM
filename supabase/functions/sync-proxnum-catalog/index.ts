import { admin } from '../_shared/core.ts';

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => v && typeof v === 'object' && !Array.isArray(v) ? v as Obj : {};
const str = (v: unknown): string => typeof v === 'string' ? v.trim() : '';
const uriSafeHttps = (value: string): string => {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && url.hostname ? value : '';
  } catch {
    return '';
  }
};
const num = (v: unknown): number | null => typeof v === 'number' && Number.isFinite(v) ? v : null;
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
  });

Deno.serve(async (request: Request) => {
  if (request.method !== 'POST') return reply({ success: false, error: 'METHOD_NOT_ALLOWED' }, 405);
  const expected = Deno.env.get('CATALOG_SYNC_SECRET') ?? '';
  const supplied = request.headers.get('x-catalog-sync-secret') ?? '';
  if (expected.length < 32 || supplied.length !== expected.length || supplied !== expected) {
    return reply({ success: false, error: 'UNAUTHORIZED' }, 401);
  } // str
  try {
    const db = admin();
    const { data: provider, error: pError } = await db.from('providers')
      .select('id,slug,endpoint,active').eq('slug', 'proxnum').eq('active', true).single();
    if (pError || !provider?.id || provider.slug !== 'proxnum') {
      return reply({ success: false, error: 'PROXNUM_PROVIDER_NOT_CONFIGURED' }, 503);
    }
    let secrets: Obj;
    try {
      secrets = obj(JSON.parse(Deno.env.get('PROVIDER_SECRETS') ?? '{}'));
    } catch {
      return reply({ success: false, error: 'PROVIDER_SECRETS_INVALID_JSON' }, 503);
    }
    const token = str(obj(secrets.proxnum).apiToken);
    if (!token) return reply({ success: false, error: 'PROXNUM_TOKEN_NOT_CONFIGURED' }, 503);
    const base = str(provider.endpoint).replace(/\/+$/, '');
    if (!base.startsWith('https://')) {
      return reply({ success: false, error: 'INVALID_PROVIDER_ENDPOINT' }, 503);
    }

    const get = async (path: string): Promise<Obj> => {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 15000);
      try {
        const response = await fetch(`${base}${path}`, {
          headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
          signal: controller.signal,
        });
        const payload = obj(await response.json().catch(() => ({})));
        if (!response.ok) throw new Error(`PROVIDER_HTTP_${response.status}`);
        return payload;
      } finally {
        clearTimeout(timeout);
      }
    };

    // Read-only endpoints only: no purchase, cancellation, wallet, or payment operation.

    // Endpoints en lecture seule : aucune opération d'achat.
    const [prices, rental, officialCountries, officialServices] = await Promise.all([
      get('/api/v1/prices'),
      get('/api/v1/resell/rental/catalog'),
      get('/api/v1/countries'),
      get('/api/v1/services'),
    ]);

    if (
      prices.success !== true ||
      !prices.prices ||
      typeof prices.prices !== 'object' ||
      Array.isArray(prices.prices)
    ) {
      return reply({ success: false, error: 'INVALID_PRICES_RESPONSE' }, 502);
    }

    if (
      rental.ok !== true ||
      !Array.isArray(rental.countries) ||
      !Array.isArray(rental.services)
    ) {
      return reply(
        { success: false, error: 'INVALID_RENTAL_CATALOG_RESPONSE' },
        502,
      );
    }

    if (
      !Array.isArray(officialCountries.countries) ||
      !Array.isArray(officialServices.services)
    ) {
      return reply(
        { success: false, error: 'INVALID_OFFICIAL_CATALOG_RESPONSE' },
        502,
      );
    }

    const priceMap = obj(prices.prices);
    const countryCodes = Object.keys(priceMap)
      .filter((code) => /^\d+$/.test(code));

    if (!countryCodes.length) {
      return reply({ success: false, error: 'EMPTY_PRICES_COUNTRIES' }, 502);
    }

    // Référentiel officiel des pays.
    const countryNames = new Map<string, string>();
    const officialCountryFlags = new Map<string, string>();

    for (const item of officialCountries.countries as unknown[]) {
      const x = obj(item);
      const code = str(x.code);
      const name = str(x.name);
      const flag = uriSafeHttps(str(x.flag));

      if (/^\d+$/.test(code) && name) {
        countryNames.set(code, name);
        if (flag) officialCountryFlags.set(code, flag);
      }
    }

    // Référentiel officiel des services.
    const serviceNames = new Map<string, string>();
    const officialServiceCodes = new Set<string>();
    const officialServiceIcons = new Map<string, string>();

    for (const item of officialServices.services as unknown[]) {
      const x = obj(item);
      const code = str(x.service);
      const name = str(x.name);
      const icon = uriSafeHttps(str(x.icon));

      if (/^[a-zA-Z0-9_-]{1,80}$/.test(code) && name) {
        officialServiceCodes.add(code);
        serviceNames.set(code, name);

        if (icon) {
          officialServiceIcons.set(code, icon);
        }
      }
    }

    // Compléter les noms officiels avec les services du catalogue
    // de location lorsque leur code est absent de la liste principale.
    for (const item of rental.services as unknown[]) {
      const x = obj(item);
      const code = str(x.code);
      const name = str(x.name);
      const icon = uriSafeHttps(str(x.icon));

      if (
        /^[a-zA-Z0-9_-]{1,80}$/.test(code) &&
        name &&
        !serviceNames.has(code)
      ) {
        serviceNames.set(code, name);
      }

      if (
        /^[a-zA-Z0-9_-]{1,80}$/.test(code) &&
        icon &&
        !officialServiceIcons.has(code)
      ) {
        officialServiceIcons.set(code, icon);
      }
    }

    // Construire la liste des services réellement tarifés.
    const serviceCodes = new Set<string>();

    for (const country of countryCodes) {
      for (const [code, raw] of Object.entries(obj(priceMap[country]))) {
        const item = obj(raw);

        if (
          /^[a-zA-Z0-9_-]{1,80}$/.test(code) &&
          num(item.base_price) !== null &&
          num(item.sell_price) !== null
        ) {
          serviceCodes.add(code);
        }
      }
    }

    if (!serviceCodes.size) {
      return reply({ success: false, error: 'EMPTY_PRICES_SERVICES' }, 502);
    }

    const syncServiceCodes = [...serviceCodes]
      .filter((code) => officialServiceCodes.has(code))
      .sort();

    if (!syncServiceCodes.length) {
      return reply({
        success: false,
        error: 'NO_MATCHING_OFFICIAL_SERVICES',
        pricedServiceCount: serviceCodes.size,
        officialServiceCount: officialServiceCodes.size,
        note: 'Aucune écriture en base.',
      }, 502);
    }

    // Ne jamais réintroduire des noms provisoires.
    const missingCountries = countryCodes.filter(
      (code) => !countryNames.has(code),
    );

    if (missingCountries.length) {
      return reply({
        success: false,
        error: 'OFFICIAL_COUNTRY_NAMES_MISSING',
        missingCountryCount: missingCountries.length,
        missingCountrySamples: missingCountries.slice(0, 40),
        note: 'Aucune écriture en base.',
      }, 502);
    }

    // Charger les données existantes pour préserver les visuels.
    const { data: existingCountries, error: existingCountriesError } = await db
      .from('countries')
      .select('code,flag');

    if (existingCountriesError) {
      throw new Error(`COUNTRIES_READ_FAILED:${existingCountriesError.message}`);
    }

    const { data: existingServices, error: existingServicesError } = await db
      .from('services')
      .select('code,flag');

    if (existingServicesError) {
      throw new Error(`SERVICES_READ_FAILED:${existingServicesError.message}`);
    }

    const countryFlags = new Map(
      (existingCountries ?? []).map((x) => [String(x.code), str(x.flag)]),
    );
    const serviceFlags = new Map(
      (existingServices ?? []).map((x) => [String(x.code), str(x.flag)]),
    );

    const { data: countries, error: cError } = await db
      .from('countries')
      .upsert(
        countryCodes.map((code) => ({
          code,
          name: countryNames.get(code)!,
          flag: officialCountryFlags.get(code) ?? countryFlags.get(code) ?? '',
          active: true,
        })),
        { onConflict: 'code' },
      )
      .select('id,code');

    if (cError || !countries) {
      throw new Error(`COUNTRIES_UPSERT_FAILED:${cError?.message ?? 'unknown'}`);
    }

    const { data: services, error: sError } = await db
      .from('services')
      .upsert(
        syncServiceCodes.map((code) => ({
          code,
          name: serviceNames.get(code)!,
          flag: (() => {
            const official = officialServiceIcons.get(code) ?? '';
            const existing = serviceFlags.get(code) ?? '';

            // Préserver un logo existant si l'icône officielle est générique.
            if (official.includes('ui-avatars.com')) {
              return existing || official;
            }

            return official || existing;
          })(),
          active: true,
        })),
        { onConflict: 'code' },
      )
      .select('id,code');

    if (sError || !services) {
      throw new Error(`SERVICES_UPSERT_FAILED:${sError?.message ?? 'unknown'}`);
    }

    const countryIds = new Map(
      countries.map((x) => [String(x.code), String(x.id)]),
    );
    const serviceIds = new Map(
      services.map((x) => [String(x.code), String(x.id)]),
    );

    const countryMappings = countryCodes.flatMap((code) =>
      countryIds.has(code)
        ? [{
          provider_id: provider.id,
          country_id: countryIds.get(code),
          provider_code: code,
        }]
        : []
    );

    const serviceMappings = syncServiceCodes.flatMap((code) =>
      serviceIds.has(code)
        ? [{
          provider_id: provider.id,
          service_id: serviceIds.get(code),
          provider_code: code,
        }]
        : []
    );

    const { error: cmError } = await db
      .from('provider_country_mappings')
      .upsert(countryMappings, { onConflict: 'provider_id,country_id' });

    if (cmError) {
      throw new Error(`COUNTRY_MAPPINGS_FAILED:${cmError.message}`);
    }

    const { error: smError } = await db
      .from('provider_service_mappings')
      .upsert(serviceMappings, { onConflict: 'provider_id,service_id' });

    if (smError) {
      throw new Error(`SERVICE_MAPPINGS_FAILED:${smError.message}`);
    }

    return reply({
      success: true,
      provider: 'proxnum',
      countriesSynced: countries.length,
      servicesSynced: services.length,
      countryMappingsSynced: countryMappings.length,
      serviceMappingsSynced: serviceMappings.length,
      notes: [
        'Lecture seule côté Proxnum; aucun numéro acheté.',
        'Noms et drapeaux des pays récupérés depuis le catalogue officiel.',
        'Noms et icônes des services récupérés depuis le catalogue officiel.',
        'Aucune table de recharge, portefeuille ou paiement modifiée.',
      ],
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'UNKNOWN_ERROR';
    return reply({ success: false, error: message.split(':')[0] }, 500);
  }
});
