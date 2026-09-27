import Foundation

/// Pure: Anthropic Admin API pages → reports.
enum AnthropicSpendDecoder {
    private struct Page<Result: Decodable>: Decodable {
        struct Bucket: Decodable { let startingAt: Date; let results: [Result] }
        let data: [Bucket]
    }

    private struct CostResult: Decodable {
        let amount: String
        let currency: String
        let description: String?
        let model: String?
    }

    private struct UsageResult: Decodable {
        struct CacheCreation: Decodable {
            let ephemeral5mInputTokens: Int?
            let ephemeral1hInputTokens: Int?
        }
        let model: String?
        let serviceTier: String?
        let uncachedInputTokens: Int?
        let cacheCreation: CacheCreation?
        let cacheReadInputTokens: Int?
        let outputTokens: Int?
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func buckets<R: Decodable>(_ pages: [Data], as: R.Type) throws -> [Page<R>.Bucket] {
        do { return try pages.flatMap { try decoder().decode(Page<R>.self, from: $0).data } } catch {
            throw APISpendError.integrationChanged(.decode)
        }
    }

    static func costReport(pages: [Data], month: UTCMonth, fetchedAt: Date, refreshStartedAt: Date) throws -> APICostReport {
        var byDay: [Date: Decimal] = [:]
        var bucketDays: Set<Date> = []
        var byModel: [String: Decimal] = [:]
        var other: [String: Decimal] = [:]
        for bucket in try buckets(pages, as: CostResult.self) where UTCMonth(containing: bucket.startingAt) == month {
            let day = UTCDay.start(of: bucket.startingAt)
            bucketDays.insert(day)
            for result in bucket.results {
                guard result.currency.uppercased() == "USD" else { throw APISpendError.integrationChanged(.currency) }
                let cents = try APIMoney.anthropicCents(result.amount)
                byDay[day, default: 0] += cents
                if let model = result.model { byModel[model, default: 0] += cents }
                else { other[result.description ?? "", default: 0] += cents }
            }
        }
        let report = APICostReport(
            month: month, fetchedAt: fetchedAt, refreshStartedAt: refreshStartedAt,
            days: byDay.map { DayCost(dayStart: $0.key, cents: $0.value) }.sorted { $0.dayStart < $1.dayStart },
            byModel: byModel.map { ModelCost(model: $0.key, cents: $0.value) }.sorted { $0.cents > $1.cents },
            otherCharges: other.map { DescriptionCost(description: $0.key, cents: $0.value) }.sorted { $0.cents > $1.cents },
            byLineItem: [],
            coversToday: bucketDays.contains(UTCDay.start(of: fetchedAt))
        )
        try APIMoney.checkMonthTotal(report.monthToDateCents)
        return report
    }

    static func tokenReport(pages: [Data], month: UTCMonth, fetchedAt: Date, refreshStartedAt: Date) throws -> APITokenReport {
        var rows: [String: [UsageResult]] = [:]
        var priority = false
        for bucket in try buckets(pages, as: UsageResult.self) where UTCMonth(containing: bucket.startingAt) == month {
            for result in bucket.results {
                rows[result.model ?? "", default: []].append(result)
                if ["priority", "priority_on_demand"].contains(result.serviceTier ?? "") { priority = true }
            }
        }
        let models = rows.map { model, results in
            ModelTokens(
                model: model,
                input: strictSum(results.map(\.uncachedInputTokens)),
                cacheWrite: strictSum(results.map { r in
                    guard let c = r.cacheCreation, let a = c.ephemeral5mInputTokens, let b = c.ephemeral1hInputTokens else { return nil }
                    return checkedAdd(a, b)
                }),
                cacheRead: strictSum(results.map(\.cacheReadInputTokens)),
                output: strictSum(results.map(\.outputTokens))
            )
        }.sorted { $0.model < $1.model }
        return APITokenReport(month: month, fetchedAt: fetchedAt, refreshStartedAt: refreshStartedAt, byModel: models, hasPriorityTierUsage: priority)
    }

    /// nil on overflow: an absurd count reads as unknown ("—"), never a crash.
    static func checkedAdd(_ a: Int, _ b: Int) -> Int? {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? nil : sum
    }

    /// nil when any value is missing — a missing field shows "—", never a partial sum.
    static func strictSum(_ values: [Int?]) -> Int? {
        values.reduce(Optional(0)) { acc, next in
            guard let acc, let next else { return nil }
            return checkedAdd(acc, next)
        }
    }
}
