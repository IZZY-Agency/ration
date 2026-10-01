import XCTest
@testable import Ration

/// The account Settings "Usage Credits" section and the Alerts row, in every
/// shipped language.
final class UsageCreditsCopyLocalizationTests: XCTestCase {
    private let nb = L10n.nbsp
    private let utc = TimeZone(identifier: "UTC")!
    private let expiry = ISO8601DateFormatter().date(from: "2027-05-27T00:00:00Z")!

    private func euros(_ cents: Int64) -> Money { Money(minorUnits: cents, currency: "EUR", exponent: 2)! }

    private var promo: UsageCreditGrant {
        UsageCreditGrant(id: "p", kind: .promotional, remaining: euros(1000), granted: euros(1000), expiresAt: expiry)
    }

    private var bought: UsageCreditGrant {
        UsageCreditGrant(id: "b", kind: .purchased, remaining: euros(250), granted: euros(2000), expiresAt: nil)
    }

    func testGrantLines() {
        XCTAssertEqual(
            SettingsCopy.usageCreditsGrantLine(promo, locale: L10n.en, timeZone: utc),
            "€10.00 left of €10.00 · expires May 27, 2027 at 12:00\u{202F}AM"
        )
        XCTAssertEqual(SettingsCopy.usageCreditsGrantLine(bought, locale: L10n.en, timeZone: utc), "€2.50 left of €20.00 · no expiry")
        XCTAssertEqual(
            SettingsCopy.usageCreditsGrantLine(bought, locale: L10n.fr, timeZone: utc),
            "2,50\(nb)€ restants sur 20,00\(nb)€ · sans expiration"
        )
        XCTAssertEqual(
            SettingsCopy.usageCreditsGrantLine(bought, locale: L10n.uk, timeZone: utc),
            "2,50\(nb)EUR з 20,00\(nb)EUR залишилося · без терміну дії"
        )
        XCTAssertTrue(SettingsCopy.usageCreditsGrantLine(promo, locale: L10n.fr, timeZone: utc).hasPrefix("10,00\(nb)€ restants sur 10,00\(nb)€ · expire le 27 mai 2027"))
    }

    func testGrantLinesWithoutTheGrantedAmount() {
        let unknown = UsageCreditGrant(id: "u", kind: .purchased, remaining: euros(400), granted: nil, expiresAt: nil)
        XCTAssertEqual(SettingsCopy.usageCreditsGrantLine(unknown, locale: L10n.en, timeZone: utc), "€4.00 left · no expiry")
        let dated = UsageCreditGrant(id: "d", kind: .promotional, remaining: euros(400), granted: nil, expiresAt: expiry)
        XCTAssertEqual(SettingsCopy.usageCreditsGrantLine(dated, locale: L10n.en, timeZone: utc), "€4.00 left · expires May 27, 2027 at 12:00\u{202F}AM")
        XCTAssertEqual(SettingsCopy.usageCreditsGrantLine(unknown, locale: L10n.uk, timeZone: utc), "4,00\(nb)EUR залишилося · без терміну дії")
    }

    func testLabelsAndTheSwitch() {
        XCTAssertEqual(SettingsSectionTitle.usageCredits(locale: L10n.en), "Usage Credits")
        XCTAssertEqual(SettingsCopy.usageCreditsKind(.promotional, locale: L10n.en), "Promotional")
        XCTAssertEqual(SettingsCopy.usageCreditsKind(.purchased, locale: L10n.fr), "Acheté")
        XCTAssertEqual(SettingsCopy.usageCreditsSwitch(false, locale: L10n.en), "Off on claude.ai")
        XCTAssertEqual(SettingsCopy.usageCreditsSwitch(true, locale: L10n.uk), "Увімкнено")
        XCTAssertEqual(SettingsCopy.usageCreditsSwitchLabel(locale: L10n.en), "Used when you hit a plan limit")
        XCTAssertEqual(
            SettingsCopy.usageCreditsFootnote(locale: L10n.en),
            "Turn usage credits on, or buy more, on claude.ai. Ration only shows them."
        )
    }

    func testReadTime() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(SettingsCopy.usageCreditsRead(now.addingTimeInterval(-180), now: now, locale: L10n.en), "Read 3 minutes ago.")
        XCTAssertEqual(SettingsCopy.usageCreditsRead(now.addingTimeInterval(-180), now: now, locale: L10n.fr), "Lu il y a 3 minutes.")
        XCTAssertEqual(SettingsCopy.usageCreditsRead(now.addingTimeInterval(-180), now: now, locale: L10n.uk), "Прочитано 3 хвилини тому.")
    }

    func testAlertsRow() {
        XCTAssertEqual(UsageCreditsAlertsCopy.title(locale: L10n.en), "Usage credits")
        XCTAssertEqual(UsageCreditsAlertsCopy.leadNote(leadDays: 1, locale: L10n.en), "\(ResetExpiryCopy.stepperLabel(leadDays: 1, locale: L10n.en)), as for resets")
    }

    /// Ukrainian says "обліковий запис", never "акаунт", in every new string.
    func testUkrainianNeverSaysAkaunt() throws {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: Bundle(for: AppModel.self).url(forResource: "Localizable", withExtension: "xcstrings") ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Ration/Resources/Localizable.xcstrings"))) as? [String: Any]
        let strings = try XCTUnwrap(catalog?["strings"] as? [String: Any])
        let keys = strings.keys.filter { $0.contains("sageCredit") || $0.contains("drop.") && $0.contains("redit") }
        XCTAssertGreaterThan(keys.count, 20)
        for key in keys {
            let data = try JSONSerialization.data(withJSONObject: strings[key] as Any)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains("акаунт"), key)
        }
    }
}
