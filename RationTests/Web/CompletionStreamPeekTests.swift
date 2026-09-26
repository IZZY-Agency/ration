import JavaScriptCore
import WebKit
import XCTest
@testable import Ration

/// Runs the REAL completion script (`WebUsageClient.completionPostScript`) in
/// JavaScriptCore against a scripted `fetch`, so the stream peek is
/// tested as shipped. Nothing reaches a network.
@MainActor
final class CompletionStreamPeekTests: XCTestCase {
    private struct Run {
        /// False when the script never settled (a hang).
        let settled: Bool
        let status: Int
        let streamError: String?
        let body: String
        let reads: Int
        let cancelled: Bool
        /// Every delay the script asked `setTimeout` for.
        let timerDelays: [Int]
    }

    private struct Options {
        var status = 200
        /// After the scripted chunks run out, `read()` never settles.
        var hangAfterChunks = false
        /// `cancel()` never settles.
        var cancelHangs = false
        /// The fake `setTimeout` actually fires (as a microtask). Off, it
        /// never fires, so only the stream can end the peek.
        var timersFire = false
    }

    /// `chunks` are the SSE byte chunks the fake body yields, in order.
    private func run(_ chunks: [String], _ options: Options = Options()) throws -> Run {
        let context = try XCTUnwrap(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in
            exception = value?.toString()
        }
        let chunkData = try JSONSerialization.data(withJSONObject: chunks)
        let chunkLiteral = String(decoding: chunkData, as: UTF8.self)
        let prelude = """
        var location = { origin: "https://claude.ai" };
        var __timerDelays = [];
        function setTimeout(fn, ms) {
            __timerDelays.push(ms);
            if (\(options.timersFire)) { Promise.resolve().then(fn); }
            return 1;
        }
        function clearTimeout(id) {}
        class TextDecoder {
            decode(bytes, options) {
                let text = "";
                if (!bytes) { return text; }
                for (const byte of bytes) { text += String.fromCharCode(byte); }
                return text;
            }
        }
        function __bytes(text) {
            const bytes = new Uint8Array(text.length);
            for (let i = 0; i < text.length; i++) { bytes[i] = text.charCodeAt(i); }
            return bytes;
        }
        var __chunks = \(chunkLiteral).map(__bytes);
        var __reads = 0;
        var __cancelled = false;
        function __cancel() {
            __cancelled = true;
            if (\(options.cancelHangs)) { return new Promise(() => {}); }
            return Promise.resolve();
        }
        function fetch(path, init) {
            const reader = {
                read() {
                    __reads += 1;
                    if (__chunks.length > 0) {
                        return Promise.resolve({ done: false, value: __chunks.shift() });
                    }
                    if (\(options.hangAfterChunks)) { return new Promise(() => {}); }
                    return Promise.resolve({ done: true, value: undefined });
                },
                cancel: __cancel
            };
            return Promise.resolve({
                ok: \(options.status) >= 200 && \(options.status) < 300,
                status: \(options.status),
                headers: { get(name) { return null; } },
                body: { getReader() { return reader; }, cancel: __cancel }
            });
        }
        var __result = null;
        """
        context.evaluateScript(prelude)
        let wrapped = """
        (async function(path, bodyJSON) {
        \(WebUsageClient.completionPostScript)
        })("/api/organizations/o/chat_conversations/c/completion", "{}")
            .then((value) => { __result = value; }, (error) => { __result = { thrown: String(error) }; });
        """
        context.evaluateScript(wrapped)
        XCTAssertNil(exception)
        let delays = context.objectForKeyedSubscript("__timerDelays").toArray() ?? []
        let common = (
            reads: Int(context.objectForKeyedSubscript("__reads").toInt32()),
            cancelled: context.objectForKeyedSubscript("__cancelled").toBool(),
            delays: delays.compactMap { ($0 as? NSNumber)?.intValue }
        )
        guard let result = context.objectForKeyedSubscript("__result").toDictionary() else {
            return Run(
                settled: false, status: -1, streamError: nil, body: "",
                reads: common.reads, cancelled: common.cancelled, timerDelays: common.delays
            )
        }
        XCTAssertNil(result["thrown"], "\(result)")
        return Run(
            settled: true,
            status: (result["status"] as? NSNumber)?.intValue ?? -1,
            streamError: result["streamError"] as? String,
            body: result["body"] as? String ?? "<missing>",
            reads: common.reads,
            cancelled: common.cancelled,
            timerDelays: common.delays
        )
    }

    func testAnErrorEventAfterMessageStartIsReported() throws {
        let run = try run([
            "event: message_start\ndata: {\"type\":\"message_start\"}\n\n",
            "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"secret prose\"}}\n\n",
        ])
        XCTAssertEqual(run.status, 200)
        XCTAssertEqual(run.streamError, "rate_limit_error")
        XCTAssertEqual(run.body, "", "the body is never returned")
        XCTAssertTrue(run.cancelled)
    }

    func testAnErrorEventSplitAcrossChunksIsReported() throws {
        let run = try run([
            "event: err",
            "or\r\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_",
            "error\"}}\r\n\r\n",
        ])
        XCTAssertEqual(run.streamError, "overloaded_error")
    }

