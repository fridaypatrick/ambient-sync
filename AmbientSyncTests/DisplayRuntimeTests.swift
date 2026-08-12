import Foundation
import AppKit
import CoreGraphics
import XCTest
@testable import AmbientSync

final class DisplayRuntimeTests: XCTestCase {
    func testLiveDisplayAdaptersDegradeGracefully() async {
        var directDisplayCount: UInt32 = 0
        let directResult = CGGetActiveDisplayList(0, nil, &directDisplayCount)
        XCTAssertEqual(directResult, .success)

        let records = await CoreGraphicsDisplayEnumerator().enumerate()
        XCTAssertEqual(records.count, Int(directDisplayCount))
        XCTAssertTrue(records.allSatisfy { $0.displayID != 0 })

        if let builtIn = records.first(where: \.isBuiltIn) {
            _ = await DisplayServicesBrightnessSource().readBrightness(for: builtIn.displayID)
        }
    }

    func testDDCRawValueScalesUsingCapabilityMaximum() {
        XCTAssertEqual(ddcRawVCPValue(forPercent: 50, maximum: 100), 50)
        XCTAssertEqual(ddcRawVCPValue(forPercent: 50, maximum: 254), 127)
        XCTAssertEqual(ddcRawVCPValue(forPercent: 100, maximum: 254), 254)
    }

    func testDDCRawValueClampsPercentBounds() {
        XCTAssertEqual(ddcRawVCPValue(forPercent: -1, maximum: 254), 0)
        XCTAssertEqual(ddcRawVCPValue(forPercent: 0, maximum: 254), 0)
        XCTAssertEqual(ddcRawVCPValue(forPercent: 101, maximum: 254), 254)
        XCTAssertEqual(ddcRawVCPValue(forPercent: Int.max, maximum: 254), 254)
    }

    func testDDCRawValueRoundsScaledFraction() {
        XCTAssertEqual(ddcRawVCPValue(forPercent: 50, maximum: 255), 128)
        XCTAssertEqual(ddcRawVCPValue(forPercent: 1, maximum: 254), 3)
    }

    func testNoBuiltInDisplayPausesWithoutWritingExternalBrightness() async {
        let external = makeDisplay(id: 2, builtIn: false)
        let sink = RecordingSink()
        let enumerator = TestDisplayEnumerator(records: [external])
        let provider = TestTransportProvider(
            bindings: [ExternalDisplayBinding(record: external, sink: sink)]
        )
        let manager = DisplayManager(
            enumerator: enumerator,
            externalProvider: provider,
            lifecycleNotificationCenter: NotificationCenter()
        )
        await manager.start()

        let source = SequenceBrightnessSource(values: [0.5])
        let settings = makeSettings().store
        let controller = BrightnessSyncController(
            displayRuntime: manager,
            brightnessSource: source,
            settings: settings
        )

        let didPoll = await controller.pollOnce()
        let writes = await sink.writes()
        let readCount = await source.readCount()
        XCTAssertFalse(didPoll)
        XCTAssertEqual(writes, [])
        XCTAssertEqual(readCount, 0)
        await manager.stop()
    }

    func testFirstAndMeaningfulSamplesWriteAndPublishAfterProcessing() async {
        let builtIn = makeDisplay(id: 1, builtIn: true)
        let external = makeDisplay(id: 2, builtIn: false)
        let sink = RecordingSink()
        let manager = await makeManager(
            records: [builtIn, external],
            bindings: [ExternalDisplayBinding(record: external, sink: sink)]
        )
        let source = SequenceBrightnessSource(values: [0.50, 0.5199, 0.5201])
        let callbackValues = DoubleRecorder()
        let settings = makeSettings().store
        let controller = BrightnessSyncController(
            displayRuntime: manager,
            brightnessSource: source,
            settings: settings,
            onMeaningfulBrightness: { value in
                await callbackValues.append(value)
            }
        )

        let firstPoll = await controller.pollOnce()
        let secondPoll = await controller.pollOnce()
        let thirdPoll = await controller.pollOnce()
        let writes = await sink.writes()
        let publishedValues = await callbackValues.values()
        XCTAssertTrue(firstPoll)
        XCTAssertFalse(secondPoll)
        XCTAssertTrue(thirdPoll)
        XCTAssertEqual(writes, [50, 52])
        XCTAssertEqual(publishedValues, [0.50, 0.5201])
        await manager.stop()
    }

