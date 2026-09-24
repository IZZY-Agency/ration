import SwiftUI

/// A single usage window rendered as one inline row: mono label · hairline
/// meter · percentage. Compact "Terminal Ledger" treatment.
struct LimitRowView: View {
    let title: String
    let window: UsageWindow?
    var now: Date = .now
    /// Which window this is, so VoiceOver hears "5 hour" rather than the
    /// drawn "5H". Nil falls back to speaking `title`.
    var kind: UsageWindowKind? = nil

    /// Clicking the countdown flips it to the absolute reset time — the exact
    /// time must not be tooltip-only (tooltips do not render on macOS 27).
    @State private var showsExactReset = false

    private var tint: Color {
        guard let window else { return Theme.creamFaint }
        return Theme.tierColor(usedFraction: window.usedFraction)
    }

    private var numberColor: Color {
        guard let window else { return Theme.creamFaint }
        return window.usedFraction >= 0.50 ? tint : Theme.cream
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(title)
                    .font(Theme.mono(13))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.creamFaint)
                    // Never "FABL/E": the title keeps its natural width on one
                    // line and the meter (GeometryReader) gives way instead.
                    .lineLimit(1)
                    .fixedSize()

                if let window {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule()
                                .fill(tint)
                                .frame(
                                    width: max(2, geometry.size.width * window.usedFraction)
                                )
                        }
                    }
                    .frame(height: 4)

                    Text(UsageFormatters.usedPercentage(window.usedFraction))
                        .font(Theme.mono(15.5))
                        .monospacedDigit()
                        .foregroundStyle(numberColor)
                        .contentTransition(.numericText())
                        // Never let the "NN %" break onto a second line — the
                        // meter (GeometryReader) flexes to give this its natural
                        // width instead.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Rectangle().fill(Theme.line)
                        .frame(height: 4).clipShape(Capsule())
                    Text("—")
                        .font(Theme.mono(15.5))
                        .foregroundStyle(Theme.creamFaint)
                }
            }

            resetCaption
        }
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var resetCaption: some View {
        HStack(spacing: 4) {
            if let resetsAt = window?.resetsAt {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .bold))
                Text(Self.resetCaptionText(resetsAt: resetsAt, now: now, showsExact: showsExactReset))
                    .font(Theme.mono(14, bold: true))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else if window != nil {
                Text("no scheduled reset")
                    .font(Theme.mono(11.5))
                    .lineLimit(1)
                    .foregroundStyle(Theme.creamFaint)
            }
        }
        .foregroundStyle(Theme.resetAccent)
        .contentShape(Rectangle())
        .onTapGesture {
            if window?.resetsAt != nil { showsExactReset.toggle() }
        }
        // Hidden: the row's own label already speaks both the countdown and
        // the exact time.
        .accessibilityHidden(true)
    }

    /// The caption under the meter: the countdown, or — after a click — the
    /// absolute reset time.
    static func resetCaptionText(
        resetsAt: Date,
        now: Date,
        showsExact: Bool,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        showsExact
            ? UsageFormatters.shortReset(resetsAt, locale: locale, timeZone: timeZone)
            : UsageFormatters.remainingUntilReset(resetsAt, relativeTo: now)
    }

    private var tooltip: String {
        guard let window else { return "\(title): unavailable" }
        guard let resetsAt = window.resetsAt else { return "\(title): no scheduled reset" }
        return "\(title) · resets \(UsageFormatters.compactReset(resetsAt, relativeTo: now))"
    }

    private var accessibilityDescription: String {
        Self.accessibilityDescription(title: title, kind: kind, window: window, now: now)
    }

    /// What VoiceOver reads for the row: the window's spoken name, the used
    /// percentage, the countdown in words AND the exact reset time — the
    /// latter otherwise lived only in the tooltip.
    static func accessibilityDescription(
        title: String,
        kind: UsageWindowKind?,
        window: UsageWindow?,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        // For the model window `title` IS the API label ("Fable").
        let name = kind.map { $0.spokenName(label: title) } ?? title
        guard let window else { return "\(name), unavailable" }
        let reset = window.resetsAt.map {
            let countdown = UsageFormatters.spokenDuration(until: $0, relativeTo: now, locale: locale)
            let exact = UsageFormatters.exactReset($0, locale: locale, timeZone: timeZone)
            return countdown == "now" ? "resets now, at \(exact)" : "resets in \(countdown), at \(exact)"
        } ?? "reset not scheduled"
        return "\(name), \(UsageFormatters.usedPercentage(window.usedFraction, locale: locale)) used, \(reset)"
    }
}
