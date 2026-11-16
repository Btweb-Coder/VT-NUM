
import { createClient } from "npm:@supabase/supabase-js@2";

type Country = {
  providerCode: string;
  isoCode: string;
  name: string;
  flag?: string;
  source: string;
};

type Service = {
  providerCode: string;
  code: string;
  name: string;
  source: string;
};

type Catalog = { countries: Country[]; services: Service[] };

const file = Deno.args[0];
if (!file) throw new Error("Provide verified-catalog.json");

const url = Deno.env.get("SUPABASE_URL");
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
if (!url || !key) {
  throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required");
}

const catalog = JSON.parse(await Deno.readTextFile(file)) as Catalog;
if (!Array.isArray(catalog.countries) || !Array.isArray(catalog.services)) {
  throw new Error("Invalid catalog format");
}

function assertUnique(values: string[], label: string) {
  if (new Set(values).size !== values.length) {
    throw new Error(`Duplicate ${label} found; import aborted`);
  }
}

assertUnique(catalog.countries.map(x => x.providerCode), "country provider code");
assertUnique(catalog.countries.map(x => x.isoCode), "country ISO code");
assertUnique(catalog.services.map(x => x.providerCode), "service provider code");
assertUnique(catalog.services.map(x => x.code), "service application code");

for (const c of catalog.countries) {
  if (!/^\d+$/.test(c.providerCode) || !/^[A-Z]{2}$/.test(c.isoCode) ||
      !c.name.trim() || !c.source.trim()) {
    throw new Error(`Invalid country record: ${JSON.stringify(c)}`);
  }
}

for (const s of catalog.services) {
  if (!s.providerCode.trim() || !s.code.trim() ||
      !s.name.trim() || !s.source.trim()) {
    throw new Error(`Invalid service record: ${JSON.stringify(s)}`);
  }
}

const db = createClient(url, key, { auth: { persistSession: false } });

const { data: provider, error: providerError } = await db
  .from("providers")
  .select("id,active")
  .eq("slug", "proxnum")
  .single();

if (providerError || !provider) {
  throw providerError ?? new Error("Proxnum provider not registered");
}

// Read-only preflight: don't overwrite existing catalog names.
const { data: existingCountries, error: countriesError } = await db
  .from("countries")
  .select("id,code,name");

if (countriesError) throw countriesError;

const { data: existingServices, error: servicesError } = await db
  .from("services")
  .select("id,code,name");

if (servicesError) throw servicesError;

const countryByCode = new Map(
  (existingCountries ?? []).map(x => [x.code, x])
);
const serviceByCode = new Map(
  (existingServices ?? []).map(x => [x.code, x])
);

for (const c of catalog.countries) {
  const old = countryByCode.get(c.isoCode);
  if (old && old.name !== c.name) {
    throw new Error(
      `Country name conflict for ${c.isoCode}: database="${old.name}", catalog="${c.name}". Review manually before importing.`,
    );
  }
}

for (const s of catalog.services) {
  const old = serviceByCode.get(s.code);
  if (old && old.name !== s.name) {
    throw new Error(
      `Service name conflict for ${s.code}: database="${old.name}", catalog="${s.name}". Review manually before importing.`,
    );
  }
}

// Read current mappings and reject conflicts before writing anything.
const { data: oldCountryMappings, error: oldCountryMapError } = await db
  .from("provider_country_mappings")
  .select("country_id,provider_code")
  .eq("provider_id", provider.id);

if (oldCountryMapError) throw oldCountryMapError;

const { data: oldServiceMappings, error: oldServiceMapError } = await db
  .from("provider_service_mappings")
  .select("service_id,provider_code")
  .eq("provider_id", provider.id);

if (oldServiceMapError) throw oldServiceMapError;

const existingCountryIds = new Map(
  (existingCountries ?? []).map(x => [x.id, x.code])
);
const existingServiceIds = new Map(
  (existingServices ?? []).map(x => [x.id, x.code])
);

const countryByProviderCode = new Map<string, string>();
const providerCodeByCountry = new Map<string, string>();

