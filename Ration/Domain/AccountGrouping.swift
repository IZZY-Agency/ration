import Foundation

/// One provider's cards, in the order they should be rendered.
struct AccountGroup: Equatable, Identifiable, Sendable {
    let provider: Provider
    let presentations: [AccountPresentation]

    var id: Provider { provider }
}

/// Groups presentations by provider and applies the capture-time ordering pin.
/// Pure: no SwiftUI, no clock, no knowledge of popovers — the pin is supplied by
/// the caller (see `AccountPinSnapshot`), which is what makes freezing testable.
enum AccountGrouping {
    static func grouped(
        _ presentations: [AccountPresentation],
        orderingPinByProvider: [Provider: UUID]
    ) -> [AccountGroup] {
        Provider.allCases.compactMap { provider in
            let members = presentations.filter { $0.account.provider == provider }
            guard !members.isEmpty else { return nil }

            guard
                let pinnedID = orderingPinByProvider[provider],
                let index = members.firstIndex(where: { $0.id == pinnedID })
            else {
                return AccountGroup(provider: provider, presentations: members)
            }

            var ordered = members
            let pinned = ordered.remove(at: index)
            ordered.insert(pinned, at: 0)
            return AccountGroup(provider: provider, presentations: ordered)
        }
    }
}
