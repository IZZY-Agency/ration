import SwiftUI
import XCTest
@testable import Ration

/// The ring bar's SwiftUI content: Rail stays thin, Capsules carry labels,
/// the edge picks the axis, and every gauge reports where it is so the
/// controller can hit-test the pointer (hover events never reach an inactive
/// app's panel).
@MainActor
final class RingBarViewTests: XCTestCase {
    private func entry(_ label: String, _ fraction: Double, inUse: Bool = false) -> GaugeEntry {
        GaugeEntry(id: UUID(), gauge: MenuBarGauge(provider: .claude, label: label, fraction: fraction, windowKind: .weekly, inUse: inUse),
                   details: .credit)
    }

    private func model(style: RingBarStyle, edge: RingBarEdge) -> RingBarModel {
        let model = RingBarModel()
        model.style = style
        model.edge = edge
        model.displaysRemaining = true
        model.groups = [
            RingBarGroup(source: .subscription(.claude), entries: [entry("Client", 0.89), entry("Personal", 0.3, inUse: true)]),
            RingBarGroup(source: .subscription(.chatGPT), entries: [entry("ChatGPT 20x", 0.5)]),
        ]
        return model
    }

    private func host(_ model: RingBarModel, sources: [DisplaySource]) -> NSHostingView<RingBarSegmentView> {
        let host = NSHostingView(rootView: RingBarSegmentView(model: model, sources: sources, segment: 0))
        host.layoutSubtreeIfNeeded()
        return host
    }

    func testRailIsThinAndCapsulesAreWider() {
        let rail = model(style: .rail, edge: .left)
        let railSize = host(rail, sources: rail.groups.map(\.source)).fittingSize
        let capsules = model(style: .capsules, edge: .left)
        let capsuleSize = host(capsules, sources: [.subscription(.claude)]).fittingSize
        XCTAssertLessThan(railSize.width, 48)
        XCTAssertGreaterThan(capsuleSize.width, railSize.width)
        XCTAssertGreaterThan(railSize.height, railSize.width, "a left bar stacks vertically")
    }

    func testTopEdgeLaysOutHorizontally() {
        let rail = model(style: .rail, edge: .top)
        let size = host(rail, sources: rail.groups.map(\.source)).fittingSize
        XCTAssertGreaterThan(size.width, size.height)
    }

    func testEveryGaugeReportsItsFrame() {
        let rail = model(style: .rail, edge: .left)
        let view = host(rail, sources: rail.groups.map(\.source))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let ids = rail.groups.flatMap(\.entries).map(\.id)
        let deadline = Date().addingTimeInterval(1)
        while rail.cellFrames.count < ids.count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(Set(rail.cellFrames.keys), Set(ids))
        for id in ids {
            let frame = rail.cellFrames[id]?.rect ?? .zero
            XCTAssertGreaterThanOrEqual(frame.width, RingBarMetrics.side(.rail))
            XCTAssertEqual(rail.cellFrames[id]?.segment, 0)
        }
    }

    func testScaleGrowsTheBar() {
        let rail = model(style: .rail, edge: .left)
        let normal = host(rail, sources: rail.groups.map(\.source)).fittingSize
        rail.scale = 1.5
        let big = host(rail, sources: rail.groups.map(\.source)).fittingSize
        XCTAssertEqual(big.width, normal.width * 1.5, accuracy: 3)
        XCTAssertEqual(big.height, normal.height * 1.5, accuracy: 8)
    }

    /// The floating grip draws its pills, and nothing else.
    func testGripViewDrawsItsPills() throws {
        let view = RingBarGripView(frame: NSRect(x: 0, y: 0, width: 60, height: 14))
        view.pills = [NSRect(x: 18, y: 5, width: 24, height: 4)]
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = rep.pixelsWide / Int(view.bounds.width)
        // Bitmap rows run top-down; the view is not flipped.
        let pill = rep.colorAt(x: 30 * scale, y: (14 - 7) * scale)
        let away = rep.colorAt(x: 4 * scale, y: (14 - 7) * scale)
        XCTAssertGreaterThan(pill?.alphaComponent ?? 0, 0.5)
        XCTAssertEqual(away?.alphaComponent ?? 1, 0, accuracy: 0.05)
    }

