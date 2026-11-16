-- Long-term Proxnum rentals use an isolated wallet hold. This does not alter
-- activation or payment/top-up routines.
begin;

create table if not exists public.proxnum_rental_wallet_holds (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.proxnum_rentals(id) on delete restrict,
  operation_key text not null,
  user_id uuid not null references public.profiles(user_id) on delete restrict,
  amount numeric(20,6) not null check (amount > 0),
  status text not null default 'HELD' check (status in ('HELD','CAPTURED','RELEASED')),
  created_at timestamptz not null default now(), captured_at timestamptz, released_at timestamptz,
  unique(rental_id,operation_key)
);

create table if not exists public.proxnum_rental_ledger_entries (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.proxnum_rentals(id) on delete restrict,
  user_id uuid not null references public.profiles(user_id) on delete restrict,
  entry_type text not null check (entry_type in ('HOLD','CAPTURE_HOLD','RELEASE_HOLD','REFUND')),
  amount numeric(20,6) not null check (amount > 0), currency char(3) not null default 'USD' check(currency='USD'),
  balance_before numeric(20,6), balance_after numeric(20,6), idempotency_key text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.proxnum_rental_operations (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.proxnum_rentals(id) on delete restrict,
  user_id uuid not null references public.profiles(user_id) on delete restrict,
  operation text not null check (operation in ('PURCHASE','CANCEL','RENEWAL','SYNC')),
  idempotency_key text not null,
  status text not null check (status in ('STARTED','SUCCEEDED','FAILED','RECONCILIATION_REQUIRED','PENDING')),
  amount numeric(20,6), provider_payload jsonb not null default '{}'::jsonb,
  error_code text, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(user_id, operation, idempotency_key)
);
create index if not exists proxnum_rental_ops_rental_idx on public.proxnum_rental_operations(rental_id,created_at desc);
-- A rental can have only one unresolved cancellation claim at a time. The
-- partial unique index also serializes concurrent requests with different keys.
create unique index if not exists proxnum_rental_one_open_cancel_idx
  on public.proxnum_rental_operations(rental_id)
  where operation='CANCEL' and status in ('STARTED','PENDING','RECONCILIATION_REQUIRED');
drop trigger if exists proxnum_rental_operations_updated_at on public.proxnum_rental_operations;
create trigger proxnum_rental_operations_updated_at before update on public.proxnum_rental_operations for each row execute function public.set_proxnum_rental_updated_at();

alter table public.proxnum_rental_wallet_holds enable row level security;
alter table public.proxnum_rental_ledger_entries enable row level security;
alter table public.proxnum_rental_operations enable row level security;
revoke all on public.proxnum_rental_wallet_holds, public.proxnum_rental_ledger_entries, public.proxnum_rental_operations from anon, authenticated;
create policy proxnum_rental_ledger_self on public.proxnum_rental_ledger_entries for select to authenticated using (user_id=(select auth.uid()));
create policy proxnum_rental_operations_self on public.proxnum_rental_operations for select to authenticated using (user_id=(select auth.uid()));
grant select on public.proxnum_rental_ledger_entries,public.proxnum_rental_operations to authenticated;
do $$
begin
  if exists (select 1 from pg_publication where pubname='supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='proxnum_rental_ledger_entries') then alter publication supabase_realtime add table public.proxnum_rental_ledger_entries; end if;
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='proxnum_rental_operations') then alter publication supabase_realtime add table public.proxnum_rental_operations; end if;
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='proxnum_rental_renewals') then alter publication supabase_realtime add table public.proxnum_rental_renewals; end if;
  end if;
end $$;

