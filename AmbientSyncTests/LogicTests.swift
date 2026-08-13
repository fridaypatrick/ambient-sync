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

    func testLocalizedDisplayProductLabelDoesNotChangePersistedIdentity() {
        let descriptor = DisplayDescriptor(
            serialNumber: "SN-42",
            vendorID: 0x1234,
            productID: 0x5678
        )
        let englishRecord = DisplayRecord(
            displayID: 99,
            name: "Studio Display",
            descriptor: descriptor,
            isBuiltIn: false
        )
        let localizedRecord = DisplayRecord(
            displayID: 99,
            name: "Écran du studio",
            descriptor: descriptor,
            isBuiltIn: false
        )

        // Localized labels feed DisplayRecord.name only. The descriptor used
        // by persistence contains stable vendor/model/serial metadata.
        XCTAssertNotEqual(englishRecord.name, localizedRecord.name)
        XCTAssertEqual(englishRecord.identity, localizedRecord.identity)
        XCTAssertEqual(englishRecord.identity.settingsKey, localizedRecord.identity.settingsKey)
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

    func testDisplayRangeNormalizationMaintainsOrderedPercentageBounds() {
        let normalized = DisplayBrightnessRange(minimum: 0.90, maximum: 0.10)

        XCTAssertEqual(normalized.minimum, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(normalized.maximum, 0.90, accuracy: 0.000_001)
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

    func testAssumedMaximumDefaultsPersistsAndClampsPerDisplayIdentity() {
        let suiteName = "AmbientSyncTests.AssumedMaximum.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let identity = DisplayIdentity(
            descriptor: DisplayDescriptor(
                manufacturer: "Samsung",
                product: "LS34A650U",
                serialNumber: "SN-42"
            )
        )
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.assumedMaximum(for: identity), 100)
        XCTAssertEqual(store.setAssumedMaximum(255, for: identity), 255)
        XCTAssertEqual(SettingsStore(defaults: defaults).assumedMaximum(for: identity), 255)
        XCTAssertEqual(store.setAssumedMaximum(0, for: identity), 1)
        XCTAssertEqual(store.setAssumedMaximum(65_536, for: identity), UInt16.max)
        XCTAssertEqual(SettingsStore(defaults: defaults).assumedMaximum(for: identity), UInt16.max)
    }

    func testWriteOnlyProbeFallbackRequiresHighConfidenceAndPreservesVerifiedReadPath() {
        XCTAssertEqual(
            ddcProbeClassification(
                readSucceeded: true,
                readMaximum: 254,
                matchConfidenceIsHigh: false,
                assumedMaximum: 100
            ),
            .verified(maximum: 254)
        )
        XCTAssertEqual(
            ddcProbeClassification(
                readSucceeded: false,
                readMaximum: 0,
                matchConfidenceIsHigh: true,
                assumedMaximum: 255
            ),
            .writeOnlyAssumed(maximum: 255)
        )
        XCTAssertEqual(
            ddcProbeClassification(
                readSucceeded: false,
                readMaximum: 0,
                matchConfidenceIsHigh: false,
                assumedMaximum: 255
            ),
            .unsupported
        )
    }

    func testHighConfidenceClassificationUsesLocationOrThreeIndependentSignals() {
        XCTAssertEqual(
            ASDDCClassifyMatchConfidence(false, 2),
            ASDDCMatchConfidenceLow
        )
        XCTAssertEqual(
            ASDDCClassifyMatchConfidence(false, 3),
            ASDDCMatchConfidenceHigh
        )
        // Samsung-like service match: location score is decisive even when
        // VCP brightness read later fails.
        XCTAssertEqual(
            ASDDCClassifyMatchConfidence(true, 0),
            ASDDCMatchConfidenceHigh
        )
    }

    func testMatchEvidenceRejectsZeroAndDefaultMetadata() {
        let evidence = scoreEvidence(
            displayLocation: "",
            serviceLocation: "",
            displayProductName: "",
            serviceProductName: "",
            displaySerial: 0,
            serviceSerial: 0,
            vendorID: 0,
            productID: 0,
            manufactureYear: 0,
            manufactureWeek: 0,
            horizontalSize: 0,
            verticalSize: 0,
            serviceEDIDUUID: "00000000-0000-0000-0000-000000000000"
        )

        XCTAssertEqual(evidence.score, 0)
        XCTAssertEqual(evidence.independentSignalCount, 0)
        XCTAssertEqual(
            ASDDCClassifyAssignedMatch(evidence, nil, 0, nil, 0),
            ASDDCMatchConfidenceNone
        )
    }

    func testValidSamsungLikeLocationIsHighConfidenceInAssignmentPath() {
        let evidence = scoreEvidence(
            displayLocation: "IOService:/display/samsung",
            serviceLocation: "IOService:/display/samsung"
        )

        XCTAssertTrue(evidence.locationMatch)
        XCTAssertEqual(
            ASDDCClassifyAssignedMatch(evidence, nil, 0, nil, 0),
            ASDDCMatchConfidenceHigh
        )
    }

    func testThreeValidIndependentMetadataDimensionsAreHighConfidence() {
        let evidence = scoreEvidence(
            vendorID: 0x4C2D,
            productID: 0x7145,
            manufactureYear: 2022,
            manufactureWeek: 26,
            horizontalSize: 800,
            verticalSize: 340,
            serviceEDIDUUID: "4C2D4571-0000-0000-1A20-0104B5502278"
        )

        XCTAssertEqual(evidence.independentSignalCount, 3)
        XCTAssertEqual(
            ASDDCClassifyAssignedMatch(evidence, nil, 0, nil, 0),
            ASDDCMatchConfidenceHigh
        )
    }

    func testVendorAndProductSlicesCountAsOneLowConfidenceDimension() {
        let evidence = scoreEvidence(
            vendorID: 0x4C2D,
            productID: 0x7145,
            serviceEDIDUUID: "4C2D4571-0000-0000-0000-000000000000"
        )

        XCTAssertEqual(evidence.independentSignalCount, 1)
        XCTAssertEqual(
            ASDDCClassifyAssignedMatch(evidence, nil, 0, nil, 0),
            ASDDCMatchConfidenceLow
        )
    }

    func testEqualHighConfidenceAssignmentTieIsNotWriteOnlyEligible() {
        let selected = scoreEvidence(
            vendorID: 0x4C2D,
            productID: 0x7145,
            manufactureYear: 2022,
            manufactureWeek: 26,
            horizontalSize: 800,
            verticalSize: 340,
            serviceEDIDUUID: "4C2D4571-0000-0000-1A20-0104B5502278"
        )
        var tiedAlternative = selected

        XCTAssertEqual(
            ASDDCClassifyAssignedMatch(
                selected,
                &tiedAlternative,
                1,
                nil,
                0
            ),
            ASDDCMatchConfidenceLow
        )
    }

    func testDisplaySupportLabelsDoNotOverclaimWriteOnlyVerification() {
        XCTAssertTrue(DisplaySupportStatus.verifiedExternal.userFacingLabel.contains("verified"))
        XCTAssertTrue(DisplaySupportStatus.writeOnlyExternal.userFacingLabel.contains("unverified (write-only)"))
        XCTAssertTrue(DisplaySupportStatus.degradedWriteOnlyExternal.userFacingLabel.contains("degraded"))
        XCTAssertTrue(DisplaySupportStatus.degradedWriteOnlyExternal.userFacingLabel.contains("unverified"))
    }
}

