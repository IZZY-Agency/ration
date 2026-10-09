import Foundation

/// The ring bar's glass segments: one per kind — subscriptions (ring gauges),
/// then API keys (square gauges) — in both styles, so the kinds read at a
/// glance. Providers keep their order within a kind; a kind with nothing has
/// no glass.
enum RingBarSegments {
    static func byKind(_ sources: [DisplaySource]) -> [[DisplaySource]] {
        let plans = sources.filter { $0.gaugeShape == .ring }
        let apiKeys = sources.filter { $0.gaugeShape != .ring }
        return [plans, apiKeys].filter { !$0.isEmpty }
    }
}
