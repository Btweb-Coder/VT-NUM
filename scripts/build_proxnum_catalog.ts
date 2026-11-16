import * as cheerio from "npm:cheerio@1.0.0";
import isoCountries from "npm:i18n-iso-countries@7.14.0";
import en from "npm:i18n-iso-countries@7.14.0/langs/en.json" with { type: "json" };

isoCountries.registerLocale(en);

const COUNTRY_URL = "https://proxnum.com/docs/countries";
const SERVICE_URL = "https://proxnum.com/docs/services";

const aliases: Record<string, string> = {
  "UK/England": "GB",
  "UK": "GB",
  "USA": "US",
  "United States": "US",
  "D. Congo": "CD",
  "DR Congo": "CD",
  "Congo": "CG",
  "Ivory Coast": "CI",
  "Macao": "MO",
  "UAE": "AE",
  "Reunion": "RE",
  "Réunion": "RE",
  "Saint Vincent": "VC",
  "Taiwan": "TW",
  "Palestine": "PS",
  "South Korea": "KR",
  "North Korea": "KP",
  "Western Sahara": "EH",
  "Kosovo": "XK",
  "Guadeloupe": "GP",
  "French Guiana": "GF",
  "Saint Lucia": "LC",
  "Saint Kitts & Nevis": "KN",
  "Trinidad & Tobago": "TT",
  "Bosnia & Herzegovina": "BA",
  "Antigua and Barbuda": "AG",
  "Sao Tome and Principe": "ST",
  "São Tomé and Príncipe": "ST",
  "New Caledonia": "NC",
  "Cape Verde": "CV",
  "Jersey": "JE",
  "Faroe Islands": "FO",
  "Montserrat": "MS",
  "Anguilla": "AI",
  "Bermuda": "BM",
  "Solomon Islands": "SB",
  "Turks and Caicos Islands": "TC",
  "Timor-Leste": "TL",
  "Laos": "LA",
  "Moldova": "MD",
  "Syria": "SY",
  "Brunei": "BN",
};

function cleanText(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

async function fetchPage(url: string): Promise<string> {
  const response = await fetch(url, {
    headers: {
      Accept: "text/html",
      "User-Agent": "VT-Num-Catalog-Builder/1.0",
    },
  });

  if (!response.ok) {
    throw new Error(`Failed to fetch ${url}: HTTP ${response.status}`);
  }

  return await response.text();
}

function getRows(html: string, kind: "country" | "service") {
  const $ = cheerio.load(html);
  const rows: Array<{ code: string; name: string }> = [];

  $("tr").each((_, element) => {
    const cells = $(element).find("td");
    if (cells.length < 2) return;

    const code = cleanText($(cells[0]).text());
    const nameCell = $(cells[1]).clone();
    nameCell.find("img, button, svg, input").remove();

    let name = cleanText(nameCell.text());

    if (kind === "service") {
      name = name.replace(/^[A-Z]{2}\s+(?=[A-Za-zÀ-ÿ])/u, "");
    }

    if (!code || !name || /^copy$/i.test(name)) return;
    if (kind === "country" && !/^\d+$/.test(code)) return;
    if (kind === "service" && !/^[a-z0-9_-]+$/i.test(code)) return;

    rows.push({ code, name });
  });

  return rows;
}

function resolveIso(name: string): string | null {
  if (aliases[name]) return aliases[name];
  return isoCountries.getAlpha2Code(name, "en") ?? null;
}

const [countryHtml, serviceHtml] = await Promise.all([
  fetchPage(COUNTRY_URL),
  fetchPage(SERVICE_URL),
]);

const countryRows = getRows(countryHtml, "country");
const serviceRows = getRows(serviceHtml, "service");

const countriesByProviderCode = new Map<string, {
  providerCode: string;
  isoCode: string;
  name: string;
  flag: string;
  source: string;
}>();

const servicesByCode = new Map<string, {
  providerCode: string;
  code: string;
  name: string;
  source: string;
}>();

const unresolved: Array<{ providerCode: string; name: string }> = [];
const duplicateIso: Array<{
  isoCode: string;
  first: { providerCode: string; name: string };
  second: { providerCode: string; name: string };
}> = [];

const providerCodesByIso = new Map<
  string,
  { providerCode: string; name: string }
>();

for (const row of countryRows) {
  // Proxnum documents Kosovo twice. Keep code 203 as canonical.
  if (row.code === "204" && row.name === "Kosovo") {
    console.log("Explicitly skipping duplicate Kosovo entry: provider code 204; keeping 203.");
    continue;
  }

  const isoCode = resolveIso(row.name);

  if (!isoCode) {
    unresolved.push({ providerCode: row.code, name: row.name });
    continue;
  }

  const record = {
    providerCode: row.code,
    isoCode,
    name: row.name,
    flag: "",
    source: COUNTRY_URL,
  };

  const previousProviderCode = countriesByProviderCode.get(row.code);
  if (
    previousProviderCode &&
    (previousProviderCode.name !== record.name ||
      previousProviderCode.isoCode !== record.isoCode)
  ) {
    throw new Error(`Conflicting names for provider country code ${row.code}`);
  }

  const previousIso = providerCodesByIso.get(isoCode);
  if (previousIso && previousIso.providerCode !== row.code) {
    duplicateIso.push({
      isoCode,
      first: previousIso,
      second: { providerCode: row.code, name: row.name },
    });
  } else {
    providerCodesByIso.set(isoCode, {
      providerCode: row.code,
      name: row.name,
    });
  }

  countriesByProviderCode.set(row.code, record);
}

for (const row of serviceRows) {
  const record = {
    providerCode: row.code,
    code: row.code,
    name: row.name,
    source: SERVICE_URL,
  };

  const previous = servicesByCode.get(row.code);
  if (previous && previous.name !== record.name) {
    throw new Error(`Conflicting names for service code ${row.code}`);
  }

  servicesByCode.set(row.code, record);
}

console.log("Official Proxnum catalog review");
console.log(`Country rows extracted: ${countryRows.length}`);
console.log(`Unique country IDs: ${countriesByProviderCode.size}`);
console.log(`Service rows extracted: ${serviceRows.length}`);
console.log(`Unique service codes: ${servicesByCode.size}`);
console.log(`Unresolved country names: ${unresolved.length}`);
console.log(`Duplicate ISO mappings: ${duplicateIso.length}`);

if (unresolved.length) {
  console.log("COUNTRIES NEEDING REVIEW:");
  console.log(JSON.stringify(unresolved, null, 2));
}

if (duplicateIso.length) {
  console.log("DUPLICATE ISO MAPPINGS NEEDING REVIEW:");
  console.log(JSON.stringify(duplicateIso, null, 2));
}

if (
  countryRows.length === 0 ||
  serviceRows.length === 0 ||
  unresolved.length > 0 ||
  duplicateIso.length > 0
) {
  throw new Error(
    "Validation failed. No catalog JSON was written. Review the report first.",
  );
}

const catalog = {
  countries: [...countriesByProviderCode.values()],
  services: [...servicesByCode.values()],
};

await Deno.writeTextFile(
  "verified-catalog.json",
  JSON.stringify(catalog, null, 2) + "\n",
);

console.log("Created verified-catalog.json");
console.log("No Supabase data was changed.");
