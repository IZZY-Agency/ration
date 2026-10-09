import Foundation

/// Hide at edge as a pure state machine, fed pointer samples by
/// `RingBarController`'s poll. A bar that does not hide at the edge is
/// always shown and ignores every sample.
struct RingBarReveal: Equatable {
    enum Phase: Equatable {
        case shown
        case hidden
        /// The pointer is at the edge; it must stay `dwell` to reveal, so a
        /// pointer flung past the edge does nothing.
        case arming(since: Date)
        /// The pointer left; the bar stays `hideDelay` before hiding.
        case hiding(since: Date)
    }

    static let dwell: TimeInterval = 0.15
    static let hideDelay: TimeInterval = 0.6

    let hidesAtEdge: Bool
    private(set) var phase: Phase

    init(hidesAtEdge: Bool) {
        self.hidesAtEdge = hidesAtEdge
        phase = hidesAtEdge ? .hidden : .shown
    }

    var isVisible: Bool {
        switch phase {
        case .shown, .hiding: true
        case .hidden, .arming: false
        }
    }

    /// One pointer sample. Returns whether `isVisible` changed.
    @discardableResult
    mutating func step(inActivation: Bool, inKeepZone: Bool, cardShown: Bool, now: Date) -> Bool {
        guard hidesAtEdge else { return false }
        let before = isVisible
        switch phase {
        case .hidden:
            if inActivation { phase = .arming(since: now) }
        case .arming(let since):
            if !inActivation {
                phase = .hidden
            } else if now.timeIntervalSince(since) >= Self.dwell {
                phase = .shown
            }
        case .shown:
            if !(inKeepZone || cardShown) { phase = .hiding(since: now) }
        case .hiding(let since):
            if inKeepZone || cardShown {
                phase = .shown
            } else if now.timeIntervalSince(since) >= Self.hideDelay {
                phase = .hidden
            }
        }
        return before != isVisible
    }

    /// Wake, a display change, a new edge: start hidden again.
    mutating func hideNow() {
        if hidesAtEdge { phase = .hidden }
    }
}
