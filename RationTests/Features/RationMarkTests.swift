import SwiftUI
import XCTest
@testable import Ration

/// The header's Ration ring mark, drawn without a tile.
@MainActor
final class RationMarkTests: XCTestCase {
    func testGeometryFollowsTheIconRecipe() {
        let g = RationMark.Geometry(size: 16)
        XCTAssertEqual(g.ringRadius, 6, accuracy: 1e-9)
        XCTAssertEqual(g.stroke, 2.2, accuracy: 1e-9)
        XCTAssertEqual(g.hubRadius, 1.4, accuracy: 1e-9)
        XCTAssertEqual(RationMark.arcFraction, 0.68)
    }

    private func render(_ scheme: ColorScheme) throws -> NSBitmapImageRep {
        AppFonts.register(in: .main)
        let view = RationMark(size: 40).padding(4).background(Theme.ink).environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        var image: CGImage?
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(image))
    }

    private func hex(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> UInt32 {
        var p = [Int](repeating: 0, count: 4)
        rep.getPixel(&p, atX: x, y: y)
        return UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2])
    }

    /// Gold arc right of 12 o'clock (clockwise), track left of it, cream hub.
    func testArcRunsClockwiseFromTwelveInThemeTokens() throws {
        for (scheme, appearance) in [(ColorScheme.dark, NSAppearance.Name.darkAqua), (.light, .aqua)] {
            let rep = try render(scheme)
            let c = 48 // (4 + 20) * 2
            let r = 30 // ring radius 15 pt * 2
            let right = hex(rep, c + r, c)     // 3 o'clock: 25% → gold
            let left = hex(rep, c - r, c)      // 9 o'clock: 75% → track
            let hub = hex(rep, c, c)
            XCTAssertLessThan(contrast(right, resolvedHex(Theme.goldNS, appearance)), 1.1, "\(scheme) arc")
            XCTAssertLessThan(contrast(left, resolvedHex(Theme.trackNS, appearance)), 1.1, "\(scheme) track")
            XCTAssertLessThan(contrast(hub, resolvedHex(Theme.creamNS, appearance)), 1.1, "\(scheme) hub")
        }
    }
}
