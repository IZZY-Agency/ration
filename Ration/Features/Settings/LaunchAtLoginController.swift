import Combine
import ServiceManagement

enum LaunchAtLoginServiceStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

@MainActor
protocol LaunchAtLoginService: AnyObject {
    var status: LaunchAtLoginServiceStatus { get }

    func register() async throws
    func unregister() async throws
    func openSystemSettings()
}

@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginService {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: LaunchAtLoginServiceStatus {
        switch service.status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .notFound
        }
    }

    func register() async throws {
        try service.register()
    }

    func unregister() async throws {
        try await service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

enum LaunchAtLoginState: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var state: LaunchAtLoginState
    @Published private(set) var errorMessage: String?

    private let service: any LaunchAtLoginService

    init(service: any LaunchAtLoginService = SystemLaunchAtLoginService()) {
        self.service = service
        state = Self.state(for: service.status)
    }

    var isEnabled: Bool {
        switch state {
        case .enabled, .requiresApproval:
            true
        case .disabled:
            false
        }
    }

    var explanation: String? {
        switch state {
        case .requiresApproval:
            "Allow Ration in System Settings → General → Login Items."
        case .disabled, .enabled:
            nil
        }
    }

    func refresh() {
        state = Self.state(for: service.status)
    }

    func setEnabled(_ shouldEnable: Bool) async {
        errorMessage = nil

        do {
            if shouldEnable {
                try await service.register()
            } else {
                try await service.unregister()
            }
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }

    private static func state(
        for status: LaunchAtLoginServiceStatus
    ) -> LaunchAtLoginState {
        switch status {
        case .notRegistered, .notFound:
            // Apple documents `.notFound` as "the framework couldn't find this
            // service". For the main app that is what an app that has never
            // called `register()` gets: backgroundtaskmanagementd logs the
            // lookup as "record not found" (seen on macOS 27 with a Developer
            // ID signed build in /Applications). Whatever the cause, the
            // actionable response is the same — offer the toggle, off — and a
            // registration that genuinely fails surfaces through `errorMessage`.
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        }
    }
}
