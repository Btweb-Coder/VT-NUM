
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
type DbRow = { id: string; code: string; name: string; flag?: string };
type Mapping = { country_id?: string; service_id?: string; provider_code: string };

const args = Deno.args;
const apply = args.includes("--apply");
const file = args.find((arg) => !arg.startsWith("--"));

if (!file) throw new Error("Usage: deno run ... sync_proxnum_catalog.safe.ts verified-catalog.json [--apply]");

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
  if (values.some((value) => !value.trim()) ||
      new Set(values).size !== values.length) {
    throw new Error(`Blank or duplicate ${label}; import aborted`);
  }
}

assertUnique(catalog.countries.map((x) => x.providerCode), "country provider code");
assertUnique(catalog.countries.map((x) => x.isoCode), "country ISO code");
assertUnique(catalog.services.map((x) => x.providerCode), "service provider code");
assertUnique(catalog.services.map((x) => x.code), "service application code");

for (const c of catalog.countries) {
  if (!/^\d+$/.test(c.providerCode) ||
      !/^[A-Z]{2}$/.test(c.isoCode) ||
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

const db = createClient(url, key, {
  auth: { persistSession: false },
});

const BATCH_SIZE = 100;
const PAGE_SIZE = 500;

// Read complete tables in stable, bounded pages.

async function readAll<T>(
  fetchPage: (from: number, to: number) => PromiseLike<{
    data: T[] | null;
    error: { message: string } | null;
  }>,
  label: string,
): Promise<T[]> {
  const rows: T[] = [];

  for (let from = 0; ; from += PAGE_SIZE) {
    const { data, error } = await fetchPage(from, from + PAGE_SIZE - 1);

    if (error) {
      throw new Error(`Reading ${label} failed: ${error.message}`);
    }

    const page = data ?? [];
    rows.push(...page);

    if (page.length < PAGE_SIZE) break;
  }

  return rows;
}


async function readCountries() {
  return await readAll<DbRow>(
    (from, to) => db.from("countries")
      .select("id,code,name,flag")
      .order("code")
      .range(from, to),
    "countries",
  );
}

async function readServices() {
  return await readAll<DbRow>(
    (from, to) => db.from("services")
      .select("id,code,name")
      .order("code")
      .range(from, to),
    "services",
  );
}


const { data: providerData, error: providerError } = await db
  .from("providers")
  .select("id, active")
  .eq("slug", "proxnum")
  .maybeSingle();

if (providerError) {
  throw new Error(`Proxnum lookup failed: ${providerError.message}`);
}

if (!providerData) {
  throw new Error("Proxnum provider not registered");
}

const provider = providerData;

if (provider.active !== false) {
  throw new Error(
    "Safety stop: Proxnum must remain inactive during catalog import.",
  );
}


let countries = await readCountries();
let services = await readServices();

const countryByCode = new Map(countries.map((row) => [row.code, row]));
const serviceByCode = new Map(services.map((row) => [row.code, row]));

function validateNames() {
  for (const c of catalog.countries) {
    const old = countryByCode.get(c.isoCode);
    if (old && old.name !== c.name) {
      throw new Error(
        `Country conflict ${c.isoCode}: database="${old.name}", catalog="${c.name}"`,
      );
    }
  }

  for (const s of catalog.services) {
    const old = serviceByCode.get(s.code);
    if (old && old.name !== s.name) {
      throw new Error(
        `Service conflict ${s.code}: database="${old.name}", catalog="${s.name}"`,
      );
    }
  }
}

validateNames();

async function readCountryMappings(): Promise<Mapping[]> {
  return await readAll<Mapping>(
    (from, to) => db.from("provider_country_mappings")
      .select("country_id,provider_code")
      .eq("provider_id", provider.id)
      .order("provider_code")
      .range(from, to),
    "Proxnum country mappings",
  );
}

async function readServiceMappings(): Promise<Mapping[]> {
  return await readAll<Mapping>(
    (from, to) => db.from("provider_service_mappings")
      .select("service_id,provider_code")
      .eq("provider_id", provider.id)
      .order("provider_code")
      .range(from, to),
    "Proxnum service mappings",
  );
}

function validateMappings(
  mappings: Mapping[],
  catalogRows: Array<{ providerCode: string; appCode: string }>,
  idToCode: Map<string, string>,
  label: string,
) {
  const byProvider = new Map<string, string>();
  const byAppCode = new Map<string, string>();

  for (const mapping of mappings) {
    const id = label === "country"
      ? mapping.country_id
      : mapping.service_id;
    const appCode = id ? idToCode.get(id) : undefined;

    if (!appCode) {
      throw new Error(
        `Safety stop: ${label} mapping ${mapping.provider_code} points to a missing record.`,
      );
    }

    if (byProvider.has(mapping.provider_code) &&
        byProvider.get(mapping.provider_code) !== appCode) {
      throw new Error(`Conflicting ${label} mappings for ${mapping.provider_code}`);
    }

    if (byAppCode.has(appCode) &&
        byAppCode.get(appCode) !== mapping.provider_code) {
      throw new Error(`Conflicting ${label} mappings for ${appCode}`);
    }

    byProvider.set(mapping.provider_code, appCode);
    byAppCode.set(appCode, mapping.provider_code);
  }

  for (const item of catalogRows) {
    const mappedCode = byProvider.get(item.providerCode);
    const mappedProvider = byAppCode.get(item.appCode);

    if (mappedCode && mappedCode !== item.appCode) {
      throw new Error(
        `${label} provider code ${item.providerCode} already maps to ${mappedCode}`,
      );
    }

    if (mappedProvider && mappedProvider !== item.providerCode) {
      throw new Error(
        `${label} ${item.appCode} already maps from ${mappedProvider}`,
      );
    }
  }

  return { byProvider, byAppCode };
}

let countryMappings = await readCountryMappings();
let serviceMappings = await readServiceMappings();

function countryIdToCode(rows: DbRow[]) {
  return new Map(rows.map((row) => [row.id, row.code]));
}

function serviceIdToCode(rows: DbRow[]) {
  return new Map(rows.map((row) => [row.id, row.code]));
}

let countryMap = validateMappings(
  countryMappings,
  catalog.countries.map((c) => ({
    providerCode: c.providerCode,
    appCode: c.isoCode,
  })),
  countryIdToCode(countries),
  "country",
);

let serviceMap = validateMappings(
  serviceMappings,
  catalog.services.map((s) => ({
    providerCode: s.providerCode,
    appCode: s.code,
  })),
  serviceIdToCode(services),
  "service",
);

const plannedCountries = catalog.countries.filter(
  (c) => !countryByCode.has(c.isoCode),
);
const plannedServices = catalog.services.filter(
  (s) => !serviceByCode.has(s.code),
);
const plannedCountryMappings = catalog.countries.filter(
  (c) => !countryMap.byProvider.has(c.providerCode),
);
const plannedServiceMappings = catalog.services.filter(
  (s) => !serviceMap.byProvider.has(s.providerCode),
);

console.log(JSON.stringify({
  mode: apply ? "APPLY" : "DRY RUN",
  writesEnabled: apply,
  provider: "proxnum",
  providerActiveBefore: provider.active,
  catalogCountries: catalog.countries.length,
  catalogServices: catalog.services.length,
  databaseCountriesBefore: countries.length,
  databaseServicesBefore: services.length,
  existingCountryMappings: countryMappings.length,
  existingServiceMappings: serviceMappings.length,
  countriesToInsert: plannedCountries.length,
  servicesToInsert: plannedServices.length,
  countryMappingsToInsert: plannedCountryMappings.length,
  serviceMappingsToInsert: plannedServiceMappings.length,
  pricingRulesModified: false,
}, null, 2));

if (!apply) {
  console.log("Dry run complete. No database writes performed.");
  Deno.exit(0);
}

let countriesInserted = 0;
let servicesInserted = 0;
let countryMappingsInserted = 0;
let serviceMappingsInserted = 0;

async function insertBatches(
  table: string,
  rows: Record<string, unknown>[],
) {
  for (let i = 0; i < rows.length; i += BATCH_SIZE) {
    const batch = rows.slice(i, i + BATCH_SIZE);
    const { error } = await db.from(table).insert(batch);
    if (error) {
      throw new Error(
        `Insert into ${table} failed at batch ${Math.floor(i / BATCH_SIZE) + 1}: ${error.message}. Rerun the dry-run before retrying.`,
      );
    }
  }
}

// Insert catalog records in batches. Never update existing rows.
await insertBatches(
  "countries",
  plannedCountries.map((c) => ({
    code: c.isoCode,
    name: c.name,
    flag: c.flag ?? "",
    active: true,
  })),
);
countriesInserted = plannedCountries.length;

await insertBatches(
  "services",
  plannedServices.map((s) => ({
    code: s.code,
    name: s.name,
    active: true,
  })),
);
servicesInserted = plannedServices.length;

// Re-read records so mapping rows use real database IDs,
// including records created before a previous partial failure.
countries = await readCountries();
services = await readServices();

const countryIdByCode = new Map(countries.map((row) => [row.code, row.id]));
const serviceIdByCode = new Map(services.map((row) => [row.code, row.id]));

for (const c of catalog.countries) {
  if (!countryIdByCode.has(c.isoCode)) {
    throw new Error(`Verification stop: country ${c.isoCode} is missing`);
  }
}

for (const s of catalog.services) {
  if (!serviceIdByCode.has(s.code)) {
    throw new Error(`Verification stop: service ${s.code} is missing`);
  }
}

// Re-read mappings before inserting, so an interrupted earlier run
// can be resumed without deliberately duplicating existing mappings.
countryMappings = await readCountryMappings();
serviceMappings = await readServiceMappings();

countryMap = validateMappings(
  countryMappings,
  catalog.countries.map((c) => ({
    providerCode: c.providerCode,
    appCode: c.isoCode,
  })),
  countryIdToCode(countries),
  "country",
);

serviceMap = validateMappings(
  serviceMappings,
  catalog.services.map((s) => ({
    providerCode: s.providerCode,
    appCode: s.code,
  })),
  serviceIdToCode(services),
  "service",
);

const countryRows = catalog.countries
  .filter((c) => !countryMap.byProvider.has(c.providerCode))
  .map((c) => ({
    provider_id: provider.id,
    country_id: countryIdByCode.get(c.isoCode)!,
    provider_code: c.providerCode,
  }));

const serviceRows = catalog.services
  .filter((s) => !serviceMap.byProvider.has(s.providerCode))
  .map((s) => ({
    provider_id: provider.id,
    service_id: serviceIdByCode.get(s.code)!,
    provider_code: s.providerCode,
  }));

await insertBatches("provider_country_mappings", countryRows);
countryMappingsInserted = countryRows.length;

await insertBatches("provider_service_mappings", serviceRows);
serviceMappingsInserted = serviceRows.length;

// Final verification: exact catalog mappings must exist.
const finalCountries = await readCountries();
const finalServices = await readServices();
const finalCountryMappings = await readCountryMappings();
const finalServiceMappings = await readServiceMappings();

const finalCountryById = countryIdToCode(finalCountries);
const finalServiceById = serviceIdToCode(finalServices);

const finalCountryMap = validateMappings(
  finalCountryMappings,
  catalog.countries.map((c) => ({
    providerCode: c.providerCode,
    appCode: c.isoCode,
  })),
  finalCountryById,
  "country",
);

const finalServiceMap = validateMappings(
  finalServiceMappings,
  catalog.services.map((s) => ({
    providerCode: s.providerCode,
    appCode: s.code,
  })),
  finalServiceById,
  "service",
);

for (const c of catalog.countries) {
  if (finalCountryMap.byProvider.get(c.providerCode) !== c.isoCode) {
    throw new Error(`Final verification failed for country ${c.isoCode}`);
  }
}

for (const s of catalog.services) {
  if (finalServiceMap.byProvider.get(s.providerCode) !== s.code) {
    throw new Error(`Final verification failed for service ${s.code}`);
  }
}

const { data: providerAfter, error: providerAfterError } = await db
  .from("providers")
  .select("active")
  .eq("id", provider.id)
  .single();

if (providerAfterError) throw providerAfterError;

if (providerAfter.active !== false) {
  throw new Error("Safety verification failed: Proxnum is no longer inactive.");
}

console.log(JSON.stringify({
  mode: "APPLY COMPLETE — VERIFIED",
  provider: "proxnum",
  providerActiveAfter: providerAfter.active,
  countriesInserted,
  servicesInserted,
  countryMappingsInserted,
  serviceMappingsInserted,
  finalDatabaseCountries: finalCountries.length,
  finalDatabaseServices: finalServices.length,
  verifiedCountryMappings: finalCountryMap.byProvider.size,
  verifiedServiceMappings: finalServiceMap.byProvider.size,
  pricingRulesModified: false,
}, null, 2));
