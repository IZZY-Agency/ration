import SwiftUI

/// The attention drop's contents: a severity header, then one LINE per
/// crossing.
///
/// Direction C of three explored: the count is promoted into the header so the
/// panel answers "how bad is it" before any row is read, and each crossing is a
/// single line — account, subject, meter, percentage, reset — so six rows stay
/// as compact as two. The alternatives (an account-grouped card like the
/// popover's, and a large-number alert strip) both grew too tall to sit under
/// the menu bar once more than a couple of windows crossed.
/// What the panel is showing, as an observable model.
///
/// The panel is data-driven rather than rebuilt: the controller mutates this
/// and SwiftUI diffs the tree. Replacing `NSHostingView.rootView` on every
/// update instead made SwiftUI deliver a spurious `ButtonBehavior.ended` —
/// the panel pressed its own ✕ and dismissed every row before the user saw
/// it. Rows legitimately change several times during startup as snapshots
/// land, so "only rebuild when content changes" was not enough; the tree must
/// not be replaced at all.
@MainActor
final class AttentionDropModelObject: ObservableObject {
    @Published var rows: [AttentionRow] = []
    @Published var now: Date = .distantPast
    /// Whether the panel is anchored under a real status item. The ▲ ticker is
    /// drawn ONLY then — with the menu bar overflowing, or no usable button
    /// frame, the panel sits at the screen's trailing edge and a ticker would
    /// point at nothing.
    @Published var showsTicker = false
    /// Room the panel has for rows on the screen it will appear on.
    @Published var availableRowsHeight: CGFloat = .greatestFiniteMagnitude
    /// `AppModel.switchAdvice`: a limit row of an advice's `from` account
    /// names the account to switch to.
    @Published var switchAdvice: [SwitchAdvice] = []
    /// The rows are the Settings › Diagnostics sample (`AttentionDropSample`),
    /// not real crossings. The header then says so in place of its title.
    @Published var isTestDrop = false

    /// Set once by the controller; not published — changing a callback must
    /// not invalidate the view.
    var onDismissAll: () -> Void = {}
    var onSelect: (AttentionRow) -> Void = { _ in }
}

/// Whether the drop is on screen — published only when that CHANGES, so a
/// surface that merely offers the keyboard dismiss (the popover) is not
/// invalidated by every refresh of the drop's rows.
@MainActor
final class AttentionDropPresence: ObservableObject {
    @Published private(set) var isShowing = false

    func set(_ showing: Bool) {
        if isShowing != showing { isShowing = showing }
    }
}

struct AttentionDropView: View {
    @ObservedObject var model: AttentionDropModelObject

    private var rows: [AttentionRow] { model.rows }
    private var now: Date { model.now }
    private var showsTicker: Bool { model.showsTicker }
    private var availableRowsHeight: CGFloat { model.availableRowsHeight }
    private func onDismissAll() { model.onDismissAll() }
    private func onSelect(_ row: AttentionRow) { model.onSelect(row) }

