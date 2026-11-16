-- Completion migration: UI compatibility and atomic replacement reservation.
alter table public.services add column if not exists flag text not null default '';
alter table public.payment_intents add column if not exists gateway_slug text;
update public.payment_intents i set gateway_slug=g.slug from public.payment_gateways g where i.gateway_id=g.id and i.gateway_slug is null;

create or replace function public.reserve_replacement_request(
  p_user_id uuid, p_old_order_id uuid, p_key text
) returns table(order_id uuid, is_new boolean)
language plpgsql security definer set search_path=public as $$
declare v_old public.orders; v_key public.idempotency_keys; v_new_id uuid;
begin
  if length(trim(p_key)) not between 1 and 200 then raise exception 'INVALID_IDEMPOTENCY_KEY'; end if;
  select * into v_key from public.idempotency_keys
    where user_id=p_user_id and operation='REPLACEMENT' and key=trim(p_key) for update;
  if found and v_key.order_id is not null then
    order_id := v_key.order_id; is_new := false; return next; return;
  end if;
  select * into v_old from public.orders where id=p_old_order_id for update;
  if not found or v_old.user_id <> p_user_id then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_old.status <> 'EXPIRED' then raise exception 'ORDER_NOT_EXPIRED'; end if;
  if v_old.financial_status <> 'RELEASED' then raise exception 'WALLET_HOLD_NOT_RELEASED'; end if;
  if not v_old.provider_cancellation_confirmed then raise exception 'PROVIDER_CANCELLATION_NOT_CONFIRMED'; end if;

  insert into public.idempotency_keys(user_id,operation,key,status)
  values(p_user_id,'REPLACEMENT',trim(p_key),'RESERVED') on conflict(user_id,operation,key) do nothing;
  select * into v_key from public.idempotency_keys
    where user_id=p_user_id and operation='REPLACEMENT' and key=trim(p_key) for update;
  if v_key.order_id is not null then
    order_id := v_key.order_id; is_new := false; return next; return;
  end if;
  if v_old.replacement_order_id is not null then
    update public.idempotency_keys set order_id=v_old.replacement_order_id,status='COMPLETED',updated_at=now() where id=v_key.id;
    order_id := v_old.replacement_order_id; is_new := false; return next; return;
  end if;
  insert into public.orders(user_id,service_id,country_id,status,financial_status,replaced_order_id)
    values(p_user_id,v_old.service_id,v_old.country_id,'CREATED','NONE',p_old_order_id) returning id into v_new_id;
  update public.orders set status='REPLACING',replacement_order_id=v_new_id where id=p_old_order_id;
  update public.idempotency_keys set order_id=v_new_id,status='PROCESSING',updated_at=now() where id=v_key.id;
  order_id := v_new_id; is_new := true; return next;
end $$;

create or replace function public.fail_replacement_request(p_old_order_id uuid,p_new_order_id uuid,p_code text,p_message text default null)
returns void language plpgsql security definer set search_path=public as $$
begin
  update public.orders set status='FAILED',failure_code=p_code,failure_message=p_message where id=p_new_order_id and status in ('CREATED','PROVIDER_REQUESTING');
  update public.orders set status='EXPIRED' where id=p_old_order_id and status='REPLACING' and replacement_order_id=p_new_order_id;
end $$;

revoke all on function public.reserve_replacement_request(uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.fail_replacement_request(uuid,uuid,text,text) from public, anon, authenticated;

create or replace function public.claim_payment_intent(p_intent_id uuid, p_manual boolean default false)
returns table(id uuid, user_id uuid, gateway_id uuid, provider_transaction_id text, provider_amount numeric, provider_currency char(3), status public.payment_intent_status)
language plpgsql security definer set search_path=public as $$
declare v public.payment_intents;
begin
  select * into v from public.payment_intents where id=p_intent_id for update;
  if not found then raise exception 'PAYMENT_INTENT_NOT_FOUND'; end if;
  if v.status <> 'PENDING' then return; end if;
  if not p_manual and (v.next_poll_at is null or v.next_poll_at > now()) then return; end if;
  if v.poll_lease_until is not null and v.poll_lease_until > now() then return; end if;
  update public.payment_intents set poll_lease_id=gen_random_uuid(),poll_lease_until=now()+interval '45 seconds',poll_count=poll_count+1,last_polled_at=now() where id=v.id;
  return query select v.id,v.user_id,v.gateway_id,v.provider_transaction_id,v.provider_amount,v.provider_currency,v.status;
end $$;
revoke all on function public.claim_payment_intent(uuid,boolean) from public, anon, authenticated;

-- Flutter consumes these through authenticated Realtime streams.  The DO block
-- keeps this migration safe when a table has already been added manually.
do $$ begin
  alter publication supabase_realtime add table public.wallets;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.orders;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.payment_intents;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.app_update_config;
exception when duplicate_object then null; end $$;
