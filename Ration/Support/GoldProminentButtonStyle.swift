import SwiftUI

/// The primary (default-action) button: a gold fill with an `onGold` label.
///
/// Replaces `.borderedProminent` under `.tint(Theme.gold)`: the system draws
/// that button's label WHITE whatever the tint, which is 1.99 : 1 on dark
/// gold (#D9B44A) and fails AA. A style of our own is the only way to choose
/// the label colour — the system ignores a `foregroundStyle` on it.
struct GoldProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.onGold)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.gold)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

extension ButtonStyle where Self == GoldProminentButtonStyle {
    static var goldProminent: GoldProminentButtonStyle { GoldProminentButtonStyle() }
}