for (const m of oldCountryMappings ?? []) {
  const iso = existingCountryIds.get(m.country_id);
  if (iso) countryByProviderCode.set(m.provider_code, iso);
  if (iso) providerCodeByCountry.set(iso, m.provider_code);
}

const serviceByProviderCode = new Map<string, string>();
const providerCodeByService = new Map<string, string>();

for (const m of oldServiceMappings ?? []) {
  const code = existingServiceIds.get(m.service_id);
  if (code) serviceByProviderCode.set(m.provider_code, code);
  if (code) providerCodeByService.set(code, m.provider_code);
}

for (const c of catalog.countries) {
  const mappedIso = countryByProviderCode.get(c.providerCode);
  const mappedProviderCode = providerCodeByCountry.get(c.isoCode);

  if (mappedIso && mappedIso !== c.isoCode) {
    throw new Error(`Provider country code ${c.providerCode} is already mapped to ${mappedIso}`);
  }
  if (mappedProviderCode && mappedProviderCode !== c.providerCode) {
    throw new Error(`Country ${c.isoCode} is already mapped from provider code ${mappedProviderCode}`);
  }
}

for (const s of catalog.services) {
  const mappedCode = serviceByProviderCode.get(s.providerCode);
  const mappedProviderCode = providerCodeByService.get(s.code);

  if (mappedCode && mappedCode !== s.code) {
    throw new Error(`Provider service ${s.providerCode} is already mapped to ${mappedCode}`);
  }
  if (mappedProviderCode && mappedProviderCode !== s.providerCode) {
    throw new Error(`Service ${s.code} is already mapped from provider code ${mappedProviderCode}`);
  }
}

let countriesInserted = 0;
let servicesInserted = 0;
let countryMappingsInserted = 0;
let serviceMappingsInserted = 0;

// Insert missing catalog rows only. Existing rows are never updated.
for (const c of catalog.countries) {
  let row = countryByCode.get(c.isoCode);

  if (!row) {
    const { data, error } = await db
      .from("countries")
      .insert({
        code: c.isoCode,
        name: c.name,
        flag: c.flag ?? "",
        active: true,
      })
      .select("id,code,name")
      .single();

    if (error) throw error;
    row = data;
    countryByCode.set(c.isoCode, row);
    countriesInserted++;
  }
}

for (const s of catalog.services) {
  let row = serviceByCode.get(s.code);

  if (!row) {
    const { data, error } = await db
      .from("services")
      .insert({ code: s.code, name: s.name, active: true })
      .select("id,code,name")
      .single();

    if (error) throw error;
    row = data;
    serviceByCode.set(s.code, row);
    servicesInserted++;
  }
}

// Insert only missing provider mappings.
for (const c of catalog.countries) {
  if (countryByProviderCode.get(c.providerCode) === c.isoCode) continue;

  const country = countryByCode.get(c.isoCode);
  if (!country) throw new Error(`Missing country row ${c.isoCode}`);

  const { error } = await db
    .from("provider_country_mappings")
    .insert({
      provider_id: provider.id,
      country_id: country.id,
      provider_code: c.providerCode,
    });

  if (error) throw error;
  countryMappingsInserted++;
}

for (const s of catalog.services) {
  if (serviceByProviderCode.get(s.providerCode) === s.code) continue;

  const service = serviceByCode.get(s.code);
  if (!service) throw new Error(`Missing service row ${s.code}`);

  const { error } = await db
    .from("provider_service_mappings")
    .insert({
      provider_id: provider.id,
      service_id: service.id,
      provider_code: s.providerCode,
    });

  if (error) throw error;
  serviceMappingsInserted++;
}

console.log(JSON.stringify({
  provider: "proxnum",
  providerActive: provider.active,
  catalogCountries: catalog.countries.length,
  catalogServices: catalog.services.length,
  countriesInserted,
  servicesInserted,
  countryMappingsInserted,
  serviceMappingsInserted,
  pricingRulesModified: false,
}, null, 2));
