import SwiftUI

struct AddAccountView: View {
    @ObservedObject var model: AppModel
    let onOpenSignIn: (UUID) -> Void
    let onDismiss: () -> Void

    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Add account")
                    .font(Theme.display(21, .bold))
                    .foregroundStyle(Theme.cream)
                Text("Each account gets a separate persistent browser profile.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.creamDim)
            }

            ForEach(Provider.allCases) { provider in
                Button {
                    beginSignIn(provider)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: provider == .claude ? "sparkles" : "hexagon")
                            .foregroundStyle(Theme.gold)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.displayName)
                                .font(Theme.display(14, .semibold))
                                .foregroundStyle(Theme.cream)
                            Text("Connect another \(provider.displayName) subscription")
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.creamDim)
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
                    .font(Theme.mono(10))
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
