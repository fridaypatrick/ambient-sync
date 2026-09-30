import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private final class DisplayRow {
        let state: DisplayState
        let minimumSlider: NSSlider?
        let maximumSlider: NSSlider?
        let minimumValueLabel: NSTextField?
        let maximumValueLabel: NSTextField?
        let assumedMaximumPopup: NSPopUpButton?
        let assumedMaximumField: NSTextField?
        let retryButton: NSButton?

        init(
            state: DisplayState,
            minimumSlider: NSSlider? = nil,
            maximumSlider: NSSlider? = nil,
            minimumValueLabel: NSTextField? = nil,
            maximumValueLabel: NSTextField? = nil,
            assumedMaximumPopup: NSPopUpButton? = nil,
            assumedMaximumField: NSTextField? = nil,
            retryButton: NSButton? = nil
        ) {
            self.state = state
            self.minimumSlider = minimumSlider
            self.maximumSlider = maximumSlider
            self.minimumValueLabel = minimumValueLabel
            self.maximumValueLabel = maximumValueLabel
            self.assumedMaximumPopup = assumedMaximumPopup
            self.assumedMaximumField = assumedMaximumField
            self.retryButton = retryButton
        }
    }

    private let settings: SettingsStore
    private let brightnessSyncForcedOff: Bool
    private let onBrightnessSyncChanged: () -> Void
    private let onAppearanceThresholdsChanged: (AppearanceThresholds) -> Void
    private let onDisplayRangeChanged: () -> Void
    private let onAssumedMaximumChanged: (DisplayIdentity, UInt16) -> Void
    private let onRetryDisplay: (DisplayTargetKey) -> Void
    private let onLaunchAtLoginChanged: (Bool) -> Void
    private let onMenuBarIconVisibilityChanged: (Bool) -> Void

    private var snapshot = DisplaySnapshot.empty
    private var appearanceStatus: AppearanceAutomationStatus = .notAttempted
    private var loginItemEnabled = false
    private var loginStatusMessage: String?
    private var displayRows: [DisplayRow] = []

    private var documentView: SettingsDocumentView?
    private var contentStack: NSStackView?
    private var contentWidthConstraint: NSLayoutConstraint?
    private var isReflowingDocument = false
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
        onMenuBarIconVisibilityChanged: @escaping (Bool) -> Void,
        onAssumedMaximumChanged: @escaping (DisplayIdentity, UInt16) -> Void = { _, _ in },
        onRetryDisplay: @escaping (DisplayTargetKey) -> Void = { _ in },
        brightnessSyncForcedOff: Bool = false
    ) {
        self.settings = settings
        self.brightnessSyncForcedOff = brightnessSyncForcedOff
        self.onBrightnessSyncChanged = onBrightnessSyncChanged
        self.onAppearanceThresholdsChanged = onAppearanceThresholdsChanged
        self.onDisplayRangeChanged = onDisplayRangeChanged
        self.onAssumedMaximumChanged = onAssumedMaximumChanged
        self.onRetryDisplay = onRetryDisplay
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
        reflowDocument()
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
        window.backgroundColor = .windowBackgroundColor

        let rootView = SettingsBackgroundView(frame: NSRect(x: 0, y: 0, width: 620, height: 680))
        let scrollView = NSScrollView(frame: rootView.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let documentView = SettingsDocumentView(frame: NSRect(x: 0, y: 0, width: 620, height: 680))
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        contentWidthConstraint = contentStack.widthAnchor.constraint(equalToConstant: 572)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            contentWidthConstraint!
        ])
        scrollView.documentView = documentView
        rootView.addSubview(scrollView)
        window.contentView = rootView

        self.documentView = documentView
        self.contentStack = contentStack
        self.window = window
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportDidResize(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )

        buildStaticContent()
        rebuildDisplayRows()
        refreshControls()
        reflowDocument()
        window.center()
    }

    private func buildStaticContent() {
        guard let contentStack else { return }

        let icon = NSImageView()
        icon.image = NSImage(named: NSImage.Name("AppIcon"))
            ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let headerText = verticalStack(spacing: 4)
        headerText.addArrangedSubview(label("AmbientSync", font: .systemFont(ofSize: 20, weight: .semibold)))
        let description = label("Sync brightness with supported external displays and adjust system appearance.", wrapping: true)
        description.textColor = .secondaryLabelColor
        addFullWidth(description, to: headerText)
        let header = NSStackView(views: [icon, headerText])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 12
        addFullWidth(header, to: contentStack)

        let global = verticalStack(spacing: 6)

        let brightnessCheckbox = NSButton(
            checkboxWithTitle: "Enable brightness synchronization",
            target: self,
            action: #selector(brightnessSyncChanged(_:))
        )
        brightnessCheckbox.setAccessibilityLabel("Enable brightness synchronization")
        self.brightnessSyncCheckbox = brightnessCheckbox
        global.addArrangedSubview(brightnessCheckbox)
        global.setCustomSpacing(12, after: brightnessCheckbox)
        let separator = NSBox()
        separator.boxType = .separator
        addFullWidth(separator, to: global)
        global.setCustomSpacing(10, after: separator)
        let thresholdsHeading = label("Appearance thresholds", font: .systemFont(ofSize: 12, weight: .medium))
        thresholdsHeading.textColor = .secondaryLabelColor
        global.addArrangedSubview(thresholdsHeading)
        let thresholdsHelp = label(
            "Uses built-in display brightness. At or below the Dark threshold, AmbientSync requests Dark Mode; at or above the Light threshold, it requests Light Mode. Brightness between the thresholds does not trigger a new appearance change.",
            font: .systemFont(ofSize: 12),
            wrapping: true
        )
        thresholdsHelp.textColor = .secondaryLabelColor
        addFullWidth(thresholdsHelp, to: global)

        let darkSlider = makePercentageSlider(action: #selector(thresholdChanged(_:)))
        let lightSlider = makePercentageSlider(action: #selector(thresholdChanged(_:)))
        self.darkThresholdSlider = darkSlider
        self.lightThresholdSlider = lightSlider
        let darkValue = valueLabel()
        let lightValue = valueLabel()
        self.darkThresholdValueLabel = darkValue
        self.lightThresholdValueLabel = lightValue
        addFullWidth(
            sliderRow(
                title: "Dark threshold",
                slider: darkSlider,
                valueLabel: darkValue,
                accessibilityLabel: "Dark appearance threshold"
            ), to: global
        )
        addFullWidth(
            sliderRow(
                title: "Light threshold",
                slider: lightSlider,
                valueLabel: lightValue,
                accessibilityLabel: "Light appearance threshold"
            ), to: global
        )
        addSection("Global", body: card(global), to: contentStack)
        let startup = verticalStack(spacing: 10)
        let login = verticalStack(spacing: 4)

        let launchCheckbox = NSButton(
            checkboxWithTitle: "Launch at Login",
            target: self,
            action: #selector(launchAtLoginChanged(_:))
        )
        launchCheckbox.setAccessibilityLabel("Launch AmbientSync at Login")
        self.launchAtLoginCheckbox = launchCheckbox
        login.addArrangedSubview(launchCheckbox)
        let loginStatusLabel = label("", font: .systemFont(ofSize: 12), wrapping: true)
        loginStatusLabel.textColor = .secondaryLabelColor
        loginStatusLabel.isHidden = true
        self.loginStatusLabel = loginStatusLabel
        login.addArrangedSubview(loginStatusLabel)
        loginStatusLabel.leadingAnchor.constraint(equalTo: login.leadingAnchor, constant: 20).isActive = true
        loginStatusLabel.trailingAnchor.constraint(equalTo: login.trailingAnchor).isActive = true
        addFullWidth(login, to: startup)

        let menuCheckbox = NSButton(
            checkboxWithTitle: "Show menu-bar icon",
            target: self,
            action: #selector(menuBarIconVisibilityChanged(_:))
        )
        menuCheckbox.setAccessibilityLabel("Show AmbientSync menu-bar icon")
        self.menuBarIconCheckbox = menuCheckbox
        startup.addArrangedSubview(menuCheckbox)
        addSection("Startup & menu bar", body: card(startup), to: contentStack)

        let displayStack = NSStackView()
        displayStack.orientation = .vertical
        displayStack.alignment = .leading
        displayStack.spacing = 10
        self.displayStack = displayStack
        addSection("Displays", body: displayStack, to: contentStack)

        let automation = verticalStack(spacing: 10)
        let appearanceStatusLabel = label("", font: .systemFont(ofSize: 12), wrapping: true)
        appearanceStatusLabel.textColor = .secondaryLabelColor
        self.appearanceStatusLabel = appearanceStatusLabel
        addFullWidth(appearanceStatusLabel, to: automation)

        let openAutomationButton = NSButton(
            title: "Open Automation Settings",
            target: self,
            action: #selector(openAutomationSettings(_:))
        )
        openAutomationButton.bezelStyle = .rounded
        openAutomationButton.setAccessibilityLabel("Open Automation Settings")
        automation.addArrangedSubview(openAutomationButton)
        addSection("Appearance automation", body: card(automation), to: contentStack)
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addSection(_ title: String, body: NSView, to stack: NSStackView) {
        let section = verticalStack(spacing: 8)
        section.addArrangedSubview(label(title, font: .systemFont(ofSize: 13, weight: .semibold)))
        addFullWidth(body, to: section)
        addFullWidth(section, to: stack)
    }

    private func card(_ stack: NSStackView) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        guard let content = box.contentView else { return box }
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        return box
    }

    private func rebuildDisplayRows() {
        guard let displayStack else { return }
        displayStack.arrangedSubviews.forEach {
            displayStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        displayRows.removeAll(keepingCapacity: true)

        if snapshot.displays.isEmpty {
            addFullWidth(label("No displays detected yet.", wrapping: true), to: displayStack)
            reflowDocument()
            return
        }

        for state in snapshot.displays {
            let row = makeDisplayRow(state)
            displayRows.append(row)
            addFullWidth(rowView(for: row), to: displayStack)
        }
        reflowDocument()
    }

    private func makeDisplayRow(_ state: DisplayState) -> DisplayRow {
        guard state.support.isExternal,
              state.support != .unsupportedExternal,
              let capability = state.capability
        else {
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

        var assumedMaximumPopup: NSPopUpButton?
        var assumedMaximumField: NSTextField?
        if capability.isWriteOnly {
            let maximum = settings.assumedMaximum(for: state.record.identity)
            let popup = makeAssumedMaximumPopup(maximum: maximum)
            let field = NSTextField(string: String(maximum))
            field.isEditable = true
            field.isSelectable = true
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 82).isActive = true
            field.setAccessibilityLabel("Assumed maximum VCP value for \(state.record.name)")
            field.target = self
            field.action = #selector(assumedMaximumFieldChanged(_:))
            assumedMaximumPopup = popup
            assumedMaximumField = field
        }

        var retryButton: NSButton?
        if state.support.isDegraded {
            let button = NSButton(
                title: "Retry",
                target: self,
                action: #selector(retryDisplay(_:))
            )
            button.bezelStyle = .rounded
            button.setAccessibilityLabel("Retry brightness control for \(state.record.name)")
            retryButton = button
        }

        return DisplayRow(
            state: state,
            minimumSlider: minimumSlider,
            maximumSlider: maximumSlider,
            minimumValueLabel: minimumLabel,
            maximumValueLabel: maximumLabel,
            assumedMaximumPopup: assumedMaximumPopup,
            assumedMaximumField: assumedMaximumField,
            retryButton: retryButton
        )
    }

    private func rowView(for row: DisplayRow) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let title = label(row.state.record.name, font: .systemFont(ofSize: 13, weight: .semibold), wrapping: true)
        title.setAccessibilityLabel(row.state.record.name)
        addFullWidth(title, to: stack)
        stack.setCustomSpacing(4, after: title)

        let statusText: String
        statusText = row.state.support.userFacingLabel
        let status = label(statusText, font: .systemFont(ofSize: 12), wrapping: true)
        status.textColor = row.state.support.isDegraded ? .labelColor : .secondaryLabelColor
        addFullWidth(status, to: stack)
        stack.setCustomSpacing(10, after: status)

        guard let minimumSlider = row.minimumSlider,
              let maximumSlider = row.maximumSlider,
              let minimumLabel = row.minimumValueLabel,
              let maximumLabel = row.maximumValueLabel
        else {
            return card(stack)
        }

        addFullWidth(
            sliderRow(
                title: "Minimum",
                slider: minimumSlider,
                valueLabel: minimumLabel,
                accessibilityLabel: "Minimum brightness for \(row.state.record.name)"
            ), to: stack
        )
        addFullWidth(
            sliderRow(
                title: "Maximum",
                slider: maximumSlider,
                valueLabel: maximumLabel,
                accessibilityLabel: "Maximum brightness for \(row.state.record.name)"
            ), to: stack
        )

        if let popup = row.assumedMaximumPopup,
           let field = row.assumedMaximumField {
            stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
            let assumedTitle = label("Assumed maximum", wrapping: true)
            assumedTitle.widthAnchor.constraint(equalToConstant: 125).isActive = true
            let assumedRow = NSStackView(views: [assumedTitle, popup, field])
            assumedRow.orientation = .horizontal
            assumedRow.alignment = .centerY
            assumedRow.spacing = 8
            stack.addArrangedSubview(assumedRow)
            stack.setCustomSpacing(4, after: assumedRow)
            let caveat =
                label(
                    "Used for write-only VCP scaling; hardware maximum is unverified.",
                    font: .systemFont(ofSize: 12),
                    wrapping: true
                )
            caveat.textColor = .secondaryLabelColor
            addFullWidth(caveat, to: stack)
        }

        if let retryButton = row.retryButton {
            stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(retryButton)
        }
        return card(stack)
    }

    private func refreshControls() {
        guard contentStack != nil else { return }
        brightnessSyncCheckbox?.state = brightnessSyncForcedOff || settings.brightnessSyncEnabled ? .on : .off
        if brightnessSyncForcedOff {
            brightnessSyncCheckbox?.state = .off
            brightnessSyncCheckbox?.isEnabled = false
        }
        let thresholds = settings.appearanceThresholds
        darkThresholdSlider?.doubleValue = thresholds.dark * 100.0
        lightThresholdSlider?.doubleValue = thresholds.light * 100.0
        darkThresholdValueLabel?.stringValue = percentageText(thresholds.dark)
        lightThresholdValueLabel?.stringValue = percentageText(thresholds.light)
        menuBarIconCheckbox?.state = settings.menuBarIconVisible ? .on : .off
        refreshLoginControls()
        appearanceStatusLabel?.stringValue = appearanceStatus.userMessage
        reflowDocument()
    }

    private func refreshLoginControls() {
        launchAtLoginCheckbox?.state = loginItemEnabled ? .on : .off
        loginStatusLabel?.stringValue = loginStatusMessage ?? ""
        loginStatusLabel?.isHidden = loginStatusMessage == nil
        reflowDocument()
    }

    private func reflowDocument() {
        guard !isReflowingDocument, let documentView, let contentStack,
              let scrollView = documentView.enclosingScrollView else { return }
        isReflowingDocument = true
        defer { isReflowingDocument = false }
        // A legacy scroller can appear after measuring the content height. Measure
        // again with its actual viewport width so it never covers the document.
        for _ in 0..<2 {
            scrollView.tile()
            let viewport = scrollView.contentView
            let width = viewport.bounds.width
            contentWidthConstraint?.constant = max(0, width - 48)
            documentView.setFrameSize(NSSize(width: width, height: documentView.frame.height))
            documentView.layoutSubtreeIfNeeded()
            contentStack.layoutSubtreeIfNeeded()
            let height = max(contentStack.fittingSize.height + 48, viewport.bounds.height)
            documentView.setFrameSize(NSSize(width: width, height: height))
        }
        documentView.needsLayout = true
    }

    func windowDidResize(_ notification: Notification) {
        reflowDocument()
    }

    @objc private func viewportDidResize(_ notification: Notification) {
        reflowDocument()
    }

    private func makePercentageSlider(action: Selector) -> NSSlider {
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: self, action: action)
        slider.isContinuous = true
        slider.numberOfTickMarks = 11
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    private func makeAssumedMaximumPopup(maximum: UInt16) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItem(withTitle: "100")
        popup.addItem(withTitle: "255")
        popup.addItem(withTitle: "Custom")
        popup.item(at: 0)?.representedObject = NSNumber(value: 100)
        popup.item(at: 1)?.representedObject = NSNumber(value: 255)
        popup.item(at: 2)?.representedObject = NSNumber(value: maximum)
        popup.widthAnchor.constraint(equalToConstant: 100).isActive = true
        popup.setAccessibilityLabel("Assumed maximum preset")
        popup.target = self
        popup.action = #selector(assumedMaximumPresetChanged(_:))
        if maximum == 100 {
            popup.selectItem(at: 0)
        } else if maximum == 255 {
            popup.selectItem(at: 1)
        } else {
            popup.selectItem(at: 2)
        }
        return popup
    }

    private func sliderRow(
        title: String,
        slider: NSSlider,
        valueLabel: NSTextField,
        accessibilityLabel: String
    ) -> NSView {
        let titleLabel = label(title, wrapping: true)
        titleLabel.widthAnchor.constraint(equalToConstant: 125).isActive = true
        slider.setAccessibilityLabel(accessibilityLabel)
        valueLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let row = NSStackView(views: [titleLabel, slider, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
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
        field.textColor = .labelColor
        if wrapping {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        return field
    }

    private func valueLabel() -> NSTextField {
        let field = label("0%")
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.alignment = .right
        return field
    }

    private func percentageText(_ value: Double) -> String {
        "\(Int((value * 100.0).rounded()))%"
    }

    @objc private func brightnessSyncChanged(_ sender: NSButton) {
        guard !brightnessSyncForcedOff else {
            sender.state = .off
            return
        }
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

    @objc private func assumedMaximumPresetChanged(_ sender: NSPopUpButton) {
        guard let row = displayRows.first(where: { $0.assumedMaximumPopup === sender }),
              let item = sender.selectedItem,
              let represented = item.representedObject as? NSNumber
        else {
            return
        }

        let maximum = settings.setAssumedMaximum(
            represented.intValue,
            for: row.state.record.identity
        )
        row.assumedMaximumField?.stringValue = String(maximum)
        onAssumedMaximumChanged(row.state.record.identity, maximum)
    }

    @objc private func assumedMaximumFieldChanged(_ sender: NSTextField) {
        guard let row = displayRows.first(where: { $0.assumedMaximumField === sender }) else {
            return
        }
        let maximum = settings.setAssumedMaximum(
            sender.integerValue,
            for: row.state.record.identity
        )
        sender.stringValue = String(maximum)
        row.assumedMaximumPopup?.selectItem(at: 2)
        onAssumedMaximumChanged(row.state.record.identity, maximum)
    }

    @objc private func retryDisplay(_ sender: NSButton) {
        guard let row = displayRows.first(where: { $0.retryButton === sender }) else {
            return
        }
        onRetryDisplay(
            DisplayTargetKey(
                identity: row.state.record.identity,
                displayID: row.state.record.displayID
            )
        )
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

@MainActor
private final class SettingsBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
