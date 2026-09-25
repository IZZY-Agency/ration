import XCTest
@testable import Ration

/// Proves the toolchain end to end: the string catalog is compiled into the
/// app, Xcode generates a symbol for a manually-managed key with a format
/// argument, and that symbol resolves per locale regardless of the language the
/// test run itself is pinned to.
final class LocalizationProofTests: XCTestCase {
    private func resolve(_ locale: String) -> String {
        var resource = LocalizedStringResource.proofHello("X")
        resource.locale = Locale(identifier: locale)
        return String(localized: resource)
    }

    func testGeneratedSymbolResolvesEnglish() {
        XCTAssertEqual(resolve("en"), "Hello, X")
    }

    func testGeneratedSymbolResolvesFrench() {
        XCTAssertEqual(resolve("fr"), "Bonjour, X")
    }

    func testGeneratedSymbolResolvesUkrainian() {
        XCTAssertEqual(resolve("uk"), "Привіт, X")
    }

    func testArgumentlessKeyIsAStaticSymbol() {
        var resource = LocalizedStringResource.commonSystem
        resource.locale = Locale(identifier: "uk")
        XCTAssertEqual(String(localized: resource), "Системна")
    }
}
