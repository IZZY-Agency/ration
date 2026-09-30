import XCTest
@testable import Ration

/// Real plan-value figures from the live logs and one reading of Claude
/// Code's sign-in, through the app's own scanner, attribution, periods and
/// prices. Read-only, and only when asked:
///
///   TEST_RUNNER_TOKEN_BURN_CORPUS=<home>/.claude/projects
///   TEST_RUNNER_TOKEN_BURN_SIGN_IN=<home>/.claude.json
///   TEST_RUNNER_TOKEN_BURN_FIGURES_OUT=<a JSON path outside the repo>
///
/// The switcher's writes live in the app's container, which this process
/// cannot read: the figures take none since the sign-in's profileFetchedAt,
/// and the output says so. Aggregates only: no path, prompt, reply or id.
final class TokenBurnFiguresProbe: XCTestCase {
    func testFiguresFromTheLiveLogs() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let corpus = env["TOKEN_BURN_CORPUS"], let signInPath = env["TOKEN_BURN_SIGN_IN"],
              let out = env["TOKEN_BURN_FIGURES_OUT"] else {
            throw XCTSkip("runs only with TEST_RUNNER_TOKEN_BURN_CORPUS, _SIGN_IN and _FIGURES_OUT")
        }
        let work = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let scanner = try TokenBurnScanner(databaseURL: work.appending(path: "figures.sqlite"))
        var report = TokenBurnScanner.Report()
        let elapsed = try await ContinuousClock().measure {
            report = try await scanner.scan(root: URL(fileURLWithPath: corpus, isDirectory: true))
        }
        let now = Date()
        let calendar = Calendar.current