    func testPerDisplayRangesAndIndependentTargetSuppression() async {
        let builtIn = makeDisplay(id: 1, builtIn: true)
        let firstExternal = makeDisplay(id: 2, builtIn: false)
        let secondExternal = makeDisplay(id: 3, builtIn: false)
        let firstSink = RecordingSink()
        let secondSink = RecordingSink()
        let manager = await makeManager(
            records: [builtIn, firstExternal, secondExternal],
            bindings: [
                ExternalDisplayBinding(record: firstExternal, sink: firstSink),
                ExternalDisplayBinding(record: secondExternal, sink: secondSink)
            ]
        )
        let settingsResult = makeSettings()
        settingsResult.store.setRange(
            DisplayBrightnessRange(minimum: 0.10, maximum: 0.80),
            for: firstExternal.identity
        )
        settingsResult.store.setRange(
            DisplayBrightnessRange(minimum: 0.20, maximum: 0.60),
            for: secondExternal.identity
        )
        let source = SequenceBrightnessSource(values: [0.50, 0.50, 0.5201])
        let controller = BrightnessSyncController(
            displayRuntime: manager,
            brightnessSource: source,
            settings: settingsResult.store
        )

        let firstPoll = await controller.pollOnce()
        let secondPoll = await controller.pollOnce()
        let thirdPoll = await controller.pollOnce()
        let firstWrites = await firstSink.writes()
        let secondWrites = await secondSink.writes()
        XCTAssertTrue(firstPoll)
        XCTAssertFalse(secondPoll)
        XCTAssertTrue(thirdPoll)
        XCTAssertEqual(firstWrites, [45, 46])
        XCTAssertEqual(secondWrites, [40, 41])
        await manager.stop()
    }

    func testDisabledSyncDoesNotReadOrWrite() async {
        let builtIn = makeDisplay(id: 1, builtIn: true)
        let external = makeDisplay(id: 2, builtIn: false)
        let sink = RecordingSink()
        let manager = await makeManager(
            records: [builtIn, external],
            bindings: [ExternalDisplayBinding(record: external, sink: sink)]
        )
        let source = SequenceBrightnessSource(values: [0.5])
        let settingsResult = makeSettings()
        settingsResult.store.brightnessSyncEnabled = false
        let controller = BrightnessSyncController(
            displayRuntime: manager,
            brightnessSource: source,
            settings: settingsResult.store
        )

        let didPoll = await controller.pollOnce()
        let readCount = await source.readCount()
        let writes = await sink.writes()
        XCTAssertFalse(didPoll)
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(writes, [])
        await manager.stop()
    }

    func testSettingsChangeResetsTargetsWithoutWritingUntilMeaningfulChange() async {
        let builtIn = makeDisplay(id: 1, builtIn: true)
        let external = makeDisplay(id: 2, builtIn: false)
        let sink = RecordingSink()
        let manager = await makeManager(
            records: [builtIn, external],
            bindings: [ExternalDisplayBinding(record: external, sink: sink)]
        )
        let settingsResult = makeSettings()
        let source = SequenceBrightnessSource(values: [0.50, 0.50, 0.5201])
        let controller = BrightnessSyncController(
            displayRuntime: manager,
            brightnessSource: source,
            settings: settingsResult.store
        )

        _ = await controller.pollOnce()
        settingsResult.store.setRange(
            DisplayBrightnessRange(minimum: 0.10, maximum: 0.80),
            for: external.identity
        )
        await controller.settingsDidChange()
        _ = await controller.pollOnce()
        _ = await controller.pollOnce()

        let writes = await sink.writes()
        XCTAssertEqual(writes, [50, 46])
        await manager.stop()
    }

