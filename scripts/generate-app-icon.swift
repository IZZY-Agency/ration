import AppKit
import Foundation

// Draws the Ration "Ring" app icon: a gold usage arc filling clockwise from
// the top over a faint cream track, on a dark izzy squircle with a cream hub.

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sizes = [16, 32, 64, 128, 256, 512, 1024]

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

func renderIcon(pixels: Int) throws -> Data {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let nsContext = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        throw CocoaError(.fileWriteUnknown)
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    let ctx = nsContext.cgContext
    let d = CGFloat(pixels)

    // Dark rounded-square ground (full-bleed squircle, small transparent margin).
    let margin = d * 0.045
    let rect = CGRect(x: margin, y: margin, width: d - 2 * margin, height: d - 2 * margin)
    let radius = (d - 2 * margin) * 0.235
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(srgbRed: 0.106, green: 0.118, blue: 0.169, alpha: 1),
            CGColor(srgbRed: 0.039, green: 0.043, blue: 0.063, alpha: 1)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: d), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    // Usage ring.
    let center = CGPoint(x: d / 2, y: d / 2)
    let ringRadius = d * 0.28
    let lineWidth = d * 0.086
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)

    // Faint cream track.
    ctx.setStrokeColor(CGColor(srgbRed: 0.867, green: 0.855, blue: 0.812, alpha: 0.16))
    ctx.addArc(center: center, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // Gold arc — from the top, clockwise, ~68% sweep.
    ctx.setStrokeColor(CGColor(srgbRed: 0.961, green: 0.773, blue: 0.094, alpha: 1))
    let start = CGFloat.pi / 2
    let sweep = CGFloat.pi * 2 * 0.68
    ctx.addArc(center: center, radius: ringRadius, startAngle: start, endAngle: start - sweep, clockwise: true)
    ctx.strokePath()

    // Cream hub.
    ctx.setFillColor(CGColor(srgbRed: 0.867, green: 0.855, blue: 0.812, alpha: 1))
    let dotRadius = d * 0.053
    ctx.fillEllipse(in: CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

for size in sizes {
    try renderIcon(pixels: size).write(
        to: outputDirectory.appendingPathComponent("icon-\(size).png")
    )
}
