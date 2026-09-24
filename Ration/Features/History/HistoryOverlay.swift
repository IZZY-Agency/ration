import SwiftUI

/// Which accounts the History window's "Patterns" charts cover.
enum HistoryScope: Hashable {
    /// Every account that owns the selected window kind, overlaid for comparison.
    case all
    case account(UUID)
}

/// One account's line in the overlaid Daily Burn chart.
struct HistoryOverlaySeries: Identifiable, Equatable {
    let accountID: UUID
    let provider: Provider
    /// Legend label — unique across the overlay (see `HistoryOverlay.labels`).
    let label: String
    /// Position within this account's provider group, which picks the shade off
    /// that provider's ladder so two Claude accounts never draw the same gold.
    let shadeIndex: Int
    let points: [DayBurn]

    var id: UUID { accountID }
}

/// Pure derivation behind the multi-account overlay: which accounts a window
/// kind can legitimately compare, how their lines are labelled and coloured,
/// and what the chart must say out loud about the accounts it cannot draw.
///
/// Comparability is the whole point: a "5h" overlay may only contain accounts
/// that genuinely own a 5-hour window. Cursor is dollars-based and owns no
/// rolling windows at all, so it is never silently folded in — it is excluded
/// and named in `exclusionNote`.
enum HistoryOverlay {
    /// Canonical window order — Fable leads, matching the account card's columns.
    static let kindOrder: [UsageWindowKind] = [.modelWeekly, .fiveHour, .weekly]

    /// The window kinds a scope can offer: one account's own kinds, or the union
    /// across every account for `.all`. Empty when no account owns any rolling
    /// window (a Cursor-only install).
    static func availableKinds(
        presentations: [AccountPresentation],
        scope: HistoryScope
    ) -> [UsageWindowKind] {
        let considered: [AccountPresentation] = switch scope {
        case .all: presentations
        case let .account(id): presentations.filter { $0.id == id }
        }
        var owned: Set<UsageWindowKind> = []
        for presentation in considered {
            owned.formUnion(kinds(of: presentation))
        }
        return kindOrder.filter(owned.contains)
    }

    /// The accounts that actually own `kind`, in the order handed in (which is
    /// already the app's display order).
    static func included(
        presentations: [AccountPresentation],
        kind: UsageWindowKind
    ) -> [AccountPresentation] {
        presentations.filter { kinds(of: $0).contains(kind) }
    }

    /// Names what the chart cannot draw, or nil when every account is included.
    /// Silence would read as "these accounts have no usage" rather than "this
    /// window does not exist for them".
    static func exclusionNote(
        presentations: [AccountPresentation],
        kind: UsageWindowKind
    ) -> String? {
        let excluded = presentations.filter { !kinds(of: $0).contains(kind) }
        guard !excluded.isEmpty else { return nil }
        let window = AccountLimitLayout.title(for: kind, snapshot: nil)
        guard excluded.count <= 3 else {
            return "Not shown: \(excluded.count) accounts with no \(window) window"
        }
        let labels = excluded.map(\.account.historyLabel).joined(separator: ", ")
        return "Not shown: \(labels) — no \(window) window"
    }

    /// Legend labels, disambiguated so two lines never share a name: a shared
    /// label gains its provider, and a label still colliding gains an ordinal.
    ///
    /// Uniqueness is enforced against every label already handed out, not just
    /// against the raw ones — the label doubles as the Swift Charts series key,
    /// and two series sharing a key are drawn as a single line. An account
    /// literally named "Work · Claude" must therefore not collide with the
    /// qualified form generated for a different account named "Work".
    static func labels(for presentations: [AccountPresentation]) -> [UUID: String] {
        var occurrences: [String: Int] = [:]
        for presentation in presentations {
            occurrences[presentation.account.historyLabel, default: 0] += 1
        }
        var taken: Set<String> = []
        var labels: [UUID: String] = [:]
        for presentation in presentations {
            let base = presentation.account.historyLabel
            let preferred = occurrences[base, default: 0] > 1
                ? "\(base) · \(presentation.account.provider.displayName)"
                : base
            var candidate = preferred
            var ordinal = 1
            while taken.contains(candidate) {
                ordinal += 1
                candidate = "\(preferred) (\(ordinal))"
            }
            taken.insert(candidate)
            labels[presentation.id] = candidate
        }
        return labels
    }

