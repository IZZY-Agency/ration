import AppKit

/// Resolves a (possibly dynamic) colour the way AppKit draws it under
/// `name` — inside `performAsCurrentDrawingAppearance`, BEFORE converting to
/// sRGB. Converting first would freeze whatever appearance happens to be
/// current in the test host.
func resolvedHex(_ color: NSColor, _ name: NSAppearance.Name) -> UInt32 {
    var out: UInt32 = 0
    NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
        let c = color.usingColorSpace(.sRGB)!
        let r = UInt32((c.redComponent * 255).rounded())
        let g = UInt32((c.greenComponent * 255).rounded())
        let b = UInt32((c.blueComponent * 255).rounded())
        out = r << 16 | g << 8 | b
    }
    return out
}

/// WCAG 2.x relative-luminance contrast ratio.
func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    func lum(_ h: UInt32) -> Double {
        [16, 8, 0].map { Double((h >> UInt32($0)) & 0xFF) / 255 }
            .map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            .enumerated()
            .reduce(0) { $0 + $1.element * [0.2126, 0.7152, 0.0722][$1.offset] }
    }
    let (hi, lo) = (max(lum(a), lum(b)), min(lum(a), lum(b)))
    return (hi + 0.05) / (lo + 0.05)
}

/// `fg` at `alpha` over opaque `bg`, per channel, in sRGB (how SwiftUI
/// composites `.opacity` fills on a Mac).
func composite(_ fg: UInt32, alpha: Double, over bg: UInt32) -> UInt32 {
    [16, 8, 0].reduce(0) { acc, s in
        let f = Double((fg >> UInt32(s)) & 0xFF), b = Double((bg >> UInt32(s)) & 0xFF)
        return acc | UInt32((f * alpha + b * (1 - alpha)).rounded()) << UInt32(s)
    }
}

/// CIE76 colour difference (sRGB → Lab, D65).
func deltaE76(_ a: UInt32, _ b: UInt32) -> Double {
    let (l1, a1, b1) = lab(a), (l2, a2, b2) = lab(b)
    return ((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)).squareRoot()
}

func lab(_ hex: UInt32) -> (Double, Double, Double) {
    func linear(_ shift: UInt32) -> Double {
        let c = Double((hex >> shift) & 0xFF) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    let r = linear(16), g = linear(8), b = linear(0)
    let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
    return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
}
