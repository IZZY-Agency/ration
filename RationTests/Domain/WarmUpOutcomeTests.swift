import XCTest
@testable import Ration

final class WarmUpOutcomeTests: XCTestCase {
    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    // MARK: Ring

    func testRingKeepsTheNewestFiveOldestFirst() throws {
        var ring: [WarmUpOutcome] = []
        for index in 0..<7 {
            ring = try XCTUnwrap(WarmUpOutcome.recording(.sent(at: at(Double(index)), status: 200), into: ring))
        }
        XCTAssertEqual(WarmUpOutcome.capacity, 5)
        XCTAssertEqual(ring.map(\.at), (2..<7).map { at(Double($0)) })
    }

    func testUnreservedRepeatIsFoldedIntoTheNewestEntry() {
        let first = WarmUpOutcome.skipped(.weeklyLimitSpent, at: at(1), reserved: false)
        let repeatOutcome = WarmUpOutcome.skipped(.weeklyLimitSpent, at: at(2), reserved: false)
        XCTAssertNil(WarmUpOutcome.recording(repeatOutcome, into: [first]))
    }

    func testReservedRepeatIsAlwaysKept() {
        let error = ClaudeMessageSender.SendError.rejected(status: 429)
        let first = WarmUpOutcome.failure(error, at: at(1), reserved: true)
        let second = WarmUpOutcome.failure(error, at: at(2), reserved: true)
        XCTAssertEqual(WarmUpOutcome.recording(second, into: [first]), [first, second])
    }

    func testADifferentUnreservedOutcomeIsAppended() {
        let hold = WarmUpOutcome.skipped(.weeklyLimitSpent, at: at(1), reserved: false)
        let failure = WarmUpOutcome.failure(
            ClaudeMessageSender.SendError.modelNotFound,
            at: at(2),
            reserved: false
        )
        XCTAssertEqual(WarmUpOutcome.recording(failure, into: [hold]), [hold, failure])
    }

    // MARK: Error mapping

    func testFailureMapping() {
        let date = at(1)
        let auth = WarmUpOutcome.failure(ClaudeMessageSender.SendError.rejected(status: 403), at: date, reserved: true)
        XCTAssertEqual(auth.kind, .rejected)
        XCTAssertEqual(auth.httpStatus, 403)
        XCTAssertEqual(auth.errorKind, .authentication)

        let limited = WarmUpOutcome.failure(ClaudeMessageSender.SendError.rejected(status: 429), at: date, reserved: true)
        XCTAssertEqual(limited.kind, .rejected)
        XCTAssertEqual(limited.errorKind, .http)

        let cases: [(Error, WarmUpOutcome.ErrorKind)] = [
            (ClaudeMessageSender.SendError.transport, .transport),
            (ClaudeMessageSender.SendError.organizationNotFound, .organizationNotFound),
            (ClaudeMessageSender.SendError.modelNotFound, .modelNotFound),
            (WebUsageClientError.timedOut, .timedOut),
            (WebUsageClientError.invalidResponse, .other),
        ]
        for (error, kind) in cases {
            let outcome = WarmUpOutcome.failure(error, at: date, reserved: false)
            XCTAssertEqual(outcome.kind, .failed, "\(error)")
            XCTAssertEqual(outcome.errorKind, kind, "\(error)")
            XCTAssertNil(outcome.httpStatus, "\(error)")
        }
    }

    // MARK: Privacy

    func testStreamErrorTypesMapOntoTheClosedDocumentedSet() {
        typealias Kind = WarmUpOutcome.StreamErrorKind
        XCTAssertEqual(Kind.recognising("rate_limit_error"), .rateLimit)
        XCTAssertEqual(Kind.recognising("overloaded_error"), .overloaded)
        XCTAssertEqual(Kind.recognising("permission_error"), .permission)
        XCTAssertEqual(Kind.recognising("authentication_error"), .authentication)
        XCTAssertEqual(Kind.recognising("invalid_request_error"), .invalidRequest)
        XCTAssertEqual(Kind.recognising("api_error"), .api)
        XCTAssertEqual(Kind.recognising("not_found_error"), .notFound)
        XCTAssertEqual(Kind.recognising("request_too_large"), .requestTooLarge)
        XCTAssertEqual(Kind.recognising("billing_error"), .billing)
        XCTAssertEqual(Kind.recognising("timeout_error"), .timeout)
        XCTAssertNil(Kind.recognising(nil))
        // Anything else — a plausible identifier, an id, a word of content,
        // free text — is `unknown`: no provider string is ever kept.
        for raw in [
            "quota_exceeded_error", "org_2f9c1a7e", "123e4567-e89b-12d3-a456-426614174000",
            "Tuesday", "sk-ant-abc", "You have used up your limit", "", "RATE_LIMIT_ERROR",
        ] {
            XCTAssertEqual(Kind.recognising(raw), .unknown, raw)
        }
    }

