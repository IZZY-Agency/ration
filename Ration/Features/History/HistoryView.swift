import Charts
import SwiftUI

/// The dedicated History window: a per-window (Fable/5h/weekly) day chart plus
/// an hour-of-day heatmap, both derived from persisted rollup buckets
/// (`UsageHistoryStore.loadRollups`).
///
/// The account picker offers a single account or `All accounts`, which overlays
/// one line per account that owns the selected window — the comparison view.
/// Which accounts those are, how their lines are named and coloured, and what
/// must be said about the ones that cannot be drawn all live in the pure
/// `HistoryOverlay`.
struct HistoryView: View {
    @ObservedObject var model: AppModel
    /// The store's throttled history revision, so open Patterns charts pick
    /// up new rollups the way the Billing-cycle cards do.
    @StateObject private var clock: HistoryRefreshClock

    init(model: AppModel) {
        self.model = model
        _clock = StateObject(wrappedValue: HistoryRefreshClock(history: model.history))
    }

    @State private var scope: HistoryScope = .all
    @State private var selectedKind: UsageWindowKind = .fiveHour
    // Derived ONCE per completed load, not per render: `daySeries` walks every
    // hourly bucket an account has ever recorded, and rollup retention is
    // unlimited. Recomputing it in `body` would put that scan on the main actor
    // for every unrelated AppModel publication.
    @State private var series: [HistoryOverlaySeries] = []
    @State private var heatHours: [HourOfDayBurn] = []

    private enum Mode: Hashable { case patterns, billingCycle }
    @State private var mode: Mode = .patterns

    /// The scope actually in effect: the user's selection if its account still
    /// exists, otherwise the overlay — which, unlike a removed account, can
    /// never be empty. Computed (not stored) so it needs no bootstrap step and
    /// stays correct as accounts are added or removed.
    private var effectiveScope: HistoryScope {
        HistoryOverlay.effectiveScope(requested: scope, presentations: model.presentations)
    }

    /// The presentations the current scope covers. Reads `model.presentations`
    /// (`@Published`), which — unlike the popover's filtered list — keeps paused
    /// accounts: their recorded usage is real data and History still shows it.
    private var scopedPresentations: [AccountPresentation] {
        switch effectiveScope {
        case .all: model.presentations
        case let .account(id): model.presentations.filter { $0.id == id }
        }
    }

    /// The window kinds this scope may offer, and the one in effect. Nil when the
    /// scope owns no rolling window at all (a Cursor-only install), which the
    /// body renders as its own honest state rather than an empty chart.
    private var availableKinds: [UsageWindowKind] {
        HistoryOverlay.availableKinds(presentations: model.presentations, scope: effectiveScope)
    }

    private var effectiveKind: UsageWindowKind? {
        HistoryOverlay.effectiveKind(
            requested: selectedKind, presentations: model.presentations, scope: effectiveScope
        )
    }

    /// A snapshot that carries the modelWeekly window, so the picker and chart
    /// title use the API's own label ("Fable") rather than the static fallback.
    /// Read from `@Published` presentations — never from retained rollups, which
    /// would keep a stale Fable label alive after a Max downgrade.
    private var labelSnapshot: UsageSnapshot? {
        scopedPresentations.first { $0.snapshot?.modelWeekly != nil }?.snapshot
    }

    private var exclusionNote: String? {
        guard let effectiveKind else { return nil }
        return HistoryOverlay.exclusionNote(
            presentations: scopedPresentations, kind: effectiveKind
        )
    }

    private var spokenExclusionNote: String {
        guard let effectiveKind else { return "" }
        let note: String? = HistoryOverlay.spokenExclusionNote(
            presentations: scopedPresentations, kind: effectiveKind
        )
        return note ?? ""
    }

    /// Identity for the loader: the scope, the window, and every account that
    /// owns that window — so adding, removing, pausing, or an account newly
    /// gaining the window all reload the overlay — plus the store's history
    /// revision, so new rollups reload it too (at most once a minute).
    /// Nil while Billing cycle is shown: the hidden Patterns charts do not
    /// reload (their scan and heatmap run on the main actor); switching back
    /// changes the key and loads them fresh.
    private var loadKey: String? {
        let identity: String = HistoryOverlay.loadIdentity(
            presentations: model.presentations, scope: effectiveScope, kind: effectiveKind
        )
        return Self.patternsLoadKey(
            identity: identity, historyRevision: clock.historyRevision, isPatternsActive: mode == .patterns
        )
    }

