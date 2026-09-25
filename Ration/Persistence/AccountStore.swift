import Combine
import Foundation

enum AccountStoreError: Error, Equatable {
    case accountNotFound
    case accountAlreadyExists
    case emptyLabel
    case operationInProgress
}

extension AccountStoreError: LocalizedError {
    var errorDescription: String? { message(locale: .current) }

    func message(locale: Locale) -> String {
        let resource: LocalizedStringResource = switch self {
        case .accountNotFound: .accountStoreErrorAccountNotFound
        case .accountAlreadyExists: .accountStoreErrorAccountAlreadyExists
        case .emptyLabel: .accountStoreErrorEmptyLabel
        case .operationInProgress: .accountStoreErrorOperationInProgress
        }
        return resource.string(in: locale)
    }
}

@MainActor
final class AccountStore: ObservableObject {
    typealias SaveAccounts = @MainActor ([AccountRecord]) async throws -> Void

    @Published private(set) var accounts: [AccountRecord] = []

    /// Web-profile IDs of records DROPPED by the last `load()` because they
    /// duplicated an accepted record's `id` or `webProfileID`, minus any profile
    /// ID still used by an accepted account. These are orphaned WebKit stores —
    /// a mis-migrated file left them with no owning account — that the owner
    /// (`AppModel.load`) journals for deletion so their authenticated cookie
    /// data is not stranded on disk.
    private(set) var orphanedProfileIDsFromLoad: [UUID] = []

    private let fileStore: JSONFileStore<[AccountRecord]>
    private let saveAccounts: SaveAccounts
    private let mutations = SerializedMutationQueue()

    init(fileURL: URL, saveAccounts: SaveAccounts? = nil) {
        let fileStore = JSONFileStore<[AccountRecord]>(
            fileURL: fileURL,
            defaultValue: []
        )
        self.fileStore = fileStore
        self.saveAccounts = saveAccounts ?? { accounts in
            try await fileStore.save(accounts)
        }
    }

    func load() async throws {
        try await mutations.run { [self] in
            let restored = try await fileStore.load()
            let sorted = restored.sorted { $0.displayOrder < $1.displayOrder }
            let partition = partitioned(sorted)
            accounts = normalized(partition.kept)

            // Orphaned profiles = dropped records' profiles NOT reused by any
            // kept account (a record dropped for a duplicate `webProfileID`
            // shares that profile with a live account and must NOT be journalled
            // for deletion). Deduplicated, order-independent.
            let keptProfileIDs = Set(partition.kept.map(\.webProfileID))
            orphanedProfileIDsFromLoad = Array(
                Set(
                    partition.dropped
                        .map(\.webProfileID)
                        .filter { !keptProfileIDs.contains($0) }
                )
            )
        }
    }

    /// Splits records into accepted (`kept`) and rejected (`dropped`). A record
    /// is dropped when it reuses an `id` or `webProfileID` already claimed by an
    /// earlier (lower-`displayOrder`) accepted record — a valid-but-corrupt or
    /// mis-migrated `accounts.json` with a duplicate `webProfileID` would
    /// otherwise make two logical accounts share one cached WebView and
    /// persistent cookie store, one account's session leaking into another's.
    /// First-wins; BOTH identifiers are tested before EITHER is claimed, so a
    /// record rejected for one collision never consumes the other identifier and
    /// drops a later distinct account.
    private func partitioned(
        _ sorted: [AccountRecord]
    ) -> (kept: [AccountRecord], dropped: [AccountRecord]) {
        var seenIDs: Set<UUID> = []
        var seenProfileIDs: Set<UUID> = []
        var kept: [AccountRecord] = []
        var dropped: [AccountRecord] = []
        for account in sorted {
            guard
                !seenIDs.contains(account.id),
                !seenProfileIDs.contains(account.webProfileID)
            else {
                dropped.append(account)
                continue
            }
            seenIDs.insert(account.id)
            seenProfileIDs.insert(account.webProfileID)
            kept.append(account)
        }
        return (kept, dropped)
    }

    func add(_ account: AccountRecord) async throws {
        try await mutations.run { [self] in
            guard !accounts.contains(where: { $0.id == account.id }) else {
                throw AccountStoreError.accountAlreadyExists
            }
            var candidate = accounts
            candidate.append(account)
            try await persist(normalized(candidate))
        }
    }

