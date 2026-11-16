
import {
  createClient,
  SupabaseClient,
} from "npm:@supabase/supabase-js@2.57.0";

// --------------------------------------------------
// CORS
// --------------------------------------------------

export const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-correlation-id, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      ...cors,
      "Content-Type": "application/json",
    },
  });

// --------------------------------------------------
// REQUEST BODY
// --------------------------------------------------

export async function readJson(
  req: Request,
  maxBytes = 4096,
): Promise<Record<string, unknown>> {
  const declared = Number(req.headers.get("content-length") ?? 0);

  if (declared > maxBytes) {
    throw new Error("PAYLOAD_TOO_LARGE");
  }

  const text = await req.text();

  if (new TextEncoder().encode(text).length > maxBytes) {
    throw new Error("PAYLOAD_TOO_LARGE");
  }

  let value: unknown;

  try {
    value = JSON.parse(text);
  } catch {
    throw new Error("INVALID_JSON");
  }

  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value)
  ) {
    throw new Error("INVALID_REQUEST");
  }

  return value as Record<string, unknown>;
}

// --------------------------------------------------
// SUPABASE CLIENTS
// --------------------------------------------------

export function clients(
  req: Request,
): {
  admin: SupabaseClient;
  user: SupabaseClient;
} {
  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!url || !anon || !serviceRole) {
    throw new Error("SUPABASE_CONFIGURATION_MISSING");
  }

  const admin = createClient(url, serviceRole, {
    auth: { persistSession: false },
  });

  const token = req.headers
    .get("Authorization")
    ?.replace(/^Bearer\s+/i, "");

  if (!token) {
    throw new Error("AUTH_REQUIRED");
  }

  const user = createClient(url, anon, {
    global: {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    },
    auth: { persistSession: false },
  });

  return { admin, user };
}

// --------------------------------------------------
// AUTHENTICATION
// --------------------------------------------------

export async function requireUser(req: Request) {
  const { admin, user } = clients(req);

  const token = req.headers
    .get("Authorization")
    ?.replace(/^Bearer\s+/i, "");

  const { data, error } = await user.auth.getUser(token);

  if (error || !data.user) {
    throw new Error("AUTH_REQUIRED");
  }

  return {
    admin,
    userId: data.user.id,
  };
}

// --------------------------------------------------
// ONLINE SIM API KEY
// --------------------------------------------------

export function providerKey(): string {
  const key = Deno.env.get("ONLINESIM_API_KEY");

  if (!key || !key.trim()) {
    throw new Error("PROVIDER_API_KEY_MISSING");
  }

  return key.trim();
}

// --------------------------------------------------
// PRICE CONVERSION
// --------------------------------------------------

export function decimalToCents(value: unknown): number {
  const text = String(value);

  if (!/^\d+(\.\d+)?$/.test(text)) {
    throw new Error("PROVIDER_PRICE_INVALID");
  }

  const [whole, fraction = ""] = text.split(".");
  const firstTwo = (fraction + "00").slice(0, 2);
  const roundUp = Number((fraction + "000")[2]) >= 5;

  const cents =
    Number(whole) * 100 +
    Number(firstTwo) +
    (roundUp ? 1 : 0);

  if (!Number.isSafeInteger(cents) || cents <= 0) {
    throw new Error("PROVIDER_PRICE_INVALID");
  }

  return cents;
}

// --------------------------------------------------
// ONLINE SIM PROVIDER
// --------------------------------------------------


function findOperationsByTzid(
  value: unknown,
  targetTzid: string,
  depth = 0,
): Record<string, unknown>[] {
  if (depth > 10 || value === null || typeof value !== 'object') {
    return [];
  }

  if (Array.isArray(value)) {
    return value.flatMap((item) =>
      findOperationsByTzid(item, targetTzid, depth + 1)
    );
  }

  const record = value as Record<string, unknown>;
  const matches: Record<string, unknown>[] = [];

  if (
    record.tzid !== undefined &&
    String(record.tzid) === targetTzid
  ) {
    matches.push(record);
  }

  for (const child of Object.values(record)) {
    if (child !== null && typeof child === 'object') {
      matches.push(
        ...findOperationsByTzid(child, targetTzid, depth + 1),
      );
    }
  }

  return matches;
}

