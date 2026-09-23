import Foundation
import XCTest
@testable import Ration

@MainActor
final class AlertStateStoreTests: XCTestCase {
    func testUnknownAccountReturnsDefaultState() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "alert-state.json")
        let store = AlertStateStore(fileURL: fileURL)

        try await store.load()

        XCTAssertEqual(store.state(for: UUID()), AccountAlertState())
    }

    func testSavingStateRoundTripsThroughFreshStore() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "alert-state.json")
        let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        var state = AccountAlertState()
        state.fiveHour.hasObserved = true
        state.fiveHour.identity = Date(timeIntervalSince1970: 1_000)
        state.fiveHour.notifiedTier = .warning
        // Non-nil `lastRemaining` (the reset-detection baseline) must survive
        // the round trip too — without it, a relaunch would treat the first
        // post-restart poll as a "first observation" and could miss (or
        // spuriously fire) a reset relative to the pre-restart remaining.
        state.fiveHour.lastRemaining = 0.42
        state.weekly.hasObserved = true
        state.weekly.lastRemaining = 0.87
        state.notifiedReauth = true
        let store = AlertStateStore(fileURL: fileURL)

        try await store.load()
        try await store.save(state, for: accountID)

        let restored = AlertStateStore(fileURL: fileURL)
        try await restored.load()

        XCTAssertEqual(restored.state(for: accountID), state)
        XCTAssertEqual(restored.state(for: accountID).fiveHour.lastRemaining, 0.42)
        XCTAssertEqual(restored.state(for: accountID).weekly.lastRemaining, 0.87)
    }

    /// `AccountAlertState.init(from:)` decodes
    /// `resetCredits` entry-by-entry through a type-erased wrapper so one
    /// malformed entry can't cost the others. `JSONFileStore` (which this
    /// store is built on) encodes/decodes with `.iso8601` dates — the
    /// wrapper must re-decode each entry with THAT SAME strategy, or a
    /// perfectly well-formed `lastSeenExpiresAt` silently becomes nil on
    /// every relaunch, breaking the re-grant re-arm across restarts.
    func testResetCreditLastSeenExpiresAtSurvivesRoundTripThroughAlertStateStore() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "alert-state.json")
        let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        var state = AccountAlertState()
        state.resetCredits["c1"] = ResetCreditAlertMemory(
            lastSeenCount: 1,
            availableRow: .active,
            expiryHandled: true,
            expiringRow: .active,
            lastSeenExpiresAt: Date(timeIntervalSince1970: 1_790_500_000)
        )
        let store = AlertStateStore(fileURL: fileURL)

        try await store.load()
        try await store.save(state, for: accountID)

        let restored = AlertStateStore(fileURL: fileURL)
        try await restored.load()

        XCTAssertEqual(restored.state(for: accountID), state)
        XCTAssertEqual(
            restored.state(for: accountID).resetCredits["c1"]?.lastSeenExpiresAt,
            Date(timeIntervalSince1970: 1_790_500_000),
            "the ISO-8601 date must decode with JSONFileStore's own strategy, not a default JSONDecoder"
        )
    }

    func testRemoveDropsStateAndPersistsDeletion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "alert-state.json")
        let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        var state = AccountAlertState()
        state.notifiedRateLimited = true
        let store = AlertStateStore(fileURL: fileURL)

        try await store.load()
        try await store.save(state, for: accountID)
        try await store.remove(accountID: accountID)

        XCTAssertEqual(store.state(for: accountID), AccountAlertState())

        let restored = AlertStateStore(fileURL: fileURL)
        try await restored.load()

        XCTAssertEqual(restored.state(for: accountID), AccountAlertState())
    }

    func testCorruptFileDefaultsToEmptyWithoutThrowing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "alert-state.json")
        let malformedJSON = Data("{ not valid json".utf8)
        try malformedJSON.write(to: fileURL)
        let store = AlertStateStore(fileURL: fileURL)

        // Should not throw
        try await store.load()

        XCTAssertEqual(store.state(for: UUID()), AccountAlertState())
    }

    /// Backward-compatibility for the freed-capacity reset fix:
    /// `WindowAlertMemory.lastRemaining` is a new `Optional` field. This
    /// reproduces exactly the shape a file written by a pre-fix app version
    /// has — same ISO-8601 dates, same encoding `JSONEncoder` actually
    /// produces for a `[UUID: AccountAlertState]` (a flat alternating
    /// `[key, value]` array — UUID does NOT encode as a keyed JSON object
    /// key, confirmed by inspecting real encoder output), just missing the
    /// new key entirely — and confirms Swift's synthesized `Decodable`
    /// conformance falls back to `nil` for the missing key (via
    /// `decodeIfPresent` for `Optional` properties) rather than throwing.
    func testLoadingOldPersistedStateMissingLastRemainingDecodesAsNil() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "alert-state.json")
        let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!

        let oldFormatJSON = """
        [
          "\(accountID.uuidString)",
          {
            "fiveHour": {
              "hasObserved": true,
              "identity": "1970-01-01T00:16:40Z",
              "notifiedTier": 75
            },
            "weekly": {
              "hasObserved": false
            },
            "notifiedReauth": false,
            "notifiedRateLimited": false
          }
        ]
        """
        try Data(oldFormatJSON.utf8).write(to: fileURL)

        let store = AlertStateStore(fileURL: fileURL)
        try await store.load()

        let restored = store.state(for: accountID)
        XCTAssertTrue(restored.fiveHour.hasObserved)
        XCTAssertEqual(restored.fiveHour.identity, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(restored.fiveHour.notifiedTier, .warning)
        XCTAssertNil(
            restored.fiveHour.lastRemaining,
            "old persisted data missing the new key must decode to nil, not throw"
        )
        XCTAssertFalse(restored.weekly.hasObserved)
        XCTAssertNil(restored.weekly.lastRemaining)
    }

    /// Migration proof: `AccountAlertState` gained a `modelWeekly`
    /// slot (Fable). This is a NEW, non-Optional stored property (default
    /// `WindowAlertMemory()`, not `WindowAlertMemory?`), so unlike
    /// `lastRemaining` above, Swift's synthesized `Decodable` conformance
    /// cannot fall back to a per-field default for a missing key — decoding
    /// would throw and the account's entire persisted alert memory (fiveHour/
    /// weekly tiers, notifiedReauth/notifiedRateLimited) would be lost. This
    /// reproduces exactly the shape a pre-Fable persisted file has — no
    /// `modelWeekly` key at all — and confirms the custom `init(from:)`
    /// defaults it instead of throwing.
    func testLegacyAlertStateWithoutModelWeeklyDecodes() throws {
        let legacy = """
        {"fiveHour":{"hasObserved":false},"weekly":{"hasObserved":false},\
        "notifiedReauth":false,"notifiedRateLimited":false}
        """.data(using: .utf8)!

        let st = try JSONDecoder().decode(AccountAlertState.self, from: legacy)

        XCTAssertFalse(st.modelWeekly.hasObserved, "missing modelWeekly key must default, not crash")
        XCTAssertEqual(st.modelWeekly, WindowAlertMemory())
        XCTAssertFalse(st.fiveHour.hasObserved)
        XCTAssertFalse(st.weekly.hasObserved)
        XCTAssertFalse(st.notifiedReauth)
        XCTAssertFalse(st.notifiedRateLimited)
    }

    /// Same migration proof through the actual persistence path (a file on
    /// disk missing the `modelWeekly` key, loaded via `AlertStateStore`),
    /// mirroring `testLoadingOldPersistedStateMissingLastRemainingDecodesAsNil`
    /// above — confirms `load()` doesn't drop the account's state to corrupt-
    /// file-recovery (empty map) when the only "problem" is the new key.
    func testAlertStateStoreLoadsLegacyFileWithoutModelWeekly() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "alert-state.json")
        let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!

        let oldFormatJSON = """
        [
          "\(accountID.uuidString)",
          {
            "fiveHour": {
              "hasObserved": true,
              "identity": "1970-01-01T00:16:40Z",
              "notifiedTier": 90
            },
            "weekly": {
              "hasObserved": false
            },
            "notifiedReauth": false,
            "notifiedRateLimited": false
          }
        ]
        """
        try Data(oldFormatJSON.utf8).write(to: fileURL)

        let store = AlertStateStore(fileURL: fileURL)
        try await store.load()

        let restored = store.state(for: accountID)
        XCTAssertTrue(restored.fiveHour.hasObserved)
        XCTAssertEqual(restored.fiveHour.notifiedTier, .critical)
        XCTAssertFalse(restored.modelWeekly.hasObserved, "no modelWeekly key must default, not throw/drop state")
        XCTAssertEqual(restored.modelWeekly, WindowAlertMemory())
    }

    /// Migration proof: `AccountAlertState` gained a `spend` slot
    /// (Cursor). Same shape of trap as `modelWeekly` above — this is a new,
    /// non-Optional stored property, so a legacy `alerts.json` written before
    /// 0.27.0 (no `"spend"` key anywhere) must still decode, with the rest of
    /// the account's alert memory (tiers, notified flags) intact, and the
    /// whole `states` map must NOT be dropped to empty by `load()`'s
    /// `DecodingError` recovery.
    func testLegacyStateWithoutSpendDecodesWithTiersIntact() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "alerts.json")
        let accountID = UUID()
        // An alerts.json as written by 0.26.x: no "spend" key anywhere.
        // `[UUID: AccountAlertState]` is Foundation's flat alternating-element
        // array encoding for a non-String/Int dictionary key (confirmed
        // against this codebase's `JSONFileStore`/`AlertStateStore`, and
        // matching the array shape already used by
        // `testAlertStateStoreLoadsLegacyFileWithoutModelWeekly` above) — NOT
        // a `{"<uuid>": ...}` object.
        try Data(#"""
        ["\#(accountID.uuidString)",{"fiveHour":{"hasObserved":true,"notifiedTier":90,
         "lastRemaining":0.05},"notifiedReauth":false,"notifiedRateLimited":false}]
        """#.utf8).write(to: fileURL)

        let store = AlertStateStore(fileURL: fileURL)
        try await store.load()

        let state = store.state(for: accountID)
        XCTAssertEqual(state.fiveHour.notifiedTier, .critical)
        XCTAssertTrue(state.fiveHour.hasObserved)
        XCTAssertEqual(state.spend, SpendAlertMemory())
        // The whole map must survive — not be reset to empty.
        XCTAssertEqual(store.states.count, 1)
    }

    /// `SpendAlertMemory` gained `periodStart` (the invoice identity, since
    /// 2026-08-27 `periodEnd` no longer is one). A 0.28.1 file has no such
    /// key; a newer one has it. Both must decode, and a malformed value must
    /// fall back per-field rather than cost the account its watermark.
    func testSpendPeriodStartDecodesAcrossVersions() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "alerts.json")
        let legacy = UUID()
        let current = UUID()
        let malformed = UUID()
        try Data(#"""
        ["\#(legacy.uuidString)",{"spend":{"hasObserved":true,"periodEnd":"2026-08-27T12:36:06Z",
         "notifiedTier":75,"lastSpentCents":0}},
         "\#(current.uuidString)",{"spend":{"hasObserved":true,"periodStart":"2026-08-01T00:00:00Z",
         "periodEnd":"2026-08-27T12:42:08Z","notifiedTier":75,"lastSpentCents":0}},
         "\#(malformed.uuidString)",{"spend":{"hasObserved":true,"periodStart":"not-a-date",
         "notifiedTier":90,"lastSpentCents":0}}]
        """#.utf8).write(to: fileURL)

        let store = AlertStateStore(fileURL: fileURL)
        try await store.load()

        XCTAssertNil(store.state(for: legacy).spend.periodStart)
        XCTAssertEqual(store.state(for: legacy).spend.notifiedTier, .warning)
        XCTAssertEqual(
            store.state(for: current).spend.periodStart,
            ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")
        )
        XCTAssertNil(store.state(for: malformed).spend.periodStart)
        XCTAssertEqual(
            store.state(for: malformed).spend.notifiedTier, .critical,
            "a bad periodStart must not cost the account its watermark"
        )
        XCTAssertEqual(store.states.count, 3)
    }

    /// The `decodeIfPresent` on the `spend` KEY only covers an absent key. A
    /// `spend` object that is present but malformed one level down still
    /// throws, and `AlertStateStore.load()` turns any `DecodingError` into
    /// `states = [:]` — wiping every OTHER account's alert memory too.
    ///
    /// The victim here is account B, which is perfectly well-formed and
    /// carries a critical watermark: if B's memory is lost, B re-fires an
    /// alert it already sent.
    func testMalformedSpendOnOneAccountDoesNotWipeAnotherAccountsMemory() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "alerts.json")
        let corrupt = UUID()
        let healthy = UUID()
        // `hasObserved` is non-Optional and typed Bool; a string there is
        // exactly the "malformed nested field" the type's own doc warns about.
        try Data(#"""
        ["\#(corrupt.uuidString)",{"spend":{"hasObserved":"not-a-bool"}},
         "\#(healthy.uuidString)",{"weekly":{"hasObserved":true,"notifiedTier":90,
         "lastRemaining":0.04},"notifiedReauth":false,"notifiedRateLimited":false}]
        """#.utf8).write(to: fileURL)

        let store = AlertStateStore(fileURL: fileURL)
        try await store.load()

        let survivor = store.state(for: healthy)
        XCTAssertEqual(
            survivor.weekly.notifiedTier, .critical,
            "a malformed spend object on a DIFFERENT account must not cost this one its watermark"
        )
        XCTAssertTrue(survivor.weekly.hasObserved)
        // The malformed field itself falls back rather than propagating.
        XCTAssertEqual(store.state(for: corrupt).spend, SpendAlertMemory())
    }

    /// Same defect, same blast radius, in the sibling type: `WindowAlertMemory`
    /// also has a non-Optional `hasObserved` decoded via the synthesized
    /// `Decodable`, so a malformed window object wipes the whole map too.
    func testMalformedWindowMemoryOnOneAccountDoesNotWipeAnotherAccountsMemory() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "alerts.json")
        let corrupt = UUID()
        let healthy = UUID()
        try Data(#"""
        ["\#(corrupt.uuidString)",{"fiveHour":{"hasObserved":"not-a-bool"}},
         "\#(healthy.uuidString)",{"weekly":{"hasObserved":true,"notifiedTier":90,
         "lastRemaining":0.04},"notifiedReauth":false,"notifiedRateLimited":false}]
        """#.utf8).write(to: fileURL)

        let store = AlertStateStore(fileURL: fileURL)
        try await store.load()

        let survivor = store.state(for: healthy)
        XCTAssertEqual(survivor.weekly.notifiedTier, .critical)
        XCTAssertEqual(store.state(for: corrupt).fiveHour, WindowAlertMemory())
    }

    func testSpendMemoryRoundTrips() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "alerts.json")
        let accountID = UUID()
        let store = AlertStateStore(fileURL: fileURL)
        try await store.load()

        var state = AccountAlertState()
        state.spend.hasObserved = true
        state.spend.notifiedTier = .warning
        state.spend.lastSpentCents = 5_500
        state.spend.periodEnd = Date(timeIntervalSince1970: 1_000)
        try await store.save(state, for: accountID)

        let restored = AlertStateStore(fileURL: fileURL)
        try await restored.load()
        XCTAssertEqual(restored.state(for: accountID).spend.notifiedTier, .warning)
        XCTAssertEqual(restored.state(for: accountID).spend.lastSpentCents, 5_500)
    }

    // MARK: - Attention-drop dismissal memory

    /// A dismissed drop row must STAY dismissed across a relaunch — otherwise
    /// the panel reappears on the next tick and the ✕ means nothing.
    ///
    /// Both memory types decode through a HAND-WRITTEN `init(from:)` (added so
    /// one malformed field cannot wipe every account's watermarks), so a new
    /// property is NOT picked up by synthesized `decodeIfPresent` — it persists
    /// only if it was added to that decoder explicitly.
    func testDismissedTierRoundTripsForWindowsAndSpend() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "alerts.json")
        let accountID = UUID()
        let store = AlertStateStore(fileURL: fileURL)
        try await store.load()

        var state = AccountAlertState()
        state.weekly.dismissedTier = .critical
        state.modelWeekly.dismissedTier = .warning
        state.spend.dismissedTier = .critical
        try await store.save(state, for: accountID)

        let restored = AlertStateStore(fileURL: fileURL)
        try await restored.load()
        let back = restored.state(for: accountID)
        XCTAssertEqual(back.weekly.dismissedTier, .critical)
        XCTAssertEqual(back.modelWeekly.dismissedTier, .warning)
        XCTAssertEqual(back.spend.dismissedTier, .critical)
        XCTAssertNil(back.fiveHour.dismissedTier, "an untouched window must stay undismissed")
    }

    /// A pre-0.28.0 file has no `dismissedTier` key anywhere; it must decode
    /// with the rest of the account's memory intact rather than throwing into
    /// `load()`'s wipe-everything recovery.
    func testLegacyStateWithoutDismissedTierDecodesWithWatermarksIntact() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "alerts.json")
        let accountID = UUID()
        try Data(#"""
        ["\#(accountID.uuidString)",{"weekly":{"hasObserved":true,"notifiedTier":90,
         "lastRemaining":0.05},"notifiedReauth":false,"notifiedRateLimited":false}]
        """#.utf8).write(to: fileURL)

        let store = AlertStateStore(fileURL: fileURL)
        try await store.load()

        let state = store.state(for: accountID)
        XCTAssertEqual(state.weekly.notifiedTier, .critical)
        XCTAssertNil(state.weekly.dismissedTier)
        XCTAssertEqual(store.states.count, 1)
    }
}
