import Foundation

/// The one refresh operation every surface uses: subscriptions and
/// API orgs together. Steps run concurrently, so a slow web fetch never
/// delays the API poll (or the reverse).
@MainActor
struct AppRefresh {
    let refreshAll: () -> Void
    let refreshWhenOpened: () -> Void

    static func combining(all: [@MainActor () async -> Void], whenOpened: [@MainActor () async -> Void]) -> AppRefresh {
        AppRefresh(
            refreshAll: { for step in all { Task { @MainActor in await step() } } },
            refreshWhenOpened: { for step in whenOpened { Task { @MainActor in await step() } } }
        )
    }
}