    /// The hover highlight of a capsule gauge had ~2 pt above the ring and
    /// ~12 pt beside it. It hugs the drawing with one margin on every side.
    func testHoverHighlightIsEvenAroundTheGauge() throws {
        let scale = 2.0
        func render(hovered: Bool) throws -> NSBitmapImageRep {
            let cell = RingBarGaugeCell(entry: entry("5x", 1), source: .subscription(.chatGPT), style: .capsules, scale: scale,
                                        displaysRemaining: true, now: .now, isHovered: hovered, onSelect: {})
                .padding(10 * scale)  // the highlight reaches past the cell, into the glass's padding
                .environment(\.colorScheme, .dark)
            let view = NSHostingView(rootView: cell)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            // At 1x on every machine (CI's virtual display is 1x, a Mac's 2x).
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        /// Bounds of everything drawn (alpha > 0), in pixels.
        func inked(_ rep: NSBitmapImageRep) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
            var box = (minX: Int.max, maxX: -1, minY: Int.max, maxY: -1)
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                    box = (min(box.minX, x), max(box.maxX, x), min(box.minY, y), max(box.maxY, y))
                }
            }
            return box
        }
        let plainRep = try render(hovered: false)
        let plain = inked(plainRep)
        let lit = inked(try render(hovered: true))
        let gaps = [plain.minX - lit.minX, lit.maxX - plain.maxX, plain.minY - lit.minY, lit.maxY - plain.maxY]
        let pixelsPerPoint = Double(plainRep.pixelsWide) / plainRep.size.width
        XCTAssertEqual(pixelsPerPoint, 1)
        for gap in gaps {
            XCTAssertEqual(Double(gap), Double(gaps[0]), accuracy: 2 * pixelsPerPoint, "gaps left/right/top/bottom: \(gaps)")
        }
        XCTAssertGreaterThanOrEqual(Double(gaps.min() ?? 0), 3 * scale * pixelsPerPoint * 0.8, "a margin, not a hairline: \(gaps)")
    }

    /// Measured on the real bar: over a white window the glass stayed light
    /// grey (#B2B2B2) even tinted, and cream text fell to 1.7:1. Each segment
    /// lays an ink shade inside its glass, under the gauges, so the glass
    /// darkens the same over anything.
    func testEverySegmentShadesItsGlass() throws {
        let rail = model(style: .capsules, edge: .bottom)
        let view = host(rail, sources: [.subscription(.claude)])
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        // The padding beside the provider chip: glass, nothing drawn on it but the shade.
        let shade = try XCTUnwrap(rep.colorAt(x: 4, y: rep.pixelsHigh - 4 - Int(RingBarMetrics.cornerRadius(.capsules))))
        XCTAssertEqual(shade.alphaComponent, RingBarMetrics.glassShade, accuracy: 0.05)
        XCTAssertLessThan(shade.redComponent, 0.15, "ink, not a light colour")
        XCTAssertEqual(RingBarMetrics.glassShade, 0.6)
    }

    /// Labels in cream, not dim grey: legible on the shaded glass.
    func testLabelsAreDrawnInCream() throws {
        let cell = RingBarGaugeCell(entry: entry("Personal", 1), source: .subscription(.claude), style: .capsules,
                                    displaysRemaining: true, now: .now, isHovered: false, onSelect: {})
            .environment(\.colorScheme, .dark)
        let view = NSHostingView(rootView: cell)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        // The label is below the ring: its brightest pixel is the label colour.
        let labelTop = Int(RingBarMetrics.side(.capsules) + 6)
        var brightest: CGFloat = 0
        for y in labelTop..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.9 else { continue }
                brightest = max(brightest, min(colour.redComponent, colour.greenComponent, colour.blueComponent))
            }
        }
        XCTAssertGreaterThan(brightest, 0.84, "cream (#E8E8EB), not dim grey (#AEB0B6): \(brightest)")
    }

    /// A long name still truncates inside its cell (the label hugs short
    /// names, but never grows past the cell's width).
    func testALongLabelStaysInsideItsCell() {
        let scale = 1.0
        let long = RingBarGaugeCell(entry: entry("Platform for the whole team", 0.5), source: .api(.openAI), style: .capsules,
                                    scale: scale, displaysRemaining: true, now: .now, isHovered: true, onSelect: {})
        let view = NSHostingView(rootView: long)
        XCTAssertEqual(view.fittingSize.width, RingBarMetrics.capsuleCellWidth(scale: scale) + 2 * RingBarMetrics.cellPadding(scale: scale),
                       accuracy: 0.5, "the cell keeps its width")
        let label = NSHostingView(rootView: RingBarCappedWidth(width: 50) { Text(verbatim: "Platform for the whole team").lineLimit(1) })
        XCTAssertLessThanOrEqual(label.fittingSize.width, 50)
        let short = NSHostingView(rootView: RingBarCappedWidth(width: 50) { Text(verbatim: "5x").lineLimit(1) })
        XCTAssertLessThan(short.fittingSize.width, 25, "a short label hugs its text")
    }

    func testMetrics() {
        XCTAssertEqual(RingBarMetrics.side(.rail), 20)
        XCTAssertEqual(RingBarMetrics.side(.capsules), 30)
    }
}
