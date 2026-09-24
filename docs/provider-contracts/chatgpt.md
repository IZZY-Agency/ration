# ChatGPT personal Codex usage contract

Verified on 2026-07-12 with a real personal ChatGPT subscription in an
isolated `WKWebsiteDataStore`, then updated on 2026-07-13 after ChatGPT began
returning a weekly-only primary window for the observed account. The local
capture retained only redacted paths and response shapes; no headers, cookies,
tokens, account identifiers, raw payloads, or quota values are stored in Git.

## Usage page

- Advertised entry URL: `https://chatgpt.com/codex/settings/usage`
- Canonical signed-in URL:
  `https://chatgpt.com/codex/cloud/settings/analytics#usage`
- The available window set is account-dependent. A response may contain only
  the weekly window.

## Request

- Origin: `https://chatgpt.com`
- Method: `GET`
- Path: `/backend-api/wham/usage`
- Authentication: the same-origin page reads `/api/auth/session`, then sends
  its bearer token and account context to the usage endpoint. Token decoding
  and request-header construction stay inside the account's isolated WebKit
  page. Authentication material is never returned to Swift, logged, or stored
  by the app.

The response fields used by the app are:

```text
rate_limit.primary_window.used_percent
rate_limit.primary_window.limit_window_seconds
rate_limit.primary_window.reset_at
rate_limit.secondary_window.used_percent
rate_limit.secondary_window.limit_window_seconds
rate_limit.secondary_window.reset_at
```

Window position does not determine its meaning. The app classifies each window
using `limit_window_seconds`: `18000` is the five-hour window and `604800` is
the weekly window. This handles the current weekly-only response where
`primary_window` is weekly and `secondary_window` is absent. Older responses
without duration metadata retain the original positional fallback.

`used_percent` is a number in `0...100`. `reset_at` is a Unix timestamp in
seconds. The app converts used percentage to its normalized remaining fraction
exactly once, then the UI derives used capacity from that normalized value.

`plan_type` (live-verified 2026-09-24: `"prolite"` on a Pro 5x account) is
read for plan detection: `prolite` → Pro 5x (verified), `pro` → Pro 20x,
`plus` → Plus; any other value is unknown and logged once (`NSLog`, the raw
value only). It is lenient — a missing or wrong-shaped `plan_type` never fails
the usage decode. The plan lands on `AccountRecord.plan` with
`planSource: detected`; a user's own choice is never overwritten.

Credit information, analytics history, and other response fields are not
needed for the menu-bar limits and are ignored.

## Error and change handling

- `401` and `403` require reauthentication.
- `429` is rate limited and honors a numeric `Retry-After` value when present.
- Other non-success statuses are provider-server errors.
- ChatGPT windows absent from a successful response are omitted from the
  account card. Before the first successful response, the card shows the weekly
  slot as unavailable.
- A successful response with neither verified window is treated as an
  integration change; the app never infers or fabricates a quota value.

The current field names and duration-based classification were cross-checked
against the installed official Codex CLI 0.144.2 and the matching OpenAI Codex
source. The browser contract, not CLI bearer-token behavior, is authoritative
for this app.
