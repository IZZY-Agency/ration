import XCTest
@testable import Ration

/// Settings › General › Language: the picker writes or clears the app's own
/// `AppleLanguages` override, and asks for a relaunch only when the choice
/// would change the running language.
@MainActor
final class LanguagePickerModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LanguagePickerModelTests-\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func model(current: AppLanguage, system: AppLanguage = .english) -> LanguagePickerModel {
        LanguagePickerModel(defaults: defaults, domain: suiteName, current: current, systemLanguage: system)
    }

    private var storedOverride: [String]? {
        defaults.persistentDomain(forName: suiteName)?[AppLanguage.defaultsKey] as? [String]
    }

    func testPickingALanguageWritesTheOverride() {
        let picker = model(current: .english)

        picker.select(.french)

        XCTAssertEqual(storedOverride, ["fr"])
        XCTAssertEqual(picker.stored, .french)
    }

    func testPickingSystemClearsTheOverride() {
        let picker = model(current: .english)
        picker.select(.ukrainian)

        picker.select(.system)

        XCTAssertNil(storedOverride)
        XCTAssertEqual(picker.stored, .system)
    }

    func testStartsFromTheStoredOverride() {
        AppLanguage.store(.ukrainian, in: defaults, domain: suiteName)
        XCTAssertEqual(model(current: .ukrainian).stored, .ukrainian)
    }

    func testNoRelaunchNeededWhileTheChoiceMatchesTheRunningLanguage() {
        let picker = model(current: .french)
        picker.select(.french)
        XCTAssertNil(picker.pendingLanguage)
    }

    func testAnotherLanguageAsksForARelaunchNamingIt() {
        let picker = model(current: .english)
        XCTAssertNil(picker.pendingLanguage, "nothing chosen yet")

        picker.select(.ukrainian)

        XCTAssertEqual(picker.pendingLanguage, .ukrainian)
        picker.select(.english)
        XCTAssertNil(picker.pendingLanguage, "back to the running language")
    }

    /// "System" is not a language: the note names what macOS would pick, and
    /// stays hidden when that is already what runs.
    func testSystemChoiceComparesWhatMacOSWouldPick() {
        let sameAsRunning = model(current: .french, system: .french)
        sameAsRunning.select(.system)
        XCTAssertNil(sameAsRunning.pendingLanguage)

        let differs = model(current: .french, system: .english)
        differs.select(.french)
        differs.select(.system)
        XCTAssertEqual(differs.pendingLanguage, .english)
    }

    func testSystemLanguageFollowsTheMacOSOrder() {
        XCTAssertEqual(LanguagePickerModel.systemLanguage(order: ["de-DE", "fr-FR", "en-US"]), .french)
        XCTAssertEqual(LanguagePickerModel.systemLanguage(order: ["uk-UA"]), .ukrainian)
        XCTAssertEqual(LanguagePickerModel.systemLanguage(order: ["de-DE"]), .english)
        XCTAssertEqual(LanguagePickerModel.systemLanguage(order: []), .english)
    }
}
