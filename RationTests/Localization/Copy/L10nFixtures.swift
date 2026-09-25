import Foundation

/// Locales and typography constants shared by the copy localization tests.
/// Every copy call in these tests passes its locale explicitly, so they hold
/// whatever language the run is pinned to.
enum L10n {
    static let en = Locale(identifier: "en_US")
    static let fr = Locale(identifier: "fr_FR")
    static let uk = Locale(identifier: "uk_UA")

    /// U+00A0: French before `: ; ! ?`, and before `%` in monospaced text.
    static let nbsp = "\u{00A0}"
    /// U+202F: French before `%` in prose.
    static let nnbsp = "\u{202F}"

    /// The counts the Ukrainian plural rules are checked at (one, few, many,
    /// and the 21/22/25 repeats), plus 0.
    static let ukrainianCounts = [0, 1, 2, 5, 21, 22, 25]
}
