import {
  handler,
  json,
  provider,
  readJson,
  requireUser,
} from "../_shared/common.ts";

Deno.serve(handler(async (req) => {
  const { admin } = await requireUser(req);
  const body = await readJson(req);
  const countryCode = Number(body.country_code);
  if (!Number.isInteger(countryCode) || countryCode < 1) {
    return json({ error: "COUNTRY_REQUIRED" }, 400);
  }
  const { data: cached } = await admin.from("tnum_service_country_catalog")
    .select("refreshed_at").eq("country_code", countryCode)
    .gte("refreshed_at", new Date(Date.now() - 5 * 60_000).toISOString()).limit(
      1,
    );
  if (cached?.length) return json({ refreshed: false, cached: true });

  const raw = await provider("getTariffs", {
    country: countryCode,
    lang: "fr",
  }) as Record<string, unknown>;
  const countryMap = raw.countries as
    | Record<string, Record<string, unknown>>
    | undefined;
  const foundCountry = Object.values(countryMap ?? {}).find((row) =>
    Number(row.code) === countryCode
  );
  if (!foundCountry) {
    return json({ error: "COUNTRY_NOT_IN_PROVIDER_CATALOG" }, 404);
  }
  await admin.from("tnum_countries").upsert({
    code: countryCode,
    name: String(foundCountry.name),
    original: String(foundCountry.original ?? ""),
    enabled: Boolean(foundCountry.enable),
    refreshed_at: new Date().toISOString(),
  });
  const services = raw.services as
    | Record<string, Record<string, unknown>>
    | undefined;
  for (const [key, service] of Object.entries(services ?? {})) {
    const slug = String(service.slug ?? key.replace(/^_/, ""));
    const price = Number(service.price);
    const available = Number(service.count ?? 0);
    if (!Number.isFinite(price) || price <= 0 || !Number.isFinite(available)) {
      continue;
    }
    await admin.from("tnum_services").upsert({
      slug,
      provider_id: Number(service.id),
      name: String(service.service),
      refreshed_at: new Date().toISOString(),
    });
    await admin.from("tnum_service_country_catalog").upsert({
      service_slug: slug,
      country_code: countryCode,
      provider_price: price,
      available_count: Math.max(0, Math.trunc(available)),
      refreshed_at: new Date().toISOString(),
    });
  }
  return json({
    refreshed: true,
    country_code: countryCode,
    services: Object.keys(services ?? {}).length,
  });
}));

