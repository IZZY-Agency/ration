import AppKit
import Foundation
import SwiftUI
import WebKit

/// Pure navigation policy for the embedded sign-in web view. Keeps the
/// authenticated auth session from being hijacked into launching other apps,
/// downgrading to plaintext HTTP, or silently downloading files — WITHOUT a
/// hard domain allowlist, which would break the legitimate cross-origin SSO
/// redirects (Google / Microsoft / Apple / Auth0) that sign-in depends on and
/// that can't be exhaustively enumerated here. Cross-origin HTTPS is allowed so
/// SSO works; the visible origin indicator (see `SignInSessionView`) is the
/// anti-phishing signal, mirroring a browser's address bar.
enum SignInNavigationPolicy {
    enum Decision: Equatable {
        /// Load it in the auth view.
        case allow
        /// Not an in-view web navigation — hand to the system (mail/phone).
        case openExternally
        /// Refuse entirely.
        case cancel
    }

    static func decision(for url: URL?) -> Decision {
        guard let scheme = url?.scheme?.lowercased() else { return .cancel }
        switch scheme {
        case "https", "about":
            // HTTPS (incl. cross-origin SSO) and about:blank load in-view.
            return .allow
        case "mailto", "tel", "facetime", "sms":
            // Legitimate contact links — let the OS open the right app.
            return .openExternally
        default:
            // http (never downgrade an auth view), file/data, and custom
            // app schemes that could deep-link into another app: refused.
            return .cancel
        }
    }

    /// An `.openExternally` scheme is handed to the OS ONLY for a user-initiated
    /// main-frame click. A script-initiated or subframe navigation (e.g. a page
    /// setting `location.href = "facetime:..."`) must not silently launch
    /// another app.
    static func mayOpenExternally(
        navigationType: WKNavigationType,
        isMainFrame: Bool?
    ) -> Bool {
        // `isMainFrame` is `navigationAction.targetFrame?.isMainFrame`, which is
        // nil when the navigation targets a NEW window (e.g. `_blank`). A nil
        // frame must NOT be treated as the main frame — only an explicit
        // in-place main-frame user click may launch another app.
        navigationType == .linkActivated && isMainFrame == true
    }
}

enum ProviderMagicLink {
    static func url(from input: String, provider: Provider) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            url.scheme?.lowercased() == "https",
            url.user == nil,
            url.password == nil,
            let host = url.host()?.lowercased(),
            provider == .claude,
            host == "claude.ai",
            url.path == "/magic-link" || url.path == "/magic-link/"
        else {
            return nil
        }
        return url
    }

    @discardableResult
    static func open(
        input: String,
        provider: Provider,
        load: (URLRequest) -> Void
    ) -> Bool {
        guard let url = url(from: input, provider: provider) else {
            return false
        }
        load(URLRequest(url: url))
        return true
    }
}