    /// Identity for the History window's loader. Includes the accounts that own
    /// `kind` — not merely the accounts in scope — so an account *gaining* the
    /// window (a Max upgrade, or its first snapshot landing) invalidates the
    /// load instead of silently missing its line until the window is reopened.
    static func loadIdentity(
        presentations: [AccountPresentation],
        scope: HistoryScope,
        kind: UsageWindowKind?
    ) -> String {
        let scoped: [AccountPresentation] = switch scope {
        case .all: presentations
        case let .account(id): presentations.filter { $0.id == id }
        }
        guard let kind else { return "\(scope)|none" }
        // Pause state rides along because it changes an account's history label
        // ("— PAUSED"), and the derived series is cached rather than recomputed
        // on every render.
        let owners = included(presentations: scoped, kind: kind)
            .map { "\($0.id.uuidString):\($0.account.isPaused)" }
            .joined(separator: ",")
        return "\(scope)|\(kind.rawValue)|\(owners)"
    }

    /// Builds one series per included account that has recorded history. An
    /// account with the window but no rollups yet is dropped rather than drawn
    /// as an empty line with a legend entry.
    static func series(
        presentations: [AccountPresentation],
        kind: UsageWindowKind,
        loaded: [UUID: [UsageHourlyBucket]]
    ) -> [HistoryOverlaySeries] {
        let included = included(presentations: presentations, kind: kind)
        let labels = labels(for: included)
        var nextShade: [Provider: Int] = [:]
        var series: [HistoryOverlaySeries] = []
        for presentation in included {
            let provider = presentation.account.provider
            // The shade slot is claimed by every INCLUDED account, drawn or not:
            // it is that account's identity, and advancing it only for drawn
            // lines would re-colour every later line the moment an earlier
            // account started recording history.
            let shade = nextShade[provider, default: 0]
            nextShade[provider] = shade + 1
            let points = UsageHistoryAggregator.daySeries(loaded[presentation.id] ?? [])
            guard !points.isEmpty else { continue }
            series.append(
                HistoryOverlaySeries(
                    accountID: presentation.id,
                    provider: provider,
                    label: labels[presentation.id] ?? presentation.account.historyLabel,
                    shadeIndex: shade,
                    points: points
                )
            )
        }
        return series
    }

    /// Every included account's buckets in one array — the hour-of-day heatmap's
    /// input, so it describes when *you* burn rather than one account in isolation.
    static func combinedBuckets(
        presentations: [AccountPresentation],
        kind: UsageWindowKind,
        loaded: [UUID: [UsageHourlyBucket]]
    ) -> [UsageHourlyBucket] {
        included(presentations: presentations, kind: kind)
            .flatMap { loaded[$0.id] ?? [] }
    }

    /// Falls back to the overlay when the selected account is gone (removed
    /// while the window was open), which can never itself be empty.
    static func effectiveScope(
        requested: HistoryScope,
        presentations: [AccountPresentation]
    ) -> HistoryScope {
        if case let .account(id) = requested,
           !presentations.contains(where: { $0.id == id }) {
            return .all
        }
        return requested
    }

    /// The window kind actually in effect: the request when the scope offers it,
    /// otherwise that scope's first kind. Nil when the scope offers none.
    static func effectiveKind(
        requested: UsageWindowKind,
        presentations: [AccountPresentation],
        scope: HistoryScope
    ) -> UsageWindowKind? {
        let available = availableKinds(presentations: presentations, scope: scope)
        return available.contains(requested) ? requested : available.first
    }

