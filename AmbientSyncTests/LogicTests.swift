import Foundation
import XCTest
@testable import AmbientSync

final class LogicTests: XCTestCase {
    func testSettingsDefaultsAndPersistenceUseStableDisplayIdentity() {
        let suiteName = "AmbientSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.brightnessSyncEnabled)
        XCTAssertTrue(store.menuBarIconVisible)
        XCTAssertFalse(store.launchAtLoginEnabled)
        XCTAssertEqual(store.appearanceThresholds, AppearanceThresholds(dark: 0.25, light: 0.40))

        let descriptor = DisplayDescriptor(
            manufacturer: "Acme",
            product: "Panel 27",
            serialNumber: "SN-42",
            vendorID: 0x1234,
            productID: 0x5678,
            displayID: 99
        )
        let identity = DisplayIdentity(descriptor: descriptor)
        let sameIdentity = DisplayIdentity(descriptor: descriptor)
        XCTAssertEqual(identity, sameIdentity)
        XCTAssertEqual(identity.basis, .edid)
        XCTAssertEqual(store.range(for: identity), .defaults)

        let configuredRange = DisplayBrightnessRange(minimum: 0.10, maximum: 0.80)
        store.setRange(configuredRange, for: identity)
        XCTAssertEqual(SettingsStore(defaults: defaults).range(for: sameIdentity), configuredRange)

        let otherIdentity = DisplayIdentity(descriptor: DisplayDescriptor(displayID: 100))
        XCTAssertEqual(store.range(for: otherIdentity), .defaults)
    }

    func testFallbackDisplayIdentityIsDeterministicWithoutEDIDSerial() {
        let firstDescriptor = DisplayDescriptor(
            manufacturer: "Acme",
            product: "Panel 27",
            vendorID: 0x1234,
            productID: 0x5678,
            displayID: 99
        )
        let secondDescriptor = DisplayDescriptor(
            manufacturer: "Acme",
            product: "Panel 27",
            vendorID: 0x1234,
            productID: 0x5678,
            displayID: 100
        )

        let first = DisplayIdentity(descriptor: firstDescriptor)
        let second = DisplayIdentity(descriptor: secondDescriptor)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.settingsKey, second.settingsKey)
        XCTAssertEqual(first.basis, .fallback)
        XCTAssertTrue(first.settingsKey.hasPrefix("display.fallback-"))
    }

    func testNumericEDIDMetadataWithSerialUsesStableEDIDIdentity() {
        let first = DisplayIdentity(
            descriptor: DisplayDescriptor(
                serialNumber: "SN-42",
                vendorID: 0x1234,
                productID: 0x5678,
                displayID: 99
            )
        )
        let second = DisplayIdentity(
            descriptor: DisplayDescriptor(
                serialNumber: "SN-42",
                vendorID: 0x1234,
                productID: 0x5678,
                displayID: 100
            )
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.basis, .edid)
        XCTAssertTrue(first.settingsKey.hasPrefix("display.edid-"))
    }

    func testLinearMappingUsesTenToEightyRange() {
        let range = DisplayBrightnessRange(minimum: 0.10, maximum: 0.80)

        XCTAssertEqual(BrightnessMapper.linear(0.0, to: range), 0.10, accuracy: 0.000_001)
        XCTAssertEqual(BrightnessMapper.linear(0.5, to: range), 0.45, accuracy: 0.000_001)
        XCTAssertEqual(BrightnessMapper.linear(1.0, to: range), 0.80, accuracy: 0.000_001)

        var targets = IntegerDDCTargetSuppressor()
        XCTAssertEqual(targets.targetIfChanged(for: 0.0, range: range), 10)
        XCTAssertEqual(targets.targetIfChanged(for: 0.5, range: range), 45)
        XCTAssertEqual(targets.targetIfChanged(for: 1.0, range: range), 80)
    }

    func testThresholdNormalizationEnforcesRangeOrderAndMinimumGap() {
        let normalized = AppearanceThresholds.normalized(dark: 0.80, light: 0.20)

        XCTAssertEqual(normalized.dark, 0.20, accuracy: 0.000_001)
        XCTAssertEqual(normalized.light, 0.80, accuracy: 0.000_001)
        XCTAssertTrue(AppearanceThresholds.isValid(dark: normalized.dark, light: normalized.light))

        let narrow = AppearanceThresholds.normalized(dark: 0.30, light: 0.32)
        XCTAssertEqual(narrow.dark, 0.30, accuracy: 0.000_001)
        XCTAssertEqual(narrow.light, 0.35, accuracy: 0.000_001)
    }

    func testMeaningfulBrightnessChangeRequiresTwoPercent() {
        var filter = MeaningfulBrightnessChangeFilter()

        XCTAssertTrue(filter.accept(0.50))
        XCTAssertFalse(filter.accept(0.5199))
        XCTAssertTrue(filter.accept(0.5201))
        XCTAssertFalse(filter.accept(0.5210))
    }

    func testIntegerDDCTargetSuppressesRedundantWrites() {
        var suppressor = IntegerDDCTargetSuppressor()
        let range = DisplayBrightnessRange(minimum: 0.10, maximum: 0.80)

        XCTAssertEqual(suppressor.targetIfChanged(for: 0.50, range: range), 45)
        XCTAssertNil(suppressor.targetIfChanged(for: 0.50, range: range))
        XCTAssertEqual(suppressor.targetIfChanged(for: 0.51, range: range), 46)
    }

    func testCombinedDecisionEngineRequiresMeaningfulChangeBeforeTargetWrite() {
        var engine = BrightnessSyncDecisionEngine()
        let range = DisplayBrightnessRange(minimum: 0.10, maximum: 0.80)

        XCTAssertEqual(engine.targetForWrite(afterInternalBrightness: 0.50, range: range), 45)
        XCTAssertNil(engine.targetForWrite(afterInternalBrightness: 0.5199, range: range))
        XCTAssertEqual(engine.targetForWrite(afterInternalBrightness: 0.5201, range: range), 46)
    }

    func testAppearanceHysteresisUsesThresholdsDwellAndRedundantGuards() {
        let clock = TestClock(now: Date(timeIntervalSince1970: 0))
        var controller = AppearanceHysteresisController(clock: clock)

        XCTAssertEqual(controller.decision(for: 0.25, currentMode: .light), .request(.dark))
        XCTAssertEqual(controller.decision(for: 0.20, currentMode: .light), .noOp)

        controller.markSwitchCompleted(to: .dark)
        XCTAssertEqual(controller.decision(for: 0.30, currentMode: .dark), .noOp)
        XCTAssertEqual(controller.decision(for: 0.20, currentMode: .dark), .noOp)

        clock.now = Date(timeIntervalSince1970: 59)
        XCTAssertEqual(controller.decision(for: 0.80, currentMode: .dark), .noOp)

        clock.now = Date(timeIntervalSince1970: 60)
        XCTAssertEqual(controller.decision(for: 0.80, currentMode: .dark), .request(.light))
    }
}

private final class TestClock: AmbientClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
