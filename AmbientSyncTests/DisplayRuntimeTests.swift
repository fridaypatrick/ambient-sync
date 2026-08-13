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
        XCTAssertEqual(ddcRawVCPValue(forPercent: 100, maximum: 100), 100)
        XCTAssertEqual(ddcRawVCPValue(forPercent: 0, maximum: 255), 0)
        XCTAssertEqual(ddcRawVCPValue(forPercent: 50, maximum: 254), 127)
        XCTAssertEqual(ddcRawVCPValue(forPercent: 50, maximum: 255), 128)
        XCTAssertEqual(ddcRawVCPValue(forPercent: 100, maximum: 255), 255)
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

    func testDDCReplyParserAcceptsValidGetVCPReply() {
        let feature: UInt8 = 0x10
        let reply = makeVCPReply(
            feature: feature,
            maximum: 254,
            current: 127
        )
        var current: UInt16 = 0
        var maximum: UInt16 = 0
        let accepted = reply.withUnsafeBufferPointer { buffer in
            ASDDCParseVCPReply(
                buffer.baseAddress,
                buffer.count,
                feature,
                &current,
                &maximum
            )
        }

        XCTAssertTrue(accepted)
        XCTAssertEqual(current, 127)
        XCTAssertEqual(maximum, 254)
    }

    func testDDCReplyParserRejectsInvalidGetVCPReplies() {
        let feature: UInt8 = 0x10
        let invalidReplies: [[UInt8]] = [
            makeVCPReply(feature: feature, maximum: 254, current: 127, sourceAddress: 0x03),
            makeVCPReply(feature: feature, maximum: 254, current: 127, payloadLength: 0x07),
            makeVCPReply(feature: feature, maximum: 254, current: 127, opcode: 0x01),
            makeVCPReply(feature: feature, maximum: 254, current: 127, result: 0x01),
            makeVCPReply(feature: 0x12, maximum: 254, current: 127),
            makeVCPReply(feature: feature, maximum: 254, current: 127, responseType: 0x01),
            makeVCPReply(feature: feature, maximum: 0, current: 0),
            makeVCPReply(feature: feature, maximum: 100, current: 101),
            Array(makeVCPReply(feature: feature, maximum: 254, current: 127).dropLast())
        ]

        for reply in invalidReplies {
            var current: UInt16 = 0
            var maximum: UInt16 = 0
            let accepted = reply.withUnsafeBufferPointer { buffer in
                ASDDCParseVCPReply(
                    buffer.baseAddress,
                    buffer.count,
                    feature,
                    &current,
                    &maximum
                )
            }
            XCTAssertFalse(accepted, "Unexpectedly accepted reply: \(reply)")
        }
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

    func testThreeConsecutiveWriteFailuresPauseWithoutFourthAndRetryReenablesOnMeaningfulEvent() async {
        let builtIn = makeDisplay(id: 1, builtIn: true)
        let external = makeDisplay(id: 2, builtIn: false)
        let sink = ConfigurableSink(outcomes: [false, false, false, true])
        let manager = await makeManager(
            records: [builtIn, external],
            bindings: [ExternalDisplayBinding(record: external, sink: sink)]
        )
        let settings = makeSettings()
        settings.store.setRange(
            DisplayBrightnessRange(minimum: 0.50, maximum: 0.50),
            for: external.identity
        )
        let source = SequenceBrightnessSource(values: [0.50, 0.5201, 0.5401, 0.5601, 0.5901])
        let controller = BrightnessSyncController(
            displayRuntime: manager,
            brightnessSource: source,
            settings: settings.store
        )

        _ = await controller.pollOnce()
        _ = await controller.pollOnce()
        _ = await controller.pollOnce()
        _ = await controller.pollOnce()
        let attemptsBeforeRetry = await sink.attemptedWrites()
        XCTAssertEqual(attemptsBeforeRetry, [50, 50, 50])

        let key = DisplayTargetKey(identity: external.identity, displayID: external.displayID)
        var state = await manager.runtimeState()
        XCTAssertEqual(state.snapshot.displays.first(where: { $0.record == external })?.support, .degradedExternal)

        await controller.retryTarget(key)
        state = await manager.runtimeState()
        XCTAssertEqual(state.snapshot.displays.first(where: { $0.record == external })?.support, .verifiedExternal)
        let attemptsAfterRetry = await sink.attemptedWrites()
        XCTAssertEqual(attemptsAfterRetry, [50, 50, 50])

        _ = await controller.pollOnce()
        let attemptsAfterMeaningfulEvent = await sink.attemptedWrites()
        let successfulAfterRetry = await sink.successfulWrites()
        XCTAssertEqual(attemptsAfterMeaningfulEvent, [50, 50, 50, 50])
        XCTAssertEqual(successfulAfterRetry, [50])
        await manager.stop()
    }

    func testWriteCutoffPersistsAcrossDisableMissingBuiltInAndControllerRestart() async throws {
        let builtIn = makeDisplay(id: 1, builtIn: true)
        let external = makeDisplay(id: 2, builtIn: false)
        let sink = ConfigurableSink(outcomes: [false, false, false, true])
        let runtime = MutableRuntimeProvider(builtIn: builtIn, external: external, sink: sink)
        let settings = makeSettings()
        settings.store.setRange(
            DisplayBrightnessRange(minimum: 0.50, maximum: 0.50),
            for: external.identity
        )
        let source = SequenceBrightnessSource(
            values: [0.50, 0.5201, 0.5401, 0.5601, 0.5801, 0.6001, 0.6201]
        )
        let controller = BrightnessSyncController(
            displayRuntime: runtime,
            brightnessSource: source,
            settings: settings.store,
            pollInterval: .seconds(3_600)
        )
        let key = DisplayTargetKey(identity: external.identity, displayID: external.displayID)

        _ = await controller.pollOnce()
        _ = await controller.pollOnce()
        _ = await controller.pollOnce()
        let attemptsAfterCutoff = await sink.attemptedWrites()
        XCTAssertEqual(attemptsAfterCutoff, [50, 50, 50])
        let degradedAfterCutoff = await runtime.isDegraded()
        XCTAssertTrue(degradedAfterCutoff)

        settings.store.brightnessSyncEnabled = false
        await controller.settingsDidChange()
        let didPollWhileDisabled = await controller.pollOnce()
        XCTAssertFalse(didPollWhileDisabled)
        settings.store.brightnessSyncEnabled = true
        await controller.settingsDidChange()
        _ = await controller.pollOnce()
        let attemptsAfterReenable = await sink.attemptedWrites()
        XCTAssertEqual(attemptsAfterReenable, [50, 50, 50])

        await runtime.setBuiltIn(nil)
        let didPollWithoutBuiltIn = await controller.pollOnce()
        XCTAssertFalse(didPollWithoutBuiltIn)
        await runtime.setBuiltIn(builtIn)
        _ = await controller.pollOnce()
        let attemptsAfterBuiltInReturn = await sink.attemptedWrites()
        XCTAssertEqual(attemptsAfterBuiltInReturn, [50, 50, 50])

        await controller.start()
        try await Task.sleep(for: .milliseconds(20))
        await controller.stop()
        let attemptsAfterRestart = await sink.attemptedWrites()
        XCTAssertEqual(attemptsAfterRestart, [50, 50, 50])

        await controller.retryTarget(key)
        _ = await controller.pollOnce()
        let attemptsAfterRetry = await sink.attemptedWrites()
        XCTAssertEqual(attemptsAfterRetry, [50, 50, 50, 50])
        let degradedAfterRetry = await runtime.isDegraded()
        XCTAssertFalse(degradedAfterRetry)
    }

    func testStaleFailureAfterRefreshDoesNotDegradeNewWriteOnlyTarget() async {
        let builtIn = makeDisplay(id: 1, builtIn: true)
        let external = makeDisplay(id: 2, builtIn: false)
        let writeGate = WriteGate()
        let staleSink = BlockingWriteSink(gate: writeGate)
        let freshSink = RecordingSink()
        let provider = TestTransportProvider(
            bindings: [
                ExternalDisplayBinding(
                    record: external,
                    sink: staleSink,
                    capability: .writeOnlyAssumed(maximum: 100)
                )
            ]
        )
        let manager = DisplayManager(
            enumerator: TestDisplayEnumerator(records: [builtIn, external]),
            externalProvider: provider,
            lifecycleNotificationCenter: NotificationCenter()
        )
        await manager.start()

        let settings = makeSettings()
        settings.store.setRange(
            DisplayBrightnessRange(minimum: 0.50, maximum: 0.50),
            for: external.identity
        )
        let source = SequenceBrightnessSource(values: [0.50, 0.5201])
        let controller = BrightnessSyncController(
            displayRuntime: manager,
            brightnessSource: source,
            settings: settings.store
        )

        let stalePoll = Task { await controller.pollOnce() }
        await writeGate.waitUntilStarted()

        await provider.setBindings([
            ExternalDisplayBinding(
                record: external,
                sink: freshSink,
                capability: .writeOnlyAssumed(maximum: 100)
            )
        ])
        await manager.refreshNow()
        let refreshedState = await manager.runtimeState()
        XCTAssertEqual(refreshedState.snapshot.generation, 2)
        XCTAssertEqual(
            refreshedState.snapshot.displays.first(where: { $0.record == external })?.support,
            .writeOnlyExternal
        )

        await writeGate.release(result: false)
        let stalePollResult = await stalePoll.value
        XCTAssertTrue(stalePollResult)

        let stateAfterStaleFailure = await manager.runtimeState()
        XCTAssertEqual(
            stateAfterStaleFailure.snapshot.displays.first(where: { $0.record == external })?.support,
            .writeOnlyExternal
        )
        let freshWritesBeforeNextPoll = await freshSink.writes()
        XCTAssertEqual(freshWritesBeforeNextPoll, [])

        _ = await controller.pollOnce()
        let freshWritesAfterNextPoll = await freshSink.writes()
        XCTAssertEqual(freshWritesAfterNextPoll, [50])
        await manager.stop()
    }

    func testStaleSuccessAfterRefreshDoesNotClearNewTargetDegradedStatus() async {
        let builtIn = makeDisplay(id: 1, builtIn: true)
        let external = makeDisplay(id: 2, builtIn: false)
        let writeGate = WriteGate()
        let staleSink = BlockingWriteSink(gate: writeGate)
        let freshSink = RecordingSink()
        let provider = TestTransportProvider(
            bindings: [
                ExternalDisplayBinding(
                    record: external,
                    sink: staleSink,
                    capability: .writeOnlyAssumed(maximum: 100)
                )
            ]
        )
        let manager = DisplayManager(
            enumerator: TestDisplayEnumerator(records: [builtIn, external]),
            externalProvider: provider,
            lifecycleNotificationCenter: NotificationCenter()
        )
        await manager.start()

        let settings = makeSettings()
        settings.store.setRange(
            DisplayBrightnessRange(minimum: 0.50, maximum: 0.50),
            for: external.identity
        )
        let source = SequenceBrightnessSource(values: [0.50])
        let controller = BrightnessSyncController(
            displayRuntime: manager,
            brightnessSource: source,
            settings: settings.store
        )

        let stalePoll = Task { await controller.pollOnce() }
        await writeGate.waitUntilStarted()
        await provider.setBindings([
            ExternalDisplayBinding(
                record: external,
                sink: freshSink,
                capability: .writeOnlyAssumed(maximum: 100)
            )
        ])
        await manager.refreshNow()
        let refreshedState = await manager.runtimeState()
        guard let freshTarget = refreshedState.externalTargets.first else {
            XCTFail("Expected refreshed external target")
            return
        }
        await manager.markTargetDegraded(
            freshTarget.key,
            generation: freshTarget.generation
        )

        await writeGate.release(result: true)
        let stalePollResult = await stalePoll.value
        XCTAssertTrue(stalePollResult)

        let stateAfterStaleSuccess = await manager.runtimeState()
        XCTAssertEqual(
            stateAfterStaleSuccess.snapshot.displays.first(where: { $0.record == external })?.support,
            .degradedWriteOnlyExternal
        )
        await manager.stop()
    }

    func testRuntimeGenerationChangeClearsWriteCutoffAndAllowsWrite() async {
        let builtIn = makeDisplay(id: 1, builtIn: true)
        let external = makeDisplay(id: 2, builtIn: false)
        let sink = ConfigurableSink(outcomes: [false, false, false, true])
        let runtime = MutableRuntimeProvider(builtIn: builtIn, external: external, sink: sink)
        let settings = makeSettings()
        settings.store.setRange(
            DisplayBrightnessRange(minimum: 0.50, maximum: 0.50),
            for: external.identity
        )
        let source = SequenceBrightnessSource(values: [0.50, 0.5201, 0.5401, 0.5601])
        let controller = BrightnessSyncController(
            displayRuntime: runtime,
            brightnessSource: source,
            settings: settings.store
        )

        _ = await controller.pollOnce()
        _ = await controller.pollOnce()
        _ = await controller.pollOnce()
        let degradedBeforeGenerationChange = await runtime.isDegraded()
        XCTAssertTrue(degradedBeforeGenerationChange)

        await runtime.setGeneration(2)
        _ = await controller.pollOnce()

        let attemptsAfterGenerationChange = await sink.attemptedWrites()
        XCTAssertEqual(attemptsAfterGenerationChange, [50, 50, 50, 50])
        let degradedAfterGenerationChange = await runtime.isDegraded()
        XCTAssertFalse(degradedAfterGenerationChange)
    }

    func testWriteOnlySnapshotCarriesCapabilityAndStatusWithoutRebuildWrites() async {
        let builtIn = makeDisplay(id: 1, builtIn: true)
        let external = makeDisplay(id: 2, builtIn: false)
        let sink = RecordingSink()
        let manager = await makeManager(
            records: [builtIn, external],
            bindings: [
                ExternalDisplayBinding(
                    record: external,
                    sink: sink,
                    capability: .writeOnlyAssumed(maximum: 255)
                )
            ]
        )

        let state = await manager.runtimeState()
        let displayState = state.snapshot.displays.first(where: { $0.record == external })
        XCTAssertEqual(displayState?.support, .writeOnlyExternal)
        XCTAssertEqual(displayState?.capability, .writeOnlyAssumed(maximum: 255))
        let writesDuringRebuild = await sink.writes()
        XCTAssertEqual(writesDuringRebuild, [])
        await manager.stop()
    }

    func testSuccessfulWriteResetsFailureCounterBeforeLaterFailures() async {
        let builtIn = makeDisplay(id: 1, builtIn: true)
        let external = makeDisplay(id: 2, builtIn: false)
        let sink = ConfigurableSink(outcomes: [false, true, false, false, false])
        let manager = await makeManager(
            records: [builtIn, external],
            bindings: [ExternalDisplayBinding(record: external, sink: sink)]
        )
        let source = SequenceBrightnessSource(values: [0.50, 0.5201, 0.5401, 0.5601, 0.5901])
        let controller = BrightnessSyncController(
            displayRuntime: manager,
            brightnessSource: source,
            settings: makeSettings().store
        )

        _ = await controller.pollOnce()
        _ = await controller.pollOnce()
        _ = await controller.pollOnce()
        _ = await controller.pollOnce()
        var state = await manager.runtimeState()
        XCTAssertEqual(state.snapshot.displays.first(where: { $0.record == external })?.support, .verifiedExternal)
        let successfulWritesBeforeFinalFailure = await sink.successfulWrites()
        XCTAssertEqual(successfulWritesBeforeFinalFailure, [52])

        _ = await controller.pollOnce()
        state = await manager.runtimeState()
        XCTAssertEqual(state.snapshot.displays.first(where: { $0.record == external })?.support, .degradedExternal)
        let attempts = await sink.attemptedWrites()
        XCTAssertEqual(attempts, [50, 52, 54, 56, 59])
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
        let firstWritesAfterRebuild = await firstSink.writes()
        let secondWritesAfterRebuild = await secondSink.writes()
        XCTAssertEqual(firstWritesAfterRebuild, [])
        XCTAssertEqual(secondWritesAfterRebuild, [])
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
        let writesAfterWakeRebuild = await secondSink.writes()
        XCTAssertEqual(writesAfterWakeRebuild, [])
        let rebuildCountAfterWake = await provider.rebuildCount()
        XCTAssertGreaterThanOrEqual(rebuildCountAfterWake, 3)

        await manager.stop()
        let rebuildsAfterStop = await provider.rebuildCount()
        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(30))
        let rebuildCountAfterNotification = await provider.rebuildCount()
        XCTAssertEqual(rebuildCountAfterNotification, rebuildsAfterStop)
    }

    func testStopInvalidatesInFlightRefreshAndSuppressesStalePublication() async {
        let builtIn = makeDisplay(id: 1, builtIn: true)
        let external = makeDisplay(id: 2, builtIn: false)
        let gate = RefreshGate()
        let provider = BlockingTransportProvider(
            bindings: [ExternalDisplayBinding(record: external, sink: RecordingSink())],
            gate: gate
        )
        let recorder = SnapshotRecorder()
        let manager = DisplayManager(
            enumerator: TestDisplayEnumerator(records: [builtIn, external]),
            externalProvider: provider,
            lifecycleNotificationCenter: NotificationCenter(),
            stateUpdateHandler: { snapshot in
                recorder.append(snapshot)
            }
        )

        let startTask = Task {
            await manager.start()
        }
        await gate.waitUntilStarted()

        await manager.stop()
        await gate.release()
        await startTask.value

        let finalState = await manager.runtimeState()
        XCTAssertEqual(finalState.snapshot, .empty)
        XCTAssertTrue(finalState.externalTargets.isEmpty)
        XCTAssertEqual(recorder.snapshots(), [])
        let activeHandleCount = await provider.activeHandleCount()
        let invalidationCount = await provider.invalidateCount()
        XCTAssertEqual(activeHandleCount, 0)
        XCTAssertGreaterThanOrEqual(invalidationCount, 2)
    }

    func testCallbackRegistryLookupRemovalAndConcurrentAccessAreSafe() async {
        let external = makeDisplay(id: 2, builtIn: false)
        let provider = TestTransportProvider(
            bindings: [ExternalDisplayBinding(record: external, sink: RecordingSink())]
        )
        let manager = DisplayManager(
            enumerator: TestDisplayEnumerator(records: [external]),
            externalProvider: provider,
            lifecycleNotificationCenter: NotificationCenter()
        )
        await manager.start()
        let registry = DisplayReconfigurationCallbackRegistry()
        let token = registry.register(manager)
        XCTAssertTrue(registry.manager(for: token) === manager)

        let lookupStarted = DispatchSemaphore(value: 0)
        let lookupFinished = DispatchSemaphore(value: 0)
        let removalFinished = DispatchSemaphore(value: 0)
        let lookupResults = CallbackLookupResults()
        DispatchQueue.global().async {
            lookupStarted.signal()
            for _ in 0..<1_000 {
                lookupResults.recordFound(registry.manager(for: token) != nil)
            }
            lookupFinished.signal()
        }
        DispatchQueue.global().async {
            lookupStarted.wait()
            registry.remove(token)
            removalFinished.signal()
        }

        XCTAssertEqual(removalFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(lookupFinished.wait(timeout: .now() + 1), .success)
        XCTAssertNil(registry.manager(for: token))
        XCTAssertGreaterThanOrEqual(lookupResults.foundCount(), 0)
        XCTAssertLessThanOrEqual(lookupResults.foundCount(), 1_000)

        let invalidationCount = await provider.invalidateCount()
        XCTAssertEqual(invalidationCount, 0)
        await manager.stop()
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

private func makeVCPReply(
    feature: UInt8,
    maximum: UInt16,
    current: UInt16,
    sourceAddress: UInt8 = 0x6E,
    payloadLength: UInt8 = 0x88,
    opcode: UInt8 = 0x02,
    result: UInt8 = 0x00,
    responseType: UInt8 = 0x00
) -> [UInt8] {
    [
        sourceAddress,
        payloadLength,
        opcode,
        result,
        feature,
        responseType,
        UInt8(maximum >> 8),
        UInt8(maximum & 0xFF),
        UInt8(current >> 8),
        UInt8(current & 0xFF),
        0x00
    ]
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

private actor MutableRuntimeProvider: DisplayRuntimeProviding {
    private var builtIn: DisplayRecord?
    private let external: DisplayRecord
    private let sink: any ExternalBrightnessSink
    private var generation: UInt64 = 1
    private var degraded = false

    init(
        builtIn: DisplayRecord?,
        external: DisplayRecord,
        sink: any ExternalBrightnessSink
    ) {
        self.builtIn = builtIn
        self.external = external
        self.sink = sink
    }

    func runtimeState() async -> DisplayRuntimeState {
        let capability = ExternalDisplayCapability.verified(maximum: 100)
        let support: DisplaySupportStatus = degraded ? .degradedExternal : .verifiedExternal
        let state = DisplaySnapshot(
            generation: generation,
            displays: [
                builtIn.map { DisplayState(record: $0, support: .builtIn) },
                DisplayState(record: external, support: support, capability: capability)
            ].compactMap { $0 },
            builtIn: builtIn
        )
        return DisplayRuntimeState(
            snapshot: state,
            externalTargets: [
                ExternalDisplayTarget(
                    record: external,
                    sink: sink,
                    capability: capability,
                    generation: generation
                )
            ]
        )
    }

    func markTargetDegraded(_ key: DisplayTargetKey, generation: UInt64) async {
        if key.displayID == external.displayID &&
            key.identity == external.identity &&
            generation == self.generation {
            degraded = true
        }
    }

    func markTargetHealthy(_ key: DisplayTargetKey, generation: UInt64) async {
        if key.displayID == external.displayID &&
            key.identity == external.identity &&
            generation == self.generation {
            degraded = false
        }
    }

    func retryTarget(_ key: DisplayTargetKey, generation: UInt64?) async {
        guard generation == nil || generation == self.generation else { return }
        degraded = false
    }

    func updateAssumedMaximum(_ maximum: UInt16, for identity: DisplayIdentity) async {
        _ = maximum
        _ = identity
    }

    func setBuiltIn(_ builtIn: DisplayRecord?) {
        self.builtIn = builtIn
    }

    func setGeneration(_ generation: UInt64) {
        self.generation = generation
        degraded = false
    }

    func isDegraded() -> Bool {
        degraded
    }
}

private actor TestTransportProvider: ExternalDisplayTransportProvider {
    private var bindings: [ExternalDisplayBinding]
    private var rebuilds = 0
    private var invalidations = 0
    private var activeHandles = 0

    init(bindings: [ExternalDisplayBinding]) {
        self.bindings = bindings
    }

    func rebuild(for displays: [DisplayRecord]) async -> [ExternalDisplayBinding] {
        rebuilds += 1
        let displayIDs = Set(displays.map(\.displayID))
        let matchingBindings = bindings.filter { displayIDs.contains($0.record.displayID) }
        activeHandles = matchingBindings.count
        return matchingBindings
    }

    func invalidate() async {
        invalidations += 1
        activeHandles = 0
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

    func activeHandleCount() -> Int {
        activeHandles
    }
}

private actor RefreshGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        guard !released else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            releaseContinuation = continuation
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor WriteGate {
    private var started = false
    private var released = false
    private var result = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Bool, Never>?

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async -> Bool {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        if released {
            return result
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            releaseContinuation = continuation
        }
    }

    func release(result: Bool) {
        self.result = result
        released = true
        releaseContinuation?.resume(returning: result)
        releaseContinuation = nil
    }
}

private actor BlockingWriteSink: ExternalBrightnessSink {
    private let gate: WriteGate

    init(gate: WriteGate) {
        self.gate = gate
    }

    func writeBrightness(_ percent: Int) async -> Bool {
        _ = percent
        return await gate.waitUntilReleased()
    }

    func invalidate() async {}
}

private actor BlockingTransportProvider: ExternalDisplayTransportProvider {
    private let bindings: [ExternalDisplayBinding]
    private let gate: RefreshGate
    private var activeHandles = 0
    private var invalidations = 0

    init(bindings: [ExternalDisplayBinding], gate: RefreshGate) {
        self.bindings = bindings
        self.gate = gate
    }

    func rebuild(for displays: [DisplayRecord]) async -> [ExternalDisplayBinding] {
        await gate.waitUntilReleased()
        let displayIDs = Set(displays.map(\.displayID))
        let matchingBindings = bindings.filter { displayIDs.contains($0.record.displayID) }
        activeHandles = matchingBindings.count
        return matchingBindings
    }

    func invalidate() async {
        activeHandles = 0
        invalidations += 1
    }

    func activeHandleCount() -> Int {
        activeHandles
    }

    func invalidateCount() -> Int {
        invalidations
    }
}

/// Lock-backed test recorder; the lock protects synchronous callback writes
/// from the actor-isolated manager without widening production sendability.
private final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSnapshots: [DisplaySnapshot] = []

    func append(_ snapshot: DisplaySnapshot) {
        lock.lock()
        recordedSnapshots.append(snapshot)
        lock.unlock()
    }

    func snapshots() -> [DisplaySnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSnapshots
    }
}

private final class CallbackLookupResults: @unchecked Sendable {
    private let lock = NSLock()
    private var lookupsWithManager = 0

    func recordFound(_ found: Bool) {
        guard found else { return }
        lock.lock()
        lookupsWithManager += 1
        lock.unlock()
    }

    func foundCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return lookupsWithManager
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

private actor ConfigurableSink: ExternalBrightnessSink {
    private var outcomes: [Bool]
    private var attempted: [Int] = []
    private var successful: [Int] = []

    init(outcomes: [Bool]) {
        self.outcomes = outcomes
    }

    func writeBrightness(_ percent: Int) async -> Bool {
        attempted.append(percent)
        let result = outcomes.isEmpty ? true : outcomes.removeFirst()
        if result {
            successful.append(percent)
        }
        return result
    }

    func invalidate() async {}

    func attemptedWrites() -> [Int] { attempted }
    func successfulWrites() -> [Int] { successful }
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
