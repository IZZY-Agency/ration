import Foundation

/// Observable state for the first-run wizard.
///
/// Deliberately thin: every decision about *which* step comes next lives in
/// `OnboardingFlow`. What this type adds is the two pieces of state a pure
/// function cannot hold — the current step, and the auto-advance latch.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var step: OnboardingStep = .welcome
    @Published var signInError: String?

    /// The account count when the wizard opened. Only a count that rises ABOVE
    /// this one counts as "the account they just added" — re-opening the Setup
    /// Guide with three accounts already connected must not skip the connect
    /// step.
    private let accountCountAtOpen: Int
    private var didAutoAdvance = false
    /// Last observed sign-in progress, retained so a step change can be
    /// evaluated against it (see `evaluateAutoAdvance`).
    private var lastKnownAccountCount: Int?
    private var lastKnownSessionsInFlight: Int?

    init(accountCountAtOpen: Int) {
        self.accountCountAtOpen = accountCountAtOpen
    }

    var position: (index: Int, total: Int) {
        OnboardingFlow.position(of: step)
    }

    var canGoBack: Bool {
        OnboardingFlow.previous(before: step) != nil
    }

    var isFinalStep: Bool {
        OnboardingFlow.next(after: step) == nil
    }

    func advance() {
        guard let next = OnboardingFlow.next(after: step) else { return }
        step = next
        evaluateAutoAdvance()
    }

    func goBack() {
        guard let previous = OnboardingFlow.previous(before: step) else { return }
        step = previous
        evaluateAutoAdvance()
    }

    /// Starts a sign-in session and hands the caller its ID to open a window
    /// with. Takes the session factory as a closure rather than an `AppModel`
    /// so the wizard's error handling is testable without a live model.
    func beginSignIn(
        provider: Provider,
        using makeSession: (Provider) throws -> UUID,
        open: (UUID) -> Void
    ) {
        signInError = nil
        do {
            open(try makeSession(provider))
        } catch {
            signInError = error.localizedDescription
        }
    }

    /// Advances past `.connect` once a sign-in has actually *settled*.
    ///
    /// Account creation is not atomic: `completeSignIn` calls
    /// `accountStore.add` — which publishes immediately — and only then saves
    /// the snapshot, rolling the account back out if that save fails. So the
    /// account count genuinely goes 0 → 1 → 0 on a failed sign-in. Advancing on
    /// the count alone would latch on that transient, move the wizard past a
    /// sign-in that did not happen, and then refuse to advance on the retry.
    ///
    /// `sessionsInFlight == 0` is what makes this safe: the transient is only
    /// ever published while the committing session is still open, so requiring
    /// a quiet session table means the count being up reflects a committed
    /// account. If an unrelated sign-in is open, this simply defers — the next
    /// publish, when that session closes, advances instead.
    func signInStateDidChange(accountCount: Int, sessionsInFlight: Int) {
        lastKnownAccountCount = accountCount
        lastKnownSessionsInFlight = sessionsInFlight
        evaluateAutoAdvance()
    }

    /// Re-run on every step change as well as every progress change, because
    /// the sign-in can complete while the user is looking at a different step:
    /// open sign-in from Connect, press Back, finish signing in, then Continue
    /// — the progress transition was already consumed on Welcome, so arriving
    /// back at Connect would otherwise strand the user there.
    ///
    /// `didAutoAdvance` is what keeps this from becoming a trap: once it has
    /// fired, pressing Back to Connect deliberately stays on Connect instead of
    /// bouncing the user forward again.
    private func evaluateAutoAdvance() {
        guard !didAutoAdvance, step == .connect else { return }
        guard
            let lastKnownSessionsInFlight,
            lastKnownSessionsInFlight == 0,
            let lastKnownAccountCount,
            lastKnownAccountCount > accountCountAtOpen
        else {
            return
        }
        // Set BEFORE advancing: `advance()` re-enters here, and this is what
        // terminates that recursion.
        didAutoAdvance = true
        advance()
    }
}
