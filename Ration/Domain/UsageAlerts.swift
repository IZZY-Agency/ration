import Foundation

/// The two-step alert ladder.
///
/// IMPORTANT: the raw values 75/90 are OPAQUE PERSISTENCE TOKENS and the
/// ordering key — they are NOT the thresholds. Since 0.27.0 the actual
/// percentages are configured per provider × window (`ThresholdPair`) and
/// resolved at evaluation time. The raw values are frozen at 75/90 purely so
/// every `alerts.json` written before 0.27.0 keeps decoding byte-identically;
/// changing them would silently invalidate every stored `notifiedTier`.
/// Do not read a percentage off this enum.
enum AlertTier: Int, Comparable, Codable, Sendable {
    case warning = 75
    case critical = 90

    static func < (lhs: AlertTier, rhs: AlertTier) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The tier for a used fraction under the given configured thresholds,
    /// or nil below the warning threshold.
    static func forUsed(_ used: Double, thresholds: ThresholdPair) -> AlertTier? {
        if used >= thresholds.criticalFraction { .critical }
        else if used >= thresholds.warningFraction { .warning }
        else { nil }
    }
}

enum AlertEvent: Equatable, Sendable {
    // `label` carries the window's API-provided label (e.g. Fable's scoped
    // model display name) through to `AlertMessage`, so the notification can
    // read "Fable" instead of the generic kind wording. It defaults to nil so
    // every existing call site (5h/weekly, which never have a window label)
    // stays source- and byte-output-identical.
    // `percent` is the CONFIGURED threshold this crossing fired at, carried so
    // the copy can state the real number — `tier`'s raw value is a persistence
    // token, not a percentage.
    case threshold(kind: UsageWindowKind, tier: AlertTier, percent: Int, label: String? = nil)
    case reset(kind: UsageWindowKind, label: String? = nil)
    case reauthRequired
    case rateLimited
    // Cursor's spend ladder. `thresholdCents`/`spentCents` are dollars-as-cents,
    // never a percentage — Cursor's API exposes spend with no denominator (see
    // `SpendThresholds`), so there is no fraction to report.
    case spendThreshold(tier: AlertTier, thresholdCents: Int, spentCents: Int)
}

/// Per-window edge-trigger memory. `hasObserved` guards against firing `reset`
/// on the first-ever snapshot. `identity` is the window's last-seen `resetsAt`;
/// it is recorded but has NO reader — it is deliberately NOT the reset trigger
/// (Claude's 5h/weekly windows are ROLLING: `resetsAt` advances on every poll,
/// so keying reset off an identity change fired a false reset every poll).
/// The reset trigger is `lastRemaining`: `.reset` fires when `remainingFraction`
/// jumps UP by at least `AlertPolicy.resetUpwardEpsilon` between polls — a
/// freed-capacity heuristic (capacity that wasn't available last poll now is),
/// which is the observable signal of a window having rolled over.
/// `notifiedTier` is the highest tier already alerted for the CURRENT window;
/// cleared on reset.
struct WindowAlertMemory: Codable, Equatable, Sendable {
    var hasObserved = false
    var identity: Date?
    var notifiedTier: AlertTier?
    var lastRemaining: Double?
    /// The highest tier the user has DISMISSED from the attention drop for the
    /// current window. Independent of `notifiedTier`: a notification firing
    /// does not dismiss the row, and dismissing the row does not suppress the
    /// notification. Cleared on reset alongside `notifiedTier`, so a new
    /// window shows its row again. A later escalation still surfaces —
    /// `critical > warning` — so dismissing a warning never hides a critical.
    var dismissedTier: AlertTier?
    init() {}

    /// Per-field lossy decode. `decodeIfPresent` is NOT enough: it defaults
    /// only when a key is absent or null, and still THROWS on a present key
    /// whose value has the wrong type. Any throw escaping here reaches
    /// `AlertStateStore.load()`, which recovers by setting `states = [:]` —
    /// discarding EVERY account's alert memory over one malformed field on
    /// one account, which then re-fires alerts those accounts already sent.
    ///
    /// `try?` collapses both cases to the property's default, so damage is
    /// contained to the field that is actually corrupt. Losing one watermark
    /// can cost at most one duplicate alert; losing the map costs one per
    /// account per window.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasObserved = (try? c.decode(Bool.self, forKey: .hasObserved)) ?? false
        identity = try? c.decode(Date.self, forKey: .identity)
        notifiedTier = try? c.decode(AlertTier.self, forKey: .notifiedTier)
        lastRemaining = try? c.decode(Double.self, forKey: .lastRemaining)
        dismissedTier = try? c.decode(AlertTier.self, forKey: .dismissedTier)
    }
}

