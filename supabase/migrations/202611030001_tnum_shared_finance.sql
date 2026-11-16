-- Move T-NUM financial movements onto VT-NUM's wallet and central ledger.
-- Existing T-NUM holds remain as activation-level state metadata. The old
-- T-NUM ledger is copied and retained under an archive name for audit.

alter table public.wallet_ledger_entries
  add column source_system text,
  add column source_operation_id uuid;

alter table public.wallet_ledger_entries
  drop constraint if exists wallet_ledger_entries_check;

alter table public.wallet_ledger_entries
  add constraint wallet_ledger_entries_reference_check check (
    order_id is not null
    or payment_intent_id is not null
    or (source_system is not null and source_operation_id is not null)
  );

alter table public.wallet_ledger_entries
  add constraint wallet_ledger_entries_source_activation_fk
  foreign key (source_operation_id)
  references public.tnum_activations(id) on delete restrict;

create unique index wallet_ledger_source_idempotency
  on public.wallet_ledger_entries(source_system, source_operation_id, entry_type)
  where source_system is not null and source_operation_id is not null;

-- Pricing calculation is shared with VT-NUM's activation rule, including its
-- activation-only fixed fee. T-NUM stores the accepted customer total in cents.
create or replace function public.calculate_activation_customer_price(
  p_provider_price numeric
)
returns table(customer_price numeric, markup_type text, markup_value numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  rule public.pricing_rules;
begin
  if p_provider_price is null or p_provider_price <= 0 then
    raise exception 'INVALID_ACTIVATION_PRICE';
  end if;

  select * into rule from public.pricing_rules where active for share;
  if not found then raise exception 'PRICING_UNAVAILABLE'; end if;

  customer_price := round((case
    when rule.markup_type = 'percentage'
      then p_provider_price * (1 + rule.markup_value / 100)
    else p_provider_price + rule.markup_value
  end) + rule.activation_extra_fee, 2);
  if customer_price <= 0 then raise exception 'INVALID_CUSTOMER_PRICE'; end if;
  markup_type := rule.markup_type;
  markup_value := rule.markup_value;
  return next;
end;
$$;

revoke all on function public.calculate_activation_customer_price(numeric)
  from public, anon, authenticated;
grant execute on function public.calculate_activation_customer_price(numeric)
  to service_role;

create or replace function public.calculate_activation_customer_prices(
  p_provider_prices numeric[]
)
returns table(provider_price numeric, customer_price numeric)
language plpgsql
security definer
set search_path = public
as $$
declare rule public.pricing_rules;
begin
  select * into rule from public.pricing_rules where active for share;
  if not found then raise exception 'PRICING_UNAVAILABLE'; end if;
  return query
  select price,
    round((case when rule.markup_type = 'percentage'
      then price * (1 + rule.markup_value / 100)
      else price + rule.markup_value end) + rule.activation_extra_fee, 2)
  from unnest(p_provider_prices) with ordinality as source(price, position)
  order by position;
end;
$$;
revoke all on function public.calculate_activation_customer_prices(numeric[])
  from public, anon, authenticated;
grant execute on function public.calculate_activation_customer_prices(numeric[])
  to service_role;

-- Only the new quote-aware reservation entry point remains callable by the
-- server. The old overload wrote to the replaced T-NUM ledger table.
drop function if exists public.tnum_reserve_activation(uuid, uuid, text, integer, bigint);

create table public.tnum_activation_quotes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete restrict,
  service_slug text not null references public.tnum_services(slug) on delete restrict,
  country_code integer not null references public.tnum_countries(code) on delete restrict,
  provider_price_cents bigint not null check (provider_price_cents > 0),
  customer_price_cents bigint not null check (customer_price_cents > 0),
  markup_type text not null check (markup_type in ('percentage', 'fixed')),
  markup_value numeric(20,6) not null,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);
create index tnum_activation_quotes_owner_recent
  on public.tnum_activation_quotes(user_id, created_at desc);
alter table public.tnum_activation_quotes enable row level security;
revoke all on public.tnum_activation_quotes from anon, authenticated;

alter table public.tnum_activations
  add column accepted_quote_id uuid references public.tnum_activation_quotes(id) on delete restrict;

alter table public.tnum_provider_worker_state
  add column lease_id uuid,
  add column lease_expires_at timestamptz;

