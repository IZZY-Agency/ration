import Foundation

/// The product's public addresses. One place to change; the About window,
/// Settings › General and the onboarding wrap-up all read from here.
enum AppLinks {
    static let website = URL(string: "https://ration.sh")!
    static let repository = URL(string: "https://github.com/IZZY-Agency/ration")!
    static let issues = repository.appending(path: "issues")

    struct Entry: Equatable {
        let title: String
        let url: URL
        let accessibilityIdentifier: String
    }

    /// What the About window shows, in display order.
    static let all: [Entry] = [
        Entry(title: "ration.sh", url: website, accessibilityIdentifier: "aboutLinkWebsite"),
        Entry(title: "GitHub", url: repository, accessibilityIdentifier: "aboutLinkRepository"),
        Entry(title: "Report an issue", url: issues, accessibilityIdentifier: "aboutLinkIssues"),
    ]
}
