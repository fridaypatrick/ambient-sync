import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AmbientSyncCoordinator?
    private var lifecycleState = AppLifecycleState()

    static func main() {
        // Attach delegate explicitly before entering AppKit's event loop.
        // This source-only bundle has no nib/delegate metadata for
        // NSApplicationMain to discover, so relying on generated @main setup
        // leaves NSApp.delegate nil and drops launch/reopen callbacks.
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        lifecycleState.markDidFinishLaunching()
        NSApp.setActivationPolicy(.accessory)

        // XCTest launches this app as a test host. Keep production display
        // enumeration, DDC probing, login-item reconciliation, and Apple
        // Events out of automated verification unless a test explicitly
        // constructs those seams.
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] == nil,
              environment["XCInjectBundleInto"] == nil
        else {
            return
        }

        let safeSmoke = environment["AMBIENTSYNC_SAFE_SMOKE"] == "1"
        coordinator = AmbientSyncCoordinator(safeSmoke: safeSmoke)
        coordinator?.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        _ = sender
        _ = flag
        coordinator?.showSettings()
        // Settings is already presented above. Returning false prevents AppKit
        // from following this callback with applicationOpenUntitledFile and
        // presenting Settings a second time.
        return false
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        _ = sender
        let shouldShow = lifecycleState.shouldShowSettingsForUntitledOpen
        guard shouldShow else {
            return false
        }
        coordinator?.showSettings()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        guard let coordinator else { return .terminateNow }
        coordinator.shutdownForTermination()
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        coordinator?.shutdown()
    }
}

struct AppLifecycleState {
    private(set) var didFinishLaunching = false

    mutating func markDidFinishLaunching() {
        didFinishLaunching = true
    }

    var shouldShowSettingsForUntitledOpen: Bool {
        didFinishLaunching
    }
}
