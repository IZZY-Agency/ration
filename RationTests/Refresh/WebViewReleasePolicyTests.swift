import XCTest
@testable import Ration

final class WebViewReleasePolicyTests: XCTestCase {
    private func account(_ id: UUID, profile: UUID) -> AccountRecord {
        AccountRecord(
            id: id, provider: .claude, label: "A", webProfileID: profile,
            displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testNoInFlightWorkMeansNothingBusy() {
        let busy = WebViewReleasePolicy.busyProfileIDs(
            accounts: [account(UUID(), profile: UUID()), account(UUID(), profile: UUID())],
            inFlightRefreshAccountIDs: [],
            sendingKeepAliveAccountIDs: [],
            removingAccountIDs: [],
            profileIDsBeingRemoved: [],
            signInProfileIDs: []
        )
        XCTAssertTrue(busy.isEmpty)
    }

    func testEachMarkerMarksTheAccountProfileBusy() {
        let refreshingID = UUID(), refreshingProfile = UUID()
        let sendingID = UUID(), sendingProfile = UUID()
        let removingID = UUID(), removingProfile = UUID()
        let idleID = UUID(), idleProfile = UUID()
        let accounts = [
            account(refreshingID, profile: refreshingProfile),
            account(sendingID, profile: sendingProfile),
            account(removingID, profile: removingProfile),
            account(idleID, profile: idleProfile),
        ]

        let busy = WebViewReleasePolicy.busyProfileIDs(
            accounts: accounts,
            inFlightRefreshAccountIDs: [refreshingID],
            sendingKeepAliveAccountIDs: [sendingID],
            removingAccountIDs: [removingID],
            profileIDsBeingRemoved: [],
            signInProfileIDs: []
        )

        XCTAssertEqual(
            busy,
            [refreshingProfile, sendingProfile, removingProfile]
        )
        XCTAssertFalse(busy.contains(idleProfile))
    }

    func testProfileKeyedMarkersAreIncludedDirectly() {
        // profileIDsBeingRemoved and signInProfileIDs are already profile-keyed,
        // so they count even for a profile with no matching loaded account.
        let orphanRemovingProfile = UUID()
        let signInProfile = UUID()
        let busy = WebViewReleasePolicy.busyProfileIDs(
            accounts: [],
            inFlightRefreshAccountIDs: [],
            sendingKeepAliveAccountIDs: [],
            removingAccountIDs: [],
            profileIDsBeingRemoved: [orphanRemovingProfile],
            signInProfileIDs: [signInProfile]
        )
        XCTAssertEqual(busy, [orphanRemovingProfile, signInProfile])
    }
}
