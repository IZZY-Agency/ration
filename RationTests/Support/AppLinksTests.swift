import XCTest
@testable import Ration

final class AppLinksTests: XCTestCase {
    func testWebsiteIsTheProductDomainOverHTTPS() {
        XCTAssertEqual(AppLinks.website.absoluteString, "https://ration.sh")
    }

    func testRepositoryIsThePublicGitHubRepo() {
        XCTAssertEqual(
            AppLinks.repository.absoluteString,
            "https://github.com/IZZY-Agency/ration"
        )
    }

    func testIssuesLiveUnderTheRepository() {
        XCTAssertEqual(
            AppLinks.issues.absoluteString,
            AppLinks.repository.absoluteString + "/issues"
        )
    }

    func testEveryLinkIsHTTPS() {
        for link in AppLinks.all {
            XCTAssertEqual(link.url.scheme, "https", link.title)
        }
    }

    func testAboutWindowOrderIsWebsiteThenSourceThenIssues() {
        XCTAssertEqual(
            AppLinks.all.map(\.title),
            ["ration.sh", "GitHub", "Report an issue"]
        )
        XCTAssertEqual(
            AppLinks.all.map(\.url),
            [AppLinks.website, AppLinks.repository, AppLinks.issues]
        )
    }

    func testAccessibilityIdentifiersAreDistinct() {
        let identifiers = AppLinks.all.map(\.accessibilityIdentifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        for identifier in identifiers {
            XCTAssertTrue(identifier.hasPrefix("aboutLink"), identifier)
        }
    }
}
