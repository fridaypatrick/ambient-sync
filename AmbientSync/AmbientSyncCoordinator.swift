import AppKit

@MainActor
final class AmbientSyncCoordinator {
    let settings: SettingsStore
    let displayManager: DisplayManager
    let brightnessController: BrightnessSyncController
    let appearanceController: AppearanceAutomationController
    let loginItemManager: LoginItemManager
    let menuBarController: MenuBarController
    let settingsWindowController: SettingsWindowController

    private let safeSmoke: Bool
    private var started = false
    private var shutdownRequested = false
    private var runtimeTask: Task<Void, Never>?
    private var settingsWindowCloseObserver: NSObjectProtocol?

    init(safeSmoke: Bool = false) {
        self.safeSmoke = safeSmoke
        let settings = SettingsStore()
        let displayManager = DisplayManager()
        let appearanceController = AppearanceAutomationController(
            adapter: SystemEventsAppearanceAdapter(),
            thresholds: settings.appearanceThresholds
        )
        let loginItemManager = LoginItemManager(settings: settings)
        let menuBarController = MenuBarController(settings: settings)

        let brightnessController = BrightnessSyncController(
            displayRuntime: displayManager,
            settings: settings,
            onMeaningfulBrightness: { [weak appearanceController] brightness in
                await appearanceController?.evaluate(brightness: brightness)
            }
        )

        let settingsWindowController = SettingsWindowController(
            settings: settings,
            onBrightnessSyncChanged: { [weak brightnessController] in
                Task { await brightnessController?.settingsDidChange() }
            },
            onAppearanceThresholdsChanged: { [weak appearanceController] thresholds in
                appearanceController?.updateThresholds(thresholds)
            },
            onDisplayRangeChanged: { [weak brightnessController] in
                Task { await brightnessController?.settingsDidChange() }
            },
            onLaunchAtLoginChanged: { [weak loginItemManager] enabled in
                loginItemManager?.setEnabled(enabled)
            },
            onMenuBarIconVisibilityChanged: { [weak menuBarController] visible in
                menuBarController?.setVisible(visible)
            }
        )

        self.settings = settings
        self.displayManager = displayManager
        self.brightnessController = brightnessController
        self.appearanceController = appearanceController
        self.loginItemManager = loginItemManager
        self.menuBarController = menuBarController
        self.settingsWindowController = settingsWindowController

        menuBarController.onOpenSettings = { [weak self] in
            self?.showSettings()
        }
        menuBarController.onQuit = {
            NSApp.terminate(nil)
        }
        appearanceController.statusDidChange = { [weak settingsWindowController] status in
            settingsWindowController?.update(appearanceStatus: status)
        }
        loginItemManager.stateDidChange = { [weak loginItemManager, weak settingsWindowController] in
            settingsWindowController?.updateLoginItem(
                enabled: loginItemManager?.isEnabled ?? false,
                statusMessage: loginItemManager?.statusMessage
            )
        }
        settingsWindowController.updateLoginItem(
            enabled: loginItemManager.isEnabled,
            statusMessage: loginItemManager.statusMessage
        )
    }

    func start() {
        guard !started else { return }
        started = true
        NSApp.setActivationPolicy(.accessory)

        if safeSmoke {
            showSettings()
            return
        }

        runtimeTask = Task { [weak self] in
            guard let self else { return }

            await self.displayManager.setStateUpdateHandler { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.settingsWindowController.update(snapshot: snapshot)
                }
            }
            await self.displayManager.start()

            let runtimeState = await self.displayManager.runtimeState()
            self.settingsWindowController.update(snapshot: runtimeState.snapshot)

            guard !Task.isCancelled, !self.shutdownRequested else {
                await self.displayManager.stop()
                return
            }

            await self.brightnessController.start()
        }
    }

    func showSettings() {
        loginItemManager.refresh()
        let wasAccessory = NSApp.activationPolicy() == .accessory
        if wasAccessory {
            NSApp.setActivationPolicy(.regular)
        }
        settingsWindowController.showSettings()

        if wasAccessory, let window = settingsWindowController.window {
            observeSettingsWindowClose(window)
        }
    }

    private func observeSettingsWindowClose(_ window: NSWindow) {
        if let observer = settingsWindowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        settingsWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restoreAccessoryPolicy()
            }
        }
    }

    private func restoreAccessoryPolicy() {
        if let observer = settingsWindowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            settingsWindowCloseObserver = nil
        }
        NSApp.setActivationPolicy(.accessory)
    }

    func shutdown() {
        guard !shutdownRequested else { return }
        shutdownRequested = true
        runtimeTask?.cancel()
        runtimeTask = Task { [brightnessController, displayManager] in
            await brightnessController.stop()
            await displayManager.stop()
        }
    }

    func shutdownForTermination() {
        guard !shutdownRequested else {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }

        shutdownRequested = true
        runtimeTask?.cancel()
        runtimeTask = Task { [brightnessController, displayManager] in
            await brightnessController.stop()
            await displayManager.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
}