    func testDisplayRefreshResetsStaleTargetsAndRequiresNewSinkWrite() async {
        let builtIn = makeDisplay(id: 1, builtIn: true)
        let external = makeDisplay(id: 2, builtIn: false)
        let firstSink = RecordingSink()
        let secondSink = RecordingSink()
        let provider = TestTransportProvider(
            bindings: [ExternalDisplayBinding(record: external, sink: firstSink)]
        )
        let manager = DisplayManager(
            enumerator: TestDisplayEnumerator(records: [builtIn, external]),
            externalProvider: provider,
            lifecycleNotificationCenter: NotificationCenter()
        )
        await manager.start()
        let source = SequenceBrightnessSource(values: [0.5, 0.5])
        let controller = BrightnessSyncController(
            displayRuntime: manager,
            brightnessSource: source,
            settings: makeSettings().store
        )

        let firstPoll = await controller.pollOnce()
        let firstWrites = await firstSink.writes()
        XCTAssertTrue(firstPoll)
        XCTAssertEqual(firstWrites, [50])

        await provider.setBindings([ExternalDisplayBinding(record: external, sink: secondSink)])
        await manager.refreshNow()

        let secondPoll = await controller.pollOnce()
        let firstWritesAfterRefresh = await firstSink.writes()
        let secondWrites = await secondSink.writes()
        XCTAssertTrue(secondPoll)
        XCTAssertEqual(firstWritesAfterRefresh, [50])
        XCTAssertEqual(secondWrites, [50])
        await manager.stop()
    }

    func testFailedWriteAllowsLaterMeaningfulRetryForSameTarget() async {
        let builtIn = makeDisplay(id: 1, builtIn: true)
        let external = makeDisplay(id: 2, builtIn: false)
        let sink = FailingThenRecordingSink()
        let manager = await makeManager(
            records: [builtIn, external],
            bindings: [ExternalDisplayBinding(record: external, sink: sink)]
        )
        let settingsResult = makeSettings()
        settingsResult.store.setRange(
            DisplayBrightnessRange(minimum: 0.50, maximum: 0.50),
            for: external.identity
        )
        let source = SequenceBrightnessSource(values: [0.50, 0.5201, 0.5401])
        let controller = BrightnessSyncController(
            displayRuntime: manager,
            brightnessSource: source,
            settings: settingsResult.store
        )

        _ = await controller.pollOnce()
        _ = await controller.pollOnce()
        _ = await controller.pollOnce()

        let attemptedWrites = await sink.attemptedWrites()
        let successfulWrites = await sink.successfulWrites()
        XCTAssertEqual(attemptedWrites, [50, 50])
        XCTAssertEqual(successfulWrites, [50])
        await manager.stop()
    }

    func testLifecycleDebounceInvalidatesAndRebuildsTransportHandles() async throws {
        let builtIn = makeDisplay(id: 1, builtIn: true)
        let external = makeDisplay(id: 2, builtIn: false)
        let firstSink = RecordingSink()
        let secondSink = RecordingSink()
        let provider = TestTransportProvider(
            bindings: [ExternalDisplayBinding(record: external, sink: firstSink)]
        )
        let notificationCenter = NotificationCenter()
        let manager = DisplayManager(
            enumerator: TestDisplayEnumerator(records: [builtIn, external]),
            externalProvider: provider,
            lifecycleNotificationCenter: notificationCenter,
            debounceInterval: .milliseconds(10)
        )
        await manager.start()
        let initialRebuildCount = await provider.rebuildCount()
        XCTAssertEqual(initialRebuildCount, 1)

        await provider.setBindings([ExternalDisplayBinding(record: external, sink: secondSink)])
        await manager.displayConfigurationDidChange()
        let firstInvalidationCount = await provider.invalidateCount()
        XCTAssertGreaterThanOrEqual(firstInvalidationCount, 1)
        try await Task.sleep(for: .milliseconds(40))

        var state = await manager.runtimeState()
        let rebuildCountAfterChange = await provider.rebuildCount()
        XCTAssertEqual(rebuildCountAfterChange, 2)
        XCTAssertEqual(state.externalTargets.count, 1)
        let secondSinkInvalidations = await secondSink.invalidateCount()
        XCTAssertEqual(secondSinkInvalidations, 0)

        await manager.systemWillSleep()
        state = await manager.runtimeState()
        XCTAssertTrue(state.externalTargets.isEmpty)
        let invalidationCountAfterSleep = await provider.invalidateCount()
        XCTAssertGreaterThanOrEqual(invalidationCountAfterSleep, 2)

        await manager.systemDidWake()
        try await Task.sleep(for: .milliseconds(40))
        state = await manager.runtimeState()
        XCTAssertEqual(state.externalTargets.count, 1)
        let rebuildCountAfterWake = await provider.rebuildCount()
        XCTAssertGreaterThanOrEqual(rebuildCountAfterWake, 3)

        await manager.stop()
        let rebuildsAfterStop = await provider.rebuildCount()
        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(30))
        let rebuildCountAfterNotification = await provider.rebuildCount()
        XCTAssertEqual(rebuildCountAfterNotification, rebuildsAfterStop)
    }
}

