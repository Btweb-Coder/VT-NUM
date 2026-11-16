import { handler, json, requireUser } from "../_shared/common.ts";
Deno.serve(handler(async (req) => {
  const { admin, userId } = await requireUser(req);
  const { data, error } = await admin.from("tnum_activations").select(
    "*,services:tnum_services(name),countries:tnum_countries(name),activation_sms:tnum_activation_sms(*)",
  ).eq("user_id", userId).in("status", [
    "completed",
    "expired",
    "cancelled",
    "failed",
  ]).order("created_at", { ascending: false }).limit(200);
  if (error) throw error;
  return json({ activations: (data ?? []).map(publicActivation) });
}));

function publicActivation(value: Record<string, unknown>) {
  const { provider_price_cents: _providerPrice,
    pricing_markup_bps: _markup, pricing_fee_cents: _fee,
    accepted_quote_id: _quote, ...activation } = value;
  return activation;
}

