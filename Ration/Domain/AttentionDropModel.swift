import Foundation

/// One thing currently wanting attention: an account's window (or Cursor's
/// spend) sitting at or above a configured tier right now.
///
/// Carries its display facts rather than a reference to the snapshot, so the
/// panel renders straight from the row and never re-derives a number that
/// might have moved underneath it.
struct AttentionRow: Equatable, Identifiable, Sendable {
    /// Who the row is about: a subscription account or an API org.
    /// Consumers dispatch on it explicitly; an org UUID is never an account.
    enum Owner: Hashable, Sendable {
        case account(UUID)
        case apiOrg(UUID)
    }

    enum Subject: Equatable, Hashable, Sendable {
        case window(UsageWindowKind)
        case cursorSpend
        case resetCredit(id: String, kind: ResetCreditRowKind)
        /// Claude usage credits about to expire; `id` is the soonest grant.
        case usageCredit(id: String)
        /// A prepaid balance (TypeSafe) below the user's threshold.
        case lowBalance
        case apiBudget
    }

    /// Identity deliberately EXCLUDES the tier: a warning escalating to
    /// critical must update its row in place, not add a second one beside it.
    struct ID: Hashable, Sendable {
        let owner: Owner
        let subject: Subject
    }

    let owner: Owner
    let accountLabel: String
    let source: DisplaySource
    let subject: Subject
    let tier: AlertTier

    /// Percentage used, for a rate window. `nil` for Cursor spend, which has
    /// no denominator to take a percentage of.
    let usedPercent: Int?
    /// Amount spent this billing cycle, for Cursor. `nil` for rate windows.
    let spentCents: Int?
    /// The threshold this row crossed, as the user configured it — never
    /// `tier.rawValue`, which is an opaque persistence token.
    let thresholdPercent: Int?
    let thresholdCents: Int?
    let resetsAt: Date?
    /// Resets available, for a reset row. `nil` otherwise.
    let resetCount: Int?
    /// Every credit id folded into this row — a reset row groups ALL of an
    /// account's ACTIVE credits for one kind (available/expiring) into a
    /// single row (ChatGPT is one credit per entry, so a multi-credit grant
    /// would otherwise show N rows). `subject`'s `id` is just the
    /// soonest-expiring member; dismissing the row must act on every id
    /// here. `[]` for a non-reset row.
    let resetCreditIDs: [String]
    /// API budget rows only.
    var budgetCents: Int? = nil
    /// API Priority Tier `.present`: figures are floored lower bounds.
    var isLowerBound: Bool = false
    /// Usage-credit rows: the money that expires (the grants' sum). Low-
    /// balance rows: the balance.
    var creditAmount: Money? = nil

    var id: ID { ID(owner: owner, subject: subject) }
    var isResetCredit: Bool { if case .resetCredit = subject { true } else { false } }
    var isUsageCredit: Bool { if case .usageCredit = subject { true } else { false } }
    var isLowBalance: Bool { subject == .lowBalance }
    /// Counted as a warning or a critical in the header: everything but the
    /// informational rows (resets, usage credits), which carry no limit tier.
    var isLimitRow: Bool { !isResetCredit && !isUsageCredit }
    /// The ✕ acknowledges these one by one instead of leaving them to the
    /// global snooze (see `AppModel.snoozeAttentionDrop`): the informational
    /// rows, and a low balance, which no window reset changes — only a top-up.
    var isAcknowledgedPerRow: Bool { isResetCredit || isUsageCredit || isLowBalance }
    /// The subscription account, for account-only callers; nil for API rows.
    var accountID: UUID? { if case .account(let id) = owner { id } else { nil } }
    var provider: Provider? { if case .subscription(let provider) = source { provider } else { nil } }
}

