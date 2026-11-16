import { handler, json, requireUser } from "../_shared/common.ts";
Deno.serve(handler(async (req) => {
  const { admin, userId } = await requireUser(req);
  const [a, w, rules] = await Promise.all([
    admin.from("tnum_activations").select(
      "*,services:tnum_services(name),countries:tnum_countries(name),activation_sms:tnum_activation_sms(*)",
    ).eq("user_id", userId).not(
      "status",
      "in",
      "(completed,expired,cancelled,failed)",
    ).order("created_at", { ascending: false }),
    admin.from("wallets").select("available_balance,held_balance,currency")
      .eq("user_id", userId).single(),
    admin.from("tnum_runtime_config").select("client_poll_seconds").eq("id", true)
      .single(),
  ]);
  if (a.error) throw a.error;
  if (w.error) throw w.error;
  if (rules.error) throw rules.error;
  return json({
    activations: (a.data ?? []).map(publicActivation),
    wallet: {
      available_cents: Math.round(Number(w.data.available_balance) * 100),
      reserved_cents: Math.round(Number(w.data.held_balance) * 100),
      currency: w.data.currency,
    },
    poll_interval_seconds: rules.data.client_poll_seconds,
    server_time: new Date().toISOString(),
  });
}));

function publicActivation(value: Record<string, unknown>) {
  const {
    provider_price_cents: _providerPrice,
    pricing_markup_bps: _markup,
    pricing_fee_cents: _fee,
    accepted_quote_id: _quote,
    ...activation
  } = value;
  return activation;
}

