
-- T-NUM initial schema.
-- Reuses vt-num authentication and public.wallets.
-- All T-NUM prices and ledger amounts are integer USD cents.
-- Existing Server 1 orders, payments, wallet holds, and ledger remain intact.

create extension if not exists pgcrypto with schema extensions;

create type public.tnum_activation_status as enum (
    'reserved',
    'purchase_pending',
    'provider_outcome_uncertain',
    'active',
    'sms_received',
    'completion_pending',
    'completed',
    'expiration_pending',
    'expired',
    'cancelled',
    'failed'
);

-- T-NUM-specific financial reservation record.
-- The actual wallet balance remains in public.wallets.
create table public.tnum_wallet_holds (
    activation_id uuid primary key,
    user_id uuid not null references public.profiles(user_id) on delete restrict,
    amount_cents bigint not null check (amount_cents > 0),
    status text not null default 'held'
        check (status in ('held', 'captured', 'released')),
    created_at timestamptz not null default now(),
    captured_at timestamptz,
    released_at timestamptz
);

-- T-NUM-specific audit trail. This is not a second wallet balance.
create table public.tnum_wallet_ledger (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.profiles(user_id) on delete restrict,
    activation_id uuid,
    kind text not null check (kind in ('credit', 'reserve', 'capture', 'release')),
    amount_cents bigint not null check (amount_cents > 0),
    idempotency_key text not null unique,
    created_at timestamptz not null default now()
);

create table public.tnum_pricing_rules (
    id boolean primary key default true check (id),
    markup_bps integer not null default 5000
        check (markup_bps between 0 and 100000),
    fixed_fee_cents bigint not null default 200
        check (fixed_fee_cents >= 0),
    currency text not null default 'USD' check (currency = 'USD'),
    activation_timeout_seconds integer not null default 360
        check (activation_timeout_seconds between 60 and 3600),
    max_active_activations integer not null default 10
        check (max_active_activations between 1 and 10),
    client_poll_seconds integer not null default 5
        check (client_poll_seconds between 3 and 60),
    provider_poll_seconds integer not null default 60
        check (provider_poll_seconds between 60 and 300),
    updated_at timestamptz not null default now()
);

insert into public.tnum_pricing_rules(id)
values (true)
on conflict do nothing;

create table public.tnum_services (
    slug text primary key,
    provider_id integer,
    name text not null,
    refreshed_at timestamptz not null default now()
);

create table public.tnum_countries (
    code integer primary key,
    name text not null,
    original text,
    enabled boolean not null default true,
    refreshed_at timestamptz not null default now()
);

create table public.tnum_service_country_catalog (
    service_slug text not null
        references public.tnum_services(slug) on delete cascade,
    country_code integer not null
        references public.tnum_countries(code) on delete cascade,
    provider_price numeric(12,4) not null check (provider_price >= 0),
    available_count integer not null default 0 check (available_count >= 0),
    refreshed_at timestamptz not null default now(),
    primary key (service_slug, country_code)
);

create table public.tnum_activations (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.profiles(user_id) on delete restrict,
    idempotency_key uuid not null,
    service_slug text not null references public.tnum_services(slug),
    country_code integer not null references public.tnum_countries(code),
    status public.tnum_activation_status not null default 'reserved',
    provider_operation_id bigint unique,
    provider_status text,
    phone_number text,
    provider_price_cents bigint not null check (provider_price_cents >= 0),
    customer_price_cents bigint not null check (customer_price_cents > 0),
    pricing_markup_bps integer not null,
    pricing_fee_cents bigint not null,
    created_at timestamptz not null default now(),
    provider_requested_at timestamptz,
    deadline_at timestamptz not null,
    provider_terminal_at timestamptz,
    completed_at timestamptz,
    cancellation_state text not null default 'not_requested'
        check (cancellation_state in (
            'not_requested',
            'pending',
            'retry',
            'confirmed',
            'not_supported',
            'uncertain'
        )),
    cancellation_attempts integer not null default 0,
    next_retry_at timestamptz,
    last_provider_check_at timestamptz,
    last_revise_at timestamptz,
    failure_code text,
    failure_message text,
    unique (user_id, idempotency_key)
);

alter table public.tnum_wallet_holds
    add constraint tnum_wallet_holds_activation_fk
    foreign key (activation_id)
    references public.tnum_activations(id)
    on delete restrict;

alter table public.tnum_wallet_ledger
    add constraint tnum_wallet_ledger_activation_fk
    foreign key (activation_id)
    references public.tnum_activations(id)
    on delete restrict;

