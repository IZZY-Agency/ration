import Combine
import Foundation

/// How the popover (and the ⌥⌘U window, which shares its content) lays out
/// accounts. `standard` = the card list; `focus` = one hero number, next-account
/// lines and a quiet row of the rest.
enum PopoverLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case focus

    var id: String { rawValue }

    /// Display name only; the persisted value is `rawValue`.
    var title: String { title(locale: .current) }

    func title(locale: Locale) -> String {
        let resource: LocalizedStringResource = switch self {
        case .standard: .popoverLayoutStandard
        case .focus: .popoverLayoutFocus
        }
        return resource.string(in: locale)
    }
}

struct AppSettingsData: Codable, Equatable, Sendable {
    var sortByWeeklyReset: Bool
    var usageAlertsEnabled: Bool
    /// Whether the attention drop is snoozed.
    ///
    /// Runtime state rather than a preference, but it lives here because it is
    /// GLOBAL — `AlertStateStore` is keyed per account and has no slot for
    /// something that belongs to the panel as a whole — and because it has to
    /// survive a relaunch, or quitting the app would become a way to
    /// un-dismiss the drop. Cleared when any window on any account resets.
    var dropSnoozed: Bool
    /// When true, usage-alert notifications use generic, label-free copy so an
    /// account label (which may be an email/employer) and exact usage never
    /// appear on the lock screen.
    var redactNotifications: Bool
    /// Quiet cells as `(weekday - 1) * 24 + hour`. Canonical: filtered to
    /// `cellRange`, deduplicated, sorted — so the persisted JSON is stable
    /// across saves and a hand-edited/corrupt entry can never crash or block
    /// warm-up forever.
    var quietHours: [Int]
    var holidays: [HolidayRange]
    /// Set on ANY dismissal of the first-run wizard — Done, Skip, or closing
    /// the window — so the wizard is shown-once by construction rather than by
    /// the user reaching one particular button.
    var hasCompletedOnboarding: Bool
    /// When true, the status item shows a usage ring per visible account,
    /// with a green center dot on accounts in the bright IN USE phase.
    /// (Key name predates the always-on rings; kept for persistence compat.)
    var showInUseInMenuBar: Bool
    /// Which usage window each provider's menu bar ring displays, stored as
    /// `Provider.rawValue → UsageWindowKind.rawValue`. Missing or unknown
    /// entries fall back to `defaultMenuBarWindow(for:)` — a hand-edited kind
    /// can never crash or stick.
    var menuBarWindows: [String: String]
    /// When true the ring (and tooltip) show remaining %, otherwise used % —
    /// used is the app's native language everywhere else.
    var menuBarDisplaysRemaining: Bool
    /// Per provider × window thresholds, keyed `"<provider>.<window>"` (e.g.
    /// "claude.fiveHour"). Missing or unknown entries fall back to
    /// `ThresholdPair.default` — a hand-edited or future key can never crash
    /// or stick. Mirrors the `menuBarWindows` pattern.
    var alertThresholds: [String: ThresholdPair]
    /// Delivery channels per threshold key, plus `cursorSpendKey`. Missing →
    /// `AlertChannels.default`, which includes the drop: an upgrading user who
    /// never configured channels gains the panel rather than never seeing it.
    var alertChannels: [String: AlertChannels]
    /// Cursor's spend thresholds. Cursor has no rate window, so it is keyed
    /// by nothing — there is one Cursor spend ladder.
    var cursorSpend: SpendThresholds
    /// Days before a reset expires to warn, keyed by `Provider.rawValue`.
    /// Missing → 1; clamped so a hand-edited value can never disable or flood
    /// the alert.
    var resetExpiryLeadDays: [String: Int]
    /// Popover layout. Missing, unknown or malformed → `.standard`.
    var popoverLayout: PopoverLayout
    /// Global feature switches (Settings → General → Features). All default ON;
    /// missing or malformed → ON. Presentation/gating only — see
    /// `FeatureSwitches` for what each one hides.
    var featureResetsEnabled: Bool
    var featureSwitchAdviceEnabled: Bool
    var featureWarmUpEnabled: Bool
    var featureInUseEnabled: Bool