    private static func kinds(of presentation: AccountPresentation) -> [UsageWindowKind] {
        AccountLimitLayout.kinds(
            for: presentation.account.provider,
            snapshot: presentation.snapshot
        )
    }
}

/// Per-provider colour ladders for overlaid lines. Slot 0 is the provider's
/// brand accent — the same colour its account card, Settings mark, and rail use
/// — so a single-account chart looks exactly as it did before the overlay, and
/// later slots stay inside that provider's hue so a line's provider is readable
/// before its label is.
enum HistoryOverlayPalette {
    /// One ladder per appearance: a dark palette for the dark ink ground and a
    /// light palette for the light one. `color` pairs them into a single
    /// dynamic colour, so a chart follows the appearance without a redraw.
    static func ladder(for provider: Provider, dark: Bool) -> [UInt32] {
        switch (provider, dark) {
        // Slot 0 is the provider's brand token in that appearance. Wide
        // lightness spread inside one hue family: the family says which
        // provider, the lightness says which account; every shade stays
        // >= 3 : 1 on ink and panel. Deliberately avoids the semantic tier
        // colours (warn/crit) and the cyan reset accent, so a series colour
        // never reads as a state signal. ChatGPT's greens share a hue family
        // with `active`, but History never draws `active`, so no series can
        // be mistaken for the in-use marker.
        case (.claude, true): [0xD9B44A, 0xF0D99A, 0xA88420, 0xE6C46E]
        case (.claude, false): [0x836400, 0xA68212, 0x5E4700, 0x957200]
        case (.chatGPT, true): [0x5CC79F, 0xA3E3C8, 0x2FA27A, 0x7FD6B3]
        case (.chatGPT, false): [0x0F7657, 0x2A8E6E, 0x0A5540, 0x2C7A66]
        case (.cursor, true): [0xB0A6EE, 0xD6D0F7, 0x8779D6, 0xC3BBF2]
        case (.cursor, false): [0x5A55B5, 0x7F7ACB, 0x3B3787, 0x6C67C2]
        }
    }

    /// Dash pattern per shade slot. Colour alone separates lines weakly when
    /// two accounts share a provider's hue family — and not at all for a
    /// colourblind viewer — so each slot draws its own stroke too. Slot 0 is
    /// solid, keeping a single-account chart exactly as it always looked.
    ///
    /// Deliberately a different length from the colour ladder (3 vs 4): what the
    /// eye reads is the *pair*, so co-prime-ish cycles keep it unique for 12
    /// accounts of one provider instead of 4.
    static let dashLadder: [[CGFloat]] = [[], [6, 3], [2, 3]]

    /// Opacity of an overlay chart's per-account points. The ladder's 3 : 1
    /// guarantee holds only at full strength, and a one-day series is ONLY its
    /// point, so this must stay 1 — `testEveryShadeIsVisibleOnBothGrounds`
    /// checks the colour actually drawn.
    static let overlayPointOpacity: Double = 1

    static func dash(shadeIndex: Int) -> [CGFloat] {
        dashLadder[wrap(shadeIndex, count: dashLadder.count)]
    }

    static func hex(provider: Provider, shadeIndex: Int, dark: Bool) -> UInt32 {
        let ladder = ladder(for: provider, dark: dark)
        return ladder[wrap(shadeIndex, count: ladder.count)]
    }

    /// Dynamic: resolves to the dark or light ladder by the drawing appearance.
    static func color(provider: Provider, shadeIndex: Int) -> Color {
        Color(nsColor: Theme.dynamic(
            dark: hex(provider: provider, shadeIndex: shadeIndex, dark: true),
            light: hex(provider: provider, shadeIndex: shadeIndex, dark: false)
        ))
    }

    private static func wrap(_ index: Int, count: Int) -> Int {
        ((index % count) + count) % count
    }
}