create table public.tnum_activation_sms (
    id uuid primary key default gen_random_uuid(),
    activation_id uuid not null
        references public.tnum_activations(id) on delete restrict,
    provider_message_key text not null,
    message_text text not null,
    code text,
    received_at timestamptz not null default now(),
    unique (activation_id, provider_message_key)
);

create table public.tnum_activation_status_events (
    id bigint generated always as identity primary key,
    activation_id uuid not null
        references public.tnum_activations(id) on delete restrict,
    from_status public.tnum_activation_status,
    to_status public.tnum_activation_status not null,
    detail_code text,
    created_at timestamptz not null default now()
);

create table public.tnum_provider_operations (
    id bigint generated always as identity primary key,
    activation_id uuid not null unique
        references public.tnum_activations(id) on delete restrict,
    operation text not null check (operation in ('purchase', 'poll', 'close')),
    state text not null,
    attempts integer not null default 0,
    next_attempt_at timestamptz,
    last_error_code text,
    updated_at timestamptz not null default now()
);

create table public.tnum_provider_worker_state (
    id boolean primary key default true check (id),
    last_started_at timestamptz
);

insert into public.tnum_provider_worker_state(id, last_started_at)
values (true, null)
on conflict do nothing;

create index tnum_activations_user_recent
    on public.tnum_activations(user_id, created_at desc);

create index tnum_activations_deadlines
    on public.tnum_activations(deadline_at)
    where status in (
        'purchase_pending',
        'provider_outcome_uncertain',
        'active',
        'sms_received',
        'completion_pending',
        'expiration_pending'
    );

create index tnum_provider_operations_retry
    on public.tnum_provider_operations(next_attempt_at)
    where next_attempt_at is not null;

create index tnum_activation_sms_activation
    on public.tnum_activation_sms(activation_id, received_at);

create index tnum_activation_status_events_activation
    on public.tnum_activation_status_events(activation_id, created_at);

create index tnum_wallet_ledger_user_recent
    on public.tnum_wallet_ledger(user_id, created_at desc);

-- Reserve funds in the existing vt-num wallet.
-- public.wallets stores dollar amounts; T-NUM prices are cents.
create or replace function public.tnum_reserve_activation(
    p_user uuid,
    p_key uuid,
    p_service text,
    p_country integer,
    p_provider_cents bigint
)
returns public.tnum_activations
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    w public.wallets;
    rule public.tnum_pricing_rules;
    a public.tnum_activations;
    price bigint;
    price_usd numeric(20,6);
begin
    if p_user is null
       or p_key is null
       or p_service is null
       or p_country is null
       or p_provider_cents is null
       or p_provider_cents < 0 then
        raise exception 'INVALID_ACTIVATION_REQUEST';
    end if;

    -- Idempotent retry: do not reserve the same activation twice.
    select *
    into a
    from public.tnum_activations
    where user_id = p_user
      and idempotency_key = p_key;

    if found then
        return a;
    end if;

    select *
    into rule
    from public.tnum_pricing_rules
    where id = true
    for share;

    if not found then
        raise exception 'PRICING_RULES_UNAVAILABLE';
    end if;

    if not exists (
        select 1
        from public.tnum_service_country_catalog
        where service_slug = p_service
          and country_code = p_country
          and available_count > 0
          and provider_price > 0
          and round(provider_price * 100)::bigint = p_provider_cents
    ) then
        raise exception 'CATALOG_UNAVAILABLE';
    end if;

    price := (
        (
            p_provider_cents::numeric * (10000 + rule.markup_bps) + 5000
        ) / 10000
    )::bigint + rule.fixed_fee_cents;

    price_usd := price::numeric / 100;

    -- Serialize purchases for this account through the shared wallet row.
    select *
    into w
    from public.wallets
    where user_id = p_user
    for update;

    if not found then
        raise exception 'WALLET_NOT_INITIALIZED';
    end if;

    if w.currency <> 'USD' then
        raise exception 'UNSUPPORTED_WALLET_CURRENCY';
    end if;

    -- Recheck idempotency after acquiring the wallet lock.
    select *
    into a
    from public.tnum_activations
    where user_id = p_user
      and idempotency_key = p_key;

    if found then
        return a;
    end if;

    if round(w.available_balance * 100)::bigint < price then
        raise exception 'INSUFFICIENT_FUNDS';
    end if;

    if (
        select count(*)
        from public.tnum_activations
        where user_id = p_user
          and status not in ('completed', 'expired', 'cancelled', 'failed')
    ) >= rule.max_active_activations then
        raise exception 'ACTIVATION_LIMIT';
    end if;

    insert into public.tnum_activations (
        user_id,
        idempotency_key,
        service_slug,
        country_code,
        status,
        provider_price_cents,
        customer_price_cents,
        pricing_markup_bps,
        pricing_fee_cents,
        deadline_at
    )
    values (
        p_user,
        p_key,
        p_service,
        p_country,
        'purchase_pending',
        p_provider_cents,
        price,
        rule.markup_bps,
        rule.fixed_fee_cents,
        now() + make_interval(secs => rule.activation_timeout_seconds)
    )
    returning * into a;

    -- One row per activation, protected by the activation primary key.
    insert into public.tnum_wallet_holds (
        activation_id,
        user_id,
        amount_cents,
        status
    )
    values (
        a.id,
        p_user,
        price,
        'held'
    );

    update public.wallets
    set available_balance = available_balance - price_usd,
        held_balance = held_balance + price_usd,
        updated_at = now()
    where user_id = p_user
      and available_balance >= price_usd;

    if not found then
        raise exception 'INSUFFICIENT_FUNDS';
    end if;

    insert into public.tnum_wallet_ledger (
        user_id,
        activation_id,
        kind,
        amount_cents,
        idempotency_key
    )
    values (
        p_user,
        a.id,
        'reserve',
        price,
        'tnum:reserve:' || a.id::text
    );

    insert into public.tnum_activation_status_events (
        activation_id,
        to_status
    )
    values (a.id, 'purchase_pending');

    insert into public.tnum_provider_operations (
        activation_id,
        operation,
        state
    )
    values (a.id, 'purchase', 'queued');

    return a;
