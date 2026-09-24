import Combine
import SwiftUI
import XCTest
@testable import Ration

/// Global feature switches (Settings → General → Features): the settings path
/// (default on, lenient decode, persistence), the pure gates, and the view
/// surfaces that read them. AppModel-level behaviour lives beside each
/// feature's own AppModel tests.
@MainActor
final class FeatureSwitchesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Settings path

    func testFreshStoreHasEveryFeatureOn() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettings(fileURL: directory.appending(path: "settings.json"))

        try await store.load()

        XCTAssertEqual(store.features, .allOn)
        XCTAssertEqual(AppSettingsData().features, .allOn)
    }

    func testMissingOrMalformedFeatureKeysDecodeOnWithoutLosingOtherFields() throws {
        let missing = try JSONDecoder().decode(AppSettingsData.self, from: Data(#"{"sortByWeeklyReset":false}"#.utf8))
        XCTAssertEqual(missing.features, .allOn)
        XCTAssertFalse(missing.sortByWeeklyReset)

        let malformed = Data(#"""
            {"featureResetsEnabled":"no","featureSwitchAdviceEnabled":3,
             "featureWarmUpEnabled":null,"featureInUseEnabled":{},"popoverLayout":"focus"}
            """#.utf8)
        let decoded = try JSONDecoder().decode(AppSettingsData.self, from: malformed)
        XCTAssertEqual(decoded.features, .allOn)
        XCTAssertEqual(decoded.popoverLayout, .focus, "one bad switch must not cost the other settings")
    }

    func testStoredOffValuesDecode() throws {
        let json = Data(#"""
            {"featureResetsEnabled":false,"featureSwitchAdviceEnabled":false,
             "featureWarmUpEnabled":false,"featureInUseEnabled":false}
            """#.utf8)
        let decoded = try JSONDecoder().decode(AppSettingsData.self, from: json)
        XCTAssertEqual(decoded.features, FeatureSwitches(resets: false, switchAdvice: false, warmUp: false, inUse: false))
    }

    func testDataRoundTrip() throws {
        var data = AppSettingsData()
        data.featureResetsEnabled = false
        data.featureInUseEnabled = false
        let decoded = try JSONDecoder().decode(AppSettingsData.self, from: try JSONEncoder().encode(data))
        XCTAssertEqual(decoded, data)
        XCTAssertEqual(decoded.features, FeatureSwitches(resets: false, switchAdvice: true, warmUp: true, inUse: false))
    }

    func testEachSwitchPersistsAndReloadsIndependently() async throws {
        for feature in FeatureSwitch.allCases {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileURL = directory.appending(path: "settings.json")
            let store = AppSettings(fileURL: fileURL)
            try await store.load()

            try await store.setFeature(feature, enabled: false)

            for other in FeatureSwitch.allCases {
                XCTAssertEqual(other.isOn(in: store.features), other != feature, "\(feature) → \(other)")
            }
            let restored = AppSettings(fileURL: fileURL)
            try await restored.load()
            XCTAssertEqual(restored.features, store.features, "\(feature)")

            try await restored.setFeature(feature, enabled: true)
            XCTAssertEqual(restored.features, .allOn, "\(feature) back on")
        }
    }

    func testFeaturesPublisherEmitsCurrentThenChanges() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettings(fileURL: directory.appending(path: "settings.json"))
        try await store.load()
        var received: [FeatureSwitches] = []
        let cancellable = store.featuresPublisher.sink { received.append($0) }
        defer { cancellable.cancel() }

        try await store.setFeature(.inUse, enabled: false)

        XCTAssertEqual(received, [.allOn, FeatureSwitches(resets: true, switchAdvice: true, warmUp: true, inUse: false)])
    }

    // MARK: Switch availability

    func testSwitchAdviceNeedsInUse() {
        var features = FeatureSwitches.allOn
        XCTAssertTrue(features.switchAdviceEffective)
        XCTAssertTrue(FeatureSwitch.switchAdvice.isAvailable(in: features))

        features.inUse = false
        XCTAssertFalse(features.switchAdviceEffective)
        XCTAssertFalse(FeatureSwitch.switchAdvice.isAvailable(in: features))
        XCTAssertTrue(FeatureSwitch.switchAdvice.isOn(in: features), "the stored choice is kept")
        for other in FeatureSwitch.allCases where other != .switchAdvice {
            XCTAssertTrue(other.isAvailable(in: features))
        }

        features = .allOn
        features.switchAdvice = false
        XCTAssertFalse(features.switchAdviceEffective)
    }

    func testFeaturesSectionTitleAndCopy() {
        XCTAssertTrue(SettingsSectionTitle.all.contains("Features"))
        XCTAssertEqual(FeatureSwitch.allCases.map(\.title), ["Resets", "Switch suggestions", "Claude warm-up", "In-use detection"])
        for feature in FeatureSwitch.allCases {
            XCTAssertFalse(feature.summary.isEmpty)
            XCTAssertFalse(feature.summary.contains("\n"), "one line")
        }
        XCTAssertEqual(FeatureSwitch.switchAdviceNeedsInUseNote, "Needs in-use detection")
        XCTAssertEqual(FeatureSwitch.warmUpOffNote, "Warm-up is off in General")
    }

    func testFeatureBindingReadsSettingAndWritesThroughCallback() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettings(fileURL: directory.appending(path: "settings.json"))
        try await store.load()
        try await store.setFeature(.warmUp, enabled: false)
        var written: [(FeatureSwitch, Bool)] = []

        let warmUp = GeneralDetailView.featureBinding(.warmUp, settings: store) { written.append(($0, $1)) }
        let resets = GeneralDetailView.featureBinding(.resets, settings: store) { written.append(($0, $1)) }
        XCTAssertFalse(warmUp.wrappedValue)
        XCTAssertTrue(resets.wrappedValue)
        warmUp.wrappedValue = true

        XCTAssertEqual(written.map(\.0), [.warmUp])
        XCTAssertEqual(written.map(\.1), [true])
        XCTAssertFalse(store.featureWarmUpEnabled, "the binding writes only through the callback")
    }

    // MARK: Claude warm-up

    private func claudeAccount(autoStart: Bool = true) -> AccountRecord {
        AccountRecord(
            id: UUID(), provider: .claude, label: "Personal", webProfileID: UUID(),
            displayOrder: 0, createdAt: .distantPast, autoStartFiveHour: autoStart
        )
    }

    private let notStarted = UsageWindow(kind: .fiveHour, remainingFraction: 1, resetsAt: nil)

    func testWarmUpOffSkipsAnOtherwiseFiringAccount() {
        let account = claudeAccount()
        XCTAssertEqual(AutoStartPolicy.decide(account: account, fiveHour: notStarted, now: now), .fire)
        XCTAssertEqual(
            AutoStartPolicy.decide(account: account, fiveHour: notStarted, now: now, warmUpEnabled: false),
            .skip
        )
        XCTAssertFalse(AutoStartPolicy.shouldAutoStart(account: account, fiveHour: notStarted, now: now, warmUpEnabled: false))
        XCTAssertTrue(AutoStartPolicy.shouldAutoStart(account: account, fiveHour: notStarted, now: now, warmUpEnabled: true))
    }

    func testWarmUpOffAlsoSilencesTheWeeklyHold() {
        let spent = UsageWindow(kind: .weekly, remainingFraction: 0, resetsAt: now.addingTimeInterval(3600))
        let account = claudeAccount()
        XCTAssertEqual(
            AutoStartPolicy.decide(account: account, fiveHour: notStarted, weekly: spent, now: now),
            .blockedByWeeklyLimit(resetsAt: spent.resetsAt)
        )
        XCTAssertEqual(
            AutoStartPolicy.decide(account: account, fiveHour: notStarted, weekly: spent, now: now, warmUpEnabled: false),
            .skip
        )
    }

    func testWarmUpBannerRespectsTheSwitch() {
        let account = claudeAccount()
        let presentation = AccountPresentation(
            account: account,
            snapshot: UsageSnapshot(
                accountID: account.id, fetchedAt: now, fiveHour: notStarted,
                weekly: UsageWindow(kind: .weekly, remainingFraction: 0, resetsAt: now.addingTimeInterval(3600))
            ),
            state: .current
        )
        let failures = [account.id: AutoStartFailure(at: now.addingTimeInterval(-60), kind: .authenticationRequired)]

        XCTAssertNotNil(WarmUpBannerModel.banner(presentations: [presentation], failures: failures, schedule: .allowAll, now: now))
        XCTAssertNotNil(WarmUpBannerModel.banner(presentations: [presentation], failures: [:], schedule: .allowAll, now: now))
        XCTAssertNil(WarmUpBannerModel.banner(
            presentations: [presentation], failures: failures, schedule: .allowAll, warmUpEnabled: false, now: now
        ))
        XCTAssertNil(WarmUpBannerModel.banner(
            presentations: [presentation], failures: [:], schedule: .allowAll, warmUpEnabled: false, now: now
        ))
    }

    func testNewAccountDisclosureFollowsTheSwitch() {
        XCTAssertTrue(WarmUpDefaults.newClaudeAccountDisclosure(warmUpEnabled: true).hasPrefix("Warm-up is on"))
        let off = WarmUpDefaults.newClaudeAccountDisclosure(warmUpEnabled: false)
        XCTAssertTrue(off.hasPrefix("Warm-up is off in General"), off)
        XCTAssertFalse(off.contains("Warm-up is on"))
        XCTAssertTrue(OnboardingProviderGuide.guide(for: .claude, warmUpEnabled: false).hint.contains("Warm-up is off in General"))
        XCTAssertTrue(OnboardingProviderGuide.guide(for: .claude, warmUpEnabled: true).hint.contains("Warm-up is on"))
    }

    // MARK: Pin ordering (in-use)

    func testPinSnapshotPinsNothingWhileInUseIsOff() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = UsageHistoryStore(rootDirectory: directory.appending(path: "history"))
        let account = claudeAccount()
        let at = Date()
        for (offset, remaining) in [(-300.0, 0.6), (0.0, 0.5)] {
            history.record(account: account, snapshot: UsageSnapshot(
                accountID: account.id, fetchedAt: at.addingTimeInterval(offset),
                fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: remaining, resetsAt: nil), weekly: nil
            ))
        }
        let pin = AccountPinSnapshot()

        pin.refresh(accounts: [account], history: history, now: at, inUseEnabled: true)
        XCTAssertEqual(pin.orderingPinByProvider, [.claude: account.id], "premise: the account is in use")

        pin.refresh(accounts: [account], history: history, now: at, inUseEnabled: false)
        XCTAssertEqual(pin.orderingPinByProvider, [:])
    }
}
