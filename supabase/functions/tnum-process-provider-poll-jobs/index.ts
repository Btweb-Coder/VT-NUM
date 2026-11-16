import { handler, json } from "../_shared/common.ts";
import { runWorker } from "../_shared/worker.ts";
Deno.serve(handler(async (req) => {
  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) {
    return json({ error: "FORBIDDEN" }, 403);
  }
  return json(await runWorker("monitor"));
}));
