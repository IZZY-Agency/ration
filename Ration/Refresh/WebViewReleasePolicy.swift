import Foundation

/// Pure decision for which web-profile IDs are BUSY and therefore must NOT have
/// their cached WKWebView released. A WebView is releasable only when its
/// account has no work in flight that depends on that live view — an in-flight
/// usage refresh, an in-flight auto-start keep-alive send, an in-flight account
/// removal, or an open sign-in/reauth session (which displays the same cached
/// WebView). All inputs are snapshots of markers `AppModel` maintains
/// synchronously on the `@MainActor`, so the result reflects the exact instant
/// it is computed.
enum WebViewReleasePolicy {
    /// The web-profile IDs currently backing in-flight work. Everything cached
    /// but NOT in this set may be released and lazily recreated (the persistent
    /// session cookies survive; only the process-heavy WKWebView is dropped).
    static func busyProfileIDs(
        accounts: [AccountRecord],
        inFlightRefreshAccountIDs: Set<UUID>,
        sendingKeepAliveAccountIDs: Set<UUID>,
        removingAccountIDs: Set<UUID>,
        profileIDsBeingRemoved: Set<UUID>,
        signInProfileIDs: Set<UUID>
    ) -> Set<UUID> {
        // Sign-in sessions and mid-removal profiles are already keyed by profile
        // ID; the rest are account-keyed and mapped to their web profile.
        var busy = signInProfileIDs.union(profileIDsBeingRemoved)
        for account in accounts where
            inFlightRefreshAccountIDs.contains(account.id)
            || sendingKeepAliveAccountIDs.contains(account.id)
            || removingAccountIDs.contains(account.id) {
            busy.insert(account.webProfileID)
        }
        return busy
    }
}
