import Foundation

enum UsageWindowKind: String, Codable, CaseIterable, Sendable {
    case fiveHour
    case weekly
    case modelWeekly
}

extension UsageWindowKind {
    /// The window's name as VoiceOver should say it — the drawn "5H" / "WK"
    /// are read letter by letter. `label` is the API's model name and only
    /// matters for `.modelWeekly` ("Fable" → "Fable weekly").
    func spokenName(label: String? = nil, locale: Locale = .current) -> String {
        let resource: LocalizedStringResource = switch self {
        case .fiveHour: .windowSpokenFiveHour
        case .weekly: .windowSpokenWeekly
        case .modelWeekly: .windowSpokenModel(label ?? "Fable")
        }
        return resource.string(in: locale)
    }
}

struct UsageWindow: Codable, Equatable, Sendable {
    let kind: UsageWindowKind
    let remainingFraction: Double
    let resetsAt: Date?
    let label: String?

    init(kind: UsageWindowKind, remainingFraction: Double, resetsAt: Date?, label: String? = nil) {
        self.kind = kind
        self.remainingFraction = min(max(remainingFraction, 0), 1)
        self.resetsAt = resetsAt
        self.label = label
    }

    // Backward-compatible decode: older persisted windows have no `label`.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(UsageWindowKind.self, forKey: .kind)
        remainingFraction = min(max(try c.decode(Double.self, forKey: .remainingFraction), 0), 1)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }

    var usedFraction: Double {
        1 - remainingFraction
    }
}

enum UsageColorTier: Equatable, Sendable {
    case blue
    case orange
    case red

    init(usedFraction: Double) {
        if usedFraction >= 0.75 {
            self = .red
        } else if usedFraction >= 0.50 {
            self = .orange
        } else {
            self = .blue
        }
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    let accountID: UUID
    let fetchedAt: Date
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    let modelWeekly: UsageWindow?
    let cursorSpend: CursorSpend?
    let resetCredits: ResetCredits?
    /// The claude.ai organization this snapshot's data came from — carried
    /// IN MEMORY ONLY so the auto-start send is structurally bound to the
    /// exact snapshot that triggered it (no shared mutable binding to
    /// overwrite or collide). Deliberately absent from `CodingKeys`: the org
    /// id is never persisted to disk (privacy stance in
    /// docs/provider-contracts/claude.md), so it decodes as nil and is
    /// dropped on encode.
    let organizationID: String?
    /// The provider's plan field as read by this fetch — IN MEMORY
    /// ONLY; the durable home of the plan is `AccountRecord.plan`. nil = the
    /// plan field was not read this fetch.
    let planDetection: PlanDetection?

    enum CodingKeys: String, CodingKey {
        case accountID, fetchedAt, fiveHour, weekly, modelWeekly, cursorSpend, resetCredits
    }

    init(
        accountID: UUID,
        fetchedAt: Date,
        fiveHour: UsageWindow?,
        weekly: UsageWindow?,
        modelWeekly: UsageWindow? = nil,
        cursorSpend: CursorSpend? = nil,
        organizationID: String? = nil,
        resetCredits: ResetCredits? = nil,
        planDetection: PlanDetection? = nil
    ) {
        self.accountID = accountID
        self.fetchedAt = fetchedAt
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.modelWeekly = modelWeekly
        self.cursorSpend = cursorSpend
        self.organizationID = organizationID
        self.resetCredits = resetCredits
        self.planDetection = planDetection
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try c.decode(UUID.self, forKey: .accountID)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        fiveHour = try c.decodeIfPresent(UsageWindow.self, forKey: .fiveHour)
        weekly = try c.decodeIfPresent(UsageWindow.self, forKey: .weekly)
        modelWeekly = try c.decodeIfPresent(UsageWindow.self, forKey: .modelWeekly)
        cursorSpend = try c.decodeIfPresent(CursorSpend.self, forKey: .cursorSpend)
        // Lossy: a malformed list must never cost the account its snapshot.
        resetCredits = try? c.decodeIfPresent(ResetCredits.self, forKey: .resetCredits)
        organizationID = nil
        planDetection = nil
    }

    func window(for kind: UsageWindowKind) -> UsageWindow? {
        switch kind {
        case .fiveHour: fiveHour
        case .weekly: weekly
        case .modelWeekly: modelWeekly
        }
    }

    /// Every window this snapshot actually carries, in `UsageWindowKind`
    /// declaration order. The single canonical iteration point for history
    /// ingestion, alert evaluation, and reset summaries — hand-listing slots at
    /// each of those call sites let a new kind be silently skipped by one
    /// subsystem while the others handled it.
    var allWindows: [(kind: UsageWindowKind, window: UsageWindow)] {
        UsageWindowKind.allCases.compactMap { kind in
            window(for: kind).map { (kind, $0) }
        }
    }

    /// Same snapshot, different reset list — the store's carry-forward uses it.
    func replacingResetCredits(_ credits: ResetCredits?) -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID,
            fetchedAt: fetchedAt,
            fiveHour: fiveHour,
            weekly: weekly,
            modelWeekly: modelWeekly,
            cursorSpend: cursorSpend,
            organizationID: organizationID,
            resetCredits: credits,
            planDetection: planDetection
        )
    }
}

enum ProviderError: Error, Equatable, Sendable {
    case authenticationRequired
    case rateLimited(retryAt: Date?)
    case server(statusCode: Int)
    case integrationChanged
    case offline
    case transport
}

extension ProviderError: LocalizedError {
    var errorDescription: String? { message(locale: .current) }

    /// The user-facing message in `locale`'s language. Logs use the case
    /// (`"\(error)"`), never this text.
    func message(locale: Locale) -> String {
        let resource: LocalizedStringResource = switch self {
        case .authenticationRequired: .providerErrorAuthenticationRequired
        case .rateLimited: .providerErrorRateLimited
        case .server: .providerErrorServer
        case .integrationChanged: .providerErrorIntegrationChanged
        case .offline: .providerErrorOffline
        case .transport: .providerErrorTransport
        }
        return resource.string(in: locale)
    }
}

enum AccountViewState: Equatable, Sendable {
    case loading
    case current
    case stale(lastError: ProviderError)
    case reauthenticationRequired
    case rateLimited(retryAt: Date?)
    case integrationChanged
    case unavailable
}

struct AccountPresentation: Identifiable, Equatable, Sendable {
    let account: AccountRecord
    let snapshot: UsageSnapshot?
    let state: AccountViewState

    var id: UUID { account.id }
}
