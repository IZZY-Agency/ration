import WebKit

@MainActor
protocol WebProfileManaging: AnyObject {
    func makeWebView(profileID: UUID) -> WKWebView
    func removeProfile(profileID: UUID) async throws

    /// Drop the disposable HTTP caches for one profile, keeping everything that
    /// carries authentication. Probed on this OS: cookies survive intact.
    func purgeDiskCache(profileID: UUID) async

    /// Every persistent store WebKit currently knows about, including ones no
    /// account references any more.
    func existingProfileIdentifiers() async -> [UUID]
}

/// Defaulted so the test doubles that only care about `makeWebView`/`removeProfile`
/// keep compiling: doing nothing and knowing of no stores is the inert answer.
extension WebProfileManaging {
    func purgeDiskCache(profileID: UUID) async {}
    func existingProfileIdentifiers() async -> [UUID] { [] }
}

@MainActor
final class WebProfileManager: WebProfileManaging {
    private let contractRecorder: ProviderContractRecorder?
    private let onContractRecordingError: (String) -> Void
    private let removePersistentStore: @MainActor (UUID) async throws -> Void
    private let purgeStoreCaches: @MainActor (UUID) async -> Void
    private let fetchStoreIdentifiers: @MainActor () async -> [UUID]

    /// What a purge is allowed to take: HTTP response bodies and their in-memory
    /// twin. Deliberately NOT cookies, local/session storage, IndexedDB or
    /// service-worker registrations — a provider's signed-in state can live in any
    /// of those, and re-authenticating these accounts is expensive for the user.
    private static let disposableCacheTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeFetchCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
    ]

    init(
        contractRecorder: ProviderContractRecorder? = nil,
        onContractRecordingError: @escaping (String) -> Void = { _ in },
        removePersistentStore: @escaping @MainActor (UUID) async throws -> Void = {
            profileID in
            // WebKit finalizes a profile's network process asynchronously after the
            // last WKWebView is released. Give that teardown one run-loop window.
            try await Task.sleep(for: .milliseconds(100))
            try await WKWebsiteDataStore.remove(forIdentifier: profileID)
        },
        purgeStoreCaches: @escaping @MainActor (UUID) async -> Void = { profileID in
            // Constructing the store for an EXISTING identifier is idempotent — it
            // does not mint a new one — and is also what warms WebKit for the static
            // identifier APIs, which trap when called from a cold process.
            await WKWebsiteDataStore(forIdentifier: profileID).removeData(
                ofTypes: WebProfileManager.disposableCacheTypes,
                modifiedSince: .distantPast
            )
        },
        fetchStoreIdentifiers: @escaping @MainActor () async -> [UUID] = {
            await WKWebsiteDataStore.allDataStoreIdentifiers
        }
    ) {
        self.contractRecorder = contractRecorder
        self.onContractRecordingError = onContractRecordingError
        self.removePersistentStore = removePersistentStore
        self.purgeStoreCaches = purgeStoreCaches
        self.fetchStoreIdentifiers = fetchStoreIdentifiers
    }

    func makeWebView(profileID: UUID) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = contractRecorder == nil
            ? WKWebsiteDataStore(forIdentifier: profileID)
            : .nonPersistent()

        if let contractRecorder {
            let userContentController = configuration.userContentController
            userContentController.add(
                ProviderContractProbeMessageHandler(
                    recorder: contractRecorder,
                    onRecordingError: onContractRecordingError
                ),
                name: ProviderContractProbeScript.messageHandlerName
            )
            userContentController.addUserScript(
                WKUserScript(
                    source: ProviderContractProbeScript.source,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true,
                    in: .page
                )
            )
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsLinkPreview = false
        return webView
    }

    func removeProfile(profileID: UUID) async throws {
        guard contractRecorder == nil else { return }
        try await removePersistentStore(profileID)
    }

    func purgeDiskCache(profileID: UUID) async {
        // Contract-capture runs on `.nonPersistent()` stores, so there is nothing on
        // disk to purge and no identified store to construct.
        guard contractRecorder == nil else { return }
        await purgeStoreCaches(profileID)
    }

    func existingProfileIdentifiers() async -> [UUID] {
        guard contractRecorder == nil else { return [] }
        return await fetchStoreIdentifiers()
    }
}
