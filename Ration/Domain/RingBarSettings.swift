import Foundation

/// How the ring bar draws its gauges (Settings › General › Ring Bar).
enum RingBarStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// One glass strip, small gauges, a provider letter per group.
    case rail
    /// One glass capsule per provider, the value inside each gauge, the
    /// account name under it.
    case capsules

    var id: String { rawValue }

    /// Display name only; the persisted value is `rawValue`.
    var title: String { title(locale: .current) }

    func title(locale: Locale) -> String {
        let resource: LocalizedStringResource = switch self {
        case .rail: .ringBarStyleRail
        case .capsules: .ringBarStyleCapsules
        }
        return resource.string(in: locale)
    }
}

/// The screen edge the ring bar docks to.
enum RingBarEdge: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case right
    case top
    case bottom

    var id: String { rawValue }

    /// Left and right bars stack their gauges vertically.
    var isVertical: Bool { self == .left || self == .right }

    /// Display name only; the persisted value is `rawValue`.
    var title: String { title(locale: .current) }

    func title(locale: Locale) -> String {
        let resource: LocalizedStringResource = switch self {
        case .left: .ringBarEdgeLeft
        case .right: .ringBarEdgeRight
        case .top: .ringBarEdgeTop
        case .bottom: .ringBarEdgeBottom
        }
        return resource.string(in: locale)
    }
}