/// Edge-trigger memory for Cursor's usage-based spend.
///
/// Keyed off `periodStart` — the invoice's identity. `WindowAlertMemory`'s
/// doc warns that `resetsAt` must NEVER be the reset trigger because Claude's
/// ROLLING windows advance it on every poll; since 2026-08-27 the same is
/// true of Cursor's `periodEndMs` (the open invoice ends "now"), which is why
/// this memory stopped keying on `periodEnd` too. The start moves only at
/// rollover, so it is the trustworthy signal. See `AlertPolicy.spendPeriodAdvanced`.
///
/// `lastSpentCents` is recorded but is NOT an independent re-arm trigger: the
/// spend figure is recomputed each fetch by summing chargeable events, so a
/// refund, a corrected event, or a rounding change could lower it mid-cycle
/// and re-alert spuriously. A decrease only counts alongside an advanced
/// boundary.
///
/// WARNING for future edits: any new stored property added here must be
/// decoded in `init(from:)` below, never left to the synthesized `Decodable`.
/// `AccountAlertState`'s outer `decodeIfPresent(SpendAlertMemory.self,
/// forKey: .spend)` only supplies a default when the `spend` key is entirely
/// ABSENT — a `spend` object that IS present but fails to decode still throws
/// out of that `decodeIfPresent`, and `AlertStateStore.load()` turns that
/// throw into a wipe of every account's alert memory, not just this field.
struct SpendAlertMemory: Codable, Equatable, Sendable {
    var hasObserved = false
    /// The invoice's identity — see `CursorSpend.periodStart`. Re-arm and the
    /// drop's snooze key on THIS advancing; `periodEnd` is recorded but is
    /// not a boundary any more.
    var periodStart: Date?
    var periodEnd: Date?
    var notifiedTier: AlertTier?
    var lastSpentCents: Int?
    /// Attention-drop dismissal for the current billing period. See
    /// `WindowAlertMemory.dismissedTier`; cleared when the period advances.
    var dismissedTier: AlertTier?
    init() {}

    /// Per-field lossy decode, for the reasons given on
    /// `WindowAlertMemory.init(from:)` — the blast radius of a throw here is
    /// every account's alert memory, not this object's.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasObserved = (try? c.decode(Bool.self, forKey: .hasObserved)) ?? false
        periodStart = try? c.decode(Date.self, forKey: .periodStart)
        periodEnd = try? c.decode(Date.self, forKey: .periodEnd)
        notifiedTier = try? c.decode(AlertTier.self, forKey: .notifiedTier)
        lastSpentCents = try? c.decode(Int.self, forKey: .lastSpentCents)
        dismissedTier = try? c.decode(AlertTier.self, forKey: .dismissedTier)
    }
}

struct AccountAlertState: Codable, Equatable, Sendable {
    var fiveHour = WindowAlertMemory()
    var weekly = WindowAlertMemory()
    var modelWeekly = WindowAlertMemory()
    var spend = SpendAlertMemory()
    var notifiedReauth = false
    var notifiedRateLimited = false
    init() {}