        // One reading, as the app takes it; plus the plan fields it shows.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: signInPath))
        let account = try XCTUnwrap(try ClaudeCodeConfig.account(in: bytes))
        let raw = try XCTUnwrap((try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["oauthAccount"] as? [String: Any])
        let identity = SignInIdentity(accountUUID: account.uuid, organizationUUID: account.organizationUUID,
                                      billingType: account.billingType)
        let fetchedAt = account.profileFetchedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        let tier = PlanTier.fromClaude(rateLimitTier: raw["organizationRateLimitTier"] as? String, capabilities: [])
        let price = ClaudePlanPrice.monthlyUSD(tier)
        let subscribed = (raw["subscriptionCreatedAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        let renewalDay = subscribed.map { calendar.component(.day, from: $0) }

        let span = SignInSpan(identity: identity, fetchedAt: fetchedAt, firstSeen: now, lastSeen: now)
        let proven = TokenBurnTimeline.proven(spans: [span], writes: [])
        let accountID = UUID()
        let bindings = TokenBurnBindings(links: [identity.accountUUID: accountID], organizations: [:],
                                         personalPlanAccounts: [], observedIdentities: [identity])
        let rows = try await scanner.minuteTotals(from: .distantPast, to: now.addingTimeInterval(60))
        let owned = rows.map { row in
            (minute: row.minute, total: row.total,
             owner: TokenBurnAttribution.owner(ofMinute: row.minute, proven: proven, resolve: bindings.owner(of:)))
        }

        func minute(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 / 60).rounded(.down)) }
        func rowsIn(_ start: Date, _ end: Date, _ include: (TokenBurnOwner) -> Bool) -> [TokenBurnStore.UsageTotal] {
            owned.filter { $0.minute >= minute(start) && $0.minute < minute(end) && include($0.owner) }.map(\.total)
        }
        func json(_ value: PlanValue) -> [String: Any] {
            ["cents": NSDecimalNumber(decimal: value.cents).doubleValue, "replies": value.replies,
             "pricedTokens": value.pricedTokens, "unpricedTokens": value.unpricedTokens,
             "assumedTokens": value.assumedTokens, "webSearches": value.webSearches, "atLeast": !value.isComplete]
        }
        func tokens(_ totals: [TokenBurnStore.UsageTotal]) -> [String: Int] {
            var t = TokenCounts()
            for total in totals { t += total.tokens }
            return ["input": t.input, "output": t.output, "cacheRead": t.cacheRead, "cacheWrite5m": t.cacheWrite5m,
                    "cacheWrite1h": t.cacheWrite1h, "cacheWriteUnsplit": t.cacheWriteUnsplit]
        }
        func byModel(_ totals: [TokenBurnStore.UsageTotal]) -> [[String: Any]] {
            Dictionary(grouping: totals, by: \.priceClass.model)
                .map { model, group in ["model": model, "value": json(TokenBurnPricing.value(of: group))] }
                .sorted { ($0["model"] as! String) < ($1["model"] as! String) }
        }
        let iso = ISO8601DateFormatter()
        func periods(renewalDay: Int?) -> [[String: Any]] {
            let current = TokenBurnPeriod.current(renewalDay: renewalDay, now: now, calendar: calendar)
            return ([current] + current.previous(count: 3, renewalDay: renewalDay, calendar: calendar)).map { period in
                let end = min(period.end, now.addingTimeInterval(60))
                let mine = rowsIn(period.start, end) { $0 == .account(accountID) }
                let all = rowsIn(period.start, end) { _ in true }
                var pooled: [String: Any] = [:]
                for (name, owner) in [("beforeTracking", TokenBurnOwner.beforeTracking), ("notObserved", .notObserved),
                                      ("unassigned", .unassigned), ("apiKey", .apiKey), ("unclassified", .unclassified)] {
                    let value = TokenBurnPricing.value(of: rowsIn(period.start, end) { $0 == owner })
                    if value.replies > 0 { pooled[name] = json(value) }
                }
                let value = AccountPlanValue(period: period, value: TokenBurnPricing.value(of: mine), planPriceUSD: price)
                return ["kind": period.kind == .cycle ? "cycle" : "month", "start": iso.string(from: period.start),
                        "end": iso.string(from: period.end), "account": json(value.value),
                        "ratio": value.ratio.map { NSDecimalNumber(decimal: $0).doubleValue } as Any,
                        "all": json(TokenBurnPricing.value(of: all)), "pooled": pooled,
                        "accountTokens": tokens(mine), "allTokens": tokens(all),
                        "accountByModel": byModel(mine), "allByModel": byModel(all)]
            }
        }
        let firstDay = calendar.date(byAdding: .day, value: -40, to: calendar.startOfDay(for: now))!
        let days = Dictionary(grouping: owned.filter { $0.minute >= minute(firstDay) }) {
            calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.minute) * 60))
        }
        let dayFormat = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()
        let daily: [[String: Any]] = days.keys.sorted().map { day in
            let group = days[day]!
            return ["day": day.formatted(dayFormat),
                    "all": json(TokenBurnPricing.value(of: group.map(\.total))),
                    "account": json(TokenBurnPricing.value(of: group.filter { $0.owner == .account(accountID) }.map(\.total)))]
        }

        let figures: [String: Any] = [
            "generatedAt": iso.string(from: now), "timeZone": calendar.timeZone.identifier,
            "priceTableDate": "2026-09-29", "planPriceDate": ClaudePlanPrice.date,
            "scan": ["files": report.filesSeen, "unreadable": report.filesUnreadable, "replies": report.repliesCounted,
                     "bytes": report.bytesRead, "seconds": elapsed / .seconds(1)],
            "signIn": ["label": account.organizationName as Any, "planTier": tier.map { "\($0)" } as Any,
                       "planPriceUSD": price.map { NSDecimalNumber(decimal: $0).doubleValue } as Any,
                       "billingType": account.billingType as Any, "renewalDayFromSubscription": renewalDay as Any,
                       "provenFrom": proven.first.map { iso.string(from: $0.start) } as Any,
                       "provenTo": proven.first.map { iso.string(from: $0.end) } as Any,
                       "assumes": "no Ration switch since profileFetchedAt (the switch log is in the app's container)"],
            "monthly": periods(renewalDay: nil),
            "cycles": periods(renewalDay: renewalDay),
            "daily": daily,
        ]
        let data = try JSONSerialization.data(withJSONObject: figures, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: out))
        print("PROBE figures: \(report.filesSeen) files, \(report.repliesCounted) replies in \(elapsed) → \(out)")
    }
}
