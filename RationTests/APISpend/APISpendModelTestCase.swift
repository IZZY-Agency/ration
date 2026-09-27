import XCTest
@testable import Ration

/// Shared setup for every `APISpendModel` test class.
@MainActor
class APISpendModelTestCase: XCTestCase {
    var now = ISO8601DateFormatter().date(from: "2026-09-27T17:05:00Z")!
    var dir: URL!
    var keys: InMemoryAPIKeyStore!
    var anthropic: FakeSpendClient!
    var bridge: FakeAlertBridge!
    var settings: AppSettings!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"usageAlertsEnabled":true}"#.utf8).write(to: dir.appending(path: "app-settings.json"))
        settings = AppSettings(fileURL: dir.appending(path: "app-settings.json"))
        try await settings.load()
        keys = InMemoryAPIKeyStore()
        anthropic = FakeSpendClient(vendor: .anthropic)
        bridge = FakeAlertBridge()
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    func seedOrg(budget: Int? = 60_000, paused: Bool = false) async throws -> UUID {
        let id = UUID()
        keys.seed("sk-ant-admin01-SENTINELSENTINEL", for: id)
        var state = APISpendState()
        state.orgs = [APIOrgRecord(id: id, vendor: .anthropic, vendorOrgID: "org-1", label: "IZZY", monthlyBudgetCents: budget, isPaused: paused, displayOrder: 0, createdAt: now)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: dir.appending(path: "api-spend.json"))
        return id
    }

    func makeModel() -> APISpendModel {
        let persistence = APISpendPersistence(stateURL: dir.appending(path: "api-spend.json"), snapshotsURL: dir.appending(path: "api-spend-snapshots.json"))
        let model = APISpendModel(
            dependencies: .init(clients: [.anthropic: anthropic], keyStore: keys, persistence: persistence,
                                now: { [unowned self] in self.now }, sleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
                                lowPowerMode: { false }, jitter: { 0 }, autoPoll: false),
            settings: settings
        )
        model.bridge = bridge
        return model
    }
}