    func rename(id: UUID, label: String) async throws {
        try await mutations.run { [self] in
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AccountStoreError.emptyLabel
            }
            guard let index = accounts.firstIndex(where: { $0.id == id }) else {
                throw AccountStoreError.accountNotFound
            }

            var candidate = accounts
            candidate[index].label = trimmed
            try await persist(candidate)
        }
    }

    func move(id: UUID, to destination: Int) async throws {
        try await mutations.run { [self] in
            guard let source = accounts.firstIndex(where: { $0.id == id }) else {
                throw AccountStoreError.accountNotFound
            }

            var candidate = accounts
            let account = candidate.remove(at: source)
            let boundedDestination = min(max(destination, 0), candidate.count)
            candidate.insert(account, at: boundedDestination)
            try await persist(normalized(candidate))
        }
    }

    func setAutoStart(id: UUID, enabled: Bool) async throws {
        try await mutations.run { [self] in
            guard let index = accounts.firstIndex(where: { $0.id == id }) else {
                throw AccountStoreError.accountNotFound
            }
            var candidate = accounts
            candidate[index].autoStartFiveHour = enabled
            try await persist(candidate)
        }
    }

    func setBillingRenewalDay(id: UUID, day: Int?) async throws {
        try await mutations.run { [self] in
            guard let index = accounts.firstIndex(where: { $0.id == id }) else {
                throw AccountStoreError.accountNotFound
            }
            var candidate = accounts
            candidate[index].billingRenewalDay = day.map { min(max($0, 1), 31) }
            try await persist(candidate)
        }
    }

    /// A user plan choice; nil = "Detect automatically" (clears the plan so the
    /// next detection fills it).
    func setPlan(id: UUID, plan: PlanTier?) async throws {
        try await mutations.run { [self] in
            guard let index = accounts.firstIndex(where: { $0.id == id }) else {
                throw AccountStoreError.accountNotFound
            }
            var candidate = accounts
            candidate[index].plan = plan
            candidate[index].planSource = plan == nil ? nil : .user
            try await persist(candidate)
        }
    }

    /// One fetch's plan detection. Judged INSIDE the serialized queue, so a
    /// user choice that landed first is always seen and never overwritten.
    /// Skips the save when nothing changes (every poll detects).
    func applyDetectedPlan(id: UUID, detection: PlanDetection) async throws {
        try await mutations.run { [self] in
            guard let index = accounts.firstIndex(where: { $0.id == id }) else {
                throw AccountStoreError.accountNotFound
            }
            let updated = accounts[index].applyingDetectedPlan(detection)
            guard updated != accounts[index] else { return }
            var candidate = accounts
            candidate[index] = updated
            try await persist(candidate)
        }
    }

    func setPaused(id: UUID, paused: Bool) async throws {
        try await mutations.run { [self] in
            guard let index = accounts.firstIndex(where: { $0.id == id }) else {
                throw AccountStoreError.accountNotFound
            }
            var candidate = accounts
            candidate[index].isPaused = paused
            try await persist(candidate)
        }
    }

    /// Reserves an auto-start attempt by persisting its timestamp BEFORE the
    /// irreversible send. If the send then fails, the policy still will not
    /// re-fire within the window — closing the retry-storm hole.
    func reserveAutoStart(id: UUID, at date: Date) async throws {
        try await mutations.run { [self] in
            guard let index = accounts.firstIndex(where: { $0.id == id }) else {
                throw AccountStoreError.accountNotFound
            }
            var candidate = accounts
            candidate[index].lastAutoStartedAt = date
            try await persist(candidate)
        }
    }

    /// Records a completed auto-start: the reusable conversation and when it
    /// fired, so the policy does not re-fire within the same window.
    func recordAutoStart(
        id: UUID,
        conversationID: UUID,
        at date: Date
    ) async throws {
        try await mutations.run { [self] in
            guard let index = accounts.firstIndex(where: { $0.id == id }) else {
                throw AccountStoreError.accountNotFound
            }
            var candidate = accounts
            candidate[index].keepAliveConversationID = conversationID
            candidate[index].lastAutoStartedAt = date
            try await persist(candidate)
        }
    }

    func remove(id: UUID) async throws {
        try await mutations.run { [self] in
            guard accounts.contains(where: { $0.id == id }) else {
                throw AccountStoreError.accountNotFound
            }

            try await persist(normalized(accounts.filter { $0.id != id }))
        }
    }

    func restore(_ account: AccountRecord, at index: Int) async throws {
        try await mutations.run { [self] in
            guard !accounts.contains(where: { $0.id == account.id }) else { return }
            var candidate = accounts
            candidate.insert(account, at: min(max(index, 0), candidate.count))
            try await persist(normalized(candidate))
        }
    }

    private func persist(_ candidate: [AccountRecord]) async throws {
        try await saveAccounts(candidate)
        accounts = candidate
    }

    private func normalized(_ candidate: [AccountRecord]) -> [AccountRecord] {
        candidate.enumerated().map { index, account in
            var normalizedAccount = account
            normalizedAccount.displayOrder = index
            return normalizedAccount
        }
    }
}
