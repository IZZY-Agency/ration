import XCTest
@testable import Ration

/// Add API Account is a provider step, then the provider's way in; TypeSafe
/// left the subscription Add Account list for it.
final class AddAPIAccountTests: XCTestCase {
    /// TypeSafe is switched off until it has a proper API:
    /// the sheet offers the Admin-key platforms only.
    func testTheChoicesAreTheAdminKeyPlatforms() {
        XCTAssertEqual(APIAccountChoice.all, [.adminKey(.anthropic), .adminKey(.openAI)])
        XCTAssertEqual(APIAccountChoice.all.map(\.name), ["Anthropic API", "OpenAI API"])
        XCTAssertFalse(Provider.typeSafe.isOffered)
    }

    /// Switched back on, TypeSafe's sign-in step returns as the last choice.
    func testSwitchedOnTypeSafeComesBackLast() {
        Provider.switchedOff = []
        defer { Provider.switchedOff = [.typeSafe] }
        XCTAssertEqual(APIAccountChoice.all, [.adminKey(.anthropic), .adminKey(.openAI), .signIn(.typeSafe)])
        XCTAssertEqual(APIAccountChoice.all.map(\.markLetter), ["A", "O", "T"])
    }

    /// A switched-off provider's account is dormant like a paused one: no
    /// card, gauge, refresh or alert; Settings drops it but keeps paused ones.
    func testASwitchedOffProvidersAccountIsDormantAndUnlisted() {
        func account(_ provider: Provider, paused: Bool = false) -> AccountRecord {
            var record = AccountRecord(id: UUID(), provider: provider, label: provider.rawValue, webProfileID: UUID(),
                                       displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0))
            record.isPaused = paused
            return record
        }
        let claude = account(.claude), paused = account(.chatGPT, paused: true), typeSafe = account(.typeSafe)
        XCTAssertEqual(AccountVisibility.visible([claude, paused, typeSafe]).map(\.id), [claude.id])
        let presentations = [claude, paused, typeSafe].map { AccountPresentation(account: $0, snapshot: nil, state: .current) }
        XCTAssertEqual(AccountVisibility.offered(presentations).map(\.id), [claude.id, paused.id])
    }

    func testTypeSafeIsAnAPINotASubscription() {
        XCTAssertEqual(Provider.subscriptionCases, [.claude, .chatGPT, .cursor])
        XCTAssertEqual(Provider.allCases.filter(\.isAPIAccount), [.typeSafe])
        XCTAssertEqual(Provider.allCases.filter(\.hasLowBalanceAlert), [.typeSafe])
    }

    /// With the provider picked first, the other platform's Admin key is
    /// refused with a pointer back rather than silently accepted.
    func testTheOtherPlatformsAdminKeyIsRefused() {
        let anthropic = "sk-ant-admin01-abc", openAI = "sk-admin-abc"
        XCTAssertEqual(apiKeyHint(anthropic, expected: .anthropic).vendor, .anthropic)
        XCTAssertNil(apiKeyHint(anthropic, expected: .anthropic).error)
        let wrong = apiKeyHint(openAI, expected: .anthropic)
        XCTAssertNil(wrong.vendor, "Add stays disabled")
        XCTAssertEqual(wrong.error, "This is an Admin key for OpenAI API. Go back and pick it instead.")
        XCTAssertEqual(apiKeyHint(openAI).vendor, .openAI, "Replace still classifies freely")
        XCTAssertNotNil(apiKeyHint("sk-ant-api03-abc", expected: .anthropic).error, "a regular key is still refused")
        XCTAssertEqual(apiKeyHint("  ", expected: .anthropic).vendor, nil)
        XCTAssertNil(apiKeyHint("  ", expected: .anthropic).error, "empty says nothing yet")
    }

    func testEachKeyFieldAsksForItsOwnPrefix() {
        XCTAssertEqual(AddAPIOrgSheet.keyPlaceholder(.anthropic), "sk-ant-admin01-…")
        XCTAssertEqual(AddAPIOrgSheet.keyPlaceholder(.openAI), "sk-admin-…")
    }
}
