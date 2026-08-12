// Portions of this file adapt the minimal display enumeration and lifecycle
// responsibilities from MonitorControl/Support/DisplayManager.swift and
// MonitorControl/Model/Display.swift at upstream commit
// f16d90f29cefbd9fff47e26fc8f99fe7a5280deb.
// Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES/MonitorControl-MIT.txt for the complete notice.

import AppKit
import CoreGraphics
import Foundation

/// Actor-owned display state. CoreGraphics callbacks and workspace
/// notifications only enqueue actor work; enumeration and DDC probing happen
/// later on the actor/provider executors.
public actor DisplayManager: DisplayRuntimeProviding {
    private let enumerator: any DisplayEnumerator
    private let externalProvider: any ExternalDisplayTransportProvider
    private let observerStore: LifecycleObserverStore
    private let debounceInterval: Duration

    private var running = false
    private var lifecycleGeneration: UInt64 = 0
    private var snapshot = DisplaySnapshot.empty
    private var externalTargets: [ExternalDisplayTarget] = []
    private var refreshTask: Task<Void, Never>?
    private var registration: DisplayReconfigurationRegistration?
    private var stateUpdateHandler: DisplayStateUpdateHandler?

    public init(
        enumerator: any DisplayEnumerator = CoreGraphicsDisplayEnumerator(),
        externalProvider: any ExternalDisplayTransportProvider = AppleSiliconDDCTransportProvider(),
        lifecycleNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        debounceInterval: Duration = .milliseconds(250),
        stateUpdateHandler: DisplayStateUpdateHandler? = nil
    ) {
        self.enumerator = enumerator
        self.externalProvider = externalProvider
        self.observerStore = LifecycleObserverStore(center: lifecycleNotificationCenter)
        self.debounceInterval = debounceInterval
        self.stateUpdateHandler = stateUpdateHandler
    }

    public func start() async {
        guard !running else { return }
        running = true
        lifecycleGeneration &+= 1
        installLifecycleObservers()
        registration = DisplayReconfigurationRegistration(manager: self)
        await refreshNow()
    }

    public func stop() async {
        guard running || registration != nil || !observerStore.isEmpty else { return }
        running = false
        lifecycleGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        registration?.stop()
        registration = nil
        observerStore.removeAll()
        externalTargets.removeAll()
        await externalProvider.invalidate()
    }

    public func shutdown() async {
        await stop()
    }

    public func refreshNow() async {
        guard running else { return }
        refreshTask?.cancel()
        refreshTask = nil
        let generation = lifecycleGeneration
        await performRefresh(for: generation)
    }

    /// Schedules debounced work. This is the only operation reached from the
    /// CoreGraphics callback path; it performs no enumeration or DDC I/O.
    public func requestRefresh() {
        guard running else { return }
        refreshTask?.cancel()
        let interval = debounceInterval
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard let self else { return }
            await self.refreshNow()
        }
    }

    /// Lifecycle seam used by the callback and deterministic tests.
    public func displayConfigurationDidChange() async {
        guard running else { return }
        await externalProvider.invalidate()
        requestRefresh()
    }

    /// Invalidates handles before sleep. External displays keep their last
    /// hardware values because this method does not write brightness.
    public func systemWillSleep() async {
        guard running else { return }
        refreshTask?.cancel()
        refreshTask = nil
        await externalProvider.invalidate()
        externalTargets.removeAll()
    }

    /// Wake always rebuilds handles through the same debounced refresh path.
    public func systemDidWake() async {
        guard running else { return }
        await externalProvider.invalidate()
        requestRefresh()
    }

    public func setStateUpdateHandler(_ handler: DisplayStateUpdateHandler?) {
        stateUpdateHandler = handler
    }

    public func runtimeState() async -> DisplayRuntimeState {
        DisplayRuntimeState(snapshot: snapshot, externalTargets: externalTargets)
    }

    private func performRefresh(for generation: UInt64) async {
        let records = await enumerator.enumerate()
        guard running, lifecycleGeneration == generation else { return }

        let externalRecords = records.filter { !$0.isBuiltIn }
        let bindings = await externalProvider.rebuild(for: externalRecords)
        guard running, lifecycleGeneration == generation else {
            // A provider can finish rebuilding after stop invalidated its
            // previous handles. Invalidate again so handles created by this
            // stale rebuild cannot survive the shutdown boundary.
            await externalProvider.invalidate()
            return
        }

        let bindingsByDisplayID = Dictionary(
            bindings.map { ($0.record.displayID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let nextGeneration = snapshot.generation &+ 1
        var states: [DisplayState] = []
        var nextTargets: [ExternalDisplayTarget] = []
        states.reserveCapacity(records.count)

        for record in records {
            if record.isBuiltIn {
                states.append(DisplayState(record: record, support: .builtIn))
            } else if let binding = bindingsByDisplayID[record.displayID] {
                states.append(DisplayState(record: record, support: .controllableExternal))
                nextTargets.append(
                    ExternalDisplayTarget(
                        record: record,
                        sink: binding.sink,
                        generation: nextGeneration
                    )
                )
            } else {
                states.append(DisplayState(record: record, support: .unsupportedExternal))
            }
        }

        snapshot = DisplaySnapshot(
            generation: nextGeneration,
            displays: states,
            builtIn: records.first(where: \.isBuiltIn)
        )
        externalTargets = nextTargets
        stateUpdateHandler?(snapshot)
    }

    private func installLifecycleObservers() {
        let sleepToken = observerStore.center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.systemWillSleep() }
        }
        let wakeToken = observerStore.center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.systemDidWake() }
        }
        observerStore.add(sleepToken)
        observerStore.add(wakeToken)
    }

    deinit {
        refreshTask?.cancel()
        // Stored registration deinitialization deactivates and unregisters
        // its retained callback context before releasing its unmanaged hold.
    }
}

