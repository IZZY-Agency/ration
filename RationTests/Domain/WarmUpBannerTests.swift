import Foundation
import XCTest
@testable import Ration

/// The warm-up banner is DERIVED, never stored: it must retract on its own when
/// the statement it makes stops being true. The predecessor was a written-once
/// `AppModel.errorMessage` that nothing ever cleared — an auto-start failure sat
/// in the popover until the app was quit, even after a later warm-up succeeded.
final class WarmUpBannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func account(
        id: UUID = UUID(),
        label: String = "AI",
        provider: Provider = .claude,
        autoStart: Bool = true,
        paused: Bool = false,
        lastAutoStartedAt: Date? = nil
    ) -> AccountRecord {
        AccountRecord(
            id: id,
            provider: provider,
            label: label,
            webProfileID: UUID(),
            displayOrder: 0,
            createdAt: .distantPast,
            autoStartFiveHour: autoStart,
            keepAliveConversationID: nil,
            lastAutoStartedAt: lastAutoStartedAt,
            isPaused: paused
        )
    }

    /// The state that fires warm-up: a fresh, unused 5h window with no reset.
    private func presentation(
        account: AccountRecord,
        weeklyRemaining: Double?
    ) -> AccountPresentation {
        AccountPresentation(
            account: account,
            snapshot: UsageSnapshot(
                accountID: account.id,
                fetchedAt: now,
                fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 1, resetsAt: nil),
                weekly: weeklyRemaining.map {
                    UsageWindow(
                        kind: .weekly,
                        remainingFraction: $0,
                        resetsAt: now.addingTimeInterval(6 * 3600)
                    )
                }
            ),
            state: .current
        )
    }

    // MARK: Nothing to say

    func testNoBannerWhenNothingIsWrong() {
        let account = account()
        XCTAssertNil(WarmUpBannerModel.banner(
            presentations: [presentation(account: account, weeklyRemaining: 0.5)],
            failures: [:],
            schedule: .allowAll,
            now: now
        ))
    }

    // MARK: Blocked by an exhausted weekly allowance

    func testBlockedBannerNamesTheAccountAndWhenWarmUpResumes() {
        let account = account(label: "AI")
        let banner = WarmUpBannerModel.banner(
            presentations: [presentation(account: account, weeklyRemaining: 0)],
            failures: [:],
            schedule: .allowAll,
            now: now
        )
        let message = banner?.message ?? ""
        XCTAssertEqual(banner?.severity, .info, "a spent allowance is a status, not an error")
        XCTAssertTrue(
            message.contains("AI"),
            "the banner must name the account it describes (\(message))"
        )
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("weekly limit"),
            "the banner must say why warm-up is paused (\(message))"
        )
        XCTAssertTrue(
            message.contains("6h"),
            "the banner must say when warm-up resumes (\(message))"
        )
    }

    /// Only reported when the exhausted allowance is the ONLY thing standing in
    /// the way — otherwise "warm-up paused, weekly limit reached" would show for
    /// accounts whose 5h window is happily running and had nothing to do anyway.
    func testNoBlockedBannerWhileTheFiveHourWindowIsStillRunning() {
        let account = account()
        let presentation = AccountPresentation(
            account: account,
            snapshot: UsageSnapshot(
                accountID: account.id,
                fetchedAt: now,
                fiveHour: UsageWindow(
                    kind: .fiveHour,
                    remainingFraction: 0.4,
                    resetsAt: now.addingTimeInterval(3600)
                ),
                weekly: UsageWindow(kind: .weekly, remainingFraction: 0, resetsAt: nil)
            ),
            state: .current
        )
        XCTAssertNil(WarmUpBannerModel.banner(
            presentations: [presentation],
            failures: [:],
            schedule: .allowAll,
            now: now
        ))
    }

    func testNoBlockedBannerForAnAccountWithWarmUpTurnedOff() {
        let account = account(autoStart: false)
        XCTAssertNil(WarmUpBannerModel.banner(
            presentations: [presentation(account: account, weeklyRemaining: 0)],
            failures: [:],
            schedule: .allowAll,
            now: now
        ))
    }

    func testSeveralBlockedAccountsCollapseToOneLineWithACount() {
        let first = account(label: "AI")
        let second = account(label: "Ada")
        let banner = WarmUpBannerModel.banner(
            presentations: [
                presentation(account: first, weeklyRemaining: 0),
                presentation(account: second, weeklyRemaining: 0)
            ],
            failures: [:],
            schedule: .allowAll,
            now: now
        )
        let message = banner?.message ?? ""
        XCTAssertTrue(message.contains("AI"), "the first blocked account is named (\(message))")
        XCTAssertTrue(
            message.contains("1 more"),
            "the rest are counted rather than listed (\(message))"
        )
    }

    /// An observation made BEFORE a reset that has since passed says nothing
    /// about the present — the allowance may well be back, and the next poll
    /// will say so. Claiming "resumes in now" is worse than saying nothing.
    func testNoHoldBannerFromAnObservationTakenBeforeAResetThatHasSincePassed() {
        XCTAssertNil(WarmUpBannerModel.banner(
            presentations: [spentPresentation(
                fetchedSecondsAgo: 300,
                resetsInSeconds: -60
            )],
            failures: [:],
            schedule: .allowAll,
            now: now
        ))
    }

    /// The other half of that coin, and the reason the rule cannot simply be
    /// "reset passed → say nothing": a snapshot taken AFTER its own reported
    /// reset that STILL says the allowance is spent is current evidence. Warm-up
    /// really is being withheld, so the row has to explain it — just without a
    /// countdown it cannot honestly give.
    func testAFreshObservationPastItsOwnResetStillExplainsTheHold() {
        let banner = WarmUpBannerModel.banner(
            presentations: [spentPresentation(
                fetchedSecondsAgo: 60,
                resetsInSeconds: -120
            )],
            failures: [:],
            schedule: .allowAll,
            now: now
        )
        let message = banner?.message ?? ""
        XCTAssertEqual(banner?.severity, .info)
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("weekly limit"),
            "warm-up is genuinely held; the row must still say why (\(message))"
        )
        XCTAssertFalse(
            message.contains("resumes in"),
            "no countdown can be honest here — the reported reset is behind us (\(message))"
        )
    }

    /// Evidence expires. An app that has been asleep or offline past a couple of
    /// poll cycles no longer knows the allowance is spent, and must stop saying
    /// so — the "resumes in now, forever" case.
    func testNoHoldBannerFromAnObservationOlderThanTheAppCanVouchFor() {
        XCTAssertNil(WarmUpBannerModel.banner(
            presentations: [spentPresentation(
                fetchedSecondsAgo: WarmUpBannerModel.maxEvidenceAge + 60,
                resetsInSeconds: 6 * 3600
            )],
            failures: [:],
            schedule: .allowAll,
            now: now
        ))
    }

    /// The two boundary tests above are stated RELATIVE to the constant, so they
    /// would follow it anywhere. This pins the value itself: it has to outlast
    /// the longest gap the poller can normally leave, or an ordinary Low Power
    /// Mode cycle would blank the row.
    func testTheEvidenceWindowOutlastsTheSlowestNormalPoll() {
        XCTAssertGreaterThan(
            WarmUpBannerModel.maxEvidenceAge,
            Double(PollSchedule.lowPowerSeconds + PollSchedule.maxJitterSeconds)
        )
    }

    /// The bound must not blank the row on an ordinary slow poll.
    func testAnObservationWithinTheEvidenceWindowStillExplainsTheHold() {
        XCTAssertNotNil(WarmUpBannerModel.banner(
            presentations: [spentPresentation(
                fetchedSecondsAgo: WarmUpBannerModel.maxEvidenceAge - 60,
                resetsInSeconds: 6 * 3600
            )],
            failures: [:],
            schedule: .allowAll,
            now: now
        ))
    }

    private func spentPresentation(
        fetchedSecondsAgo: TimeInterval,
        resetsInSeconds: TimeInterval
    ) -> AccountPresentation {
        let account = account()
        return AccountPresentation(
            account: account,
            snapshot: UsageSnapshot(
                accountID: account.id,
                fetchedAt: now.addingTimeInterval(-fetchedSecondsAgo),
                fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 1, resetsAt: nil),
                weekly: UsageWindow(
                    kind: .weekly,
                    remainingFraction: 0,
                    resetsAt: now.addingTimeInterval(resetsInSeconds)
                )
            ),
            state: .current
        )
    }

    /// The countdown shown has to be the one that actually ends a hold, so the
    /// soonest reset wins — not merely whichever account was listed first.
    func testTheSoonestResetIsTheOneNamed() {
        let later = account(label: "Later")
        let sooner = account(label: "Sooner")
        let banner = WarmUpBannerModel.banner(
            presentations: [
                blockedPresentation(account: later, resetsInSeconds: 20 * 3600),
                blockedPresentation(account: sooner, resetsInSeconds: 2 * 3600)
            ],
            failures: [:],
            schedule: .allowAll,
            now: now
        )
        let message = banner?.message ?? ""
        XCTAssertTrue(message.contains("Sooner"), "the soonest reset is named (\(message))")
        XCTAssertTrue(message.contains("2h"), "and its countdown is the one shown (\(message))")
    }

    private func blockedPresentation(
        account: AccountRecord,
        resetsInSeconds: TimeInterval
    ) -> AccountPresentation {
        AccountPresentation(
            account: account,
            snapshot: UsageSnapshot(
                accountID: account.id,
                fetchedAt: now,
                fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 1, resetsAt: nil),
                weekly: UsageWindow(
                    kind: .weekly,
                    remainingFraction: 0,
                    resetsAt: now.addingTimeInterval(resetsInSeconds)
                )
            ),
            state: .current
        )
    }

    // MARK: Recorded failures

    func testFailureBannerShowsWithinTheWindowItDescribes() {
        let account = account(label: "AI")
        let banner = WarmUpBannerModel.banner(
            presentations: [presentation(account: account, weeklyRemaining: 0.5)],
            failures: [account.id: AutoStartFailure(at: now, kind: .transient)],
            schedule: .allowAll,
            now: now.addingTimeInterval(3600)
        )
        XCTAssertEqual(banner?.severity, .critical)
        XCTAssertTrue(
            banner?.message.contains("AI") == true,
            "the failure banner names its account (\(banner?.message ?? "nil"))"
        )
    }

    /// The core of the reported bug: the banner must stop asserting a failure
    /// once the attempt it describes can no longer be the latest word — one
    /// warm-up window later, the policy has had another chance to fire.
    func testFailureBannerRetractsAfterOneWarmUpWindow() {
        let account = account(label: "AI")
        XCTAssertNil(WarmUpBannerModel.banner(
            presentations: [presentation(account: account, weeklyRemaining: 0.5)],
            failures: [account.id: AutoStartFailure(at: now, kind: .transient)],
            schedule: .allowAll,
            now: now.addingTimeInterval(AutoStartPolicy.minimumInterval)
        ))
    }

    func testFailureBannerDropsAnAccountThatNoLongerExists() {
        XCTAssertNil(WarmUpBannerModel.banner(
            presentations: [],
            failures: [UUID(): AutoStartFailure(at: now, kind: .transient)],
            schedule: .allowAll,
            now: now
        ))
    }

    func testFailureBannerDropsAPausedAccount() {
        let account = account(paused: true)
        XCTAssertNil(WarmUpBannerModel.banner(
            presentations: [presentation(account: account, weeklyRemaining: 0.5)],
            failures: [account.id: AutoStartFailure(at: now, kind: .transient)],
            schedule: .allowAll,
            now: now
        ))
    }

    func testAFailureOutranksABlockedAccount() {
        let failed = account(label: "AI")
        let blocked = account(label: "Ada")
        let banner = WarmUpBannerModel.banner(
            presentations: [
                presentation(account: failed, weeklyRemaining: 0.5),
                presentation(account: blocked, weeklyRemaining: 0)
            ],
            failures: [failed.id: AutoStartFailure(at: now, kind: .transient)],
            schedule: .allowAll,
            now: now
        )
        XCTAssertEqual(banner?.severity, .critical)
        XCTAssertTrue(banner?.message.contains("AI") == true)
    }

    /// One row speaks for the whole group, so it must be the one that asks the
    /// user to DO something. A newer transient failure standing in front of an
    /// account that needs re-authentication hides the only actionable item.
    func testAnAuthFailureOutranksANewerTransientOne() {
        let needsSignIn = account(label: "AI")
        let transient = account(label: "Ada")
        let banner = WarmUpBannerModel.banner(
            presentations: [
                presentation(account: needsSignIn, weeklyRemaining: 0.5),
                presentation(account: transient, weeklyRemaining: 0.5)
            ],
            failures: [
                needsSignIn.id: AutoStartFailure(
                    at: now.addingTimeInterval(-100),
                    kind: .authenticationRequired
                ),
                transient.id: AutoStartFailure(at: now, kind: .transient)
            ],
            schedule: .allowAll,
            now: now
        )
        let message = banner?.message ?? ""
        XCTAssertTrue(message.contains("AI"), "the account needing action is named (\(message))")
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("sign in"),
            "and its required action survives the collapse (\(message))"
        )
        XCTAssertTrue(message.contains("1 more"), "the rest are still counted (\(message))")
    }

    // MARK: Copy

    func testAuthRejectionAsksToSignIn() {
        let account = account(label: "Ada")
        let banner = WarmUpBannerModel.banner(
            presentations: [presentation(account: account, weeklyRemaining: 0.5)],
            failures: [account.id: AutoStartFailure(at: now, kind: .authenticationRequired)],
            schedule: .allowAll,
            now: now
        )
        XCTAssertTrue(
            banner?.message.localizedCaseInsensitiveContains("sign in") == true,
            "an auth rejection should ask the user to sign in (\(banner?.message ?? "nil"))"
        )
    }

    /// Regression: the original bug reported every non-auth failure as "Sign in
    /// again", so a heavy account whose model discovery failed on the 1 MB cap
    /// was told to re-authenticate forever while its session was fine.
    func testTransientFailureDoesNotAskToSignIn() {
        let account = account(label: "Ada")
        let banner = WarmUpBannerModel.banner(
            presentations: [presentation(account: account, weeklyRemaining: 0.5)],
            failures: [account.id: AutoStartFailure(at: now, kind: .transient)],
            schedule: .allowAll,
            now: now
        )
        let message = banner?.message ?? ""
        XCTAssertFalse(
            message.localizedCaseInsensitiveContains("sign in"),
            "a transient failure must not tell the user to sign in (\(message))"
        )
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("retry"),
            "a transient failure retries automatically; the copy should say so (\(message))"
        )
    }

    // MARK: Error classification

    func testOnlyAuthRejectionsClassifyAsAuthenticationRequired() {
        for status in [401, 403] {
            XCTAssertEqual(
                AutoStartFailure.Kind(error: ClaudeMessageSender.SendError.rejected(status: status)),
                .authenticationRequired,
                "a \(status) rejection is an auth failure"
            )
        }
        let transient: [Error] = [
            ClaudeMessageSender.SendError.transport,
            ClaudeMessageSender.SendError.modelNotFound,
            ClaudeMessageSender.SendError.organizationNotFound,
            ClaudeMessageSender.SendError.rejected(status: 429),
            ClaudeMessageSender.SendError.rejected(status: 500)
        ]
        for error in transient {
            XCTAssertEqual(
                AutoStartFailure.Kind(error: error),
                .transient,
                "\(error) is not an auth failure"
            )
        }
    }
}
