import AppKit
import Foundation

public enum AppearanceAutomationError: Error, Equatable, LocalizedError, Sendable {
    case permissionDenied
    case unavailable
    case invalidResponse
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "AmbientSync is not permitted to control System Events."
        case .unavailable:
            return "System Events appearance automation is unavailable."
        case .invalidResponse:
            return "System Events returned an invalid appearance response."
        case .requestFailed(let message):
            return message
        }
    }
}

@MainActor
public protocol SystemAppearanceAdapter: AnyObject {
    func currentMode() throws -> AppearanceMode
    func setMode(_ mode: AppearanceMode) throws
}

public enum AppearanceAutomationStatus: Equatable, Sendable {
    case notAttempted
    case operational
    case permissionDenied
    case failed(String)

    public var userMessage: String {
        switch self {
        case .notAttempted:
            return "Appearance automation requests access only after a brightness update reaches a threshold."
        case .operational:
            return "Appearance automation is active."
        case .permissionDenied:
            return "AmbientSync needs permission to control System Events. Open System Settings → Privacy & Security → Automation and allow AmbientSync."
        case .failed(let message):
            return "Appearance automation failed: \(message)"
        }
    }
}

/// Coordinates appearance reads and writes on the main actor. The adapter is
/// never touched while Settings is being constructed or presented.
@MainActor
public final class AppearanceAutomationController {
    private let adapter: any SystemAppearanceAdapter
    private var hysteresis: AppearanceHysteresisController

    public private(set) var status: AppearanceAutomationStatus = .notAttempted
    public var statusDidChange: ((AppearanceAutomationStatus) -> Void)?

    public init(
        adapter: any SystemAppearanceAdapter,
        thresholds: AppearanceThresholds = AppearanceThresholds(),
        minimumDwell: TimeInterval = 60.0,
        clock: any AmbientClock = SystemClock()
    ) {
        self.adapter = adapter
        hysteresis = AppearanceHysteresisController(
            thresholds: thresholds,
            minimumDwell: minimumDwell,
            clock: clock
        )
    }

    public func updateThresholds(_ thresholds: AppearanceThresholds) {
        hysteresis.updateThresholds(thresholds)
    }

    /// Evaluates one meaningful built-in brightness sample. Values between
    /// thresholds do not read System Events and therefore do not trigger TCC.
    public func evaluate(brightness: Double) {
        guard brightness.isFinite else { return }
        let thresholds = hysteresis.thresholds
        guard brightness <= thresholds.dark || brightness >= thresholds.light else {
            return
        }

        do {
            let currentMode = try adapter.currentMode()
            switch hysteresis.decision(for: brightness, currentMode: currentMode) {
            case .noOp:
                setStatus(.operational)
            case .request(let requestedMode):
                do {
                    try adapter.setMode(requestedMode)
                    hysteresis.markSwitchCompleted(to: requestedMode)
                    setStatus(.operational)
                } catch {
                    hysteresis.markRequestFailed()
                    setStatus(Self.status(for: error))
                }
            }
        } catch {
            hysteresis.markRequestFailed()
            setStatus(Self.status(for: error))
        }
    }

    public static func status(for error: Error) -> AppearanceAutomationStatus {
        if let appearanceError = error as? AppearanceAutomationError,
           appearanceError == .permissionDenied {
            return .permissionDenied
        }

        let nsError = error as NSError
        if nsError.code == -1743 {
            return .permissionDenied
        }

        let message = error.localizedDescription
        return .failed(message.isEmpty ? "Unknown System Events error." : message)
    }

    private func setStatus(_ nextStatus: AppearanceAutomationStatus) {
        guard status != nextStatus else { return }
        status = nextStatus
        statusDidChange?(nextStatus)
    }
}

/// Apple Events adapter for System Events. The first call to either method
/// may invoke TCC Automation authorization; Settings never calls this class.
@MainActor
public final class SystemEventsAppearanceAdapter: SystemAppearanceAdapter {
    public init() {}

    public func currentMode() throws -> AppearanceMode {
        let result = try execute(
            """
            tell application "System Events"
                tell appearance preferences
                    return dark mode
                end tell
            end tell
            """
        )

        guard result.descriptorType == typeBoolean else {
            throw AppearanceAutomationError.invalidResponse
        }
        return result.booleanValue ? .dark : .light
    }

    public func setMode(_ mode: AppearanceMode) throws {
        let value = mode == .dark ? "true" : "false"
        _ = try execute(
            """
            tell application "System Events"
                tell appearance preferences
                    set dark mode to \(value)
                end tell
            end tell
            """
        )
    }

    private func execute(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw AppearanceAutomationError.unavailable
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            throw Self.map(error: error)
        }
        return result
    }

    private static func map(error: NSDictionary?) -> AppearanceAutomationError {
        let errorNumber = (error?["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
        if errorNumber == -1743 {
            return .permissionDenied
        }

        let message = error?["NSAppleScriptErrorMessage"] as? String
        return .requestFailed(message ?? "System Events returned an Apple Events error.")
    }
}
