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
    /// Claude usage credits, from their own background read (never from the
    /// usage fetch itself). nil = never read; carried forward by the store.
    let usageCredits: UsageCredits?
    /// Whether claude.ai spends usage credits once a plan limit is hit (its
    /// "Turn on usage credits" switch), read by the usage fetch. nil = not
    /// read this fetch; carried forward by the store.
    let usageCreditsEnabled: Bool?
    /// ChatGPT Codex credits, read by the usage fetch. nil = not read this
    /// fetch; carried forward by the store.
    let codexCredits: CodexCredits?
    /// TypeSafe's billing cycle. nil = not read this fetch; carried forward.
    let typeSafeSpend: TypeSafeSpend?
    /// TypeSafe's per-day usage. nil = not read this fetch; carried forward.
    let typeSafeDailyUsage: TypeSafeDailyUsage?

    enum CodingKeys: String, CodingKey {
        case accountID, fetchedAt, fiveHour, weekly, modelWeekly, cursorSpend, resetCredits
        case usageCredits, usageCreditsEnabled, codexCredits, typeSafeSpend, typeSafeDailyUsage
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
        planDetection: PlanDetection? = nil,
        usageCredits: UsageCredits? = nil,
        usageCreditsEnabled: Bool? = nil,
        codexCredits: CodexCredits? = nil,
        typeSafeSpend: TypeSafeSpend? = nil,
        typeSafeDailyUsage: TypeSafeDailyUsage? = nil
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
        self.usageCredits = usageCredits
        self.usageCreditsEnabled = usageCreditsEnabled
        self.codexCredits = codexCredits
        self.typeSafeSpend = typeSafeSpend
        self.typeSafeDailyUsage = typeSafeDailyUsage
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
        // Lossy like `resetCredits`: a malformed value costs only itself.
        usageCredits = (try? c.decodeIfPresent(UsageCredits.self, forKey: .usageCredits)) ?? nil
        usageCreditsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .usageCreditsEnabled)) ?? nil
        codexCredits = (try? c.decodeIfPresent(CodexCredits.self, forKey: .codexCredits)) ?? nil
        typeSafeSpend = (try? c.decodeIfPresent(TypeSafeSpend.self, forKey: .typeSafeSpend)) ?? nil
        typeSafeDailyUsage = (try? c.decodeIfPresent(TypeSafeDailyUsage.self, forKey: .typeSafeDailyUsage)) ?? nil
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

    /// The usage-credits reading was applied THIS SESSION for this snapshot's
    /// own organization. Only then may anything warn about its expiry; a
    /// reading restored from disk or carried across a workspace switch shows
    /// its balance and nothing more.
    /// Also true for a reading this snapshot's OWN fetch made in this session
    /// (TypeSafe reads its balance with the usage fetch): a carried one keeps
    /// its older `fetchedAt`, and one restored from disk is not
    /// `readThisSession`.
    var usageCreditsVerified: Bool {
        guard let credits = usageCredits else { return false }
        if credits.readThisSession, credits.fetchedAt == fetchedAt { return true }
        guard let readFor = credits.organizationID else { return false }
        return readFor == organizationID
    }

    /// Same snapshot, different reset list — the store's carry-forward uses it.
    func replacingResetCredits(_ credits: ResetCredits?) -> UsageSnapshot {
        replacing(resetCredits: credits, usageCredits: usageCredits, usageCreditsEnabled: usageCreditsEnabled, codexCredits: codexCredits, typeSafeSpend: typeSafeSpend)
    }

    /// Same snapshot, different usage-credits reading.
    func replacingUsageCredits(_ credits: UsageCredits?) -> UsageSnapshot {
        replacing(resetCredits: resetCredits, usageCredits: credits, usageCreditsEnabled: usageCreditsEnabled, codexCredits: codexCredits, typeSafeSpend: typeSafeSpend)
    }

    /// Same snapshot, different usage-credits switch state.
    func replacingUsageCreditsEnabled(_ enabled: Bool?) -> UsageSnapshot {
        replacing(resetCredits: resetCredits, usageCredits: usageCredits, usageCreditsEnabled: enabled, codexCredits: codexCredits, typeSafeSpend: typeSafeSpend)
    }

    /// Same snapshot, different TypeSafe spend reading.
    func replacingTypeSafeSpend(_ spend: TypeSafeSpend?) -> UsageSnapshot {
        replacing(resetCredits: resetCredits, usageCredits: usageCredits, usageCreditsEnabled: usageCreditsEnabled, codexCredits: codexCredits, typeSafeSpend: spend)
    }

    /// Same snapshot, different Codex credits reading.
    func replacingCodexCredits(_ credits: CodexCredits?) -> UsageSnapshot {
        replacing(resetCredits: resetCredits, usageCredits: usageCredits, usageCreditsEnabled: usageCreditsEnabled, codexCredits: credits, typeSafeSpend: typeSafeSpend)
    }

    /// The one rebuild every `replacing…` goes through, so a new field is
    /// added in one place and none of them can drop it.
    private func replacing(
        resetCredits: ResetCredits?,
        usageCredits: UsageCredits?,
        usageCreditsEnabled: Bool?,
        codexCredits: CodexCredits?,
        typeSafeSpend: TypeSafeSpend?,
        typeSafeDailyUsage: TypeSafeDailyUsage? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID,
            fetchedAt: fetchedAt,
            fiveHour: fiveHour,
            weekly: weekly,
            modelWeekly: modelWeekly,
            cursorSpend: cursorSpend,
            organizationID: organizationID,
            resetCredits: resetCredits,
            planDetection: planDetection,
            usageCredits: usageCredits,
            usageCreditsEnabled: usageCreditsEnabled,
            codexCredits: codexCredits,
            typeSafeSpend: typeSafeSpend,
            typeSafeDailyUsage: typeSafeDailyUsage ?? self.typeSafeDailyUsage
        )
    }

    /// Same snapshot, different TypeSafe daily usage.
    func replacingTypeSafeDailyUsage(_ usage: TypeSafeDailyUsage?) -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID, fetchedAt: fetchedAt, fiveHour: fiveHour, weekly: weekly,
            modelWeekly: modelWeekly, cursorSpend: cursorSpend, organizationID: organizationID,
            resetCredits: resetCredits, planDetection: planDetection, usageCredits: usageCredits,
            usageCreditsEnabled: usageCreditsEnabled, codexCredits: codexCredits,
            typeSafeSpend: typeSafeSpend, typeSafeDailyUsage: usage
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
