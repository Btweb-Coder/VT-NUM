
-- ===== 20261008110000_initial_schema.sql =====

-- VT NUM relational backend. All balances use exact NUMERIC values, never float.
create extension if not exists pgcrypto;

create type public.order_status as enum ('CREATED','PROVIDER_REQUESTING','WAITING_FOR_SMS','SMS_RECEIVED','COMPLETED','EXPIRING','CANCELLING','EXPIRED','CANCELLED','REPLACING','FAILED');
create type public.order_financial_status as enum ('NONE','HOLDING','CAPTURED','RELEASED');
create type public.wallet_hold_status as enum ('HELD','CAPTURED','RELEASED');
create type public.wallet_entry_type as enum ('DEPOSIT','HOLD','RELEASE_HOLD','CAPTURE_HOLD','ADJUSTMENT');
create type public.provider_attempt_action as enum ('PURCHASE','STATUS','CANCEL','BALANCE');
create type public.provider_attempt_status as enum ('STARTED','SUCCESS','NO_NUMBERS','TIMEOUT','FAILED');
create type public.payment_intent_status as enum ('INITIATED','PENDING','SUCCESSFUL','FAILED','REQUIRES_RECONCILIATION');
create type public.idempotency_status as enum ('RESERVED','PROCESSING','COMPLETED','FAILED');

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete restrict,
  email text not null,
  email_verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.wallets (
  user_id uuid primary key references public.profiles(user_id) on delete restrict,
  currency char(3) not null default 'USD' check (currency = 'USD'),
  available_balance numeric(20,6) not null default 0 check (available_balance >= 0),
  held_balance numeric(20,6) not null default 0 check (held_balance >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.services (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.countries (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  flag text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.providers (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug in ('proxnum','codasms')),
  active boolean not null default false,
  priority integer not null unique check (priority >= 0),
  endpoint text not null check (endpoint like 'https://%'),
  config jsonb not null default '{}'::jsonb,
  secret_name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.provider_service_mappings (
  provider_id uuid not null references public.providers(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete restrict,
  provider_code text not null,
  primary key (provider_id, service_id), unique (provider_id, provider_code)
);
create table public.provider_country_mappings (
  provider_id uuid not null references public.providers(id) on delete cascade,
  country_id uuid not null references public.countries(id) on delete restrict,
  provider_code text not null,
  primary key (provider_id, country_id), unique (provider_id, provider_code)
);
create table public.pricing_rules (
  id uuid primary key default gen_random_uuid(),
  active boolean not null default true,
  markup_type text not null check (markup_type in ('percentage','fixed')),
  markup_value numeric(20,6) not null check (markup_value >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index pricing_rules_one_active on public.pricing_rules ((active)) where active;
create table public.payment_fee_config (
  id boolean primary key default true check (id),
  fee_percent numeric(10,8) not null check (fee_percent >= 0 and fee_percent <= 1),
  updated_at timestamptz not null default now()
);
create table public.payment_gateways (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug in ('fapshi','cinetpay','transfluo')),
  active boolean not null default false,
  endpoint text not null check (endpoint like 'https://%'),
  provider_currency char(3) not null,
  exchange_rate numeric(20,6) not null check (exchange_rate > 0),
  min_provider_amount numeric(20,6) not null check (min_provider_amount > 0),
  config jsonb not null default '{}'::jsonb,
  secret_name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.app_update_config (
  id boolean primary key default true check (id),
  force_update boolean not null default false,
  required_version text not null default '',
  download_url text not null default '',
  updated_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete restrict,
  service_id uuid not null references public.services(id) on delete restrict,
  country_id uuid not null references public.countries(id) on delete restrict,
  provider_id uuid references public.providers(id) on delete restrict,
  status public.order_status not null default 'CREATED',
  financial_status public.order_financial_status not null default 'NONE',
  provider_activation_id text,
  phone_number text,
  provider_price numeric(20,6),
  markup_type text check (markup_type in ('percentage','fixed')),
  markup_value numeric(20,6),
  markup_percentage numeric(20,6),
  customer_price numeric(20,6),
  currency char(3),
  code text,
  provider_cancellation_confirmed boolean not null default false,
  failure_code text,
  failure_message text,
  replaced_order_id uuid references public.orders(id) on delete restrict,
  replacement_order_id uuid unique references public.orders(id) on delete restrict,
  assigned_at timestamptz,
  expires_at timestamptz,
  sms_received_at timestamptz,
  completed_at timestamptz,
  expired_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((status in ('WAITING_FOR_SMS','SMS_RECEIVED','COMPLETED','EXPIRING','CANCELLING','EXPIRED','CANCELLED')) = (provider_id is not null and provider_activation_id is not null and customer_price is not null) or status in ('CREATED','PROVIDER_REQUESTING','REPLACING','FAILED'))
);
create unique index orders_provider_activation_unique on public.orders(provider_id, provider_activation_id) where provider_id is not null and provider_activation_id is not null;
create index orders_user_created_idx on public.orders(user_id, created_at desc);
create index orders_monitor_idx on public.orders(status, expires_at) where status in ('WAITING_FOR_SMS','EXPIRING','CANCELLING');

create table public.wallet_holds (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete restrict,
  user_id uuid not null references public.profiles(user_id) on delete restrict,
  amount numeric(20,6) not null check (amount > 0),
  currency char(3) not null check (currency = 'USD'),
  status public.wallet_hold_status not null default 'HELD',
  created_at timestamptz not null default now(), captured_at timestamptz, released_at timestamptz
);
create table public.payment_intents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete restrict,
  gateway_id uuid not null references public.payment_gateways(id) on delete restrict,
  idempotency_key text not null check (length(idempotency_key) between 1 and 200),
  amount numeric(20,6) not null check (amount > 0),
  fee numeric(20,6) not null check (fee >= 0),
  provider_amount numeric(20,6) not null check (provider_amount > 0),
  currency char(3) not null default 'USD' check (currency = 'USD'),
  provider_currency char(3) not null,
  exchange_rate numeric(20,6) not null check (exchange_rate > 0),
  phone_last4 text not null, phone_hash text not null,
  status public.payment_intent_status not null default 'INITIATED',
  provider_transaction_id text, provider_reference_id text, provider_status text, checkout_url text,
  poll_count integer not null default 0 check (poll_count >= 0), poll_lease_id uuid, poll_lease_until timestamptz,
  next_poll_at timestamptz, last_polled_at timestamptz, last_poll_error text, start_error text,
  failure_code text, initiated_at timestamptz, failed_at timestamptz, credited_at timestamptz, reconciliation_required_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(user_id, idempotency_key)
);
create unique index payment_intents_one_active_per_user on public.payment_intents(user_id) where status in ('INITIATED','PENDING','REQUIRES_RECONCILIATION');
create index payment_intents_due_idx on public.payment_intents(status, next_poll_at) where status = 'PENDING';
create index payment_intents_initiated_idx on public.payment_intents(status, created_at) where status = 'INITIATED';

create table public.wallet_ledger_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete restrict,
  order_id uuid references public.orders(id) on delete restrict,
  payment_intent_id uuid references public.payment_intents(id) on delete restrict,
  entry_type public.wallet_entry_type not null,
  amount numeric(20,6) not null check (amount > 0), currency char(3) not null check (currency = 'USD'),
  balance_before numeric(20,6), balance_after numeric(20,6), provider_amount numeric(20,6), provider_currency char(3), fee numeric(20,6), exchange_rate numeric(20,6),
  provider_transaction_id text, provider_status text, metadata jsonb not null default '{}'::jsonb,
  idempotency_key text not null unique, created_at timestamptz not null default now(),
  check ((order_id is not null) or (payment_intent_id is not null))
);
create index wallet_ledger_user_created_idx on public.wallet_ledger_entries(user_id, created_at desc);
create table public.provider_attempts (
  id uuid primary key default gen_random_uuid(), order_id uuid not null references public.orders(id) on delete restrict,
  provider_id uuid not null references public.providers(id) on delete restrict,
  action public.provider_attempt_action not null, status public.provider_attempt_status not null default 'STARTED',
  error_code text, error_message text, metadata jsonb not null default '{}'::jsonb, started_at timestamptz not null default now(), finished_at timestamptz
);
create index provider_attempts_order_idx on public.provider_attempts(order_id, started_at);
create table public.order_events (
  id uuid primary key default gen_random_uuid(), order_id uuid not null references public.orders(id) on delete restrict,
  user_id uuid not null references public.profiles(user_id) on delete restrict, event_type text not null,
  provider_id uuid references public.providers(id) on delete restrict, metadata jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);
create index order_events_order_idx on public.order_events(order_id, created_at);
create table public.operation_events (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(user_id) on delete restrict,
  action text not null check (length(action) between 1 and 80), outcome text not null check (outcome in ('SUCCESS','FAILURE')),
  metadata jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);
create table public.idempotency_keys (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(user_id) on delete restrict,
  operation text not null check (operation in ('ACTIVATION','REPLACEMENT','TOPUP')), key text not null check (length(key) between 1 and 200),
  order_id uuid references public.orders(id) on delete restrict, payment_intent_id uuid references public.payment_intents(id) on delete restrict,
  status public.idempotency_status not null default 'RESERVED', created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(user_id, operation, key)
);

create or replace function public.set_updated_at() returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin insert into public.profiles(user_id,email,email_verified_at) values (new.id,coalesce(new.email,''),case when new.email_confirmed_at is null then null else new.email_confirmed_at end) on conflict (user_id) do update set email=excluded.email,email_verified_at=excluded.email_verified_at,updated_at=now(); return new; end $$;
create trigger on_auth_user_created after insert or update of email,email_confirmed_at on auth.users for each row execute procedure public.handle_new_user();
create trigger profiles_updated before update on public.profiles for each row execute procedure public.set_updated_at();
create trigger wallets_updated before update on public.wallets for each row execute procedure public.set_updated_at();
create trigger services_updated before update on public.services for each row execute procedure public.set_updated_at();
create trigger countries_updated before update on public.countries for each row execute procedure public.set_updated_at();
create trigger providers_updated before update on public.providers for each row execute procedure public.set_updated_at();
create trigger pricing_rules_updated before update on public.pricing_rules for each row execute procedure public.set_updated_at();
create trigger gateways_updated before update on public.payment_gateways for each row execute procedure public.set_updated_at();
create trigger orders_updated before update on public.orders for each row execute procedure public.set_updated_at();
create trigger payment_intents_updated before update on public.payment_intents for each row execute procedure public.set_updated_at();

-- Bootstrap is callable by the verified authenticated user; all other money/order writes stay server-only.
create or replace function public.bootstrap_account() returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists (select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null) then raise exception 'EMAIL_NOT_VERIFIED'; end if;
  insert into public.wallets(user_id) values(auth.uid()) on conflict (user_id) do nothing;
end $$;

create or replace function public.create_wallet_hold(p_order_id uuid) returns void language plpgsql security definer set search_path = public as $$
declare v_order public.orders; v_wallet public.wallets;
begin
  select * into v_order from public.orders where id=p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if exists(select 1 from public.wallet_holds where order_id=p_order_id) then return; end if;
  if v_order.customer_price is null or v_order.currency <> 'USD' then raise exception 'INVALID_ORDER_AMOUNT'; end if;
  select * into v_wallet from public.wallets where user_id=v_order.user_id for update;
  if not found then raise exception 'WALLET_NOT_FOUND'; end if;
  if v_wallet.available_balance < v_order.customer_price then raise exception 'INSUFFICIENT_BALANCE'; end if;
  update public.wallets set available_balance=available_balance-v_order.customer_price,held_balance=held_balance+v_order.customer_price where user_id=v_order.user_id;
  insert into public.wallet_holds(order_id,user_id,amount,currency) values(p_order_id,v_order.user_id,v_order.customer_price,'USD');
  insert into public.wallet_ledger_entries(user_id,order_id,entry_type,amount,currency,balance_before,balance_after,idempotency_key) values(v_order.user_id,p_order_id,'HOLD',v_order.customer_price,'USD',v_wallet.available_balance,v_wallet.available_balance-v_order.customer_price,'hold:'||p_order_id);
end $$;
create or replace function public.release_wallet_hold(p_order_id uuid) returns void language plpgsql security definer set search_path = public as $$
declare v_hold public.wallet_holds; v_wallet public.wallets;
begin
 select * into v_hold from public.wallet_holds where order_id=p_order_id for update; if not found then raise exception 'HOLD_NOT_FOUND'; end if; if v_hold.status='RELEASED' then return; end if; if v_hold.status='CAPTURED' then raise exception 'HOLD_ALREADY_CAPTURED'; end if;
 select * into v_wallet from public.wallets where user_id=v_hold.user_id for update; if v_wallet.held_balance < v_hold.amount then raise exception 'INVALID_HELD_BALANCE'; end if;
 update public.wallets set available_balance=available_balance+v_hold.amount,held_balance=held_balance-v_hold.amount where user_id=v_hold.user_id;
 update public.wallet_holds set status='RELEASED',released_at=now() where id=v_hold.id;
 insert into public.wallet_ledger_entries(user_id,order_id,entry_type,amount,currency,balance_before,balance_after,idempotency_key) values(v_hold.user_id,p_order_id,'RELEASE_HOLD',v_hold.amount,'USD',v_wallet.available_balance,v_wallet.available_balance+v_hold.amount,'release:'||p_order_id) on conflict (idempotency_key) do nothing;
end $$;
create or replace function public.capture_wallet_hold(p_order_id uuid) returns void language plpgsql security definer set search_path = public as $$
declare v_hold public.wallet_holds; v_wallet public.wallets;
begin
 select * into v_hold from public.wallet_holds where order_id=p_order_id for update; if not found then raise exception 'HOLD_NOT_FOUND'; end if; if v_hold.status='CAPTURED' then return; end if; if v_hold.status='RELEASED' then raise exception 'HOLD_ALREADY_RELEASED'; end if;
 select * into v_wallet from public.wallets where user_id=v_hold.user_id for update; if v_wallet.held_balance < v_hold.amount then raise exception 'INVALID_HELD_BALANCE'; end if;
 update public.wallets set held_balance=held_balance-v_hold.amount where user_id=v_hold.user_id;
 update public.wallet_holds set status='CAPTURED',captured_at=now() where id=v_hold.id;
 insert into public.wallet_ledger_entries(user_id,order_id,entry_type,amount,currency,balance_before,balance_after,idempotency_key) values(v_hold.user_id,p_order_id,'CAPTURE_HOLD',v_hold.amount,'USD',v_wallet.available_balance,v_wallet.available_balance,'capture:'||p_order_id) on conflict (idempotency_key) do nothing;
end $$;

alter table public.profiles enable row level security; alter table public.wallets enable row level security; alter table public.services enable row level security; alter table public.countries enable row level security; alter table public.app_update_config enable row level security;
alter table public.orders enable row level security; alter table public.wallet_holds enable row level security; alter table public.wallet_ledger_entries enable row level security; alter table public.payment_intents enable row level security; alter table public.order_events enable row level security; alter table public.operation_events enable row level security;
alter table public.providers enable row level security; alter table public.provider_service_mappings enable row level security; alter table public.provider_country_mappings enable row level security; alter table public.pricing_rules enable row level security; alter table public.payment_gateways enable row level security; alter table public.payment_fee_config enable row level security; alter table public.provider_attempts enable row level security; alter table public.idempotency_keys enable row level security;
create policy profiles_self on public.profiles for select using (user_id=auth.uid());
create policy wallets_self on public.wallets for select using (user_id=auth.uid());
create policy services_read on public.services for select to authenticated using (active);
create policy countries_read on public.countries for select to authenticated using (active);
create policy update_public_read on public.app_update_config for select using (true);
create policy orders_self on public.orders for select using (user_id=auth.uid());
create policy holds_self on public.wallet_holds for select using (user_id=auth.uid());
create policy ledger_self on public.wallet_ledger_entries for select using (user_id=auth.uid());
create policy intents_self on public.payment_intents for select using (user_id=auth.uid());
create policy order_events_self on public.order_events for select using (user_id=auth.uid());
create policy operation_events_self on public.operation_events for select using (user_id=auth.uid());
grant execute on function public.bootstrap_account() to authenticated;

-- Seed only non-sensitive defaults. Configure providers/gateways and their secrets separately.
insert into public.pricing_rules(active,markup_type,markup_value) values(true,'percentage',50);
insert into public.payment_fee_config(id,fee_percent) values(true,0) on conflict (id) do nothing;
insert into public.app_update_config(id,force_update,required_version,download_url) values(true,false,'','') on conflict (id) do nothing;


-- ===== 20261008111000_workflow_rpcs.sql =====

-- Server-side workflow primitives. They are intentionally not granted to client roles.
create or replace function public.reserve_activation_request(p_user_id uuid,p_service_id uuid,p_country_id uuid,p_key text)
returns table(order_id uuid, is_new boolean) language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_order_id uuid; v_new boolean := false;
begin
 if length(trim(p_key)) not between 1 and 200 then raise exception 'INVALID_IDEMPOTENCY_KEY'; end if;
 insert into public.idempotency_keys(user_id,operation,key,status) values(p_user_id,'ACTIVATION',trim(p_key),'RESERVED') on conflict(user_id,operation,key) do nothing;
 select id, k.order_id into v_id, v_order_id from public.idempotency_keys k where user_id=p_user_id and operation='ACTIVATION' and key=trim(p_key) for update;
 if v_order_id is null then
   insert into public.orders(user_id,service_id,country_id,status,financial_status) values(p_user_id,p_service_id,p_country_id,'CREATED','NONE') returning id into v_order_id;
   update public.idempotency_keys set order_id=v_order_id,status='PROCESSING',updated_at=now() where id=v_id;
   is_new := true;
 else is_new := false; end if;
 order_id := v_order_id;
 return next;
end $$;

create or replace function public.transition_order(p_order_id uuid,p_from public.order_status[],p_to public.order_status,p_extra jsonb default '{}'::jsonb)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_status public.order_status;
begin
 select status into v_status from public.orders where id=p_order_id for update;
 if not found then raise exception 'ORDER_NOT_FOUND'; end if;
 if v_status=p_to then return false; end if;
 if not v_status=any(p_from) then raise exception 'INVALID_ORDER_TRANSITION:%->%',v_status,p_to; end if;
 update public.orders set status=p_to,
   code=coalesce(p_extra->>'code',code), provider_cancellation_confirmed=coalesce((p_extra->>'provider_cancellation_confirmed')::boolean,provider_cancellation_confirmed),
   sms_received_at=case when p_to='SMS_RECEIVED' then now() else sms_received_at end,
   completed_at=case when p_to='COMPLETED' then now() else completed_at end,
   expired_at=case when p_to='EXPIRED' then now() else expired_at end,
   cancelled_at=case when p_to='CANCELLED' then now() else cancelled_at end,
   financial_status=case when p_to='COMPLETED' then 'CAPTURED'::public.order_financial_status when p_to='EXPIRED' then 'RELEASED'::public.order_financial_status else financial_status end
 where id=p_order_id;
 return true;
end $$;

create or replace function public.credit_payment_intent(p_intent_id uuid,p_provider_status text,p_provider_transaction_id text)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_intent public.payment_intents; v_wallet public.wallets;
begin
 select * into v_intent from public.payment_intents where id=p_intent_id for update;
 if not found then raise exception 'PAYMENT_INTENT_NOT_FOUND'; end if;
 if v_intent.status='SUCCESSFUL' then return false; end if;
 if v_intent.status not in ('PENDING','INITIATED') then raise exception 'PAYMENT_NOT_CREDITABLE'; end if;
 select * into v_wallet from public.wallets where user_id=v_intent.user_id for update; if not found then raise exception 'WALLET_NOT_FOUND'; end if;
 update public.wallets set available_balance=available_balance+v_intent.amount where user_id=v_intent.user_id;
 insert into public.wallet_ledger_entries(user_id,payment_intent_id,entry_type,amount,currency,balance_before,balance_after,provider_amount,provider_currency,fee,exchange_rate,provider_transaction_id,provider_status,idempotency_key)
 values(v_intent.user_id,v_intent.id,'DEPOSIT',v_intent.amount,'USD',v_wallet.available_balance,v_wallet.available_balance+v_intent.amount,v_intent.provider_amount,v_intent.provider_currency,v_intent.fee,v_intent.exchange_rate,p_provider_transaction_id,p_provider_status,'deposit:'||v_intent.id);
 update public.payment_intents set status='SUCCESSFUL',provider_status=p_provider_status,provider_transaction_id=p_provider_transaction_id,credited_at=now(),poll_lease_id=null,poll_lease_until=null where id=p_intent_id;
 return true;
end $$;

revoke all on function public.reserve_activation_request(uuid,uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.transition_order(uuid,public.order_status[],public.order_status,jsonb) from public, anon, authenticated;
revoke all on function public.credit_payment_intent(uuid,text,text) from public, anon, authenticated;


-- ===== 20261008112000_snapshots_cron.sql =====

alter table public.orders add column service_code text, add column service_name text, add column country_code text, add column country_name text, add column country_flag text not null default '';
create index orders_due_expiry_idx on public.orders(expires_at) where status = 'WAITING_FOR_SMS';

-- Supabase Cron invokes monitor functions through pg_net. Set CRON_SECRET in Vault
-- and in Edge Function secrets before applying the schedules in production.
create extension if not exists pg_cron;
create extension if not exists pg_net;
-- Schedules are created after Vault secrets are supplied; see docs/supabase-setup.md.


-- ===== 20261008113000_complete_migration.sql =====

-- Completion migration: UI compatibility and atomic replacement reservation.
alter table public.services add column if not exists flag text not null default '';
alter table public.payment_intents add column if not exists gateway_slug text;
update public.payment_intents i set gateway_slug=g.slug from public.payment_gateways g where i.gateway_id=g.id and i.gateway_slug is null;

create or replace function public.reserve_replacement_request(
  p_user_id uuid, p_old_order_id uuid, p_key text
) returns table(order_id uuid, is_new boolean)
language plpgsql security definer set search_path=public as $$
declare v_old public.orders; v_key public.idempotency_keys; v_new_id uuid;
begin
  if length(trim(p_key)) not between 1 and 200 then raise exception 'INVALID_IDEMPOTENCY_KEY'; end if;
  select * into v_key from public.idempotency_keys
    where user_id=p_user_id and operation='REPLACEMENT' and key=trim(p_key) for update;
  if found and v_key.order_id is not null then
    order_id := v_key.order_id; is_new := false; return next; return;
  end if;
  select * into v_old from public.orders where id=p_old_order_id for update;
  if not found or v_old.user_id <> p_user_id then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_old.status <> 'EXPIRED' then raise exception 'ORDER_NOT_EXPIRED'; end if;
  if v_old.financial_status <> 'RELEASED' then raise exception 'WALLET_HOLD_NOT_RELEASED'; end if;
  if not v_old.provider_cancellation_confirmed then raise exception 'PROVIDER_CANCELLATION_NOT_CONFIRMED'; end if;

  insert into public.idempotency_keys(user_id,operation,key,status)
  values(p_user_id,'REPLACEMENT',trim(p_key),'RESERVED') on conflict(user_id,operation,key) do nothing;
  select * into v_key from public.idempotency_keys
    where user_id=p_user_id and operation='REPLACEMENT' and key=trim(p_key) for update;
  if v_key.order_id is not null then
    order_id := v_key.order_id; is_new := false; return next; return;
  end if;
  if v_old.replacement_order_id is not null then
    update public.idempotency_keys set order_id=v_old.replacement_order_id,status='COMPLETED',updated_at=now() where id=v_key.id;
    order_id := v_old.replacement_order_id; is_new := false; return next; return;
  end if;
  insert into public.orders(user_id,service_id,country_id,status,financial_status,replaced_order_id)
    values(p_user_id,v_old.service_id,v_old.country_id,'CREATED','NONE',p_old_order_id) returning id into v_new_id;
  update public.orders set status='REPLACING',replacement_order_id=v_new_id where id=p_old_order_id;
  update public.idempotency_keys set order_id=v_new_id,status='PROCESSING',updated_at=now() where id=v_key.id;
  order_id := v_new_id; is_new := true; return next;
end $$;

create or replace function public.fail_replacement_request(p_old_order_id uuid,p_new_order_id uuid,p_code text,p_message text default null)
returns void language plpgsql security definer set search_path=public as $$
begin
  update public.orders set status='FAILED',failure_code=p_code,failure_message=p_message where id=p_new_order_id and status in ('CREATED','PROVIDER_REQUESTING');
  update public.orders set status='EXPIRED' where id=p_old_order_id and status='REPLACING' and replacement_order_id=p_new_order_id;
end $$;

revoke all on function public.reserve_replacement_request(uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.fail_replacement_request(uuid,uuid,text,text) from public, anon, authenticated;

create or replace function public.claim_payment_intent(p_intent_id uuid, p_manual boolean default false)
returns table(id uuid, user_id uuid, gateway_id uuid, provider_transaction_id text, provider_amount numeric, provider_currency char(3), status public.payment_intent_status)
language plpgsql security definer set search_path=public as $$
declare v public.payment_intents;
begin
  select * into v from public.payment_intents where id=p_intent_id for update;
  if not found then raise exception 'PAYMENT_INTENT_NOT_FOUND'; end if;
  if v.status <> 'PENDING' then return; end if;
  if not p_manual and (v.next_poll_at is null or v.next_poll_at > now()) then return; end if;
  if v.poll_lease_until is not null and v.poll_lease_until > now() then return; end if;
  update public.payment_intents set poll_lease_id=gen_random_uuid(),poll_lease_until=now()+interval '45 seconds',poll_count=poll_count+1,last_polled_at=now() where id=v.id;
  return query select v.id,v.user_id,v.gateway_id,v.provider_transaction_id,v.provider_amount,v.provider_currency,v.status;
end $$;
revoke all on function public.claim_payment_intent(uuid,boolean) from public, anon, authenticated;

-- Flutter consumes these through authenticated Realtime streams.  The DO block
-- keeps this migration safe when a table has already been added manually.
do $$ begin
  alter publication supabase_realtime add table public.wallets;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.orders;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.payment_intents;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.app_update_config;
exception when duplicate_object then null; end $$;


-- ===== 20261009120000_production_hardening.sql =====

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

-- Monitoring schedules intentionally omitted from the test migration.



-- ===== 20261010110000_payment_gateway_seed.sql =====

-- Non-secret payment gateway bootstrap.  All rows remain inactive until the
-- merchant has completed the documented sandbox checks.
insert into public.payment_gateways (
  slug, active, endpoint, provider_currency, exchange_rate,
  min_provider_amount, config, secret_name
) values (
  'fapshi', false, 'https://sandbox.fapshi.com', 'XAF', 1, 100,
  '{"api":{"requestPath":"/direct-pay","checkPath":"/payment-status"},"environment":"sandbox","checkout":"direct-pay"}'::jsonb,
  'PAYMENT_SECRETS'
) on conflict (slug) do update set
  endpoint = excluded.endpoint,
  provider_currency = excluded.provider_currency,
  min_provider_amount = excluded.min_provider_amount,
  config = public.payment_gateways.config || excluded.config,
  secret_name = excluded.secret_name,
  updated_at = now();

-- `exchange_rate=1` is a deliberately inactive placeholder. Set the current
-- USD-to-XAF rate in Table Editor before enabling Fapshi; never enable a row
-- with this placeholder value.


-- ===== 20261010112000_seed_transfluo_gateway.sql =====

-- Seed Transfluo using the existing adapter's documented API contract.
-- Keep inactive until the exchange rate and sandbox flow are verified.

insert into public.payment_gateways (
  slug,
  active,
  endpoint,
  provider_currency,
  exchange_rate,
  min_provider_amount,
  config,
  secret_name
)
values (
  'transfluo',
  false,
  'https://direct-api.transfluo.com',
  'XAF',
  1,
  2,
  '{"api":{"requestPath":"/requestPayment.php","checkPath":"/checkStatus.php"}}'::jsonb,
  'PAYMENT_SECRETS'
)
on conflict (slug) do update set
  endpoint = excluded.endpoint,
  provider_currency = excluded.provider_currency,
  min_provider_amount = excluded.min_provider_amount,
  config = public.payment_gateways.config || excluded.config,
  secret_name = excluded.secret_name,
  updated_at = now();

-- exchange_rate=1 is only a placeholder.
-- Verify the amount conversion convention and configure the approved
-- USD-to-XAF rate before enabling Transfluo, if the wallet uses USD.

