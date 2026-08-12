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
        resetState()
    }

    /// Called after global or per-display settings changes. Ranges take effect
    /// on the next meaningful brightness update; no write is triggered solely
    /// by a settings edit.
    public func settingsDidChange() {
        targetSuppressors.removeAll()
        if !settings.brightnessSyncEnabled {
            changeFilter.reset()
            lastRuntimeGeneration = nil
        }
    }

    /// Exposed as a narrow coordinator seam for deterministic tests and later
    /// lifecycle wiring. Production polling calls this every two seconds.
    @discardableResult
    public func pollOnce() async -> Bool {
        guard settings.brightnessSyncEnabled else {
            resetState()
            return false
        }

        let runtimeState = await displayRuntime.runtimeState()
        guard let builtIn = runtimeState.snapshot.builtIn else {
            resetState()
            return false
        }

        if lastRuntimeGeneration != runtimeState.snapshot.generation {
            lastRuntimeGeneration = runtimeState.snapshot.generation
            changeFilter.reset()
            targetSuppressors.removeAll()
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
            var suppressor = targetSuppressors[target.key] ?? IntegerDDCTargetSuppressor()
            if let targetValue = suppressor.targetIfChanged(
                for: brightness,
                range: settings.range(for: target.record.identity)
            ) {
                let didWrite = await target.sink.writeBrightness(targetValue)
                guard didWrite else {
                    continue
                }
            }
            targetSuppressors[target.key] = suppressor
        }

        if let onMeaningfulBrightness {
            await onMeaningfulBrightness(brightness)
        }
        return true
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

    private func resetState() {
        changeFilter.reset()
        targetSuppressors.removeAll()
        lastRuntimeGeneration = nil
    }

    deinit {
        pollTask?.cancel()
    }
}
