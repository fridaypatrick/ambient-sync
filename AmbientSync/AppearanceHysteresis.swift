import Foundation

public enum AppearanceMode: String, Codable, Equatable, Sendable {
    case dark
    case light
}

/// Clock seam for deterministic dwell-time tests.
public protocol AmbientClock: AnyObject {
    var now: Date { get }
}

public final class SystemClock: AmbientClock {
    public init() {}

    public var now: Date {
        Date()
    }
}

public enum AppearanceDecision: Equatable, Sendable {
    case noOp
    case request(AppearanceMode)
}

/// Decides threshold-driven system appearance requests without performing I/O.
///
/// The caller supplies the current system appearance, so a request is never
/// emitted merely because a threshold is crossed. The caller must call
/// `markSwitchCompleted` only after the external appearance switch succeeds.
public struct AppearanceHysteresisController {
    public private(set) var thresholds: AppearanceThresholds
    public let minimumDwell: TimeInterval

    private let clock: any AmbientClock
    private var lastCompletedSwitchAt: Date?
    private var pendingRequest: AppearanceMode?

    public init(
        thresholds: AppearanceThresholds = AppearanceThresholds(),
        minimumDwell: TimeInterval = 60.0,
        clock: any AmbientClock = SystemClock()
    ) {
        self.thresholds = thresholds
        self.minimumDwell = max(minimumDwell.isFinite ? minimumDwell : 60.0, 0.0)
        self.clock = clock
        lastCompletedSwitchAt = nil
        pendingRequest = nil
    }

    public mutating func decision(
        for normalizedBrightness: Double,
        currentMode: AppearanceMode
    ) -> AppearanceDecision {
        guard normalizedBrightness.isFinite else { return .noOp }

        let desiredMode: AppearanceMode?
        if normalizedBrightness <= thresholds.dark {
            desiredMode = .dark
        } else if normalizedBrightness >= thresholds.light {
            desiredMode = .light
        } else {
            desiredMode = nil
        }

        guard let desiredMode else {
            pendingRequest = nil
            return .noOp
        }

        guard desiredMode != currentMode else {
            pendingRequest = nil
            return .noOp
        }

        if pendingRequest == desiredMode {
            return .noOp
        }
        pendingRequest = nil

        if let lastCompletedSwitchAt,
           clock.now.timeIntervalSince(lastCompletedSwitchAt) < minimumDwell {
            return .noOp
        }

        pendingRequest = desiredMode
        return .request(desiredMode)
    }

    public mutating func markSwitchCompleted(to mode: AppearanceMode) {
        markSwitchCompleted(to: mode, at: clock.now)
    }

    public mutating func markSwitchCompleted(to mode: AppearanceMode, at date: Date) {
        lastCompletedSwitchAt = date
        pendingRequest = nil
    }

    public mutating func markRequestFailed() {
        pendingRequest = nil
    }

    /// Applies a threshold edit without performing an appearance request.
    /// Pending work is discarded because it was decided using old settings.
    public mutating func updateThresholds(_ thresholds: AppearanceThresholds) {
        self.thresholds = AppearanceThresholds.normalized(
            dark: thresholds.dark,
            light: thresholds.light
        )
        pendingRequest = nil
    }
}
