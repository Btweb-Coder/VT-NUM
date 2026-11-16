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
