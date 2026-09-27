import XCTest
@testable import Ration

final class APIOrgSettingsCopyTests: XCTestCase {
    private let locales = ["en", "fr", "uk"].map(Locale.init(identifier:))
    private let errors: [APIOrgEditError] = [
        .invalidKey, .regularKey(.anthropic), .regularKey(.openAI), .duplicate(label: "IZZY"), .secondOpenAIWithoutIdentity,
        .identityMismatch, .replaceUnavailable, .busy, .validation(.keyRejected), .keychain(.keyMissing), .saveFailed,
    ]

    func testEveryErrorHasCopyInEveryLanguage() {
        for locale in locales {
            for error in errors {
                let text = error.message(locale: locale)
                XCTAssertFalse(text.isEmpty, "\(error) \(locale)")
                XCTAssertFalse(text.hasPrefix("apiSpend."), "untranslated key for \(error) in \(locale): \(text)")
            }
        }
    }

    func testRegularKeyNamesWhereToCreateAnAdminKey() {
        for locale in locales {
            XCTAssertTrue(APIOrgEditError.regularKey(.anthropic).message(locale: locale).contains("Claude Console"))
            XCTAssertTrue(APIOrgEditError.regularKey(.openAI).message(locale: locale).contains("OpenAI Platform"))
        }
        XCTAssertTrue(APIOrgEditError.duplicate(label: "IZZY").message(locale: Locale(identifier: "en")).contains("IZZY"))
    }

    /// Token counts in the org pane follow the app language, like its dollars.
    func testTokenCountsFollowTheLanguage() {
        XCTAssertEqual(UsageFormatters.tokenCount(4_812_000, locale: Locale(identifier: "en")), "4.8M")
        XCTAssertEqual(UsageFormatters.tokenCount(4_812_000, locale: Locale(identifier: "fr")).filter { !$0.isWhitespace && $0 != "\u{202F}" && $0 != "\u{00A0}" }, "4,8M")
        XCTAssertEqual(UsageFormatters.tokenCount(912, locale: Locale(identifier: "en")), "912")
    }
}
