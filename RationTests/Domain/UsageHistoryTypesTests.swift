import XCTest
@testable import Ration

final class UsageHistoryTypesTests: XCTestCase {
    func testEnvelopeRoundTripsWithISO8601AndSortedKeys() throws {
        let bucket = UsageHourlyBucket(
            hourStart: Date(timeIntervalSince1970: 3600),
            tzOffsetSeconds: 7200,
            consumed: 0.25,
            minRemaining: 0.5,
            sampleCount: 3
        )
        let envelope = UsageHistoryEnvelope(data: [bucket])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(UsageHistoryEnvelope<[UsageHourlyBucket]>.self, from: data)

        XCTAssertEqual(restored.version, 1)
        XCTAssertEqual(restored.data, [bucket])
    }

    func testRetentionCapsAndSpacingPerKind() {
        XCTAssertEqual(UsageHistoryRetention.rawCap(for: .fiveHour), 144)
        XCTAssertEqual(UsageHistoryRetention.rawCap(for: .weekly), 700)
        XCTAssertEqual(UsageHistoryRetention.minSpacing(for: .fiveHour), 0)
        XCTAssertEqual(UsageHistoryRetention.minSpacing(for: .weekly), 15 * 60)
    }
}
