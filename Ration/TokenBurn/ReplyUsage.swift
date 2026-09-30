import CryptoKit
import Foundation

/// What decides a reply's list price besides its token counts. Empty strings
/// stand for fields older Claude Code logs do not write.
struct PriceClass: Hashable, Sendable {
    let model: String
    let speed: String
    let geo: String
    let tier: String
    /// Prompt (input + cache read + cache write) over 200K tokens.
    let longContext: Bool
}

struct TokenCounts: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    /// Cache writes whose 5-minute/1-hour split was missing or did not add up:
    /// never priced (spec §5.3).
    var cacheWriteUnsplit = 0

    var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h + cacheWriteUnsplit }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheRead += rhs.cacheRead
        lhs.cacheWrite5m += rhs.cacheWrite5m
        lhs.cacheWrite1h += rhs.cacheWrite1h
        lhs.cacheWriteUnsplit += rhs.cacheWriteUnsplit
    }
}

/// A reply's identity: Claude Code writes one record per content block, all
/// with the same pair (spec §2).
struct ReplyKey: Hashable, Sendable {
    let messageID: String
    let requestID: String

    /// The only form the store keeps. The first id is length-prefixed, so no
    /// two pairs can share an input.
    var hash64: Int64 {
        let digest = SHA256.hash(data: Data("\(messageID.utf8.count):\(messageID)\(requestID)".utf8))
        return digest.withUnsafeBytes { Int64(bitPattern: $0.loadUnaligned(as: UInt64.self)) }
    }
}

struct ReplyUsage: Equatable, Sendable {
    let key: ReplyKey
    let timestamp: Date
    let priceClass: PriceClass
    let tokens: TokenCounts
    let webSearches: Int

    /// Minutes since 1970, UTC (spec §10: a switch is placed to the minute).
    var minute: Int64 { Int64((timestamp.timeIntervalSince1970 / 60).rounded(.down)) }
}

/// Turns one complete log line into reply usage, reading nothing else of it
/// (spec §5.1). Not thread-safe: one per scanner.
struct ReplyLineDecoder {
    enum Result: Equatable, Sendable {
        case reply(ReplyUsage)
        case notAReply
        /// A complete line that should have been a reply and could not be read.
        case malformed
    }

    /// No real reply has 10^12 tokens of anything; a bigger count is broken
    /// data, and the bound keeps every sum far from overflow.
    static let maxCount = 1_000_000_000_000

    private let json = JSONDecoder()
    private let marker = Data("assistant".utf8)
    private let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private let withoutFraction = Date.ISO8601FormatStyle()

    func decode(_ line: Data) -> Result {
        guard line.range(of: marker) != nil else { return .notAReply }
        guard let record = try? json.decode(Record.self, from: line) else { return .malformed }
        guard record.type == "assistant" else { return .notAReply }
        guard let message = record.message else { return .malformed }
        guard message.model != "<synthetic>" else { return .notAReply }
        guard let id = message.id, let request = record.requestId, let model = message.model,
              let usage = message.usage, let stamp = record.timestamp,
              let timestamp = (try? withFraction.parse(stamp)) ?? (try? withoutFraction.parse(stamp))
        else { return .malformed }
        let counts = [usage.input, usage.output, usage.cacheRead, usage.cacheWrite, usage.split?.m5, usage.split?.h1, usage.tools?.webSearches]
        guard counts.allSatisfy({ $0.map { (0...Self.maxCount).contains($0) } ?? true }) else { return .malformed }
        let write = usage.cacheWrite ?? 0
        var tokens = TokenCounts(input: usage.input ?? 0, output: usage.output ?? 0, cacheRead: usage.cacheRead ?? 0)
        if let m5 = usage.split?.m5, let h1 = usage.split?.h1, m5 + h1 == write {
            tokens.cacheWrite5m = m5
            tokens.cacheWrite1h = h1
        } else {
            tokens.cacheWriteUnsplit = write
        }
        let searches = usage.tools?.webSearches ?? 0
        let prompt = tokens.input + tokens.cacheRead + write
        let priceClass = PriceClass(model: model, speed: usage.speed ?? "", geo: usage.geo ?? "", tier: usage.tier ?? "",
                                    longContext: prompt > ClaudePriceTable.longContextThreshold)
        return .reply(ReplyUsage(key: ReplyKey(messageID: id, requestID: request), timestamp: timestamp,
                                 priceClass: priceClass, tokens: tokens, webSearches: searches))
    }

    private struct Record: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let message: Message?
    }

    private struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    private struct Usage: Decodable {
        let input: Int?
        let output: Int?
        let cacheRead: Int?
        let cacheWrite: Int?
        let split: Split?
        let tier: String?
        let speed: String?
        let geo: String?
        let tools: Tools?

        enum CodingKeys: String, CodingKey {
            case input = "input_tokens", output = "output_tokens", cacheRead = "cache_read_input_tokens"
            case cacheWrite = "cache_creation_input_tokens", split = "cache_creation", tier = "service_tier"
            case speed, geo = "inference_geo", tools = "server_tool_use"
        }
    }

    private struct Split: Decodable {
        let m5: Int?
        let h1: Int?
        enum CodingKeys: String, CodingKey { case m5 = "ephemeral_5m_input_tokens", h1 = "ephemeral_1h_input_tokens" }
    }

    private struct Tools: Decodable {
        let webSearches: Int?
        enum CodingKeys: String, CodingKey { case webSearches = "web_search_requests" }
    }
}
