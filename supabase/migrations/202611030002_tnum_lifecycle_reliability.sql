begin;

-- Store provider-supplied SMS metadata separately from the local insertion time.
alter table public.tnum_activation_sms
  add column if not exists provider_sender text,
  add column if not exists provider_received_at timestamptz,
  add column if not exists provider_payload jsonb;

-- Preserve the last exact-operation cancellation evidence for reconciliation.
alter table public.tnum_provider_operations
  add column if not exists provider_evidence jsonb not null default '{}'::jsonb;

-- Persist richer SMS data while retaining the existing transaction lock and
-- status transition that arbitrates against cancellation finalization.
create or replace function public.tnum_save_activation_sms(
  p_activation uuid,
  p_provider_message_key text,
  p_message_text text,
  p_code text,
  p_provider_status text,
  p_sender text,
  p_provider_received_at timestamptz,
  p_provider_payload jsonb
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.tnum_activations;
  has_message boolean;
  is_answered boolean;
begin
  select * into a from public.tnum_activations
    where id = p_activation for update;
  if not found then return false; end if;

  if a.status in ('completed', 'expired', 'cancelled', 'failed') then
    return false;
  end if;

  has_message := p_provider_message_key is not null
    and length(trim(p_provider_message_key)) > 0
    and p_message_text is not null
    and length(trim(p_message_text)) > 0;
  is_answered := p_provider_status = 'TZ_NUM_ANSWER';
  if not has_message and not is_answered then return false; end if;

  if has_message then
    insert into public.tnum_activation_sms (
      activation_id, provider_message_key, message_text, code,
      provider_sender, provider_received_at, provider_payload
    ) values (
      p_activation, p_provider_message_key, p_message_text, nullif(p_code, ''),
      nullif(p_sender, ''), p_provider_received_at, p_provider_payload
    )
    on conflict (activation_id, provider_message_key) do update set
      message_text = excluded.message_text,
      code = coalesce(excluded.code, public.tnum_activation_sms.code),
      provider_sender = coalesce(excluded.provider_sender, public.tnum_activation_sms.provider_sender),
      provider_received_at = coalesce(excluded.provider_received_at, public.tnum_activation_sms.provider_received_at),
      provider_payload = coalesce(excluded.provider_payload, public.tnum_activation_sms.provider_payload);
  end if;

  if a.status <> 'completion_pending' then
    update public.tnum_activations set
      status = 'sms_received',
      provider_status = p_provider_status,
      cancellation_state = case
        when cancellation_state in ('pending', 'retry', 'uncertain') then 'uncertain'
        else cancellation_state
      end,
      next_retry_at = null,
      last_provider_check_at = now()
    where id = p_activation;
  else
    update public.tnum_activations set
      provider_status = p_provider_status,
      last_provider_check_at = now()
    where id = p_activation;
  end if;

  -- An SMS that wins the race invalidates an in-flight no-SMS close claim.
  update public.tnum_provider_operations set
    operation = 'poll', state = 'sms_received', next_attempt_at = null,
    last_error_code = null, updated_at = now()
  where activation_id = p_activation
    and operation = 'close' and state = 'sending';

  return true;
end;
$$;

create or replace function public.tnum_record_cancellation_evidence(
  p_activation uuid,
  p_evidence jsonb
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_evidence is null or jsonb_typeof(p_evidence) <> 'object' then
    raise exception 'INVALID_CANCELLATION_EVIDENCE';
  end if;
  update public.tnum_provider_operations set
    provider_evidence = provider_evidence || jsonb_build_object(
      'last_cancellation', p_evidence
    ),
    updated_at = now()
  where activation_id = p_activation;
  return found;
end;
$$;

-- Atomically reclaim a cancellation claim left in `sending` by a stopped
-- worker. A valid SMS wins under the same activation row lock and is excluded.
create or replace function public.tnum_recover_stale_cancellation_claims()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row record;
  recovered integer := 0;
begin
  for v_row in
    select a.id
    from public.tnum_activations a
    join public.tnum_provider_operations o on o.activation_id = a.id
    where a.status = 'expiration_pending'
      and a.cancellation_state = 'pending'
      and a.provider_operation_id is not null
      and o.operation = 'close'
      and o.state = 'sending'
      and o.updated_at <= now() - interval '2 minutes'
      and not exists (
        select 1 from public.tnum_activation_sms s
        where s.activation_id = a.id
      )
    for update of a, o skip locked
  loop
    update public.tnum_activations set
      cancellation_state = 'retry',
      next_retry_at = now(),
      failure_code = 'STALE_CANCELLATION_CLAIM_RECOVERED',
      last_provider_check_at = now()
    where id = v_row.id
      and status = 'expiration_pending'
      and cancellation_state = 'pending'
      and not exists (
        select 1 from public.tnum_activation_sms s
        where s.activation_id = v_row.id
      );

    if found then
      update public.tnum_provider_operations set
        state = 'retry', next_attempt_at = now(),
        last_error_code = 'STALE_CANCELLATION_CLAIM_RECOVERED',
        updated_at = now(),
        provider_evidence = provider_evidence || jsonb_build_object(
          'stale_claim_recovered_at', now()
        )
      where activation_id = v_row.id
        and operation = 'close' and state = 'sending';
      recovered := recovered + 1;
    end if;
  end loop;
  return recovered;
end;
$$;

-- The claim remains one atomic operation and refuses activations with any
-- persisted SMS before moving the operation row to `sending`.
create or replace function public.tnum_claim_activation_cancellation(
  p_activation uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.tnum_activations;
  op_state text;
begin
  select * into a from public.tnum_activations
    where id = p_activation for update;
  if not found or a.provider_operation_id is null
    or a.deadline_at > now()
    or a.status <> 'expiration_pending'
    or a.cancellation_state not in ('not_requested', 'retry', 'uncertain')
    or (a.next_retry_at is not null and a.next_retry_at > now())
    or exists (select 1 from public.tnum_activation_sms s where s.activation_id = p_activation)
  then return false; end if;

  select state into op_state from public.tnum_provider_operations
    where activation_id = p_activation for update;
  if not found or op_state = 'sending' then return false; end if;

  update public.tnum_activations set
    cancellation_state = 'pending',
    cancellation_attempts = cancellation_attempts + 1,
    next_retry_at = null
  where id = p_activation;

  update public.tnum_provider_operations set
    operation = 'close', state = 'sending', attempts = attempts + 1,
    next_attempt_at = null, updated_at = now(),
    provider_evidence = provider_evidence || jsonb_build_object(
      'last_claimed_at', now(), 'claimed_tzid', a.provider_operation_id
    )
  where activation_id = p_activation and state <> 'sending';

  if not found then
    update public.tnum_activations set
      cancellation_state = 'retry', next_retry_at = now() + interval '10 seconds'
    where id = p_activation and cancellation_state = 'pending';
    return false;
  end if;
  return true;
end;
$$;

-- A release requires evidence for this exact operation, an exact precheck
-- without SMS, and either TZ_OVER_EMPTY or a successful close followed by a
-- targeted postcheck. ERROR_NO_OPERATIONS alone never qualifies.
create or replace function public.tnum_finalize_activation_cancellation(
  p_activation uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.tnum_activations;
  e jsonb;
  released boolean;
begin
  select * into a from public.tnum_activations
    where id = p_activation for update;
  if not found then return false; end if;

  if exists (select 1 from public.tnum_activation_sms s where s.activation_id = p_activation) then
    update public.tnum_activations set
      status = 'sms_received', cancellation_state = 'uncertain', next_retry_at = null
    where id = p_activation and status = 'expiration_pending';
    return false;
  end if;

  if a.status <> 'expiration_pending'
    or a.cancellation_state <> 'pending'
    or a.provider_operation_id is null then return false; end if;

  select provider_evidence -> 'last_cancellation' into e
    from public.tnum_provider_operations
    where activation_id = p_activation and operation = 'close'
    for update;
  if e is null
    or e ->> 'tzid' is distinct from a.provider_operation_id::text
    or e ->> 'precheck_tzid' is distinct from a.provider_operation_id::text
    or e ->> 'precheck_no_messages' is distinct from 'true'
    or e ->> 'no_sms_confirmed' is distinct from 'true'
  then return false; end if;

  if e ->> 'terminal_status' = 'TZ_OVER_EMPTY' then
    if e ->> 'precheck_status' <> 'TZ_OVER_EMPTY'
      and e ->> 'postcheck_status' <> 'TZ_OVER_EMPTY' then return false; end if;
  elsif e ->> 'terminal_status' = 'CLOSED_AFTER_CONFIRMED_REQUEST' then
    if e ->> 'precheck_status' not in ('TZ_NUM_WAIT', 'TZ_INPOOL')
      or e ->> 'close_tzid' is distinct from a.provider_operation_id::text
      or e ->> 'close_response' <> '1'
      or e ->> 'postcheck_code' <> 'ERROR_NO_OPERATIONS'
      or e ->> 'postcheck_tzid' is distinct from a.provider_operation_id::text
    then return false; end if;
  else
    return false;
  end if;

  select public.tnum_release_activation_reservation(p_activation) into released;
  if released is not true then return false; end if;

  update public.tnum_activations set
    status = 'expired', cancellation_state = 'confirmed',
    provider_status = coalesce(e ->> 'terminal_status', e ->> 'postcheck_status'),
    provider_terminal_at = now(), next_retry_at = null,
    failure_code = null, last_provider_check_at = now()
  where id = p_activation;
  update public.tnum_provider_operations set
    operation = 'close', state = 'confirmed', next_attempt_at = null,
    last_error_code = null, updated_at = now()
  where activation_id = p_activation;
  return true;
end;
$$;

-- The worker is invoked once per minute. A shorter lease permits recovery after
-- a process crash while the provider-call pacing and global lease remain in
-- force to prevent overlapping workers.
create or replace function public.tnum_claim_provider_worker()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  poll_seconds integer;
  claimed_lease uuid := gen_random_uuid();
begin
  select provider_poll_seconds into poll_seconds
    from public.tnum_runtime_config where id = true;
  update public.tnum_provider_worker_state set
    last_started_at = now(), lease_id = claimed_lease,
    lease_expires_at = now() + interval '5 minutes'
  where id = true
    and (lease_id is null or lease_expires_at <= now())
    and (last_started_at is null or
      last_started_at <= now() - make_interval(secs => poll_seconds));
  if not found then return null; end if;
  return claimed_lease;
end;
$$;

revoke all on function public.tnum_save_activation_sms(uuid,text,text,text,text,text,timestamptz,jsonb)
  from public, anon, authenticated;
revoke all on function public.tnum_record_cancellation_evidence(uuid,jsonb)
  from public, anon, authenticated;
revoke all on function public.tnum_recover_stale_cancellation_claims()
  from public, anon, authenticated;
revoke all on function public.tnum_claim_activation_cancellation(uuid)
  from public, anon, authenticated;
revoke all on function public.tnum_finalize_activation_cancellation(uuid)
  from public, anon, authenticated;
revoke all on function public.tnum_claim_provider_worker()
  from public, anon, authenticated;

grant execute on function public.tnum_save_activation_sms(uuid,text,text,text,text,text,timestamptz,jsonb)
  to service_role;
grant execute on function public.tnum_record_cancellation_evidence(uuid,jsonb)
  to service_role;
grant execute on function public.tnum_recover_stale_cancellation_claims()
  to service_role;
grant execute on function public.tnum_claim_activation_cancellation(uuid)
  to service_role;
grant execute on function public.tnum_finalize_activation_cancellation(uuid)
  to service_role;
grant execute on function public.tnum_claim_provider_worker()
  to service_role;

-- This migration is intentionally local until a reviewed deployment. When
-- applied, it installs only the T-NUM lifecycle job and reads the existing
-- secret from Vault at invocation time.
do $$
declare
  v_secret text;
  v_url constant text := 'https://mvvmdiabzkcywjvkffgr.supabase.co/functions/v1/tnum-monitor-activations';
begin
  if not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') then
    raise exception 'PG_CRON_EXTENSION_NOT_INSTALLED';
  end if;
  if not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') then
    raise exception 'PG_NET_EXTENSION_NOT_INSTALLED';
  end if;
  if to_regclass('vault.decrypted_secrets') is null then
    raise exception 'VAULT_DECRYPTED_SECRETS_NOT_AVAILABLE';
  end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets
    where name = 'cron_secret' limit 1;
  if v_secret is null or length(v_secret) = 0 then
    raise exception 'VAULT_CRON_SECRET_MISSING';
  end if;
  perform cron.unschedule(jobid) from cron.job
    where jobname = 'online-sim-monitor-tnum-activations';
  perform cron.schedule(
    'online-sim-monitor-tnum-activations', '* * * * *',
    format(
      $cmd$select net.http_post(url := %L, headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')), body := '{}'::jsonb);$cmd$,
      v_url
    )
  );
end;
$$;

commit;