-- T-NUM keeps operational limits and polling cadence here. Its legacy markup
-- columns remain for audit but are no longer read by any purchase path.
alter table public.tnum_pricing_rules rename to tnum_runtime_config;
comment on column public.tnum_runtime_config.markup_bps is
  'Deprecated. T-NUM customer prices use public.pricing_rules.';
comment on column public.tnum_runtime_config.fixed_fee_cents is
  'Deprecated. T-NUM customer prices use public.pricing_rules.';
comment on column public.tnum_runtime_config.currency is
  'Deprecated. T-NUM uses the shared public.wallets currency.';

drop function public.tnum_claim_provider_worker();
create function public.tnum_claim_provider_worker()
returns uuid language plpgsql security definer set search_path = public as $$
declare poll_seconds integer; claimed_lease uuid := gen_random_uuid();
begin
  select provider_poll_seconds into poll_seconds
    from public.tnum_runtime_config where id = true;
  update public.tnum_provider_worker_state
    set last_started_at = now(), lease_id = claimed_lease,
        lease_expires_at = now() + interval '30 minutes'
    where id = true
      and (lease_id is null or lease_expires_at <= now())
      and (last_started_at is null or
        last_started_at <= now() - make_interval(secs => poll_seconds));
  if not found then return null; end if;
  return claimed_lease;
end;
$$;