private final class LifecycleObserverStore: @unchecked Sendable {
    let center: NotificationCenter
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tokens.isEmpty
    }

    func add(_ token: NSObjectProtocol) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        let tokensToRemove = tokens
        tokens.removeAll()
        lock.unlock()

        for token in tokensToRemove {
            center.removeObserver(token)
        }
    }

    deinit {
        removeAll()
    }
}

/// The registry is the only unchecked Sendable boundary in callback lifetime
/// management. Its lock protects token allocation, weak manager storage, and
/// strong manager lookup; callbacks never dereference token pointers.
final class DisplayReconfigurationCallbackRegistry: @unchecked Sendable {
    static let shared = DisplayReconfigurationCallbackRegistry()

    private final class WeakManagerReference {
        weak var manager: DisplayManager?

        init(manager: DisplayManager) {
            self.manager = manager
        }
    }

    private let lock = NSLock()
    private var nextToken: UInt = 1
    private var managers: [UInt: WeakManagerReference] = [:]

    func register(_ manager: DisplayManager) -> UInt {
        lock.lock()
        defer { lock.unlock() }

        while true {
            let token = nextToken
            nextToken &+= 1
            guard token != 0, managers[token] == nil else { continue }
            managers[token] = WeakManagerReference(manager: manager)
            return token
        }
    }

    func manager(for token: UInt) -> DisplayManager? {
        lock.lock()
        defer { lock.unlock() }

        guard let reference = managers[token] else { return nil }
        guard let manager = reference.manager else {
            managers.removeValue(forKey: token)
            return nil
        }
        return manager
    }

    func remove(_ token: UInt) {
        lock.lock()
        managers.removeValue(forKey: token)
        lock.unlock()
    }
}

/// Registration retains callback context independently from the actor. The
/// context weakly references the actor, so registration cannot form a cycle.
private final class DisplayReconfigurationRegistration {
    private let token: UInt
    private let lock = NSLock()
    private var registered = false

    init(manager: DisplayManager) {
        let token = DisplayReconfigurationCallbackRegistry.shared.register(manager)
        self.token = token
        let userInfo = UnsafeMutableRawPointer(bitPattern: token)!
        let result = CGDisplayRegisterReconfigurationCallback(
            ambientSyncDisplayReconfigurationCallback,
            userInfo
        )
        if result == .success {
            registered = true
        } else {
            DisplayReconfigurationCallbackRegistry.shared.remove(token)
        }
    }

    func stop() {
        lock.lock()
        let shouldRemove = registered
        registered = false
        lock.unlock()

        if shouldRemove {
            _ = CGDisplayRemoveReconfigurationCallback(
                ambientSyncDisplayReconfigurationCallback,
                UnsafeMutableRawPointer(bitPattern: token)!
            )
        }
        DisplayReconfigurationCallbackRegistry.shared.remove(token)
    }

    deinit {
        stop()
    }
}

private func ambientSyncDisplayReconfigurationCallback(
    _ displayID: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    _ = displayID
    _ = flags
    guard let userInfo else { return }
    let token = UInt(bitPattern: userInfo)
    let manager = DisplayReconfigurationCallbackRegistry.shared.manager(for: token)
    guard let manager else { return }
    Task {
        await manager.displayConfigurationDidChange()
    }
}