    /// SSE lets one event's data span several `data:` lines; they are joined
    /// and parsed once, at the blank line.
    func testAMultiLineErrorEventIsAssembledBeforeParsing() throws {
        let run = try run([
            "event: error\ndata: {\"type\":\"error\",\ndata: \"error\":{\"type\":\"permission_error\"}}\n\n",
        ])
        XCTAssertEqual(run.streamError, "permission_error")
    }

    func testAnErrorPayloadWithoutAnEventLineIsReported() throws {
        let run = try run(["data: {\"type\":\"error\",\"error\":{\"type\":\"permission_error\"}}\n\n"])
        XCTAssertEqual(run.streamError, "permission_error")
    }

    func testAHealthyStreamStopsAtMessageStopAndReportsNothing() throws {
        let run = try run([
            "event: message_start\ndata: {\"type\":\"message_start\"}\n\n",
            "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
            "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"api_error\"}}\n\n",
        ])
        XCTAssertNil(run.streamError)
        XCTAssertEqual(run.reads, 2, "the peek stops at message_stop")
        XCTAssertTrue(run.cancelled)
    }

    func testTheOrdinaryDataEventsAreNotErrors() throws {
        let run = try run([
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"error\"}}\n\n",
        ])
        XCTAssertNil(run.streamError)
    }

    func testThePeekIsBoundedInBytesAcrossChunks() throws {
        let filler = "event: ping\ndata: {\"type\":\"ping\"}\n\n"
        let big = String(repeating: filler, count: WebUsageClient.streamPeekBytes / filler.count + 1)
        let run = try run([
            big,
            "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"api_error\"}}\n\n",
        ])
        XCTAssertNil(run.streamError)
        XCTAssertEqual(run.reads, 1)
    }

    /// One big chunk is cut to the budget before it is scanned: an error that
    /// starts past byte 16 384 of the same chunk is never seen.
    func testThePeekIsBoundedInBytesWithinOneChunk() throws {
        let filler = "event: ping\ndata: {\"type\":\"ping\"}\n\n"
        let head = String(repeating: filler, count: WebUsageClient.streamPeekBytes / filler.count + 1)
        let error = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"api_error\"}}\n\n"
        let run = try run([head + error])
        XCTAssertNil(run.streamError)
        // Control: the same event inside the budget IS reported.
        XCTAssertEqual(try self.run([filler + error]).streamError, "api_error")
    }

    /// A stream that goes quiet is abandoned when the peek's own timer fires,
    /// and that timer is the 4 s deadline.
    func testAQuietStreamEndsAtThePeekDeadline() throws {
        var options = Options()
        options.hangAfterChunks = true
        options.timersFire = true
        let run = try run(["event: message_start\ndata: {\"type\":\"message_start\"}\n\n"], options)
        XCTAssertTrue(run.settled, "the deadline must end a silent stream")
        XCTAssertEqual(run.status, 200)
        XCTAssertNil(run.streamError)
        XCTAssertTrue(run.cancelled)
        let delay = try XCTUnwrap(run.timerDelays.first)
        XCTAssertGreaterThan(delay, 0)
        XCTAssertLessThanOrEqual(delay, WebUsageClient.streamPeekMilliseconds)
        XCTAssertGreaterThan(delay, WebUsageClient.streamPeekMilliseconds - 1_000)
    }

    /// Control for the test above: with the timer never firing, the same
    /// quiet stream does not settle — so the settling above is the timer's.
    func testAQuietStreamWithoutTheTimerNeverSettles() throws {
        var options = Options()
        options.hangAfterChunks = true
        let run = try run(["event: message_start\ndata: {\"type\":\"message_start\"}\n\n"], options)
        XCTAssertFalse(run.settled)
    }

    /// A cancel that never settles must not hold the result back.
    func testAStalledCancelDoesNotDelayTheResult() throws {
        var options = Options()
        options.cancelHangs = true
        let run = try run([
            "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\"}}\n\n",
        ], options)
        XCTAssertTrue(run.settled)
        XCTAssertTrue(run.cancelled)
        XCTAssertEqual(run.streamError, "rate_limit_error")

        var refused = Options()
        refused.cancelHangs = true
        refused.status = 429
        XCTAssertTrue(try self.run([], refused).settled)
    }

    /// Only documented error types leave the page as themselves.
    func testAnUnrecognisedTypeIsReducedToUnknown() throws {
        for type in ["quota_exceeded_error", "org_2f9c1a7e", "You are out of messages"] {
            let run = try run(["event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"\(type)\"}}\n\n"])
            XCTAssertEqual(run.streamError, "unknown", type)
        }
    }

    func testANon2xxIsNotReadAtAll() throws {
        var options = Options()
        options.status = 429
        let run = try run(["event: error\ndata: {\"type\":\"error\"}\n\n"], options)
        XCTAssertEqual(run.status, 429)
        XCTAssertNil(run.streamError)
        XCTAssertEqual(run.reads, 0)
        XCTAssertTrue(run.cancelled)
    }

    func testTheEnvelopeMapsTheStreamErrorOntoTheClosedSet() async throws {
        let client = WebUsageClient(evaluator: { _, _, _ in
            ["status": 200, "retryAfter": NSNull(), "body": "", "streamError": "has_spaces_not"]
        })
        let envelope = try await client.postCompletion(path: "/p", bodyJSON: "{}", in: WKWebView())
        XCTAssertEqual(envelope.streamErrorType, .unknown)
    }
}
