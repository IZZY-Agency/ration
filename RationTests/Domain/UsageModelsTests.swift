import XCTest
@testable import Ration

final class UsageModelsTests: XCTestCase {
    /// The org id rides the snapshot IN MEMORY ONLY (it binds the auto-start
    /// send to the snapshot that triggered it) and must never reach disk —
    /// the privacy stance in docs/provider-contracts/claude.md.
    func testSnapshotOrganizationIDIsNeverPersisted() throws {
        let snapshot = UsageSnapshot(
            accountID: UUID(),
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.5, resetsAt: nil),
            weekly: nil,
            organizationID: "20553b43-bbde-4a26-95e3-b385724ddcd4"
        )

        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("20553b43"), "the org id must not be encoded")

        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertNil(decoded.organizationID)
        XCTAssertEqual(decoded.accountID, snapshot.accountID)
        XCTAssertEqual(decoded.fiveHour, snapshot.fiveHour)

        // The decode side must hold on its own: JSON that explicitly smuggles
        // an organizationID key is ignored, not adopted.
        let smuggled = """
        {"accountID":"\(snapshot.accountID.uuidString)",
         "fetchedAt":-978306200,
         "organizationID":"20553b43-bbde-4a26-95e3-b385724ddcd4"}
        """.data(using: .utf8)!
        let decodedSmuggled = try JSONDecoder().decode(UsageSnapshot.self, from: smuggled)
        XCTAssertNil(decodedSmuggled.organizationID)
    }

    func testUsageWindowCanRepresentAnUnscheduledReset() {
        let window = UsageWindow(
            kind: .fiveHour,
            remainingFraction: 0.95,
            resetsAt: nil
        )

        XCTAssertNil(window.resetsAt)
        XCTAssertEqual(window.usedFraction, 0.05, accuracy: 0.0001)
    }

    func testRemainingFractionClampsToClosedUnitRange() {
        XCTAssertEqual(
            UsageWindow(
                kind: .fiveHour,
                remainingFraction: 1.4,
                resetsAt: .distantFuture
            ).remainingFraction,
            1
        )
        XCTAssertEqual(
            UsageWindow(
                kind: .weekly,
                remainingFraction: -0.2,
                resetsAt: .distantFuture
            ).remainingFraction,
            0
        )
    }

    func testUnavailableWindowIsRepresentedByNil() {
        let snapshot = UsageSnapshot(
            accountID: UUID(),
            fetchedAt: .now,
            fiveHour: nil,
            weekly: nil
        )

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.weekly)
    }

    func testUsedFractionIsDerivedFromStoredRemainingFraction() {
        let window = UsageWindow(
            kind: .fiveHour,
            remainingFraction: 0.2,
            resetsAt: .distantFuture
        )

        XCTAssertEqual(window.usedFraction, 0.8, accuracy: 0.0001)
    }

    func testUsageColorTierUsesRequestedUsedThresholds() {
        XCTAssertEqual(UsageColorTier(usedFraction: 0.49), .blue)
        XCTAssertEqual(UsageColorTier(usedFraction: 0.50), .orange)
        XCTAssertEqual(UsageColorTier(usedFraction: 0.749), .orange)
        XCTAssertEqual(UsageColorTier(usedFraction: 0.75), .red)
    }

    func testChatGPTWeeklyOnlyLayoutOmitsFiveHourWindow() {
        let snapshot = UsageSnapshot(
            accountID: UUID(),
            fetchedAt: Date(timeIntervalSince1970: 1_783_927_591),
            fiveHour: nil,
            weekly: UsageWindow(
                kind: .weekly,
                remainingFraction: 0.28,
                resetsAt: Date(timeIntervalSince1970: 1_784_487_780)
            )
        )

        XCTAssertEqual(
            AccountLimitLayout.kinds(for: .chatGPT, snapshot: snapshot),
            [.weekly]
        )
    }

    func testUsedPercentageFormatterUsesWholePercentUnits() {
        let formatted = UsageFormatters.usedPercentage(
            0.42,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(formatted, "42%")
    }

    func testRelativeResetFormatterUsesInjectedCurrentDate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let formatted = UsageFormatters.relativeReset(
            Date(timeIntervalSince1970: 4_600),
            relativeTo: now,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(formatted, "in 1 hour")
    }

    func testCompactResetIncludesRelativeAndExactLocalTime() {
        let now = Date(timeIntervalSince1970: 1_000)
        let resetDate = Date(timeIntervalSince1970: 4_600)
        let locale = Locale(identifier: "en_US")
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = "\(UsageFormatters.relativeReset(resetDate, relativeTo: now, locale: locale)) · \(UsageFormatters.exactReset(resetDate, locale: locale, timeZone: timeZone))"

        XCTAssertEqual(
            UsageFormatters.compactReset(
                resetDate,
                relativeTo: now,
                locale: locale,
                timeZone: timeZone
            ),
            expected
        )
    }

    func testModelWeeklyIsACase() {
        XCTAssertTrue(UsageWindowKind.allCases.contains(.modelWeekly))
        XCTAssertEqual(UsageWindowKind.modelWeekly.rawValue, "modelWeekly")
    }

    func testWindowForKindAccessor() {
        let five = UsageWindow(kind: .fiveHour, remainingFraction: 0.9, resetsAt: nil)
        let wk = UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: nil)
        let model = UsageWindow(kind: .modelWeekly, remainingFraction: 0.54, resetsAt: nil, label: "Fable")
        let snap = UsageSnapshot(accountID: UUID(), fetchedAt: Date(timeIntervalSince1970: 0),
                                 fiveHour: five, weekly: wk, modelWeekly: model)
        XCTAssertEqual(snap.window(for: .fiveHour), five)
        XCTAssertEqual(snap.window(for: .weekly), wk)
        XCTAssertEqual(snap.window(for: .modelWeekly), model)
        XCTAssertEqual(snap.window(for: .modelWeekly)?.label, "Fable")
    }

    func testWindowCarriesOptionalLabel() {
        let w = UsageWindow(kind: .modelWeekly, remainingFraction: 0.5, resetsAt: nil, label: "Fable")
        XCTAssertEqual(w.label, "Fable")
        let plain = UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: nil)
        XCTAssertNil(plain.label)
    }

    func testLegacySnapshotDecodesWithoutModelWeekly() throws {
        // Old snapshots persisted before modelWeekly existed must still decode.
        let legacy = """
        {"accountID":"00000000-0000-0000-0000-000000000001","fetchedAt":0,\
        "fiveHour":null,"weekly":{"kind":"weekly","remainingFraction":0.5,"resetsAt":null}}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(UsageSnapshot.self, from: legacy)
        XCTAssertNil(snap.modelWeekly)
        XCTAssertEqual(snap.weekly?.remainingFraction, 0.5)
    }

    func testEncodeDecodeRoundTripsPopulatedModelWeekly() throws {
        let model = UsageWindow(kind: .modelWeekly, remainingFraction: 0.54, resetsAt: Date(timeIntervalSince1970: 1000), label: "Fable")
        let snap = UsageSnapshot(accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
                                 fetchedAt: Date(timeIntervalSince1970: 0),
                                 fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.9, resetsAt: nil),
                                 weekly: UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: nil),
                                 modelWeekly: model)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(decoded, snap)
        XCTAssertEqual(decoded.modelWeekly?.label, "Fable")
    }

    // MARK: allWindows canonical collection

    func testAllWindowsCoversEveryKindInDeclarationOrder() {
        func w(_ kind: UsageWindowKind) -> UsageWindow {
            UsageWindow(kind: kind, remainingFraction: 0.5, resetsAt: nil)
        }
        let full = UsageSnapshot(
            accountID: UUID(), fetchedAt: Date(timeIntervalSince1970: 0),
            fiveHour: w(.fiveHour), weekly: w(.weekly), modelWeekly: w(.modelWeekly))
        // Exhaustiveness: adding a fourth kind without a slot fails this.
        XCTAssertEqual(full.allWindows.map(\.kind), UsageWindowKind.allCases)
    }

    func testAllWindowsSkipsAbsentWindowsAndPreservesOrder() {
        func w(_ kind: UsageWindowKind) -> UsageWindow {
            UsageWindow(kind: kind, remainingFraction: 0.5, resetsAt: nil)
        }
        let sparse = UsageSnapshot(
            accountID: UUID(), fetchedAt: Date(timeIntervalSince1970: 0),
            fiveHour: nil, weekly: w(.weekly), modelWeekly: w(.modelWeekly))
        XCTAssertEqual(sparse.allWindows.map(\.kind), [.weekly, .modelWeekly])

        let empty = UsageSnapshot(
            accountID: UUID(), fetchedAt: Date(timeIntervalSince1970: 0),
            fiveHour: nil, weekly: nil, modelWeekly: nil)
        XCTAssertTrue(empty.allWindows.isEmpty)
    }
}