export async function provider(
  method: string,
  params: Record<string, string | number | boolean> = {},
): Promise<unknown> {
  if (!/^[a-zA-Z0-9_]+$/.test(method)) {
    throw new Error("PROVIDER_INVALID_METHOD");
  }

  const key = providerKey();
  const url = new URL(`https://onlinesim.io/api/${method}.php`);

  url.searchParams.set("apikey", key);

  for (const [name, value] of Object.entries(params)) {
    url.searchParams.set(name, String(value));
  }

  const debug = Deno.env.get("TNUM_PROVIDER_DEBUG") === "true";
  const debugTzid = Deno.env.get("TNUM_PROVIDER_DEBUG_TZID") ?? "";
  const requestedTzid = params.tzid === undefined
    ? ""
    : String(params.tzid);

  const targetedDebug =
    debug &&
    method === "getState" &&
    requestedTzid !== "" &&
    (!debugTzid || requestedTzid === debugTzid);

  const startedAt = Date.now();

  if (debug) {
    console.log(JSON.stringify({
      event: "ONLINE_SIM_REQUEST",
      method,
      params,
      targeted_debug: targetedDebug,
      timestamp: new Date().toISOString(),
    }));
  }

  let response: Response;

  try {
    response = await fetch(url, {
      method: "GET",
      signal: AbortSignal.timeout(12000),
      headers: { Accept: "application/json" },
    });
  } catch (error) {
    const reason = error instanceof Error
      ? error.message
      : "Unknown network error";

    console.error(JSON.stringify({
      event: "ONLINE_SIM_NETWORK_ERROR",
      method,
      params,
      duration_ms: Date.now() - startedAt,
      error: reason,
    }));

    if (
      error instanceof DOMException &&
      error.name === "TimeoutError"
    ) {
      throw new Error("PROVIDER_TIMEOUT");
    }

    throw new Error("PROVIDER_NETWORK_ERROR");
  }

  const responseText = await response.text();

  if (debug) {
    console.log(JSON.stringify({
      event: "ONLINE_SIM_HTTP_RESPONSE",
      method,
      http_status: response.status,
      duration_ms: Date.now() - startedAt,
      response_length: responseText.length,
      timestamp: new Date().toISOString(),
    }));
  }

  if (!response.ok) {
    console.error(JSON.stringify({
      event: "ONLINE_SIM_HTTP_ERROR",
      method,
      http_status: response.status,
      response_body: debug
        ? responseText
        : responseText.slice(0, 1000),
    }));

    throw new Error(`PROVIDER_HTTP_${response.status}`);
  }

  let body: unknown;

  try {
    body = JSON.parse(responseText);
  } catch {
    console.error(JSON.stringify({
      event: "ONLINE_SIM_INVALID_JSON",
      method,
      raw_response: debug ? responseText : responseText.slice(0, 1000),
    }));

    throw new Error("PROVIDER_INVALID_RESPONSE");
  }

  // Full diagnostic for a targeted lookup of our test activation.
  if (targetedDebug) {
    console.log(JSON.stringify({
      event: "ONLINE_SIM_TARGETED_RAW_RESPONSE",
      method,
      requested_tzid: requestedTzid,
      http_status: response.status,
      raw_response: responseText,
      parsed_response: body,
      response_code: responseCodeForDebug(body),
      timestamp: new Date().toISOString(),
    }));
  }

  // For a global getState, never dump every customer's SMS.
  // Record only the operation matching our configured test TZID.
  if (debug && method === "getState" && !requestedTzid) {
    const matches = debugTzid
      ? findOperationsByTzid(body, debugTzid)
      : [];

    console.log(JSON.stringify({
      event: "ONLINE_SIM_GLOBAL_STATE_DIAGNOSTIC",
      method,
      target_tzid: debugTzid || null,
      target_found: matches.length > 0,
      matching_operations: matches,
      response_root_type: Array.isArray(body)
        ? "array"
        : typeof body,
      response_code: responseCodeForDebug(body),
      timestamp: new Date().toISOString(),
    }));
  }

  // Capture the complete response from non-getState operations too.
  if (debug && method !== "getState") {
    console.log(JSON.stringify({
      event: "ONLINE_SIM_OPERATION_RESPONSE",
      method,
      params,
      http_status: response.status,
      raw_response: responseText,
      parsed_response: body,
      timestamp: new Date().toISOString(),
    }));
  }

  if (method === "getState") {
    if (
      body &&
      typeof body === "object" &&
      !Array.isArray(body) &&
      "response" in body
    ) {
      const code = String(
        (body as Record<string, unknown>).response,
      );

      if (code === "ERROR_NO_OPERATIONS") {
        console.info("ONLINE SIM: no active operations returned");
      } else {
        console.log("ONLINE SIM GETSTATE STATUS:", code);
      }
    }

    return body;
  }

  if (
    body &&
    typeof body === "object" &&
    !Array.isArray(body) &&
    "response" in body
  ) {
    const code = String(
      (body as Record<string, unknown>).response,
    );

    if (code !== "1" && code !== "true") {
      console.error("ONLINE SIM API ERROR:", code);
      throw new Error(`PROVIDER_${code}`);
    }
  }

  return body;
}

