-- Online SIM: isolated schema for long-term Proxnum rentals.
-- Prepared for manual review; this migration has not been applied anywhere.
-- It creates no provider purchase and leaves the feature disabled.

begin;

create table if not exists public.proxnum_rentals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null
    references public.profiles(user_id) on delete restrict,

  provider_slug text not null default 'proxnum'
    check (provider_slug = 'proxnum'),
  provider_rental_id text,
  service_code text not null,
  service_name text not null,
  country_code text not null,
  country_name text not null,
  phone_number text,
  duration_hours integer not null check (duration_hours > 0),

  -- Prix source et prix client sont conservés séparément.
  provider_price numeric(20,6) check (provider_price is null or provider_price >= 0),
  customer_price numeric(20,6) check (customer_price is null or customer_price > 0),
  currency char(3) not null default 'USD' check (currency = 'USD'),
  markup_type text check (markup_type is null or markup_type in ('percentage','fixed')),
  markup_value numeric(20,6) check (markup_value is null or markup_value >= 0),

  status text not null default 'CREATED'
    check (status in (
      'CREATED',
      'PURCHASE_REQUESTED',
      'ACTIVE',
      'CANCEL_REQUESTED',
      'CANCEL_PENDING',
      'CANCELLED',
      'EXPIRED',
      'RENEWAL_REQUESTED',
      'RECONCILIATION_REQUIRED',
      'FAILED'
    )),

  purchased_at timestamptz,
  expires_at timestamptz,
  cancel_until timestamptz,
  can_cancel boolean not null default false,
  cancel_pending boolean not null default false,
  can_extend boolean not null default false,

  last_provider_status text,
  last_provider_payload jsonb not null default '{}'::jsonb,
  last_sync_at timestamptz,
  next_sync_at timestamptz,
  sync_failures integer not null default 0 check (sync_failures >= 0),
  last_sync_error text,
  reconciliation_escalated_at timestamptz,
  reconciliation_escalation_reason text,
  failure_code text,
  failure_message text,
  idempotency_key text not null,
  version integer not null default 1 check (version > 0),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint proxnum_rentals_provider_id_unique unique (provider_rental_id),
  constraint proxnum_rentals_user_idempotency_unique unique (user_id, idempotency_key)
);

create index if not exists proxnum_rentals_user_created_idx
  on public.proxnum_rentals (user_id, created_at desc);

create index if not exists proxnum_rentals_active_expiry_idx
  on public.proxnum_rentals (status, expires_at)
  where status in ('ACTIVE','CANCEL_PENDING','RENEWAL_REQUESTED');

create index if not exists proxnum_rentals_unresolved_sync_idx
  on public.proxnum_rentals (last_sync_at nulls first, created_at)
  where provider_rental_id is null and status in ('PURCHASE_REQUESTED','RECONCILIATION_REQUIRED');

create index if not exists proxnum_rentals_due_sync_idx
  on public.proxnum_rentals (last_sync_at nulls first, created_at)
  where provider_rental_id is not null and status in ('ACTIVE','CANCEL_PENDING','CANCEL_REQUESTED','RENEWAL_REQUESTED','RECONCILIATION_REQUIRED');

create table if not exists public.proxnum_rental_messages (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.proxnum_rentals(id) on delete restrict,
  provider_message_id text,
  sender text,
  message_text text not null,
  sms_code text,
  message_at timestamptz,
  created_at timestamptz not null default now(),
  constraint proxnum_rental_message_provider_unique
    unique (rental_id, provider_message_id)
);

create index if not exists proxnum_rental_messages_rental_time_idx
  on public.proxnum_rental_messages (rental_id, message_at desc);

create table if not exists public.proxnum_rental_renewals (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.proxnum_rentals(id) on delete restrict,
  user_id uuid not null references public.profiles(user_id) on delete restrict,
  idempotency_key text not null,
  requested_hours integer not null check (requested_hours > 0),
  provider_price numeric(20,6) check (provider_price is null or provider_price >= 0),
  customer_price numeric(20,6) check (customer_price is null or customer_price > 0),
  markup_type text check (markup_type is null or markup_type in ('percentage','fixed')),
  markup_value numeric(20,6) check (markup_value is null or markup_value >= 0),
  status text not null default 'CREATED'
    check (status in ('CREATED','REQUESTED','SUCCEEDED','FAILED','RECONCILIATION_REQUIRED')),
  previous_expires_at timestamptz,
  new_expires_at timestamptz,
  provider_payload jsonb not null default '{}'::jsonb,
  failure_code text,
  failure_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, idempotency_key)
);

create index if not exists proxnum_rental_renewals_rental_created_idx
  on public.proxnum_rental_renewals (rental_id, created_at desc);

create or replace function public.set_proxnum_rental_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists proxnum_rentals_updated_at on public.proxnum_rentals;
create trigger proxnum_rentals_updated_at
before update on public.proxnum_rentals
for each row execute function public.set_proxnum_rental_updated_at();

drop trigger if exists proxnum_rental_renewals_updated_at on public.proxnum_rental_renewals;
create trigger proxnum_rental_renewals_updated_at
before update on public.proxnum_rental_renewals
for each row execute function public.set_proxnum_rental_updated_at();

alter table public.proxnum_rentals enable row level security;
alter table public.proxnum_rental_messages enable row level security;
alter table public.proxnum_rental_renewals enable row level security;

-- Les écritures doivent passer par Edge Functions/service_role.
-- Un utilisateur authentifié ne voit que ses locations, SMS et renouvellements.
drop policy if exists proxnum_rentals_select_own on public.proxnum_rentals;
create policy proxnum_rentals_select_own
  on public.proxnum_rentals for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists proxnum_rental_messages_select_own on public.proxnum_rental_messages;
create policy proxnum_rental_messages_select_own
  on public.proxnum_rental_messages for select to authenticated
  using (exists (
    select 1 from public.proxnum_rentals r
    where r.id = rental_id and r.user_id = (select auth.uid())
  ));

drop policy if exists proxnum_rental_renewals_select_own on public.proxnum_rental_renewals;
create policy proxnum_rental_renewals_select_own
  on public.proxnum_rental_renewals for select to authenticated
  using (user_id = (select auth.uid()));

revoke all on public.proxnum_rentals from anon, authenticated;
revoke all on public.proxnum_rental_messages from anon, authenticated;
revoke all on public.proxnum_rental_renewals from anon, authenticated;

grant select on public.proxnum_rentals to authenticated;
grant select on public.proxnum_rental_messages to authenticated;
grant select on public.proxnum_rental_renewals to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname='supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='proxnum_rentals') then alter publication supabase_realtime add table public.proxnum_rentals; end if;
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='proxnum_rental_messages') then alter publication supabase_realtime add table public.proxnum_rental_messages; end if;
  end if;
end $$;

commit;

-- Apply the following reviewed wallet migration before enabling the feature.
-- providers.features.rental_numbers remains false until a manual activation.
