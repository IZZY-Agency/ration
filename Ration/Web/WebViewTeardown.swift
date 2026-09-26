import Foundation
import WebKit

/// The frame teardown a timed-out web view gets, and how to tell afterwards
/// whether the view acted on it.
///
/// `stopLoading()` alone does NOT settle a pending script-evaluation callback:
/// pending callbacks are invalidated on FRAME DESTRUCTION, not on load
/// cancellation. Navigating to `about:blank` destroys the current frame and
/// force-settles the abandoned call. A persistently wedged WebContent process
/// can ignore that navigation too; `hasCompleted` is how the session manager
/// notices.
@MainActor
enum WebViewTeardown {
    static let blankURL = URL(string: "about:blank")!

    static func begin(_ webView: WKWebView) {
        webView.stopLoading()
        webView.load(URLRequest(url: blankURL))
    }

    /// True once the `about:blank` navigation has finished: the view shows it
    /// and is no longer loading. WebKit reports the requested URL as soon as
    /// the load is issued, so the URL alone is not proof; the finished load
    /// is, since only the WebContent process can finish it.
    static func hasCompleted(_ webView: WKWebView) -> Bool {
        !webView.isLoading && webView.url == blankURL
    }
}
