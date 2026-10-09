import AppKit

/// Shows a `RingBarPointer`. Ration is never the active app under the bar (a
/// non-activating panel), and AppKit ignores an inactive app's cursor:
/// `set()`, cursor rects and `push()` all left the arrow (probed on macOS 27,
/// sandboxed or not). The window server's per-connection switch
/// "SetsCursorInBackground" lets it through once the pointer moves. It is
/// private, so it is looked up at run time: a macOS without it keeps the
/// arrow, as before. Leaving the bar needs nothing: macOS gives the pointer
/// back to the window under it (probed).
@MainActor
enum RingBarCursor {
    private static var allowedInBackground = false

    static func show(_ pointer: RingBarPointer) {
        allowInBackground()
        cursor(for: pointer).set()
    }

    static func cursor(for pointer: RingBarPointer) -> NSCursor {
        let arrows = pointer.arrows
        guard case let .resize(edge, _, _) = pointer, !arrows.isEmpty else { return .arrow }
        if edge.isVertical {
            var directions: NSHorizontalDirection.Set = []
            if arrows.contains(.left) { directions.insert(.left) }
            if arrows.contains(.right) { directions.insert(.right) }
            return .columnResize(directions: directions)
        }
        var directions: NSVerticalDirection.Set = []
        if arrows.contains(.up) { directions.insert(.up) }
        if arrows.contains(.down) { directions.insert(.down) }
        return .rowResize(directions: directions)
    }

    private static func allowInBackground() {
        guard !allowedInBackground else { return }
        allowedInBackground = true
        let anyImage = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let connection = dlsym(anyImage, "_CGSDefaultConnection"),
              let setProperty = dlsym(anyImage, "CGSSetConnectionProperty") else { return }
        typealias Connection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let id = unsafeBitCast(connection, to: Connection.self)()
        _ = unsafeBitCast(setProperty, to: SetProperty.self)(id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
