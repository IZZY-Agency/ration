import SwiftUI

/// One gauge in a compact popover row: the window's tag, its
/// percent and its reset side by side, a thin bar under them, and — on rows
/// that show them — the sparkline. The row speaks every gauge in its own
/// label (`AccountRowCopy.spokenRow`); inside it, each countdown is a button
/// that speaks its gauge, and the sparkline keeps its own label.
struct CompactLimitView: View {
    struct Sparkline {
        let samples: [UsageHistorySample]
        let projection: Date?
    }

    let title: String
    let window: UsageWindow?
    /// Which window this is, so VoiceOver hears "5 hour" rather than the
    /// drawn "5H", and each countdown has its own identifier.
    var kind: UsageWindowKind? = nil
    var now: Date = .now
    /// Nil: no trend line (folded-away or flat).
    var sparkline: Sparkline? = nil

    /// A click on the countdown shows the absolute reset time on its own
    /// line under the bar; the next click on the countdown hides it again
    /// (tooltips do not render on macOS 27). Settable at creation for tests;
    /// the row starts it false.
    @State var showsExactReset = false

    /// The countdown's forms, longest first: the full one ("12 h 30 min"),
    /// then its leading unit ("12 h") for a column too narrow for it — a
    /// FABLE tag and a French percent leave little room. The due state and
    /// the exact time have one form: a leading unit would say "0 min".
    static func countdowns(
        resetsAt: Date, now: Date, showsExact: Bool,
        locale: Locale = .current, timeZone: TimeZone = .current
    ) -> [String] {
        let full: String = LimitRowView.resetCaptionText(resetsAt: resetsAt, now: now, showsExact: showsExact,
                                                         locale: locale, timeZone: timeZone)
        guard !showsExact, !UsageFormatters.isResetDue(resetsAt, relativeTo: now) else { return [full] }
        let short: String = UsageFormatters.remainingUntilResetLeadingUnit(resetsAt, relativeTo: now, locale: locale)
        return short == full ? [full] : [full, short]
    }

    /// "resetCountdown.weekly", "resetExact.fiveHour": one per window.
    private func identifier(_ base: String) -> String {
        kind.map { "\(base).\($0.rawValue)" } ?? base
    }

    private var tooltip: String { LimitRowView.tooltip(title: title, window: window, now: now) }

    var body: some View {
        // The tooltip goes on each drawn piece, never on a stack around the
        // countdown: there SwiftUI would stretch the countdown button's
        // accessibility frame over the whole gauge.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    WindowTag(title, size: 10)
                        .help(tooltip)
                        .accessibilityHidden(true)
                    LimitPercentText(window: window, size: 14)
                        .help(tooltip)
                        .accessibilityHidden(true)
                    Spacer(minLength: 4)
                    // Offered the room before the spacer: otherwise the two
                    // split it and the countdown shrinks though it fits. It
                    // stays while the exact time shows, so the next click
                    // lands on it again.
                    resetCaption
                        .layoutPriority(1)
                }
                LimitMeter(window: window, height: 3)
                    .help(tooltip)
                    .accessibilityHidden(true)
                // The exact time ("15 oct. à 19:43") never fits beside the
                // tag and percent: it takes its own line under the bar.
                if showsExactReset, let resetsAt = window?.resetsAt {
                    exactReset(resetsAt)
                }
            }

            if let sparkline {
                UsageSparkline(
                    samples: sparkline.samples,
                    projection: sparkline.projection,
                    tierUsedFraction: window?.usedFraction ?? 0,
                    now: now,
                    height: 20
                )
                .padding(.top, 8)
            }
        }
    }

    /// The countdown, a button: each click shows or hides the exact time
    /// under the bar. VoiceOver hears the whole gauge, as each gauge read
    /// before the compact rows (`LimitRowView`), and the gauge's tooltip as
    /// its help. No hint: on macOS a hint is that same help attribute, and
    /// the tooltip wins it.
    @ViewBuilder
    private var resetCaption: some View {
        if let resetsAt = window?.resetsAt {
            // The exact time has its own line (`exactReset`).
            let forms = Self.countdowns(resetsAt: resetsAt, now: now, showsExact: false)
            Button {
                showsExactReset.toggle()
            } label: {
                // The full countdown when it fits, else its leading unit,
                // each at full size; only when neither fits does the short
                // one shrink.
                ViewThatFits(in: .horizontal) {
                    ForEach(forms, id: \.self) { form in
                        countdown(form, shrinks: false)
                    }
                    countdown(forms.last ?? "", shrinks: true)
                }
                .foregroundStyle(Theme.resetAccent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(tooltip)
            .accessibilityLabel(LimitRowView.accessibilityDescription(title: title, kind: kind, window: window, now: now))
            .accessibilityIdentifier(identifier("resetCountdown"))
        } else if window != nil {
            Text("no scheduled reset")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.creamFaint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
                .help(tooltip)
                .accessibilityHidden(true)
        }
    }

    /// The exact reset time on its own line. Text only: a click on it does
    /// nothing — the countdown above takes it away.
    private func exactReset(_ resetsAt: Date) -> some View {
        let text: String = LimitRowView.resetCaptionText(resetsAt: resetsAt, now: now, showsExact: true)
        return HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9.5, weight: .bold))
            Text(text)
                .font(Theme.mono(12, bold: true))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(Theme.resetAccent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier(identifier("resetExact"))
    }

    /// One countdown form: at its full size, or (the last resort) allowed to
    /// shrink into whatever room is left.
    private func countdown(_ text: String, shrinks: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9.5, weight: .bold))
            Text(text)
                .font(Theme.mono(12, bold: true))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(shrinks ? 0.75 : 1)
        }
        .fixedSize(horizontal: !shrinks, vertical: false)
    }
}

