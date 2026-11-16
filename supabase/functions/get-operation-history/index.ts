import { handler, json, readJson, requireUser } from "../_shared/common.ts";

const terminalTnum = ["completed", "expired", "cancelled", "failed"];
const activeVt = ["PROVIDER_REQUESTING", "WAITING_FOR_SMS", "SMS_RECEIVED", "EXPIRING", "CANCELLING", "REPLACING"];
const terminalVt = ["COMPLETED", "EXPIRED", "CANCELLED", "FAILED"];

Deno.serve(handler(async (req) => {
  const { admin, userId } = await requireUser(req);
  const body = await readJson(req);
  const activeOnly = body.active_only === true;

  let vtQuery = admin.from("orders").select(
    "id,service_name,service_code,country_name,country_code,country_flag,phone_number,code,status,customer_price,currency,expires_at,created_at,completed_at",
  ).eq("user_id", userId).order("created_at", { ascending: false }).limit(200);
  let tnumQuery = admin.from("tnum_activations").select(
    "id,service_slug,country_code,phone_number,status,customer_price_cents,deadline_at,created_at,completed_at,services:tnum_services(name),countries:tnum_countries(name,original),activation_sms:tnum_activation_sms(code,message_text,received_at)",
  ).eq("user_id", userId).order("created_at", { ascending: false }).limit(200);

  if (activeOnly) {
    vtQuery = vtQuery.in("status", activeVt);
    tnumQuery = tnumQuery.not("status", "in", `(${terminalTnum.join(",")})`);
  } else {
    vtQuery = vtQuery.not("status", "in", `(${terminalVt.join(",")})`);
  }

  const [{ data: vtRows, error: vtError }, { data: tnumRows, error: tnumError }] =
    await Promise.all([vtQuery, tnumQuery]);
  if (vtError) throw vtError;
  if (tnumError) throw tnumError;

  const vt = (vtRows ?? []).map((row) => ({
    origin: "VT-NUM",
    source_id: row.id,
    id: row.id,
    service: row.service_name ?? row.service_code ?? "",
    country: row.country_name ?? row.country_code ?? "",
    country_flag: row.country_flag ?? "",
    phone_number: row.phone_number,
    code: row.code,
    status: row.status,
    customer_price: row.customer_price,
    currency: row.currency ?? "USD",
    created_at: row.created_at,
    expires_at: row.expires_at,
    completed_at: row.completed_at,
  }));
  const tnum = (tnumRows ?? []).map((row) => {
    const service = Array.isArray(row.services) ? row.services[0] : row.services;
    const country = Array.isArray(row.countries) ? row.countries[0] : row.countries;
    return {
      origin: "T-NUM",
      source_id: row.id,
      id: row.id,
      service: service?.name ?? row.service_slug,
      country: country?.name ?? String(row.country_code),
      country_flag: "",
      phone_number: row.phone_number,
      code: (row.activation_sms as Array<Record<string, unknown>> | null)?.[0]?.code ?? null,
      status: row.status,
      customer_price: Number(row.customer_price_cents) / 100,
      currency: "USD",
      created_at: row.created_at,
      expires_at: row.deadline_at,
      completed_at: row.completed_at,
    };
  });

  const operations = [...vt, ...tnum].sort((left, right) =>
    Date.parse(String(right.created_at)) - Date.parse(String(left.created_at))
  );
  return json({ operations });
}));
