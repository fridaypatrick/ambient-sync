import Foundation

/// Normalized external-display brightness bounds.
public struct DisplayBrightnessRange: Codable, Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double

    public init(minimum: Double, maximum: Double) {
        let safeMinimum = Self.clamp(minimum, fallback: 0.0)
        let safeMaximum = Self.clamp(maximum, fallback: 1.0)

        if safeMinimum <= safeMaximum {
            self.minimum = safeMinimum
            self.maximum = safeMaximum
        } else {
            self.minimum = safeMaximum
            self.maximum = safeMinimum
        }
    }

    public static let defaults = DisplayBrightnessRange(minimum: 0.0, maximum: 1.0)

    private static func clamp(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0.0), 1.0)
    }
}

/// Appearance thresholds kept valid at all times.
public struct AppearanceThresholds: Codable, Equatable, Sendable {
    public static let defaultDark = 0.25
    public static let defaultLight = 0.40
    public static let minimumGap = 0.05

    public let dark: Double
    public let light: Double

    public init(dark: Double = AppearanceThresholds.defaultDark, light: Double = AppearanceThresholds.defaultLight) {
        let normalized = Self.normalized(dark: dark, light: light)
        self.dark = normalized.dark
        self.light = normalized.light
    }

    public var gap: Double {
        light - dark
    }

    /// Returns thresholds clamped to 0...1, ordered dark-before-light, and
    /// separated by at least `minimumGap`.
    public static func normalized(
        dark: Double,
        light: Double,
        minimumGap: Double = AppearanceThresholds.minimumGap
    ) -> AppearanceThresholds {
        let requiredGap = min(max(minimumGap.isFinite ? minimumGap : Self.minimumGap, 0.0), 1.0)
        let safeDark = clamp(dark, fallback: Self.defaultDark)
        let safeLight = clamp(light, fallback: Self.defaultLight)
        let lower = min(safeDark, safeLight)
        let upper = max(safeDark, safeLight)
        let normalizedDark = min(lower, 1.0 - requiredGap)
        let normalizedLight = max(upper, normalizedDark + requiredGap)

        return AppearanceThresholds(normalizedDark: normalizedDark, normalizedLight: min(normalizedLight, 1.0))
    }

    public static func isValid(
        dark: Double,
        light: Double,
        minimumGap: Double = AppearanceThresholds.minimumGap
    ) -> Bool {
        dark.isFinite && light.isFinite &&
            dark >= 0.0 && dark <= 1.0 &&
            light >= 0.0 && light <= 1.0 &&
            light - dark >= minimumGap &&
            dark < light
    }

    private init(normalizedDark: Double, normalizedLight: Double) {
        dark = normalizedDark
        light = normalizedLight
    }

    private static func clamp(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0.0), 1.0)
    }
}

public enum BrightnessMapper {
    /// Maps normalized internal brightness into a configured external range.
    public static func linear(_ normalizedBrightness: Double, to range: DisplayBrightnessRange) -> Double {
        let input: Double
        if normalizedBrightness.isFinite {
            input = min(max(normalizedBrightness, 0.0), 1.0)
        } else {
            input = 0.0
        }

        return range.minimum + input * (range.maximum - range.minimum)
    }
}

/// Accepts the first sample, then only samples changing by at least 0.02.
public struct MeaningfulBrightnessChangeFilter: Equatable, Sendable {
    public let tolerance: Double
    public private(set) var lastAcceptedValue: Double?

    public init(tolerance: Double = 0.02) {
        self.tolerance = max(tolerance.isFinite ? tolerance : 0.02, 0.0)
        lastAcceptedValue = nil
    }

    public mutating func accept(_ normalizedBrightness: Double) -> Bool {
        guard normalizedBrightness.isFinite else { return false }

        let value = min(max(normalizedBrightness, 0.0), 1.0)
        guard let lastAcceptedValue else {
            self.lastAcceptedValue = value
            return true
        }

        guard abs(value - lastAcceptedValue) >= tolerance else { return false }
        self.lastAcceptedValue = value
        return true
    }

    public mutating func reset() {
        lastAcceptedValue = nil
    }
}

/// Converts mapped normalized brightness to integer DDC percentage targets and
/// suppresses repeated writes for the same target.
public struct IntegerDDCTargetSuppressor: Equatable, Sendable {
    public private(set) var lastTarget: Int?

    public init() {
        lastTarget = nil
    }

    public mutating func targetIfChanged(
        for normalizedBrightness: Double,
        range: DisplayBrightnessRange
    ) -> Int? {
        guard normalizedBrightness.isFinite else { return nil }
        let target = Int((BrightnessMapper.linear(normalizedBrightness, to: range) * 100.0).rounded())
        guard target != lastTarget else { return nil }

        lastTarget = target
        return target
    }

    public mutating func reset() {
        lastTarget = nil
    }

    public mutating func rollback(to previousTarget: Int?) {
        lastTarget = previousTarget
    }
}

/// Pure decision pipeline used by a future display transport coordinator.
public struct BrightnessSyncDecisionEngine: Equatable, Sendable {
    public private(set) var changeFilter: MeaningfulBrightnessChangeFilter
    public private(set) var targetSuppressor: IntegerDDCTargetSuppressor

    public init(
        tolerance: Double = 0.02,
        targetSuppressor: IntegerDDCTargetSuppressor = IntegerDDCTargetSuppressor()
    ) {
        changeFilter = MeaningfulBrightnessChangeFilter(tolerance: tolerance)
        self.targetSuppressor = targetSuppressor
    }

    public mutating func targetForWrite(
        afterInternalBrightness normalizedBrightness: Double,
        range: DisplayBrightnessRange
    ) -> Int? {
        guard changeFilter.accept(normalizedBrightness) else { return nil }
        return targetSuppressor.targetIfChanged(for: normalizedBrightness, range: range)
    }
}
