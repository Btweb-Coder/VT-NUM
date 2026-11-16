-- LOCAL-ONLY financial regression harness for the shared VT-NUM wallet.
-- Apply all migrations to a disposable local Supabase database first.
-- This transaction rolls back all rows and wallet changes at the end.

begin;
set local statement_timeout = '30s';

do $$
declare
  v_user uuid;
  v_country integer;
  v_service text := 'audit-' || replace(gen_random_uuid()::text, '-', '');
  v_key_capture uuid := gen_random_uuid();
  v_key_release uuid := gen_random_uuid();
  v_quote_capture uuid;
  v_quote_release uuid;
  v_activation_capture uuid;
  v_activation_release uuid;
  v_price numeric;
  v_markup_type text;
  v_markup_value numeric;
  v_price_cents bigint;
  v_before_available numeric;
  v_before_held numeric;
  v_after_available numeric;
  v_after_held numeric;
  v_entries integer;
begin
  select w.user_id into v_user
  from public.wallets w
  where not exists (
    select 1 from public.tnum_activations a
    where a.user_id = w.user_id
      and a.status not in ('completed', 'expired', 'cancelled', 'failed')
    group by a.user_id having count(*) >= 10
  )
  order by w.created_at limit 1;
  if v_user is null then
    raise exception 'TEST_FIXTURE_REQUIRED: an account with wallet is required';
  end if;

  select code into v_country from public.tnum_countries where enabled order by code limit 1;
  if v_country is null then
    v_country := 999999;
    insert into public.tnum_countries(code, name, enabled)
      values (v_country, 'Audit fixture', true);
  end if;
  insert into public.tnum_services(slug, name)
    values (v_service, 'Audit fixture');
  insert into public.tnum_service_country_catalog(
    service_slug, country_code, provider_price, available_count
  ) values (v_service, v_country, 1.00, 10);

  select available_balance, held_balance into v_before_available, v_before_held
    from public.wallets where user_id = v_user for update;
  update public.wallets set available_balance = available_balance + 100
    where user_id = v_user;
  select available_balance into v_before_available
    from public.wallets where user_id = v_user;

  select customer_price, markup_type, markup_value
    into v_price, v_markup_type, v_markup_value
    from public.calculate_activation_customer_price(1.00);
  v_price_cents := round(v_price * 100)::bigint;

  insert into public.tnum_activation_quotes(
    user_id, service_slug, country_code, provider_price_cents,
    customer_price_cents, markup_type, markup_value, expires_at
  ) values (
    v_user, v_service, v_country, 100, v_price_cents,
    v_markup_type, v_markup_value, now() + interval '2 minutes'
  ) returning id into v_quote_capture;

  select (public.tnum_reserve_activation(
    v_user, v_key_capture, v_service, v_country, 100, v_quote_capture
  )).id into v_activation_capture;
  if (public.tnum_reserve_activation(
    v_user, v_key_capture, v_service, v_country, 100, v_quote_capture
  )).id <> v_activation_capture then
    raise exception 'IDEMPOTENT_RESERVATION_RETURNED_DIFFERENT_ACTIVATION';
  end if;

  if not public.tnum_capture_activation_reservation(v_activation_capture) then
    raise exception 'CAPTURE_FAILED';
  end if;
  if public.tnum_capture_activation_reservation(v_activation_capture) then
    raise exception 'CAPTURE_WAS_NOT_IDEMPOTENT';
  end if;

  insert into public.tnum_activation_quotes(
    user_id, service_slug, country_code, provider_price_cents,
    customer_price_cents, markup_type, markup_value, expires_at
  ) values (
    v_user, v_service, v_country, 100, v_price_cents,
    v_markup_type, v_markup_value, now() + interval '2 minutes'
  ) returning id into v_quote_release;
  select (public.tnum_reserve_activation(
    v_user, v_key_release, v_service, v_country, 100, v_quote_release
  )).id into v_activation_release;

  if not public.tnum_release_activation_reservation(v_activation_release) then
    raise exception 'RELEASE_FAILED';
  end if;
  if public.tnum_release_activation_reservation(v_activation_release) then
    raise exception 'RELEASE_WAS_NOT_IDEMPOTENT';
  end if;

  select available_balance, held_balance into v_after_available, v_after_held
    from public.wallets where user_id = v_user;
  if v_after_available <> v_before_available - v_price_cents::numeric / 100
     or v_after_held <> v_before_held then
    raise exception 'SHARED_WALLET_INVARIANT_FAILED';
  end if;

  select count(*) into v_entries from public.wallet_ledger_entries
   where source_system = 'T-NUM'
     and source_operation_id in (v_activation_capture, v_activation_release);
  if v_entries <> 4 then
    raise exception 'EXPECTED_FOUR_CENTRAL_LEDGER_ENTRIES_GOT_%', v_entries;
  end if;

  select count(*) into v_entries from public.tnum_wallet_ledger
   where activation_id in (v_activation_capture, v_activation_release);
  if v_entries <> 4 then
    raise exception 'TNUM_LEDGER_COMPATIBILITY_VIEW_MISMATCH';
  end if;
end;
$$;

rollback;