extension AttentionRow {
    /// The pre-API-spend subscription initializer, kept so existing call sites
    /// and tests compile unchanged.
    init(accountID: UUID, accountLabel: String, provider: Provider, subject: Subject, tier: AlertTier,
         usedPercent: Int?, spentCents: Int?, thresholdPercent: Int?, thresholdCents: Int?,
         resetsAt: Date?, resetCount: Int?, resetCreditIDs: [String]) {
        self.init(owner: .account(accountID), accountLabel: accountLabel, source: .subscription(provider),
                  subject: subject, tier: tier, usedPercent: usedPercent, spentCents: spentCents,
                  thresholdPercent: thresholdPercent, thresholdCents: thresholdCents, resetsAt: resetsAt,
                  resetCount: resetCount, resetCreditIDs: resetCreditIDs, budgetCents: nil, isLowerBound: false)
    }
}

/// Which side of a reset row's lifecycle a `.resetCredit` subject shows: newly
/// granted resets, or resets about to expire unused.
enum ResetCreditRowKind: String, Hashable, Sendable { case available, expiring }

/// Derives the attention drop's contents from live state.
///
/// Pure and recomputed from scratch on every tick — there is no queue of
/// pending rows and nothing to invalidate. That is what makes the panel
/// self-retracting: a window that resets overnight simply stops satisfying the
/// conditions, so its row is gone without anything having to remember to
/// withdraw it. Quiet-hours deferral needs no held state for the same reason,
/// and a settings change applies on the next tick with no invalidation code.
enum AttentionDropModel {
    /// A row exists iff ALL of these hold right now:
    ///
    /// 1. usage alerts are enabled (the master switch governs the drop too);
    /// 2. the account is visible (not paused);
    /// 3. its snapshot is current evidence (`UsageEvidence`);
    /// 4. the cell's channels include `.drop`;
    /// 5. usage (or spend) is at or above a configured tier;
    /// 6. that tier has not been dismissed;
    /// 7. `now` is not inside a quiet cell or holiday;
    /// 8. reset rows: row state active, credit unexpired, the provider's
    ///    Resets drop channel on.
    ///
    /// `AccountViewState` is deliberately NOT a condition. Snapshot age, not
    /// view state, is the authority on whether a number still speaks for the
    /// present: a transient fetch failure must not blank a row still backed by
    /// fresh data, and a genuinely stale one is already retracted by (3). The
    /// consequence, stated so it is a choice and not an accident: an account in
    /// `.reauthenticationRequired` keeps its row until its snapshot ages out,
    /// and the existing reauth notification is what tells the user to act.
    static func rows(
        presentations: [AccountPresentation],
        settings: AppSettingsData,
        alertStates: [UUID: AccountAlertState],
        schedule: WarmUpQuietSchedule,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [AttentionRow] {
        // (1) and (7) are whole-panel gates — cheap, and they short-circuit
        // every per-account computation below.
        guard settings.usageAlertsEnabled else { return [] }
        guard !schedule.isQuiet(at: now, calendar: calendar) else { return [] }

        var rows: [AttentionRow] = []
        var resetRows: [AttentionRow] = []
        for presentation in AccountVisibility.visible(presentations) {  // (2)
            guard let snapshot = presentation.snapshot else { continue }
            let account = presentation.account
            let memory = alertStates[account.id] ?? AccountAlertState()

            for (kind, window) in snapshot.allWindows {
                let key = AppSettingsData.thresholdKey(
                    provider: account.provider,
                    window: kind
                )
                guard settings.channels(forKey: key).drop else { continue }  // (4)
                // (3) — per window, since each carries its own reset boundary.
                guard UsageEvidence.isCurrent(
                    snapshot: snapshot,
                    windowResetsAt: window.resetsAt,
                    now: now
                ) else { continue }

                let thresholds = settings.thresholds(
                    provider: account.provider,
                    window: kind
                )
                guard let tier = AlertTier.forUsed(  // (5)
                    window.usedFraction,
                    thresholds: thresholds
                ) else { continue }
                guard !isDismissed(tier, by: memory.memory(for: kind).dismissedTier)
                else { continue }  // (6)

                rows.append(
                    AttentionRow(
                        accountID: account.id,
                        accountLabel: account.label,
                        provider: account.provider,
                        subject: .window(kind),
                        tier: tier,
                        usedPercent: Int((window.usedFraction * 100).rounded()),
                        spentCents: nil,
                        thresholdPercent: tier == .critical
                            ? thresholds.criticalPercent
                            : thresholds.warningPercent,
                        thresholdCents: nil,
                        resetsAt: window.resetsAt,
                        resetCount: nil,
                        resetCreditIDs: []
                    )
                )
            }

            if
                let spend = snapshot.cursorSpend,
                settings.channels(forKey: AppSettingsData.cursorSpendKey).drop,  // (4)
                // (3) — age alone. Cursor has no reset boundary to be
                // overtaken by: the open invoice's `periodEndMs` is the fetch
                // time, and with the provider's clock slightly ahead it lands
                // AFTER `fetchedAt`, which would drop a fresh row the moment
                // local time passed it.
                UsageEvidence.isCurrent(
                    snapshot: snapshot,
                    windowResetsAt: nil,
                    now: now
                ),
                // (5) — Cursor exposes no cap, so an unset threshold means off.
                // There is deliberately no default that would fire on any spend.
                let crossing = settings.cursorSpend.tier(forSpentCents: spend.spentCents),
                !isDismissed(crossing.tier, by: memory.spend.dismissedTier)  // (6)
            {
                rows.append(
                    AttentionRow(
                        accountID: account.id,
                        accountLabel: account.label,
                        provider: account.provider,
                        subject: .cursorSpend,
                        tier: crossing.tier,
                        usedPercent: nil,
                        spentCents: spend.spentCents,
                        thresholdPercent: nil,
                        thresholdCents: crossing.thresholdCents,
                        resetsAt: spend.futureReset(relativeTo: now),
                        resetCount: nil,
                        resetCreditIDs: []
                    )
                )
            }

            // Reset rows. Shown from the alert that activated them until the
            // user clicks them away or the reset is gone (used or expired).
            // Deliberately NOT gated on `UsageEvidence`: a carried list is
            // still the best knowledge of what the account holds, and rows are
            // only ever ACTIVATED from fresh evidence (see ResetCreditPolicy).
            //
            // GROUPED per account AND kind into at most one row each: ChatGPT
            // is one credit per entry, so a multi-credit grant would
            // otherwise show N rows. Only ACTIVE members are counted/listed —
            // a per-row dismissal on one credit shrinks the group rather than
            // leaving a stale member behind. `.expiring` before `.available`
            // matches the loop order below and the ordering this function's
            // doc promises.
            if settings.shows(.resets, for: account.provider),
               settings.channels(forKey: AppSettingsData.resetCreditsKey(provider: account.provider)).drop {
                let unexpired = snapshot.resetCredits?.unexpired(at: now) ?? []
                for kind in [ResetCreditRowKind.expiring, .available] {
                    let active = unexpired.filter { credit in
                        guard let entry = memory.resetCredits[credit.id] else { return false }
                        return (kind == .expiring ? entry.expiringRow : entry.availableRow) == .active
                    }
                    guard let soonest = active.min(by: { $0.expiresAt < $1.expiresAt }) else { continue }
                    resetRows.append(AttentionRow(
                        accountID: account.id,
                        accountLabel: account.label,
                        provider: account.provider,
                        subject: .resetCredit(id: soonest.id, kind: kind),
                        tier: .warning,   // not a limit tier; header/tint ignore it for reset rows
                        usedPercent: nil,
                        spentCents: nil,
                        thresholdPercent: nil,
                        thresholdCents: nil,
                        resetsAt: soonest.expiresAt,
                        resetCount: active.reduce(0) { $0 + $1.count },
                        resetCreditIDs: active.map(\.id)
                    ))
                }
            }

            // Usage-credit rows, one per account: every grant whose expiry
            // warning is active and still unexpired, summed. Like reset
            // rows, not gated on `UsageEvidence` (a carried reading is still
            // the best knowledge) and only ever ACTIVATED from fresh evidence
            // (see `UsageCreditPolicy`). `resetCreditIDs` carries the grant
            // ids so a dismissal acknowledges them all.
            // Only a reading verified for this organization this session: a
            // restored or carried one must not revive another org's row.
            if settings.shows(.credits, for: account.provider),
               settings.channels(forKey: AppSettingsData.usageCreditsKey(provider: account.provider)).drop,
               snapshot.usageCreditsVerified,
               let credits = snapshot.usageCredits {
                let active = credits.grants(unexpiredAt: now).filter { grant in
                    grant.expiresAt != nil && memory.usageCredits[grant.id]?.row == .active
                }
                if let soonest = active.min(by: { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }) {
                    let amount = Money.sum(active.map(\.remaining)) ?? soonest.remaining
                    var row = AttentionRow(
                        accountID: account.id,
                        accountLabel: account.label,
                        provider: account.provider,
                        subject: .usageCredit(id: soonest.id),
                        tier: .warning,   // not a limit tier; header/tint ignore it
                        usedPercent: nil,
                        spentCents: nil,
                        thresholdPercent: nil,
                        thresholdCents: nil,
                        resetsAt: soonest.expiresAt,
                        resetCount: nil,
                        resetCreditIDs: active.map(\.id)
                    )
                    row.creditAmount = amount
                    resetRows.append(row)
                }
            }

            // Low balance: from the alert that activated it until the user
            // clicks it away or a reading shows the balance back at or above
            // the threshold (which re-arms the alert).
            if account.provider.hasLowBalanceAlert,
               settings.shows(.credits, for: account.provider),
               settings.channels(forKey: AppSettingsData.lowBalanceKey(provider: account.provider)).drop,
               let thresholdCents = settings.lowBalanceCents(provider: account.provider),
               memory.lowBalance.row == .active,
               // The alert's own evidence rule: verified this session AND
               // current, so a long fetch failure never keeps an old balance up.
               let balance = LowBalancePolicy.currentBalance(snapshot: snapshot, now: now),
               LowBalancePolicy.isBelow(balance, thresholdCents: thresholdCents) {
                var row = AttentionRow(
                    accountID: account.id,
                    accountLabel: account.label,
                    provider: account.provider,
                    subject: .lowBalance,
                    tier: .warning,
                    usedPercent: nil,
                    spentCents: nil,
                    thresholdPercent: nil,
                    thresholdCents: thresholdCents,
                    resetsAt: nil,
                    resetCount: nil,
                    resetCreditIDs: []
                )
                row.creditAmount = balance
                rows.append(row)
            }
        }

        // Worst first, so the panel leads with the thing most worth acting on,
        // with ties keeping `presentations` order — the user's own account
        // ordering, and within an account the `UsageWindowKind` declaration
        // order that `allWindows` walks.
        //
        // Sorted on (tier, discovery index) rather than tier alone because
        // Swift's `sorted` is introsort and is NOT stable: on tier alone,
        // equal-tier rows could legitimately swap places between two ticks
        // that produced identical data, and the panel would visibly jitter
        // once a minute for no reason.
        //
        // This is correctness by construction, and deliberately not something
        // the tests can prove: `sorted` is deterministic, so for any fixed
        // input it returns a fixed order and a stability bug is invisible from
        // outside. Do not "simplify" this back to a tier-only comparison
        // because the suite stays green — it will.
        //
        // Reset rows are appended after the sorted threshold rows rather than
        // folded into that sort: they carry no limit tier to rank by, and
        // belong at the end regardless of severity. They keep account
        // (presentation) order, expiring before available within an account.
        let sortedThresholdRows = rows
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.tier == rhs.element.tier
                    ? lhs.offset < rhs.offset
                    : lhs.element.tier > rhs.element.tier
            }
            .map(\.element)
        return sortedThresholdRows + resetRows
    }

    /// A dismissal covers its own tier AND everything below it: dismissing a
    /// critical must not leave the warning beneath it showing, while a later
    /// escalation above a dismissed warning still surfaces.
    private static func isDismissed(_ tier: AlertTier, by dismissed: AlertTier?) -> Bool {
        guard let dismissed else { return false }
        return tier <= dismissed
    }
}

private extension AccountAlertState {
    func memory(for kind: UsageWindowKind) -> WindowAlertMemory {
        switch kind {
        case .fiveHour: fiveHour
        case .weekly: weekly
        case .modelWeekly: modelWeekly
        }
    }
}
