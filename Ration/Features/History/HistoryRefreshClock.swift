import AppKit
import Combine
import Foundation

/// What makes an open History window reload: the store's coalesced
/// `historyRevision`, the calendar day (midnight, and with it a renewal
/// boundary — cycles start at local midnight), the system time zone, and
/// waking from sleep.
///
/// `now` is re-sampled on every one of those events. Waking re-reads the time
/// and the zone because a Mac asleep at midnight or at a renewal may get no
/// day notification and, with every account paused or offline, no poll.
///
/// Observing runs between `start()` and `stop()`: the view starts it on
/// appear (which also catches up on anything missed while closed) and stops
/// it on disappear, so a closed window leaves no observers behind.
@MainActor
final class HistoryRefreshClock: ObservableObject {
    @Published private(set) var historyRevision: Int
    @Published private(set) var now: Date
    @Published private(set) var timeZone: TimeZone

    private let history: UsageHistoryStore
    private let notificationCenter: NotificationCenter
    private let wakeNotificationCenter: NotificationCenter
    private let clock: () -> Date
    private let currentTimeZone: () -> TimeZone
    private var subscriptions: Set<AnyCancellable> = []

    /// The system zone, re-read after a change: `TimeZone.current` is cached
    /// until reset. Touches no actor state.
    nonisolated static func systemTimeZone() -> TimeZone {
        NSTimeZone.resetSystemTimeZone()
        return TimeZone.current
    }

    /// `wakeNotificationCenter` is `NSWorkspace.shared.notificationCenter`
    /// in the app (where `didWakeNotification` is posted); tests inject one.
    init(
        history: UsageHistoryStore,
        notificationCenter: NotificationCenter = .default,
        wakeNotificationCenter: NotificationCenter? = nil,
        now: @escaping () -> Date = { .now },
        timeZone: @escaping () -> TimeZone = { HistoryRefreshClock.systemTimeZone() }
    ) {
        self.history = history
        self.notificationCenter = notificationCenter
        self.wakeNotificationCenter = wakeNotificationCenter ?? NSWorkspace.shared.notificationCenter
        self.clock = now
        self.currentTimeZone = timeZone
        self.historyRevision = history.historyRevision
        self.now = now()
        self.timeZone = timeZone()
        start()
    }

    /// Begins observing (idempotent) and re-samples everything at once.
    func start() {
        catchUp()
        guard subscriptions.isEmpty else { return }

        // The store publishes on the main actor; `dropFirst` skips the
        // current value, already read by `catchUp`.
        history.$historyRevision
            .dropFirst()
            .sink { [weak self] revision in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.revisionChanged(revision)
                }
            }
            .store(in: &subscriptions)

        // These may be posted on any thread.
        observe(notificationCenter, .NSCalendarDayChanged)
        observe(notificationCenter, .NSSystemTimeZoneDidChange)
        observe(wakeNotificationCenter, NSWorkspace.didWakeNotification)
    }

    /// Stops observing: cancelling the subscriptions removes every observer.
    func stop() {
        for subscription in subscriptions {
            subscription.cancel()
        }
        subscriptions.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        center.publisher(for: name)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.catchUp()
                }
            }
            .store(in: &subscriptions)
    }

    private func revisionChanged(_ revision: Int) {
        now = clock()
        historyRevision = revision
    }

    /// Day change, zone change, wake, start: re-read the zone and the time
    /// (and the revision, which may have moved while stopped). Assigns only
    /// what changed, so an unchanged value does not re-render the view.
    private func catchUp() {
        let zone: TimeZone = currentTimeZone()
        if zone != timeZone { timeZone = zone }
        let revision: Int = history.historyRevision
        if revision != historyRevision { historyRevision = revision }
        now = clock()
    }
}
