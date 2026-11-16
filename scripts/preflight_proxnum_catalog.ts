
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

type Catalog = {
  countries: Country[];
  services: Service[];
};

const file = Deno.args.find((arg) => !arg.startsWith("--"));
if (!file) {
  throw new Error(
    "Usage: deno run --allow-env --allow-read --allow-net scripts/preflight_proxnum_catalog.ts verified-catalog.json",
  );
}

const url = Deno.env.get("SUPABASE_URL");
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!url || !key) {
  throw new Error(
    "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required.",
  );
}

const catalog = JSON.parse(
  await Deno.readTextFile(file),
) as Catalog;

if (
  !Array.isArray(catalog.countries) ||
  !Array.isArray(catalog.services)
) {
  throw new Error(
    "Invalid catalog: countries and services must be arrays.",
  );
}

function assertUnique(values: string[], label: string) {
  if (new Set(values).size !== values.length) {
    throw new Error(`Duplicate ${label}; preflight aborted.`);
  }
}

assertUnique(
  catalog.countries.map((c) => c.providerCode),
  "country provider code",
);
assertUnique(
  catalog.countries.map((c) => c.isoCode),
  "country ISO code",
);
assertUnique(
  catalog.services.map((s) => s.providerCode),
  "service provider code",
);
assertUnique(
  catalog.services.map((s) => s.code),
  "service application code",
);

for (const c of catalog.countries) {
  if (
    !/^\d+$/.test(c.providerCode) ||
    !/^[A-Z]{2}$/.test(c.isoCode) ||
    !c.name?.trim() ||
    !c.source?.trim()
  ) {
    throw new Error(
      `Invalid country record: ${JSON.stringify(c)}`,
    );
  }
}

for (const s of catalog.services) {
  if (
    !s.providerCode?.trim() ||
    !s.code?.trim() ||
    !s.name?.trim() ||
    !s.source?.trim()
  ) {
    throw new Error(
      `Invalid service record: ${JSON.stringify(s)}`,
    );
  }
}

const db = createClient(url, key, {
  auth: { persistSession: false },
});

async function readAll<T>(
  table: string,
  columns: string,
  filters: Array<[string, string]> = [],
): Promise<T[]> {
  const rows: T[] = [];
  const pageSize = 500;

  for (let from = 0; ; from += pageSize) {
    let query = db
      .from(table)
      .select(columns)
      .range(from, from + pageSize - 1);

    for (const [column, value] of filters) {
      query = query.eq(column, value);
    }

    const { data, error } = await query;

    if (error) {
      throw new Error(
        `Read ${table} failed: ${error.message}`,
      );
    }

    const page = (data ?? []) as T[];
    rows.push(...page);

    if (page.length < pageSize) break;
  }

  return rows;
}

type Provider = { id: string; active: boolean };
type CountryRow = { id: string; code: string; name: string };
type ServiceRow = { id: string; code: string; name: string };
type CountryMapping = {
  country_id: string;
  provider_code: string;
};
type ServiceMapping = {
  service_id: string;
  provider_code: string;
};

const { data: provider, error: providerError } = await db
  .from("providers")
  .select("id,active")
  .eq("slug", "proxnum")
  .single();

if (providerError || !provider) {
  throw new Error(
    `Cannot verify Proxnum provider: ${
      providerError?.message ?? "not found"
    }`,
  );
}

if (provider.active !== false) {
  throw new Error(
    `Safety stop: Proxnum is active (${provider.active}). No writes were made.`,
  );
}

const [
  countries,
  services,
  countryMappings,
  serviceMappings,
] = await Promise.all([
  readAll<CountryRow>("countries", "id,code,name"),
  readAll<ServiceRow>("services", "id,code,name"),
  readAll<CountryMapping>(
    "provider_country_mappings",
    "country_id,provider_code",
    [["provider_id", provider.id]],
  ),
  readAll<ServiceMapping>(
    "provider_service_mappings",
    "service_id,provider_code",
    [["provider_id", provider.id]],
  ),
]);

const countryByCode = new Map(
  countries.map((row) => [row.code, row]),
);
const serviceByCode = new Map(
  services.map((row) => [row.code, row]),
);
const countryCodeById = new Map(
  countries.map((row) => [row.id, row.code]),
);
const serviceCodeById = new Map(
  services.map((row) => [row.id, row.code]),
);

