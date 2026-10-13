import Foundation

/// How one account's row draws in the Standard popover: a compact row with
/// every gauge, or folded to one line around its tightest gauge.
///
/// Pure, so every rule is tested without a view (`AccountRowModeTests`).
enum AccountRowMode: Equatable {
    /// One line: name, plan, the tightest gauge and a chevron that expands it.
    case folded
    /// Every gauge. `sparklines`: the trend line under each gauge.
    /// `collapsible`: a chevron folds the row back.
    case expanded(sparklines: Bool, collapsible: Bool)

    var isFolded: Bool { self == .folded }

    var showsSparklines: Bool {
        if case .expanded(let sparklines, _) = self { return sparklines }
        return false
    }

    /// Folded rows expand from their chevron; only rows the user expanded
    /// fold back from it.
    var showsChevron: Bool { toggledExpansion != nil }

    /// What a click on the chevron (or on the row's first line; folded, its
    /// only line) asks to store for this account: expanded (true) or not
    /// (false); nil when the row has no chevron and a click changes nothing.
    var toggledExpansion: Bool? {
        switch self {
        case .folded: true
        case .expanded(_, true): false
        case .expanded(_, false): nil
        }
    }

    /// The rules, in order:
    /// - nothing to fold to (Cursor spend, TypeSafe balance): the whole row;
    /// - In-use detection off: nothing is in use, so nothing folds and every
    ///   row shows in full;
    /// - in use: always in full, with no chevron;
    /// - "Fold accounts not in use" off: the compact row, sparklines only
    ///   while in use (the line above);
    /// - otherwise folded, unless the user expanded it.
    ///
    /// The last-used tail is not in use: it folds like an idle row.
    static func make(
        phase: InUsePhase,
        hasGauges: Bool,
        inUseDetection: Bool,
        foldsAccountsNotInUse: Bool,
        userExpanded: Bool
    ) -> AccountRowMode {
        guard hasGauges, inUseDetection else { return .expanded(sparklines: true, collapsible: false) }
        if case .inUse = phase { return .expanded(sparklines: true, collapsible: false) }
        guard foldsAccountsNotInUse else { return .expanded(sparklines: false, collapsible: false) }
        return userExpanded ? .expanded(sparklines: true, collapsible: true) : .folded
    }

    /// Rows with rate-limit gauges (Claude, ChatGPT) — the only ones that fold.
    static func hasGauges(_ provider: Provider) -> Bool {
        !AccountLimitLayout.kinds(for: provider, snapshot: nil).isEmpty
    }

    /// The gauge a folded row keeps: the highest percent as DRAWN (whole
    /// percent), ties to the soonest reset (a scheduled reset before none),
    /// then column order. Limits without a reading are skipped; with none at
    /// all the first column stays (drawn as "—"). Nil only for no columns.
    static func tightestKind(kinds: [UsageWindowKind], snapshot: UsageSnapshot?) -> UsageWindowKind? {
        let read: [(index: Int, kind: UsageWindowKind, percent: Int, resetsAt: Date?)] = kinds.enumerated()
            .compactMap { index, kind in
                guard let window = snapshot?.window(for: kind) else { return nil }
                return (index, kind, drawnPercent(window.usedFraction), window.resetsAt)
            }
        guard let best = read.min(by: { lhs, rhs in
            if lhs.percent != rhs.percent { return lhs.percent > rhs.percent }
            switch (lhs.resetsAt, rhs.resetsAt) {
            case let (left?, right?) where left != right: return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.index < rhs.index
            }
        }) else { return kinds.first }
        return best.kind
    }

    /// The whole percent a gauge draws (`UsageFormatters.usedPercentage`
    /// rounds to no decimals the same way).
    static func drawnPercent(_ usedFraction: Double) -> Int {
        Int((usedFraction * 100).rounded(.toNearestOrEven))
    }
}

/// What a popover row says to VoiceOver and on its chevron. Pure, so each
/// language is tested (`PopoverCopyLocalizationTests`).
enum AccountRowCopy {
    /// The chevron's name and tooltip: "Expand Work" / "Collapse Work"; nil
    /// when the row has no chevron.
    static func chevronLabel(_ mode: AccountRowMode, label: String, locale: Locale = .current) -> String? {
        switch mode.toggledExpansion {
        case true?: LocalizedStringResource.accountRowExpand(label).string(in: locale)
        case false?: LocalizedStringResource.accountRowCollapse(label).string(in: locale)
        case nil: nil
        }
    }

    /// The row as one element: name and plan, in use (or last used), then
    /// every gauge — or, folded, that it shows its tightest limit and that
    /// limit. Each gauge reads exactly as `LimitRowView` reads it.
    static func spokenRow(
        _ presentation: AccountPresentation, phase: InUsePhase, mode: AccountRowMode, now: Date,
        locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String {
        var parts: [String] = [AccountCardView.nameAccessibilityLabel(for: presentation.account)]
        switch phase {
        case let .inUse(age):
            parts.append(InUseMarkerContent.inUseSpoken(relative(age, now: now, locale: locale), locale: locale))
        case let .lastUsed(age):
            parts.append(InUseMarkerContent.lastUsedSpoken(relative(age, now: now, locale: locale), locale: locale))
        case .none:
            break
        }
        let snapshot = presentation.snapshot
        let kinds = AccountLimitLayout.kinds(for: presentation.account.provider, snapshot: snapshot)
        func gauge(_ kind: UsageWindowKind) -> String {
            LimitRowView.accessibilityDescription(
                title: AccountLimitLayout.title(for: kind, snapshot: snapshot), kind: kind,
                window: snapshot?.window(for: kind), now: now, locale: locale, timeZone: timeZone
            )
        }
        if mode.isFolded, let tightest = AccountRowMode.tightestKind(kinds: kinds, snapshot: snapshot) {
            parts.append(LocalizedStringResource.accountRowSpokenFolded(gauge(tightest)).string(in: locale))
        } else {
            parts += kinds.map(gauge)
        }
        return parts.joined(separator: ", ")
    }

    private static func relative(_ age: TimeInterval, now: Date, locale: Locale) -> String {
        UsageFormatters.relativeReset(now.addingTimeInterval(-age), relativeTo: now, locale: locale)
    }
}
