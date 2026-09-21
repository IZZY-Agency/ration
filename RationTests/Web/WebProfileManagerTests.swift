import WebKit
import XCTest
@testable import Ration

final class WebProfileManagerTests: XCTestCase {
    @MainActor
    func testWebViewsUsePersistentIsolatedDataStores() async throws {
        let manager = WebProfileManager()
        let firstID = UUID()
        let secondID = UUID()
        var firstWebView: WKWebView? = manager.makeWebView(profileID: firstID)
        var restoredFirstWebView: WKWebView? = manager.makeWebView(profileID: firstID)
        var secondWebView: WKWebView? = manager.makeWebView(profileID: secondID)

        XCTAssertTrue(firstWebView!.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(firstWebView!.configuration.websiteDataStore.identifier, firstID)
        XCTAssertEqual(restoredFirstWebView!.configuration.websiteDataStore.identifier, firstID)
        XCTAssertEqual(secondWebView!.configuration.websiteDataStore.identifier, secondID)
        XCTAssertNotEqual(
            firstWebView!.configuration.websiteDataStore.identifier,
            secondWebView!.configuration.websiteDataStore.identifier
        )

        firstWebView = nil
        restoredFirstWebView = nil
        secondWebView = nil
        try await manager.removeProfile(profileID: firstID)
        try await manager.removeProfile(profileID: secondID)
    }

    @MainActor
    func testProbeProfileRemovalSkipsPersistentStoreDeletion() async throws {
        var removedProfileIDs: [UUID] = []
        let recorder = ProviderContractRecorder(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "unused-\(UUID().uuidString).json")
        )
        let manager = WebProfileManager(
            contractRecorder: recorder,
            removePersistentStore: { profileID in
                removedProfileIDs.append(profileID)
            }
        )

        try await manager.removeProfile(profileID: UUID())

        XCTAssertTrue(removedProfileIDs.isEmpty)
    }
}
