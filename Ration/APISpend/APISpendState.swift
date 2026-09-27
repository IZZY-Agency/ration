import Foundation

struct APIOrgRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let vendor: APIVendor
    var vendorOrgID: String?
    var label: String
    var monthlyBudgetCents: Int?
    var isPaused: Bool
    var displayOrder: Int
    let createdAt: Date
}

/// Per-org alert memory. `evaluatedMonthKey` advances ONLY when an
/// accepted report is evaluated — never on an edit.
struct BudgetAlertMemory: Codable, Equatable, Sendable {
    var evaluatedMonthKey: String?
    var notifiedTier: AlertTier?
    var dismissedTier: AlertTier?
}

/// Everything whose consistency matters, in ONE atomic file.
struct APISpendState: Codable, Equatable, Sendable {
    var orgs: [APIOrgRecord] = []
    var thresholds: ThresholdPair = .default
    var memory: [UUID: BudgetAlertMemory] = [:]
    var pendingKeyDeletions: [UUID] = []
    /// Settings' one list of subscription and API accounts, as ids
    /// (`SidebarAccountOrder`). Absent in files written before it existed.
    var sidebarOrder: [UUID] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        orgs = try container.decode([APIOrgRecord].self, forKey: .orgs)
        thresholds = try container.decode(ThresholdPair.self, forKey: .thresholds)
        memory = try container.decode([UUID: BudgetAlertMemory].self, forKey: .memory)
        pendingKeyDeletions = try container.decode([UUID].self, forKey: .pendingKeyDeletions)
        sidebarOrder = try container.decodeIfPresent([UUID].self, forKey: .sidebarOrder) ?? []
    }
}

enum PersistOutcome: Equatable, Sendable {
    case written, stale, failed
}

extension ThresholdPair {
    func percent(for tier: AlertTier) -> Int {
        switch tier {
        case .warning: warningPercent
        case .critical: criticalPercent
        }
    }
}