    /// Threshold-crossing rows — everything except reset rows, which carry no
    /// limit tier and are counted separately.
    private var limitRows: [AttentionRow] { rows.filter { !$0.isResetCredit } }
    private var criticalCount: Int { limitRows.filter { $0.tier == .critical }.count }
    private var warningCount: Int { limitRows.filter { $0.tier == .warning }.count }
    private var resetRowCount: Int { rows.count - limitRows.count }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if showsTicker {
                Ticker()
                    .fill(Theme.panel)
                    .frame(width: 14, height: 7)
                    .overlay(Ticker().stroke(Theme.line2, lineWidth: 1))
                    .padding(.trailing, Self.tickerInset)
            }
            panelBody
        }
    }

    /// Distance from the panel's trailing edge to the ticker's centre.
    static let tickerInset: CGFloat = 15

    private var panelBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.line)
            rowsArea
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(Theme.line2, lineWidth: 1)
        )
    }

    /// Every crossing at a fixed height per row, so the panel is as tall as it
    /// needs to be — until that would exceed the screen, at which point the
    /// area caps and scrolls so the overflow stays reachable.
    @ViewBuilder
    private var rowsArea: some View {
        let height = AttentionDropGeometry.rowsAreaHeight(
            rowCount: rows.count,
            availableHeight: availableRowsHeight
        )
        if AttentionDropGeometry.rowsScroll(
            rowCount: rows.count,
            availableHeight: availableRowsHeight
        ) {
            ScrollView(.vertical) { rowsStack }
                .frame(height: height)
                .scrollIndicators(.automatic)
        } else {
            rowsStack.frame(height: height)
        }
    }

    private var rowsStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                AttentionDropRowView(
                    row: row,
                    now: now,
                    advice: Self.switchAdvice(for: row, in: model.switchAdvice),
                    onSelect: { onSelect(row) }
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            // At the +2 pt sizes the title plus all three counts outgrow the
            // 320 pt panel and the title wrapped to "NEARING / LIMITS",
            // growing the header by a line. The counts alone already say what
            // the panel is, so the title yields when it does not fit.
            //
            // A test drop is the exception: its title is the one thing that
            // must never yield, so its fallback drops the counts instead.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    headerTitleText
                    counts
                }
                if model.isTestDrop {
                    headerTitleText
                } else {
                    counts
                }
            }
            // One spoken element whichever branch is drawn: the fallback
            // drops the title from the tree, but VoiceOver must still hear it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(headerSpokenLabel)

            Spacer(minLength: 8)

            Button { onDismissAll() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.creamFaint)
                    // A 9pt glyph is not a hit target; pad it out to something
                    // clickable without changing the drawn size.
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss until these limits reset")
            .accessibilityLabel("Dismiss all")
        }
        .padding(.leading, 13)
        .padding(.trailing, 5)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var headerTitleText: some View {
        let title = model.isTestDrop
            ? Self.testDropTitle()
            : Self.headerTitle(hasLimitRows: !limitRows.isEmpty)
        return Text(title)
            .font(Theme.mono(11))
            .tracking(1.2)
            .foregroundStyle(model.isTestDrop ? Theme.warn : Theme.creamFaint)
            .lineLimit(1)
            .fixedSize()
    }

    private var headerSpokenLabel: String {
        let label = Self.headerAccessibilityLabel(
            critical: criticalCount, warning: warningCount,
            resets: resetRowCount, hasLimitRows: !limitRows.isEmpty
        )
        guard model.isTestDrop else { return label }
        return Self.testDropSpokenPrefix() + ", " + label
    }

    /// The header title of a test drop: "TEST DROP · SAMPLE".
    static func testDropTitle(locale: Locale = .current) -> String {
        LocalizedStringResource.dropTestHeader.string(in: locale)
    }

    /// What VoiceOver hears before a test drop's counts.
    static func testDropSpokenPrefix(locale: Locale = .current) -> String {
        LocalizedStringResource.dropTestSpoken.string(in: locale)
    }

    /// The drawn header title — uppercase in the catalog.
    static func headerTitle(hasLimitRows: Bool, locale: Locale = .current) -> String {
        let resource: LocalizedStringResource = hasLimitRows ? .dropHeaderNearingLimits : .dropHeaderResets
        return resource.string(in: locale)
    }

    /// The drawn header counts: "2 CRIT", "1 WARN", "1 RESET".
    static func criticalCountText(_ count: Int, locale: Locale = .current) -> String {
        LocalizedStringResource.dropCountCritical(count).string(in: locale)
    }

    static func warningCountText(_ count: Int, locale: Locale = .current) -> String {
        LocalizedStringResource.dropCountWarning(count).string(in: locale)
    }

    static func resetCountText(_ count: Int, locale: Locale = .current) -> String {
        LocalizedStringResource.dropCountReset(count).string(in: locale)
    }

    /// What VoiceOver reads for the header's title and counts — always the
    /// title, even when the drawn header had room only for the counts.
    static func headerAccessibilityLabel(
        critical: Int, warning: Int, resets: Int, hasLimitRows: Bool, locale: Locale = .current
    ) -> String {
        let title: LocalizedStringResource = hasLimitRows ? .dropSpokenNearingLimits : .dropSpokenResets
        var parts: [String] = [title.string(in: locale)]
        if critical > 0 { parts.append(LocalizedStringResource.dropSpokenCriticalCount(critical).string(in: locale)) }
        if warning > 0 { parts.append(LocalizedStringResource.dropSpokenWarningCount(warning).string(in: locale)) }
        if resets > 0 && hasLimitRows { parts.append(LocalizedStringResource.dropSpokenResetCount(resets).string(in: locale)) }
        return parts.joined(separator: ", ")
    }

    /// The same label, counted from the rows — what the controller posts as
    /// the drop's VoiceOver announcement, so the announcement and the header
    /// can never say different things.
    static func headerAccessibilityLabel(rows: [AttentionRow], locale: Locale = .current) -> String {
        let limitRows = rows.filter { !$0.isResetCredit }
        return headerAccessibilityLabel(
            critical: limitRows.filter { $0.tier == .critical }.count,
            warning: limitRows.filter { $0.tier == .warning }.count,
            resets: rows.count - limitRows.count,
            hasLimitRows: !limitRows.isEmpty,
            locale: locale
        )
    }

    /// The advice a row shows: only a LIMIT row (a rate window) of the
    /// advice's `from` account. Cursor spend and reset rows never carry one.
    static func switchAdvice(for row: AttentionRow, in advice: [SwitchAdvice]) -> SwitchAdvice? {
        guard case .window = row.subject else { return nil }
        return advice.first { $0.fromAccountID == row.accountID }
    }

    /// What VoiceOver reads for one row: words, never the drawn "5H" / "WK" /
    /// "4h 12m" (read letter by letter). An advised row ends with
    /// ", switch to <target>".
    static func rowAccessibilityLabel(
        _ row: AttentionRow,
        now: Date,
        advice: SwitchAdvice? = nil,
        locale: Locale = .current
    ) -> String {
        func spoken(_ date: Date) -> String {
            UsageFormatters.spokenDuration(until: date, relativeTo: now, locale: locale)
        }
        if case .resetCredit(_, let kind) = row.subject {
            let count = row.resetCount ?? 1
            let head: LocalizedStringResource = kind == .expiring
                ? .dropSpokenResetRowExpiring(row.accountLabel, count: count)
                : .dropSpokenResetRowAvailable(row.accountLabel, count: count)
            let expires: String = row.resetsAt.map {
                let resource: LocalizedStringResource = UsageFormatters.isResetDue($0, relativeTo: now)
                    ? .dropSpokenExpiresNow
                    : .dropSpokenExpiresIn(spoken($0))
                return resource.string(in: locale)
            } ?? ""
            return head.string(in: locale) + expires
        }
        let subject: String = switch row.subject {
            case .window(let kind): kind.spokenName(locale: locale)
            case .cursorSpend: LocalizedStringResource.dropSpokenSpend.string(in: locale)
            case .resetCredit: ""
        }
        let tier: LocalizedStringResource = row.tier == .critical ? .dropSpokenTierCritical : .dropSpokenTierWarning
        var value: String = ""
        if let percent = row.usedPercent {
            value = LocalizedStringResource.dropSpokenPercentUsed(percent).string(in: locale)
        } else if let cents = row.spentCents {
            value = LocalizedStringResource.dropSpokenSpent(AlertMessage.dollars(cents, locale: locale)).string(in: locale)
        }
        let reset: String = row.resetsAt.map {
            let resource: LocalizedStringResource = UsageFormatters.isResetDue($0, relativeTo: now)
                ? .dropSpokenResetsNow
                : .dropSpokenResetsIn(spoken($0))
            return resource.string(in: locale)
        } ?? ""
        let switchTo: String = advice.map { SwitchAdviceCopy.dropSpokenSuffix($0, locale: locale) } ?? ""
        return "\(row.accountLabel), \(subject), \(value), \(tier.string(in: locale))\(reset)\(switchTo)"
    }

    /// A non-window row's drawn subject word — uppercase in the catalog. A
    /// window is drawn as its `WindowTag`, whose text is never translated.
    static func subjectLabel(_ subject: AttentionRow.Subject, locale: Locale = .current) -> String {
        switch subject {
        case .window(let kind): WindowTag.text(kind: kind, label: nil)
        case .cursorSpend: LocalizedStringResource.dropSubjectSpend.string(in: locale)
        case .resetCredit(_, .available): LocalizedStringResource.dropSubjectReset.string(in: locale)
        case .resetCredit(_, .expiring): LocalizedStringResource.dropSubjectExpires.string(in: locale)
        }
    }

    @ViewBuilder
    private var counts: some View {
        HStack(spacing: 7) {
            if criticalCount > 0 {
                Text(Self.criticalCountText(criticalCount))
                    .font(Theme.mono(11))
                    .tracking(1.2)
                    .foregroundStyle(Theme.crit)
            }
            if criticalCount > 0 && warningCount > 0 {
                Text(verbatim: "·").font(Theme.mono(11)).foregroundStyle(Theme.creamFaint)
            }
            if warningCount > 0 {
                Text(Self.warningCountText(warningCount))
                    .font(Theme.mono(11))
                    .tracking(1.2)
                    .foregroundStyle(Theme.warn)
            }
            if resetRowCount > 0 && !limitRows.isEmpty {
                Text(verbatim: "·").font(Theme.mono(11)).foregroundStyle(Theme.creamFaint)
                Text(Self.resetCountText(resetRowCount))
                    .font(Theme.mono(11))
                    .tracking(1.2)
                    .foregroundStyle(Theme.resetAccent)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The ▲ pointing back at the status item.
private struct Ticker: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// One crossing, on one line.
private struct AttentionDropRowView: View {
    let row: AttentionRow
    let now: Date
    let advice: SwitchAdvice?
    let onSelect: () -> Void

    @State private var isHovering = false

    private var tint: Color {
        if case .resetCredit(_, let kind) = row.subject {
            return kind == .expiring ? Theme.warn : Theme.resetAccent
        }
        return row.tier == .critical ? Theme.crit : Theme.warn
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)

                name
                    .layoutPriority(1)

                subjectView
                    .layoutPriority(1)

                meter

                Text(valueLabel)
                    .font(Theme.mono(14.5, bold: true))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                // The full countdown when it fits the column; otherwise its
                // leading unit ("12 h" for "12 h 30 min" in French), with the
                // full form as the tooltip. English always fits.
                ViewThatFits(in: .horizontal) {
                    Text(resetLabel)
                    Text(resetLabelLeadingUnit)
                        .help(resetLabel)
                }
                .font(Theme.mono(13))
                .monospacedDigit()
                .foregroundStyle(Theme.resetAccent)
                .lineLimit(1)
                .frame(width: AttentionDropGeometry.countdownColumnWidth, alignment: .trailing)
            }
            .padding(.horizontal, 13)
            .frame(
                maxWidth: .infinity,
                minHeight: AttentionDropGeometry.rowHeight,
                maxHeight: AttentionDropGeometry.rowHeight,
                alignment: .leading
            )
            .background(isHovering ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens Ration and dismisses this row")
    }

    /// The account's name, then "→ target" in the activity green when the
    /// row is advised. The name gives way first (the target outranks it
    /// inside this stack), then the target.
    @ViewBuilder
    private var name: some View {
        let label = Text(row.accountLabel)
            .font(Theme.display(15, .semibold))
            .foregroundStyle(Theme.cream)
            .lineLimit(1)
        if let advice {
            AdvisedNameLayout(spacing: 5) {
                label
                Text(SwitchAdviceCopy.dropSuffix(advice))
                    .font(Theme.display(15, .semibold))
                    .foregroundStyle(Theme.active)
                    .lineLimit(1)
            }
            .clipped()
        } else {
            label
        }
    }

    /// Cursor has no denominator, so its line shows the amount alone with no
    /// meter — there is nothing to fill a meter against.
    @ViewBuilder
    private var meter: some View {
        if let percent = row.usedPercent {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, geometry.size.width * Double(percent) / 100))
                }
            }
            // A long account label (layout priority 1) otherwise squeezes the
            // meter down to its 2 pt fill — a dot, not a meter.
            .frame(minWidth: AttentionDropGeometry.meterMinWidth)
            .frame(height: 3)
        } else {
            Spacer(minLength: 8)
        }
    }

    /// A limit window is named by the shared `WindowTag`; the other
    /// subjects (spend, reset credits) are words, not windows.
    @ViewBuilder
    private var subjectView: some View {
        if case let .window(kind) = row.subject {
            WindowTag(kind: kind, label: nil, size: 12)
        } else {
            Text(AttentionDropView.subjectLabel(row.subject))
                .font(Theme.mono(12))
                .tracking(0.6)
                .foregroundStyle(Theme.creamFaint)
                .lineLimit(1)
        }
    }

    private var valueLabel: String {
        if let count = row.resetCount { return "×\(count)" }
        if let percent = row.usedPercent { return UsageFormatters.compactPercent(percent) }
        if let cents = row.spentCents { return AlertMessage.dollars(cents) }
        return "—"
    }

    private var resetLabel: String {
        guard let resetsAt = row.resetsAt else { return "" }
        // Reset-credit rows use the coarser day/hour formatting — a reset
        // lives for weeks, and the fine-grained "29d 7h" both reads as noise
        // and truncates in the drop's fixed-width column. Window rows keep
        // the finer `remainingUntilReset`.
        return row.isResetCredit
            ? UsageFormatters.resetCreditRemaining(resetsAt, relativeTo: now)
            : UsageFormatters.remainingUntilReset(resetsAt, relativeTo: now)
    }

    /// `resetLabel` cut to its leading unit, for when the full form does
    /// not fit the countdown column.
    private var resetLabelLeadingUnit: String {
        guard let resetsAt = row.resetsAt else { return "" }
        return row.isResetCredit
            ? UsageFormatters.resetCreditRemaining(resetsAt, relativeTo: now)
            : UsageFormatters.remainingUntilResetLeadingUnit(resetsAt, relativeTo: now)
    }

    private var accessibilityLabel: String {
        AttentionDropView.rowAccessibilityLabel(row, now: now, advice: advice)
    }
}

