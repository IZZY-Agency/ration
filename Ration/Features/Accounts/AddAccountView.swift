import SwiftUI

struct AddAccountView: View {
    @ObservedObject var model: AppModel
    let onOpenSignIn: (UUID) -> Void
    let onDismiss: () -> Void

    @State private var errorMessage: String?

    /// Each provider row's icon wears that provider's identity accent (ChatGPT
    /// and Cursor used to borrow Claude's gold).
    static func iconAccent(for provider: Provider) -> Color { provider.markAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Add account")
                    .font(Theme.display(23, .bold))
                    .foregroundStyle(Theme.cream)
                Text("Each account gets a separate persistent browser profile.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)
                    // ≈403 pt in Mono 12 against a 376 pt column: wrap to a
                    // second line instead of truncating.
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Provider.allCases) { provider in
                Button {
                    beginSignIn(provider)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: provider == .claude ? "sparkles" : "hexagon")
                            .foregroundStyle(Self.iconAccent(for: provider))
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.displayName)
                                .font(Theme.display(16, .semibold))
                                .foregroundStyle(Theme.cream)
                            Text("Connect another \(provider.displayName) subscription")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.creamDim)
                            if provider == .claude {
                                Text(WarmUpDefaults.newClaudeAccountDisclosure(
                                    warmUpEnabled: model.settings.featureWarmUpEnabled
                                ))
                                    .font(Theme.mono(11))
                                    .foregroundStyle(Theme.creamDim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Theme.creamFaint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(provider.displayName) account")
                .padding(14)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12).stroke(Theme.line2, lineWidth: 1)
                )
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.crit)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onDismiss()
                }
            }
        }
        .padding(22)
        .frame(width: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
        .tint(Theme.gold)
    }

    private func beginSignIn(_ provider: Provider) {
        do {
            let sessionID = try model.beginSignIn(provider: provider)
            onOpenSignIn(sessionID)
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
