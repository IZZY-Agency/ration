import XCTest
@testable import Ration

final class ReplyLineDecoderTests: XCTestCase {
    private let decoder = ReplyLineDecoder()
    private func decode(_ text: String) -> ReplyLineDecoder.Result { decoder.decode(Data(text.utf8)) }

    func testDecodesUsagePriceClassAndHour() {
        guard case .reply(let reply) = decode(TokenBurnFixtures.line(webSearches: 2)) else { return XCTFail() }
        XCTAssertEqual(reply.key, ReplyKey(messageID: "msg_1", requestID: "req_1"))
        XCTAssertEqual(reply.priceClass, PriceClass(model: "claude-opus-5-5", speed: "standard", geo: "not_available", tier: "standard", longContext: false))
        XCTAssertEqual(reply.tokens, TokenCounts(input: 10, output: 20, cacheRead: 30, cacheWrite5m: 40, cacheWrite1h: 0, cacheWriteUnsplit: 0))
        XCTAssertEqual(reply.webSearches, 2)
        XCTAssertEqual(reply.timestamp, ISO8601DateFormatter().date(from: "2026-09-29T10:15:00Z")!.addingTimeInterval(0.25))
        XCTAssertEqual(reply.minute, Int64(ISO8601DateFormatter().date(from: "2026-09-29T10:15:00Z")!.timeIntervalSince1970 / 60))
    }

    /// The byte prefilter: a line without the word is skipped undecoded, even
    /// when it is not JSON at all.
    func testLineWithoutTheMarkerIsNotAReplyEvenIfGarbage() {
        XCTAssertEqual(decode("{not json"), .notAReply)
    }

    func testUserRecordMentioningTheWordIsNotAReply() {
        XCTAssertEqual(decode(TokenBurnFixtures.userLine()), .notAReply)
    }

    func testBrokenJSONWithTheMarkerIsMalformed() {
        XCTAssertEqual(decode(#"{"type":"assistant","message":"#), .malformed)
    }

    func testSyntheticPlaceholderIsNotAReply() {
        XCTAssertEqual(decode(TokenBurnFixtures.line(model: "<synthetic>")), .notAReply)
    }

    func testAssistantRecordMissingItsRequestIdIsMalformed() {
        let line = TokenBurnFixtures.line().replacingOccurrences(of: #""requestId":"req_1","#, with: "")
        XCTAssertEqual(decode(line), .malformed)
    }

    func testWhitespaceFormattedRecordStillDecodes() {
        let pretty = try! JSONSerialization.jsonObject(with: Data(TokenBurnFixtures.line().utf8))
        let spaced = String(decoding: try! JSONSerialization.data(withJSONObject: pretty, options: [.prettyPrinted]), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
        guard case .reply = decode(spaced) else { return XCTFail("spec §5.1: no whitespace-dependent matching") }
    }

    func testSplitThatDoesNotAddUpIsUnsplit() {
        guard case .reply(let reply) = decode(TokenBurnFixtures.line(cacheWrite: 40, split5m: 10, split1h: 10)) else { return XCTFail() }
        XCTAssertEqual(reply.tokens.cacheWriteUnsplit, 40)
        XCTAssertEqual(reply.tokens.cacheWrite5m + reply.tokens.cacheWrite1h, 0)
        guard case .reply(let missing) = decode(TokenBurnFixtures.line(split5m: nil, split1h: nil)) else { return XCTFail() }
        XCTAssertEqual(missing.tokens.cacheWriteUnsplit, 40)
    }

    func testTimestampWithoutFractionalSeconds() {
        guard case .reply = decode(TokenBurnFixtures.line(timestamp: "2026-09-29T10:15:00Z")) else { return XCTFail() }
    }

    func testMissingSpeedTierAndRegionBecomeEmpty() {
        guard case .reply(let reply) = decode(TokenBurnFixtures.line(tier: nil, speed: nil, geo: nil)) else { return XCTFail() }
        XCTAssertEqual(reply.priceClass.speed, "")
        XCTAssertEqual(reply.priceClass.tier, "")
        XCTAssertEqual(reply.priceClass.geo, "")
    }

    func testLongContextFlagCountsTheWholePrompt() {
        guard case .reply(let under) = decode(TokenBurnFixtures.line(input: 100_000, cacheRead: 60_000, cacheWrite: 40_000, split5m: 40_000)) else { return XCTFail() }
        XCTAssertFalse(under.priceClass.longContext, "exactly 200K is not over")
        guard case .reply(let over) = decode(TokenBurnFixtures.line(input: 100_001, cacheRead: 60_000, cacheWrite: 40_000, split5m: 40_000)) else { return XCTFail() }
        XCTAssertTrue(over.priceClass.longContext)
    }

    func testNegativeCountIsMalformed() {
        XCTAssertEqual(decode(TokenBurnFixtures.line(output: -1)), .malformed)
    }

    func testKeyHashSeparatesItsParts() {
        XCTAssertEqual(ReplyKey(messageID: "a", requestID: "b").hash64, ReplyKey(messageID: "a", requestID: "b").hash64)
        XCTAssertNotEqual(ReplyKey(messageID: "ab", requestID: "c").hash64, ReplyKey(messageID: "a", requestID: "bc").hash64)
    }

    /// No real reply has 10^12 tokens of anything.
    func testCountsBeyondAnyRealReplyAreMalformed() {
        XCTAssertEqual(decode(TokenBurnFixtures.line(input: 2_000_000_000_000)), .malformed)
        XCTAssertEqual(decode(TokenBurnFixtures.line(webSearches: 2_000_000_000_000)), .malformed)
        // Adding these two used to trap: the bound is checked before any sum.
        XCTAssertEqual(decode(TokenBurnFixtures.line(cacheWrite: 5, split5m: Int.max, split1h: 1)), .malformed)
    }

    /// An assistant record without a message is malformed.
    func testAssistantRecordWithoutMessageIsMalformed() {
        XCTAssertEqual(decode(#"{"type":"assistant","requestId":"r","timestamp":"2026-09-29T10:00:00Z"}"#), .malformed)
    }

    /// A negative split is broken data, not unpriced usage.
    func testNegativeSplitIsMalformed() {
        XCTAssertEqual(decode(TokenBurnFixtures.line(cacheWrite: 40, split5m: -1, split1h: 41)), .malformed)
    }

    /// The key hash cannot be confused by the separator.
    func testKeyHashCannotBeConfusedByTheSeparator() {
        XCTAssertNotEqual(ReplyKey(messageID: "a\nb", requestID: "c").hash64, ReplyKey(messageID: "a", requestID: "b\nc").hash64)
    }
}
