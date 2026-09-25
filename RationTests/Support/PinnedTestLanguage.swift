import Foundation
import XCTest

/// The language `xcodebuild -testLanguage` pinned this run to. It arrives as
/// `-AppleLanguages (<code>)` in the argument domain, independent of the code
/// under test. `make unit-test` pins `en`; `make l10n-test` pins `fr` or `uk`.
enum PinnedTestLanguage {
    /// The pinned code, or nil when the run is unpinned (`make test`, Xcode ⌘U).
    static var code: String? {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        return (arguments["AppleLanguages"] as? [String])?.first
    }

    /// The pinned code; skips the calling test when the run is unpinned.
    /// Call it outside an assertion, which would swallow the skip.
    static func require() throws -> String {
        guard let code else {
            throw XCTSkip("run without -testLanguage; use make unit-test or make l10n-test")
        }
        return code
    }
}
