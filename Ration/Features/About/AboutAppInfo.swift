import Foundation

struct AboutAppInfo: Equatable {
    let displayName: String
    let versionText: String
    let copyrightText: String

    init(infoDictionary: [String: Any], locale: Locale = .current) {
        displayName = Self.nonEmptyString(
            infoDictionary["CFBundleDisplayName"]
        ) ?? LocalizedStringResource.aboutDisplayNameFallback.string(in: locale)

        if
            let version = Self.nonEmptyString(
                infoDictionary["CFBundleShortVersionString"]
            ),
            let build = Self.nonEmptyString(
                infoDictionary["CFBundleVersion"]
            )
        {
            versionText = LocalizedStringResource.aboutVersion(version, build).string(in: locale)
        } else {
            versionText = LocalizedStringResource.aboutVersionUnavailable.string(in: locale)
        }

        copyrightText = Self.copyrightText(
            bundleLine: Self.nonEmptyString(infoDictionary["NSHumanReadableCopyright"]),
            locale: locale
        )
    }

    /// The bundle's line ("Copyright © 2026 IZZY.Agency", set once in
    /// project.yml) is English. Its year and holder are re-set in the
    /// catalog's sentence for the UI language; a line in any other shape is
    /// shown as it is rather than guessed at.
    private static func copyrightText(bundleLine: String?, locale: Locale) -> String {
        guard let bundleLine else {
            return LocalizedStringResource.aboutCopyrightUnavailable.string(in: locale)
        }
        // "Copyright © <year or year range> <holder>".
        let pattern = /Copyright © (\d{4}(?:[–-]\d{4})?) (\S.*)/
        guard let match = bundleLine.wholeMatch(of: pattern) else {
            return bundleLine
        }
        let year = String(match.1)
        let holder = String(match.2)
        return LocalizedStringResource.aboutCopyright(year, holder).string(in: locale)
    }

    static var current: AboutAppInfo {
        AboutAppInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard
            let value = value as? String,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return value
    }
}
