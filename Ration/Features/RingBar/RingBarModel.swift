import Foundation

/// A drag on the ring bar's empty glass (`RingBarDragRouter`).
enum RingBarResizePhase: Sendable {
    case began
    case changed
    case ended
}

/// The ring bar's data, mutated in place by `RingBarController` so SwiftUI
/// diffs rather than the hosting views being replaced (the drop learned that
/// replacing `rootView` breaks button actions).
@MainActor
final class RingBarModel: ObservableObject {
    @Published var groups: [RingBarGroup] = []
    @Published var style: RingBarStyle = .rail
    @Published var edge: RingBarEdge = .left
    @Published var displaysRemaining = false
    /// `KeepAwakeEye.forBars`: while Keep awake is on, an eye heads the bar —
    /// outline at rest, filled blue while a hold is live.
    @Published var keepAwake: KeepAwakeEye = .hidden
    /// For the gauges' VoiceOver details (reset countdowns); moves by the
    /// minute, so updates within a minute re-render nothing for it.
    @Published var now: Date = .distantPast
    /// Every metric of the bar multiplies by this (Settings › Display › Size).
    @Published var scale: Double = 1
    /// The gauge under the pointer, from the controller's poll (hover events
    /// never reach an inactive app's panel).
    @Published var hoveredID: UUID?

    /// A gauge's click.
    var onSelect: (UUID) -> Void = { _ in }

    /// Where each gauge is: its segment (one glass view) and its frame in
    /// that segment's hosting view (top-left origin). Not published — only
    /// the controller's hit test reads it.
    private(set) var cellFrames: [UUID: (segment: Int, rect: CGRect)] = [:]

    func group(_ source: DisplaySource) -> RingBarGroup? {
        groups.first { $0.source == source }
    }

    func reportFrames(_ frames: [UUID: CGRect], segment: Int) {
        cellFrames = cellFrames.filter { $0.value.segment != segment }
        for (id, rect) in frames { cellFrames[id] = (segment, rect) }
    }

    /// Segments are rebuilt (style, edge or providers changed): forget them.
    func resetFrames() {
        cellFrames = [:]
    }
}
