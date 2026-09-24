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
/// Written as plain typed steps: Xcode 26.6's type checker times out on the
/// equivalent map/enumerated/reduce chain.
func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let la: Double = relativeLuminance(a)
    let lb: Double = relativeLuminance(b)
    let hi: Double = max(la, lb)
    let lo: Double = min(la, lb)
    return (hi + 0.05) / (lo + 0.05)
}

private func linearChannel(_ hex: UInt32, shift: UInt32) -> Double {
    let c: Double = Double((hex >> shift) & 0xFF) / 255.0
    if c <= 0.03928 { return c / 12.92 }
    return pow((c + 0.055) / 1.055, 2.4)
}

private func relativeLuminance(_ hex: UInt32) -> Double {
    let r: Double = linearChannel(hex, shift: 16)
    let g: Double = linearChannel(hex, shift: 8)
    let b: Double = linearChannel(hex, shift: 0)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

/// `fg` at `alpha` over opaque `bg`, per channel, in sRGB (how SwiftUI
/// composites `.opacity` fills on a Mac).
func composite(_ fg: UInt32, alpha: Double, over bg: UInt32) -> UInt32 {
    var out: UInt32 = 0
    for shift in [UInt32(16), 8, 0] {
        let f: Double = Double((fg >> shift) & 0xFF)
        let b: Double = Double((bg >> shift) & 0xFF)
        let mixed: Double = (f * alpha + b * (1 - alpha)).rounded()
        out |= UInt32(mixed) << shift
    }
    return out
}

/// CIE76 colour difference (sRGB → Lab, D65).
func deltaE76(_ a: UInt32, _ b: UInt32) -> Double {
    let (l1, a1, b1) = lab(a)
    let (l2, a2, b2) = lab(b)
    let dl: Double = l1 - l2
    let da: Double = a1 - a2
    let db: Double = b1 - b2
    return (dl * dl + da * da + db * db).squareRoot()
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
