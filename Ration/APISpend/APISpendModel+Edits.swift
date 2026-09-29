import Foundation

enum APIOrgEditError: Error, Equatable {
    case invalidKey
    case regularKey(APIVendor)
    case duplicate(label: String)
    case secondOpenAIWithoutIdentity
    case identityMismatch
    case replaceUnavailable
    case busy
    case validation(APISpendError)
    case keychain(APISpendError)
    case saveFailed
}

extension APISpendModel {
    var hasPendingKeyDeletions: Bool { !state.pendingKeyDeletions.isEmpty }

    private func admin(_ rawKey: String) throws -> (key: String, vendor: APIVendor) {
        let key = APIVendor.normalizedKey(rawKey)
        switch APIVendor.classify(key) {
        case .admin(let vendor): return (key, vendor)
        case .regular(let vendor): throw APIOrgEditError.regularKey(vendor)
        case .invalid: throw APIOrgEditError.invalidKey
        }
    }

    /// Validate (one cost request + identity), refuse duplicates, key first then record.
    func addOrg(label: String, rawKey: String, budgetCents: Int?) async throws -> UUID {
        let (key, vendor) = try admin(rawKey)
        guard let client = deps.clients[vendor] else { throw APIOrgEditError.validation(.integrationChanged(.unexpectedStatus)) }
        let now = deps.now()
        let identity: OrgIdentity?
        do {
            _ = try await client.costReport(month: UTCMonth(containing: now), key: key, refreshStartedAt: now)
            identity = try await client.identity(key: key)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw APIOrgEditError.validation(error as? APISpendError ?? .transport)
        }
        // Cancelled from the sheet during validation: nothing reaches the Keychain.
        try Task.checkCancellation()
        if let id = identity?.id, let existing = state.orgs.first(where: { $0.vendor == vendor && $0.vendorOrgID == id }) {
            throw APIOrgEditError.duplicate(label: existing.label)
        }
        if identity == nil, vendor == .openAI, state.orgs.contains(where: { $0.vendor == .openAI }) {
            throw APIOrgEditError.secondOpenAIWithoutIdentity
        }
        let orgID = UUID()
        do { try await keyCall { try $0.add(key, for: orgID) } } catch {
            throw APIOrgEditError.keychain(error as? APISpendError ?? .keychain(status: 0))
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = APIOrgRecord(
            id: orgID, vendor: vendor, vendorOrgID: identity?.id,
            label: trimmed.isEmpty ? (identity?.name ?? vendor.displayName) : trimmed,
            monthlyBudgetCents: budgetCents.flatMap { APIMoney.budgetRange.contains($0) ? $0 : nil },
            isPaused: false,
            displayOrder: (state.orgs.map(\.displayOrder).max() ?? -1) + 1,
            createdAt: now
        )
        mutateState { $0.orgs.append(record) }
        guard await writeStateNow() == .written else {
            mutateState { $0.orgs.removeAll { $0.id == orgID } }
            try? await keyCall { try $0.delete(for: orgID) }
            throw APIOrgEditError.saveFailed
        }
        Task { await refresh(orgID) }
        return orgID
    }

    func rename(_ id: UUID, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = state.orgs.firstIndex(where: { $0.id == id }) else { return }
        mutateOrg(at: index) { $0.label = trimmed }
        persistState()
    }

    /// Budget transitions, compared on the canonical value.
    func setBudget(_ id: UUID, cents: Int?) {
        guard let index = state.orgs.firstIndex(where: { $0.id == id }) else { return }
        let canonical = cents.flatMap { APIMoney.budgetRange.contains($0) ? $0 : nil }
        guard state.orgs[index].monthlyBudgetCents != canonical else { return }   // X → X: no-op
        generation[id, default: 0] += 1
        mutateOrg(at: index) { $0.monthlyBudgetCents = canonical }
        mutateState { state in
            if canonical == nil {
                state.memory[id] = nil
            } else {
                let month = state.memory[id]?.evaluatedMonthKey          // never moved by an edit
                state.memory[id] = BudgetAlertMemory(evaluatedMonthKey: month, notifiedTier: nil, dismissedTier: nil)
            }
        }
        if !evaluate(id) { persistState() }
        Task { await refresh(id) }
    }

    /// Settings' one list after a drag: saves the
    /// interleaving and renumbers the API accounts' `displayOrder` to match,
    /// so the popover cards and gauges follow. Subscriptions move through
    /// `AppModel.moveAccount` (their store owns their order).
    func setSidebarOrder(_ items: [SidebarAccountOrder.Item]) {
        let ids = items.map(\.id)
        let apiOrder = items.filter { !$0.isSubscription }.map(\.id)
        let changesAPIOrder = apiOrder.enumerated().contains { order, id in org(id).map { $0.displayOrder != order } ?? false }
        guard ids != state.sidebarOrder || changesAPIOrder else { return }
        mutateState { state in
            state.sidebarOrder = ids
            for (order, id) in apiOrder.enumerated() {
                if let index = state.orgs.firstIndex(where: { $0.id == id }) { state.orgs[index].displayOrder = order }
            }
        }
        persistState()
    }

    /// Global API thresholds: tiers are NOT reset (fire-once holds).
    func setThresholds(_ pair: ThresholdPair) {
        guard pair != state.thresholds else { return }
        mutateState { $0.thresholds = pair }
        var handedToBridge = false
        for org in state.orgs { handedToBridge = evaluate(org.id) || handedToBridge }
        if !handedToBridge { persistState() }
    }

    func setPaused(_ id: UUID, _ paused: Bool) async {
        guard let index = state.orgs.firstIndex(where: { $0.id == id }), state.orgs[index].isPaused != paused else { return }
        generation[id, default: 0] += 1
        pausingOrgIDs.insert(id)
        mutateOrg(at: index) { $0.isPaused = paused }
        _ = await writeStateNow()
        pausingOrgIDs.remove(id)
        if !paused { await refresh(id) }
    }

    /// Key replacement: one at a time per org, token-owned.
    func replaceKey(_ id: UUID, rawKey: String) async throws {
        // Never alongside a removal of the same org — checked
        // first: mid-removal the org has already left `state`.
        guard !removingOrgIDs.contains(id) else { throw APIOrgEditError.busy }
        guard let org = org(id) else { return }
        guard org.vendorOrgID != nil else { throw APIOrgEditError.replaceUnavailable }
        guard replacing[id] == nil else { throw APIOrgEditError.busy }
        let (key, vendor) = try admin(rawKey)
        guard vendor == org.vendor, let client = deps.clients[vendor] else { throw APIOrgEditError.invalidKey }
        let token = UUID()
        replacing[id] = token
        generation[id, default: 0] += 1
        func release() { if replacing[id] == token { replacing[id] = nil } }
        let identity: OrgIdentity?
        do {
            let now = deps.now()
            _ = try await client.costReport(month: UTCMonth(containing: now), key: key, refreshStartedAt: now)
            identity = try await client.identity(key: key)
        } catch {
            release()
            if Task.isCancelled { throw CancellationError() }
            throw APIOrgEditError.validation(error as? APISpendError ?? .transport)
        }
        if Task.isCancelled { release(); throw CancellationError() }
        guard replacing[id] == token else { return }
        guard identity?.id == org.vendorOrgID else { release(); throw APIOrgEditError.identityMismatch }
        do {
            do {
                try await keyCall { try $0.update(key, for: id) }
            } catch APISpendError.keyMissing {
                // The key is gone from the Keychain: Replace restores it.
                try await keyCall { try $0.add(key, for: id) }
            }
        } catch {
            // SecItemUpdate either succeeds or leaves the item as it was: confirm.
            if (try? await keyCall({ try $0.read(for: id) })) == nil { markCostError(id, .keyMissing) }
            release()
            throw APIOrgEditError.keychain(error as? APISpendError ?? .keychain(status: 0))
        }
        guard replacing[id] == token else { return }
        replacing[id] = nil
        generation[id, default: 0] += 1
        markCostError(id, nil)
        await refresh(id)
    }

    /// Removal: record + memory + journal in ONE write, Keychain last.
    func removeOrg(_ id: UUID) async -> Bool {
        // Not while a replacement runs: its late Keychain write (even one whose
        // sheet was cancelled) could re-add the key after this deletes it.
        guard replacing[id] == nil, !removingOrgIDs.contains(id),
              let index = state.orgs.firstIndex(where: { $0.id == id }) else { return false }
        removingOrgIDs.insert(id)
        generation[id, default: 0] += 1
        clearRemoveFailure(id)
        let record = state.orgs[index]
        let memory = state.memory[id]
        mutateState { state in
            state.orgs.remove(at: index)
            state.memory[id] = nil
            state.pendingKeyDeletions.append(id)
        }
        guard await writeStateNow() == .written else {
            mutateState { state in
                state.orgs.insert(record, at: min(index, state.orgs.count))
                state.memory[id] = memory
                state.pendingKeyDeletions.removeAll { $0 == id }
            }
            removingOrgIDs.remove(id)
            markRemoveFailure(id)
            return false
        }
        dropCaches(for: id)
        removingOrgIDs.remove(id)
        await retryPendingKeyDeletions()
        return true
    }

    /// Idempotent; re-checks live orgs right before every Keychain delete.
    func retryPendingKeyDeletions() async {
        // A removal still writing owns its key: the write can fail and restore the org.
        for id in state.pendingKeyDeletions where !removingOrgIDs.contains(id) {
            if state.orgs.contains(where: { $0.id == id }) {
                mutateState { $0.pendingKeyDeletions.removeAll { $0 == id } }
                persistState()
                continue
            }
            do { try await keyCall { try $0.delete(for: id) } } catch { continue }
            mutateState { $0.pendingKeyDeletions.removeAll { $0 == id } }
            persistState()
        }
    }
}

/// A quit saves API edits like any other Settings edit: the
/// model registers in `AppModel.pendingEdits`, which quits await (bounded).
extension APISpendModel: PendingEditFlushing {
    static let pendingEditKey = "api-spend.state"

    /// A state change not yet on disk. Never while the file was unreadable —
    /// that file is never overwritten.
    var hasPendingEdit: Bool { hydrated && !loadFailed && writtenRevision < stateRevision }

    func flushPendingEdit() async {
        guard hasPendingEdit else { return }
        _ = await writeStateNow()
    }
}