create or replace function public.tnum_release_provider_worker(p_lease uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update public.tnum_provider_worker_state
    set lease_id = null, lease_expires_at = null
    where id = true and lease_id = p_lease;
  return found;
end;
$$;

revoke all on function public.tnum_claim_provider_worker() from public, anon, authenticated;
revoke all on function public.tnum_release_provider_worker(uuid) from public, anon, authenticated;
grant execute on function public.tnum_claim_provider_worker() to service_role;
grant execute on function public.tnum_release_provider_worker(uuid) to service_role;

-- Preserve historical rows before replacing the old ledger table with a
-- read-only compatibility view over the central ledger.
insert into public.wallet_ledger_entries (
  user_id, source_system, source_operation_id, entry_type, amount, currency,
  metadata, idempotency_key, created_at
)
select l.user_id, 'T-NUM', l.activation_id,
  case l.kind
    when 'reserve' then 'HOLD'::public.wallet_entry_type
    when 'capture' then 'CAPTURE_HOLD'::public.wallet_entry_type
    when 'release' then 'RELEASE_HOLD'::public.wallet_entry_type
    else 'ADJUSTMENT'::public.wallet_entry_type
  end,
  l.amount_cents::numeric / 100, 'USD',
  jsonb_build_object('origin', 'T-NUM', 'legacy_kind', l.kind),
  l.idempotency_key, l.created_at
from public.tnum_wallet_ledger l
where l.activation_id is not null
on conflict (idempotency_key) do nothing;

alter table public.tnum_wallet_ledger rename to tnum_wallet_ledger_legacy;
drop policy if exists tnum_own_ledger_read on public.tnum_wallet_ledger_legacy;
revoke all on public.tnum_wallet_ledger_legacy from anon, authenticated;

create view public.tnum_wallet_ledger
with (security_invoker = true)
as
select id, user_id, source_operation_id as activation_id,
  case entry_type
    when 'HOLD' then 'reserve'
    when 'CAPTURE_HOLD' then 'capture'
    when 'RELEASE_HOLD' then 'release'
    else 'credit'
  end::text as kind,
  round(amount * 100)::bigint as amount_cents,
  idempotency_key, created_at
from public.wallet_ledger_entries
where source_system = 'T-NUM';
grant select on public.tnum_wallet_ledger to authenticated, service_role;

-- One atomic wallet movement primitive is shared by VT-NUM orders and T-NUM
-- activations; product-specific hold rows remain in their own domains.
create or replace function public.apply_shared_wallet_operation(
  p_user uuid, p_order uuid, p_source_system text, p_source_operation uuid,
  p_amount numeric, p_operation text, p_idempotency_key text
)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  w public.wallets;
  existing public.wallet_ledger_entries;
  entry_type public.wallet_entry_type;
  balance_before numeric(20,6);
  balance_after numeric(20,6);
begin
  if p_user is null or p_amount is null or p_amount <= 0
     or p_idempotency_key is null or length(p_idempotency_key) > 200
     or p_source_system not in ('VT-NUM', 'T-NUM')
     or (p_source_system = 'VT-NUM' and (p_order is null or p_source_operation is not null))
     or (p_source_system = 'T-NUM' and (p_order is not null or p_source_operation is null))
     or p_operation not in ('HOLD', 'RELEASE', 'CAPTURE') then
    raise exception 'INVALID_WALLET_OPERATION';
  end if;

  entry_type := case p_operation
    when 'HOLD' then 'HOLD'::public.wallet_entry_type
    when 'RELEASE' then 'RELEASE_HOLD'::public.wallet_entry_type
    else 'CAPTURE_HOLD'::public.wallet_entry_type
  end;

  select * into existing from public.wallet_ledger_entries
    where idempotency_key = p_idempotency_key;
  if found then
    if existing.user_id <> p_user or existing.order_id is distinct from p_order
       or existing.source_system is distinct from p_source_system
       or existing.source_operation_id is distinct from p_source_operation
       or existing.entry_type <> entry_type or existing.amount <> p_amount then
      raise exception 'IDEMPOTENCY_KEY_REUSED';
    end if;
    return false;
  end if;

  select * into w from public.wallets where user_id = p_user for update;
  if not found then raise exception 'WALLET_NOT_FOUND'; end if;
  if w.currency <> 'USD' then raise exception 'UNSUPPORTED_WALLET_CURRENCY'; end if;

  -- Serialize duplicate operations on the common wallet row.
  select * into existing from public.wallet_ledger_entries
    where idempotency_key = p_idempotency_key;
  if found then
    if existing.user_id <> p_user or existing.order_id is distinct from p_order
       or existing.source_system is distinct from p_source_system
       or existing.source_operation_id is distinct from p_source_operation
       or existing.entry_type <> entry_type or existing.amount <> p_amount then
      raise exception 'IDEMPOTENCY_KEY_REUSED';
    end if;
    return false;
  end if;

  balance_before := w.available_balance;
  balance_after := balance_before;
  if p_operation = 'HOLD' then
    if w.available_balance < p_amount then raise exception 'INSUFFICIENT_BALANCE'; end if;
    balance_after := balance_before - p_amount;
    update public.wallets set available_balance = balance_after,
      held_balance = held_balance + p_amount, updated_at = now()
      where user_id = p_user;
  elsif p_operation = 'RELEASE' then
    if w.held_balance < p_amount then raise exception 'WALLET_INVARIANT'; end if;
    balance_after := balance_before + p_amount;
    update public.wallets set available_balance = balance_after,
      held_balance = held_balance - p_amount, updated_at = now()
      where user_id = p_user;
  else
    if w.held_balance < p_amount then raise exception 'WALLET_INVARIANT'; end if;
    update public.wallets set held_balance = held_balance - p_amount,
      updated_at = now() where user_id = p_user;
  end if;

  insert into public.wallet_ledger_entries (
    user_id, order_id, source_system, source_operation_id, entry_type,
    amount, currency, balance_before, balance_after, metadata, idempotency_key
  ) values (
    p_user, p_order, p_source_system, p_source_operation, entry_type,
    p_amount, 'USD', balance_before, balance_after,
    jsonb_build_object('origin', p_source_system, 'operation', lower(p_operation)),
    p_idempotency_key
  );
  return true;
end;
$$;

revoke all on function public.apply_shared_wallet_operation(uuid,uuid,text,uuid,numeric,text,text)
  from public, anon, authenticated;
grant execute on function public.apply_shared_wallet_operation(uuid,uuid,text,uuid,numeric,text,text)
  to service_role;

create or replace function public.create_wallet_hold(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare order_row public.orders;
begin
  select * into order_row from public.orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if exists (select 1 from public.wallet_holds where order_id = p_order_id) then return; end if;
  if order_row.customer_price is null or order_row.currency <> 'USD' then
    raise exception 'INVALID_ORDER_AMOUNT';
  end if;
  perform public.apply_shared_wallet_operation(order_row.user_id, p_order_id,
    'VT-NUM', null, order_row.customer_price, 'HOLD', 'hold:' || p_order_id);
  insert into public.wallet_holds(order_id, user_id, amount, currency)
    values (p_order_id, order_row.user_id, order_row.customer_price, 'USD');
end;
$$;

create or replace function public.release_wallet_hold(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare hold_row public.wallet_holds;
begin
  select * into hold_row from public.wallet_holds where order_id = p_order_id for update;
  if not found then raise exception 'HOLD_NOT_FOUND'; end if;
  if hold_row.status = 'RELEASED' then return; end if;
  if hold_row.status = 'CAPTURED' then raise exception 'HOLD_ALREADY_CAPTURED'; end if;
  perform public.apply_shared_wallet_operation(hold_row.user_id, p_order_id,
    'VT-NUM', null, hold_row.amount, 'RELEASE', 'release:' || p_order_id);
  update public.wallet_holds set status = 'RELEASED', released_at = now()
    where id = hold_row.id;
end;
$$;

create or replace function public.capture_wallet_hold(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare hold_row public.wallet_holds;
begin
  select * into hold_row from public.wallet_holds where order_id = p_order_id for update;
  if not found then raise exception 'HOLD_NOT_FOUND'; end if;
  if hold_row.status = 'CAPTURED' then return; end if;
  if hold_row.status = 'RELEASED' then raise exception 'HOLD_ALREADY_RELEASED'; end if;
  perform public.apply_shared_wallet_operation(hold_row.user_id, p_order_id,
    'VT-NUM', null, hold_row.amount, 'CAPTURE', 'capture:' || p_order_id);
  update public.wallet_holds set status = 'CAPTURED', captured_at = now()
    where id = hold_row.id;
end;
$$;

create or replace function public.assign_activation_and_create_hold(
  p_order_id uuid, p_provider_id uuid, p_provider_activation_id text,
  p_phone_number text, p_provider_price numeric, p_currency char(3),
  p_service_code text, p_service_name text, p_country_code text,
  p_country_name text, p_country_flag text, p_expires_at timestamptz
)
returns table(customer_price numeric, markup_type text, markup_value numeric)
language plpgsql security definer set search_path = public as $$
declare order_row public.orders; rule public.pricing_rules; customer numeric(20,6);
begin
  if p_provider_price <= 0 or p_currency <> 'USD' or p_expires_at <= now() then
    raise exception 'INVALID_ACTIVATION_PRICE';
  end if;
  select * into order_row from public.orders where id = p_order_id for update;
  if not found or order_row.status not in ('CREATED', 'PROVIDER_REQUESTING') then
    raise exception 'ORDER_NOT_ASSIGNABLE';
  end if;
  select * into rule from public.pricing_rules where active for update;
  if not found then raise exception 'PRICING_UNAVAILABLE'; end if;
  customer := round((case when rule.markup_type = 'percentage'
    then p_provider_price * (1 + rule.markup_value / 100)
    else p_provider_price + rule.markup_value end) + rule.activation_extra_fee, 6);
  if customer <= 0 then raise exception 'INVALID_CUSTOMER_PRICE'; end if;

  update public.orders set provider_id = p_provider_id,
    provider_activation_id = p_provider_activation_id, phone_number = p_phone_number,
    provider_price = round(p_provider_price, 6), markup_type = rule.markup_type,
    markup_value = rule.markup_value,
    markup_percentage = case when rule.markup_type = 'percentage' then rule.markup_value else 0 end,
    customer_price = customer, currency = p_currency, service_code = p_service_code,
    service_name = p_service_name, country_code = p_country_code,
    country_name = p_country_name, country_flag = coalesce(p_country_flag, ''),
    assigned_at = now(), expires_at = p_expires_at, status = 'WAITING_FOR_SMS',
    financial_status = 'HOLDING', next_monitor_at = now(), monitor_failures = 0,
    last_monitor_error = null
    where id = p_order_id;
  perform public.apply_shared_wallet_operation(order_row.user_id, p_order_id,
    'VT-NUM', null, customer, 'HOLD', 'hold:' || p_order_id);
  insert into public.wallet_holds(order_id, user_id, amount, currency)
    values (p_order_id, order_row.user_id, customer, 'USD');

  customer_price := customer;
  markup_type := rule.markup_type;
  markup_value := rule.markup_value;
  return next;
end;
$$;

revoke all on function public.create_wallet_hold(uuid), public.release_wallet_hold(uuid),
  public.capture_wallet_hold(uuid),
  public.assign_activation_and_create_hold(uuid,uuid,text,text,numeric,char,text,text,text,text,text,timestamptz)
  from public, anon, authenticated;
grant execute on function public.create_wallet_hold(uuid), public.release_wallet_hold(uuid),
  public.capture_wallet_hold(uuid),
  public.assign_activation_and_create_hold(uuid,uuid,text,text,numeric,char,text,text,text,text,text,timestamptz)
  to service_role;

-- A T-NUM hold row is lifecycle metadata, not a second financial ledger.
-- The wallet and central ledger change atomically with this metadata.
create or replace function public.tnum_reserve_activation(
  p_user uuid,
  p_key uuid,
  p_service text,
  p_country integer,
  p_provider_cents bigint,
  p_quote uuid
)
returns public.tnum_activations
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  quote public.tnum_activation_quotes;
  activation public.tnum_activations;
  calculated record;
  amount_cents bigint;
  amount numeric(20,6);
begin
  if p_user is null or p_key is null or p_quote is null
     or p_service is null or p_country is null or p_provider_cents <= 0 then
    raise exception 'INVALID_ACTIVATION_REQUEST';
  end if;

  select * into activation from public.tnum_activations
   where user_id = p_user and idempotency_key = p_key;
  if found then return activation; end if;

  select * into quote from public.tnum_activation_quotes
   where id = p_quote and user_id = p_user and service_slug = p_service
     and country_code = p_country and consumed_at is null and expires_at > now()
   for update;
  if not found then raise exception 'QUOTE_EXPIRED'; end if;
  if quote.provider_price_cents <> p_provider_cents then
    raise exception 'PRICE_CHANGED';
  end if;

  select * into calculated from public.calculate_activation_customer_price(
    p_provider_cents::numeric / 100
  );
  amount_cents := round(calculated.customer_price * 100)::bigint;
  if quote.customer_price_cents <> amount_cents then
    raise exception 'PRICE_CHANGED';
  end if;
  amount := amount_cents::numeric / 100;

  if not exists (
    select 1 from public.tnum_service_country_catalog
    where service_slug = p_service and country_code = p_country
      and available_count > 0
      and round(provider_price * 100)::bigint = p_provider_cents
  ) then raise exception 'CATALOG_UNAVAILABLE'; end if;

  if (select count(*) from public.tnum_activations where user_id = p_user
      and status not in ('completed', 'expired', 'cancelled', 'failed')) >= 10 then
    raise exception 'ACTIVATION_LIMIT';
  end if;

  insert into public.tnum_activations (
    user_id, idempotency_key, service_slug, country_code, status,
    provider_price_cents, customer_price_cents, pricing_markup_bps,
    pricing_fee_cents, deadline_at, accepted_quote_id
  ) values (
    p_user, p_key, p_service, p_country, 'purchase_pending', p_provider_cents,
    amount_cents,
    case when calculated.markup_type = 'percentage'
      then round(calculated.markup_value * 100)::integer else 0 end,
    round((calculated.customer_price - (p_provider_cents::numeric / 100) *
      (case when calculated.markup_type = 'percentage'
        then 1 + calculated.markup_value / 100 else 1 end)) * 100)::bigint,
    now() + interval '6 minutes', p_quote
  ) returning * into activation;

  insert into public.tnum_wallet_holds(activation_id, user_id, amount_cents, status)
    values (activation.id, p_user, amount_cents, 'held');

  perform public.apply_shared_wallet_operation(p_user, null, 'T-NUM', activation.id,
    amount, 'HOLD', 'tnum:reserve:' || activation.id::text);

  update public.tnum_activation_quotes set consumed_at = now() where id = p_quote;
  insert into public.tnum_activation_status_events(activation_id, to_status)
    values (activation.id, 'purchase_pending');
  insert into public.tnum_provider_operations(activation_id, operation, state)
    values (activation.id, 'purchase', 'queued');
  return activation;
end;
$$;

create or replace function public.tnum_release_activation_reservation(p_activation uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare a public.tnum_activations; h public.tnum_wallet_holds;
  amount numeric(20,6);
begin
  select * into a from public.tnum_activations where id = p_activation for update;
  if not found then return false; end if;
  select * into h from public.tnum_wallet_holds where activation_id = p_activation for update;
  if not found or h.status <> 'held' then return false; end if;
  if exists (select 1 from public.tnum_activation_sms where activation_id = p_activation)
    then raise exception 'SMS_ALREADY_RECEIVED'; end if;
  amount := h.amount_cents::numeric / 100;
  perform public.apply_shared_wallet_operation(h.user_id, null, 'T-NUM', a.id,
    amount, 'RELEASE', 'tnum:release:' || a.id::text);
  update public.tnum_wallet_holds set status = 'released', released_at = now()
    where activation_id = p_activation and status = 'held';
  return true;
end;
$$;

create or replace function public.tnum_capture_activation_reservation(p_activation uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare a public.tnum_activations; h public.tnum_wallet_holds;
  amount numeric(20,6);
begin
  select * into a from public.tnum_activations where id = p_activation for update;
  if not found then return false; end if;
  select * into h from public.tnum_wallet_holds where activation_id = p_activation for update;
  if not found or h.status <> 'held' then return false; end if;
  amount := h.amount_cents::numeric / 100;
  perform public.apply_shared_wallet_operation(h.user_id, null, 'T-NUM', a.id,
    amount, 'CAPTURE', 'tnum:capture:' || a.id::text);
  update public.tnum_wallet_holds set status = 'captured', captured_at = now()
    where activation_id = p_activation and status = 'held';
  return true;
end;
$$;

create or replace function public.tnum_finalize_activation_cancellation(p_activation uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare a public.tnum_activations; finalized boolean;
begin
  select * into a from public.tnum_activations where id = p_activation for update;
  if not found then return false; end if;
  if exists (select 1 from public.tnum_activation_sms where activation_id = p_activation) then
    update public.tnum_activations set status = 'sms_received',
      cancellation_state = 'uncertain', next_retry_at = null
      where id = p_activation and status = 'expiration_pending';
    return false;
  end if;
  if a.status <> 'expiration_pending' or a.cancellation_state <> 'pending' then return false; end if;

  -- The worker calls this only after an explicit successful close response or
  -- a targeted provider lookup that conclusively reports a terminal operation.
  select public.tnum_release_activation_reservation(p_activation) into finalized;
  if finalized is not true then return false; end if;
  update public.tnum_activations set status = 'expired', cancellation_state = 'confirmed',
    provider_terminal_at = now(), next_retry_at = null, failure_code = null
    where id = p_activation;
  update public.tnum_provider_operations set operation = 'close', state = 'confirmed',
    next_attempt_at = null, last_error_code = null, updated_at = now()
    where activation_id = p_activation;
  return true;
end;
$$;

create or replace function public.tnum_fail_activation_and_release(
  p_activation uuid,
  p_failure_code text
)
returns boolean language plpgsql security definer set search_path = public as $$
declare a public.tnum_activations; released boolean;
begin
  select * into a from public.tnum_activations where id = p_activation for update;
  if not found then return false; end if;
  if a.status in ('failed', 'expired', 'cancelled', 'completed') then return false; end if;
  if exists (select 1 from public.tnum_activation_sms where activation_id = p_activation)
    then raise exception 'SMS_ALREADY_RECEIVED'; end if;
  select public.tnum_release_activation_reservation(p_activation) into released;
  if released is not true then raise exception 'RESERVATION_NOT_RELEASED'; end if;
  update public.tnum_activations set status = 'failed',
    failure_code = left(p_failure_code, 100), provider_terminal_at = now()
    where id = p_activation;
  update public.tnum_provider_operations set state = 'failed',
    last_error_code = left(p_failure_code, 100), updated_at = now()
    where activation_id = p_activation;
  return true;
end;
$$;

revoke all on function public.tnum_reserve_activation(uuid,uuid,text,integer,bigint,uuid),
  public.tnum_release_activation_reservation(uuid),
  public.tnum_capture_activation_reservation(uuid),
  public.tnum_finalize_activation_cancellation(uuid),
  public.tnum_fail_activation_and_release(uuid,text)
  from public, anon, authenticated;
grant execute on function public.tnum_reserve_activation(uuid,uuid,text,integer,bigint,uuid),
  public.tnum_release_activation_reservation(uuid),
  public.tnum_capture_activation_reservation(uuid),
  public.tnum_finalize_activation_cancellation(uuid),
  public.tnum_fail_activation_and_release(uuid,text) to service_role;
grant execute on function public.tnum_claim_provider_worker() to service_role;

