# TypeSafe contract (live-verified 2026-09-30)

> **Switched off 2026-10-01 (`Provider.switchedOff`) until TypeSafe exposes
> a key-readable balance and usage API.** Live diagnosis: a
> background read lands on Cloudflare's bot check (page title "Just a
> moment...", only `cdn-cgi/challenge-platform` requests) once the pass earned
> in the visible sign-in expires (about 30 minutes). Ration does not try to get past Cloudflare's check. Existing
> accounts stay on disk, dormant and unlisted; the Add API Account sheet
> offers the Admin-key platforms only.

TypeSafe (typesafe.ai) is a pay-as-you-go AI API with a prepaid balance.
Ration shows the balance, this cycle's spend, daily usage and the credit
grants of a TypeSafe account, and warns before a grant expires. It never
tops up, redeems or changes anything.

## Account kind

An API account, not a subscription: added from Settings › Add API Account
(TypeSafe → Sign In…), listed with the API accounts in Settings and under the
popover's API header. It still signs in through a web session: a TypeSafe API
key reads nothing but the model (verified 2026-10-01: `/v1/usage`,
`/v1/billing`, `/v1/balance`, `/v1/credits`, `/v1/me`, `/v1/account` and
`/v1/organization` answer 404 to a key; the console's `/api/usage` answers 403).

## Session

- Sign-in: `https://console.typesafe.ai/settings/billing` in Ration's sign-in
  window. Signed out, the console redirects to `/login`, then
  `login.typesafe.ai` (Google or an emailed code) behind Cloudflare Turnstile.
  Google refuses embedded web views; the emailed code works. The user passes
  Turnstile by hand.
- `Provider.typeSafe.appHost` is `console.typesafe.ai` (not `typesafe.ai`), so
  the login host never counts as the provider page.
- Signed out on a refresh: the page settles on `login.typesafe.ai` or the
  console's `/login` → Sign in.

## Billing (the balance)

Not in any JSON route (`/api/billing`, `/api/credits`, `/api/balance` and
similar are 404) or in the page's HTML/RSC payload. Opening Settings › Billing
makes the page itself POST a Next.js server action to `/settings/billing`
(`next-action: <per-deployment id>`, response `text/x-component`). Its RSC
line `1:` is JSON:

```
{"ok":true,"data":{"billing":{"plan":"pay_as_you_go","spent":4.2,"freeCreditsRemaining":0.8,
 "balance":20.8,"purchased":20,"resetsInDays":3,"cycleLabel":"September 2026",
 "paymentMethod":{…},"autoPay":null,
 "credits":[{"id":"…","amount":5,"remaining":0.8,"createdAt":"2026-09-01T00:00:00Z",
             "expiresAt":"2026-10-01T00:00:00Z","reason":"free_tier_credit"},
            {"id":"…","amount":20,"remaining":20,"createdAt":"2026-09-10T12:00:00Z",
             "expiresAt":"2027-09-10T00:00:00Z","reason":"purchased_credits"}],
 "invoiceEmail":…,"billingAddress":…},"payments":[…],"hasMore":…,"credits":…}}
```

Ration never calls the action (its id changes with each deployment). Every
refresh loads the billing page with a document-start script
(`TypeSafeBillingCapture`, `.page` world, main frame) that wraps `fetch`,
reads a clone of the one POST to `/settings/billing` answering
`text/x-component` with a 1 MB byte cap, and extracts IN THE PAGE only the
permitted fields (`TypeSafeScripts.extractBilling`): `balance`, `spent`,
`cycleLabel`, `resetsInDays`, `autoPay` as "on"/"off", and per credit `id`,
`amount`, `remaining`, `expiresAt`, `reason`. Only that summary crosses the
WebKit bridge; payment method, invoice e-mail, billing address, payments,
`createdAt` and `plan` never do. The handler accepts only the main frame on
exactly `https://console.typesafe.ai` (port 443) and summaries up to 64 KB;
the summary is parsed as data and cleared once taken.

`free_tier_credit` → "Free credit", `purchased_credits` → "Purchased",
anything else → "Promotional". A missing or null `credits` list is partial,
never "no grants". Amounts are US dollars, rounded to cents; the next reset
counts from when the answer arrived.

## Usage (the bars)

`GET https://console.typesafe.ai/api/usage?granularity=day` (cookie session)
→ `{"buckets":[{"day","apiKeyId","apiKeyName","userId","userEmail","requests",
"inputTokens","outputTokens"}]}`, the last 30 days, one bucket per day and API
key. A dedicated in-page script (`WebUsageClient.fetchTypeSafeUsage`, 1 MB
bounded read) sums it per UTC day IN THE PAGE (`TypeSafeScripts
.aggregateUsage`) and returns only `[day, input, output, requests]` rows: key
ids and names, user ids and e-mails never cross the bridge. Estimated
dollars: input tokens × $0.042 per million (`TypeSafePrice`), output free, as
the console estimates; a live 30-day sum matched the console's own estimate. Days before
the answer's 30-day window are unknown and not drawn.

Billing and usage are read independently: either can fail while the other
lands, and each keeps its own read time (the card fades each on its own).

## Kept

In the account's snapshot (`usage-snapshots.json`): the balance and the grants
(`UsageCredits`), `TypeSafeSpend` (this cycle's spend, its label, the next
reset, auto-recharge on/off, read time) and `TypeSafeDailyUsage` (per-day
input/output tokens and requests, read time). "Read this session" is kept in
memory only, so a restored balance never warns before it is read again.

## Low-balance alert

Opt-in, Settings › Alerts › TypeSafe › Low balance (a dollar threshold, empty
is off). One notification and drop row when a balance read this session falls
strictly below it; a later reading at or above it (a top-up) re-arms. Only the
balance Ration already keeps is used; nothing more is read.
