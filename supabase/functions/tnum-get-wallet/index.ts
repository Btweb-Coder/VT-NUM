import { handler, json, requireUser } from "../_shared/common.ts";
Deno.serve(handler(async (req) => {
  const { admin, userId } = await requireUser(req);
  const { data, error } = await admin.from("wallets").select(
    "available_balance,held_balance,currency",
  ).eq("user_id", userId).single();
  if (error) throw error;
  return json({ wallet: {
    available_cents: Math.round(Number(data.available_balance) * 100),
    reserved_cents: Math.round(Number(data.held_balance) * 100),
    currency: data.currency,
  } });
}));

