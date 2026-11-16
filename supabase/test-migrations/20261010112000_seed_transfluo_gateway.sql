-- Seed Transfluo using the existing adapter's documented API contract.
-- Keep inactive until the exchange rate and sandbox flow are verified.

insert into public.payment_gateways (
  slug,
  active,
  endpoint,
  provider_currency,
  exchange_rate,
  min_provider_amount,
  config,
  secret_name
)
values (
  'transfluo',
  false,
  'https://direct-api.transfluo.com',
  'XAF',
  1,
  2,
  '{"api":{"requestPath":"/requestPayment.php","checkPath":"/checkStatus.php"}}'::jsonb,
  'PAYMENT_SECRETS'
)
on conflict (slug) do update set
  endpoint = excluded.endpoint,
  provider_currency = excluded.provider_currency,
  min_provider_amount = excluded.min_provider_amount,
  config = public.payment_gateways.config || excluded.config,
  secret_name = excluded.secret_name,
  updated_at = now();

-- exchange_rate=1 is only a placeholder.
-- Verify the amount conversion convention and configure the approved
-- USD-to-XAF rate before enabling Transfluo, if the wallet uses USD.