/// Name, then "→ target": the target keeps its full width while the name can
/// give way, but never below a short floor — a plain priority split squeezed a
/// long name down to its first glyph behind a long target. Past the floor the
/// target truncates too.
struct AdvisedNameLayout: Layout {
    var spacing: CGFloat
    /// The least of the account's name that stays visible while the target
    /// still has room to give (a name shorter than this keeps its own width).
    static let nameFloor: CGFloat = 44

    /// Offered name width and target width. The gap exists only while the
    /// target gets width; with none, the name has the whole span.
    /// `available == nil` → ideal sizes.
    static func split(
        available: CGFloat?,
        spacing: CGFloat,
        nameIdeal: CGFloat,
        targetIdeal: CGFloat
    ) -> (name: CGFloat, target: CGFloat) {
        guard let available else { return (nameIdeal, targetIdeal) }
        let room: CGFloat = max(0, available - spacing)
        let floor: CGFloat = min(nameIdeal, nameFloor)
        let target: CGFloat = min(targetIdeal, max(0, room - floor))
        guard target > 0 else { return (min(nameIdeal, max(0, available)), 0) }
        return (min(nameIdeal, max(0, room - target)), target)
    }

    private func widths(available: CGFloat?, subviews: Subviews) -> (name: CGFloat, target: CGFloat) {
        guard subviews.count == 2 else { return (0, 0) }
        let nameIdeal: CGFloat = subviews[0].sizeThatFits(.unspecified).width
        let targetIdeal: CGFloat = subviews[1].sizeThatFits(.unspecified).width
        let offered = Self.split(
            available: available, spacing: spacing, nameIdeal: nameIdeal, targetIdeal: targetIdeal
        )
        guard let available, offered.target > 0 else { return offered }
        let drawn: CGFloat = subviews[0].sizeThatFits(ProposedViewSize(width: offered.name, height: nil)).width
        return Self.reclaim(
            available: available, spacing: spacing, offered: offered,
            drawnName: drawn, nameIdeal: nameIdeal, targetIdeal: targetIdeal
        )
    }

