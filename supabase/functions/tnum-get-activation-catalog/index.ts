
import {
  handler,
  json,
  provider,
  requireUser,
} from "../_shared/common.ts";

Deno.serve(handler(async (req) => {
  const { admin } = await requireUser(req);

  // Check whether countries already exist.
  const { data: existingCountries, error: countriesCheckError } =
    await admin
      .from("tnum_countries")
      .select("code")
      .limit(1);

  if (countriesCheckError) {
    throw countriesCheckError;
  }

  // Initialize countries and services if the countries table is empty.
  if (!existingCountries?.length) {
    const raw = await provider("getTariffs", {
      lang: "fr",
    }) as Record<string, unknown>;

    console.log("ONLINE SIM RAW:", JSON.stringify(raw));

    const providerCountries = raw.countries as
      | Record<string, Record<string, unknown>>
      | undefined;

    const providerServices = raw.services as
      | Record<string, Record<string, unknown>>
      | undefined;

    console.log(
      "COUNTRIES COUNT:",
      Object.keys(providerCountries ?? {}).length,
    );

    console.log(
      "SERVICES COUNT:",
      Object.keys(providerServices ?? {}).length,
    );

    // Import countries.
    for (const country of Object.values(providerCountries ?? {})) {
      const { error } = await admin
        .from("tnum_countries")
        .upsert({
          code: Number(country.code),
          name: String(country.name),
          original: String(country.original ?? ""),
          enabled: Boolean(country.enable),
        });

      if (error) {
        console.error("COUNTRY UPSERT ERROR:", error);
        throw error;
      }
    }

    // Import services.
    for (const [key, service] of Object.entries(
      providerServices ?? {},
    )) {
      const { error } = await admin
        .from("tnum_services")
        .upsert({
          slug: String(service.slug ?? key.replace(/^_/, "")),
          provider_id: Number(service.id),
          name: String(service.service),
        });

      if (error) {
        console.error("SERVICE UPSERT ERROR:", error);
        throw error;
      }
    }

    console.log("INITIAL CATALOG IMPORT COMPLETED");
  }

  // Retrieve available catalog entries and enabled countries.
  const [catalog, countries] = await Promise.all([
    admin
      .from("tnum_service_country_catalog")
      .select(
        "service_slug,country_code,provider_price,available_count,refreshed_at,services:tnum_services(name),countries:tnum_countries(name,original)",
      )
      .gt("available_count", 0)
      .order("service_slug"),

    admin
      .from("tnum_countries")
      .select("code,name,original,enabled")
      .eq("enabled", true)
      .order("name"),
  ]);

  if (catalog.error) {
    console.error("CATALOG QUERY ERROR:", catalog.error);
    throw catalog.error;
  }

  if (countries.error) {
    console.error("COUNTRIES QUERY ERROR:", countries.error);
    throw countries.error;
  }

  const catalogRows = catalog.data ?? [];
  const providerPrices = catalogRows.map((row) =>
    Math.round(Number(row.provider_price) * 100) / 100
  );
  const { data: pricingRows, error: pricingError } = await admin.rpc(
    "calculate_activation_customer_prices",
    { p_provider_prices: providerPrices },
  );
  if (pricingError) throw pricingError;
  if (!Array.isArray(pricingRows) || pricingRows.length !== catalogRows.length) {
    throw new Error("PRICING_RESPONSE_MISMATCH");
  }
  const customerCatalog = catalogRows.map((row, index) => {
    const rule = pricingRows[index] as Record<string, unknown>;
    return {
      service_slug: row.service_slug,
      country_code: row.country_code,
      available_count: row.available_count,
      refreshed_at: row.refreshed_at,
      customer_price_cents: Math.round(Number(rule?.customer_price) * 100),
      services: row.services,
      countries: row.countries,
    };
  });

  console.log(
    "CATALOG ENTRIES RETURNED:",
    catalog.data?.length ?? 0,
  );

  console.log(
    "ENABLED COUNTRIES RETURNED:",
    countries.data?.length ?? 0,
  );

  return json({
    catalog: customerCatalog,
    countries: countries.data ?? [],
  });
}));

