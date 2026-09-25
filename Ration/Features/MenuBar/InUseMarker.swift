import SwiftUI

/// The single source of truth for the "in use" indicator, reused by the
/// popover card, the Settings sidebar row, and the Settings detail header.
/// Owns a periodic tick so the phase (and the pill) expire on their own —
/// essential in Settings, which has no other periodic refresh.
struct InUseMarker: View {
    enum Style {
        /// Pill when in use, muted "last used · …" otherwise, nothing when idle.
        case full
        /// Only the IN USE pill; renders nothing in the last-used / idle phases.
        case pillOnly
    }

    let activeUsage: ActiveUsage?
    var style: Style = .full
    var now: Date = .now

    var body: some View {
        TimelineView(.periodic(from: now, by: 60)) { context in
            makeContent(at: context.date)
        }
    }

    /// Builds the content view for a given tick. Exposed (rather than inlined
    /// into `body`) so tests can assert that `style` is genuinely forwarded,
    /// not just stored on this struct.
    func makeContent(at date: Date) -> InUseMarkerContent {
        InUseMarkerContent(
            phase: InUsePhase.classify(activeUsage, now: date),
            date: date,
            style: style
        )
    }
}

/// Stateless renderer: draws whatever phase it is handed and owns no clock, so a
/// parent that already ticks (the account card) can drive the outline and this
/// text from ONE computed phase.
struct InUseMarkerContent: View {
    let phase: InUsePhase
    let date: Date
    var style: InUseMarker.Style = .full

    var body: some View {
        content(for: phase, at: date)
    }

    @ViewBuilder
    private func content(for phase: InUsePhase, at date: Date) -> some View {
        switch phase {
        case let .inUse(age):
            let rel = relative(age, at: date)
            HStack(spacing: 5) {
                pill(accessibility: Self.inUseSpoken(rel))
                if style == .full {
                    // The pill already carries the full a11y label; the age is
                    // decorative next to it.
                    Text(verbatim: "· \(rel)")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.creamDim)
                        .accessibilityHidden(true)
                }
            }
        case let .lastUsed(age):
            if style == .full {
                let rel = relative(age, at: date)
                Text(Self.lastUsedText(rel))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.creamDim)
                    .accessibilityLabel(Self.lastUsedSpoken(rel))
            }
        case .none:
            EmptyView()
        }
    }

    private func pill(accessibility: String) -> some View {
        // Always `Theme.active`: the ONE activity green, shared with the
        // menu-bar dot and the card frame. Deliberately not a parameter — a
        // per-caller accent is how the surfaces drifted apart (provider gold/
        // teal here vs green in the menu bar) before 0.26.1 unified them.
        Text(Self.pillText())
            .font(Theme.mono(11, bold: true))
            .tracking(0.8)
            // Never "IN U…": if the row is short of room, the label gives way.
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Theme.active, in: RoundedRectangle(cornerRadius: 3))
            .accessibilityLabel(accessibility)
    }

    /// The pill's text: "IN USE" (uppercase in the catalog).
    static func pillText(locale: Locale = .current) -> String {
        LocalizedStringResource.inUsePill.string(in: locale)
    }

    /// VoiceOver for the pill. `relative` is already localized ("5 minutes ago").
    static func inUseSpoken(_ relative: String, locale: Locale = .current) -> String {
        LocalizedStringResource.inUseSpokenPill(relative).string(in: locale)
    }

    /// The muted caption: "last used · 1 hour ago".
    static func lastUsedText(_ relative: String, locale: Locale = .current) -> String {
        LocalizedStringResource.inUseLastUsed(relative).string(in: locale)
    }

    static func lastUsedSpoken(_ relative: String, locale: Locale = .current) -> String {
        LocalizedStringResource.inUseSpokenLastUsed(relative).string(in: locale)
    }

    private func relative(_ age: TimeInterval, at date: Date) -> String {
        UsageFormatters.relativeReset(date.addingTimeInterval(-age), relativeTo: date)
    }
}
