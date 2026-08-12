import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private final class DisplayRow {
        let state: DisplayState
        let minimumSlider: NSSlider?
        let maximumSlider: NSSlider?
        let minimumValueLabel: NSTextField?
        let maximumValueLabel: NSTextField?

        init(
            state: DisplayState,
            minimumSlider: NSSlider? = nil,
            maximumSlider: NSSlider? = nil,
            minimumValueLabel: NSTextField? = nil,
            maximumValueLabel: NSTextField? = nil
        ) {
            self.state = state
            self.minimumSlider = minimumSlider
            self.maximumSlider = maximumSlider
            self.minimumValueLabel = minimumValueLabel
            self.maximumValueLabel = maximumValueLabel
        }
    }

    private let settings: SettingsStore
    private let onBrightnessSyncChanged: () -> Void
    private let onAppearanceThresholdsChanged: (AppearanceThresholds) -> Void
    private let onDisplayRangeChanged: () -> Void
    private let onLaunchAtLoginChanged: (Bool) -> Void
    private let onMenuBarIconVisibilityChanged: (Bool) -> Void

    private var snapshot = DisplaySnapshot.empty
    private var appearanceStatus: AppearanceAutomationStatus = .notAttempted
    private var loginItemEnabled = false
    private var loginStatusMessage: String?
    private var displayRows: [DisplayRow] = []

    private var documentView: SettingsDocumentView?
    private var contentStack: NSStackView?
    private var displayStack: NSStackView?
    private var appearanceStatusLabel: NSTextField?
    private var loginStatusLabel: NSTextField?
    private var brightnessSyncCheckbox: NSButton?
    private var darkThresholdSlider: NSSlider?
    private var lightThresholdSlider: NSSlider?
    private var darkThresholdValueLabel: NSTextField?
    private var lightThresholdValueLabel: NSTextField?
    private var launchAtLoginCheckbox: NSButton?
    private var menuBarIconCheckbox: NSButton?

    init(
        settings: SettingsStore,
        onBrightnessSyncChanged: @escaping () -> Void,
        onAppearanceThresholdsChanged: @escaping (AppearanceThresholds) -> Void,
        onDisplayRangeChanged: @escaping () -> Void,
        onLaunchAtLoginChanged: @escaping (Bool) -> Void,
        onMenuBarIconVisibilityChanged: @escaping (Bool) -> Void
    ) {
        self.settings = settings
        self.onBrightnessSyncChanged = onBrightnessSyncChanged
        self.onAppearanceThresholdsChanged = onAppearanceThresholdsChanged
        self.onDisplayRangeChanged = onDisplayRangeChanged
        self.onLaunchAtLoginChanged = onLaunchAtLoginChanged
        self.onMenuBarIconVisibilityChanged = onMenuBarIconVisibilityChanged
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController does not support storyboards.")
    }

    func showSettings() {
        if window == nil {
            makeWindow()
        }

        guard let window else { return }
        refreshControls()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func update(snapshot: DisplaySnapshot) {
        self.snapshot = snapshot
        guard window != nil else { return }
        rebuildDisplayRows()
        refreshControls()
    }

    func update(appearanceStatus: AppearanceAutomationStatus) {
        self.appearanceStatus = appearanceStatus
        appearanceStatusLabel?.stringValue = appearanceStatus.userMessage
    }

    func updateLoginItem(enabled: Bool, statusMessage: String?) {
        loginItemEnabled = enabled
        loginStatusMessage = statusMessage
        refreshLoginControls()
    }

    private func makeWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AmbientSync Settings"
        window.minSize = NSSize(width: 560, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 680))
        let scrollView = NSScrollView(frame: rootView.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let documentView = SettingsDocumentView(frame: NSRect(x: 0, y: 0, width: 620, height: 680))
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        documentView.addSubview(contentStack)
        scrollView.documentView = documentView
        rootView.addSubview(scrollView)
        window.contentView = rootView

        self.documentView = documentView
        self.contentStack = contentStack
        self.window = window

        buildStaticContent()
        rebuildDisplayRows()
        refreshControls()
        reflowDocument()
        window.center()
    }

    private func buildStaticContent() {
        guard let contentStack else { return }

        contentStack.addArrangedSubview(label("AmbientSync", font: .boldSystemFont(ofSize: 20)))
        contentStack.addArrangedSubview(
            label(
                "Synchronize built-in brightness with supported external displays and system appearance.",
                wrapping: true
            )
        )
        contentStack.addArrangedSubview(label("Global", font: .boldSystemFont(ofSize: 15)))

        let brightnessCheckbox = NSButton(
            checkboxWithTitle: "Enable brightness synchronization",
            target: self,
            action: #selector(brightnessSyncChanged(_:))
        )
        brightnessCheckbox.setAccessibilityLabel("Enable brightness synchronization")
        self.brightnessSyncCheckbox = brightnessCheckbox
        contentStack.addArrangedSubview(brightnessCheckbox)

        let darkSlider = makePercentageSlider(action: #selector(thresholdChanged(_:)))
        let lightSlider = makePercentageSlider(action: #selector(thresholdChanged(_:)))
        self.darkThresholdSlider = darkSlider
        self.lightThresholdSlider = lightSlider
        let darkValue = valueLabel()
        let lightValue = valueLabel()
        self.darkThresholdValueLabel = darkValue
        self.lightThresholdValueLabel = lightValue
        contentStack.addArrangedSubview(
            sliderRow(
                title: "Dark threshold",
                slider: darkSlider,
                valueLabel: darkValue,
                accessibilityLabel: "Dark appearance threshold"
            )
        )
        contentStack.addArrangedSubview(
            sliderRow(
                title: "Light threshold",
                slider: lightSlider,
                valueLabel: lightValue,
                accessibilityLabel: "Light appearance threshold"
            )
        )

        let launchCheckbox = NSButton(
            checkboxWithTitle: "Launch at Login",
            target: self,
            action: #selector(launchAtLoginChanged(_:))
        )
        launchCheckbox.setAccessibilityLabel("Launch AmbientSync at Login")
        self.launchAtLoginCheckbox = launchCheckbox
        contentStack.addArrangedSubview(launchCheckbox)
        let loginStatusLabel = label("", wrapping: true)
        loginStatusLabel.textColor = .secondaryLabelColor
        loginStatusLabel.isHidden = true
        self.loginStatusLabel = loginStatusLabel
        contentStack.addArrangedSubview(loginStatusLabel)

        let menuCheckbox = NSButton(
            checkboxWithTitle: "Show menu-bar icon",
            target: self,
            action: #selector(menuBarIconVisibilityChanged(_:))
        )
        menuCheckbox.setAccessibilityLabel("Show AmbientSync menu-bar icon")
        self.menuBarIconCheckbox = menuCheckbox
        contentStack.addArrangedSubview(menuCheckbox)

        contentStack.addArrangedSubview(label("Displays", font: .boldSystemFont(ofSize: 15)))
        let displayStack = NSStackView()
        displayStack.orientation = .vertical
        displayStack.alignment = .leading
        displayStack.spacing = 10
        self.displayStack = displayStack
        contentStack.addArrangedSubview(displayStack)

        contentStack.addArrangedSubview(label("Appearance automation", font: .boldSystemFont(ofSize: 15)))
        let appearanceStatusLabel = label("", wrapping: true)
        self.appearanceStatusLabel = appearanceStatusLabel
        contentStack.addArrangedSubview(appearanceStatusLabel)

        let openAutomationButton = NSButton(
            title: "Open Automation Settings",
            target: self,
            action: #selector(openAutomationSettings(_:))
        )
        openAutomationButton.bezelStyle = .rounded
        openAutomationButton.setAccessibilityLabel("Open Automation Settings")
        contentStack.addArrangedSubview(openAutomationButton)
    }

    private func rebuildDisplayRows() {
        guard let displayStack else { return }
        displayStack.arrangedSubviews.forEach {
            displayStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        displayRows.removeAll(keepingCapacity: true)

        if snapshot.displays.isEmpty {
            displayStack.addArrangedSubview(label("No displays detected yet.", wrapping: true))
            reflowDocument()
            return
        }

        for state in snapshot.displays {
            let row = makeDisplayRow(state)
            displayRows.append(row)
            displayStack.addArrangedSubview(rowView(for: row))
        }
        reflowDocument()
    }

    private func makeDisplayRow(_ state: DisplayState) -> DisplayRow {
        guard state.support == .controllableExternal else {
            return DisplayRow(state: state)
        }

        let range = settings.range(for: state.record.identity)
        let minimumSlider = makePercentageSlider(action: #selector(displayRangeChanged(_:)))
        let maximumSlider = makePercentageSlider(action: #selector(displayRangeChanged(_:)))
        minimumSlider.doubleValue = range.minimum * 100.0
        maximumSlider.doubleValue = range.maximum * 100.0
        let minimumLabel = valueLabel()
        let maximumLabel = valueLabel()
        minimumSlider.setAccessibilityLabel("Minimum brightness for \(state.record.name)")
        maximumSlider.setAccessibilityLabel("Maximum brightness for \(state.record.name)")
        minimumLabel.stringValue = percentageText(range.minimum)
        maximumLabel.stringValue = percentageText(range.maximum)

        return DisplayRow(
            state: state,
            minimumSlider: minimumSlider,
            maximumSlider: maximumSlider,
            minimumValueLabel: minimumLabel,
            maximumValueLabel: maximumLabel
        )
    }

    private func rowView(for row: DisplayRow) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5

        let title = label(row.state.record.name, font: .systemFont(ofSize: 13, weight: .medium))
        title.setAccessibilityLabel(row.state.record.name)
        stack.addArrangedSubview(title)

        let statusText: String
        switch row.state.support {
        case .builtIn:
            statusText = "Built-in display"
        case .controllableExternal:
            statusText = "External display · brightness controllable"
        case .unsupportedExternal:
            statusText = "External display · unsupported for brightness control"
        }
        let status = label(statusText, wrapping: true)
        status.textColor = row.state.support == .unsupportedExternal ? .secondaryLabelColor : .labelColor
        stack.addArrangedSubview(status)

        guard let minimumSlider = row.minimumSlider,
              let maximumSlider = row.maximumSlider,
              let minimumLabel = row.minimumValueLabel,
              let maximumLabel = row.maximumValueLabel
        else {
            return stack
        }

        stack.addArrangedSubview(
            sliderRow(
                title: "Minimum",
                slider: minimumSlider,
                valueLabel: minimumLabel,
                accessibilityLabel: "Minimum brightness for \(row.state.record.name)"
            )
        )
        stack.addArrangedSubview(
            sliderRow(
                title: "Maximum",
                slider: maximumSlider,
                valueLabel: maximumLabel,
                accessibilityLabel: "Maximum brightness for \(row.state.record.name)"
            )
        )
        return stack
    }

    private func refreshControls() {
        guard contentStack != nil else { return }
        brightnessSyncCheckbox?.state = settings.brightnessSyncEnabled ? .on : .off
        let thresholds = settings.appearanceThresholds
        darkThresholdSlider?.doubleValue = thresholds.dark * 100.0
        lightThresholdSlider?.doubleValue = thresholds.light * 100.0
        darkThresholdValueLabel?.stringValue = percentageText(thresholds.dark)
        lightThresholdValueLabel?.stringValue = percentageText(thresholds.light)
        menuBarIconCheckbox?.state = settings.menuBarIconVisible ? .on : .off
        refreshLoginControls()
        appearanceStatusLabel?.stringValue = appearanceStatus.userMessage
    }

    private func refreshLoginControls() {
        launchAtLoginCheckbox?.state = loginItemEnabled ? .on : .off
        loginStatusLabel?.stringValue = loginStatusMessage ?? ""
        loginStatusLabel?.isHidden = loginStatusMessage == nil
    }

    private func reflowDocument() {
        guard let documentView, let contentStack else { return }
        contentStack.layoutSubtreeIfNeeded()
        let fittingSize = contentStack.fittingSize
        let width = max(documentView.bounds.width, 620)
        let height = max(fittingSize.height + 48, 680)
        documentView.setFrameSize(NSSize(width: width, height: height))
        contentStack.frame = NSRect(x: 24, y: 24, width: width - 48, height: fittingSize.height)
        documentView.needsLayout = true
    }

    private func makePercentageSlider(action: Selector) -> NSSlider {
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: self, action: action)
        slider.isContinuous = true
        slider.numberOfTickMarks = 11
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return slider
    }

    private func sliderRow(
        title: String,
        slider: NSSlider,
        valueLabel: NSTextField,
        accessibilityLabel: String
    ) -> NSView {
        let titleLabel = label(title)
        titleLabel.widthAnchor.constraint(equalToConstant: 125).isActive = true
        slider.setAccessibilityLabel(accessibilityLabel)
        valueLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let row = NSStackView(views: [titleLabel, slider, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func label(
        _ text: String,
        font: NSFont = .systemFont(ofSize: 13),
        wrapping: Bool = false
    ) -> NSTextField {
        let field = wrapping ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = font
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = wrapping ? 0 : 1
        return field
    }

    private func valueLabel() -> NSTextField {
        let field = label("0%")
        field.alignment = .right
        return field
    }

    private func percentageText(_ value: Double) -> String {
        "\(Int((value * 100.0).rounded()))%"
    }

    @objc private func brightnessSyncChanged(_ sender: NSButton) {
        settings.brightnessSyncEnabled = sender.state == .on
        onBrightnessSyncChanged()
    }

    @objc private func thresholdChanged(_ sender: NSSlider) {
        _ = sender
        let normalized = AppearanceThresholds.normalized(
            dark: (darkThresholdSlider?.doubleValue ?? 25.0) / 100.0,
            light: (lightThresholdSlider?.doubleValue ?? 40.0) / 100.0
        )
        settings.appearanceThresholds = normalized
        let stored = settings.appearanceThresholds
        darkThresholdSlider?.doubleValue = stored.dark * 100.0
        lightThresholdSlider?.doubleValue = stored.light * 100.0
        darkThresholdValueLabel?.stringValue = percentageText(stored.dark)
        lightThresholdValueLabel?.stringValue = percentageText(stored.light)
        onAppearanceThresholdsChanged(stored)
    }

    @objc private func displayRangeChanged(_ sender: NSSlider) {
        guard let row = displayRows.first(where: { $0.minimumSlider === sender || $0.maximumSlider === sender }),
              let minimumSlider = row.minimumSlider,
              let maximumSlider = row.maximumSlider,
              let minimumLabel = row.minimumValueLabel,
              let maximumLabel = row.maximumValueLabel
        else {
            return
        }

        settings.setRange(
            DisplayBrightnessRange(
                minimum: minimumSlider.doubleValue / 100.0,
                maximum: maximumSlider.doubleValue / 100.0
            ),
            for: row.state.record.identity
        )
        let normalized = settings.range(for: row.state.record.identity)
        minimumSlider.doubleValue = normalized.minimum * 100.0
        maximumSlider.doubleValue = normalized.maximum * 100.0
        minimumLabel.stringValue = percentageText(normalized.minimum)
        maximumLabel.stringValue = percentageText(normalized.maximum)
        onDisplayRangeChanged()
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        onLaunchAtLoginChanged(sender.state == .on)
    }

    @objc private func menuBarIconVisibilityChanged(_ sender: NSButton) {
        let visible = sender.state == .on
        settings.menuBarIconVisible = visible
        onMenuBarIconVisibilityChanged(visible)
    }

    @objc private func openAutomationSettings(_ sender: NSButton) {
        _ = sender
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
