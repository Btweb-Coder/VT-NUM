-- Server-side workflow primitives. They are intentionally not granted to client roles.
create or replace function public.reserve_activation_request(p_user_id uuid,p_service_id uuid,p_country_id uuid,p_key text)
returns table(order_id uuid, is_new boolean) language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_order_id uuid; v_new boolean := false;
begin
 if length(trim(p_key)) not between 1 and 200 then raise exception 'INVALID_IDEMPOTENCY_KEY'; end if;
 insert into public.idempotency_keys(user_id,operation,key,status) values(p_user_id,'ACTIVATION',trim(p_key),'RESERVED') on conflict(user_id,operation,key) do nothing;
 select id, k.order_id into v_id, v_order_id from public.idempotency_keys k where user_id=p_user_id and operation='ACTIVATION' and key=trim(p_key) for update;
 if v_order_id is null then
   insert into public.orders(user_id,service_id,country_id,status,financial_status) values(p_user_id,p_service_id,p_country_id,'CREATED','NONE') returning id into v_order_id;
   update public.idempotency_keys set order_id=v_order_id,status='PROCESSING',updated_at=now() where id=v_id;
   is_new := true;
 else is_new := false; end if;
 order_id := v_order_id;
 return next;
end $$;

create or replace function public.transition_order(p_order_id uuid,p_from public.order_status[],p_to public.order_status,p_extra jsonb default '{}'::jsonb)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_status public.order_status;
begin
 select status into v_status from public.orders where id=p_order_id for update;
 if not found then raise exception 'ORDER_NOT_FOUND'; end if;
 if v_status=p_to then return false; end if;
 if not v_status=any(p_from) then raise exception 'INVALID_ORDER_TRANSITION:%->%',v_status,p_to; end if;
 update public.orders set status=p_to,
   code=coalesce(p_extra->>'code',code), provider_cancellation_confirmed=coalesce((p_extra->>'provider_cancellation_confirmed')::boolean,provider_cancellation_confirmed),
   sms_received_at=case when p_to='SMS_RECEIVED' then now() else sms_received_at end,
   completed_at=case when p_to='COMPLETED' then now() else completed_at end,
   expired_at=case when p_to='EXPIRED' then now() else expired_at end,
   cancelled_at=case when p_to='CANCELLED' then now() else cancelled_at end,
   financial_status=case when p_to='COMPLETED' then 'CAPTURED'::public.order_financial_status when p_to='EXPIRED' then 'RELEASED'::public.order_financial_status else financial_status end
 where id=p_order_id;
 return true;
end $$;

create or replace function public.credit_payment_intent(p_intent_id uuid,p_provider_status text,p_provider_transaction_id text)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_intent public.payment_intents; v_wallet public.wallets;
begin
 select * into v_intent from public.payment_intents where id=p_intent_id for update;
 if not found then raise exception 'PAYMENT_INTENT_NOT_FOUND'; end if;
 if v_intent.status='SUCCESSFUL' then return false; end if;
 if v_intent.status not in ('PENDING','INITIATED') then raise exception 'PAYMENT_NOT_CREDITABLE'; end if;
 select * into v_wallet from public.wallets where user_id=v_intent.user_id for update; if not found then raise exception 'WALLET_NOT_FOUND'; end if;
 update public.wallets set available_balance=available_balance+v_intent.amount where user_id=v_intent.user_id;
 insert into public.wallet_ledger_entries(user_id,payment_intent_id,entry_type,amount,currency,balance_before,balance_after,provider_amount,provider_currency,fee,exchange_rate,provider_transaction_id,provider_status,idempotency_key)
 values(v_intent.user_id,v_intent.id,'DEPOSIT',v_intent.amount,'USD',v_wallet.available_balance,v_wallet.available_balance+v_intent.amount,v_intent.provider_amount,v_intent.provider_currency,v_intent.fee,v_intent.exchange_rate,p_provider_transaction_id,p_provider_status,'deposit:'||v_intent.id);
 update public.payment_intents set status='SUCCESSFUL',provider_status=p_provider_status,provider_transaction_id=p_provider_transaction_id,credited_at=now(),poll_lease_id=null,poll_lease_until=null where id=p_intent_id;
 return true;
end $$;

revoke all on function public.reserve_activation_request(uuid,uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.transition_order(uuid,public.order_status[],public.order_status,jsonb) from public, anon, authenticated;
revoke all on function public.credit_payment_intent(uuid,text,text) from public, anon, authenticated;
