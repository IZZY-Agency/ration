import Foundation

/// Where a minute of usage goes (spec §5.2, §10.1).
enum TokenBurnOwner: Hashable, Sendable {
    case account(UUID)
    /// Before the first proven time.
    case beforeTracking
    /// Between proven times, or a minute that straddles a boundary.
    case notObserved
    /// A subscription sign-in that binds to no single Ration account.
    case unassigned
    /// `billingType` `usage_based`: billed to an API key.
    case apiKey
    /// A `billingType` Ration does not know, or none.
    case unclassified
}

/// The time each sign-in is proven (spec §10.1). Pure.
enum TokenBurnTimeline {
    struct Proven: Equatable, Sendable {
        let identity: SignInIdentity
        let start: Date
        let end: Date
    }

    /// A span proves its identity from the later of its `profileFetchedAt`
    /// (a login or a profile refresh wrote it) and Ration's latest write at
    /// or before its first reading, to its last reading. Nothing between spans
    /// is inferred. A start never reaches back over the previous span.
    static func proven(spans: [SignInSpan], writes: [Date]) -> [Proven] {
        let writes = writes.sorted()
        var result: [Proven] = []
        for span in spans {
            var start = span.fetchedAt.map { min($0, span.firstSeen) } ?? span.firstSeen
            if let write = writes.last(where: { $0 <= span.firstSeen }) { start = max(start, write) }
            if let previous = result.last { start = max(start, previous.end) }
            guard start <= span.lastSeen else { continue }
            result.append(Proven(identity: span.identity, start: start, end: span.lastSeen))
        }
        return result
    }
}

enum TokenBurnAttribution {
    /// A minute `[m·60, m·60 + 60)` belongs to an identity only when it lies
    /// wholly inside one of its proven intervals.
    static func owner(ofMinute minute: Int64, proven: [TokenBurnTimeline.Proven],
                      resolve: (SignInIdentity) -> TokenBurnOwner) -> TokenBurnOwner {
        let start = Date(timeIntervalSince1970: TimeInterval(minute) * 60)
        let end = start.addingTimeInterval(60)
        if let interval = proven.first(where: { $0.start <= start && end <= $0.end }) {
            return resolve(interval.identity)
        }
        guard let first = proven.map(\.start).min(), end > first else { return .beforeTracking }
        return .notObserved
    }

    /// Minute rows (ascending) summed per owner. Each identity is resolved once.
    static func totals(minutes: [(minute: Int64, total: TokenBurnStore.UsageTotal)], proven: [TokenBurnTimeline.Proven],
                       resolve: (SignInIdentity) -> TokenBurnOwner) -> [TokenBurnOwner: [TokenBurnStore.UsageTotal]] {
        var resolved: [SignInIdentity: TokenBurnOwner] = [:]
        func cachedResolve(_ identity: SignInIdentity) -> TokenBurnOwner {
            if let owner = resolved[identity] { return owner }
            let owner = resolve(identity)
            resolved[identity] = owner
            return owner
        }
        var result: [TokenBurnOwner: [TokenBurnStore.UsageTotal]] = [:]
        for row in minutes {
            result[owner(ofMinute: row.minute, proven: proven, resolve: cachedResolve), default: []].append(row.total)
        }
        return result
    }
}

/// Which Ration account a sign-in is (spec §10.1).
struct TokenBurnBindings: Sendable {
    /// Claude Code's own subscription billing types (2.1.285, `UA`).
    static let subscriptionBillingTypes: Set<String> = [
        "stripe_subscription", "stripe_subscription_contracted", "stripe_subscription_enterprise_self_serve",
        "aws_marketplace", "c4e_consumption_trial", "apple_subscription", "google_play_subscription",
    ]
    static let apiBillingType = "usage_based"

    /// The switcher's links: Claude account uuid → Ration account.
    let links: [String: UUID]
    /// The organization Ration last resolved per Ration Claude account.
    let organizations: [UUID: String]
    /// Accounts whose personal plan (Pro, Max 5x, Max 20x) Ration detected
    /// from their organization's own rate-limit tier: one seat.
    let personalPlanAccounts: Set<UUID>
    /// Every sign-in token burn has read.
    let observedIdentities: [SignInIdentity]

    func owner(of identity: SignInIdentity) -> TokenBurnOwner {
        guard let billing = identity.billingType, billing != Self.apiBillingType else {
            return identity.billingType == Self.apiBillingType ? .apiKey : .unclassified
        }
        guard Self.subscriptionBillingTypes.contains(billing) else { return .unclassified }
        if let linked = links[identity.accountUUID] { return .account(linked) }
        guard let organization = identity.organizationUUID else { return .unassigned }
        let accounts = organizations.filter { $0.value == organization }.map(\.key)
        let otherSeats = observedIdentities.contains { $0.organizationUUID == organization && $0.accountUUID != identity.accountUUID }
        guard accounts.count == 1, let account = accounts.first, personalPlanAccounts.contains(account), !otherSeats else {
            return .unassigned
        }
        return .account(account)
    }
}
