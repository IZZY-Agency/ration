import Foundation

/// The first-run wizard's steps, in canonical order.
enum OnboardingStep: String, CaseIterable, Sendable {
    case welcome
    case connect
    case launchAtLogin
    case done
}

/// Pure step arithmetic for the first-run wizard. Free of UI and I/O so the
/// sequence, the which-steps-apply rule, and the auto-present predicate are
/// all directly testable.
enum OnboardingFlow {
    /// The wizard's steps, in order. Every step always applies: the
    /// launch-at-login step used to be dropped when `SMAppService` looked
    /// unavailable, until 0.29.0 established that its `.notFound` is merely the
    /// never-registered state (see `LaunchAtLoginController`).
    static let steps: [OnboardingStep] = OnboardingStep.allCases

    /// `nil` at the end of the sequence.
    static func next(after step: OnboardingStep) -> OnboardingStep? {
        guard
            let index = steps.firstIndex(of: step),
            steps.indices.contains(index + 1)
        else {
            return nil
        }
        return steps[index + 1]
    }

    /// `nil` at the start of the sequence.
    static func previous(before step: OnboardingStep) -> OnboardingStep? {
        guard
            let index = steps.firstIndex(of: step),
            steps.indices.contains(index - 1)
        else {
            return nil
        }
        return steps[index - 1]
    }

    /// 1-based position for the "Step 2 of 4" indicator. `steps` is
    /// `allCases`, so every step has an index.
    static func position(of step: OnboardingStep) -> (index: Int, total: Int) {
        (steps.firstIndex(of: step)! + 1, steps.count)
    }

    /// Whether the wizard should open by itself at launch.
    ///
    /// Three conditions, each load-bearing:
    /// - `hasCompletedOnboarding` — set on any dismissal, so shown-once.
    /// - `accountCount == 0` — an existing install has no such key in
    ///   `settings.json`, so it decodes to `false`; without this guard an
    ///   upgrade would greet every current user with a welcome wizard. It
    ///   cannot mis-fire later, because the flag is set on first dismissal and
    ///   survives the user deleting every account.
    /// - `!settingsLoadFailed` — corrupt JSON substitutes defaults, and a
    ///   `false` from substituted defaults is not a user choice, so this fails
    ///   closed (the same rule `AppModel.warmUpSchedule` applies to quiet
    ///   hours).
    static func shouldPresentAtLaunch(
        hasCompletedOnboarding: Bool,
        accountCount: Int,
        settingsLoadFailed: Bool
    ) -> Bool {
        !hasCompletedOnboarding && accountCount == 0 && !settingsLoadFailed
    }
}
