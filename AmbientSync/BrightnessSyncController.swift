import Foundation

/// Polls built-in brightness and writes mapped integer DDC targets. Actor
/// isolation owns the meaningful-change filter and one suppression state per
/// runtime display target.
public actor BrightnessSyncController {
    private let displayRuntime: any DisplayRuntimeProviding
    private let brightnessSource: any BuiltInBrightnessSource
    private let settings: SettingsStore
    private let pollInterval: Duration
    private let onMeaningfulBrightness: MeaningfulBrightnessUpdateHandler?

    private var pollTask: Task<Void, Never>?
    private var changeFilter = MeaningfulBrightnessChangeFilter()
    private var targetSuppressors: [DisplayTargetKey: IntegerDDCTargetSuppressor] = [:]
    private var consecutiveWriteFailures: [DisplayTargetKey: Int] = [:]
    private var lastRuntimeGeneration: UInt64?

    public init(
        displayRuntime: any DisplayRuntimeProviding,
        brightnessSource: any BuiltInBrightnessSource = DisplayServicesBrightnessSource(),
        settings: SettingsStore = SettingsStore(),
        pollInterval: Duration = .seconds(2),
        onMeaningfulBrightness: MeaningfulBrightnessUpdateHandler? = nil
    ) {
        self.displayRuntime = displayRuntime
        self.brightnessSource = brightnessSource
        self.settings = settings
        self.pollInterval = pollInterval
        self.onMeaningfulBrightness = onMeaningfulBrightness
    }

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        resetTransientState()
    }

    /// Called after global or per-display settings changes. Ranges take effect
    /// on the next meaningful brightness update; no write is triggered solely
    /// by a settings edit.
    public func settingsDidChange() {
        targetSuppressors.removeAll()
    }

    /// Clears one target's transport fault. This changes no hardware state;
    /// the next meaningful internal-brightness event may write again.
    public func retryTarget(_ key: DisplayTargetKey) async {
        let runtimeState = await displayRuntime.runtimeState()
        guard let target = runtimeState.externalTargets.first(where: { $0.key == key }) else {
            return
        }
        consecutiveWriteFailures.removeValue(forKey: key)
        targetSuppressors.removeValue(forKey: key)
        await displayRuntime.retryTarget(key, generation: target.generation)
    }

    /// Exposed as a narrow coordinator seam for deterministic tests and later
    /// lifecycle wiring. Production polling calls this every two seconds.
    @discardableResult
    public func pollOnce() async -> Bool {
        guard settings.brightnessSyncEnabled else {
            resetTransientState()
            return false
        }

        let runtimeState = await displayRuntime.runtimeState()
        guard let builtIn = runtimeState.snapshot.builtIn else {
            resetTransientState()
            return false
        }

        if lastRuntimeGeneration != runtimeState.snapshot.generation {
            lastRuntimeGeneration = runtimeState.snapshot.generation
            changeFilter.reset()
            targetSuppressors.removeAll()
            consecutiveWriteFailures.removeAll()
        }

        guard let brightness = await brightnessSource.readBrightness(for: builtIn.displayID),
              brightness.isFinite
        else {
            return false
        }

        guard changeFilter.accept(brightness) else {
            return false
        }

        let currentKeys = Set(runtimeState.externalTargets.map(\.key))
        targetSuppressors = targetSuppressors.filter { currentKeys.contains($0.key) }

        for target in runtimeState.externalTargets {
            let isDegraded = runtimeState.snapshot.displays.contains {
                $0.record.displayID == target.key.displayID &&
                $0.record.identity == target.key.identity &&
                $0.support.isDegraded
            }
            guard !isDegraded else { continue }
            var suppressor = targetSuppressors[target.key] ?? IntegerDDCTargetSuppressor()
            let previousTarget = suppressor.lastTarget
            if let targetValue = suppressor.targetIfChanged(
                for: brightness,
                range: settings.range(for: target.record.identity)
            ) {
                let didWrite = await target.sink.writeBrightness(targetValue)
                guard await isCurrent(target, in: runtimeState) else {
                    continue
                }
                if didWrite {
                    consecutiveWriteFailures.removeValue(forKey: target.key)
                    await displayRuntime.markTargetHealthy(
                        target.key,
                        generation: target.generation
                    )
                } else {
                    let failures = (consecutiveWriteFailures[target.key] ?? 0) + 1
                    consecutiveWriteFailures[target.key] = failures
                    // Preserve rollback-on-failure: retry this target value on
                    // a later meaningful event until the cutoff is reached.
                    suppressor.rollback(to: previousTarget)
                    if failures >= 3 {
                        await displayRuntime.markTargetDegraded(
                            target.key,
                            generation: target.generation
                        )
                    }
                }
            }
            targetSuppressors[target.key] = suppressor
        }

        if let onMeaningfulBrightness {
            await onMeaningfulBrightness(brightness)
        }
        return true
    }

    private func isCurrent(
        _ attemptedTarget: ExternalDisplayTarget,
        in attemptedState: DisplayRuntimeState
    ) async -> Bool {
        let currentState = await displayRuntime.runtimeState()
        guard currentState.snapshot.generation == attemptedState.snapshot.generation else {
            return false
        }
        return currentState.externalTargets.contains {
            $0.key == attemptedTarget.key &&
            $0.generation == attemptedTarget.generation
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            _ = await pollOnce()
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return
            }
        }
    }

    private func resetTransientState() {
        changeFilter.reset()
        targetSuppressors.removeAll()
    }

    deinit {
        pollTask?.cancel()
    }
}
