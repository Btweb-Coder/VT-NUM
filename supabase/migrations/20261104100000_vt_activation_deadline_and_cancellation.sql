-- VT-NUM application deadline and cancellation safeguards.
-- T-NUM uses its own activation tables and functions; Proxnum rows are excluded.

create or replace function public.enforce_vt_activation_deadline()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_slug text;
begin
  if new.status <> 'WAITING_FOR_SMS' or new.assigned_at is null then
    return new;
  end if;

  select slug into v_slug from public.providers where id = new.provider_id;
  if v_slug is null or v_slug = 'proxnum' then
    return new;
  end if;

  new.expires_at := least(
    coalesce(new.expires_at, new.assigned_at + interval '360 seconds'),
    new.assigned_at + interval '360 seconds'
  );
  return new;
end;
$$;

drop trigger if exists enforce_vt_activation_deadline on public.orders;
create trigger enforce_vt_activation_deadline
before insert or update of status, assigned_at, expires_at, provider_id
on public.orders
for each row execute function public.enforce_vt_activation_deadline();

-- Correct any still-open VT-NUM records whose stored deadline is longer than
-- six minutes. No row with an SMS/code is changed and no funds are released.
update public.orders o
set expires_at = least(coalesce(o.expires_at, coalesce(o.assigned_at, o.created_at) + interval '360 seconds'),
                       coalesce(o.assigned_at, o.created_at) + interval '360 seconds'),
    next_monitor_at = now(),
    updated_at = now()
from public.providers p
where p.id = o.provider_id
  and p.slug <> 'proxnum'
  and o.status in ('WAITING_FOR_SMS', 'EXPIRING', 'CANCELLING')
  and o.code is null
  and o.sms_received_at is null;

