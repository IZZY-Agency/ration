import Combine
import Foundation

@MainActor
final class UsageSnapshotStore: ObservableObject {
    typealias SaveSnapshots = @MainActor (
        [UUID: UsageSnapshot]
    ) async throws -> Void

    @Published private(set) var snapshots: [UUID: UsageSnapshot] = [:]

    var count: Int { snapshots.count }

    private let fileStore: JSONFileStore<[UUID: UsageSnapshot]>
    private let saveSnapshots: SaveSnapshots
    private let mutations = SerializedMutationQueue()

    init(fileURL: URL, saveSnapshots: SaveSnapshots? = nil) {
        let fileStore = JSONFileStore<[UUID: UsageSnapshot]>(
            fileURL: fileURL,
            defaultValue: [:]
        )
        self.fileStore = fileStore
        self.saveSnapshots = saveSnapshots ?? { snapshots in
            try await fileStore.save(snapshots)
        }
    }

    func load() async throws {
        try await mutations.run { [self] in
            snapshots = try await fileStore.load()
        }
    }

    func snapshot(for accountID: UUID) -> UsageSnapshot? {
        snapshots[accountID]
    }

    func save(_ snapshot: UsageSnapshot) async throws {
        try await mutations.run { [self] in
            var candidate = snapshots
            candidate[snapshot.accountID] = Self.merged(
                incoming: snapshot,
                previous: snapshots[snapshot.accountID]
            )
            try await saveSnapshots(candidate)
            snapshots = candidate
        }
    }

    /// Applies a background usage-credits read (see
    /// `AppModel.refreshUsageCreditsInBackground`) to the account's current
    /// snapshot. Returns whether it was written.
    ///
    /// Refused when the account has no snapshot (removed), or when its
    /// snapshot now names another claude.ai organization than the one the
    /// read was made for (a workspace switch landed meanwhile). Reads never
    /// overlap (`AppModel` runs one per account at a time), so the latest
    /// applied is the latest read; no wall-clock ordering, which a clock set
    /// backwards would break. Serialized with `save`, so a usage fetch saved
    /// meanwhile cannot interleave with this read-modify-write.
    @discardableResult
    func applyUsageCredits(_ credits: UsageCredits, accountID: UUID, organizationID: String) async throws -> Bool {
        var written = false
        try await mutations.run { [self] in
            guard
                let current = snapshots[accountID],
                current.organizationID == organizationID
            else { return }
            var candidate = snapshots
            candidate[accountID] = current.replacingUsageCredits(credits.applied(for: organizationID))
            try await saveSnapshots(candidate)
            snapshots = candidate
            written = true
        }
        return written
    }

    /// THE one place a snapshot that did not read resets — or usage credits,
    /// or their switch — inherits the last ones. Every writer (refresh,
    /// warm-up refetch, re-auth commit) goes through `save`, so none of them
    /// can erase these by accident.
    ///
    /// A carried list keeps its OWN `fetchedAt`, which is how alerts tell it
    /// apart from a fresh read. Resets and credits are dropped when both
    /// sides know their claude.ai organization and they differ — a workspace
    /// switch must not show one org's resets or balance under another. After
    /// a relaunch the previous org is unknown (never persisted); they are
    /// then display-only until the next successful read, and alerts only act
    /// on fresh reads. The switch state is carried even across an org change
    /// only until the new fetch reads it, which a successful fetch always
    /// attempts.
    static func merged(incoming: UsageSnapshot, previous: UsageSnapshot?) -> UsageSnapshot {
        guard let previous else { return incoming }
        let orgChanged: Bool = {
            guard let before = previous.organizationID, let after = incoming.organizationID else { return false }
            return before != after
        }()
        var result = incoming
        if result.resetCredits == nil, let carried = previous.resetCredits, !orgChanged {
            result = result.replacingResetCredits(carried)
        }
        if result.usageCredits == nil, let carried = previous.usageCredits, !orgChanged {
            result = result.replacingUsageCredits(carried)
        }
        if result.usageCreditsEnabled == nil, let carried = previous.usageCreditsEnabled, !orgChanged {
            result = result.replacingUsageCreditsEnabled(carried)
        }
        // ChatGPT has no organization id here; its credits simply carry.
        if result.codexCredits == nil, let carried = previous.codexCredits {
            result = result.replacingCodexCredits(carried)
        }
        // TypeSafe's billing and daily usage are read apart; each carries.
        if result.typeSafeSpend == nil, let carried = previous.typeSafeSpend {
            result = result.replacingTypeSafeSpend(carried)
        }
        if result.typeSafeDailyUsage == nil, let carried = previous.typeSafeDailyUsage {
            result = result.replacingTypeSafeDailyUsage(carried)
        }
        return result
    }

    func remove(accountID: UUID) async throws {
        try await mutations.run { [self] in
            var candidate = snapshots
            candidate.removeValue(forKey: accountID)
            try await saveSnapshots(candidate)
            snapshots = candidate
        }
    }
}
