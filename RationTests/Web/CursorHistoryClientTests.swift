import WebKit
import XCTest
@testable import Ration

/// `WebUsageClient.fetchCursorHistory` outside the page: cancellation ends
/// the wait at once (so the caller can reap the page), and `mayDispatch`
/// vetoes the script before WebKit sees it.
@MainActor
final class CursorHistoryClientTests: XCTestCase {
    private let month = [CursorInvoiceMonth(year: 2026, month: 7)]
    private let open = Date(timeIntervalSince1970: 1_788_220_800)

    func testCancellationEndsAHungReadAtOnce() async throws {
        var started = false
        let client = WebUsageClient(
            evaluator: { _, _, _ in
                started = true
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return nil
            },
            // The timeout never fires: only cancellation can end the wait.
            sleep: { _ in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        )
        let task = Task { @MainActor in
            try await client.fetchCursorHistory(months: self.month, currentPeriodStart: self.open, in: WKWebView(frame: .zero))
        }
        for _ in 0..<1_000 where !started {
            await Task.yield()
        }
        XCTAssertTrue(started, "premise: the evaluation is in flight")
        task.cancel()
        // A watchdog, so a regression fails here instead of hanging the run.
        final class Finished { var done = false }
        let finished = Finished()
        Task { @MainActor in
            _ = try? await task.value
            finished.done = true
        }
        for _ in 0..<300 where !finished.done {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(finished.done, "cancellation must end the wait")
        guard finished.done else { return }
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testVetoStopsTheScriptBeforeWebKit() async {
        var evaluations = 0
        let client = WebUsageClient(
            evaluator: { _, _, _ in
                evaluations += 1
                return nil
            },
            sleep: { _ in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        )
        struct Vetoed: Error {}
        do {
            _ = try await client.fetchCursorHistory(
                months: month, currentPeriodStart: open,
                mayDispatch: { throw Vetoed() },
                in: WKWebView(frame: .zero)
            )
            XCTFail("expected the veto")
        } catch {
            XCTAssertTrue(error is Vetoed)
        }
        XCTAssertEqual(evaluations, 0)
    }
}
