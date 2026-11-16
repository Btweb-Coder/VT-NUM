import {
  decimalToCents,
  handler,
  json,
  provider,
  readJson,
  requireUser,
} from "../_shared/common.ts";

type Row = Record<string, unknown>;

function customerPriceCents(value: unknown): number {
  const row = Array.isArray(value) ? value[0] as Row | undefined : value as Row | null;
  const cents = Math.round(Number(row?.customer_price) * 100);
  if (!Number.isSafeInteger(cents) || cents <= 0) {
    throw new Error("PRICING_UNAVAILABLE");
  }
  return cents;
}

Deno.serve(handler(async (req) => {
  const { admin, userId } = await requireUser(req);
  const body = await readJson(req);
  const service = body.service_slug;
  const country = body.country_code;
  if (typeof service !== "string" || service.length > 80 ||
      typeof country !== "number" || !Number.isInteger(country) || country < 1) {
    return json({ error: "INVALID_REQUEST" }, 400);
  }

  const tariffResponse = await provider("getTariffs", {
    country,
    filter_service: service,
    lang: "fr",
  }) as Record<string, unknown>;
  const tariffMap = tariffResponse.services as
    | Record<string, Record<string, unknown>>
    | undefined;
  const tariff = Object.entries(tariffMap ?? {}).find(([slug, item]) =>
    String(item.slug ?? slug.replace(/^_/, "")) === service
  )?.[1];
  const available = Number(tariff?.count ?? 0);
  if (!tariff || !Number.isFinite(available) || available <= 0) {
    return json({ error: "PROVIDER_NO_NUMBER" }, 409);
  }

  const providerPriceCents = decimalToCents(tariff.price);
  const { data: price, error: priceError } = await admin.rpc(
    "calculate_activation_customer_price",
    { p_provider_price: providerPriceCents / 100 },
  );
  if (priceError) throw priceError;
  const customerPrice = customerPriceCents(price);
  const expiresAt = new Date(Date.now() + 2 * 60_000).toISOString();

  const { data: quote, error: quoteError } = await admin
    .from("tnum_activation_quotes")
    .insert({
      user_id: userId,
      service_slug: service,
      country_code: country,
      provider_price_cents: providerPriceCents,
      customer_price_cents: customerPrice,
      markup_type: (Array.isArray(price) ? price[0] : price)?.markup_type,
      markup_value: (Array.isArray(price) ? price[0] : price)?.markup_value,
      expires_at: expiresAt,
    })
    .select("id,customer_price_cents,expires_at")
    .single();
  if (quoteError) throw quoteError;

  // Provider prices and raw tariff responses are deliberately omitted.
  return json({ quote });
}));
