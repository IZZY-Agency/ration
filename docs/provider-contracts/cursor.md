# Cursor personal usage contract

Probe run 2026-07-27 against a real **paid** Cursor subscription in an
isolated, non-persistent `WKWebView` launched with
`--capture-provider-contracts`. The capture stored only sanitized paths,
response key/type shapes, and two auth-presence booleans — no headers,
cookies, tokens, account identifiers, values, or quota numbers. 36 Cursor
captures were recorded across the dashboard load.

## Origin & authentication — the decisive finding

**All 36 captures are same-origin `https://cursor.com`.** Zero cross-origin
requests to `api2.cursor.sh` (or any other host) were observed. Zero
`Authorization` headers. Same-origin fetches use `credentials: "include"` —
i.e. the **session cookie**, same-origin.

Consequences:

- **A `cursor.com`-origin endpoint serves the data.** The dashboard reads
  everything it shows from `cursor.com` itself.
- **There is no cross-origin auth to handle.** No cross-origin request is made
  and there is no bearer token to reason about.
- **The app has no cross-origin fetch primitive.** `Provider.webOrigin` stays a
  single string and the injected same-origin guard is untouched, so Cursor adds
  nothing to the security surface that the Claude and ChatGPT integrations
  don't already have.

The adapter therefore uses the existing same-origin
`WebUsageClient.fetch(path:expectedOrigin:in:)` with
`expectedOrigin == "https://cursor.com"`, exactly like the Claude adapter.

## Observed structure

The dashboard is a Connect-RPC / REST mix. Response objects are wrapped (the
probe rendered the wrapper key as `_0`); unknown field names are `:redacted`
by the probe's allowlist. **Structural fields that surfaced un-redacted**
(they were in the candidate allowlist, so they are real Cursor field names):

```text
membershipType        : string   (plan tier)
subscriptionStatus    : string
billingCycleStart     : string
billingCycleEnd       : string
startOfMonth          : string   (on GET /api/usage)
```

- `GET /api/usage` (same-origin, cookie) exists and carries `startOfMonth`
  plus nested redacted structure — the legacy monthly request-count endpoint
  per community tooling.
- Several POST endpoints (Connect-RPC `DashboardService`-style) carry numeric
  and array payloads under redacted field names.

## Live-verified endpoints (2026-07-27, authenticated same-origin fetch)

Read directly from the authenticated dashboard via same-origin `fetch`
(field NAMES + types only; no values). All same-origin `cursor.com`, cookie
session:

```text
GET  /api/auth/stripe
  membershipType, individualMembershipType, isYearlyPlan,
  subscriptionStatus, customerBalance (number), isOnBillableAuto, ...
  → plan tier + account balance. NO usage percentage.

POST /api/dashboard/get-monthly-invoice  {month, year, includeUsageEvents}
  periodStartMs (string), periodEndMs (string), pricingDescription.id
  → THE BILLING-CYCLE BOUNDARIES (reset date). No percentage.

POST /api/dashboard/get-filtered-usage-events
  totalUsageEventsCount (number),
  usageEventsDisplay[]: { timestamp, model, kind, requestsCosts,
    usageBasedCosts (string), isTokenBasedCall, isChargeable,
    chargedCents (number), tokenUsage{inputTokens, outputTokens,
    cacheReadTokens, totalCents}, subscriptionProductId, ... }
  → DOLLAR/CENT-denominated per-event spend. No ready percentage.

GET  /api/usage
  { "<model>": { numRequests, numRequestsTotal, numTokens,
    maxTokenUsage, maxRequestUsage } }, startOfMonth
  → legacy per-model REQUEST COUNTS. No percentage.

POST /api/dashboard/get-hard-limit → { noUsageBasedAllowed }
```

## Request/response semantics (verified 2026-07-28, authenticated probe)

Verified by direct same-origin `fetch` against a real authenticated Pro account.

- **`month` is 0-INDEXED.** `{month: 6, year: 2026}` → period
  `2026-07-01 … 2026-08-01`; `{month: 7}` → `2026-08-01 … 2026-09-01`.
  Sending `getUTCMonth() + 1` therefore returns NEXT month's cycle.
