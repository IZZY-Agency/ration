import AppKit
import SwiftUI

enum GaugeShape: Sendable {
    case ring
    case roundedSquare
}

/// Who a shared display element (gauge, drop row) belongs to.
enum DisplaySource: Hashable, Sendable {
    case subscription(Provider)
    case api(APIVendor)

    var accent: Color {
        switch self {
        case .subscription(let provider): provider.markAccent
        case .api(let vendor): vendor.accent
        }
    }

    var accentNS: NSColor { NSColor(accent) }

    var markLetter: String {
        switch self {
        case .subscription(let provider): provider.markLetter
        case .api(let vendor): vendor.markLetter
        }
    }

    var displayName: String {
        switch self {
        case .subscription(let provider): provider.displayName
        case .api(let vendor): vendor.displayName
        }
    }

    var gaugeShape: GaugeShape {
        switch self {
        case .subscription: .ring
        case .api: .roundedSquare
        }
    }
}
