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
public final class SettingsStore {
    public static let brightnessSyncEnabledKey = "brightnessSyncEnabled"
    public static let menuBarIconVisibleKey = "menuBarIconVisible"
    public static let launchAtLoginEnabledKey = "launchAtLoginEnabled"
    public static let darkThresholdKey = "appearance.darkThreshold"
    public static let lightThresholdKey = "appearance.lightThreshold"

    private let defaults: any DefaultsProviding

    public init(defaults: any DefaultsProviding = UserDefaults.standard) {
        self.defaults = defaults
    }

    public var brightnessSyncEnabled: Bool {
        get { bool(forKey: Self.brightnessSyncEnabledKey, fallback: true) }
        set { defaults.set(newValue, forKey: Self.brightnessSyncEnabledKey) }
    }

    public var menuBarIconVisible: Bool {
        get { bool(forKey: Self.menuBarIconVisibleKey, fallback: true) }
        set { defaults.set(newValue, forKey: Self.menuBarIconVisibleKey) }
    }

    public var launchAtLoginEnabled: Bool {
        get { bool(forKey: Self.launchAtLoginEnabledKey, fallback: false) }
        set { defaults.set(newValue, forKey: Self.launchAtLoginEnabledKey) }
    }

    public var appearanceThresholds: AppearanceThresholds {
        get {
            let storedDark = double(forKey: Self.darkThresholdKey)
            let storedLight = double(forKey: Self.lightThresholdKey)
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
        set {
            let normalized = AppearanceThresholds.normalized(dark: newValue.dark, light: newValue.light)
            defaults.set(normalized.dark, forKey: Self.darkThresholdKey)
            defaults.set(normalized.light, forKey: Self.lightThresholdKey)
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
        let storedMinimum = double(forKey: identity.minimumSettingsKey)
        let storedMaximum = double(forKey: identity.maximumSettingsKey)
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

    public func setRange(_ range: DisplayBrightnessRange, for identity: DisplayIdentity) {
        let normalized = DisplayBrightnessRange(minimum: range.minimum, maximum: range.maximum)
        defaults.set(normalized.minimum, forKey: identity.minimumSettingsKey)
        defaults.set(normalized.maximum, forKey: identity.maximumSettingsKey)
    }

    private func bool(forKey key: String, fallback: Bool) -> Bool {
        guard let value = defaults.object(forKey: key) else { return fallback }
        if let number = value as? NSNumber { return number.boolValue }
        if let bool = value as? Bool { return bool }
        return fallback
    }

    private func double(forKey key: String) -> Double? {
        guard let value = defaults.object(forKey: key) else { return nil }
        if let number = value as? NSNumber {
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }
        if let double = value as? Double, double.isFinite { return double }
        return nil
    }
}