-- Creates the durable intent and reserves the server-computed customer price
-- in one transaction. A repeated key returns the existing intent without another hold.
create or replace function public.reserve_proxnum_rental(
  p_user_id uuid, p_key text, p_service_code text, p_service_name text,
  p_country_code text, p_country_name text, p_hours integer, p_provider_price numeric
) returns table(rental_id uuid, is_new boolean, customer_price numeric, status text)
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_rule public.pricing_rules; v_wallet public.wallets; v_price numeric(20,6); v_existing public.proxnum_rentals; v_rule_count integer;
begin
  if p_user_id is null or p_key is null or length(trim(p_key)) not between 1 and 200 or p_hours is null or p_hours <= 0 or p_provider_price is null or p_provider_price <= 0 then raise exception 'INVALID_RENTAL_REQUEST'; end if;
  insert into public.proxnum_rentals(user_id,idempotency_key,service_code,service_name,country_code,country_name,duration_hours,provider_price,status)
    values(p_user_id,trim(p_key),p_service_code,p_service_name,p_country_code,p_country_name,p_hours,p_provider_price,'CREATED')
    on conflict(user_id,idempotency_key) do nothing returning id into v_id;
  if v_id is null then
    select * into v_existing from public.proxnum_rentals r where r.user_id=p_user_id and r.idempotency_key=trim(p_key) for update;
    if v_existing.service_code<>p_service_code or v_existing.country_code<>p_country_code or v_existing.duration_hours<>p_hours then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return query select v_existing.id,false,v_existing.customer_price,v_existing.status; return;
  end if;
  insert into public.proxnum_rental_operations(rental_id,user_id,operation,idempotency_key,status)
    values(v_id,p_user_id,'PURCHASE',trim(p_key),'STARTED');
  select count(*) into v_rule_count from public.pricing_rules where active;
  if v_rule_count <> 1 then raise exception 'PRICING_RULE_NOT_UNIQUE'; end if;
  select * into v_rule from public.pricing_rules where active order by created_at desc,id desc limit 1 for share;
  if not found then raise exception 'PRICING_RULE_NOT_CONFIGURED'; end if;
  v_price := case v_rule.markup_type when 'percentage' then round(p_provider_price * (1 + v_rule.markup_value / 100), 6) else round(p_provider_price + v_rule.markup_value, 6) end;
  if v_price <= 0 then raise exception 'INVALID_CUSTOMER_PRICE'; end if;
  select * into v_wallet from public.wallets where user_id=p_user_id for update;
  if not found then raise exception 'WALLET_NOT_FOUND'; end if;
  if v_wallet.currency <> 'USD' then raise exception 'UNSUPPORTED_WALLET_CURRENCY'; end if;
  if v_wallet.available_balance < v_price then raise exception 'INSUFFICIENT_BALANCE'; end if;
  update public.wallets set available_balance=available_balance-v_price,held_balance=held_balance+v_price where user_id=p_user_id;
  update public.proxnum_rentals set customer_price=v_price,markup_type=v_rule.markup_type,markup_value=v_rule.markup_value,status='PURCHASE_REQUESTED' where id=v_id;
  insert into public.proxnum_rental_wallet_holds(rental_id,operation_key,user_id,amount) values(v_id,'PURCHASE:'||trim(p_key),p_user_id,v_price);
  insert into public.proxnum_rental_ledger_entries(user_id,rental_id,entry_type,amount,currency,balance_before,balance_after,idempotency_key)
    values(p_user_id,v_id,'HOLD',v_price,'USD',v_wallet.available_balance,v_wallet.available_balance-v_price,'rental-hold:'||v_id);
  return query select v_id,true,v_price,'PURCHASE_REQUESTED'::text;
end $$;

create or replace function public.finish_proxnum_rental_hold(p_rental_id uuid, p_operation_key text, p_capture boolean)
returns void language plpgsql security definer set search_path = public as $$
declare h public.proxnum_rental_wallet_holds; w public.wallets; v_type public.wallet_entry_type; v_key text;
begin
  select * into h from public.proxnum_rental_wallet_holds where rental_id=p_rental_id and operation_key=p_operation_key for update;
  if not found then raise exception 'RENTAL_HOLD_NOT_FOUND'; end if;
  if (p_capture and h.status='CAPTURED') or (not p_capture and h.status='RELEASED') then return; end if;
  if h.status <> 'HELD' then raise exception 'RENTAL_HOLD_ALREADY_FINAL'; end if;
  select * into w from public.wallets where user_id=h.user_id for update;
  if not found then raise exception 'WALLET_NOT_FOUND'; end if;
  if w.currency <> 'USD' then raise exception 'UNSUPPORTED_WALLET_CURRENCY'; end if;
  if w.held_balance < h.amount then raise exception 'INVALID_HELD_BALANCE'; end if;
  if p_capture then
    update public.wallets set held_balance=held_balance-h.amount where user_id=h.user_id;
    update public.proxnum_rental_wallet_holds set status='CAPTURED',captured_at=now() where rental_id=p_rental_id and operation_key=p_operation_key;
    v_type:='CAPTURE_HOLD'; v_key:='rental-capture:'||p_rental_id||':'||p_operation_key;
  else
    update public.wallets set held_balance=held_balance-h.amount,available_balance=available_balance+h.amount where user_id=h.user_id;
    update public.proxnum_rental_wallet_holds set status='RELEASED',released_at=now() where rental_id=p_rental_id and operation_key=p_operation_key;
    v_type:='RELEASE_HOLD'; v_key:='rental-release:'||p_rental_id||':'||p_operation_key;
  end if;
  insert into public.proxnum_rental_ledger_entries(user_id,rental_id,entry_type,amount,currency,balance_before,balance_after,idempotency_key)
    values(h.user_id,p_rental_id,v_type::text,h.amount,'USD',w.available_balance,case when p_capture then w.available_balance else w.available_balance+h.amount end,v_key);
