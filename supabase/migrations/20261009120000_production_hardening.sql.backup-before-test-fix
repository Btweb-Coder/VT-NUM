-- Production hardening.  This migration is additive and safe to apply after
-- the four migrations already deployed for this project.
create extension if not exists supabase_vault with schema vault;

alter table public.orders
  add column if not exists monitor_failures integer not null default 0 check (monitor_failures >= 0),
  add column if not exists next_monitor_at timestamptz,
  add column if not exists last_monitor_error text,
  add column if not exists last_monitored_at timestamptz;

create index if not exists orders_monitor_due_idx
  on public.orders (next_monitor_at, expires_at)
  where status in ('WAITING_FOR_SMS', 'EXPIRING', 'CANCELLING');

create table if not exists public.background_job_leases (
  job_name text primary key check (job_name in ('monitor-activations', 'monitor-topups')),
  lease_id uuid,
  lease_until timestamptz,
  consecutive_failures integer not null default 0 check (consecutive_failures >= 0),
  last_started_at timestamptz,
  last_finished_at timestamptz,
  last_error text,
  updated_at timestamptz not null default now()
);
alter table public.background_job_leases enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='payment_gateways' and policyname='payment_gateways_active_read') then
    create policy payment_gateways_active_read on public.payment_gateways for select to authenticated using (active);
  end if;
end $$;

create or replace function public.claim_background_job(p_job_name text, p_lease_seconds integer default 55)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_lease uuid := gen_random_uuid();
begin
  if p_job_name not in ('monitor-activations', 'monitor-topups') then raise exception 'INVALID_JOB'; end if;
  if p_lease_seconds not between 10 and 300 then raise exception 'INVALID_LEASE_DURATION'; end if;
  insert into public.background_job_leases(job_name) values (p_job_name) on conflict (job_name) do nothing;
  update public.background_job_leases
     set lease_id = v_lease, lease_until = now() + make_interval(secs => p_lease_seconds),
         last_started_at = now(), updated_at = now()
   where job_name = p_job_name and (lease_until is null or lease_until < now());
  if found then return v_lease; end if;
  return null;
end $$;

create or replace function public.finish_background_job(p_job_name text, p_lease_id uuid, p_error text default null)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update public.background_job_leases
     set lease_id = null, lease_until = null, last_finished_at = now(),
         consecutive_failures = case when p_error is null then 0 else consecutive_failures + 1 end,
         last_error = p_error, updated_at = now()
   where job_name = p_job_name and lease_id = p_lease_id;
  return found;
end $$;

-- Stores all monetary snapshots and creates the hold in one transaction.
-- The caller has already acquired a provider allocation; a hold failure is
-- returned atomically so the Edge Function can compensate at the provider.
create or replace function public.assign_activation_and_create_hold(
  p_order_id uuid, p_provider_id uuid, p_provider_activation_id text,
  p_phone_number text, p_provider_price numeric, p_currency char(3),
  p_service_code text, p_service_name text, p_country_code text,
  p_country_name text, p_country_flag text, p_expires_at timestamptz
) returns table(customer_price numeric, markup_type text, markup_value numeric)
language plpgsql security definer set search_path = public as $$
declare v_order public.orders; v_wallet public.wallets; v_rule public.pricing_rules;
declare v_customer numeric(20,6);
begin
  if p_provider_price <= 0 or p_currency <> 'USD' or p_expires_at <= now() then raise exception 'INVALID_ACTIVATION_PRICE'; end if;
  select * into v_order from public.orders where id = p_order_id for update;
  if not found or v_order.status not in ('CREATED', 'PROVIDER_REQUESTING') then raise exception 'ORDER_NOT_ASSIGNABLE'; end if;
  select * into v_rule from public.pricing_rules where active for update;
  if not found then raise exception 'PRICING_UNAVAILABLE'; end if;
  v_customer := round(case when v_rule.markup_type = 'percentage'
    then p_provider_price * (1 + v_rule.markup_value / 100)
    else p_provider_price + v_rule.markup_value end, 6);
  if v_customer <= 0 then raise exception 'INVALID_CUSTOMER_PRICE'; end if;
  select * into v_wallet from public.wallets where user_id = v_order.user_id for update;
  if not found then raise exception 'WALLET_NOT_FOUND'; end if;
  if v_wallet.available_balance < v_customer then raise exception 'INSUFFICIENT_BALANCE'; end if;
  update public.orders set provider_id=p_provider_id, provider_activation_id=p_provider_activation_id,
    phone_number=p_phone_number, provider_price=round(p_provider_price, 6), markup_type=v_rule.markup_type,
    markup_value=v_rule.markup_value, markup_percentage=case when v_rule.markup_type='percentage' then v_rule.markup_value else 0 end,
    customer_price=v_customer, currency=p_currency, service_code=p_service_code, service_name=p_service_name,
    country_code=p_country_code, country_name=p_country_name, country_flag=coalesce(p_country_flag,''),
    assigned_at=now(), expires_at=p_expires_at, status='WAITING_FOR_SMS', financial_status='HOLDING',
    next_monitor_at=now(), monitor_failures=0, last_monitor_error=null
    where id=p_order_id;
  update public.wallets set available_balance=available_balance-v_customer, held_balance=held_balance+v_customer where user_id=v_order.user_id;
  insert into public.wallet_holds(order_id,user_id,amount,currency) values(p_order_id,v_order.user_id,v_customer,'USD');
  insert into public.wallet_ledger_entries(user_id,order_id,entry_type,amount,currency,balance_before,balance_after,idempotency_key)
    values(v_order.user_id,p_order_id,'HOLD',v_customer,'USD',v_wallet.available_balance,v_wallet.available_balance-v_customer,'hold:'||p_order_id);
  customer_price := v_customer; markup_type := v_rule.markup_type; markup_value := v_rule.markup_value; return next;
