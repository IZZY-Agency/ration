import Foundation

/// Why an account is not up to date — the one classification the popover
/// header's hover card, its click target and the Settings banner share.
///
/// Derived, never stored: an account that recovers stops having a cause on
/// the next render, so nothing has to be cleared.
enum AttentionCause: Equatable, Sendable {
    /// The provider signed the account out.
    case signInExpired
    /// The provider changed its page; the app needs an update.
    case integrationChanged
    /// The provider's page does not load (`.transport`), or never loaded
    /// (`.unavailable`, `lastError` nil — its cause was collapsed). A sign-in
    /// is one possible reason, not the diagnosis.
    case pageNotLoading(lastError: ProviderError?)
    /// The provider keeps answering with server errors — usually on their
    /// side, and temporary.
    case serverErrors
    /// The app could not reach the provider: the last fetch failed offline,
    /// or the header says OFFLINE and this account is one of the accounts it
    /// counts. `lastError` is the fetch's error, nil when there was none
    /// (the app was not looking, e.g. asleep).
    case connection(lastError: ProviderError?)
    /// No error of its own: the app has not been able to look (asleep) and
    /// the last snapshot aged out.
    case agedOut
    /// The provider asked the app to slow down; it retries by itself.
    case rateLimited(retryAt: Date?)

    /// Lower is more actionable: a sign-in the user can fix beats a waiting
    /// rate limit the user cannot.
    var priority: Int {
        switch self {
        case .signInExpired: 0
        case .integrationChanged: 1
        case .pageNotLoading: 2
        case .serverErrors: 3
        case .connection: 4
        case .agedOut: 5
        case .rateLimited: 6
        }
    }

    /// nil = nothing to fix: the account is paused, current, or still on its
    /// first fetch. Uses the header's own rule (`HeaderFreshness`), so the
    /// header, the hover card and the banner never disagree about which
    /// accounts have a problem.
    ///
    /// `headerOffline`: the header reads OFFLINE for the accounts this one is
    /// shown with. Every account OFFLINE counts is then a `.connection`
    /// problem whatever its last error, so the banner never contradicts the
    /// header's "check your internet connection" with sign-in advice.
    static func classify(
        _ presentation: AccountPresentation,
        now: Date,
        headerOffline: Bool = false
    ) -> AttentionCause? {
        guard !presentation.account.isPaused else { return nil }
        guard HeaderFreshness.needsAttention(presentation, now: now) else { return nil }
        if headerOffline, HeaderFreshness.isAgedOut(presentation, now: now) {
            return .connection(lastError: presentation.state.lastError)
        }
        switch presentation.state {
        case .reauthenticationRequired:
            return .signInExpired
        case .integrationChanged:
            return .integrationChanged
        case let .rateLimited(retryAt):
            return .rateLimited(retryAt: retryAt)
        case .unavailable:
            return .pageNotLoading(lastError: nil)
        case let .stale(lastError):
            switch lastError {
            case .authenticationRequired: return .signInExpired
            case .integrationChanged: return .integrationChanged
            case let .rateLimited(retryAt): return .rateLimited(retryAt: retryAt)
            case .transport: return .pageNotLoading(lastError: .transport)
            case .server: return .serverErrors
            case .offline: return .connection(lastError: .offline)
            }
        case .loading, .current:
            return .agedOut
        }
    }

    /// Whether the header reads OFFLINE for `presentations`.
    static func headerIsOffline(_ presentations: [AccountPresentation], now: Date) -> Bool {
        HeaderFreshness.make(presentations: presentations, now: now) == .offline
    }

    /// The problem accounts, most actionable first; ties keep the order they
    /// were given in (the account display order).
    static func ranked(
        _ presentations: [AccountPresentation],
        now: Date
    ) -> [(presentation: AccountPresentation, cause: AttentionCause)] {
        let offline: Bool = headerIsOffline(presentations, now: now)
        var problems: [(index: Int, presentation: AccountPresentation, cause: AttentionCause)] = []
        for (index, presentation) in presentations.enumerated() {
            guard let cause = classify(presentation, now: now, headerOffline: offline) else { continue }
            problems.append((index, presentation, cause))
        }
        problems.sort { lhs, rhs in
            if lhs.cause.priority != rhs.cause.priority {
                return lhs.cause.priority < rhs.cause.priority
            }
            return lhs.index < rhs.index
        }
        return problems.map { (presentation: $0.presentation, cause: $0.cause) }
    }