end $$;

create or replace function public.reserve_proxnum_rental_renewal(p_user_id uuid,p_rental_id uuid,p_key text,p_hours integer,p_provider_price numeric)
returns table(renewal_id uuid,is_new boolean,customer_price numeric,status text)
language plpgsql security definer set search_path=public as $$
declare r public.proxnum_rentals; w public.wallets; rule public.pricing_rules; price numeric(20,6); n uuid; old public.proxnum_rental_renewals; v_rule_count integer;
begin
  if p_user_id is null or p_key is null or length(trim(p_key)) not between 1 and 200 or p_hours is null or p_hours<=0 or p_provider_price is null or p_provider_price<=0 then raise exception 'INVALID_RENEWAL_REQUEST'; end if;
  select * into r from public.proxnum_rentals where id=p_rental_id and user_id=p_user_id for update;
  if not found then raise exception 'RENTAL_NOT_FOUND'; end if;
  select * into old from public.proxnum_rental_renewals where user_id=p_user_id and idempotency_key=trim(p_key) for update;
  if found then
    if old.rental_id<>p_rental_id or old.requested_hours<>p_hours then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return query select old.id,false,old.customer_price,old.status; return;
  end if;
  if r.status <> 'ACTIVE' then raise exception 'RENTAL_NOT_ACTIVE'; end if;
  if r.can_extend is not true then raise exception 'RENTAL_CANNOT_EXTEND'; end if;
  insert into public.proxnum_rental_renewals(rental_id,user_id,idempotency_key,requested_hours,provider_price,status,previous_expires_at)
    values(p_rental_id,p_user_id,trim(p_key),p_hours,p_provider_price,'REQUESTED',r.expires_at)
    on conflict(user_id,idempotency_key) do nothing returning id into n;
  if n is null then select * into old from public.proxnum_rental_renewals where user_id=p_user_id and idempotency_key=trim(p_key) for update; if old.rental_id<>p_rental_id or old.requested_hours<>p_hours then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if; return query select old.id,false,old.customer_price,old.status; return; end if;
  select count(*) into v_rule_count from public.pricing_rules where active;
  if v_rule_count <> 1 then raise exception 'PRICING_RULE_NOT_UNIQUE'; end if;
  select * into rule from public.pricing_rules where active order by created_at desc,id desc limit 1 for share;
  if not found then raise exception 'PRICING_RULE_NOT_CONFIGURED'; end if;
  price := CASE
  WHEN rule.markup_type = 'percentage'
    THEN round(p_provider_price * (1 + rule.markup_value / 100), 6)
  ELSE round(p_provider_price + rule.markup_value, 6)
END;

IF price IS NULL OR price <= 0 THEN
  RAISE EXCEPTION 'INVALID_CUSTOMER_PRICE';
END IF;
  select * into w from public.wallets where user_id=p_user_id for update;
  if not found then raise exception 'WALLET_NOT_FOUND'; end if;
  if w.currency <> 'USD' then raise exception 'UNSUPPORTED_WALLET_CURRENCY'; end if;
  if w.available_balance<price then raise exception 'INSUFFICIENT_BALANCE'; end if;
  update public.wallets set available_balance=available_balance-price,held_balance=held_balance+price where user_id=p_user_id;
  update public.proxnum_rental_renewals set customer_price=price,markup_type=rule.markup_type,markup_value=rule.markup_value where id=n;
  insert into public.proxnum_rental_wallet_holds(rental_id,operation_key,user_id,amount) values(p_rental_id,'RENEWAL:'||trim(p_key),p_user_id,price);
  insert into public.proxnum_rental_ledger_entries(rental_id,user_id,entry_type,amount,balance_before,balance_after,idempotency_key)
    values(p_rental_id,p_user_id,'HOLD',price,w.available_balance,w.available_balance-price,'rental-renewal-hold:'||n);
  update public.proxnum_rentals set status='RENEWAL_REQUESTED' where id=p_rental_id;
  return query select n,true,price,'REQUESTED'::text;
end $$;