    /// A truncated name draws narrower than offered (it cuts at a glyph);
    /// hand that slack back to the target instead of leaving a gap — but
    /// never below the floor, or the target would eat into it.
    static func reclaim(
        available: CGFloat,
        spacing: CGFloat,
        offered: (name: CGFloat, target: CGFloat),
        drawnName: CGFloat,
        nameIdeal: CGFloat,
        targetIdeal: CGFloat
    ) -> (name: CGFloat, target: CGFloat) {
        let floor: CGFloat = min(nameIdeal, nameFloor)
        let name: CGFloat = min(offered.name, max(drawnName, floor))
        let room: CGFloat = max(0, available - spacing)
        return (name, min(targetIdeal, max(0, room - name)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let split = widths(available: proposal.width, subviews: subviews)
        var height: CGFloat = 0
        for subview in subviews {
            height = max(height, subview.sizeThatFits(.unspecified).height)
        }
        let gap: CGFloat = split.target > 0 ? spacing : 0
        return CGSize(width: split.name + gap + split.target, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let split = widths(available: bounds.width, subviews: subviews)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: split.name, height: bounds.height)
        )
        // A target with no width is parked past the trailing edge (the
        // container clips), never drawn over the name.
        let targetX: CGFloat = split.target > 0 ? bounds.minX + split.name + spacing : bounds.maxX
        subviews[1].place(
            at: CGPoint(x: targetX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: split.target, height: bounds.height)
        )
    }
}