private struct SettingsResult {
    let store: SettingsStore
    let defaults: UserDefaults
    let suiteName: String
}

private func makeSettings() -> SettingsResult {
    let suiteName = "AmbientSyncTests.Runtime.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults.standard
    defaults.removePersistentDomain(forName: suiteName)
    return SettingsResult(
        store: SettingsStore(defaults: defaults),
        defaults: defaults,
        suiteName: suiteName
    )
}

private func makeDisplay(id: UInt32, builtIn: Bool) -> DisplayRecord {
    let descriptor = DisplayDescriptor(
        manufacturer: builtIn ? "Apple" : "Acme",
        product: builtIn ? "Internal" : "Panel",
        serialNumber: builtIn ? "Internal-\(id)" : "External-\(id)",
        vendorID: builtIn ? 0x0610 : 0x1234,
        productID: builtIn ? 0x0001 : UInt32(id),
        displayID: id
    )
    return DisplayRecord(
        displayID: id,
        name: builtIn ? "Built-in display" : "External display \(id)",
        descriptor: descriptor,
        isBuiltIn: builtIn
    )
}

private func makeManager(
    records: [DisplayRecord],
    bindings: [ExternalDisplayBinding]
) async -> DisplayManager {
    let manager = DisplayManager(
        enumerator: TestDisplayEnumerator(records: records),
        externalProvider: TestTransportProvider(bindings: bindings),
        lifecycleNotificationCenter: NotificationCenter()
    )
    await manager.start()
    return manager
}

private actor TestDisplayEnumerator: DisplayEnumerator {
    private var records: [DisplayRecord]

    init(records: [DisplayRecord]) {
        self.records = records
    }

    func enumerate() async -> [DisplayRecord] {
        records
    }
}

private actor TestTransportProvider: ExternalDisplayTransportProvider {
    private var bindings: [ExternalDisplayBinding]
    private var rebuilds = 0
    private var invalidations = 0

    init(bindings: [ExternalDisplayBinding]) {
        self.bindings = bindings
    }

    func rebuild(for displays: [DisplayRecord]) async -> [ExternalDisplayBinding] {
        rebuilds += 1
        let displayIDs = Set(displays.map(\.displayID))
        return bindings.filter { displayIDs.contains($0.record.displayID) }
    }

    func invalidate() async {
        invalidations += 1
    }

    func setBindings(_ bindings: [ExternalDisplayBinding]) {
        self.bindings = bindings
    }

    func rebuildCount() -> Int {
        rebuilds
    }

    func invalidateCount() -> Int {
        invalidations
    }
}

private actor RecordingSink: ExternalBrightnessSink {
    private var recordedWrites: [Int] = []
    private var recordedInvalidations = 0

    func writeBrightness(_ percent: Int) async -> Bool {
        recordedWrites.append(percent)
        return true
    }

    func invalidate() async {
        recordedInvalidations += 1
    }

    func writes() -> [Int] {
        recordedWrites
    }

    func invalidateCount() -> Int {
        recordedInvalidations
    }
}

private actor FailingThenRecordingSink: ExternalBrightnessSink {
    private var outcomes = [false, true]
    private var attempted = [Int]()
    private var successful = [Int]()

    func writeBrightness(_ percent: Int) async -> Bool {
        attempted.append(percent)
        let outcome = outcomes.isEmpty ? true : outcomes.removeFirst()
        if outcome {
            successful.append(percent)
        }
        return outcome
    }

    func invalidate() async {}

    func attemptedWrites() -> [Int] {
        attempted
    }

    func successfulWrites() -> [Int] {
        successful
    }
}

private actor SequenceBrightnessSource: BuiltInBrightnessSource {
    private var values: [Double?]
    private var reads = 0

    init(values: [Double?]) {
        self.values = values
    }

    func readBrightness(for displayID: UInt32) async -> Double? {
        _ = displayID
        reads += 1
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }

    func readCount() -> Int {
        reads
    }
}

private actor DoubleRecorder {
    private var recordedValues: [Double] = []

    func append(_ value: Double) {
        recordedValues.append(value)
    }

    func values() -> [Double] {
        recordedValues
    }
}
