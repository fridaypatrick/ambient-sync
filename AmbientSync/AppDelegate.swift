import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AmbientSyncCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
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