end;
$$;

create or replace function public.tnum_claim_purchase_quote(p_user uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    claimed uuid;
begin
    update public.wallets
    set updated_at = now()
    where user_id = p_user
      and (
          -- A separate T-NUM rate-limit timestamp is kept in the T-NUM table.
          not exists (
              select 1
              from public.tnum_activations a
              where a.user_id = p_user
                and a.created_at > now() - interval '2 seconds'
          )
      )
    returning user_id into claimed;

    return claimed is not null;
end;
$$;

create or replace function public.tnum_claim_activation_purchase(p_activation uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    claimed uuid;
begin
    update public.tnum_provider_operations
    set state = 'requesting',
        attempts = attempts + 1,
        updated_at = now()
    where activation_id = p_activation
      and operation = 'purchase'
      and state = 'queued'
    returning activation_id into claimed;

    if claimed is null then
        return false;
    end if;

    update public.tnum_activations
    set provider_requested_at = now()
    where id = p_activation
      and status = 'purchase_pending';

    return found;
end;
$$;

create or replace function public.tnum_claim_sms_revise(p_activation uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    claimed uuid;
begin
    update public.tnum_activations
    set last_revise_at = now()
    where id = p_activation
      and status = 'sms_received'
      and provider_operation_id is not null
      and (
          last_revise_at is null
          or last_revise_at < now() - interval '30 seconds'
      )
    returning id into claimed;

    return claimed is not null;
end;
$$;

create or replace function public.tnum_claim_activation_completion(p_activation uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    claimed uuid;
begin
    update public.tnum_activations
    set status = 'completion_pending'
    where id = p_activation
      and status = 'sms_received'
      and exists (
          select 1
          from public.tnum_activation_sms
          where activation_id = p_activation
      )
    returning id into claimed;

    if claimed is null then
        return false;
    end if;

    update public.tnum_provider_operations
    set operation = 'close',
        state = 'sending',
        updated_at = now()
    where activation_id = p_activation;

    return true;
end;
$$;

-- Release funds only when called by the trusted backend after the relevant
-- provider/cancellation checks have been performed.
create or replace function public.tnum_release_activation_reservation(
    p_activation uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    a public.tnum_activations;
    h public.tnum_wallet_holds;
    price_usd numeric(20,6);
begin
    select *
    into a
    from public.tnum_activations
    where id = p_activation
    for update;

    if not found then
        return false;
    end if;

    select *
    into h
    from public.tnum_wallet_holds
    where activation_id = p_activation
    for update;

    if not found or h.status <> 'held' then
        return false;
    end if;

    -- Never refund an activation for which an SMS was recorded.
    if exists (
        select 1
        from public.tnum_activation_sms
        where activation_id = p_activation
    ) then
        raise exception 'SMS_ALREADY_RECEIVED';
    end if;

    price_usd := h.amount_cents::numeric / 100;

    update public.wallets
    set available_balance = available_balance + price_usd,
        held_balance = held_balance - price_usd,
        updated_at = now()
    where user_id = h.user_id
      and held_balance >= price_usd;

    if not found then
        raise exception 'WALLET_INVARIANT';
    end if;

    update public.tnum_wallet_holds
    set status = 'released',
        released_at = now()
    where activation_id = p_activation
      and status = 'held';

    if not found then
        raise exception 'WALLET_HOLD_STATE_CHANGED';
    end if;

    insert into public.tnum_wallet_ledger (
        user_id,
        activation_id,
        kind,
        amount_cents,
        idempotency_key
    )
    values (
        h.user_id,
        a.id,
        'release',
        h.amount_cents,
        'tnum:release:' || a.id::text
    )
    on conflict (idempotency_key) do nothing;

    return true;
end;
$$;

create or replace function public.tnum_capture_activation_reservation(
    p_activation uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    a public.tnum_activations;
    h public.tnum_wallet_holds;
    price_usd numeric(20,6);
begin
    select *
    into a
    from public.tnum_activations
    where id = p_activation
    for update;

    if not found then
        return false;
    end if;

    select *
    into h
    from public.tnum_wallet_holds
    where activation_id = p_activation
    for update;

    if not found or h.status <> 'held' then
        return false;
    end if;

    price_usd := h.amount_cents::numeric / 100;

    update public.wallets
    set held_balance = held_balance - price_usd,
        updated_at = now()
    where user_id = h.user_id
      and held_balance >= price_usd;

    if not found then
        raise exception 'WALLET_INVARIANT';
    end if;

    update public.tnum_wallet_holds
    set status = 'captured',
        captured_at = now()
    where activation_id = p_activation
      and status = 'held';

    if not found then
        raise exception 'WALLET_HOLD_STATE_CHANGED';
    end if;

    insert into public.tnum_wallet_ledger (
        user_id,
        activation_id,
        kind,
        amount_cents,
        idempotency_key
    )
    values (
        h.user_id,
        a.id,
        'capture',
        h.amount_cents,
        'tnum:capture:' || a.id::text
    )
    on conflict (idempotency_key) do nothing;

    return true;
end;
$$;

create or replace function public.tnum_claim_provider_worker()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    poll_seconds integer;
    affected integer;
begin
    select provider_poll_seconds
    into poll_seconds
    from public.tnum_pricing_rules
    where id = true;

    update public.tnum_provider_worker_state
    set last_started_at = now()
    where id = true
      and (
          last_started_at is null
          or last_started_at <= now() - make_interval(secs => poll_seconds)
      );

    get diagnostics affected = row_count;

    return affected > 0;
end;
$$;

create or replace function public.tnum_prevent_ledger_mutation()
returns trigger
language plpgsql
as $$
begin
    raise exception 'WALLET_LEDGER_IMMUTABLE';
end;
$$;

create trigger tnum_wallet_ledger_immutable
before update or delete on public.tnum_wallet_ledger
for each row
execute function public.tnum_prevent_ledger_mutation();

create trigger tnum_wallet_holds_immutable_ledger_guard
before update or delete on public.tnum_wallet_ledger
for each row
execute function public.tnum_prevent_ledger_mutation();

create or replace function public.tnum_record_activation_status_event()
returns trigger
language plpgsql
as $$
begin
    if new.status is distinct from old.status then
        insert into public.tnum_activation_status_events (
            activation_id,
            from_status,
            to_status,
            detail_code
        )
        values (
            new.id,
            old.status,
            new.status,
            new.failure_code
        );
    end if;

    return new;
end;
$$;

create trigger tnum_activation_status_event
after update of status on public.tnum_activations
for each row
execute function public.tnum_record_activation_status_event();

create or replace function public.tnum_validate_activation_transition()
returns trigger
language plpgsql
as $$
begin
    if new.status = old.status then
        return new;
    end if;

    if old.status in ('completed', 'expired', 'cancelled', 'failed') then
        raise exception 'TERMINAL_ACTIVATION';
    end if;

    if not (
        (old.status = 'reserved'
            and new.status in ('purchase_pending', 'failed')) or
        (old.status = 'purchase_pending'
            and new.status in (
                'active',
                'provider_outcome_uncertain',
                'failed',
                'expiration_pending'
            )) or
        (old.status = 'provider_outcome_uncertain'
            and new.status in ('active', 'failed', 'expiration_pending')) or
        (old.status = 'active'
            and new.status in (
                'sms_received',
                'completion_pending',
                'completed',
                'expiration_pending'
            )) or
        (old.status = 'sms_received'
            and new.status in (
                'completion_pending',
                'completed',
                'expiration_pending'
            )) or
        (old.status = 'completion_pending'
            and new.status in (
                'sms_received',
                'completed',
                'expiration_pending'
            )) or
        (old.status = 'expiration_pending'
            and new.status in ('completed', 'expired', 'cancelled'))
    ) then
        raise exception 'INVALID_ACTIVATION_TRANSITION';
    end if;

    return new;
end;
$$;

create trigger tnum_activation_transition_guard
before update of status on public.tnum_activations
for each row
execute function public.tnum_validate_activation_transition();

-- Row-level security for T-NUM-specific tables.
-- Existing public.profiles and public.wallets policies are left untouched.
alter table public.tnum_wallet_holds enable row level security;
alter table public.tnum_wallet_ledger enable row level security;
alter table public.tnum_pricing_rules enable row level security;
alter table public.tnum_services enable row level security;
alter table public.tnum_countries enable row level security;
alter table public.tnum_service_country_catalog enable row level security;
alter table public.tnum_activations enable row level security;
alter table public.tnum_activation_sms enable row level security;
alter table public.tnum_activation_status_events enable row level security;
alter table public.tnum_provider_operations enable row level security;
alter table public.tnum_provider_worker_state enable row level security;

create policy tnum_own_hold_read
on public.tnum_wallet_holds
for select to authenticated
using (user_id = auth.uid());

create policy tnum_own_ledger_read
on public.tnum_wallet_ledger
for select to authenticated
using (user_id = auth.uid());

create policy tnum_catalog_services_read
on public.tnum_services
for select to authenticated
using (true);

create policy tnum_catalog_countries_read
on public.tnum_countries
for select to authenticated
using (true);

create policy tnum_catalog_matrix_read
on public.tnum_service_country_catalog
for select to authenticated
using (true);

create policy tnum_own_activations_read
on public.tnum_activations
for select to authenticated
using (user_id = auth.uid());

create policy tnum_own_sms_read
on public.tnum_activation_sms
for select to authenticated
using (
    exists (
        select 1
        from public.tnum_activations a
        where a.id = activation_id
          and a.user_id = auth.uid()
    )
);

create policy tnum_own_events_read
on public.tnum_activation_status_events
for select to authenticated
using (
    exists (
        select 1
        from public.tnum_activations a
        where a.id = activation_id
          and a.user_id = auth.uid()
    )
);

revoke all on public.tnum_wallet_holds,
              public.tnum_wallet_ledger,
              public.tnum_provider_operations,
              public.tnum_pricing_rules
from anon, authenticated;

revoke all on public.tnum_provider_worker_state
from anon, authenticated;

grant select on public.tnum_wallet_holds,
                public.tnum_wallet_ledger
to authenticated;

revoke insert, update, delete
on public.tnum_services,
   public.tnum_countries,
   public.tnum_service_country_catalog,
   public.tnum_activations,
   public.tnum_activation_sms,
   public.tnum_activation_status_events
from anon, authenticated;

revoke all on function public.tnum_reserve_activation(uuid, uuid, text, integer, bigint),
    public.tnum_claim_purchase_quote(uuid),
    public.tnum_claim_activation_purchase(uuid),
    public.tnum_claim_sms_revise(uuid),
    public.tnum_claim_activation_completion(uuid),
    public.tnum_release_activation_reservation(uuid),
    public.tnum_capture_activation_reservation(uuid)
from public, anon, authenticated;

grant execute on function public.tnum_reserve_activation(uuid, uuid, text, integer, bigint),
    public.tnum_claim_purchase_quote(uuid),
    public.tnum_claim_activation_purchase(uuid),
    public.tnum_claim_sms_revise(uuid),
    public.tnum_claim_activation_completion(uuid),
    public.tnum_release_activation_reservation(uuid),
    public.tnum_capture_activation_reservation(uuid)
to service_role;

revoke all on function public.tnum_claim_provider_worker()
from public, anon, authenticated;

grant execute on function public.tnum_claim_provider_worker()
to postgres;
