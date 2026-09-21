import Foundation

struct AboutAppInfo: Equatable {
    let displayName: String
    let versionText: String
    let copyrightText: String

    init(infoDictionary: [String: Any]) {
        displayName = Self.nonEmptyString(
            infoDictionary["CFBundleDisplayName"]
        ) ?? "Application"

        if
            let version = Self.nonEmptyString(
                infoDictionary["CFBundleShortVersionString"]
            ),
            let build = Self.nonEmptyString(
                infoDictionary["CFBundleVersion"]
            )
        {
            versionText = "Version \(version) (\(build))"
        } else {
            versionText = "Version unavailable"
        }

        copyrightText = Self.nonEmptyString(
            infoDictionary["NSHumanReadableCopyright"]
        ) ?? "Copyright unavailable"
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