end $$;

revoke all on function public.claim_background_job(text,integer) from public, anon, authenticated;
revoke all on function public.finish_background_job(text,uuid,text) from public, anon, authenticated;
revoke all on function public.assign_activation_and_create_hold(uuid,uuid,text,text,numeric,char(3),text,text,text,text,text,timestamptz) from public, anon, authenticated;

-- Register Proxnum without enabling it.  The adapter reads only this existing
-- Edge Function secret; no token is copied into PostgreSQL.
do $$
declare v_priority integer;
begin
  select coalesce(min(p.priority) filter (where p.priority >= 10), 10) into v_priority from public.providers p;
  while exists (select 1 from public.providers where priority = v_priority and slug <> 'proxnum') loop v_priority := v_priority + 1; end loop;
  insert into public.providers(slug, active, priority, endpoint, secret_name, config)
  values ('proxnum', false, v_priority, 'https://proxnum.com', 'PROVIDER_SECRETS',
    '{"features":{"virtual_sms":true,"rental_numbers":false},"pricing":{"cost_field":"base_price","reseller_field":"sell_price","currency":"USD"}}'::jsonb)
  on conflict (slug) do update set endpoint=excluded.endpoint, secret_name=excluded.secret_name,
    config=public.providers.config || excluded.config, updated_at=now();
end $$;

-- Schedules are deliberately installed only after an administrator places the
-- already-existing CRON_SECRET into Vault as `cron_secret`.  The secret is read
-- at invocation time and is never written into a migration or cron command.
create or replace function public.configure_monitoring_schedules()
returns void language plpgsql security definer set search_path = public, cron, net, vault as $$
declare v_secret text; v_url text := 'https://mvvmdiabzkcywjvkffgr.supabase.co/functions/v1/';
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name='cron_secret' limit 1;
  if v_secret is null or length(v_secret) = 0 then raise exception 'VAULT_CRON_SECRET_MISSING'; end if;
  perform cron.unschedule(jobid) from cron.job where jobname in ('online-sim-monitor-activations','online-sim-monitor-topups');
  perform cron.schedule('online-sim-monitor-activations', '* * * * *', format($cmd$select net.http_post(url := %L, headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')), body := '{}'::jsonb);$cmd$, v_url || 'monitor-activations'));
  perform cron.schedule('online-sim-monitor-topups', '* * * * *', format($cmd$select net.http_post(url := %L, headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')), body := '{}'::jsonb);$cmd$, v_url || 'monitor-topups'));
end $$;
revoke all on function public.configure_monitoring_schedules() from public, anon, authenticated;
