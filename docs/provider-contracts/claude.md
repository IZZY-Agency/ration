# Claude personal usage contract

Verified locally on 2026-07-11 from the authenticated Claude Usage page in an
isolated `WKWebView`.

## Request

- Method: `GET`
- Origin: `https://claude.ai`
- Path shape: `/api/organizations/{uuid}/usage`
- Authentication: the WebView's own isolated website data store

### Organization discovery (revised 2026-08-13)

Claude.ai's 2026-08 frontend migration moved the usage page to
`/new#settings/usage` and stopped requesting `/api/organizations/{uuid}/usage`
from the page itself, so the pre-migration rule ("take the exact resource path
the usage page requested") went permanently blind. `ClaudeOrganizationResolver`
now resolves the org id, in order:

1. the **`lastActiveOrg` cookie** — claude.ai's own active-workspace selector
   (live-verified 2026-08-13: non-httpOnly, value is the org uuid). Read via an
   origin-guarded bridge script on EVERY resolution so a workspace switch is
   picked up at the next poll; its value must parse as a UUID before use.
2. **`GET /api/organizations`** (live-verified 2026-08-13: array of
   `{uuid, name, capabilities[], rate_limit_tier, billing_type}`; the chat org
   carries `"chat"` in `capabilities`). Selected only when unambiguous — a
   single org, or a single chat-capable org; a list with any undecodable
   element is never selected from. `401/403` here surfaces as
   sign-in-required.
3. **org-scoped `performance` resource entries**, consulted only when the
   list is unknowable and accepted only when UNANIMOUS — every entry naming
   the same org. Conflicting page evidence (or a list that PROVED ambiguity
   or proved the only viable org invalid) refuses resolution rather than
   guessing, because a wrong guess would publish another workspace's usage.

The resolved id is memoized in memory per account for the fallback steps only
(the cookie is re-read every time); a `404` from the usage endpoint drops the
memo and re-resolves once with that org excluded. Nothing is persisted to
disk.

### Plan detection (live-verified 2026-09-24)

After a successful usage fetch the adapter reads the RESOLVED org's
`rate_limit_tier` and `capabilities` from `GET /api/organizations` (the same
list as above; cached per org uuid for 30 minutes in the resolver, and
refreshed for free whenever resolution itself decodes the list). Verified on
a Max 20x account: `rate_limit_tier: "default_claude_max_20x"`,
`capabilities: ["chat", "claude_max"]`.

| `rate_limit_tier` | Plan |
| --- | --- |
| `default_claude_max_20x` | Max 20x (verified) |
| `default_claude_max_5x` | Max 5x (inferred) |
| other `default_claude_*` without "max", and no `claude_max` capability | Pro (inferred) |
| anything else | unknown — logged once (`NSLog`, the raw tier only, no account data) |

Best effort: a failed or wrong-shaped list never fails the usage fetch
(`rate_limit_tier` of the wrong type reads as absent and never makes the org
element undecodable for resolution). The plan lands on `AccountRecord.plan`
with `planSource: detected`; a user's own choice (`planSource: user`) is
never overwritten. An unknown value clears a previously detected plan.

## Response fields used

```text
five_hour: object | null
  utilization: number
  resets_at: ISO-8601 string | null

seven_day: object | null
  utilization: number
  resets_at: ISO-8601 string | null
```

`utilization` is percentage used on a `0...100` scale. The adapter normalizes
it once as `remainingFraction = 1 - utilization / 100`; the app presents the
corresponding used percentage.

At least one window with valid utilization is required. A missing or null reset
time is accepted and displayed without a reset schedule. A missing window or
missing utilization is unavailable while another valid window remains.
Out-of-range utilization or a malformed non-null reset time is treated as an
integration change, as is a response with no usable verified windows.

## `limits[]` array — model-scoped weekly windows (Fable)

Verified 2026-07-21 by live read-only inspection of the authenticated Max
`/usage` response. The response also carries a top-level **`limits`** array — a
modern, labeled representation (the top-level `five_hour`/`seven_day` still
duplicate two of its entries; the top-level `seven_day_opus`/`seven_day_sonnet`/
etc. were `null`). Only the model-scoped weekly entry is read from here; 5h/weekly
stay on the legacy fields above.

```text
limits: array | null
  [].kind: "session" | "weekly_all" | "weekly_scoped" | (other, ignored)
  [].group: "session" | "weekly"
  [].percent: number            # 0…100, SAME scale as `utilization`
  [].severity: string           # e.g. "normal" (informational only)
  [].resets_at: ISO-8601 string
  [].is_active: boolean
  [].scope: object | null
    model: { id: string | null, display_name: string }   # e.g. "Fable"
    surface: (ignored)
```

The **model weekly window** (`.modelWeekly`) is the entry with
`kind == "weekly_scoped"` and a non-empty `scope.model.display_name`. It maps to
`UsageWindow` via `remainingFraction = 1 - percent / 100`, `resetsAt` from
`resets_at`, and `label` from `scope.model.display_name`. Cadence is weekly (its
`resets_at` matches `weekly_all`).

- **Presence gates visibility (Max-only):** absent `limits`, no `weekly_scoped`
  model entry, empty `display_name`, or out-of-range `percent` → no window; the
  row/history/alert simply does not appear. No plan-tier is inferred.
- **`is_active` is NOT a visibility gate.** It marks the currently *binding*
  constraint (a model window at 46% was `is_active:false` while `weekly_all` was
  active at 57%). The window renders whenever present; `severity`/`is_active` may
  inform emphasis only.
- **Robustness:** `limits` is an evolving, provider-controlled array. It is
  decoded leniently — an individually unparseable entry is dropped and a
  malformed array shape yields no model window, so it can never fail the whole
  `/usage` decode (the 5h/weekly windows always survive).

## Send contract (auto-start 5h window)

Captured 2026-07-13 via the contract probe (shapes only — no tokens, ids, or
values) while sending one message in a fresh Claude session. Used by the opt-in
auto-start feature to start the 5h window at reset.

- **Send message:** `POST /api/organizations/{org}/chat_conversations/{conversation}/completion`
  - Request body key-shape (values redacted):
    `prompt: string`, `model: string`, `timezone: string`,
    `rendering_mode: string`, `attachments: []`, `files: []`,
    `sync_sources: []`, `tools: [{name, …}]`, plus one object field
    (personalization). Response streams SSE (no JSON body); a `200` is success.
  - **Create is required first** (confirmed by live validation 2026-07-13: a
    completion to a fresh conversation uuid returns `404`). The sender creates
    the reusable keep-alive conversation via
    `POST /api/organizations/{org}/chat_conversations` with `{uuid, name}`, then
    POSTs the completion to that uuid. A stored conversation that later 404s
    (deleted) is recreated once and retried. The minimal completion body
    (`prompt`, `model`, `timezone`, `rendering_mode:"messages"`, empty
    `attachments`/`files`/`sync_sources`/`tools`) was live-validated to succeed
    and deliver the message.
- **Value discovery:** `model` and `rendering_mode` values are redacted in the
  contract by design. The sender reads a current `model` string at runtime from
  the account's own `GET /api/organizations/{org}/chat_conversations` response
  (each conversation carries a `model`), so no model string is hardcoded.
- Org uuid: the send is STRUCTURALLY bound to the organization the
  triggering usage snapshot's data actually came from —
  `UsageSnapshot.organizationID`, set by the adapter after full payload
  validation and carried IN MEMORY ONLY (excluded from the snapshot's
  `CodingKeys`, so it is never persisted). The auto-start policy FAILS
  CLOSED when its snapshot carries no org; live discovery exists only for
  the explicitly unbound manual debug send, and even that discovery refuses
  mixed-workspace page evidence (the resolver's unanimity rule).

## Capture boundary

The local contract probe stored only method, sanitized path, status, and JSON
key/type shape. It did not store response values, query strings, headers,
cookies, email addresses, tokens, or organization identifiers.

Set `RATION_CLAUDE_CONTRACT_FIXTURE` to a local sanitized probe
file to run the optional captured-shape regression test.
