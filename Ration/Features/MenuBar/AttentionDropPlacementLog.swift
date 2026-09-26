import AppKit
import OSLog

/// Where the attention drop actually landed, for live placement checks.
///
/// `AttentionDropGeometry` is pure and unit-tested, but its INPUT — the status
/// item's button frame after `convert(_:to: nil)` and `convertToScreen(_:)` —
/// is not, and a wrong input yields a correctly computed frame in the wrong
/// place. This records the input, the screen it resolved to, the anchor mode,
/// and the output, so a misplaced drop can be diagnosed from the log alone.
///
/// Numbers, fixed tokens and 0/1 flags ONLY — no account label, no usage, and
/// no free text of any kind: a display's `localizedName` can be renamed to
/// include a person's name, and the frontmost app's bundle id says what the
/// user is doing. The type enforces it: no stored property is a `String`
/// (`AttentionDropPlacementLogTests` checks), so `line` can only ever hold
/// numbers and the literals written below — which is why it is logged
/// `.public`.
struct AttentionDropPlacementReport: Equatable {
    enum Event: String {
        /// The panel was just ordered front.
        case present
        /// An already-visible panel moved or resized.
        case reposition
    }

    var event: Event
    /// Whether the rows are the Settings › Diagnostics sample.
    var isTestDrop: Bool
    /// The status-item button frame in screen coordinates; nil when there is
    /// no status item, no button, or the button has no window.
    var buttonFrame: NSRect?
    var screenFrame: NSRect
    var visibleFrame: NSRect
    /// Whether the chosen display is `NSScreen.main`. False when no
    /// `NSScreen` matched the chosen frame at all.
    var isMainScreen: Bool
    /// `safeAreaInsets.top > 0` on the chosen display.
    var hasNotch: Bool
    var screenCount: Int
    var anchor: AttentionDropGeometry.Anchor
    var panelFrame: NSRect
    var appIsActive: Bool
    var panelIsKey: Bool
    /// Whether the frontmost application is Ration itself — the one fact
    /// about the frontmost app the focus checks need.
    var rationIsFrontmost: Bool

    /// One log line. Pure, so its format is testable without a window server.
    var line: String {
        var fields: [String] = []
        fields.append("event=\(event.rawValue)")
        fields.append("test=\(Self.flag(isTestDrop))")
        fields.append("button=\(Self.frameText(buttonFrame))")
        fields.append("screen=\(Self.frameText(screenFrame))")
        fields.append("visible=\(Self.frameText(visibleFrame))")
        fields.append("main=\(Self.flag(isMainScreen))")
        fields.append("notch=\(Self.flag(hasNotch))")
        fields.append("screens=\(screenCount)")
        fields.append("anchor=\(Self.anchorText(anchor))")
        fields.append("panel=\(Self.frameText(panelFrame))")
        fields.append("active=\(Self.flag(appIsActive))")
        fields.append("key=\(Self.flag(panelIsKey))")
        fields.append("frontRation=\(Self.flag(rationIsFrontmost))")
        return fields.joined(separator: " ")
    }

    /// `(x,y wxh)` with one decimal: menu-bar frames are routinely on
    /// half-points, and a locale-free format keeps the log greppable.
    static func frameText(_ frame: NSRect?) -> String {
        guard let frame else { return "none" }
        let origin = "\(number(frame.minX)),\(number(frame.minY))"
        let size = "\(number(frame.width))x\(number(frame.height))"
        return "(\(origin) \(size))"
    }

    static func anchorText(_ anchor: AttentionDropGeometry.Anchor) -> String {
        switch anchor {
        case .statusItem: "statusItem"
        case .screenTrailing: "screenTrailing"
        }
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private static func flag(_ value: Bool) -> String {
        value ? "1" : "0"
    }
}

/// The placement half of a report: what decides where the panel sits, and
/// the frame it got. Compared between refreshes so only a real move logs a
/// `reposition` — the drop re-places itself on every tick and publish.
struct AttentionDropPlacement: Equatable {
    var buttonFrame: NSRect?
    var screenFrame: NSRect
    var visibleFrame: NSRect
    var isMainScreen: Bool
    var hasNotch: Bool
    var screenCount: Int
    var anchor: AttentionDropGeometry.Anchor
    var panelFrame: NSRect
}

/// Where placement reports go: subsystem `agency.izzy.ration`, category
/// `drop`, at `.debug`.
///
/// On in every build, Release included, because live placement checks are
/// walked on the Release app in /Applications. `.debug` costs nothing unless someone
/// is streaming it (`log stream --level debug`) or has asked for it to be
/// persisted (`log config`); it is never written to disk by default.
enum AttentionDropPlacementLog {
    static let subsystem = "agency.izzy.ration"
    static let category = "drop"

    private static let logger = Logger(subsystem: subsystem, category: category)

    static func record(_ report: AttentionDropPlacementReport) {
        let line = report.line
        logger.debug("\(line, privacy: .public)")
    }
}
