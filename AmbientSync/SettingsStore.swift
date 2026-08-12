import Foundation

/// Minimal seam around UserDefaults for deterministic settings tests.
public protocol DefaultsProviding: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: DefaultsProviding {}

/// UserDefaults-backed global and per-display settings.
///
/// First-run defaults:
/// - brightness synchronization enabled
/// - menu-bar icon visible
/// - launch at login disabled
/// - dark threshold 0.25
/// - light threshold 0.40
/// - each display range 0.0...1.0
/// `SettingsStore` is shared across actor boundaries by explicit lock
/// confinement. The lock serializes every `UserDefaults` access, including
/// test doubles supplied through `DefaultsProviding`.
public final class SettingsStore: @unchecked Sendable {
    public static let brightnessSyncEnabledKey = "brightnessSyncEnabled"
    public static let menuBarIconVisibleKey = "menuBarIconVisible"
    public static let launchAtLoginEnabledKey = "launchAtLoginEnabled"
    public static let darkThresholdKey = "appearance.darkThreshold"
    public static let lightThresholdKey = "appearance.lightThreshold"

    private let defaults: any DefaultsProviding
    private let lock = NSLock()

    public init(defaults: any DefaultsProviding = UserDefaults.standard) {
        self.defaults = defaults
    }

    public var brightnessSyncEnabled: Bool {
        get { withLock { boolUnlocked(forKey: Self.brightnessSyncEnabledKey, fallback: true) } }
        set { withLock { defaults.set(newValue, forKey: Self.brightnessSyncEnabledKey) } }
    }

    public var menuBarIconVisible: Bool {
        get { withLock { boolUnlocked(forKey: Self.menuBarIconVisibleKey, fallback: true) } }
        set { withLock { defaults.set(newValue, forKey: Self.menuBarIconVisibleKey) } }
    }

    public var launchAtLoginEnabled: Bool {
        get { withLock { boolUnlocked(forKey: Self.launchAtLoginEnabledKey, fallback: false) } }
        set { withLock { defaults.set(newValue, forKey: Self.launchAtLoginEnabledKey) } }
    }

    public var appearanceThresholds: AppearanceThresholds {
        get {
            withLock {
                let storedDark = doubleUnlocked(forKey: Self.darkThresholdKey)
                let storedLight = doubleUnlocked(forKey: Self.lightThresholdKey)
                let normalized = AppearanceThresholds.normalized(
                    dark: storedDark ?? AppearanceThresholds.defaultDark,
                    light: storedLight ?? AppearanceThresholds.defaultLight
                )

                if storedDark != normalized.dark {
                    defaults.set(normalized.dark, forKey: Self.darkThresholdKey)
                }
                if storedLight != normalized.light {
                    defaults.set(normalized.light, forKey: Self.lightThresholdKey)
                }

                return normalized
            }
        }
        set {
            withLock {
                let normalized = AppearanceThresholds.normalized(dark: newValue.dark, light: newValue.light)
                defaults.set(normalized.dark, forKey: Self.darkThresholdKey)
                defaults.set(normalized.light, forKey: Self.lightThresholdKey)
            }
        }
    }

    public var darkThreshold: Double {
        get { appearanceThresholds.dark }
        set { appearanceThresholds = .normalized(dark: newValue, light: appearanceThresholds.light) }
    }

    public var lightThreshold: Double {
        get { appearanceThresholds.light }
        set { appearanceThresholds = .normalized(dark: appearanceThresholds.dark, light: newValue) }
    }

    public func range(for identity: DisplayIdentity) -> DisplayBrightnessRange {
        withLock {
            let storedMinimum = doubleUnlocked(forKey: identity.minimumSettingsKey)
            let storedMaximum = doubleUnlocked(forKey: identity.maximumSettingsKey)
            let normalized = DisplayBrightnessRange(
                minimum: storedMinimum ?? DisplayBrightnessRange.defaults.minimum,
                maximum: storedMaximum ?? DisplayBrightnessRange.defaults.maximum
            )

            if storedMinimum != normalized.minimum {
                defaults.set(normalized.minimum, forKey: identity.minimumSettingsKey)
            }
            if storedMaximum != normalized.maximum {
                defaults.set(normalized.maximum, forKey: identity.maximumSettingsKey)
            }

            return normalized
        }
    }

    public func setRange(_ range: DisplayBrightnessRange, for identity: DisplayIdentity) {
        withLock {
            let normalized = DisplayBrightnessRange(minimum: range.minimum, maximum: range.maximum)
            defaults.set(normalized.minimum, forKey: identity.minimumSettingsKey)
            defaults.set(normalized.maximum, forKey: identity.maximumSettingsKey)
        }
    }

    private func boolUnlocked(forKey key: String, fallback: Bool) -> Bool {
        guard let value = defaults.object(forKey: key) else { return fallback }
        if let number = value as? NSNumber { return number.boolValue }
        if let bool = value as? Bool { return bool }
        return fallback
    }

    private func doubleUnlocked(forKey key: String) -> Double? {
        guard let value = defaults.object(forKey: key) else { return nil }
        if let number = value as? NSNumber {
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }
        if let double = value as? Double, double.isFinite { return double }
        return nil
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
