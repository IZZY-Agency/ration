import Foundation
import ObjectiveC
import WebKit

/// Receives TypeSafe's billing SUMMARY as the console page loads its billing.
///
/// The balance only reaches the page through a Next.js server action (a POST
/// to `/settings/billing` keyed by an id that changes with every TypeSafe
/// deployment), so Ration never calls it: a document-start script wraps the
/// page's own `fetch`, reads a clone of that one response with a byte cap,
/// and posts only the permitted fields (`TypeSafeScripts.extractBilling`).
/// Payment method, invoice e-mail, billing address and payments never cross
/// the WebKit bridge.
///
/// The summary is untrusted page data: it is only parsed
/// (`TypeSafeBilling.parse`), never acted on, and only accepted from the main
/// frame on exactly `https://console.typesafe.ai` (port 443).
@MainActor
final class TypeSafeBillingCapture: NSObject, WKScriptMessageHandler {
    nonisolated static let handlerName = "rationTypeSafeBilling"
    nonisolated static let host = "console.typesafe.ai"

    /// Summaries accepted so far on this web view.
    private(set) var received = 0
    /// The latest summary and when it ARRIVED (the reset date counts from
    /// then, not from when the adapter's poll picks it up).
    private var latest: (summary: String, at: Date)?
    private let clock: () -> Date

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    private static var associationKey: UInt8 = 0

