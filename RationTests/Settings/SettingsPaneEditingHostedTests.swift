import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// The real Alerts and Warm-up panes, hosted in a window and typed into
/// through AppKit's field editor, against a real `AppModel` over temporary
/// files. These fail if a pane drops a field binding, its Return or focus
/// handler, or the registry it hands its editors.
///
/// Text typed here is never in a form the 700 ms autosave would save ("060",
/// not "60"), so only Return, focus leaving the row, or a quit can save it.
@MainActor
final class SettingsPaneEditingHostedTests: XCTestCase {
    private var fixture: TerminationTestModel?
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.contentView = nil
        window?.close()
        window = nil
        fixture?.removeFiles()
        fixture = nil
    }

    // MARK: Alerts pane

    func testReturnInAThresholdFieldSavesTheRow() async throws {
        let fixture = try await makeFixture()
        let window = try await host(alertsPane(fixture))
        let field = try textField(in: window, identifier: "alertWarningField.claude.fiveHour", fallbackIndex: 0)

        type("060", into: field, in: window)
        pressReturn(in: field)

        await waitUntil { self.stored(fixture) == ThresholdPair(warningPercent: 60, criticalPercent: 90) }
    }

    // Not covered here: focus LEAVING the row (`.onChange(of: focus)`).
    // SwiftUI's focus state does not follow the first responder in a window
    // that is not really key, and making one key would activate the test
    // app over whatever the user is doing. `ThresholdDraftEditorTests`
    // covers the editor side of it.

    func testClosingThePaneSavesATypedRow() async throws {
        let fixture = try await makeFixture()
        let window = try await host(alertsPane(fixture))
        let field = try textField(in: window, identifier: "alertWarningField.claude.fiveHour", fallbackIndex: 0)

        type("060", into: field, in: window)
        await settleRunLoop()
        let hosting = try XCTUnwrap(window.contentView as? NSHostingView<AnyView>)
        hosting.rootView = AnyView(EmptyView())

        await waitUntil { self.stored(fixture) == ThresholdPair(warningPercent: 60, criticalPercent: 90) }
    }

    func testQuitSavesAThresholdFieldThatStillHasFocus() async throws {
        let fixture = try await makeFixture()
        let window = try await host(alertsPane(fixture))
        let field = try textField(in: window, identifier: "alertWarningField.claude.fiveHour", fallbackIndex: 0)

        type("060", into: field, in: window)
        await settleRunLoop()
        XCTAssertTrue(fixture.model.requiresTerminationPreparation, "the pane registered its editor")
        let canTerminate = await fixture.model.prepareForTermination()

        XCTAssertTrue(canTerminate)
        let settings = try await fixture.settingsOnDisk()
        XCTAssertEqual(
            settings.data.thresholds(provider: .claude, window: .fiveHour),
            ThresholdPair(warningPercent: 60, criticalPercent: 90)
        )
    }

    // MARK: Warm-up pane

    func testQuitSavesAHolidayLabelThatStillHasFocus() async throws {
        let fixture = try await makeFixture()
        let holiday = HolidayRange(
            start: LocalDate(year: 2026, month: 12, day: 24),
            end: LocalDate(year: 2026, month: 12, day: 26),
            label: ""
        )
        try await fixture.model.addHoliday(holiday)
        let window = try await host(warmUpPane(fixture))
        let field = try textField(in: window, identifier: nil, fallbackIndex: 0)

        type("Winter", into: field, in: window)
        await settleRunLoop()
        XCTAssertTrue(fixture.model.requiresTerminationPreparation, "the pane registered its editor")
        let canTerminate = await fixture.model.prepareForTermination()

        XCTAssertTrue(canTerminate)
        let settings = try await fixture.settingsOnDisk()
        XCTAssertEqual(settings.holidays.map(\.label), ["Winter"])
    }

    func testReturnInAHolidayLabelSavesIt() async throws {
        let fixture = try await makeFixture()
        let holiday = HolidayRange(
            start: LocalDate(year: 2026, month: 12, day: 24),
            end: LocalDate(year: 2026, month: 12, day: 26),
            label: ""
        )
        try await fixture.model.addHoliday(holiday)
        let window = try await host(warmUpPane(fixture))
        let field = try textField(in: window, identifier: nil, fallbackIndex: 0)

        type("Winter", into: field, in: window)
        pressReturn(in: field)

        await waitUntil { fixture.model.settings.holidays.map(\.label) == ["Winter"] }
    }

    // MARK: panes, as SettingsView builds them

    private func alertsPane(_ fixture: TerminationTestModel) -> some View {
        let model = fixture.model
        return AlertsDetailView(
            settings: model.settings,
            providers: [.claude],
            notificationPermission: .allowed,
            pendingEdits: model.pendingEdits,
            onSetThresholds: SettingsEditors.thresholdsSave(model),
            onSetCursorSpend: SettingsEditors.cursorSpendSave(model),
            onSetDropEnabled: { _, _ in },
            onSetNotificationEnabled: { _, _ in },
            onSetResetLeadDays: { _, _ in },
            onError: { error in XCTFail("\(error)") }
        )
    }

    private func warmUpPane(_ fixture: TerminationTestModel) -> some View {
        let model = fixture.model
        return WarmUpDetailView(
            settings: model.settings,
            autoStartEnabledCount: 1,
            pendingEdits: model.pendingEdits,
            onSetQuietHours: { _ in },
            onAddHoliday: { _ in },
            onSetHolidayLabel: SettingsEditors.holidayLabelSave(model),
            onSetHolidayStart: { _, _ in },
            onSetHolidayEnd: { _, _ in },
            onRemoveHoliday: { _ in },
            onError: { error in XCTFail("\(error)") }
        )
    }

    // MARK: helpers

    private func makeFixture() async throws -> TerminationTestModel {
        let fixture = try await TerminationTestModel.make()
        self.fixture = fixture
        // The Alerts form is disabled while usage alerts are off.
        try await fixture.model.setUsageAlertsEnabled(true)
        return fixture
    }

    private func stored(_ fixture: TerminationTestModel) -> ThresholdPair {
        fixture.model.settings.data.thresholds(provider: .claude, window: .fiveHour)
    }

    private func host(_ view: some View) async throws -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 760, height: 900)
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: 760, height: 900)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        self.window = window
        hosting.layoutSubtreeIfNeeded()
        await settleRunLoop()
        hosting.layoutSubtreeIfNeeded()
        return window
    }

    private func textField(in window: NSWindow, identifier: String?, fallbackIndex: Int) throws -> NSTextField {
        let fields = textFields(in: try XCTUnwrap(window.contentView))
        if let identifier {
            for field in fields where field.accessibilityIdentifier() == identifier || field.identifier?.rawValue == identifier {
                return field
            }
        }
        XCTAssertGreaterThan(fields.count, fallbackIndex, "no editable text field in the pane")
        return fields[fallbackIndex]
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.isEditable {
                found.append(field)
            }
            found.append(contentsOf: textFields(in: subview))
        }
        return found
    }

    /// Types `text` over the field's contents through the field editor, as a
    /// keyboard would.
    private func type(_ text: String, into field: NSTextField, in window: NSWindow) {
        XCTAssertTrue(window.makeFirstResponder(field), "the field takes focus")
        guard let editor = field.currentEditor() as? NSTextView else {
            XCTFail("no field editor")
            return
        }
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func pressReturn(in field: NSTextField) {
        guard let editor = field.currentEditor() as? NSTextView else {
            XCTFail("no field editor")
            return
        }
        editor.insertNewline(nil)
    }

    private func settleRunLoop() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out waiting for condition", file: file, line: line)
    }
}
