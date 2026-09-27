import XCTest
@testable import Ration

final class APIKeyClassificationTests: XCTestCase {
    func testAdminKeysAreClassifiedByVendor() {
        XCTAssertEqual(APIVendor.classify("sk-ant-admin01-SENTINELSENTINEL"), .admin(.anthropic))
        XCTAssertEqual(APIVendor.classify("sk-admin-SENTINELSENTINEL"), .admin(.openAI))
    }

    func testRegularKeysAreRefusedWithTheirVendor() {
        XCTAssertEqual(APIVendor.classify("sk-ant-api03-SENTINEL"), .regular(.anthropic))
        XCTAssertEqual(APIVendor.classify("sk-proj-SENTINEL"), .regular(.openAI))
        XCTAssertEqual(APIVendor.classify("sk-SENTINEL"), .regular(.openAI))
    }

    func testAnythingElseIsInvalid() {
        XCTAssertEqual(APIVendor.classify(""), .invalid)
        XCTAssertEqual(APIVendor.classify("hello"), .invalid)
        XCTAssertEqual(APIVendor.classify("sk-admin-\"quote"), .invalid)
        XCTAssertEqual(APIVendor.classify("sk-admin-a b"), .invalid)
    }

    /// A key copied from the Console often carries a trailing newline.
    func testPastedWhitespaceIsTrimmedBeforeClassification() {
        let pasted = "  sk-ant-admin01-SENTINELSENTINEL\n"
        XCTAssertEqual(APIVendor.normalizedKey(pasted), "sk-ant-admin01-SENTINELSENTINEL")
        XCTAssertEqual(APIVendor.classify(pasted), .admin(.anthropic))
    }
}