    /// The capture for `webView`, installing the script and the handler on
    /// first use. The script applies from the NEXT navigation, which is why
    /// the adapter always loads the billing page after this.
    static func installed(on webView: WKWebView) -> TypeSafeBillingCapture {
        if let existing = objc_getAssociatedObject(webView, &associationKey) as? TypeSafeBillingCapture {
            return existing
        }
        let capture = TypeSafeBillingCapture()
        let controller = webView.configuration.userContentController
        // A name can be registered once per world; clear any leftover first.
        controller.removeScriptMessageHandler(forName: handlerName, contentWorld: .page)
        controller.add(capture, contentWorld: .page, name: handlerName)
        controller.addUserScript(WKUserScript(
            source: TypeSafeScripts.capture,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
        objc_setAssociatedObject(webView, &associationKey, capture, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return capture
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            let origin = message.frameInfo.securityOrigin
            guard
                message.frameInfo.isMainFrame,
                Self.accepts(protocol: origin.protocol, host: origin.host, port: origin.port),
                let summary = message.body as? String
            else { return }
            accept(summary)
        }
    }

    /// Exactly `https://console.typesafe.ai` (0 is WebKit's "default port").
    nonisolated static func accepts(protocol scheme: String, host: String, port: Int) -> Bool {
        scheme.lowercased() == "https" && host.lowercased() == Self.host && (port == 0 || port == 443)
    }

    /// Takes a summary the page posted (the handler's checks already passed).
    /// The cap is in UTF-8 bytes, as in the page.
    func accept(_ summary: String) {
        guard summary.utf8.count <= TypeSafeBilling.maxMessageBytes else { return }
        latest = (summary, clock())
        received += 1
    }

    /// The latest summary and its arrival, once: cleared as it is taken.
    func take() -> (summary: String, at: Date)? {
        defer { latest = nil }
        return latest
    }
}

/// The page scripts TypeSafe needs. The extraction functions are separate
/// strings so tests can run them in JavaScriptCore.
enum TypeSafeScripts {
    static let maxBillingBytes = 1_048_576

    /// `__rationTypeSafeBilling(text)`: the RSC answer's `data.billing`, cut to
    /// the permitted fields, or null.
    static let extractBilling = """
    function __rationTypeSafeBilling(text) {
      const lines = String(text).split("\\n");
      for (const line of lines) {
        const colon = line.indexOf(":");
        if (colon < 0) { continue; }
        const rest = line.slice(colon + 1);
        if (rest.charAt(0) !== "{") { continue; }
        let parsed;
        try { parsed = JSON.parse(rest); } catch (error) { continue; }
        const billing = parsed && parsed.data && parsed.data.billing;
        if (!billing || typeof billing !== "object") { continue; }
        // Only plain values of the expected type ever leave: a field that
        // changed shape (an object where a string was) becomes null, so no
        // nested data can ride along.
        const num = (value) => (typeof value === "number" && Number.isFinite(value)) ? value : null;
        const str = (value, max) => (typeof value === "string" && value.length <= max) ? value : null;
        const pick = (credit) => (credit && typeof credit === "object" && !Array.isArray(credit))
          ? { id: str(credit.id, 128), amount: num(credit.amount), remaining: num(credit.remaining), expiresAt: str(credit.expiresAt, 64), reason: str(credit.reason, 64) }
          : null;
        return {
          balance: num(billing.balance),
          spent: num(billing.spent),
          cycleLabel: str(billing.cycleLabel, 64),
          resetsInDays: Number.isInteger(billing.resetsInDays) ? billing.resetsInDays : null,
          autoPay: Object.prototype.hasOwnProperty.call(billing, "autoPay") ? (billing.autoPay === null ? "off" : "on") : null,
          credits: Array.isArray(billing.credits) ? billing.credits.slice(0, 200).map(pick) : null
        };
      }
      return null;
    }
    """

    /// Runs in the page's own world at document start, main frame only.
    /// The page keeps its own response untouched; only a clone of the one
    /// matching response is read, up to `maxBillingBytes`.
    static let capture = """
    (() => {
      if (window.__rationTypeSafeCapture) { return; }
      window.__rationTypeSafeCapture = true;
      const original = window.fetch;
      if (typeof original !== "function") { return; }
      \(extractBilling)
      const readCapped = async (response, max) => {
        if (!response.body || !response.body.getReader) { return null; }
        const reader = response.body.getReader();
        const chunks = [];
        let received = 0;
        while (true) {
          const { done, value } = await reader.read();
          if (done) { break; }
          received += value.byteLength;
          if (received > max) { try { await reader.cancel(); } catch (error) {} return null; }
          chunks.push(value);
        }
        const merged = new Uint8Array(received);
        let offset = 0;
        for (const chunk of chunks) { merged.set(chunk, offset); offset += chunk.byteLength; }
        return new TextDecoder().decode(merged);
      };
      window.fetch = async function (input, init) {
        const response = await original.apply(this, arguments);
        try {
          const raw = typeof input === "string" ? input : (input && input.url) || String(input);
          const url = new URL(raw, location.href);
          const method = String((init && init.method) || (input && input.method) || "GET").toUpperCase();
          const type = response.headers.get("content-type") || "";
          if (method === "POST" && url.origin === location.origin && url.pathname === "/settings/billing" && type.indexOf("text/x-component") !== -1) {
            readCapped(response.clone(), \(maxBillingBytes)).then((text) => {
              if (text === null) { return; }
              const summary = __rationTypeSafeBilling(text);
              if (!summary) { return; }
              const json = JSON.stringify(summary);
              if (new TextEncoder().encode(json).length > \(TypeSafeBilling.maxMessageBytes)) { return; }
              window.webkit.messageHandlers.\(TypeSafeBillingCapture.handlerName).postMessage(json);
            }).catch(() => {});
          }
        } catch (error) {}
        return response;
      };
    })();
    """

    /// `__rationTypeSafeDays(parsed)`: the usage answer summed per UTC day as
    /// `[yyyy-MM-dd, input, output, requests]` rows, or null.
    static let aggregateUsage = """
    function __rationTypeSafeDays(parsed) {
      const buckets = parsed && Array.isArray(parsed.buckets) ? parsed.buckets : null;
      if (!buckets) { return null; }
      const count = (value) => (typeof value === "number" && Number.isFinite(value) && value > 0) ? Math.floor(value) : 0;
      const byDay = {};
      for (const bucket of buckets) {
        if (!bucket || typeof bucket.day !== "string" || bucket.day.length < 10) { continue; }
        const day = bucket.day.slice(0, 10);
        if (!/^\\d{4}-\\d{2}-\\d{2}$/.test(day)) { continue; }
        const total = byDay[day] || (byDay[day] = [0, 0, 0]);
        total[0] += count(bucket.inputTokens);
        total[1] += count(bucket.outputTokens);
        total[2] += count(bucket.requests);
      }
      return Object.keys(byDay).sort().map((day) => [day, byDay[day][0], byDay[day][1], byDay[day][2]]);
    }
    """
}
