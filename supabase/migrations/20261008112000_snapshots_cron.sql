alter table public.orders add column service_code text, add column service_name text, add column country_code text, add column country_name text, add column country_flag text not null default '';
create index orders_due_expiry_idx on public.orders(expires_at) where status = 'WAITING_FOR_SMS';

-- Supabase Cron invokes monitor functions through pg_net. Set CRON_SECRET in Vault
-- and in Edge Function secrets before applying the schedules in production.
create extension if not exists pg_cron;
create extension if not exists pg_net;
-- Schedules are created after Vault secrets are supplied; see docs/supabase-setup.md.