    // Backward-compatible decode: older persisted files predate `modelWeekly`
    // and `spend` and have no such keys. A synthesized `init(from:)` would
    // `decode` (not `decodeIfPresent`) every stored property including these
    // — since neither is Optional at the type level, that would THROW on
    // legacy files, dropping the account's entire alert memory (fiveHour/
    // weekly tiers, notifiedReauth/notifiedRateLimited) on next load. Mirrors
    // the `UsageWindow`/`UsageSnapshot` backward-compat pattern.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try c.decodeIfPresent(WindowAlertMemory.self, forKey: .fiveHour) ?? WindowAlertMemory()
        weekly = try c.decodeIfPresent(WindowAlertMemory.self, forKey: .weekly) ?? WindowAlertMemory()
        modelWeekly = try c.decodeIfPresent(WindowAlertMemory.self, forKey: .modelWeekly) ?? WindowAlertMemory()
        spend = try c.decodeIfPresent(SpendAlertMemory.self, forKey: .spend) ?? SpendAlertMemory()
        notifiedReauth = try c.decodeIfPresent(Bool.self, forKey: .notifiedReauth) ?? false
        notifiedRateLimited = try c.decodeIfPresent(Bool.self, forKey: .notifiedRateLimited) ?? false
    }
}

/// Pure edge-trigger policy turning a raw usage snapshot + account state into
/// alert events, given prior alert memory. Never re-fires a tier that has
/// already been notified for the current window; only a window reset (freed
/// capacity — `remainingFraction` jumping up) re-arms the tier ladder.
enum AlertPolicy {
    /// Minimum upward jump in `remainingFraction` between polls that counts
    /// as "capacity was freed" (i.e. a window reset). Claude's rolling
    /// windows advance `resetsAt` every poll, so `resetsAt` alone can never
    /// be used as the reset signal — only an actual jump in remaining
    /// capacity indicates a real reset.
    static let resetUpwardEpsilon = 0.05

    static func evaluate(
        previous: AccountAlertState,
        snapshot: UsageSnapshot?,
        state: AccountViewState,
        thresholds: (UsageWindowKind) -> ThresholdPair,
        spendThresholds: SpendThresholds
    ) -> (events: [AlertEvent], next: AccountAlertState) {
        var next = previous
        var events: [AlertEvent] = []

        evaluateWindow(.fiveHour, window: snapshot?.fiveHour, thresholds: thresholds(.fiveHour), memory: &next.fiveHour, events: &events)
        evaluateWindow(.weekly, window: snapshot?.weekly, thresholds: thresholds(.weekly), memory: &next.weekly, events: &events)
        evaluateWindow(.modelWeekly, window: snapshot?.modelWeekly, thresholds: thresholds(.modelWeekly), memory: &next.modelWeekly, events: &events)
        evaluateSpend(snapshot?.cursorSpend, thresholds: spendThresholds, memory: &next.spend, events: &events)

        // Reauth — fire once on entry, re-arm on leaving.
        if case .reauthenticationRequired = state {
            if !next.notifiedReauth { events.append(.reauthRequired); next.notifiedReauth = true }
        } else {
            next.notifiedReauth = false
        }
        // Rate-limited — same edge-trigger.
        if case .rateLimited = state {
            if !next.notifiedRateLimited { events.append(.rateLimited); next.notifiedRateLimited = true }
        } else {
            next.notifiedRateLimited = false
        }

        return (events, next)
    }

    private static func evaluateWindow(
        _ kind: UsageWindowKind,
        window: UsageWindow?,
        thresholds: ThresholdPair,
        memory: inout WindowAlertMemory,
        events: inout [AlertEvent]
    ) {
        guard let window else { return } // no data → leave memory untouched

        // Reset detection: freed capacity, not a changed `resetsAt`. Claude's
        // 5h/weekly windows are ROLLING — `resetsAt` advances on essentially
        // every poll even mid-window — so an identity change is not evidence
        // of a real reset and must never be used to trigger one (that was the
        // false-positive bug: it fired `.reset` on almost every poll). Freed
        // capacity instead looks like `remainingFraction` jumping UP by at
        // least `resetUpwardEpsilon` since the last observation — i.e. capacity
        // that wasn't there before is now available. The very first
        // observation (`hasObserved == false` / no `lastRemaining` yet) must
        // never fire, since there is nothing to compare against.
        //
        // The `- 1e-10` slack absorbs binary floating-point error so a jump of
        // *exactly* the epsilon still counts as "at least the epsilon" — e.g.
        // `0.15 - 0.10` evaluates to 0.04999999999999999, just under a bare
        // 0.05 threshold. Mirrors `UsageWindowSeries.detectReset`'s history-path
        // guard for the identical rolling-window class.
        let remaining = window.remainingFraction
        if
            memory.hasObserved,
            let last = memory.lastRemaining,
            remaining - last >= Self.resetUpwardEpsilon - 1e-10
        {
            events.append(.reset(kind: kind, label: window.label))
            memory.notifiedTier = nil
            // The drop dismissal is scoped to the window that was dismissed —
            // a fresh window must be able to raise its row again, or one ✕
            // silences that subject for good.
            memory.dismissedTier = nil
        }
        // `identity` is still recorded (it costs nothing and keeps the last
        // `resetsAt` in persisted state) but is no longer what triggers
        // `.reset` above — see `WindowAlertMemory`'s doc.
        memory.identity = window.resetsAt
        memory.lastRemaining = remaining
        memory.hasObserved = true

        // Threshold: fire once when crossing UP to a not-yet-notified tier.
        if let tier = AlertTier.forUsed(window.usedFraction, thresholds: thresholds),
           memory.notifiedTier == nil || tier > memory.notifiedTier! {
            let percent = tier == .critical
                ? thresholds.criticalPercent
                : thresholds.warningPercent
            events.append(
                .threshold(kind: kind, tier: tier, percent: percent, label: window.label)
            )
            memory.notifiedTier = tier
        }
    }

