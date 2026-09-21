import Foundation

@MainActor
final class SerializedMutationQueue {
    private var tail = Task<Void, Never> {}

    /// Chains `operation` onto the queue's tail and awaits its result.
    func run(
        _ operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        try await enqueue(operation).value
    }

    /// Chains `operation` onto the queue's tail SYNCHRONOUSLY — the capture of
    /// the current tail and the scheduling of the new one both happen before
    /// this call returns, with no intervening suspension. This matters for
    /// callers driving the queue from a non-async context (e.g. a Combine
    /// `sink`): a later `run`/`enqueue` call is guaranteed to observe this
    /// operation as already queued, even though `operation` itself hasn't
    /// started running yet. Returns the task so a caller that wants
    /// completion/error visibility can await it directly; callers that only
    /// need FIFO ordering (fire-and-forget) can discard the result.
    @discardableResult
    func enqueue(
        _ operation: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Error> {
        let previous = tail
        let task = Task<Void, Error> { @MainActor in
            await previous.value
            try await operation()
        }
        tail = Task { @MainActor in
            _ = try? await task.value
        }
        return task
    }
}