- **`includeUsageEvents` is IGNORED.** The response is 158 bytes with exactly
  three keys — `pricingDescription` (only `{id}`), `periodStartMs`,
  `periodEndMs`. It NEVER embeds `usageEventsDisplay`. The plan's "preferred,
  cycle-bounded by construction" event source does not exist.
- **`periodStartMs`/`periodEndMs` are top-level STRINGS** (`$.periodEndMs`), no
  Connect-RPC wrapper — the defensive nesting DFS is unnecessary here.
- **`get-filtered-usage-events` is PAGINATED and NOT cycle-bounded.** Body `{}`
  returns 100 of `totalUsageEventsCount` events, ordered **strictly descending**
  by `timestamp` (page 1 = newest). `{pageSize: 1000}` returned all 518.
  Summing an unfiltered page yields arbitrary historical spend.
- **No server-side date filter exists.** `{startDate, endDate}` (ms strings)
  returns `{}` — an EMPTY object, HTTP 200, no `usageEventsDisplay` and no
  count. `{startDateMs, endDateMs}` and `{month, year}` are silently ignored
  (byte-identical to `{}`). Current-cycle spend must therefore be summed
  CLIENT-SIDE over `timestamp ∈ [periodStartMs, periodEndMs)`; descending order
  makes early-exit paging safe.
- **`chargedCents` is FRACTIONAL**, not integer cents (observed
  `26.698150634765625`, `42.54804992675781`). Round only the final sum.
- **A removed endpoint returns HTTP 200 + ~1.16 MB of HTML** (SPA catch-all;
  e.g. `get-user-usage-summary`, `get-monthly-spend` do not exist). `!ok` can
  NEVER detect a changed integration — `integrationChanged` must be decided by
  validating the decoded JSON shape, not the status code.
- **Two different "resets" exist** (as pinned 2026-07-28 — `periodEndMs` has
  since changed, see the next bullet). `periodEndMs` was a CALENDAR-month
  invoice boundary (`2026-08-01`), whereas `/api/usage.startOfMonth` was
  `2026-07-17T12:09:04Z` — the subscription/quota month rolls on the 17th. A
  card labelled "resets in Yd" must state WHICH reset it means; for
  usage-based *spend* the invoice boundary is the correct one.
- **`periodEndMs` is no longer a boundary (observed 2026-08-27).** For the
  OPEN invoice, `get-monthly-invoice` now reports `periodEndMs` as the
  server's current time: consecutive polls returned `12:36:06Z` and
  `12:42:08Z`, each one second before the app's `fetchedAt`. It advances on
  every poll and must not be used to detect rollover or to promise a reset
  — treat it as the observation cutoff. The app keys the invoice's identity
  on `periodStartMs` instead, and the card only shows a countdown for an end
  still in the future. `periodStartMs` is still the calendar boundary:
  live-verified 2026-08-27 as `2026-08-01T00:00:00Z`, stable across polls.

## No percentage, only spend

**Cursor does NOT expose ready-made percentage pools.** The community `totalPercentUsed`/`apiPercentUsed` fields
(from `api2.cursor.sh/GetCurrentPeriodUsage`) do not exist on the live
same-origin API. What Cursor actually serves is a **dollar/cents spend model**:
per-event `chargedCents`, a plan tier (`membershipType`), a billing period
(`periodStartMs`/`periodEndMs`), and legacy per-model request counts.

To render "% of monthly budget" the adapter would have to (a) map
`membershipType`→budget ($20/$60/$200 — public but hardcoded), and (b)
aggregate spend across the period (a heavy events sum; no clean aggregated
endpoint responded to probed params). Neither is a ready percentage.

Ration therefore shows Cursor as usage-based dollar spend for the current
billing period, summed from the period's events, instead of a percentage. The
trade-offs of that choice are recorded in `docs/KNOWN-LIMITATIONS.md`.

## Error & change handling

- `401`/`403` → reauthentication.
- `429` → rate limited, honoring numeric `Retry-After`.
- Other non-2xx → provider-server error.
- A successful response that fails to decode, or whose billing period or event
  amounts are missing or implausible → `integrationChanged`; a spend value is
  never inferred or fabricated.
