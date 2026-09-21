# Known Limitations

Deliberate, owner-accepted trade-offs. Each entry names the defect, the trace,
why it is accepted, and what would fix it if that ever changes.

## Mid-send quiet-hours edit race (accepted 2026-07-21)

**What:** editing the warm-up quiet-hours/holiday schedule while a Claude
warm-up send is already in flight does not retract that send. The schedule is
consulted at send *scheduling* time; a send that passed the gate and is
mid-flight commits even if the user marks that hour quiet during the
seconds-long window.

**Worst case:** one warm-up message lands inside a quiet hour that was added
while the send was in flight. No data loss, no repeated sends, self-corrects
from the next scheduling decision on.

**Why accepted:** the proper fix is to apply the synchronous schedule-intent
pattern that the alerts and auto-start toggles already use to the warm-up
scheduler — a design pass on a hardened concurrency path, disproportionate to a rare,
cosmetic, self-correcting miss of an opt-in convenience feature.

**If it ever matters:** route warm-up sends through a tap-time intent claim +
commit-point recheck, the same pattern `requestSetAutoStart` /
`requestSetUsageAlerts` use.

## Per-view minute timers (dropped 2026-07-21)

**What:** several views each run their own minute-cadence `TimelineView` /
timer for relative-time captions instead of sharing one tick source.

**Why dropped:** minute-cadence wake-ups across a handful of lightweight views
are unmeasurable against the app's polling baseline; consolidating them is a
multi-view refactor with real regression surface and no user-perceptible win.
Assessed as low value and formally dropped rather than left as roadmap noise.

## Cursor shows usage-based spend, not "% of plan" (accepted 2026-07-27)

**What:** Cursor's `cursor.com` web API does not expose a budget percentage.
The "Auto %/API %" figures live in the Cursor *editor's* status bar, backed by
a separate `api2.cursor.sh` service unreachable from a `cursor.com` web view
(the only surface this app can read). What the web API serves is a dollar/cent
spend model: per-event `chargedCents`, a plan tier (`membershipType`), and the
billing-cycle boundary (`periodEndMs`). So the Cursor card shows the real
usage-based dollars spent this cycle plus the reset date — not a percentage.

**Why accepted:** rendering "% of budget" would require inventing a budget
denominator Cursor does not meter, i.e. fabricated data. Showing real spend is
the honest representation of what the API provides. Documented, not a bug. An
earlier design assumed percentage pools; it was removed when a live probe showed
the API does not provide them.

## Cursor spend is summed in-page from the current cycle's events (accepted 2026-07-27, revised 2026-07-28)

**What:** the adapter aggregates `chargedCents` over the current billing
cycle's chargeable usage events inside the web view rather than paging every
event back to Swift. Cursor exposes **no server-side date filter and no
aggregate spend endpoint** — live-verified 2026-07-28: `{startDate, endDate}`
returns an empty object, `{startDateMs, endDateMs}` and `{month, year}` are
silently ignored, and `get-monthly-invoice` never embeds events despite
`includeUsageEvents`. So the cycle bound must be applied client-side.

**Why accepted:** events arrive strictly newest-first and `page`/`pageSize`
compose, so the walk stops at the first event older than the cycle start —
in practice one 250-event page (~113 KB, well under the 1 MiB read cap). The
walk is capped at 20 pages; if it cannot prove it covered the whole cycle it
reports `integrationChanged` rather than a silently understated total.

## Cursor's reset is the invoice boundary, not the quota month (accepted 2026-07-28)

**What (as accepted 2026-07-28; superseded below):** the reset shown on the
Cursor card was `periodEndMs` from `get-monthly-invoice`, then a
**calendar-month** boundary (e.g. `2026-08-01`). A separate subscription/quota
month exists — `/api/usage` reported `startOfMonth: 2026-07-17T12:09:04Z`,
i.e. request quotas roll on the 17th — and the two do not coincide.

**Why accepted:** the card reports usage-based **spend**, which is invoiced on
the calendar boundary, so `periodEndMs` is the correct reset for the figure
shown. The quota month governs a different quantity (per-model request counts)
that this card does not display. Noted so the two are never conflated.

**Revised 2026-08-27:** Cursor now reports the open invoice's `periodEndMs` as
the server's current time — it advanced from `12:36:06Z` to `12:42:08Z`
across two consecutive polls, one second before each `fetchedAt`. It is an
observation cutoff, not a boundary. `periodStartMs` is still the calendar
boundary — live-verified on the same account as `2026-08-01T00:00:00Z`,
stable across polls. Two consequences, both shipped in 0.28.2: (1) the
invoice's identity is its **start** (`periodStartMs`, now carried as
`CursorSpend.periodStart`), and
both the spend re-arm and the attention drop's ✕ snooze key on that — keying
on the end had undone the ✕ on every refresh; (2) the card no longer claims
"resets in …" for an end that is not in the future, so under the new
behaviour it reads just "no usage-based charges" / "this cycle". Deriving the
real boundary from the calendar month is possible but is inference, not an
API value, so it is deliberately not done.

## A correct Cursor card reads $0.00 whenever usage stays inside the plan allowance (accepted 2026-07-28)

**What:** usage-based charges accrue only past a plan's included allowance, so
an account inside its allowance has no chargeable events at all and the card
legitimately shows `$0.00` for the whole cycle. Live-verified 2026-07-28 on a
yearly Pro account: zero events in the current cycle.

**Why accepted:** `$0.00` is the true value, and no alternative real signal
exists to substitute for it (no percentage is exposed, and the legacy
`/api/usage` counters are `gpt-4`-only and read zero). The caption says "no
usage-based charges" rather than "this cycle" so a true zero is distinguishable
from a failed read.
