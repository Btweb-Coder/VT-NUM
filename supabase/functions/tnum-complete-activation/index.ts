import {
  handler,
  json,
  provider,
  readJson,
  requireUser,
} from "../_shared/common.ts";

Deno.serve(handler(async (req) => {
  const { admin, userId } = await requireUser(req);
  const { id } = await readJson(req);
  if (typeof id !== "string" || !/^[0-9a-f-]{36}$/i.test(id)) {
    return json({ error: "INVALID_ID" }, 400);
  }
  const { data: activation, error } = await admin.from("tnum_activations")
    .select("id,status,provider_operation_id").eq("user_id", userId).eq(
      "id",
      id,
    ).single();
  if (error || !activation) return json({ error: "ACTIVATION_NOT_FOUND" }, 404);
  if (
    activation.status !== "sms_received" || !activation.provider_operation_id
  ) {
    return json({ error: "SMS_REQUIRED_BEFORE_COMPLETION" }, 409);
  }
  const { count } = await admin.from("tnum_activation_sms")
    .select("id", { count: "exact", head: true }).eq("activation_id", id);
  if (!count) return json({ error: "SMS_REQUIRED_BEFORE_COMPLETION" }, 409);
  const { data: claimed, error: claimError } = await admin.rpc(
    "tnum_claim_activation_completion",
    { p_activation: id },
  );
  if (claimError) throw claimError;
  if (claimed !== true) {
    return json({ error: "COMPLETION_ALREADY_PROCESSING" }, 409);
  }
  try {
    await provider("setOperationOk", {
      tzid: activation.provider_operation_id,
      ban: 0,
      lang: "fr",
    });
    const now = new Date().toISOString();
    const { error: captureError } = await admin.rpc(
      "tnum_capture_activation_reservation",
      { p_activation: id },
    );
    if (captureError) throw captureError;
    await admin.from("tnum_activations").update({
      status: "completed",
      provider_terminal_at: now,
      completed_at: now,
      cancellation_state: "confirmed",
      failure_code: null,
    }).eq("id", id);
    await admin.from("tnum_provider_operations").update({
      operation: "close",
      state: "confirmed",
      updated_at: now,
    }).eq("activation_id", id);
    return json({ status: "completed" });
  } catch (error) {
    const code = error instanceof Error
      ? error.message
      : "PROVIDER_CLOSE_UNCERTAIN";
    if (code === "PROVIDER_NO_COMPLETE_TZID") {
      await admin.from("tnum_activations").update({ status: "sms_received" }).eq(
        "id",
        id,
      );
      return json({ error: "PROVIDER_PROTECTIVE_INTERVAL" }, 409);
    }
    await admin.from("tnum_activations").update({ status: "completion_pending" }).eq(
      "id",
      id,
    );
    await admin.from("tnum_provider_operations").update({
      operation: "close",
      state: "uncertain",
      last_error_code: code,
      updated_at: new Date().toISOString(),
    }).eq("activation_id", id);
    console.warn(
      JSON.stringify({
        activation_id: id,
        event: "completion_outcome_uncertain",
      }),
    );
    return json({ activation_id: id, status: "completion_pending" }, 202);
  }
}));

