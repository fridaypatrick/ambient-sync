import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Phase 1 has no menu bar or settings UI. Keep the shell accessory-only
        // so the later status-item integration starts from the right lifecycle.
        NSApp.setActivationPolicy(.accessory)
    }
}
