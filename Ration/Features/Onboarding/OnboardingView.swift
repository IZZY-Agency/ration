import SwiftUI

/// The first-run wizard. Owns no auth logic: the connect step starts a session
/// through `AppModel.beginSignIn` and hands the ID to `onOpenSignIn`, which
/// opens the existing, hardened sign-in window.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    let onOpenSignIn: (UUID) -> Void
    let onFinish: () -> Void

    @StateObject private var flow: OnboardingModel
    /// Every session this wizard opened. A SET, not a single ID: the provider
    /// buttons stay enabled, so a user can open Claude and then ChatGPT, and
    /// cancelling the second must not clear a caption the first still earns.
    /// `signInSessions` is the authority for whether each is still open, so
    /// the caption clears itself without any reset bookkeeping here.
    @State private var openedSessionIDs: Set<UUID> = []

    init(
        model: AppModel,
        launchAtLogin: LaunchAtLoginController,
        onOpenSignIn: @escaping (UUID) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.model = model
        self.launchAtLogin = launchAtLogin
        self.onOpenSignIn = onOpenSignIn
        self.onFinish = onFinish
        // Captured once, at window creation: the step list must not change
        // shape underneath a wizard that is already open.
        _flow = StateObject(
            wrappedValue: OnboardingModel(
                accountCountAtOpen: model.presentations.count
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().overlay(Theme.line)

            ScrollView {
                stepBody
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Theme.line)

            footer
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(Theme.ink)
        .tint(Theme.gold)
        .onChange(of: signInProgress) { _, progress in
            flow.signInStateDidChange(
                accountCount: progress.accountCount,
                sessionsInFlight: progress.sessionsInFlight
            )
        }
        .onAppear { launchAtLogin.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("STEP \(flow.position.index) OF \(flow.position.total)")
                .font(Theme.mono(11))
                .tracking(1.4)
                .foregroundStyle(Theme.creamFaint)

            Spacer()

            if !flow.isFinalStep {
                Button("Skip setup") { onFinish() }
                    .buttonStyle(.plain)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var stepBody: some View {
        switch flow.step {
        case .welcome:
            OnboardingWelcomeStep()
        case .connect:
            OnboardingConnectStep(
                onSelect: startSignIn,
                isWaitingForSignIn: isWaitingForSignIn,
                signInError: flow.signInError
            )
        case .launchAtLogin:
            OnboardingLaunchAtLoginStep(launchAtLogin: launchAtLogin)
        case .done:
            OnboardingDoneStep(hasAccounts: !model.presentations.isEmpty)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if flow.canGoBack {
                Button("Back") { flow.goBack() }
            }

            Spacer()

            if flow.isFinalStep {
                Button("Done") { onFinish() }
                    .buttonStyle(.goldProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(flow.step == .connect ? "Skip for now" : "Continue") {
                    flow.advance()
                }
                .buttonStyle(.goldProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    /// The pair the auto-advance rule reads. Combined into one `Equatable`
    /// value so a single `onChange` sees both halves move together — observing
    /// the account count alone would fire mid-transaction.
    private struct SignInProgress: Equatable {
        let accountCount: Int
        let sessionsInFlight: Int
    }

    private var signInProgress: SignInProgress {
        SignInProgress(
            accountCount: model.presentations.count,
            sessionsInFlight: model.signInSessions.count
        )
    }

    /// True while ANY session this wizard started is still open.
    private var isWaitingForSignIn: Bool {
        openedSessionIDs.contains { model.signInSessions[$0] != nil }
    }

    private func startSignIn(_ provider: Provider) {
        flow.beginSignIn(
            provider: provider,
            using: { try model.beginSignIn(provider: $0) },
            open: { sessionID in
                openedSessionIDs.insert(sessionID)
                onOpenSignIn(sessionID)
            }
        )
    }
}
