
begin;

create or replace function public.finalize_proxnum_rental_renewal(
  p_rental_id uuid,
  p_renewal_id uuid,
  p_expires_at timestamptz,
  p_provider_payload jsonb,
  p_can_extend boolean,
  p_provider_status text,
  p_status_payload jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.proxnum_rentals;
  n public.proxnum_rental_renewals;
  h public.proxnum_rental_wallet_holds;
begin
  if p_rental_id is null
     or p_renewal_id is null
     or p_expires_at is null
     or p_can_extend is null
     or p_provider_status is distinct from 'active'
     or p_provider_payload is null
     or p_status_payload is null then
    raise exception 'INVALID_RENEWAL_CONFIRMATION';
  end if;

  select * into r
  from public.proxnum_rentals
  where id = p_rental_id
  for update;

  if not found or r.provider_rental_id is null then
    raise exception 'RENTAL_NOT_FOUND';
  end if;

  select * into n
  from public.proxnum_rental_renewals
  where id = p_renewal_id
    and rental_id = p_rental_id
  for update;

  if not found then
    raise exception 'RENEWAL_NOT_FOUND';
  end if;

  if n.user_id is distinct from r.user_id then
  raise exception 'RENEWAL_USER_MISMATCH';
end if;

  -- Idempotence: a repeated confirmation must match the saved expiry.
  if n.status = 'SUCCEEDED' then
    if n.new_expires_at is distinct from p_expires_at then
      raise exception 'RENEWAL_CONFIRMATION_CONFLICT';
    end if;

    select * into h
    from public.proxnum_rental_wallet_holds
    where rental_id = p_rental_id
      and operation_key = 'RENEWAL:' || n.idempotency_key
    for update;

    if not found or h.status <> 'CAPTURED' then
      raise exception 'SUCCEEDED_RENEWAL_WITHOUT_CAPTURED_HOLD';
    end if;

    return;
  end if;

  if n.status not in ('REQUESTED', 'RECONCILIATION_REQUIRED') then
    raise exception 'RENEWAL_NOT_FINALIZABLE';
  end if;

  if r.status not in ('RENEWAL_REQUESTED', 'RECONCILIATION_REQUIRED', 'ACTIVE') then
    raise exception 'RENTAL_NOT_FINALIZABLE';
  end if;

  select * into h
  from public.proxnum_rental_wallet_holds
  where rental_id = p_rental_id
    and operation_key = 'RENEWAL:' || n.idempotency_key
  for update;

  if not found then
    raise exception 'RENTAL_HOLD_NOT_FOUND';
  end if;

  if h.status not in ('HELD', 'CAPTURED') then
    raise exception 'RENTAL_HOLD_ALREADY_FINAL';
  end if;

  -- Capture and both record updates commit or roll back together.
  if h.status = 'HELD' then
    perform public.finish_proxnum_rental_hold(
      p_rental_id,
      'RENEWAL:' || n.idempotency_key,
      true
    );
  end if;

  update public.proxnum_rental_renewals
  set status = 'SUCCEEDED',
      new_expires_at = p_expires_at,
      provider_payload = p_provider_payload,
      failure_code = null,
      failure_message = null
  where id = p_renewal_id;

  update public.proxnum_rentals
  set status = 'ACTIVE',
      expires_at = p_expires_at,
      can_cancel = false,
      can_extend = p_can_extend,
      last_provider_status = p_provider_status,
      last_provider_payload = p_status_payload,
      last_sync_at = now(),
      sync_failures = 0,
      last_sync_error = null,
      failure_code = null,
      failure_message = null
  where id = p_rental_id;
end;
$$;

revoke all on function public.finalize_proxnum_rental_renewal(
  uuid, uuid, timestamptz, jsonb, boolean, text, jsonb
) from public, anon, authenticated;

grant execute on function public.finalize_proxnum_rental_renewal(
  uuid, uuid, timestamptz, jsonb, boolean, text, jsonb
) to service_role;

commit;
