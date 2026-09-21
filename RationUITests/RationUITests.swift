import AppKit
import XCTest

final class RationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testEmptyStateExposesPrimaryActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]

        app.launch()
        app.activate()

        XCTAssertTrue(
            app.windows["Ration"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Ration"].exists)
        XCTAssertFalse(app.staticTexts["Used capacity"].exists)
        XCTAssertTrue(
            app.staticTexts["No accounts connected"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["Add Account"].exists)
        XCTAssertTrue(app.buttons["Refresh"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertTrue(app.buttons["Quit"].exists)
        app.terminate()
    }

    @MainActor
    func testAddAccountAndSettingsWindowsOpenFromMenuContent() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.activate()

        app.buttons["Add Account"].firstMatch.click()
        XCTAssertTrue(app.windows["Add Account"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Add Claude account"].exists)
        XCTAssertTrue(app.buttons["Add ChatGPT account"].exists)
        app.windows["Add Account"].buttons[XCUIIdentifierCloseWindow].click()

        app.buttons["Settings"].click()
        XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.windows["Settings"].buttons["Add Account"].exists
        )
        // Select the General detail pane and assert it rendered. Deliberately
        // NOT asserting `launchAtLoginToggle`: that row is hidden when
        // SMAppService reports `.notFound`, which is exactly what an ad-hoc
        // signed build gets (no Team Identifier). Its presence therefore depends
        // on how the test build was signed, so it is not a stable assertion —
        // `openWindowShortcut` is always in this pane.
        let general = app.descendants(matching: .any)["generalSettingsItem"]
        XCTAssertTrue(general.waitForExistence(timeout: 3))
        general.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["openWindowShortcut"].waitForExistence(timeout: 3)
        )
        app.terminate()
    }

    @MainActor
    func testAboutWindowShowsProductMetadata() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.activate()

        let aboutButton = app.buttons["About"]
        XCTAssertTrue(aboutButton.waitForExistence(timeout: 3))
        aboutButton.click()

        let aboutWindow = app.windows["About Ration"]
        XCTAssertTrue(aboutWindow.waitForExistence(timeout: 3))
        XCTAssertTrue(aboutWindow.staticTexts["Ration"].exists)
        XCTAssertTrue(aboutWindow.staticTexts["Version 1.0.1 (63)"].exists)
        XCTAssertTrue(
            aboutWindow.staticTexts[
                "Copyright © 2026 IZZY.Agency"
            ].exists
        )

        let attachment = XCTAttachment(
            screenshot: XCUIScreen.main.screenshot()
        )
        attachment.name = "Ration-About"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    @MainActor
    func testCaptureModeKeepsRealMenuBarItemVisible() {
        let app = XCUIApplication()
        app.launchArguments = ["--capture-provider-contracts"]
        app.launch()

        XCTAssertFalse(
            app.windows["Ration"].waitForExistence(timeout: 1),
            "Capture mode must remain a menu-bar-only experience"
        )

        app.activate()
        let statusItem = app.menuBars.statusItems["Ration"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3))
        XCTAssertNotEqual(app.state, .notRunning)
        app.terminate()
    }

    @MainActor
    func testCaptureModeReopenFallbackOpensNativeAccountFlow() throws {
        let app = XCUIApplication()
        let preexistingProcessIDs = Set(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "agency.izzy.ration"
            ).map(\.processIdentifier)
        )
        app.launchArguments = ["--capture-provider-contracts"]
        app.launch()

        XCTAssertFalse(
            app.windows["Ration"].waitForExistence(timeout: 1),
            "Capture mode must remain a menu-bar-only experience"
        )

        let statusItem = app.menuBars.statusItems["Ration"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3))

        let runningApp = try XCTUnwrap(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "agency.izzy.ration"
            ).first {
                !preexistingProcessIDs.contains($0.processIdentifier)
            }
        )
        XCTAssertTrue(
            NSWorkspace.shared.open(try XCTUnwrap(runningApp.bundleURL))
        )

        let fallbackWindow = app.windows["Ration"]
        XCTAssertTrue(fallbackWindow.waitForExistence(timeout: 3))

        let addAccount = fallbackWindow.buttons["Add Account"].firstMatch
        XCTAssertTrue(addAccount.waitForExistence(timeout: 3))
        addAccount.click()

        let addAccountWindow = app.windows["Add Account"]
        XCTAssertTrue(addAccountWindow.waitForExistence(timeout: 3))
        XCTAssertTrue(
            addAccountWindow.buttons["Add Claude account"].isHittable,
            "The Add Account window must be frontmost and interactive"
        )
        addAccountWindow.buttons["Add Claude account"].click()

        let signInWindow = app.windows["Sign In"]
        XCTAssertTrue(signInWindow.waitForExistence(timeout: 3))
        XCTAssertTrue(
            signInWindow.isHittable,
            "The provider sign-in window must be frontmost and interactive"
        )
        XCTAssertTrue(
            signInWindow.textFields["Claude magic link"].waitForExistence(timeout: 2),
            "The in-app browser must let the user paste Claude's emailed magic link"
        )
        app.terminate()
    }
}
