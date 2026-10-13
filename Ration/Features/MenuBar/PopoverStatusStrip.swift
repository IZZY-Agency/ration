import SwiftUI

/// The one status strip under the popover header: the keep-awake notice and
/// the snoozed-drop notice, which used to be two banners, in one band — a
/// row each, only the ones that apply. Pure, so the composition is
/// tested without a view (`PopoverStatusStripTests`).
struct PopoverStatusStrip: Equatable {
    enum Item: Equatable {
        /// The Mac is held awake. `isOverride`: the user's own override,
        /// drawn gold (easy to forget); the automatic hold stays quiet.
        case keepAwake(text: String, isOverride: Bool)
        /// The drop is held back until a limit resets; the row offers
        /// "Show now".
        case dropSnoozed

        /// The keep-awake glyph is the footer eye's live one.
        var symbol: String {
            switch self {
            case .keepAwake: MenuBarView.keepAwakeGlyph(.automatic)
            case .dropSnoozed: "bell.badge.slash"
            }
        }
    }

    let items: [Item]

    /// Nil when nothing applies. The drop counts as snoozed only while it is
    /// off screen: on screen, nothing is hidden.
    static func make(
        keepAwake: KeepAwakeStatus,
        dropSnoozed: Bool,
        dropShowing: Bool,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> PopoverStatusStrip? {
        var items: [Item] = []
        if let text = KeepAwakeCopy.banner(keepAwake, locale: locale, timeZone: timeZone) {
            items.append(.keepAwake(text: text, isOverride: keepAwake != .automatic))
        }
        if dropSnoozed && !dropShowing {
            items.append(.dropSnoozed)
        }
        return items.isEmpty ? nil : PopoverStatusStrip(items: items)
    }
}

/// Draws a `PopoverStatusStrip`: one band, a row per notice, each with its
/// glyph; the drop's row ends with "Show now".
struct PopoverStatusStripView: View {
    let strip: PopoverStatusStrip
    let onShowAttentionDrop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(strip.items.enumerated()), id: \.offset) { _, item in
                row(item)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel.opacity(Self.groundOpacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("popoverStatusStrip")
    }

    /// The band's ground: half-way from the popover's ink to the panel, so
    /// the strip reads as one band without competing with the rows.
    static let groundOpacity = 0.55

    @ViewBuilder
    private func row(_ item: PopoverStatusStrip.Item) -> some View {
        switch item {
        case let .keepAwake(text, isOverride):
            label(text, symbol: item.symbol)
                .foregroundStyle(isOverride ? Theme.gold : Theme.creamDim)
                .accessibilityIdentifier("popoverKeepAwakeBanner")
        case .dropSnoozed:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label(String(localized: LocalizedStringResource.popoverDropSnoozedBanner), symbol: item.symbol)
                    .foregroundStyle(Theme.creamDim)
                Spacer(minLength: 8)
                Button(action: onShowAttentionDrop) { Text(LocalizedStringResource.popoverDropSnoozedShow) }
                    .font(Theme.mono(11.5))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.gold)
                    .fixedSize()
                    .accessibilityIdentifier("popoverShowAttentionDropButton")
            }
        }
    }

    private func label(_ text: String, symbol: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 14)
        }
        .font(Theme.mono(11.5))
        .labelStyle(StripLabelStyle())
    }
}

/// Icon and text 8 pt apart, aligned on the text's first line.
private struct StripLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
            configuration.title
        }
    }
}
