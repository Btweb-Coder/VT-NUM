-- Fixed extra fee applied only to one-time SMS activations.
-- Rental purchases and extensions remain unchanged.

ALTER TABLE public.pricing_rules
ADD COLUMN activation_extra_fee numeric(20,6) NOT NULL DEFAULT 0
CHECK (activation_extra_fee >= 0);

CREATE OR REPLACE FUNCTION public.assign_activation_and_create_hold(
  p_order_id uuid,
  p_provider_id uuid,
  p_provider_activation_id text,
  p_phone_number text,
  p_provider_price numeric,
  p_currency char(3),
  p_service_code text,
  p_service_name text,
  p_country_code text,
  p_country_name text,
  p_country_flag text,
  p_expires_at timestamptz
)
RETURNS TABLE(
  customer_price numeric,
  markup_type text,
  markup_value numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders;
  v_wallet public.wallets;
  v_rule public.pricing_rules;
  v_customer numeric(20,6);
BEGIN
  IF p_provider_price <= 0
     OR p_currency <> 'USD'
     OR p_expires_at <= now()
  THEN
    RAISE EXCEPTION 'INVALID_ACTIVATION_PRICE';
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_order.status NOT IN ('CREATED', 'PROVIDER_REQUESTING')
  THEN
    RAISE EXCEPTION 'ORDER_NOT_ASSIGNABLE';
  END IF;

  SELECT *
  INTO v_rule
  FROM public.pricing_rules
  WHERE active
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRICING_UNAVAILABLE';
  END IF;

  -- Preserve the existing markup calculation, then add the fixed fee.
  v_customer := round(
    (
      CASE
        WHEN v_rule.markup_type = 'percentage'
          THEN p_provider_price * (1 + v_rule.markup_value / 100)
        ELSE p_provider_price + v_rule.markup_value
      END
    ) + v_rule.activation_extra_fee,
    6
  );

  IF v_customer <= 0 THEN
    RAISE EXCEPTION 'INVALID_CUSTOMER_PRICE';
  END IF;

  SELECT *
  INTO v_wallet
  FROM public.wallets
  WHERE user_id = v_order.user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'WALLET_NOT_FOUND';
  END IF;

  IF v_wallet.available_balance < v_customer THEN
    RAISE EXCEPTION 'INSUFFICIENT_BALANCE';
  END IF;

  UPDATE public.orders
  SET
    provider_id = p_provider_id,
    provider_activation_id = p_provider_activation_id,
    phone_number = p_phone_number,
    provider_price = round(p_provider_price, 6),
    markup_type = v_rule.markup_type,
    markup_value = v_rule.markup_value,
    markup_percentage = CASE
      WHEN v_rule.markup_type = 'percentage' THEN v_rule.markup_value
      ELSE 0
    END,
    customer_price = v_customer,
    currency = p_currency,
    service_code = p_service_code,
    service_name = p_service_name,
    country_code = p_country_code,
    country_name = p_country_name,
    country_flag = coalesce(p_country_flag, ''),
    assigned_at = now(),
    expires_at = p_expires_at,
    status = 'WAITING_FOR_SMS',
    financial_status = 'HOLDING',
    next_monitor_at = now(),
    monitor_failures = 0,
    last_monitor_error = NULL
  WHERE id = p_order_id;

  UPDATE public.wallets
  SET
    available_balance = available_balance - v_customer,
    held_balance = held_balance + v_customer
  WHERE user_id = v_order.user_id;

  INSERT INTO public.wallet_holds (
    order_id,
    user_id,
    amount,
    currency
  )
  VALUES (
    p_order_id,
    v_order.user_id,
    v_customer,
    'USD'
  );

  INSERT INTO public.wallet_ledger_entries (
    user_id,
    order_id,
    entry_type,
    amount,
    currency,
    balance_before,
    balance_after,
    idempotency_key
  )
  VALUES (
    v_order.user_id,
    p_order_id,
    'HOLD',
    v_customer,
    'USD',
    v_wallet.available_balance,
    v_wallet.available_balance - v_customer,
    'hold:' || p_order_id
  );

  customer_price := v_customer;
  markup_type := v_rule.markup_type;
  markup_value := v_rule.markup_value;

  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.assign_activation_and_create_hold(
  uuid, uuid, text, text, numeric, char(3),
  text, text, text, text, text, timestamptz
) FROM public, anon, authenticated;