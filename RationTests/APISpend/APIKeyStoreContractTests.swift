import XCTest
@testable import Ration

final class APIKeyStoreContractTests: XCTestCase {
    func testDeleteIsIdempotent() throws {
        let store = InMemoryAPIKeyStore()
        let id = UUID()
        try store.delete(for: id)
        try store.delete(for: id)
    }

    func testReadMissingIsKeyMissing() {
        XCTAssertThrowsError(try InMemoryAPIKeyStore().read(for: UUID())) {
            XCTAssertEqual($0 as? APISpendError, .keyMissing)
        }
    }

    func testKeychainStatusMapping() {
        XCTAssertNil(KeychainAPIKeyStore.deleteError(for: errSecSuccess))
        XCTAssertNil(KeychainAPIKeyStore.deleteError(for: errSecItemNotFound))
        XCTAssertEqual(KeychainAPIKeyStore.deleteError(for: errSecAuthFailed), .keychain(status: errSecAuthFailed))
        XCTAssertEqual(KeychainAPIKeyStore.readError(for: errSecItemNotFound), .keyMissing)
        XCTAssertEqual(KeychainAPIKeyStore.readError(for: errSecInteractionNotAllowed), .keychain(status: errSecInteractionNotAllowed))
        XCTAssertNil(KeychainAPIKeyStore.readError(for: errSecSuccess))
    }
}