-- A dedicated VT monitor scheduler leaves the existing top-up schedule alone.
-- Use 10-second cadence where supported; older pg_cron installs fall back to
-- the existing one-minute cadence. The URL uses the project's current Edge
-- Functions endpoint and the secret is read from Vault at invocation time.
create or replace function public.configure_vt_activation_monitor_schedule()
returns void
language plpgsql
security definer
set search_path = public, cron, net, vault
as $$
declare
  v_secret text;
  v_cron_version text;
  v_schedule text := '* * * * *';
  v_url constant text := 'https://mvvmdiabzkcywjvkffgr.supabase.co/functions/v1/monitor-activations';
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets
  where name = 'cron_secret' limit 1;
  if v_secret is null or length(v_secret) = 0 then
    raise exception 'VAULT_CRON_SECRET_MISSING';
  end if;
  select extversion into v_cron_version from pg_catalog.pg_extension where extname = 'pg_cron';
  if v_cron_version is null then raise exception 'PG_CRON_EXTENSION_NOT_INSTALLED'; end if;
  if not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') then
    raise exception 'PG_NET_EXTENSION_NOT_INSTALLED';
  end if;
  if string_to_array(v_cron_version, '.')::integer[] >= array[1, 5, 0] then
    v_schedule := '10 seconds';
  end if;

  perform cron.unschedule(jobid) from cron.job where jobname = 'online-sim-monitor-activations';
  perform cron.schedule(
    'online-sim-monitor-activations', v_schedule,
    format(
      $cmd$select net.http_post(url := %L, headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')), body := '{}'::jsonb);$cmd$,
      v_url
    )
  );
end;
$$;

revoke all on function public.configure_vt_activation_monitor_schedule() from public, anon, authenticated;
grant execute on function public.configure_vt_activation_monitor_schedule() to service_role;

-- Configure the worker during migration when the existing secret and
-- extensions are already present. Otherwise the function remains available
-- for an administrator to call after those prerequisites are configured.
do $$
begin
  if to_regclass('cron.job') is not null
     and to_regclass('vault.decrypted_secrets') is not null
     and exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net')
     and exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron')
     and exists (select 1 from vault.decrypted_secrets where name = 'cron_secret' and length(decrypted_secret) > 0) then
    perform public.configure_vt_activation_monitor_schedule();
  end if;
end;
$$;

-- Claims a due activation under a row lock. next_monitor_at doubles as a
-- short lease so overlapping cron invocations cannot process one row twice.
create or replace function public.vt_claim_expired_activation_cancellation(p_order_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_order public.orders; v_slug text;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then return false; end if;
  select slug into v_slug from public.providers where id = v_order.provider_id;

  if v_slug is null or v_slug = 'proxnum'
     or v_order.provider_activation_id is null
     or v_order.code is not null
     or v_order.sms_received_at is not null
     or v_order.status not in ('WAITING_FOR_SMS', 'EXPIRING', 'CANCELLING')
     or (v_order.financial_status = 'HOLDING' and (v_order.expires_at is null or v_order.expires_at > now()))
     or (v_order.next_monitor_at is not null and v_order.next_monitor_at > now())
     or v_order.financial_status not in ('HOLDING', 'NONE') then
    return false;
  end if;

  update public.orders
  set status = 'CANCELLING',
      provider_cancellation_confirmed = false,
      next_monitor_at = now() + interval '120 seconds',
      last_monitored_at = now(),
      updated_at = now()
  where id = p_order_id;
  return true;
end;
$$;

-- Recheck under the same order lock immediately before the remote request.
create or replace function public.vt_authorize_activation_cancellation_request(p_order_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_order public.orders; v_slug text;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then return false; end if;
  select slug into v_slug from public.providers where id = v_order.provider_id;
  return v_slug is not null
     and v_slug <> 'proxnum'
     and v_order.status = 'CANCELLING'
     and v_order.provider_activation_id is not null
     and v_order.code is null
     and v_order.sms_received_at is null
     and v_order.financial_status in ('HOLDING', 'NONE')
     and (v_order.financial_status = 'NONE' or v_order.expires_at <= now());
end;
$$;

-- An observed provider SMS wins atomically against cancellation finalization.
-- The order lock and wallet-hold RPC run in this same transaction.
create or replace function public.vt_record_activation_sms_and_capture(
  p_order_id uuid,
  p_code text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_order public.orders; v_slug text;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then return false; end if;
  select slug into v_slug from public.providers where id = v_order.provider_id;
  if v_slug is null or v_slug = 'proxnum' then return false; end if;

  if v_order.sms_received_at is not null or v_order.code is not null then
    return true;
  end if;
  if v_order.status not in ('WAITING_FOR_SMS', 'EXPIRING', 'CANCELLING') then
    return false;
  end if;

  update public.orders
  set status = 'SMS_RECEIVED',
      code = nullif(btrim(p_code), ''),
      sms_received_at = now(),
      next_monitor_at = null,
      updated_at = now()
  where id = p_order_id;

  if v_order.financial_status = 'HOLDING' then
    perform public.capture_wallet_hold(p_order_id);
    update public.orders
    set status = 'COMPLETED', financial_status = 'CAPTURED', completed_at = now(), updated_at = now()
    where id = p_order_id;
  end if;
  return true;
end;
$$;

-- This is the only monitor path that releases a VT-NUM hold. It requires an
-- exact terminal status from a targeted provider status query, and rechecks
-- SMS/code while holding the order row lock before the ledger transition.
create or replace function public.vt_finalize_confirmed_activation_cancellation(
  p_order_id uuid,
  p_provider_status text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_order public.orders; v_slug text; v_status_attempt record;
begin
  if p_provider_status not in ('CANCELLED', 'EXPIRED') then return false; end if;
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then return false; end if;
  select slug into v_slug from public.providers where id = v_order.provider_id;

  if v_slug is null or v_slug = 'proxnum'
     or v_order.status <> 'CANCELLING'
     or v_order.provider_activation_id is null
     or v_order.code is not null
     or v_order.sms_received_at is not null
     or (v_order.financial_status = 'HOLDING' and (v_order.expires_at is null or v_order.expires_at > now())) then
    return false;
  end if;

  -- The worker must have persisted the most recent exact-operation status
  -- response. A caller-supplied status string alone is not provider proof.
  select pa.status, pa.metadata->>'mappedStatus' as mapped_status, pa.started_at
  into v_status_attempt
  from public.provider_attempts pa
  where pa.order_id = p_order_id
    and pa.provider_id = v_order.provider_id
    and pa.action = 'STATUS'
  order by pa.started_at desc
  limit 1;
  if not found
     or v_status_attempt.status <> 'SUCCESS'
     or v_status_attempt.mapped_status <> p_provider_status
     or v_status_attempt.started_at < now() - interval '2 minutes' then
    return false;
  end if;

  if v_order.financial_status = 'HOLDING' then
    perform public.release_wallet_hold(p_order_id);
    update public.orders
    set status = 'EXPIRED', financial_status = 'RELEASED',
        provider_cancellation_confirmed = true, expired_at = now(),
        next_monitor_at = null, updated_at = now()
    where id = p_order_id;
  elsif v_order.financial_status = 'NONE' then
    update public.orders
    set status = 'FAILED', provider_cancellation_confirmed = true,
        next_monitor_at = null, updated_at = now()
    where id = p_order_id;
  else
    return false;
  end if;
  return true;
end;
$$;

create or replace function public.vt_schedule_activation_monitor_retry(
  p_order_id uuid,
  p_reason text,
  p_retry_seconds integer default 60
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_order public.orders; v_slug text;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then return false; end if;
  select slug into v_slug from public.providers where id = v_order.provider_id;
  if v_slug is null or v_slug = 'proxnum'
     or v_order.status not in ('WAITING_FOR_SMS', 'EXPIRING', 'CANCELLING')
     or v_order.code is not null or v_order.sms_received_at is not null then
    return false;
  end if;
  update public.orders
  set next_monitor_at = now() + make_interval(secs => greatest(15, least(p_retry_seconds, 300))),
      monitor_failures = coalesce(monitor_failures, 0) + 1,
      last_monitor_error = left(coalesce(p_reason, 'UNKNOWN'), 200),
      last_monitored_at = now(), updated_at = now()
  where id = p_order_id;
  return true;
end;
$$;

revoke all on function public.vt_claim_expired_activation_cancellation(uuid),
  public.vt_authorize_activation_cancellation_request(uuid),
  public.vt_record_activation_sms_and_capture(uuid, text),
  public.vt_finalize_confirmed_activation_cancellation(uuid, text),
  public.vt_schedule_activation_monitor_retry(uuid, text, integer)
  from public, anon, authenticated;
grant execute on function public.vt_claim_expired_activation_cancellation(uuid),
  public.vt_authorize_activation_cancellation_request(uuid),
  public.vt_record_activation_sms_and_capture(uuid, text),
  public.vt_finalize_confirmed_activation_cancellation(uuid, text),
  public.vt_schedule_activation_monitor_retry(uuid, text, integer)
  to service_role;
