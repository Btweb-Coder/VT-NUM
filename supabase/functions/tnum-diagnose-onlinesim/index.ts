
import { handler, json, provider, providerKey } from "../_shared/common.ts";

const OPERATION_IDS = [
  208311909,
];

Deno.serve(handler(async (req) => {
  const expected = Deno.env.get("CRON_SECRET");
  const supplied = req.headers.get("x-cron-secret");

  if (!expected || supplied !== expected) {
    return json({ error: "FORBIDDEN" }, 403);
  }

  // Verify that the provider secret exists without returning it.
  providerKey();

  const results = [];

  for (const tzid of OPERATION_IDS) {
    try {
      const response = await provider("getState", {
        tzid,
        msg_list: 1,
        message_to_code: 1,
        lang: "en",
      });

      results.push({
        tzid,
        success: true,
        response,
      });
    } catch (error) {
      results.push({
        tzid,
        success: false,
        error: error instanceof Error
          ? error.message
          : "UNKNOWN_ERROR",
      });
    }
  }

  return json({
    diagnostic: "ONLINESIM_READ_ONLY",
    project: "T-NUM",
    results,
  });
}));
