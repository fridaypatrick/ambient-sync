import Foundation
import ServiceManagement

public enum LoginItemRegistrationState: Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case unavailable
}

@MainActor
public protocol LoginItemService: AnyObject {
    func registrationState() -> LoginItemRegistrationState
    func register() throws
    func unregister() throws
}

@MainActor
public final class SystemMainAppLoginItemService: LoginItemService {
    public init() {}

    public func registrationState() -> LoginItemRegistrationState {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

@MainActor
public final class LoginItemManager {
    private let settings: SettingsStore
    private let service: any LoginItemService

    public private(set) var isEnabled = false
    public private(set) var registrationState: LoginItemRegistrationState = .unavailable
    public private(set) var lastError: String?
    public var stateDidChange: (() -> Void)?

    public init(
        settings: SettingsStore,
        service: (any LoginItemService)? = nil
    ) {
        self.settings = settings
        self.service = service ?? SystemMainAppLoginItemService()
        reconcileToService()
    }

    public var statusMessage: String? {
        if let lastError {
            return lastError
        }

        switch registrationState {
        case .enabled, .notRegistered:
            return nil
        case .requiresApproval:
            return "Login item requires approval in System Settings."
        case .unavailable:
            return "Launch at Login is unavailable for this app installation."
        }
    }

    public func refresh() {
        reconcileToService()
    }

    public func setEnabled(_ enabled: Bool) {
        lastError = nil

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }

        reconcileToService()
    }

    private func reconcileToService() {
        registrationState = service.registrationState()
        isEnabled = registrationState == .enabled

        // Persist observed service state, never the requested state.
        settings.launchAtLoginEnabled = isEnabled
        stateDidChange?()
    }
}
