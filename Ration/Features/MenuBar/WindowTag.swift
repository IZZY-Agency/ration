import SwiftUI

/// A limit window's name as a small bordered tag — "5H", "WK", "FABLE" — the
/// one look for every place a window is named (NEXT RESET line, account
/// cards, drop rows, Settings account pane). Text and 1 pt border are
/// `creamFaint`, ≥ 4.5 : 1 on ink and panel. Drawn only: VoiceOver reads the
/// surrounding element's spoken name (`UsageWindowKind.spokenName`).
struct WindowTag: View {
    static let foreground: Color = Theme.creamFaint

    let text: String
    /// Each site keeps its label's existing type size.
    var size: CGFloat = 10.5

    init(_ text: String, size: CGFloat = 10.5) {
        self.text = text.uppercased()
        self.size = size
    }

    init(kind: UsageWindowKind, label: String?, size: CGFloat = 10.5) {
        self.init(Self.text(kind: kind, label: label), size: size)
    }

    static func text(kind: UsageWindowKind, label: String?) -> String {
        switch kind {
        case .fiveHour: "5H"
        case .weekly: "WK"
        case .modelWeekly: (label ?? "Fable").uppercased()
        }
    }

    var body: some View {
        Text(text)
            .font(Theme.mono(size))
            .tracking(0.6)
            .foregroundStyle(Self.foreground)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Self.foreground, lineWidth: 1)
            )
            .fixedSize()
    }
}
