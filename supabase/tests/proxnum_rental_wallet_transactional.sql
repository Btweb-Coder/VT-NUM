
-- LOCAL-ONLY transactional regression harness.
-- Requires the Proxnum schema, wallet, and atomic renewal migrations,
-- plus at least one seeded public.wallets row.
-- Run only against a disposable local Supabase/PostgreSQL database.
-- Never run against production. The fixture transaction rolls back.

begin;
set local statement_timeout = '30s';

do $$
declare
  v_user uuid;
  v_key text := 'review-test-' || gen_random_uuid()::text;
  v_first record;
  v_again record;
  v_renewal record;
  v_before public.wallets;
  v_after public.wallets;
  v_renewal_id uuid;
  v_ledger_count integer;
  v_failed boolean;
  v_new_expiry timestamptz;
  v_hold_status text;
  v_renewal_status text;
  v_rental_status text;
  v_before_capture integer;
  v_after_capture integer;
begin
  select user_id into v_user
  from public.wallets
  order by created_at
  limit 1;

  if v_user is null then
    raise exception 'TEST_FIXTURE_REQUIRED: seed one profile and wallet locally';
  end if;

  update public.wallets
  set currency = 'USD',
      available_balance = 1000000,
      held_balance = 0
  where user_id = v_user;

  select * into v_before
  from public.wallets
  where user_id = v_user;

  -- Insufficient funds must atomically leave no intent, operation or hold.
  update public.wallets
  set available_balance = 0
  where user_id = v_user;

  v_failed := false;

  begin
    perform *
    from public.reserve_proxnum_rental(
      v_user, v_key || '-poor', 'wa', 'WhatsApp',
      '187', 'USA', 24, 100
    );
  exception when others then
    if sqlerrm not like '%INSUFFICIENT_BALANCE%' then
      raise;
    end if;
    v_failed := true;
  end;

  if not v_failed then
    raise exception 'ASSERT_FAILED: insufficient balance accepted';
  end if;

  if exists (
    select 1 from public.proxnum_rentals
    where user_id = v_user
      and idempotency_key = v_key || '-poor'
  ) then
    raise exception 'ASSERT_FAILED: failed reserve left rental';
  end if;

  update public.wallets
  set available_balance = 1000000
  where user_id = v_user;

  -- Repeated purchase key returns the original intent and holds funds once.
  select * into v_first
  from public.reserve_proxnum_rental(
    v_user, v_key || '-buy', 'wa', 'WhatsApp',
    '187', 'USA', 24, 1
  );

  select * into v_again
  from public.reserve_proxnum_rental(
    v_user, v_key || '-buy', 'wa', 'WhatsApp',
    '187', 'USA', 24, 1
  );

  if v_first.rental_id <> v_again.rental_id or v_again.is_new then
    raise exception 'ASSERT_FAILED: repeated purchase key was not idempotent';
  end if;

  select * into v_after
  from public.wallets
  where user_id = v_user;

  if v_after.held_balance <= v_before.held_balance then
    raise exception 'ASSERT_FAILED: funds were not held';
  end if;

  -- Captures and releases are idempotent; conflicting finalization is rejected.
  perform public.finish_proxnum_rental_hold(
    v_first.rental_id, 'PURCHASE:' || v_key || '-buy', true
  );

  perform public.finish_proxnum_rental_hold(
    v_first.rental_id, 'PURCHASE:' || v_key || '-buy', true
  );

  select count(*) into v_ledger_count
  from public.proxnum_rental_ledger_entries
  where rental_id = v_first.rental_id
    and entry_type = 'CAPTURE_HOLD';

  if v_ledger_count <> 1 then
    raise exception 'ASSERT_FAILED: double capture wrote multiple ledger rows';
  end if;

  v_failed := false;

  begin
    perform public.finish_proxnum_rental_hold(
      v_first.rental_id, 'PURCHASE:' || v_key || '-buy', false
    );
  exception when others then
    v_failed := true;
  end;

  if not v_failed then
    raise exception 'ASSERT_FAILED: captured hold was released';
  end if;

  select * into v_again
  from public.reserve_proxnum_rental(
    v_user, v_key || '-release', 'wa', 'WhatsApp',
    '187', 'USA', 24, 1
  );

  perform public.finish_proxnum_rental_hold(
    v_again.rental_id, 'PURCHASE:' || v_key || '-release', false
  );

  perform public.finish_proxnum_rental_hold(
    v_again.rental_id, 'PURCHASE:' || v_key || '-release', false
  );

  select count(*) into v_ledger_count
  from public.proxnum_rental_ledger_entries
  where rental_id = v_again.rental_id
    and entry_type = 'RELEASE_HOLD';

  if v_ledger_count <> 1 then
    raise exception 'ASSERT_FAILED: double release wrote multiple ledger rows';
  end if;

  -- An ambiguous provider result stays held.
  select * into v_again
  from public.reserve_proxnum_rental(
    v_user, v_key || '-ambiguous', 'wa', 'WhatsApp',
    '187', 'USA', 24, 1
  );

  update public.proxnum_rentals
  set status = 'RECONCILIATION_REQUIRED'
  where id = v_again.rental_id;

  if not exists (
    select 1 from public.proxnum_rental_wallet_holds
    where rental_id = v_again.rental_id
      and status = 'HELD'
  ) then
    raise exception 'ASSERT_FAILED: ambiguous purchase released funds';
  end if;

  -- Prepare an active rental for renewal tests.
  select * into v_first
  from public.reserve_proxnum_rental(
    v_user, v_key || '-renew-base', 'wa', 'WhatsApp',
    '187', 'USA', 24, 1
  );

  update public.proxnum_rentals
  set status = 'ACTIVE',
      provider_rental_id = 'local-test-' || v_first.rental_id::text,
      can_extend = true,
      expires_at = now() + interval '1 day'
  where id = v_first.rental_id;

  perform public.finish_proxnum_rental_hold(
    v_first.rental_id, 'PURCHASE:' || v_key || '-renew-base', true
  );

  -- A repeated renewal key must not create a second hold.
  select * into v_renewal
  from public.reserve_proxnum_rental_renewal(
    v_user, v_first.rental_id, v_key || '-renew', 24, 1
  );

  v_renewal_id := v_renewal.renewal_id;

  update public.proxnum_rental_renewals
  set status = 'RECONCILIATION_REQUIRED'
  where id = v_renewal_id;

  if not exists (
    select 1 from public.proxnum_rental_wallet_holds
    where rental_id = v_first.rental_id
      and operation_key = 'RENEWAL:' || v_key || '-renew'
      and status = 'HELD'
  ) then
    raise exception 'ASSERT_FAILED: interrupted renewal released its hold';
  end if;

  v_failed := false;

  begin
    perform *
    from public.reserve_proxnum_rental_renewal(
      v_user, v_first.rental_id, v_key || '-renew', 24, 1
    );
  exception when others then
    v_failed := true;
  end;

  if v_failed then
    raise exception 'ASSERT_FAILED: repeated renewal key failed';
  end if;

  select count(*) into v_ledger_count
  from public.proxnum_rental_ledger_entries
  where rental_id = v_first.rental_id
    and idempotency_key like 'rental-renewal-hold:%';

  if v_ledger_count <> 1 then
    raise exception 'ASSERT_FAILED: repeated renewal made duplicate hold';
  end if;

  -- Atomic renewal finalization: capture and record updates happen together.
  v_new_expiry := now() + interval '3 days';

  select count(*) into v_before_capture
  from public.proxnum_rental_ledger_entries
  where rental_id = v_first.rental_id
    and entry_type = 'CAPTURE_HOLD'
    and idempotency_key =
      'rental-capture:' || v_first.rental_id
      || ':RENEWAL:' || v_key || '-renew';

  perform public.finalize_proxnum_rental_renewal(
    v_first.rental_id,
    v_renewal_id,
    v_new_expiry,
    '{"test":"renewal-confirmed"}'::jsonb,
    true,
    'active',
    '{"status":"active","test":true}'::jsonb
  );

  -- Repeating the same finalization must not capture twice.
  perform public.finalize_proxnum_rental_renewal(
    v_first.rental_id,
    v_renewal_id,
    v_new_expiry,
    '{"test":"renewal-confirmed"}'::jsonb,
    true,
    'active',
    '{"status":"active","test":true}'::jsonb
  );

  select status into v_renewal_status
  from public.proxnum_rental_renewals
  where id = v_renewal_id;

  select status into v_rental_status
  from public.proxnum_rentals
  where id = v_first.rental_id;

  select status into v_hold_status
  from public.proxnum_rental_wallet_holds
  where rental_id = v_first.rental_id
    and operation_key = 'RENEWAL:' || v_key || '-renew';

  if v_renewal_status <> 'SUCCEEDED'
     or v_rental_status <> 'ACTIVE'
     or v_hold_status <> 'CAPTURED' then
    raise exception 'ASSERT_FAILED: renewal finalization state incorrect';
  end if;

  if not exists (
    select 1 from public.proxnum_rental_renewals
    where id = v_renewal_id
      and new_expires_at = v_new_expiry
  ) then
    raise exception 'ASSERT_FAILED: renewal expiry not saved';
  end if;

  if not exists (
    select 1 from public.proxnum_rentals
    where id = v_first.rental_id
      and expires_at = v_new_expiry
  ) then
    raise exception 'ASSERT_FAILED: rental expiry not saved';
  end if;

  select count(*) into v_after_capture
  from public.proxnum_rental_ledger_entries
  where rental_id = v_first.rental_id
    and entry_type = 'CAPTURE_HOLD'
    and idempotency_key =
      'rental-capture:' || v_first.rental_id
      || ':RENEWAL:' || v_key || '-renew';

  if v_after_capture <> v_before_capture + 1 then
    raise exception 'ASSERT_FAILED: renewal capture was not exactly once';
  end if;

  -- A conflicting expiry must be rejected.
  v_failed := false;

  begin
    perform public.finalize_proxnum_rental_renewal(
      v_first.rental_id,
      v_renewal_id,
      v_new_expiry + interval '1 day',
      '{"test":"conflict"}'::jsonb,
      true,
      'active',
      '{"status":"active"}'::jsonb
    );
  exception when others then
    if sqlerrm not like '%RENEWAL_CONFIRMATION_CONFLICT%' then
      raise;
    end if;
    v_failed := true;
  end;

  if not v_failed then
    raise exception 'ASSERT_FAILED: conflicting renewal expiry accepted';
  end if;

  -- The partial unique index prevents two open cancellations for one rental.
  update public.proxnum_rentals
  set status = 'ACTIVE', can_cancel = true
  where id = v_first.rental_id;

  insert into public.proxnum_rental_operations(
    rental_id, user_id, operation, idempotency_key, status
  ) values (
    v_first.rental_id, v_user, 'CANCEL', v_key || '-cancel-a', 'STARTED'
  );

  v_failed := false;

  begin
    insert into public.proxnum_rental_operations(
      rental_id, user_id, operation, idempotency_key, status
    ) values (
      v_first.rental_id, v_user, 'CANCEL', v_key || '-cancel-b', 'STARTED'
    );
  exception when unique_violation then
    v_failed := true;
  end;

  if not v_failed then
    raise exception 'ASSERT_FAILED: duplicate open cancellation claim was accepted';
  end if;

  -- Test rejection of a non-USD wallet. The outer transaction rolls this back.
  alter table public.wallets drop constraint wallets_currency_check;

  update public.wallets
  set currency = 'EUR'
  where user_id = v_user;

  v_failed := false;

  begin
    perform *
    from public.reserve_proxnum_rental(
      v_user, v_key || '-currency', 'wa', 'WhatsApp',
      '187', 'USA', 24, 1
    );
  exception when others then
    if sqlerrm not like '%UNSUPPORTED_WALLET_CURRENCY%' then
      raise;
    end if;
    v_failed := true;
  end;

  if not v_failed then
    raise exception 'ASSERT_FAILED: non-USD wallet was accepted';
  end if;

  alter table public.wallets
    add constraint wallets_currency_check check (currency = 'USD');
end $$;

rollback;
