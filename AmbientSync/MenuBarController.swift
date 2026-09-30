import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let settings: SettingsStore
    private var statusItem: NSStatusItem?

    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
        updateVisibility()
    }

    var isVisible: Bool {
        statusItem != nil
    }

    func setVisible(_ visible: Bool) {
        settings.menuBarIconVisible = visible
        updateVisibility()
    }

    func updateVisibility() {
        if settings.menuBarIconVisible {
            installStatusItemIfNeeded()
        } else {
            removeStatusItem()
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.accessibilityDescription = "AmbientSync"
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            button.toolTip = "AmbientSync"
            button.setAccessibilityLabel("AmbientSync menu")
        }

        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit AmbientSync",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        _ = sender
        onOpenSettings?()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        _ = sender
        onQuit?()
    }
}
