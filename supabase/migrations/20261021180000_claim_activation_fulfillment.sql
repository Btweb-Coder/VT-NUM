-- Restore the atomic activation fulfillment claim.
-- This migration must be applied to TEST first.

create or replace function public.claim_activation_fulfillment(
  p_order_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
begin
  select *
    into v_order
    from public.orders
   where id = p_order_id
   for update;

  -- Fail closed without exposing whether another user's order exists.
  if not found then
    return false;
  end if;

  if v_order.user_id <> p_user_id then
    return false;
  end if;

  -- Only a newly created order can be claimed.
  if v_order.status <> 'CREATED' then
    return false;
  end if;

  update public.orders
     set status = 'PROVIDER_REQUESTING',
         updated_at = now()
   where id = p_order_id;

  return found;
end;
$$;

revoke all on function public.claim_activation_fulfillment(uuid, uuid)
  from public, anon, authenticated;

grant execute on function public.claim_activation_fulfillment(uuid, uuid)
  to service_role;