    /// The four global switches as one value, for pure gating code.
    var features: FeatureSwitches {
        FeatureSwitches(
            resets: featureResetsEnabled,
            switchAdvice: featureSwitchAdviceEnabled,
            warmUp: featureWarmUpEnabled,
            inUse: featureInUseEnabled
        )
    }

    static let cellRange = 0...167

    static func defaultMenuBarWindow(for provider: Provider) -> UsageWindowKind {
        provider == .chatGPT ? .weekly : .fiveHour
    }

    func menuBarWindow(for provider: Provider) -> UsageWindowKind {
        menuBarWindows[provider.rawValue]
            .flatMap(UsageWindowKind.init(rawValue:))
            ?? Self.defaultMenuBarWindow(for: provider)
    }

    static func thresholdKey(provider: Provider, window: UsageWindowKind) -> String {
        "\(provider.rawValue).\(window.rawValue)"
    }

    static let cursorSpendKey = "cursor.spend"

    /// Delivery-channel cell for a provider's reset-credit alerts (the
    /// Settings → Alerts "Resets" row). Mirrors `thresholdKey`'s pattern.
    static func resetCreditsKey(provider: Provider) -> String {
        "\(provider.rawValue).resetCredits"
    }

    static let resetExpiryLeadDaysRange = 1...7

    /// Days before a reset expires to warn. Missing → 1; clamped so a
    /// hand-edited value can never disable or flood the alert.
    func resetExpiryLeadDays(provider: Provider) -> Int {
        let raw = resetExpiryLeadDays[provider.rawValue] ?? 1
        return min(max(raw, Self.resetExpiryLeadDaysRange.lowerBound), Self.resetExpiryLeadDaysRange.upperBound)
    }

    func thresholds(provider: Provider, window: UsageWindowKind) -> ThresholdPair {
        alertThresholds[Self.thresholdKey(provider: provider, window: window)] ?? .default
    }

    func channels(forKey key: String) -> AlertChannels {
        alertChannels[key] ?? .default
    }

    init(
        sortByWeeklyReset: Bool = true,
        usageAlertsEnabled: Bool = false,
        dropSnoozed: Bool = false,
        redactNotifications: Bool = false,
        quietHours: [Int] = [],
        holidays: [HolidayRange] = [],
        hasCompletedOnboarding: Bool = false,
        showInUseInMenuBar: Bool = true,
        menuBarWindows: [String: String] = [:],
        menuBarDisplaysRemaining: Bool = false,
        alertThresholds: [String: ThresholdPair] = [:],
        alertChannels: [String: AlertChannels] = [:],
        cursorSpend: SpendThresholds = .off,
        resetExpiryLeadDays: [String: Int] = [:],
        popoverLayout: PopoverLayout = .standard,
        featureResetsEnabled: Bool = true,
        featureSwitchAdviceEnabled: Bool = true,
        featureWarmUpEnabled: Bool = true,
        featureInUseEnabled: Bool = true
    ) {
        self.sortByWeeklyReset = sortByWeeklyReset
        self.usageAlertsEnabled = usageAlertsEnabled
        self.dropSnoozed = dropSnoozed
        self.redactNotifications = redactNotifications
        self.quietHours = Self.canonical(quietHours)
        self.holidays = holidays
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.showInUseInMenuBar = showInUseInMenuBar
        self.menuBarWindows = menuBarWindows
        self.menuBarDisplaysRemaining = menuBarDisplaysRemaining
        self.alertThresholds = alertThresholds
        self.alertChannels = alertChannels
        self.cursorSpend = cursorSpend
        self.resetExpiryLeadDays = resetExpiryLeadDays
        self.popoverLayout = popoverLayout
        self.featureResetsEnabled = featureResetsEnabled
        self.featureSwitchAdviceEnabled = featureSwitchAdviceEnabled
        self.featureWarmUpEnabled = featureWarmUpEnabled
        self.featureInUseEnabled = featureInUseEnabled
    }

