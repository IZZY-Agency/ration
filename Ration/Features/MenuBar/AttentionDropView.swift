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

    /// Set once by the controller; not published — changing a callback must
    /// not invalidate the view.
    var onDismissAll: () -> Void = {}
    var onSelect: (AttentionRow) -> Void = { _ in }
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
                AttentionDropRowView(row: row, now: now, onSelect: { onSelect(row) })
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text(limitRows.isEmpty ? "RESETS" : "NEARING LIMITS")
                .font(Theme.mono(9))
                .tracking(1.2)
                .foregroundStyle(Theme.creamFaint)

            if criticalCount > 0 {
                Text("\(criticalCount) CRIT")
                    .font(Theme.mono(9))
                    .tracking(1.2)
                    .foregroundStyle(Theme.crit)
            }
            if criticalCount > 0 && warningCount > 0 {
                Text("·").font(Theme.mono(9)).foregroundStyle(Theme.creamFaint)
            }
            if warningCount > 0 {
                Text("\(warningCount) WARN")
                    .font(Theme.mono(9))
                    .tracking(1.2)
                    .foregroundStyle(Theme.warn)
            }
            if resetRowCount > 0 && !limitRows.isEmpty {
                Text("·").font(Theme.mono(9)).foregroundStyle(Theme.creamFaint)
                Text("\(resetRowCount) RESET")
                    .font(Theme.mono(9))
                    .tracking(1.2)
                    .foregroundStyle(Theme.resetAccent)
            }

            Spacer(minLength: 8)

            Button { onDismissAll() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
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

                Text(row.accountLabel)
                    .font(Theme.display(13, .semibold))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                    .layoutPriority(1)

                Text(subjectLabel)
                    .font(Theme.mono(10))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.creamFaint)
                    .lineLimit(1)
                    .layoutPriority(1)

                meter

                Text(valueLabel)
                    .font(Theme.mono(12.5, bold: true))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Text(resetLabel)
                    .font(Theme.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.resetAccent)
                    .lineLimit(1)
                    .frame(width: 46, alignment: .trailing)
            }
            .padding(.horizontal, 13)
            .frame(
                maxWidth: .infinity,
                minHeight: AttentionDropGeometry.rowHeight,
                maxHeight: AttentionDropGeometry.rowHeight,
                alignment: .leading
            )
            .background(isHovering ? Theme.cream.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens Ration and dismisses this row")
    }

    /// Cursor has no denominator, so its line shows the amount alone with no
    /// meter — there is nothing to fill a meter against.
    @ViewBuilder
    private var meter: some View {
        if let percent = row.usedPercent {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cream.opacity(0.09))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, geometry.size.width * Double(percent) / 100))
                }
            }
            .frame(height: 3)
        } else {
            Spacer(minLength: 8)
        }
    }

    private var subjectLabel: String {
        switch row.subject {
        case .window(.fiveHour): "5H"
        case .window(.weekly): "WK"
        case .window(.modelWeekly): "Fable"
        case .cursorSpend: "spend"
        case .resetCredit(_, .available): "reset"
        case .resetCredit(_, .expiring): "expires"
        }
    }

    private var valueLabel: String {
        if let count = row.resetCount { return "×\(count)" }
        if let percent = row.usedPercent { return "\(percent)%" }
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

    private var accessibilityLabel: String {
        if case .resetCredit(_, let kind) = row.subject {
            let count = row.resetCount ?? 1
            let expires = row.resetsAt.map { "expires in \(UsageFormatters.resetCreditRemaining($0, relativeTo: now))" } ?? ""
            return "\(row.accountLabel), \(count) usage-limit reset\(count == 1 ? "" : "s") \(kind == .expiring ? "expiring" : "available"), \(expires)"
        }
        let tierWord = row.tier == .critical ? "critical" : "warning"
        let value = row.usedPercent.map { "\($0) percent used" }
            ?? row.spentCents.map { "\(AlertMessage.dollars($0)) spent" }
            ?? ""
        let reset = row.resetsAt.map { ", resets in \(UsageFormatters.remainingUntilReset($0, relativeTo: now))" } ?? ""
        return "\(row.accountLabel), \(subjectLabel), \(value), \(tierWord)\(reset)"
    }
}
