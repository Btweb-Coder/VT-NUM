-- Non-secret payment gateway bootstrap.  All rows remain inactive until the
-- merchant has completed the documented sandbox checks.
insert into public.payment_gateways (
  slug, active, endpoint, provider_currency, exchange_rate,
  min_provider_amount, config, secret_name
) values (
  'fapshi', false, 'https://sandbox.fapshi.com', 'XAF', 1, 100,
  '{"api":{"requestPath":"/direct-pay","checkPath":"/payment-status"},"environment":"sandbox","checkout":"direct-pay"}'::jsonb,
  'PAYMENT_SECRETS'
) on conflict (slug) do update set
  endpoint = excluded.endpoint,
  provider_currency = excluded.provider_currency,
  min_provider_amount = excluded.min_provider_amount,
  config = public.payment_gateways.config || excluded.config,
  secret_name = excluded.secret_name,
  updated_at = now();

-- `exchange_rate=1` is a deliberately inactive placeholder. Set the current
-- USD-to-XAF rate in Table Editor before enabling Fapshi; never enable a row
-- with this placeholder value.