/// A folded row's one gauge: tag, a short bar, the percent and
/// the reset, at set widths so folded rows line up. The bar is the one part
/// that gives way when the line is short of room.
struct FoldedLimitView: View {
    let title: String
    let window: UsageWindow?
    var now: Date = .now

    static let meterWidth: CGFloat = 84
    static let meterMinWidth: CGFloat = 32
    static let percentWidth: CGFloat = 40
    static let resetWidth: CGFloat = 70

    var body: some View {
        HStack(spacing: 8) {
            WindowTag(title, size: 10)
            LimitMeter(window: window, height: 3)
                .frame(minWidth: Self.meterMinWidth, idealWidth: Self.meterWidth, maxWidth: Self.meterWidth)
            LimitPercentText(window: window, size: 13)
                .frame(minWidth: Self.percentWidth, alignment: .trailing)
                .fixedSize()
            reset
                .frame(minWidth: Self.resetWidth, alignment: .leading)
                .fixedSize()
        }
        .fixedSize(horizontal: false, vertical: true)
        .help(LimitRowView.tooltip(title: title, window: window, now: now))
    }

    @ViewBuilder
    private var reset: some View {
        if let resetsAt = window?.resetsAt {
            HStack(spacing: 3) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9.5, weight: .bold))
                Text(UsageFormatters.remainingUntilReset(resetsAt, relativeTo: now))
                    .font(Theme.mono(12, bold: true))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.resetAccent)
        } else {
            Text(verbatim: "—")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.creamFaint)
        }
    }
}

/// A usage window's used percent, tier-coloured from half full (as on
/// `LimitRowView`); "—" without a reading.
struct LimitPercentText: View {
    let window: UsageWindow?
    let size: CGFloat

    var body: some View {
        if let window {
            Text(UsageFormatters.compactUsedPercentage(window.usedFraction))
                .font(Theme.mono(size))
                .monospacedDigit()
                .foregroundStyle(window.usedFraction >= 0.50 ? Theme.tierColor(usedFraction: window.usedFraction) : Theme.cream)
                .contentTransition(.numericText())
                .lineLimit(1)
                .fixedSize()
        } else {
            Text(verbatim: "—")
                .font(Theme.mono(size))
                .foregroundStyle(Theme.creamFaint)
                .fixedSize()
        }
    }
}

/// A thin capsule bar filled to the used fraction in its tier colour; an
/// empty track without a reading.
struct LimitMeter: View {
    let window: UsageWindow?
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(window == nil ? Theme.line : Theme.track)
                if let window {
                    Capsule()
                        .fill(Theme.tierColor(usedFraction: window.usedFraction))
                        .frame(width: max(height, geometry.size.width * min(max(window.usedFraction, 0), 1)))
                }
            }
        }
        .frame(height: height)
    }
}
