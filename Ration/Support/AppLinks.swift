import Foundation

/// The product's public addresses. One place to change; the About window,
/// Settings › General and the onboarding wrap-up all read from here.
enum AppLinks {
    static let website = URL(string: "https://ration.sh")!
    static let repository = URL(string: "https://github.com/IZZY-Agency/ration")!
    static let issues = repository.appending(path: "issues")
    /// Where a newer version is published — the "Check for updates" link.
    static let releases = repository.appending(path: "releases")

    struct Entry: Equatable {
        let title: String
        let url: URL
        let accessibilityIdentifier: String

        /// What the About window draws. `title` stays the identity (and the
        /// brand names ration.sh and GitHub are never translated); only the
        /// issue link is prose.
        func displayTitle(locale: Locale = .current) -> String {
            guard url == AppLinks.issues else { return title }
            return LocalizedStringResource.aboutLinkReportIssue.string(in: locale)
        }
    }

    /// What the About window shows, in display order.
    static let all: [Entry] = [
        Entry(title: "ration.sh", url: website, accessibilityIdentifier: "aboutLinkWebsite"),
        Entry(title: "GitHub", url: repository, accessibilityIdentifier: "aboutLinkRepository"),
        Entry(title: "Report an issue", url: issues, accessibilityIdentifier: "aboutLinkIssues"),
    ]
}
