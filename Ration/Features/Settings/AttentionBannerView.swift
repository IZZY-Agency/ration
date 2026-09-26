import SwiftUI

/// The amber "Needs attention" card at the top of an account's Settings page:
/// the cause, the steps and the buttons that fix it. Pure presentation of an
/// `AttentionGuidance`; the pane decides what each action runs.
struct AttentionBannerView: View {
    let guidance: AttentionGuidance
    let onAction: (AttentionGuidance.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(guidance.label)
                    .font(Theme.mono(11))
                    .tracking(1.2)
                    .textCase(.uppercase)
            }
            .foregroundStyle(Theme.warn)
            .accessibilityHidden(true)

            Text(guidance.title)
                .font(Theme.display(15, .semibold))
                .foregroundStyle(Theme.cream)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(guidance.body)
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.cream)
                .fixedSize(horizontal: false, vertical: true)

            if !guidance.steps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(guidance.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "\(index + 1).")
                                .font(Theme.mono(12.5, bold: true))
                                .foregroundStyle(Theme.warn)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.text)
                                    .font(Theme.mono(12.5))
                                    .foregroundStyle(Theme.cream)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let link = step.link {
                                    Button {
                                        onAction(link)
                                    } label: {
                                        Text(link.title())
                                            .font(Theme.mono(12.5, bold: true))
                                            .underline()
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.gold)
                                    .pointerStyle(.link)
                                }
                            }
                        }
                    }
                }
            }

            if !guidance.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(guidance.actions.enumerated()), id: \.element) { index, action in
                        actionButton(action, primary: index == 0)
                    }
                }
                .padding(.top, 2)
            }

            if let meta = guidance.meta {
                Text(meta)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.creamDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.warn.opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.warn.opacity(0.45), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(guidance.label)
        .accessibilityIdentifier("attentionBanner")
    }

    @ViewBuilder
    private func actionButton(_ action: AttentionGuidance.Action, primary: Bool) -> some View {
        let title: String = action.title()
        if primary {
            Button {
                onAction(action)
            } label: {
                Text(title).font(Theme.mono(12, bold: true))
            }
            .buttonStyle(.goldProminent)
        } else {
            Button {
                onAction(action)
            } label: {
                Text(title).font(Theme.mono(12, bold: true))
            }
            .buttonStyle(AttentionSecondaryButtonStyle())
        }
    }
}

/// The banner's other buttons: the gold button's shape, outlined.
private struct AttentionSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.cream)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Theme.hover : Theme.panel)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.line2, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
    }
}