    static func patternsLoadKey(identity: String, historyRevision: Int, isPatternsActive: Bool = true) -> String? {
        guard isPatternsActive else { return nil }
        return "\(historyRevision)|" + identity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().overlay(Theme.line)

            Group {
                switch mode {
                case .patterns:
                    if model.accounts.isEmpty {
                        emptyAccountsState
                    } else if effectiveKind == nil && cursorPresentations.isEmpty {
                        noRollingWindowState
                    } else if series.isEmpty && cursorPresentations.isEmpty {
                        emptyHistoryState
                    } else {
                        content
                    }
                case .billingCycle:
                    BillingCycleView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.ink)
        .frame(minWidth: 680, minHeight: 480)
        .task(id: loadKey) {
            guard loadKey != nil else { return }
            await loadBuckets()
        }
        .onAppear { clock.start() }
        .onDisappear { clock.stop() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("History")
                .font(Theme.display(19, .semibold))
                .foregroundStyle(Theme.cream)

            Picker("Mode", selection: $mode) {
                // Short segment titles (French and Ukrainian did not fit the
                // 200 pt control); VoiceOver keeps the full names.
                Text(LocalizedStringResource.historyModePatterns)
                    .accessibilityLabel(Text("Patterns"))
                    .tag(Mode.patterns)
                Text(LocalizedStringResource.historyModeBillingCycle)
                    .accessibilityLabel(Text("Billing cycle"))
                    .tag(Mode.billingCycle)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            Spacer()

            if mode == .patterns && !model.accounts.isEmpty {
                Picker(
                    "Account",
                    selection: Binding(get: { effectiveScope }, set: { scope = $0 })
                ) {
                    Text("All accounts").tag(HistoryScope.all)
                    Divider()
                    ForEach(model.accounts) { account in
                        Text(account.historyLabel).tag(HistoryScope.account(account.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .accessibilityIdentifier("historyAccountPicker")

                if !availableKinds.isEmpty {
                    Picker(
                        "Window",
                        selection: Binding(
                            get: { effectiveKind ?? availableKinds[0] },
                            set: { selectedKind = $0 }
                        )
                    ) {
                        ForEach(availableKinds, id: \.self) { kind in
                            Text(AccountLimitLayout.title(for: kind, snapshot: labelSnapshot))
                                .accessibilityLabel(HistoryOverlay.spokenWindowName(kind, snapshot: labelSnapshot))
                                .tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: availableKinds.count > 2 ? 150 : 110)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The scope's Cursor accounts: each gets its spend-per-cycle section
    /// below the rolling-window charts (or alone, in a Cursor-only scope).
    private var cursorPresentations: [AccountPresentation] {
        scopedPresentations.filter { $0.account.provider == .cursor }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !series.isEmpty {
                    dayChart
                    heatmap
                } else if effectiveKind != nil {
                    Text("Usage is recorded as it's fetched.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)
                }
                ForEach(cursorPresentations) { presentation in
                    CursorSpendHistorySection(
                        label: presentation.account.historyLabel,
                        history: model.cursorSpendHistories[presentation.id] ?? CursorSpendHistory(),
                        current: presentation.snapshot?.cursorSpend
                    )
                }
            }
            .padding(16)
        }
    }

    private var dayChart: some View {
        let isOverlay = series.count > 1
        // "All accounts" always names what it drew, even when only one account
        // has history — otherwise the header claims a comparison the chart is
        // not showing, with nothing to say which account survived.
        let showsLegend = isOverlay || effectiveScope == .all
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Daily Burn")
                    .font(Theme.mono(12, bold: true))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.creamFaint)

                if let exclusionNote {
                    Text(exclusionNote)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.creamDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(exclusionNote)
                        .accessibilityLabel(spokenExclusionNote)
                }
            }

            Chart {
                ForEach(series) { line in
                    ForEach(line.points, id: \.dayStart) { day in
                        LineMark(
                            x: .value("Day", day.dayStart),
                            y: .value("Consumed", day.consumed),
                            series: .value("Account", line.label)
                        )
                        .foregroundStyle(by: .value("Account", line.label))
                        .interpolationMethod(.monotone)
                        // Overlaid, two accounts of one provider share a hue
                        // family, so the stroke carries the distinction colour
                        // alone cannot. A lone line stays solid.
                        .lineStyle(
                            StrokeStyle(
                                lineWidth: 2,
                                dash: isOverlay ? HistoryOverlayPalette.dash(shadeIndex: line.shadeIndex) : []
                            )
                        )
                    }

                    ForEach(line.points, id: \.dayStart) { day in
                        PointMark(
                            x: .value("Day", day.dayStart),
                            y: .value("Consumed", day.consumed)
                        )
                        // One account keeps the tier-coloured points it has
                        // always had. Overlaid, per-point tier colour would
                        // fight the per-account colour that carries the
                        // comparison — but the points must stay: a series with a
                        // single day has no segment to draw and would otherwise
                        // be invisible.
                        .foregroundStyle(by: .value("Account", line.label))
                        .symbolSize(isOverlay ? 18 : 40)
                        .opacity(isOverlay ? HistoryOverlayPalette.overlayPointOpacity : 0)
                    }

                    if !isOverlay {
                        ForEach(line.points, id: \.dayStart) { day in
                            PointMark(
                                x: .value("Day", day.dayStart),
                                y: .value("Consumed", day.consumed)
                            )
                            .foregroundStyle(Theme.tierColor(usedFraction: min(day.consumed, 1)))
                        }
                    }
                }
            }
            .chartForegroundStyleScale(
                domain: series.map(\.label),
                range: series.map {
                    HistoryOverlayPalette.color(provider: $0.provider, shadeIndex: $0.shadeIndex)
                }
            )
            .chartLegend(showsLegend ? .visible : .hidden)
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .foregroundStyle(Theme.creamDim)
                        .font(Theme.mono(11))
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel()
                        .foregroundStyle(Theme.creamDim)
                        .font(Theme.mono(11))
                }
            }
            .frame(height: 200)
        }
    }

    private var heatmap: some View {
        HistoryHeatmapView(hours: heatHours)
    }

    private var emptyAccountsState: some View {
        ContentUnavailableView {
            Label("No accounts", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text("Add an account to see usage history.")
        }
        .background(Theme.ink)
    }

    /// A scope whose accounts own no rolling window — today, a Cursor-only
    /// install. Cursor is dollars-based, so there is no percentage to chart.
    private var noRollingWindowState: some View {
        ContentUnavailableView {
            Label("No rolling windows", systemImage: "chart.xyaxis.line")
        } description: {
            Text("Cursor tracks usage-based spend rather than 5h or weekly windows — its spend and cycle reset show on its account card.")
        }
        .background(Theme.ink)
    }

    private var emptyHistoryState: some View {
        ContentUnavailableView {
            Label("No history yet", systemImage: "chart.xyaxis.line")
        } description: {
            Text("Usage is recorded as it's fetched.")
        }
        .background(Theme.ink)
    }

    private func loadBuckets() async {
        guard let kind = effectiveKind else {
            series = []
            heatHours = UsageHistoryAggregator.hourOfDayHeatmap([])
            return
        }
        let scoped = scopedPresentations
        let targets = HistoryOverlay.included(presentations: scoped, kind: kind)
        var loaded: [UUID: [UsageHourlyBucket]] = [:]
        for target in targets {
            let buckets = await model.history.loadRollups(accountID: target.id, kind: kind)
            // `.task(id:)` cancellation is cooperative: when the selection
            // changes, this superseded task keeps running through `loadRollups`'
            // awaits and could resume AFTER its successor, clobbering the new
            // selection's data with stale results. Never publish from a
            // cancelled task.
            guard !Task.isCancelled else { return }
            loaded[target.id] = buckets
        }
        let built = HistoryOverlay.series(presentations: scoped, kind: kind, loaded: loaded)
        let hours = UsageHistoryAggregator.hourOfDayHeatmap(
            HistoryOverlay.combinedBuckets(presentations: scoped, kind: kind, loaded: loaded)
        )
        guard !Task.isCancelled else { return }
        series = built
        heatHours = hours
    }
}