    /// Lowercase, a few words: the hover card's line.
    func shortText(locale: Locale = .current) -> String {
        let resource: LocalizedStringResource
        switch self {
        case .signInExpired: resource = .attentionCauseSignIn
        case .integrationChanged: resource = .attentionCausePageChanged
        case .pageNotLoading: resource = .attentionCausePageNotLoaded
        case .serverErrors: resource = .attentionCauseServerErrors
        case .connection: resource = .attentionCauseOffline
        case .agedOut: resource = .attentionCauseAgedOut
        case .rateLimited: resource = .attentionCauseRateLimited
        }
        return resource.string(in: locale)
    }

    /// The banner's "last error": what the provider (or the network) last
    /// reported. nil when nothing was reported — the app was not looking.
    func reportedErrorText(locale: Locale = .current) -> String? {
        let resource: LocalizedStringResource
        switch self {
        case .agedOut, .connection(lastError: nil):
            return nil
        case let .connection(lastError?):
            resource = Self.errorResource(lastError)
        case .signInExpired, .integrationChanged, .pageNotLoading, .serverErrors, .rateLimited:
            return shortText(locale: locale)
        }
        return resource.string(in: locale)
    }

    private static func errorResource(_ error: ProviderError) -> LocalizedStringResource {
        switch error {
        case .authenticationRequired: .attentionCauseSignIn
        case .rateLimited: .attentionCauseRateLimited
        case .server: .attentionCauseServerErrors
        case .integrationChanged: .attentionCausePageChanged
        case .offline: .attentionCauseOffline
        case .transport: .attentionCausePageNotLoaded
        }
    }
}

extension AccountViewState {
    /// The last fetch's error, for the states that carry one.
    var lastError: ProviderError? {
        guard case let .stale(error) = self else { return nil }
        return error
    }
}

/// The amber "Needs attention" banner at the top of an account's Settings
/// page: what is wrong, what to do, and the buttons that do it.
struct AttentionGuidance: Equatable, Sendable {
    enum Action: Hashable, Sendable {
        /// `AccountDetailView.onReauthenticate`.
        case signInAgain
        /// `AppModel.refreshAll(reason: .manual)`.
        case refreshNow
        /// Opens `AppLinks.releases`.
        case checkForUpdates
        /// Opens `AppLinks.issues`.
        case reportIssue

        func title(locale: Locale = .current) -> String {
            let resource: LocalizedStringResource
            switch self {
            case .signInAgain: resource = LocalizedStringResource("Sign in again")
            case .refreshNow: resource = .attentionActionRefreshNow
            case .checkForUpdates: resource = .attentionActionCheckForUpdates
            case .reportIssue: resource = .attentionActionReportIt
            }
            return resource.string(in: locale)
        }

        /// The page a link action opens; nil for in-app actions.
        var url: URL? {
            switch self {
            case .signInAgain, .refreshNow: nil
            case .checkForUpdates: AppLinks.releases
            case .reportIssue: AppLinks.issues
            }
        }
    }

    /// One numbered step; `link`, when set, is a button drawn after it.
    struct Step: Equatable, Sendable {
        let text: String
        var link: Action? = nil
    }

    let cause: AttentionCause
    /// "Needs attention" — the banner's caption and its VoiceOver name.
    let label: String
    let title: String
    let body: String
    /// Numbered, in order. Empty for causes with one obvious fix.
    let steps: [Step]
    /// The first is the primary (gold) button.
    let actions: [Action]
    /// "Last successful update 14:12 · last error: page didn't load"; nil
    /// when neither part is known.
    let meta: String?

