import Foundation

/// Per-window alert thresholds in PERCENTAGE POINTS of used capacity.
///
/// Stored as Int percent rather than a fraction so the persisted JSON is
/// human-legible and immune to float drift; converted to a fraction only at
/// comparison time against `UsageWindow.usedFraction`.
///
/// Canonical form is enforced on init AND on decode: `criticalPercent` in
/// 2...100 and `warningPercent` in 1...(criticalPercent - 1). Critical's floor
/// is 2, not 1, because a floor of 1 leaves no room for a strictly smaller
/// warning — the ladder must stay ordered for `AlertTier.forUsed` to be
/// meaningful.
struct ThresholdPair: Codable, Equatable, Sendable {
    private(set) var warningPercent: Int
    private(set) var criticalPercent: Int

    static let `default` = ThresholdPair(warningPercent: 75, criticalPercent: 90)

    init(warningPercent: Int, criticalPercent: Int) {
        let critical = min(max(criticalPercent, 2), 100)
        let warning = min(max(warningPercent, 1), critical - 1)
        self.criticalPercent = critical
        self.warningPercent = warning
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            warningPercent: try c.decode(Int.self, forKey: .warningPercent),
            criticalPercent: try c.decode(Int.self, forKey: .criticalPercent)
        )
    }

    var warningFraction: Double { Double(warningPercent) / 100 }
    var criticalFraction: Double { Double(criticalPercent) / 100 }
}

/// Cursor spend thresholds in CENTS. `nil` means that tier is off — Cursor's
/// API exposes spend with no cap (`CursorSpend` has no denominator), so there
/// is no honest default to pick and the app never invents one.
///
/// Canonical: non-positive values become nil; if both are set and warning is
/// not strictly below critical, the weaker signal (warning) yields.
struct SpendThresholds: Codable, Equatable, Sendable {
    private(set) var warningCents: Int?
    private(set) var criticalCents: Int?

    static let off = SpendThresholds(warningCents: nil, criticalCents: nil)

    init(warningCents: Int?, criticalCents: Int?) {
        let critical = criticalCents.flatMap { $0 > 0 ? $0 : nil }
        var warning = warningCents.flatMap { $0 > 0 ? $0 : nil }
        if let w = warning, let c = critical, w >= c { warning = nil }
        self.warningCents = warning
        self.criticalCents = critical
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            warningCents: try c.decodeIfPresent(Int.self, forKey: .warningCents),
            criticalCents: try c.decodeIfPresent(Int.self, forKey: .criticalCents)
        )
    }

    /// The tier this spend has reached, and the configured amount it crossed.
    ///
    /// `nil` when no configured threshold is met — including when none is SET:
    /// Cursor exposes no cap, so there is deliberately no default here that
    /// would fire on any spend at all. Inclusive (`>=`), so landing exactly on
    /// a threshold counts.
    ///
    /// Shared by the notification path (`AlertPolicy`) and the attention drop,
    /// which must never disagree about whether a spend has crossed.
    func tier(forSpentCents spentCents: Int) -> (tier: AlertTier, thresholdCents: Int)? {
        if let critical = criticalCents, spentCents >= critical {
            return (.critical, critical)
        }
        if let warning = warningCents, spentCents >= warning {
            return (.warning, warning)
        }
        return nil
    }
}

/// Which surfaces a threshold crossing is delivered on.
///
/// Persisted as an ARRAY OF TOKENS rather than a bitmask or a keyed object so
/// a future channel is purely additive: an older build decoding a file that
/// names a channel it doesn't know ignores that token instead of throwing.
struct AlertChannels: Codable, Equatable, Sendable {
    var notification: Bool
    var drop: Bool

    /// What an unconfigured cell resolves to: BOTH surfaces.
    ///
    /// The drop ships on by default deliberately. It is the headline surface of
    /// this feature, and a menu-bar panel nobody has switched on is a feature
    /// nobody ever sees — the failure mode is silence, which is exactly what
    /// the drop exists to fix. It is also cheap to be wrong about: the panel
    /// never takes focus, dismisses with one click, and retracts itself when
    /// the window resets.
    static let `default` = AlertChannels(notification: true, drop: true)

    /// An explicit opt-out of the drop. Still meaningful — it is what turning
    /// the Drop checkbox off persists as — but no longer the fallback.
    static let notificationOnly = AlertChannels(notification: true, drop: false)

    private enum Token: String { case notification, drop }

    init(notification: Bool, drop: Bool) {
        self.notification = notification
        self.drop = drop
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var tokens: Set<String> = []
        while !container.isAtEnd {
            tokens.insert(try container.decode(String.self))
        }
        notification = tokens.contains(Token.notification.rawValue)
        drop = tokens.contains(Token.drop.rawValue)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        if notification { try container.encode(Token.notification.rawValue) }
        if drop { try container.encode(Token.drop.rawValue) }
    }
}

/// Minimal type-erased holder used ONLY to re-decode dictionary entries
/// individually, so one malformed entry can be dropped without failing its
/// siblings. Stores the raw JSON bytes for the entry and re-decodes on demand.
struct AnyCodable: Decodable {
    private let data: Data

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Re-encode whatever this entry is back to JSON bytes so it can be
        // decoded independently later. `JSONSerialization` accepts fragments.
        let raw = try container.decode(JSONValue.self)
        data = try JSONEncoder().encode(raw)
    }

    func decode<T: Decodable>(as type: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: data)
    }
}

/// A structural JSON value — enough to round-trip an arbitrary entry.
private enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unrecognised JSON value"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// Which delivery-channel cell an alert event belongs to, if any.
///
/// Only THRESHOLD crossings are governed by the per-cell channels — they are
/// what the user configured a threshold for. Reset, reauth and rate-limit
/// events have no cell and are never suppressed by one: silencing a window's
/// notifications must not also silence "sign in again", which is actionable
/// and unrelated to how close that window is to its limit.
enum AlertChannelKey {
    /// `nil` means "no cell governs this event" — deliver it.
    static func forEvent(_ event: AlertEvent, provider: Provider) -> String? {
        switch event {
        case .threshold(let kind, _, _, _):
            AppSettingsData.thresholdKey(provider: provider, window: kind)
        case .spendThreshold:
            AppSettingsData.cursorSpendKey
        case .reset, .reauthRequired, .rateLimited:
            nil
        }
    }
}