    /// Cursor's spend ladder. Structurally parallel to `evaluateWindow`, with
    /// one deliberate difference: the re-arm signal is a NEW INVOICE — its
    /// start (`CursorSpend.periodStart` ← `periodStartMs`) advancing, per
    /// `spendPeriodAdvanced` — not freed capacity, which spend does not have.
    /// A spend DECREASE alone is not evidence of rollover — spend is re-summed
    /// from chargeable events each fetch, so a refund or correction can lower
    /// it mid-cycle.
    /// Whether a later Cursor observation belongs to a NEW invoice.
    ///
    /// The one place this is decided — `evaluateSpend`'s re-arm and the
    /// attention drop's snooze (`AppModel.endAttentionSnoozeIfNeeded`) both
    /// ask here, so they cannot disagree. Keyed on the period START: since
    /// 2026-08-27 Cursor reports `periodEndMs` as the fetch time for the open
    /// invoice, so the end advances on every poll and proves nothing.
    ///
    /// Memory written before `periodStart` existed (0.28.1) has only its
    /// `periodEnd` as boundary evidence. On that one upgrade poll a new start
    /// AT or PAST it is a crossed boundary — `>=` because under the old
    /// semantics the end WAS the next start (Sep 1 == Sep 1) — while a start
    /// before it is the same invoice, whether that end was a real boundary or
    /// the drifting "now" of the last legacy poll. Without either the previous
    /// start or end there is no evidence of rollover.
    static func spendPeriodAdvanced(from previous: SpendAlertMemory, toStart next: Date?) -> Bool {
        guard let next else { return false }
        if let previousStart = previous.periodStart { return next > previousStart }
        guard let legacyEnd = previous.periodEnd else { return false }
        return next >= legacyEnd
    }

    private static func evaluateSpend(
        _ spend: CursorSpend?,
        thresholds: SpendThresholds,
        memory: inout SpendAlertMemory,
        events: inout [AlertEvent]
    ) {
        guard let spend else { return } // no data → leave memory untouched

        if
            memory.hasObserved,
            Self.spendPeriodAdvanced(from: memory, toStart: spend.periodStart)
        {
            memory.notifiedTier = nil
            memory.dismissedTier = nil
        }
        memory.periodStart = spend.periodStart
        memory.periodEnd = spend.resetsAt
        memory.lastSpentCents = spend.spentCents
        memory.hasObserved = true

        // Shared with the attention drop — see `SpendThresholds.tier(forSpentCents:)`.
        let crossing = thresholds.tier(forSpentCents: spend.spentCents)
        let tier = crossing?.tier
        let thresholdCents = crossing?.thresholdCents

        if
            let tier, let thresholdCents,
            memory.notifiedTier == nil || tier > memory.notifiedTier!
        {
            events.append(
                .spendThreshold(
                    tier: tier,
                    thresholdCents: thresholdCents,
                    spentCents: spend.spentCents
                )
            )
            memory.notifiedTier = tier
        }
    }
}