    /// nil while the account has no problem — the banner hides by itself
    /// once the account is healthy again.
    ///
    /// `among`: the accounts the header judges with this one (the popover's
    /// list), so an account the header counts as OFFLINE gets connection
    /// guidance. Empty = this account alone.
    static func make(
        presentation: AccountPresentation,
        among presentations: [AccountPresentation] = [],
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> AttentionGuidance? {
        let offline: Bool = AttentionCause.headerIsOffline(presentations, now: now)
        guard let cause = AttentionCause.classify(presentation, now: now, headerOffline: offline) else { return nil }
        let provider: String = presentation.account.provider.displayName
        let lastSuccess: Date? = presentation.snapshot?.fetchedAt
        // Every cause but a never-loaded page has a snapshot (an account
        // with none is judged only when it failed), so the age is known.
        let age: String = AttentionCopy.longAge(since: lastSuccess ?? now, now: now, locale: locale)

        let title: LocalizedStringResource
        let body: String
        var steps: [Step] = []
        let actions: [Action]
        switch cause {
        case .signInExpired:
            title = .attentionTitleCantRefresh
            body = LocalizedStringResource.attentionBodySignIn.string(in: locale)
            actions = [.signInAgain]
        case .pageNotLoading:
            title = .attentionTitleCantRefresh
            if lastSuccess != nil {
                body = LocalizedStringResource.attentionBodyPageNotLoading(provider, age).string(in: locale)
            } else {
                body = LocalizedStringResource.attentionBodyPageNotLoadingNoAge(provider).string(in: locale)
            }
            steps = [
                Step(text: LocalizedStringResource.attentionStepRefresh.string(in: locale)),
                Step(text: LocalizedStringResource.attentionStepSignInMaybe(provider).string(in: locale)),
                Step(text: LocalizedStringResource.attentionStepCheckHost(presentation.account.provider.appHost).string(in: locale)),
            ]
            actions = [.refreshNow, .signInAgain]
        case .serverErrors:
            title = .attentionTitleCantRefresh
            body = LocalizedStringResource.attentionBodyServer(provider, age).string(in: locale)
            steps = [
                Step(text: LocalizedStringResource.attentionStepRefresh.string(in: locale)),
                Step(text: LocalizedStringResource.attentionStepReportIfPersists.string(in: locale), link: .reportIssue),
            ]
            actions = [.refreshNow]
        case .connection:
            title = .attentionTitleCantRefresh
            body = LocalizedStringResource.attentionBodyConnection(provider, age).string(in: locale)
            actions = [.refreshNow]
        case .agedOut:
            title = .attentionTitleCantRefresh
            body = LocalizedStringResource.attentionBodyAgedOut(age).string(in: locale)
            actions = [.refreshNow]
        case let .rateLimited(retryAt):
            title = .attentionTitleWaiting
            if let retryAt {
                let when: String = AttentionCopy.clock(retryAt, now: now, locale: locale, timeZone: timeZone)
                body = LocalizedStringResource.attentionBodyRateLimited(provider, when).string(in: locale)
            } else {
                body = LocalizedStringResource.attentionBodyRateLimitedNoTime(provider).string(in: locale)
            }
            actions = []
        case .integrationChanged:
            title = .attentionTitleCantRead
            body = LocalizedStringResource.attentionBodyIntegrationChanged(provider).string(in: locale)
            actions = [.checkForUpdates, .reportIssue]
        }

        return AttentionGuidance(
            cause: cause,
            label: LocalizedStringResource.attentionBannerLabel.string(in: locale),
            title: title.string(in: locale),
            body: body,
            steps: steps,
            actions: actions,
            meta: meta(cause: cause, lastSuccess: lastSuccess, now: now, locale: locale, timeZone: timeZone)
        )
    }

    private static func meta(
        cause: AttentionCause,
        lastSuccess: Date?,
        now: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> String? {
        var parts: [String] = []
        if let lastSuccess {
            let when: String = AttentionCopy.clock(lastSuccess, now: now, locale: locale, timeZone: timeZone)
            parts.append(LocalizedStringResource.attentionMetaLastSuccess(when).string(in: locale))
        }
        if let error = cause.reportedErrorText(locale: locale) {
            let resource: LocalizedStringResource = parts.isEmpty
                ? .attentionMetaLastErrorAlone(error)
                : .attentionMetaLastError(error)
            parts.append(resource.string(in: locale))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// The account the header's click should open: the most actionable
    /// problem account, ties in display order. nil when none has a problem.
    static func mostActionable(_ presentations: [AccountPresentation], now: Date) -> AccountPresentation? {
        AttentionCause.ranked(AccountVisibility.visible(presentations), now: now).first?.presentation
    }
}

/// The popover header's hover card for STALE and OFFLINE, and where a click
/// on the status word goes.
struct FreshnessHelp: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        /// STALE: open Settings on this account.
        case account(UUID)
        /// OFFLINE: refresh every account.
        case refreshAll
    }

    let title: String
    /// One per problem account (at most `maxAccountLines`), then "and N more".
    let lines: [String]
    let hint: String
    let target: Target

    static let maxAccountLines = 4

    /// Everything the card says, for VoiceOver (the card itself is visual).
    var spokenText: String {
        ([title] + lines + [hint]).joined(separator: "\n")
    }

    /// nil while the header is LIVE (or shows nothing): no card, no click.
    static func make(
        presentations: [AccountPresentation],
        now: Date,
        locale: Locale = .current
    ) -> FreshnessHelp? {
        guard let freshness = HeaderFreshness.make(presentations: presentations, now: now) else { return nil }
        switch freshness {
        case .live:
            return nil
        case .offline:
            return FreshnessHelp(
                title: LocalizedStringResource.freshnessHelpOffline.string(in: locale),
                lines: [],
                hint: LocalizedStringResource.freshnessHelpHintOffline.string(in: locale),
                target: .refreshAll
            )
        case .stale:
            let problems = AttentionCause.ranked(AccountVisibility.visible(presentations), now: now)
            guard let first = problems.first else { return nil }
            var lines: [String] = []
            for problem in problems.prefix(maxAccountLines) {
                lines.append(line(problem.presentation, cause: problem.cause, now: now, locale: locale))
            }
            let hidden: Int = problems.count - maxAccountLines
            if hidden > 0 {
                lines.append(LocalizedStringResource.freshnessHelpMore(hidden).string(in: locale))
            }
            return FreshnessHelp(
                title: LocalizedStringResource.freshnessHelpTitle(problems.count).string(in: locale),
                lines: lines,
                hint: LocalizedStringResource.freshnessHelpHintStale.string(in: locale),
                target: .account(first.presentation.id)
            )
        }
    }

    private static func line(
        _ presentation: AccountPresentation,
        cause: AttentionCause,
        now: Date,
        locale: Locale
    ) -> String {
        let label: String = presentation.account.label
        let provider: String = presentation.account.provider.displayName
        let causeText: String = cause.shortText(locale: locale)
        guard let fetchedAt = presentation.snapshot?.fetchedAt else {
            return LocalizedStringResource.freshnessHelpLineNoAge(label, provider, causeText).string(in: locale)
        }
        let age: String = AttentionCopy.shortAge(since: fetchedAt, now: now, locale: locale)
        return LocalizedStringResource.freshnessHelpLine(label, provider, causeText, age).string(in: locale)
    }
}

/// Durations and times for the attention copy.
enum AttentionCopy {
    /// "3h ago" — the hover card's compact age, leading unit only, at least
    /// a minute.
    static func shortAge(since date: Date, now: Date, locale: Locale) -> String {
        let age: TimeInterval = max(60, now.timeIntervalSince(date))
        let compact: String = UsageFormatters.remainingUntilResetLeadingUnit(
            now.addingTimeInterval(age),
            relativeTo: now,
            locale: locale
        )
        return LocalizedStringResource.attentionAgeAgo(compact).string(in: locale)
    }

    /// "3 hours" — the banner's age in words. Whole hours from an hour up
    /// (minutes are noise at that scale), at least a minute.
    static func longAge(since date: Date, now: Date, locale: Locale) -> String {
        let age: TimeInterval = max(60, now.timeIntervalSince(date))
        let coarse: TimeInterval = age >= 3_600 ? (age / 3_600).rounded(.down) * 3_600 : age
        return UsageFormatters.spokenDuration(
            until: now.addingTimeInterval(coarse),
            relativeTo: now,
            locale: locale
        )
    }

    /// A clock time for today ("14:12"), with the date otherwise.
    static func clock(_ date: Date, now: Date, locale: Locale, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            return UsageFormatters.shortTime(date, locale: locale, timeZone: timeZone)
        }
        return UsageFormatters.shortReset(date, locale: locale, timeZone: timeZone)
    }
}