create or replace function public.refund_confirmed_proxnum_rental(p_rental_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare r public.proxnum_rentals; h public.proxnum_rental_wallet_holds; w public.wallets;
begin
  select * into r from public.proxnum_rentals where id=p_rental_id for update;
  if not found or r.status<>'CANCELLED' then raise exception 'PROVIDER_CANCELLATION_NOT_CONFIRMED'; end if;
  if exists(select 1 from public.proxnum_rental_ledger_entries where rental_id=p_rental_id and entry_type='REFUND') then return; end if;
  select * into h from public.proxnum_rental_wallet_holds where rental_id=p_rental_id and operation_key like 'PURCHASE:%' and status='CAPTURED' for update;
  if not found then raise exception 'CAPTURED_PURCHASE_NOT_FOUND'; end if;
  select * into w from public.wallets where user_id=h.user_id for update;
  if not found then raise exception 'WALLET_NOT_FOUND'; end if;
  if w.currency <> 'USD' then raise exception 'UNSUPPORTED_WALLET_CURRENCY'; end if;
  update public.wallets set available_balance=available_balance+h.amount where user_id=h.user_id;
  insert into public.proxnum_rental_ledger_entries(rental_id,user_id,entry_type,amount,balance_before,balance_after,idempotency_key)
    values(p_rental_id,h.user_id,'REFUND',h.amount,w.available_balance,w.available_balance+h.amount,'rental-refund:'||p_rental_id);
end $$;

-- Optional, isolated scheduler for the dedicated rental monitor. Call manually
-- only after the reviewed Edge Function and Vault cron_secret are configured.
create or replace function public.configure_proxnum_rental_monitor()
returns void language plpgsql security definer set search_path=public,cron,net,vault as $$
declare v_secret text; v_url constant text := 'https://mvvmdiabzkcywjvkffgr.supabase.co/functions/v1/monitor-proxnum-rentals';
  v_cron_version text;
begin
  if current_setting('server_version_num')::integer < 100000 then raise exception 'POSTGRES_10_OR_NEWER_REQUIRED'; end if;
  select extversion into v_cron_version from pg_catalog.pg_extension where extname='pg_cron';
  if v_cron_version is null or string_to_array(v_cron_version,'.')::integer[] < array[1,5,0] then
    raise exception 'PG_CRON_1_5_OR_NEWER_REQUIRED_FOR_SECONDS';
  end if;
  if not exists (select 1 from pg_catalog.pg_extension where extname='pg_net') then raise exception 'PG_NET_EXTENSION_NOT_INSTALLED'; end if;
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then raise exception 'PG_NET_HTTP_POST_NOT_AVAILABLE'; end if;
  if to_regclass('vault.decrypted_secrets') is null then raise exception 'VAULT_DECRYPTED_SECRETS_NOT_AVAILABLE'; end if;
  if to_regclass('cron.job') is null then raise exception 'PG_CRON_JOB_CATALOG_NOT_AVAILABLE'; end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name='cron_secret' limit 1;
  if v_secret is null or length(v_secret)=0 then raise exception 'VAULT_CRON_SECRET_MISSING'; end if;
  perform cron.unschedule(jobid) from cron.job where jobname='online-sim-monitor-proxnum-rentals';
  perform cron.schedule('online-sim-monitor-proxnum-rentals','10 seconds',format($cmd$select net.http_post(url := %L,headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')),body := '{}'::jsonb);$cmd$,v_url));
end $$;

revoke all on function public.reserve_proxnum_rental(uuid,text,text,text,text,text,integer,numeric) from public,anon,authenticated;
revoke all on function public.finish_proxnum_rental_hold(uuid,text,boolean) from public,anon,authenticated;
revoke all on function public.reserve_proxnum_rental_renewal(uuid,uuid,text,integer,numeric) from public,anon,authenticated;
revoke all on function public.refund_confirmed_proxnum_rental(uuid) from public,anon,authenticated;
revoke all on function public.configure_proxnum_rental_monitor() from public,anon,authenticated;
grant execute on function public.reserve_proxnum_rental(uuid,text,text,text,text,text,integer,numeric) to service_role;
grant execute on function public.finish_proxnum_rental_hold(uuid,text,boolean) to service_role;
grant execute on function public.reserve_proxnum_rental_renewal(uuid,uuid,text,integer,numeric) to service_role;
grant execute on function public.refund_confirmed_proxnum_rental(uuid) to service_role;
grant execute on function public.configure_proxnum_rental_monitor() to service_role;
commit;
