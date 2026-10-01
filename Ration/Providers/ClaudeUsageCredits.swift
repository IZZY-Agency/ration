import Foundation
import WebKit

/// Claude usage credits: the balance that pays for Claude once a plan limit is
/// hit, read from claude.ai's own settings call
/// `GET /api/organizations/{org}/prepaid/credits` (verified live 2026-09-30;
/// see docs/provider-contracts/claude.md). Read only, in the background,
/// after a usage fetch.
extension ClaudeProviderAdapter {
    static func usageCreditsPath(organizationID: String) -> String {
        "/api/organizations/\(organizationID)/prepaid/credits"
    }

    /// nil = no reading (the store keeps the previous one). Timeouts and
    /// cancellation propagate so the caller's recovery can yield the web view;
    /// every other failure is "no reading", never an error the account shows.
    func fetchUsageCredits(
        for snapshot: UsageSnapshot,
        in webView: WKWebView
    ) async throws -> UsageCredits? {
        guard let organizationID = snapshot.organizationID else { return nil }
        let envelope: WebResponseEnvelope
        do {
            envelope = try await client.fetch(
                path: Self.usageCreditsPath(organizationID: organizationID),
                expectedOrigin: Provider.claude.webOrigin,
                in: webView
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WebUsageClientError where error == .timedOut {
            throw error
        } catch {
            return nil
        }
        guard (200..<300).contains(envelope.status) else { return nil }
        return Self.usageCredits(fromBody: envelope.body, fetchedAt: now())
    }

    /// The balance and its grants. nil unless `balance.money` is a valid
    /// amount. A grant that cannot be read is skipped and marks the reading
    /// incomplete; one with nothing left is dropped as well-formed.
    static func usageCredits(fromBody body: String, fetchedAt: Date) -> UsageCredits? {
        guard
            let payload = try? JSONDecoder().decode(ClaudePrepaidCreditsPayload.self, from: Data(body.utf8)),
            let balance = payload.balance?.money?.money
        else { return nil }
        var complete = payload.promoTranches.isRead && payload.tranches.isRead
        var grants: [UsageCreditGrant] = []
        let lists: [(ClaudeTrancheList, UsageCreditGrant.Kind)] = [
            (payload.promoTranches, .promotional),
            (payload.tranches, .purchased),
        ]
        for (list, kind) in lists {
            for element in list.elements {
                guard
                    let tranche = element,
                    let id = tranche.id, !id.isEmpty,
                    let remaining = tranche.remaining?.money?.money,
                    remaining.currency == balance.currency,
                    remaining.exponent == balance.exponent
                else {
                    complete = false
                    continue
                }
                let expiresAt: Date?
                if let raw = tranche.expiresAt {
                    guard let parsed = parseISO8601(raw) else {
                        complete = false
                        continue
                    }
                    expiresAt = parsed
                } else {
                    expiresAt = nil
                }
                guard remaining.minorUnits > 0 else { continue }
                // Unknown rather than invented when missing or in another unit.
                let granted = tranche.granted?.money?.money
                grants.append(UsageCreditGrant(
                    id: id,
                    kind: kind,
                    remaining: remaining,
                    granted: granted.flatMap { $0.currency == remaining.currency && $0.exponent == remaining.exponent ? $0 : nil },
                    expiresAt: expiresAt
                ))
            }
        }
        grants.sort { lhs, rhs in
            switch (lhs.expiresAt, rhs.expiresAt) {
            case let (l?, r?) where l != r: l < r
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.id < rhs.id
            }
        }
        return UsageCredits(fetchedAt: fetchedAt, balance: balance, grants: grants, complete: complete)
    }

    /// claude.ai's "Turn on usage credits to keep using Claude if you hit a
    /// plan limit" switch, from the usage payload: `spend.enabled`, else the
    /// older `extra_usage.is_enabled`, else unknown.
    static func usageCreditsEnabled(from payload: ClaudeUsagePayload) -> Bool? {
        payload.spend?.enabled ?? payload.extraUsage?.isEnabled
    }

    static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: value)
    }
}

/// `prepaid/credits`. Every level is lenient: a changed shape anywhere is a
/// missing reading or a skipped grant, never a thrown decode.
struct ClaudePrepaidCreditsPayload: Decodable, Sendable {
    let balance: ClaudeBalancePayload?
    let promoTranches: ClaudeTrancheList
    let tranches: ClaudeTrancheList

    enum CodingKeys: String, CodingKey {
        case balance
        case promoTranches = "promo_tranches"
        case tranches
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        balance = (try? c.decodeIfPresent(ClaudeBalancePayload.self, forKey: .balance)) ?? nil
        promoTranches = ClaudeTrancheList(c, forKey: .promoTranches)
        tranches = ClaudeTrancheList(c, forKey: .tranches)
    }
}

/// A tranche list: missing or `null` is an empty list that was read; any other
/// shape is unread (`isRead == false`), which marks the reading incomplete.
struct ClaudeTrancheList: Sendable {
    let elements: [ClaudeTranchePayload?]
    let isRead: Bool

    init(_ c: KeyedDecodingContainer<ClaudePrepaidCreditsPayload.CodingKeys>, forKey key: ClaudePrepaidCreditsPayload.CodingKeys) {
        if !c.contains(key) || ((try? c.decodeNil(forKey: key)) ?? false) {
            elements = []
            isRead = true
        } else if let wrapped = try? c.decode([FailableTranche].self, forKey: key) {
            elements = wrapped.map(\.value)
            isRead = true
        } else {
            elements = []
            isRead = false
        }
    }
}

private struct FailableTranche: Decodable {
    let value: ClaudeTranchePayload?
    init(from decoder: any Decoder) throws { value = try? ClaudeTranchePayload(from: decoder) }
}

struct ClaudeTranchePayload: Decodable, Sendable {
    let id: String?
    let remaining: ClaudeBalancePayload?
    let granted: ClaudeBalancePayload?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, remaining, granted
        case expiresAt = "expires_at"
    }
}

/// `{"money": {"amount_minor": 1000, "currency": "EUR", "exponent": 2}, "credits": null}`
struct ClaudeBalancePayload: Decodable, Sendable {
    let money: ClaudeMoneyPayload?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        money = (try? c.decodeIfPresent(ClaudeMoneyPayload.self, forKey: .money)) ?? nil
    }

    enum CodingKeys: String, CodingKey { case money }
}

struct ClaudeMoneyPayload: Decodable, Sendable {
    let amountMinor: Int64
    let currency: String
    let exponent: Int

    enum CodingKeys: String, CodingKey {
        case amountMinor = "amount_minor"
        case currency, exponent
    }

    var money: Money? { Money(minorUnits: amountMinor, currency: currency, exponent: exponent) }
}

/// Usage payload `spend` (newer shape): only the switch is read.
struct ClaudeSpendPayload: Decodable, Sendable {
    let enabled: Bool?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil
    }

    enum CodingKeys: String, CodingKey { case enabled }
}

/// Usage payload `extra_usage` (older shape): only the switch is read.
struct ClaudeExtraUsagePayload: Decodable, Sendable {
    let isEnabled: Bool?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? nil
    }

    enum CodingKeys: String, CodingKey { case isEnabled = "is_enabled" }
}
