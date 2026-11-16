import {
  decimalToCents,
  handler,
  json,
  provider,
  readJson,
  requireUser,
} from "../_shared/common.ts";

Deno.serve(handler(async (req) => {
  const { admin, userId } = await requireUser(req);
  const body = await readJson(req);
  const { service_slug: service, country_code: country, idempotency_key: key,
    quote_id: quoteId } = body;
  if (
    typeof service !== "string" || service.length > 80 ||
    typeof country !== "number" || !Number.isInteger(country) ||
    typeof key !== "string" ||
    typeof quoteId !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(key)
  ) {
    return json({ error: "INVALID_REQUEST" }, 400);
  }
  const { data: existing, error: existingError } = await admin.from(
    "tnum_activations",
  )
    .select("*").eq("user_id", userId).eq("idempotency_key", key).maybeSingle();
  if (existingError) throw existingError;
  if (existing) {
    return json(
      { activation: publicActivation(existing), idempotent_replay: true },
      existing.status === "provider_outcome_uncertain" ? 202 : 200,
    );
  }
  const { data: unresolved, error: uncertainError } = await admin.from(
    "tnum_activations",
  )
    .select("id,status,provider_requested_at,provider_operation_id")
    .eq("user_id", userId)
    .in("status", ["provider_outcome_uncertain", "purchase_pending"]);
  if (uncertainError) throw uncertainError;
  if (
    unresolved?.some((row) =>
      row.status === "provider_outcome_uncertain" ||
      (row.provider_requested_at && !row.provider_operation_id)
    )
  ) {
    return json({ error: "PENDING_PROVIDER_OPERATION" }, 409);
  }
  const { data: quoteSlot, error: slotError } = await admin.rpc(
    "tnum_claim_purchase_quote",
    { p_user: userId },
  );
  if (slotError) throw slotError;
  if (quoteSlot !== true) return json({ error: "REQUEST_RATE_LIMIT" }, 429);

  const { data: quote, error: quoteError } = await admin
    .from("tnum_activation_quotes")
    .select("id,user_id,service_slug,country_code,provider_price_cents,customer_price_cents,expires_at,consumed_at")
    .eq("id", quoteId)
    .eq("user_id", userId)
    .eq("service_slug", service)
    .eq("country_code", country)
    .maybeSingle();
  if (quoteError) throw quoteError;
  if (!quote || quote.consumed_at || Date.parse(quote.expires_at) <= Date.now()) {
    return json({ error: "QUOTE_EXPIRED" }, 409);
  }

  // Recheck provider tariff and the shared VT-NUM pricing rule before holding funds.
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
    throw new Error("PROVIDER_NO_NUMBER");
  }
  const providerCents = decimalToCents(tariff.price);
  const { data: pricing, error: pricingError } = await admin.rpc(
    "calculate_activation_customer_price",
    { p_provider_price: providerCents / 100 },
  );
  if (pricingError) throw pricingError;
  const rule = Array.isArray(pricing) ? pricing[0] : pricing;
  const customerCents = Math.round(Number(rule?.customer_price) * 100);
  if (!Number.isSafeInteger(customerCents) || customerCents <= 0) {
    throw new Error("PRICING_UNAVAILABLE");
  }
  if (quote.provider_price_cents !== providerCents ||
      quote.customer_price_cents !== customerCents) {
    const expiresAt = new Date(Date.now() + 2 * 60_000).toISOString();
    const { data: replacementQuote, error: replacementError } = await admin
      .from("tnum_activation_quotes")
      .insert({
        user_id: userId,
        service_slug: service,
        country_code: country,
        provider_price_cents: providerCents,
        customer_price_cents: customerCents,
        markup_type: rule.markup_type,
        markup_value: rule.markup_value,
        expires_at: expiresAt,
      })
      .select("id,customer_price_cents,expires_at")
      .single();
    if (replacementError) throw replacementError;
    return json({ error: "PRICE_CHANGED", quote: replacementQuote }, 409);
  }
  const { error: upsertError } = await admin.from("tnum_service_country_catalog").upsert({
    service_slug: service,
    country_code: country,
    provider_price: String(tariff.price),
    available_count: Math.max(0, Math.trunc(available)),
    refreshed_at: new Date().toISOString(),
  });
  if (upsertError) throw upsertError;
  const { data: catalog, error: catalogError } = await admin
    .from("tnum_service_country_catalog").select("provider_price")
    .eq("service_slug", service).eq("country_code", country).single();
  if (catalogError || !catalog) throw new Error("CATALOG_UNAVAILABLE");

  const { data: reserved, error: reserveError } = await admin.rpc(
    "tnum_reserve_activation",
    {
      p_user: userId,
      p_key: key,
      p_service: service,
      p_country: country,
      p_provider_cents: providerCents,
      p_quote: quoteId,
    },
  ).single();
  
  if (reserveError) {
    const databaseError = String(reserveError.message ?? '').trim();

    if (databaseError.includes('PRICE_CHANGED')) {
      return json({ error: 'PRICE_CHANGED' }, 409);
    }

    if (databaseError === 'INSUFFICIENT_BALANCE') {
      return json({ error: 'INSUFFICIENT_BALANCE' }, 409);
    }

    console.error('[T-NUM] Activation reservation failed:', {
      code: reserveError.code,
      message: databaseError,
    });

    throw new Error('ACTIVATION_RESERVATION_FAILED');
  }

  const activation = reserved as Record<string, unknown> & {
    id: string;
    status: string;
  };

  // Only one retry-safe database claimant can cross the purchase boundary.
  const { data: claimed, error: claimError } = await admin.rpc(
    "tnum_claim_activation_purchase",
    { p_activation: activation.id },
  );
  if (claimError) throw claimError;
  if (claimed !== true) {
    return json(
      { activation: publicActivation(activation), idempotent_replay: true },
      activation.status === "provider_outcome_uncertain" ? 202 : 200,
    );
  }

  try {
    // Space the tariff lookup and purchase calls to reduce provider frequency errors.
    await new Promise((resolve) => setTimeout(resolve, 1000));
    const result = await provider("getNum", {
      service,
      country,
      number: true,
      lang: "fr",
    }) as Record<string, unknown>;
        const phoneNumber = typeof result.number === "string"
      ? result.number.trim()
      : "";

    if (!phoneNumber) {
      throw new Error("PROVIDER_NO_NUMBER");
    }

    const tzid = Number(result.tzid);
    if (!Number.isSafeInteger(tzid) || tzid <= 0) {
      throw new Error("PROVIDER_AMBIGUOUS");
    }

    const { data: updated, error } = await admin.from("tnum_activations").update({
      provider_operation_id: tzid,
      phone_number: phoneNumber,
      status: "active",
    }).eq("id", activation.id).select().single();
    if (error) throw error;
    const { error: operationUpdateError } = await admin.from("tnum_provider_operations").update({
      state: "confirmed",
      updated_at: new Date().toISOString(),
    }).eq("activation_id", activation.id);
    if (operationUpdateError) throw operationUpdateError;
    return json({ activation: publicActivation(updated) });
  } catch (error) {
    const code = error instanceof Error ? error.message : "PROVIDER_AMBIGUOUS";
    const definitive = new Set([
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
       if (definitive.has(code)) {
      const { data: released, error: failureError } = await admin.rpc(
        "tnum_fail_activation_and_release",
        { p_activation: activation.id, p_failure_code: code },
      );

      if (failureError) {
        console.error("[T-NUM] Activation release failed:", failureError);
        throw new Error("ACTIVATION_RELEASE_FAILED");
      }

      if (released !== true) {
        console.error("[T-NUM] Activation was not released:", {
          activation_id: activation.id,
          code,
        });
        throw new Error("ACTIVATION_RELEASE_FAILED");
      }

      throw new Error(code);
    }
    const { error: uncertainError } = await admin.from("tnum_activations").update({
      status: "provider_outcome_uncertain",
    }).eq("id", activation.id);
    if (uncertainError) throw uncertainError;
    const { error: operationError } = await admin.from("tnum_provider_operations").update({
      state: "uncertain",
      last_error_code: code,
      updated_at: new Date().toISOString(),
    }).eq("activation_id", activation.id);
    if (operationError) throw operationError;
    console.warn(
      JSON.stringify({
        activation_id: activation.id,
        event: "purchase_outcome_uncertain",
        code,
      }),
    );
    return json({
      activation_id: activation.id,
      status: "provider_outcome_uncertain",
    }, 202);
  }
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

// activations