const countryProviderToIso = new Map<string, string>();
const countryIsoToProvider = new Map<string, string>();

for (const m of countryMappings) {
  const iso = countryCodeById.get(m.country_id);

  if (!iso) {
    throw new Error(
      `Country mapping references missing country: ${m.country_id}`,
    );
  }

  const previousIso = countryProviderToIso.get(m.provider_code);
  const previousProvider = countryIsoToProvider.get(iso);

  if (previousIso && previousIso !== iso) {
    throw new Error(
      `Conflicting country mapping for provider code ${m.provider_code}`,
    );
  }

  if (previousProvider && previousProvider !== m.provider_code) {
    throw new Error(
      `Conflicting provider codes for country ${iso}`,
    );
  }

  countryProviderToIso.set(m.provider_code, iso);
  countryIsoToProvider.set(iso, m.provider_code);
}

const serviceProviderToCode = new Map<string, string>();
const serviceCodeToProvider = new Map<string, string>();

for (const m of serviceMappings) {
  const code = serviceCodeById.get(m.service_id);

  if (!code) {
    throw new Error(
      `Service mapping references missing service: ${m.service_id}`,
    );
  }

  const previousCode = serviceProviderToCode.get(m.provider_code);
  const previousProvider = serviceCodeToProvider.get(code);

  if (previousCode && previousCode !== code) {
    throw new Error(
      `Conflicting service mapping for provider code ${m.provider_code}`,
    );
  }

  if (previousProvider && previousProvider !== m.provider_code) {
    throw new Error(
      `Conflicting provider codes for service ${code}`,
    );
  }

  serviceProviderToCode.set(m.provider_code, code);
  serviceCodeToProvider.set(code, m.provider_code);
}

let countriesToInsert = 0;
let servicesToInsert = 0;
let countryMappingsToInsert = 0;
let serviceMappingsToInsert = 0;

for (const c of catalog.countries) {
  const old = countryByCode.get(c.isoCode);

  if (old && old.name !== c.name) {
    throw new Error(
      `Country name conflict for ${c.isoCode}: database="${old.name}", catalog="${c.name}"`,
    );
  }

  const mappedIso = countryProviderToIso.get(c.providerCode);
  const mappedProvider = countryIsoToProvider.get(c.isoCode);

  if (mappedIso && mappedIso !== c.isoCode) {
    throw new Error(
      `Provider country code ${c.providerCode} already maps to ${mappedIso}`,
    );
  }

  if (mappedProvider && mappedProvider !== c.providerCode) {
    throw new Error(
      `Country ${c.isoCode} already maps from provider code ${mappedProvider}`,
    );
  }

  if (!old) countriesToInsert++;

  if (!mappedIso && !mappedProvider) {
    countryMappingsToInsert++;
  }
}

for (const s of catalog.services) {
  const old = serviceByCode.get(s.code);

  if (old && old.name !== s.name) {
    throw new Error(
      `Service name conflict for ${s.code}: database="${old.name}", catalog="${s.name}"`,
    );
  }

  const mappedCode = serviceProviderToCode.get(s.providerCode);
  const mappedProvider = serviceCodeToProvider.get(s.code);

  if (mappedCode && mappedCode !== s.code) {
    throw new Error(
      `Provider service ${s.providerCode} already maps to ${mappedCode}`,
    );
  }

  if (mappedProvider && mappedProvider !== s.providerCode) {
    throw new Error(
      `Service ${s.code} already maps from provider code ${mappedProvider}`,
    );
  }

  if (!old) servicesToInsert++;

  if (!mappedCode && !mappedProvider) {
    serviceMappingsToInsert++;
  }
}

console.log(
  JSON.stringify(
    {
      mode: "READ-ONLY PREFLIGHT",
      writesPerformed: false,
      provider: "proxnum",
      providerActive: provider.active,
      catalogCountries: catalog.countries.length,
      catalogServices: catalog.services.length,
      databaseCountries: countries.length,
      databaseServices: services.length,
      existingProviderCountryMappings: countryMappings.length,
      existingProviderServiceMappings: serviceMappings.length,
      countriesToInsert,
      servicesToInsert,
      countryMappingsToInsert,
      serviceMappingsToInsert,
      pricingRulesModified: false,
    },
    null,
    2,
  ),
);