function responseCodeForDebug(value: unknown): string {
  if (
    value &&
    typeof value === "object" &&
    !Array.isArray(value)
  ) {
    return String(
      (value as Record<string, unknown>).response ?? "",
    );
  }

  return "";
}


// --------------------------------------------------
// ERROR HANDLING
// --------------------------------------------------

export function fail(req: Request, error: unknown) {
  const id =
    req.headers.get("x-correlation-id") ??
    crypto.randomUUID();

  const name =
    error instanceof Error
      ? error.message
      : "INTERNAL_ERROR";

  console.error(JSON.stringify({
    correlation_id: id,
    error: name,
  }));

  if (name === "AUTH_REQUIRED") {
    return json({ error: name, correlation_id: id }, 401);
  }

  const publicProviderErrors = new Set([
    "PROVIDER_NO_NUMBER",
    "PROVIDER_WARNING_LOW_BALANCE",
    "PROVIDER_ACCOUNT_BLOCKED",
    "PROVIDER_API_ACCESS_DISABLED",
    "PROVIDER_API_ACCESS_IP",
    "PROVIDER_ERROR_WRONG_KEY",
    "PROVIDER_ERROR_NO_KEY",
    "PROVIDER_ERROR_NO_SERVICE",
    "PROVIDER_UNDEFINED_COUNTRY",
    "PROVIDER_INTERVAL_CONCURRENT_REQUESTS_ERROR",
    "PROVIDER_REQUEST_NOT_FOUND",
  ]);

  const safeErrors = new Set([
    "PROVIDER_API_KEY_MISSING",
    "PROVIDER_TIMEOUT",
    "PROVIDER_NETWORK_ERROR",
    "PROVIDER_INVALID_RESPONSE",
    "PROVIDER_INVALID_METHOD",
  ]);

  let safeError = name;
  let status = 400;

  if (publicProviderErrors.has(name)) {
    status = 400;
  } else if (safeErrors.has(name)) {
    status = 503;
  } else if (name.startsWith("PROVIDER_HTTP_")) {
    safeError = "PROVIDER_UNAVAILABLE";
    status = 503;
  } else if (name.startsWith("PROVIDER_")) {
    safeError = "PROVIDER_UNAVAILABLE";
    status = 503;
  } else if (
    name === "CATALOG_UNAVAILABLE" ||
    name === "SUPABASE_CONFIGURATION_MISSING"
  ) {
    status = 503;
  } else if (name === "PAYLOAD_TOO_LARGE") {
    status = 413;
  } else if (
    name === "INVALID_JSON" ||
    name === "INVALID_REQUEST"
  ) {
    status = 400;
  }

  return json({
    error: safeError,
    correlation_id: id,
  }, status);
}

// --------------------------------------------------
// EDGE FUNCTION HANDLER
// --------------------------------------------------

export function handler(
  fn: (req: Request) => Promise<Response>,
) {
  return (req: Request) =>
    req.method === "OPTIONS"
      ? new Response("ok", { headers: cors })
      : fn(req).catch((error) => fail(req, error));
}

// provider()