struct SignInWebView: NSViewRepresentable {
    let webView: WKWebView
    let onNavigation: (URL?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNavigation: onNavigation)
    }

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onNavigation = onNavigation
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        if nsView.navigationDelegate === coordinator {
            nsView.navigationDelegate = nil
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onNavigation: (URL?) -> Void

        init(onNavigation: @escaping (URL?) -> Void) {
            self.onNavigation = onNavigation
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            // A download-intent action (e.g. an HTML `download` link) must not
            // start a file download inside the sign-in window.
            if navigationAction.shouldPerformDownload {
                return .cancel
            }
            switch SignInNavigationPolicy.decision(for: navigationAction.request.url) {
            case .allow:
                return .allow
            case .openExternally:
                if
                    SignInNavigationPolicy.mayOpenExternally(
                        navigationType: navigationAction.navigationType,
                        isMainFrame: navigationAction.targetFrame?.isMainFrame
                    ),
                    let url = navigationAction.request.url
                {
                    NSWorkspace.shared.open(url)
                }
                return .cancel
            case .cancel:
                return .cancel
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse
        ) async -> WKNavigationResponsePolicy {
            // A response the view can't render would otherwise become a file
            // download inside the sign-in window — refuse it.
            navigationResponse.canShowMIMEType ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
            onNavigation(webView.url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            onNavigation(webView.url)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: any Error
        ) {
            onNavigation(webView.url)
        }
    }
}

struct SignInSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @ObservedObject var session: SignInSession
    let onDismiss: (() -> Void)?

    @State private var label: String
    @State private var currentHost: String?
    @State private var magicLink = ""
    @State private var magicLinkError: String?
    @State private var sessionCookie = ""
    @State private var sessionCookieStatus: SessionCookieStatus?
    @State private var isVerifying = false
    @State private var errorMessage: String?
    @State private var verificationTask: Task<Void, Never>?
    /// Set after a successful sign-in of a NEW account whose plan or billing
    /// day is still unknown: the window then shows the plan step.
    @State private var planStepAccount: AccountRecord?

    enum SessionCookieStatus: Equatable {
        case applied
        case failed(String)
    }

    init(
        model: AppModel,
        session: SignInSession,
        onDismiss: (() -> Void)? = nil
    ) {
        self.model = model
        self.session = session
        self.onDismiss = onDismiss
        _label = State(initialValue: session.initialLabel)
    }

    private var isOnProviderPage: Bool {
        session.provider.matchesAppHost(currentHost)
    }

    var body: some View {
        // The plan step covers the sign-in content instead of replacing it,
        // so the sign-in view's own appear/disappear hooks don't fire.
        ZStack {
            signInContent
                .accessibilityHidden(planStepAccount != nil)
            if let planStepAccount {
                PlanStepView(
                    account: planStepAccount,
                    onSave: { plan, day in
                        let id = planStepAccount.id
                        if let plan {
                            try await model.requestSetPlan(accountID: id, plan: plan).value
                        }
                        if let day {
                            try await model.requestSetBillingRenewalDay(accountID: id, day: day).value
                        }
                        close()
                    },
                    onSkip: { close() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.ink)
            }
        }
    }

    private var signInContent: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to \(session.provider.displayName)")
                        .font(Theme.display(19, .semibold))
                        .foregroundStyle(Theme.cream)
                    Text("This browser profile belongs only to this account.")
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.creamDim)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            if session.provider == .claude {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
                        TextField("Paste the link from your email", text: $magicLink)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Claude magic link")
                            .onSubmit {
                                openMagicLink()
                            }
                        Button("Open Link") {
                            openMagicLink()
                        }
                        .disabled(
                            magicLink.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )
                    }

                    if let magicLinkError {
                        Label(
                            magicLinkError,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.crit)
                    } else {
                        Text("Magic links must open in this isolated browser profile.")
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.creamDim)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()
            }

            if session.provider == .chatGPT {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "key.horizontal")
                            .foregroundStyle(.secondary)
                        SecureField(
                            "Passkey-only account? Paste your session cookie",
                            text: $sessionCookie
                        )
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("ChatGPT session cookie")
                        .onSubmit { applySessionCookie() }
                        Button("Apply") {
                            applySessionCookie()
                        }
                        // Also disabled while VERIFYING: a cookie write landing
                        // mid-verification would make verify vouch for a
                        // credential state that no longer exists (the model
                        // additionally refuses to commit in that case).
                        .disabled(
                            isVerifying || sessionCookie.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )
                    }

                    switch sessionCookieStatus {
                    case .applied:
                        Label(
                            "Cookie applied — once the page shows you signed in, add the account below.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.active)
                    case let .failed(message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.crit)
                    case nil:
                        Text(
                            "Passkeys can't run in this view. Log in at chatgpt.com in your browser, then copy the \(ChatGPTSessionCookiePaste.sessionTokenName) cookie value (DevTools → Application → Cookies) and paste it here. If your browser shows numbered chunks (…session-token.0 and .1), paste BOTH as name=value pairs separated by a semicolon. It stays in this account's isolated profile."
                        )
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.creamDim)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()
            }

            // Address-bar-style origin indicator. Rendered by the app, not
            // the page, so a phishing page cannot spoof it — the user can always
            // see the real host the web view is on before typing a password.
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.creamDim)
                Text(SignInCopy.hostText(currentHost))
                    .font(Theme.mono(13, bold: true))
                    .foregroundStyle(Theme.cream)
                    .textSelection(.enabled)
                    .lineLimit(1)
                if session.provider.matchesAppHost(currentHost) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                        .accessibilityLabel("Verified \(session.provider.displayName) domain")
                }
                Spacer(minLength: 8)
                Text("Check this address before entering your password.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.creamDim)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Theme.ink)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("signInOriginBar")

            Divider()

            SignInWebView(webView: session.webView) { url in
                currentHost = url?.host()
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                TextField("Local account label", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Local account label")

                HStack(spacing: 6) {
                    Image(systemName: isOnProviderPage
                        ? "checkmark.circle.fill"
                        : "globe")
                        .foregroundStyle(isOnProviderPage ? .green : .secondary)
                    // Explicit keys: a ternary of two literals would otherwise be
                    // free to resolve to the verbatim `String` initializer.
                    Text(isOnProviderPage
                        ? LocalizedStringKey("Provider page detected. Verify when sign-in is complete.")
                        : LocalizedStringKey("Finish sign-in, then return to the provider page."))
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.creamDim)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.crit)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Cancel") {
                        verificationTask?.cancel()
                        let sessionID = session.id
                        Task {
                            await model.cancelSignIn(sessionID: sessionID)
                            close()
                        }
                    }
                    Spacer()
                    Button("Verify Account") {
                        verify()
                    }
                    .buttonStyle(.goldProminent)
                    .disabled(
                        isVerifying
                            || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !isOnProviderPage
                    )
                }
            }
            .padding(16)
        }
        .frame(minWidth: 700, minHeight: 620)
        .background(Theme.ink)
        .tint(Theme.gold)
        .onAppear {
            currentHost = session.webView.url?.host()
            if session.webView.url == nil {
                session.webView.load(URLRequest(url: session.signInURL))
            }
        }
        .onDisappear {
            verificationTask?.cancel()
            let sessionID = session.id
            Task {
                await model.cancelSignIn(sessionID: sessionID)
            }
        }
    }

    private func applySessionCookie() {
        // The Return key reaches here without passing the button's disable —
        // the mid-verification gate must live in the action itself.
        guard !isVerifying else { return }
        let submitted = sessionCookie
        guard !submitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { @MainActor in
            do {
                try await model.applyPastedSessionCookies(
                    sessionID: session.id,
                    raw: submitted
                )
                // Clear only what was submitted — a correction the user
                // pasted while this apply was in flight must survive, and
                // the status must not imply the UNAPPLIED correction was
                // installed. An EMPTY field means an identical duplicate
                // submission already cleared it: that success stands.
                if sessionCookie == submitted || sessionCookie.isEmpty {
                    sessionCookie = ""
                    sessionCookieStatus = .applied
                } else {
                    sessionCookieStatus = nil
                }
            } catch SessionCookiePasteError.nothingToApply,
                    SessionCookiePasteError.missingSessionToken {
                sessionCookieStatus = .failed(SignInCopy.notASessionCookie())
            } catch {
                sessionCookieStatus = .failed(SignInCopy.cookieApplyFailed())
            }
        }
    }

    private func openMagicLink() {
        let didOpen = ProviderMagicLink.open(
            input: magicLink,
            provider: session.provider,
            load: { request in
                session.webView.load(request)
            }
        )
        guard didOpen else {
            magicLinkError = SignInCopy.invalidMagicLink()
            return
        }

        magicLinkError = nil
        magicLink = ""
    }

    private func verify() {
        isVerifying = true
        errorMessage = nil
        verificationTask = Task { @MainActor in
            defer { verificationTask = nil }
            do {
                try await model.completeSignIn(
                    sessionID: session.id,
                    label: label
                )
                if session.isNewAccount, model.needsPlanStep(accountID: session.accountID),
                   let account = model.accounts.first(where: { $0.id == session.accountID }) {
                    planStepAccount = account
                    isVerifying = false
                } else {
                    close()
                }
            } catch is CancellationError {
                isVerifying = false
            } catch is AccountCommitError {
                close()
            } catch {
                errorMessage = error.localizedDescription
                isVerifying = false
            }
        }
    }

    private func close() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

/// Sign-in window text built in code rather than drawn from a view literal.
/// Only Ration's own chrome: the web view's content is the provider's.
enum SignInCopy {
    /// The address bar: the page's host, never translated, or a loading
    /// placeholder before the page has one.
    static func hostText(_ host: String?, locale: Locale = .current) -> String {
        if let host { return host }
        return LocalizedStringResource.signInLoading.string(in: locale)
    }

    static func notASessionCookie(locale: Locale = .current) -> String {
        LocalizedStringResource.signInCookieNotASessionCookie(ChatGPTSessionCookiePaste.sessionTokenName)
            .string(in: locale)
    }

    static func cookieApplyFailed(locale: Locale = .current) -> String {
        LocalizedStringResource.signInCookieApplyFailed.string(in: locale)
    }

    static func invalidMagicLink(locale: Locale = .current) -> String {
        LocalizedStringResource.signInMagicLinkInvalid.string(in: locale)
    }
}