    func testAStoredUnrecognisedStreamTypeDecodesAsUnknown() throws {
        let json = #"{"at":"1970-01-01T00:16:40Z","kind":"rejectedInStream","streamErrorType":"org_2f9c1a7e","reserved":true}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let outcome = try decoder.decode(WarmUpOutcome.self, from: Data(json.utf8))
        XCTAssertEqual(outcome.streamErrorType, .unknown)
        let reencoded = String(decoding: try JSONEncoder().encode(outcome), as: UTF8.self)
        XCTAssertFalse(reencoded.contains("org_2f9c1a7e"))
    }

    func testEncodedOutcomeCarriesOnlyStatusesAndKinds() throws {
        let outcome = WarmUpOutcome.rejectedInStream(at: at(1), status: 200, type: .rateLimit)
        let data = try JSONEncoder().encode(outcome)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["at", "kind", "httpStatus", "errorKind", "streamErrorType", "reserved"]
        )
    }

    // MARK: Decoding compatibility

    private let legacyAccountJSON = """
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "provider": "claude",
      "label": "Work",
      "webProfileID": "00000000-0000-0000-0000-000000000002",
      "displayOrder": 0,
      "createdAt": "1970-01-01T00:16:40Z",
      "autoStartFiveHour": true,
      "lastAutoStartedAt": "1970-01-01T00:16:40Z"
      %@
    }
    """

    private func decodeAccount(extra: String) throws -> AccountRecord {
        let json = legacyAccountJSON.replacingOccurrences(of: "%@", with: extra)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AccountRecord.self, from: Data(json.utf8))
    }

    func testAnOldAccountsFileWithoutOutcomesStillDecodes() throws {
        let account = try decodeAccount(extra: "")
        XCTAssertEqual(account.warmUpOutcomes, [])
        XCTAssertTrue(account.autoStartFiveHour)
        XCTAssertEqual(account.lastAutoStartedAt, at(1_000))
    }

    func testAnUnreadableOutcomeIsDroppedNotTheAccount() throws {
        let extra = """
        , "warmUpOutcomes": [
          { "at": "1970-01-01T00:16:40Z", "kind": "fromTheFuture", "reserved": true },
          { "at": "1970-01-01T00:16:41Z", "kind": "rejected", "httpStatus": 429,
            "errorKind": "http", "reserved": true },
          { "at": "1970-01-01T00:16:42Z", "kind": "failed", "errorKind": "newKind" }
        ]
        """
        let account = try decodeAccount(extra: extra)
        XCTAssertEqual(account.warmUpOutcomes.count, 2)
        XCTAssertEqual(account.warmUpOutcomes.first?.httpStatus, 429)
        // An unknown error kind degrades to nil; a missing `reserved` to false.
        XCTAssertEqual(account.warmUpOutcomes.last?.kind, .failed)
        XCTAssertNil(account.warmUpOutcomes.last?.errorKind)
        XCTAssertEqual(account.warmUpOutcomes.last?.reserved, false)
    }

    func testAMalformedOutcomesValueLeavesTheAccountIntact() throws {
        let account = try decodeAccount(extra: #", "warmUpOutcomes": "nope""#)
        XCTAssertEqual(account.warmUpOutcomes, [])
        XCTAssertEqual(account.label, "Work")
    }

    func testOutcomesRoundTripThroughTheAccountRecord() throws {
        var account = try decodeAccount(extra: "")
        account.warmUpOutcomes = [
            .sent(at: at(1_000), status: 200),
            .skipped(.weeklyLimitSpent, at: at(2_000), reserved: false),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AccountRecord.self, from: try encoder.encode(account))
        XCTAssertEqual(decoded, account)
    }
}