    static func canonical(_ cells: [Int]) -> [Int] {
        Array(Set(cells.filter { cellRange.contains($0) })).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case sortByWeeklyReset
        case usageAlertsEnabled
        case dropSnoozed
        case redactNotifications
        case quietHours
        case holidays
        case hasCompletedOnboarding
        case showInUseInMenuBar
        case menuBarWindows
        case menuBarDisplaysRemaining
        case alertThresholds
        case alertChannels
        case cursorSpend
        case resetExpiryLeadDays
        case popoverLayout
        case featureResetsEnabled
        case featureSwitchAdviceEnabled
        case featureWarmUpEnabled
        case featureInUseEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sortByWeeklyReset = try container.decodeIfPresent(
            Bool.self,
            forKey: .sortByWeeklyReset
        ) ?? true
        usageAlertsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .usageAlertsEnabled
        ) ?? false
        // Absent in every pre-0.28.0 file — default to not snoozed.
        dropSnoozed = try container.decodeIfPresent(Bool.self, forKey: .dropSnoozed) ?? false
        redactNotifications = try container.decodeIfPresent(
            Bool.self,
            forKey: .redactNotifications
        ) ?? false
        quietHours = Self.canonical(
            try container.decodeIfPresent([Int].self, forKey: .quietHours) ?? []
        )
        holidays = try container.decodeIfPresent(
            [HolidayRange].self,
            forKey: .holidays
        ) ?? []
        hasCompletedOnboarding = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasCompletedOnboarding
        ) ?? false
        showInUseInMenuBar = try container.decodeIfPresent(
            Bool.self,
            forKey: .showInUseInMenuBar
        ) ?? true
        menuBarWindows = try container.decodeIfPresent(
            [String: String].self,
            forKey: .menuBarWindows
        ) ?? [:]
        menuBarDisplaysRemaining = try container.decodeIfPresent(
            Bool.self,
            forKey: .menuBarDisplaysRemaining
        ) ?? false
        alertThresholds = Self.lossyDecode(container, forKey: .alertThresholds)
        alertChannels = Self.lossyDecode(container, forKey: .alertChannels)
        cursorSpend = (try? container.decodeIfPresent(SpendThresholds.self, forKey: .cursorSpend))
            ?? .off
        resetExpiryLeadDays = Self.lossyDecode(container, forKey: .resetExpiryLeadDays)
        // Lenient: a value from a newer build (or a hand edit) must not cost
        // the user every other setting — `load()` defaults ALL fields on a throw.
        let layout: PopoverLayout? = try? container.decodeIfPresent(PopoverLayout.self, forKey: .popoverLayout)
        popoverLayout = layout ?? .standard
        // Lenient like `popoverLayout`: missing or malformed → ON.
        func feature(_ key: CodingKeys) -> Bool {
            ((try? container.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? true
        }
        featureResetsEnabled = feature(.featureResetsEnabled)
        featureSwitchAdviceEnabled = feature(.featureSwitchAdviceEnabled)
        featureWarmUpEnabled = feature(.featureWarmUpEnabled)
        featureInUseEnabled = feature(.featureInUseEnabled)
    }

    /// Decodes a `[String: Value]` entry by entry, DROPPING malformed entries
    /// instead of failing the whole dictionary.
    ///
    /// This matters because `AppSettings.load()` substitutes defaults for
    /// EVERY setting on any `DecodingError` — without per-entry tolerance, one
    /// hand-edited threshold would silently reset the user's quiet hours,
    /// holidays, and menu-bar preferences too.
    private static func lossyDecode<Value: Decodable>(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [String: Value] {
        guard
            let raw = try? container.decodeIfPresent([String: AnyCodable].self, forKey: key)
        else { return [:] }
        var result: [String: Value] = [:]
        for (entryKey, wrapped) in raw {
            guard let value = wrapped.decode(as: Value.self) else { continue }
            result[entryKey] = value
        }
        return result
    }
}

@MainActor
final class AppSettings: ObservableObject {
    typealias SaveSettings = @MainActor (AppSettingsData) async throws -> Void

    @Published private(set) var sortByWeeklyReset: Bool = true
    @Published private(set) var usageAlertsEnabled: Bool = false
    /// See `AppSettingsData.dropSnoozed`.
    @Published private(set) var dropSnoozed: Bool = false
    @Published private(set) var redactNotifications: Bool = false
    @Published private(set) var quietHours: [Int] = []
    @Published private(set) var holidays: [HolidayRange] = []
    @Published private(set) var hasCompletedOnboarding: Bool = false
    @Published private(set) var showInUseInMenuBar: Bool = true
    @Published private(set) var menuBarWindows: [String: String] = [:]
    @Published private(set) var menuBarDisplaysRemaining: Bool = false
    @Published private(set) var alertThresholds: [String: ThresholdPair] = [:]
    @Published private(set) var alertChannels: [String: AlertChannels] = [:]
    @Published private(set) var cursorSpend: SpendThresholds = .off
    @Published private(set) var resetExpiryLeadDays: [String: Int] = [:]
    @Published private(set) var popoverLayout: PopoverLayout = .standard
    @Published private(set) var featureResetsEnabled: Bool = true
    @Published private(set) var featureSwitchAdviceEnabled: Bool = true
    @Published private(set) var featureWarmUpEnabled: Bool = true
    @Published private(set) var featureInUseEnabled: Bool = true

    var features: FeatureSwitches { data.features }

    /// The four switches as they change (current value first). For views that
    /// hold `AppModel` rather than observing `AppSettings` directly — values
    /// come from the `@Published` projections, so they are the NEW values even
    /// though `@Published` emits from `willSet`.
    var featuresPublisher: AnyPublisher<FeatureSwitches, Never> {
        Publishers.CombineLatest4($featureResetsEnabled, $featureSwitchAdviceEnabled, $featureWarmUpEnabled, $featureInUseEnabled)
            .map { FeatureSwitches(resets: $0, switchAdvice: $1, warmUp: $2, inUse: $3) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    /// `true` when the persisted settings file failed to decode and defaults
    /// were substituted. Consumers that fail *closed* on unknown config (the
    /// warm-up inhibition schedule) read this to avoid trusting the empty
    /// defaults as if the user had chosen them. Cleared by the next successful
    /// save, which re-persists valid, complete JSON.
    @Published private(set) var loadFailed: Bool = false

    /// The current settings as a value — used by pure policy code that needs
    /// several fields at once (threshold resolution) rather than one binding.
    var data: AppSettingsData {
        AppSettingsData(
            sortByWeeklyReset: sortByWeeklyReset,
            usageAlertsEnabled: usageAlertsEnabled,
            dropSnoozed: dropSnoozed,
            redactNotifications: redactNotifications,
            quietHours: quietHours,
            holidays: holidays,
            hasCompletedOnboarding: hasCompletedOnboarding,
            showInUseInMenuBar: showInUseInMenuBar,
            menuBarWindows: menuBarWindows,
            menuBarDisplaysRemaining: menuBarDisplaysRemaining,
            alertThresholds: alertThresholds,
            alertChannels: alertChannels,
            cursorSpend: cursorSpend,
            resetExpiryLeadDays: resetExpiryLeadDays,
            popoverLayout: popoverLayout,
            featureResetsEnabled: featureResetsEnabled,
            featureSwitchAdviceEnabled: featureSwitchAdviceEnabled,
            featureWarmUpEnabled: featureWarmUpEnabled,
            featureInUseEnabled: featureInUseEnabled
        )
    }

    private let fileStore: JSONFileStore<AppSettingsData>
    private let saveSettings: SaveSettings
    private let mutations = SerializedMutationQueue()

    init(fileURL: URL, saveSettings: SaveSettings? = nil) {
        let fileStore = JSONFileStore<AppSettingsData>(
            fileURL: fileURL,
            defaultValue: AppSettingsData(sortByWeeklyReset: true)
        )
        self.fileStore = fileStore
        self.saveSettings = saveSettings ?? { settings in
            try await fileStore.save(settings)
        }
    }

    func load() async throws {
        try await mutations.run { [self] in
            do {
                let loaded = try await fileStore.load()
                apply(loaded)
                hydrateDropSnoozed(loaded.dropSnoozed)
                loadFailed = false
            } catch is DecodingError {
                // Corrupt JSON defaults to ON (sort) / OFF (alerts) / no quiet
                // hours, without throwing. `loadFailed` records that these are
                // substituted defaults, not user choices — the warm-up schedule
                // fails closed while it is set (see `AppModel.warmUpSchedule`).
                apply(AppSettingsData())
                hydrateDropSnoozed(false)
                loadFailed = true
            }
        }
    }

    func setSortByWeeklyReset(_ value: Bool) async throws {
        try await mutate { $0.sortByWeeklyReset = value }
    }

    func setPopoverLayout(_ value: PopoverLayout) async throws {
        try await mutate { $0.popoverLayout = value }
    }

    func setFeature(_ feature: FeatureSwitch, enabled value: Bool) async throws {
        switch feature {
        case .resets: try await setFeatureResetsEnabled(value)
        case .switchAdvice: try await setFeatureSwitchAdviceEnabled(value)
        case .warmUp: try await setFeatureWarmUpEnabled(value)
        case .inUse: try await setFeatureInUseEnabled(value)
        }
    }

    func setFeatureResetsEnabled(_ value: Bool) async throws {
        try await mutate { $0.featureResetsEnabled = value }
    }

    func setFeatureSwitchAdviceEnabled(_ value: Bool) async throws {
        try await mutate { $0.featureSwitchAdviceEnabled = value }
    }

    func setFeatureWarmUpEnabled(_ value: Bool) async throws {
        try await mutate { $0.featureWarmUpEnabled = value }
    }

    func setFeatureInUseEnabled(_ value: Bool) async throws {
        try await mutate { $0.featureInUseEnabled = value }
    }

    func setUsageAlertsEnabled(_ value: Bool) async throws {
        try await mutate { $0.usageAlertsEnabled = value }
    }

    func setRedactNotifications(_ value: Bool) async throws {
        try await mutate { $0.redactNotifications = value }
    }

    func setQuietHours(_ value: [Int]) async throws {
        try await mutate { $0.quietHours = AppSettingsData.canonical(value) }
    }

    func setHolidays(_ value: [HolidayRange]) async throws {
        try await mutate { $0.holidays = value }
    }

    func setHasCompletedOnboarding(_ value: Bool) async throws {
        try await mutate { $0.hasCompletedOnboarding = value }
    }

    func setShowInUseInMenuBar(_ value: Bool) async throws {
        try await mutate { $0.showInUseInMenuBar = value }
    }

    func setMenuBarWindow(_ kind: UsageWindowKind, for provider: Provider) async throws {
        try await mutate { $0.menuBarWindows[provider.rawValue] = kind.rawValue }
    }

    func setMenuBarDisplaysRemaining(_ value: Bool) async throws {
        try await mutate { $0.menuBarDisplaysRemaining = value }
    }

    func setThresholds(
        _ value: ThresholdPair,
        provider: Provider,
        window: UsageWindowKind
    ) async throws {
        let key = AppSettingsData.thresholdKey(provider: provider, window: window)
        try await mutate { $0.alertThresholds[key] = value }
    }

    /// Commits a row's draft — both fields at once — against the freshest
    /// stored pair inside `mutate`, and returns the pair as saved.
    ///
    /// ONE canonicalisation, from both values the user typed: committing the
    /// fields one at a time made the result depend on their order (from 75/90,
    /// warning 95 then critical 99 gave 89/99, the other order 95/99). A
    /// `.keep` field is read from the stored pair inside the serialized
    /// mutation, never from a copy the caller held, so a commit cannot carry a
    /// stale sibling back over an edit that has not round-tripped yet.
    ///
    /// The returned pair is what the editor shows: `ThresholdPair` may have
    /// changed either field, and a canonical result equal to what is already
    /// stored publishes nothing.
    @discardableResult
    func setThresholds(
        warning: FieldEdit<Int>,
        critical: FieldEdit<Int>,
        provider: Provider,
        window: UsageWindowKind
    ) async throws -> ThresholdPair {
        let key = AppSettingsData.thresholdKey(provider: provider, window: window)
        return try await mutate(returning: { data in
            let current = data.alertThresholds[key] ?? .default
            let pair = ThresholdPair(
                warningPercent: warning.applied(to: current.warningPercent),
                criticalPercent: critical.applied(to: current.criticalPercent)
            )
            data.alertThresholds[key] = pair
            return pair
        })
    }

    /// One field of `setThresholds(warning:critical:…)`.
    @discardableResult
    func setWarningPercent(_ value: Int, provider: Provider, window: UsageWindowKind) async throws -> ThresholdPair {
        try await setThresholds(warning: .set(value), critical: .keep, provider: provider, window: window)
    }

    /// One field of `setThresholds(warning:critical:…)`.
    @discardableResult
    func setCriticalPercent(_ value: Int, provider: Provider, window: UsageWindowKind) async throws -> ThresholdPair {
        try await setThresholds(warning: .keep, critical: .set(value), provider: provider, window: window)
    }

    func setChannels(_ value: AlertChannels, forKey key: String) async throws {
        try await mutate { $0.alertChannels[key] = value }
    }

    /// Field-level equivalent of `setChannels` — same reasoning as
    /// `setWarningPercent`. `notification` and `drop` are two fields of ONE
    /// stored value, so the sibling is read INSIDE the serialized mutation;
    /// composing a whole `AlertChannels` from a locally-held copy would let
    /// one checkbox's commit carry a stale sibling back over the other's.
    /// Sibling of `setDropEnabled`, same field-level reasoning.
    func setNotificationEnabled(_ enabled: Bool, forKey key: String) async throws {
        try await mutate { data in
            let current = data.channels(forKey: key)
            data.alertChannels[key] = AlertChannels(
                notification: enabled,
                drop: current.drop
            )
        }
    }

    /// Commits the snooze flag to the published snapshot WITHOUT waiting for
    /// the save. The drop is derived synchronously from `data`, so an async-only
    /// setter would leave the panel on screen until the write landed.
    func setDropSnoozedInMemory(_ snoozed: Bool) {
        dropSnoozed = snoozed
    }

    /// Persists the snooze flag.
    ///
    /// Takes NO value: it writes whatever `dropSnoozed` is when the mutation
    /// actually runs, read inside the serialized closure. Capturing the value
    /// at call time made the write order-dependent — the ✕ and a reset each
    /// spawn an unstructured task, and Swift makes no promise about which
    /// reaches the queue first, so a stale `true` could land after a newer
    /// `false` and resurrect a dismissed panel on the next launch. Reading the
    /// live value makes the last writer correct regardless of order; the
    /// in-memory flag is the authority, this is only its durable copy.
    func setDropSnoozed() async throws {
        try await mutate { [weak self] data in
            data.dropSnoozed = self?.dropSnoozed ?? data.dropSnoozed
        }
    }

    func setDropEnabled(_ enabled: Bool, forKey key: String) async throws {
        try await mutate { data in
            let current = data.channels(forKey: key)
            data.alertChannels[key] = AlertChannels(
                notification: current.notification,
                drop: enabled
            )
        }
    }

    func setResetExpiryLeadDays(_ days: Int, provider: Provider) async throws {
        let clamped = min(max(days, AppSettingsData.resetExpiryLeadDaysRange.lowerBound), AppSettingsData.resetExpiryLeadDaysRange.upperBound)
        try await mutate { $0.resetExpiryLeadDays[provider.rawValue] = clamped }
    }

    func setCursorSpend(_ value: SpendThresholds) async throws {
        try await mutate { $0.cursorSpend = value }
    }

    /// Cursor's spend draft, both fields at once — see
    /// `setThresholds(warning:critical:…)`. From $50/$80, warning $90 then
    /// critical $100 one at a time lost the warning (90 ≥ 80 turns it off);
    /// as one draft it is $90/$100 whichever field was typed first.
    @discardableResult
    func setCursorSpend(
        warning: FieldEdit<Int?>,
        critical: FieldEdit<Int?>
    ) async throws -> SpendThresholds {
        try await mutate(returning: { data in
            let current = data.cursorSpend
            let spend = SpendThresholds(
                warningCents: warning.applied(to: current.warningCents),
                criticalCents: critical.applied(to: current.criticalCents)
            )
            data.cursorSpend = spend
            return spend
        })
    }

    /// One field of `setCursorSpend(warning:critical:)`.
    @discardableResult
    func setSpendWarningCents(_ value: Int?) async throws -> SpendThresholds {
        try await setCursorSpend(warning: .set(value), critical: .keep)
    }

    /// One field of `setCursorSpend(warning:critical:)`.
    @discardableResult
    func setSpendCriticalCents(_ value: Int?) async throws -> SpendThresholds {
        try await setCursorSpend(warning: .keep, critical: .set(value))
    }

    func menuBarWindow(for provider: Provider) -> UsageWindowKind {
        menuBarWindows[provider.rawValue]
            .flatMap(UsageWindowKind.init(rawValue:))
            ?? AppSettingsData.defaultMenuBarWindow(for: provider)
    }

    /// Atomic, id-addressed, FIELD-SPECIFIC holiday deltas. Callers must NOT
    /// read the published array, mutate it, and write the whole thing back: the
    /// published value lags an in-flight save, so two quick whole-record edits
    /// would both start from the same stale record and the second would discard
    /// the first field. These each touch ONE field of the freshest record
    /// INSIDE the serialized mutation, so a label commit and a date change (or
    /// two date changes) compose instead of clobbering. Clamping lives here so
    /// it always applies to current data, never a stale prop.
    func addHoliday(_ holiday: HolidayRange) async throws {
        try await mutate { data in
            guard !data.holidays.contains(where: { $0.id == holiday.id }) else { return }
            data.holidays.append(holiday)
        }
    }

    func setHolidayLabel(id: UUID, _ label: String) async throws {
        try await mutateHoliday(id) { $0.label = label }
    }

    func setHolidayStart(id: UUID, _ start: LocalDate) async throws {
        try await mutateHoliday(id) {
            $0.start = start
            if $0.end < start { $0.end = start }
        }
    }

    func setHolidayEnd(id: UUID, _ end: LocalDate) async throws {
        try await mutateHoliday(id) {
            $0.end = end
            if end < $0.start { $0.start = end }
        }
    }

    func removeHoliday(id: UUID) async throws {
        try await mutate { data in
            data.holidays.removeAll { $0.id == id }
        }
    }

    private func mutateHoliday(
        _ id: UUID,
        _ change: @escaping (inout HolidayRange) -> Void
    ) async throws {
        try await mutate { data in
            guard let index = data.holidays.firstIndex(where: { $0.id == id }) else { return }
            change(&data.holidays[index])
        }
    }

    /// Read the current snapshot, apply `change` to a copy, save, and only then
    /// publish. Each setter touches only its own field, so adding a field can
    /// never silently revert another (the previous per-setter re-enumeration of
    /// every field was a footgun that grew with each new setting).
    ///
    /// Two orderings here are load-bearing:
    /// 1. the snapshot is read INSIDE `mutations.run`, so a setter suspended in
    ///    `saveSettings` cannot make a later setter clobber its field; and
    /// 2. the published values are updated only AFTER a successful save — the
    ///    alerts lifecycle depends on that (see `AppModel.setUsageAlertsEnabled`).
    private func mutate(
        _ change: @escaping (inout AppSettingsData) -> Void
    ) async throws {
        try await mutations.run { [self] in
            var candidate = currentData
            change(&candidate)
            try await saveSettings(candidate)
            apply(candidate)
            // A successful save re-persisted valid, complete JSON — the file is
            // no longer corrupt, so consumers may trust it again.
            loadFailed = false
        }
    }

    private var currentData: AppSettingsData { data }

    /// `mutate`, returning what `change` computed from the freshest data —
    /// only once that data has been saved and published.
    private func mutate<Value>(
        returning change: @escaping (inout AppSettingsData) -> Value
    ) async throws -> Value {
        let result = MutationResult<Value>()
        try await mutate { data in
            result.value = change(&data)
        }
        guard let value = result.value else {
            preconditionFailure("a saved mutation always ran its change")
        }
        return value
    }

    /// Seeds the snooze from disk, ONCE, at load.
    ///
    /// It is excluded from `apply` on purpose. `mutate` captures a candidate,
    /// awaits the save, then republishes that candidate — so a snooze write
    /// still in flight would overwrite a newer in-memory value set while it was
    /// suspended, resurrecting a panel the user had just seen dismissed (or the
    /// reverse). Every other field is only ever changed THROUGH `mutate`, so
    /// republishing is safe for them; this one is set synchronously from the ✕
    /// and from reset detection, which is why it needs a different rule:
    /// memory is the authority, disk is its durable copy, and disk is read only
    /// here.
    private func hydrateDropSnoozed(_ value: Bool) {
        if dropSnoozed != value { dropSnoozed = value }
    }

    /// Assign only what actually changed. `@Published` emits on every
    /// assignment, even of an identical value, so a blanket re-assign would
    /// make (say) a quiet-hours edit needlessly drive the `sortByWeeklyReset`
    /// presentation pipeline that `AppModel` subscribes to.
    private func apply(_ data: AppSettingsData) {
        if sortByWeeklyReset != data.sortByWeeklyReset {
            sortByWeeklyReset = data.sortByWeeklyReset
        }
        if usageAlertsEnabled != data.usageAlertsEnabled {
            usageAlertsEnabled = data.usageAlertsEnabled
        }
        // `dropSnoozed` is deliberately NOT applied here — see `hydrate`.
        if redactNotifications != data.redactNotifications {
            redactNotifications = data.redactNotifications
        }
        if quietHours != data.quietHours {
            quietHours = data.quietHours
        }
        if holidays != data.holidays {
            holidays = data.holidays
        }
        if hasCompletedOnboarding != data.hasCompletedOnboarding {
            hasCompletedOnboarding = data.hasCompletedOnboarding
        }
        if showInUseInMenuBar != data.showInUseInMenuBar {
            showInUseInMenuBar = data.showInUseInMenuBar
        }
        if menuBarWindows != data.menuBarWindows {
            menuBarWindows = data.menuBarWindows
        }
        if menuBarDisplaysRemaining != data.menuBarDisplaysRemaining {
            menuBarDisplaysRemaining = data.menuBarDisplaysRemaining
        }
        if alertThresholds != data.alertThresholds {
            alertThresholds = data.alertThresholds
        }
        if alertChannels != data.alertChannels {
            alertChannels = data.alertChannels
        }
        if cursorSpend != data.cursorSpend {
            cursorSpend = data.cursorSpend
        }
        if resetExpiryLeadDays != data.resetExpiryLeadDays {
            resetExpiryLeadDays = data.resetExpiryLeadDays
        }
        if popoverLayout != data.popoverLayout {
            popoverLayout = data.popoverLayout
        }
        if featureResetsEnabled != data.featureResetsEnabled {
            featureResetsEnabled = data.featureResetsEnabled
        }
        if featureSwitchAdviceEnabled != data.featureSwitchAdviceEnabled {
            featureSwitchAdviceEnabled = data.featureSwitchAdviceEnabled
        }
        if featureWarmUpEnabled != data.featureWarmUpEnabled {
            featureWarmUpEnabled = data.featureWarmUpEnabled
        }
        if featureInUseEnabled != data.featureInUseEnabled {
            featureInUseEnabled = data.featureInUseEnabled
        }
    }
}

/// Carries a value out of `AppSettings.mutate`'s serialized closure.
@MainActor
private final class MutationResult<Value> {
    var value: Value?
}