private func scoreEvidence(
    displayLocation: String = "",
    serviceLocation: String = "",
    displayProductName: String = "",
    serviceProductName: String = "",
    displaySerial: Int64 = 0,
    serviceSerial: Int64 = 0,
    vendorID: Int64 = 0,
    productID: Int64 = 0,
    manufactureYear: Int64 = 0,
    manufactureWeek: Int64 = 0,
    horizontalSize: Int64 = 0,
    verticalSize: Int64 = 0,
    serviceEDIDUUID: String = ""
) -> ASDDCMatchEvidence {
    displayLocation.withCString { displayLocationPointer in
        serviceLocation.withCString { serviceLocationPointer in
            displayProductName.withCString { displayProductNamePointer in
                serviceProductName.withCString { serviceProductNamePointer in
                    serviceEDIDUUID.withCString { serviceEDIDUUIDPointer in
                        ASDDCScoreMatchEvidence(
                            displayLocationPointer,
                            serviceLocationPointer,
                            displayProductNamePointer,
                            serviceProductNamePointer,
                            displaySerial,
                            serviceSerial,
                            manufactureYear,
                            manufactureWeek,
                            vendorID,
                            productID,
                            horizontalSize,
                            verticalSize,
                            serviceEDIDUUIDPointer
                        )
                    }
                }
            }
        }
    }
}

private final class TestClock: AmbientClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
