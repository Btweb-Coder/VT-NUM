# Supabase setup for VT NUM

The client receives only `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` through
`--dart-define`. Do not commit project keys, service-role keys, payment keys, or
provider credentials.

1. Link this repository to the `vt-num` Supabase project (`supabase link
   --project-ref mvvmdiabzkcywjvkffgr`) before deploying. Its project reference
   is recorded in `supabase/config.toml`; linking stores the local CLI state.
2. Enable Email auth, email confirmation, password recovery, and set the
   application redirect URLs for every released platform.
3. Enable Realtime replication for `wallets`, `orders`, `payment_intents`, and
   `app_update_config`. RLS policies in the migrations are required.
4. Configure Edge Function secrets outside Git:
   - `SUPABASE_SERVICE_ROLE_KEY`
   - `CRON_SECRET`
   - `PROVIDER_SECRETS` as a JSON object keyed by `proxnum`/`codasms`
   - `PAYMENT_SECRETS` as a JSON object keyed by `fapshi`/`cinetpay`/`transfluo`
5. Configure non-secret providers, provider mappings, payment gateways, catalog,
   and update configuration through a controlled administrator workflow.
6. Deploy all Edge Functions, including `replace-activation`, then apply
   `20261009120000_production_hardening.sql`. Create a Vault secret named
   `cron_secret` with the same value already held by the Edge Function secret
   `CRON_SECRET` (Dashboard: Database > Vault > New secret). In SQL Editor,
   run `select public.configure_monitoring_schedules();`. This creates the two
   one-minute schedules without putting the secret in source control or the
   cron command. Verify the jobs in Database > Cron Jobs and Edge Function logs.
7. Populate Proxnum only from an official mapping source. Copy
   `scripts/proxnum-catalog.template.json`, complete records with source URLs,
   and run `deno run --allow-env --allow-read --allow-net
   scripts/sync_proxnum_catalog.ts path/to/verified-catalog.json`. It refuses
   guessed codes/names and is safe to re-run.

The CODA SMS endpoint paths/status mapping must come from its real vendor
documentation before the provider is enabled. Do not invent those values.
