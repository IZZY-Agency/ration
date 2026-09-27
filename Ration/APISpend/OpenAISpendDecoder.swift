import Foundation

/// Pure: OpenAI organization usage/costs pages → reports.
enum OpenAISpendDecoder {
    private struct Page<Result: Decodable>: Decodable {
        struct Bucket: Decodable { let startTime: Int; let results: [Result] }
        let data: [Bucket]
    }

    private struct CostResult: Decodable {
        struct Amount: Decodable { let value: Decimal; let currency: String }
        let amount: Amount
        let lineItem: String?
    }

    private struct CompletionResult: Decodable {
        let model: String?
        let inputUncachedTokens: Int?
        let inputCacheWriteTokens: Int?
        let inputCachedTokens: Int?
        let outputTokens: Int?
    }

    /// Zero-significand numeric tokens (`0E-6176`, `-0.0e+5`) → `0`.
    ///
    /// OpenAI serializes zero amounts as `0E-6176`, an
    /// exponent far outside `Decimal`'s range, and `JSONDecoder` then rejects the
    /// WHOLE page ("not representable in Swift"). Zero is exactly zero at any
    /// exponent, so the rewrite changes no value. Only a token directly after
    /// `:`, `[` or `,` and directly before `,`, `}` or `]` is touched, so text
    /// inside JSON strings (line items) is left alone. A NON-zero out-of-range
    /// exponent is not rewritten and still fails the decode (refuse, don't guess).
    static func normalizingZeroExponents(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("e") || text.contains("E") else { return data }
        let range = NSRange(text.startIndex..., in: text)
        let result = zeroExponentPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "$1 0")
        return Data(result.utf8)
    }

    private static let zeroExponentPattern = try! NSRegularExpression(
        pattern: #"([:\[,]\s*)-?0(?:\.0*)?[eE][+-]?[0-9]+(?=\s*[,}\]])"#
    )

    private static func buckets<R: Decodable>(_ pages: [Data], as: R.Type) throws -> [Page<R>.Bucket] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try pages.flatMap { try decoder.decode(Page<R>.self, from: normalizingZeroExponents($0)).data } } catch {
            throw APISpendError.integrationChanged(.decode)
        }
    }

    static func costReport(pages: [Data], month: UTCMonth, fetchedAt: Date, refreshStartedAt: Date) throws -> APICostReport {
        var byDay: [Date: Decimal] = [:]
        var bucketDays: Set<Date> = []
        var byLine: [String: Decimal] = [:]
        for bucket in try buckets(pages, as: CostResult.self) {
            let start = Date(timeIntervalSince1970: TimeInterval(bucket.startTime))
            guard UTCMonth(containing: start) == month else { continue }
            let day = UTCDay.start(of: start)
            bucketDays.insert(day)
            for result in bucket.results {
                guard result.amount.currency.uppercased() == "USD" else { throw APISpendError.integrationChanged(.currency) }
                let cents = try APIMoney.openAICents(dollars: result.amount.value)
                byDay[day, default: 0] += cents
                byLine[result.lineItem ?? "", default: 0] += cents
            }
        }
        let report = APICostReport(
            month: month, fetchedAt: fetchedAt, refreshStartedAt: refreshStartedAt,
            days: byDay.map { DayCost(dayStart: $0.key, cents: $0.value) }.sorted { $0.dayStart < $1.dayStart },
            byModel: [], otherCharges: [],
            byLineItem: byLine.map { LineItemCost(lineItem: $0.key, cents: $0.value) }.sorted { $0.cents > $1.cents },
            coversToday: bucketDays.contains(UTCDay.start(of: fetchedAt))
        )
        try APIMoney.checkMonthTotal(report.monthToDateCents)
        return report
    }

    static func tokenReport(pages: [Data], month: UTCMonth, fetchedAt: Date, refreshStartedAt: Date) throws -> APITokenReport {
        var rows: [String: [CompletionResult]] = [:]
        for bucket in try buckets(pages, as: CompletionResult.self) {
            guard UTCMonth(containing: Date(timeIntervalSince1970: TimeInterval(bucket.startTime))) == month else { continue }
            for result in bucket.results { rows[result.model ?? "", default: []].append(result) }
        }
        let models = rows.map { model, results in
            ModelTokens(
                model: model,
                input: AnthropicSpendDecoder.strictSum(results.map(\.inputUncachedTokens)),
                cacheWrite: AnthropicSpendDecoder.strictSum(results.map(\.inputCacheWriteTokens)),
                cacheRead: AnthropicSpendDecoder.strictSum(results.map(\.inputCachedTokens)),
                output: AnthropicSpendDecoder.strictSum(results.map(\.outputTokens))
            )
        }.sorted { $0.model < $1.model }
        return APITokenReport(month: month, fetchedAt: fetchedAt, refreshStartedAt: refreshStartedAt, byModel: models, hasPriorityTierUsage: false)
    }
}
