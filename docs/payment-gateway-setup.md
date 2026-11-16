# Payment gateway setup

Payments are handled only by Supabase Edge Functions. The Flutter app receives
no provider credential and cannot write a wallet, ledger entry, or payment
intent state.

Deploy the SQL migrations and Edge Functions, then set `PAYMENT_SECRETS` as a
JSON secret with members only for gateways that have been configured and tested.
Each member uses the credential keys required by its documented adapter:

- Fapshi: `apiUser`, `apiKey`, `webhookSecret`
- CinetPay: `apiKey`, `siteId`
- Transfluo: `merchantId`, `apiKey`

Create each non-secret `payment_gateways` row through a trusted administrator
workflow. Its `config.api` must contain the documented endpoint paths from the
provider account, including `requestPath`/`checkPath` (Fapshi and Transfluo) or
`initiatePath`/`checkPath`/`initiateStaticBody` (CinetPay). Do not enable a row
until its sandbox request and status-response contracts have been tested.

Fapshi supports a tested webhook wake-up endpoint at
`https://mvvmdiabzkcywjvkffgr.supabase.co/functions/v1/payment-webhook?gateway=fapshi`.
Configure the same `webhookSecret` in the Fapshi dashboard and `PAYMENT_SECRETS`.
The function authenticates `x-wh-secret` and still verifies status server to
server before it credits a wallet. It is a Fapshi-only addition and does not
change the existing Transfluo flow.

`monitor-topups` is invoked by Supabase Cron every minute. It verifies pending
payments server-to-server. A verified success credits the wallet with
`credit_payment_intent`; amount/currency mismatches enter
`REQUIRES_RECONCILIATION` and never credit automatically. The customer refresh
button uses the same server-side verifier.

Set `CRON_SECRET` in Edge Function secrets and Vault before scheduling the
monitor. Never manually edit a wallet balance to resolve a payment: use a
controlled, auditable adjustment workflow instead.

## Final manual checklist

All credentials are entered in **Supabase Dashboard → Edge Functions → Secrets**
as the single JSON secret named `PAYMENT_SECRETS`; never put them in the Flutter
build or a database row. Configure non-secret rows in **Database → Table editor
→ payment_gateways**. Keep `active` false until the final test succeeds.

### Fapshi

1. In the Fapshi dashboard, create and activate a service. Obtain its **API
   User** and **API Key**, and configure a separate webhook secret. Fapshi documents
   these as the `apiuser`/`apikey` request headers and requires the webhook to
   send `x-wh-secret`.
2. Add those three values under the `fapshi` member of `PAYMENT_SECRETS` using
   the keys `apiUser`, `apiKey`, and `webhookSecret`.
3. The migration creates an inactive sandbox row using
   `https://sandbox.fapshi.com`, `/direct-pay`, and `/payment-status`. In
   `payment_gateways`, replace the placeholder USD-to-XAF `exchange_rate` with
   your current approved rate before enabling it. Set the webhook URL to
   `https://mvvmdiabzkcywjvkffgr.supabase.co/functions/v1/payment-webhook?gateway=fapshi`.
4. Whitelist the Supabase Edge Function egress address if Fapshi requires it,
   then run one Fapshi sandbox collection. Confirm the webhook/log entry and
   that server-side status verification creates exactly one `DEPOSIT` ledger
   entry before setting `active=true`.

### CinetPay

1. In the CinetPay merchant dashboard, obtain the **API key**, **site ID**, and
   webhook HMAC secret (Integrations). Put only the API key and site ID under
   the `cinetpay` member of `PAYMENT_SECRETS` as `apiKey` and `siteId`.
2. In `payment_gateways`, configure the provider URL/currency/exchange/minimum
   and the documented `initiatePath`, `checkPath`, and `initiateStaticBody`.
3. Keep the row inactive. Before activation, complete a sandbox test that
   checks the CinetPay status endpoint independently of the redirect/callback.
   CinetPay callbacks can be duplicated and their documentation requires a
   server-side verification; the current production adapter therefore remains
   polling-only until its HMAC callback contract is sandbox-tested.

### Transfluo

The existing Transfluo integration is preserved as provided by the Transfluo
developer. This project does not impose an additional webhook, crypto, or
activation requirement beyond that established integration.
