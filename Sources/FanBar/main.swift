import AppKit
import Darwin
import ServiceManagement
import SMCBridge

private enum FanPreset: Equatable {
    case automatic
    case target(Int)
    case fullBlast

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .target(let rpm): return "\(rpm) rpm"
        case .fullBlast: return "Full blast"
        }
    }
}

private enum MenuBarContent: Int {
    case both, temperature, fanSpeed
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let helper = FanHelper()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let readoutField = NSTextField(labelWithString: "--°C\n-- rpm")
    private lazy var readoutHeight = readoutField.heightAnchor.constraint(equalToConstant: 22)
    private let menu = NSMenu()
    private var timer: Timer?
    private var preset: FanPreset = .automatic
    private var metrics = FanBarMetrics(temperatureC: 0, rpm: 0, minimumRPM: 0, maximumRPM: 0, fanCount: 0)
    private var presetItems: [(FanPreset, NSMenuItem)] = []
    private var settingsWindow: NSWindow?
    private var loginItemCheck: NSButton?
    private var temperatureUnitPopup: NSPopUpButton?
    private var sensorPopup: NSPopUpButton?
    private lazy var sensors = TemperatureSensor.available()
    private var menuBarContentPopup: NSPopUpButton?
    private var twoLinesCheck: NSButton?
    private var automaticMode: NSButton?
    private var manualMode: NSButton?
    private var slider: NSSlider?
    private var sliderValue: NSTextField?
    private var sliderMinimum: NSTextField?
    private var sliderMaximum: NSTextField?
    private var fanReadouts: [(current: NSTextField, maximum: NSTextField)] = []
    private var settingsStatus: NSTextField?
    private var autoUpdateCheck: NSButton?
    private let updates = Updates()
    private let launchCallout = LaunchCallout()
    private let updateItem = NSMenuItem(title: "", action: #selector(installUpdate), keyEquivalent: "")
    private let updateSeparator = NSMenuItem.separator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let atLogin = launchedAtLogin
        NSApp.setActivationPolicy(.accessory)
        configureMainMenu()
        configureStatusItem()
        configureMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        updates.canRestartNow = { [weak self] in self?.preset == .automatic }
        updates.onAvailableChange = { [weak self] _ in self?.showUpdateAvailable() }
        updates.start()
        // Say where FanBar went, except at login when nobody asked for it.
        if !atLogin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.launchCallout.show(below: self?.statusItem.button)
            }
        }
    }

    /// Opening FanBar again from Finder or Spotlight while it runs opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
    }

    private var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// The menu bar menus shown while Settings is open and FanBar is in the Dock.
    private func configureMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About FanBar", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettingsWindow), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide FanBar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit FanBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let main = NSMenu()
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// The install item at the top of the menu while an update is waiting.
    private func showUpdateAvailable() {
        let shown = menu.items.contains(updateItem)
        guard let version = updates.availableVersion else {
            if shown {
                menu.removeItem(updateItem)
                menu.removeItem(updateSeparator)
            }
            return
        }
        updateItem.title = updates.isReadyToInstall ? "Update to \(version) and Restart" : "Update to \(version)…"
        if !shown {
            menu.insertItem(updateItem, at: 0)
            menu.insertItem(updateSeparator, at: 1)
        }
    }

    @objc private func installUpdate() {
        updates.installAvailableUpdate()
    }

    @objc private func checkForUpdates() {
        updates.checkForUpdates()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if preset != .automatic { helper.restoreAutomaticIfRunning() }
    }

    private func configureStatusItem() {
        statusItem.menu = menu
        if let button = statusItem.button {
            button.toolTip = "FanBar"
            button.title = ""
            readoutField.alignment = .center
            readoutField.font = NSFont.systemFont(ofSize: 9, weight: .regular)
            readoutField.textColor = .labelColor
            readoutField.isEditable = false
            readoutField.isSelectable = false
            readoutField.isBezeled = false
            readoutField.drawsBackground = false
            readoutField.usesSingleLineMode = false
            readoutField.maximumNumberOfLines = 2
            readoutField.lineBreakMode = .byClipping
            readoutField.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(readoutField)
            NSLayoutConstraint.activate([
                readoutField.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                readoutField.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                readoutHeight
            ])
        }
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        // Not named openSettings: AppKit auto-adds a gear icon for that selector, misaligning the menu.
        let open = NSMenuItem(title: "Open FanBar", action: #selector(showSettingsWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let presets: [FanPreset] = [.automatic, .fullBlast]
        for preset in presets {
            let item = NSMenuItem(title: preset.title, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            presetItems.append((preset, item))
        }
        menu.addItem(.separator())
        let presetsMenu = NSMenu(title: "Presets")
        let fixedPresets: [FanPreset] = [.target(1000), .target(2000), .target(3000), .target(4000), .target(5000), .target(6000)]
        for preset in fixedPresets {
            let item = NSMenuItem(title: preset.title, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            presetsMenu.addItem(item)
            presetItems.append((preset, item))
        }
        let presetsItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        presetsItem.submenu = presetsMenu
        menu.addItem(presetsItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FanBar", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        updateItem.target = self
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let selected = presetItems.first(where: { $0.1 === sender })?.0 else { return }
        preset = selected
        apply(selected)
        updateChecks()
        refreshSettingsControls()
        refresh()
    }

    /// Sends the preset to every fan. The UI shows it straight away; if the
    /// helper can't apply it, the fans are left to macOS and the UI says so.
    private func apply(_ selected: FanPreset) {
        let completion: (FanHelper.Outcome) -> Void = { [weak self] outcome in
            guard let self, outcome != .done else { return }
            preset = .automatic
            updateChecks()
            refreshSettingsControls()
            report(outcome)
        }
        switch selected {
        case .automatic: helper.setAutomatic(completion: completion)
        case .target(let rpm): helper.setTarget(rpm: rpm, completion: completion)
        case .fullBlast: helper.setMaximum(completion: completion)
        }
    }

    private var showingFanAlert = false

    private func report(_ outcome: FanHelper.Outcome) {
        guard !showingFanAlert else { return }
        showingFanAlert = true
        defer { showingFanAlert = false }
        let alert = NSAlert()
        switch outcome {
        case .done:
            return
        case .needsApproval:
            alert.messageText = "Allow FanBar to control the fans"
            alert.informativeText = "FanBar changes fan speed through a background helper. Turn on FanBar in System Settings › General › Login Items & Extensions, then try again."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { helper.openApprovalSettings() }
        case .failed(let message):
            alert.messageText = "Fan speed not changed"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func showSettingsWindow() {
        if settingsWindow == nil { settingsWindow = makeSettingsWindow() }
        refreshSettingsControls()
        launchCallout.dismiss()
        // In the Dock and app switcher while Settings is open, like a normal app window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(settingsTab("General", symbol: "gearshape", content: makeGeneralPane()))
        tabs.addTabViewItem(settingsTab("Speed", symbol: "fan", content: makeFanPane()))
        tabs.addTabViewItem(settingsTab("About", symbol: "info.circle", content: makeAboutPane()))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func settingsTab(_ title: String, symbol: String, content: NSView) -> NSTabViewItem {
        let controller = NSViewController()
        controller.view = settingsPane(content)
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    // Every pane shares one size so switching tabs never resizes the window.
    private func settingsPane(_ content: NSView) -> NSView {
        let pane = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(content)
        NSLayoutConstraint.activate([
            pane.widthAnchor.constraint(equalToConstant: 480),
            pane.heightAnchor.constraint(equalToConstant: 280),
            content.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            content.topAnchor.constraint(equalTo: pane.topAnchor, constant: 32)
        ])
        return pane
    }

    // Right-aligned labels beside their controls; an empty label leaves the cell blank.
    private func formGrid(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { label, control in
            [label.isEmpty ? NSGridCell.emptyContentView : NSTextField(labelWithString: label), control]
        })
        grid.rowSpacing = 14
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .center }
        return grid
    }

    private func makeGeneralPane() -> NSView {
        let login = NSButton(checkboxWithTitle: "Launch FanBar at login", target: self, action: #selector(toggleLoginItem(_:)))
        loginItemCheck = login
        let autoUpdate = NSButton(checkboxWithTitle: "Install updates automatically", target: self, action: #selector(toggleAutoUpdate(_:)))
        autoUpdateCheck = autoUpdate

        let temperaturePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        temperaturePopup.addItems(withTitles: ["Celsius (°C)", "Fahrenheit (°F)"])
        temperaturePopup.target = self
        temperaturePopup.action = #selector(temperatureUnitChanged(_:))
        temperaturePopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        temperatureUnitPopup = temperaturePopup

        let sensorChoice = NSPopUpButton(frame: .zero, pullsDown: false)
        sensorChoice.addItems(withTitles: sensors.map(\.name))
        if sensors.isEmpty {
            sensorChoice.addItem(withTitle: "Default")
            sensorChoice.isEnabled = false
        }
        sensorChoice.target = self
        sensorChoice.action = #selector(sensorChanged(_:))
        sensorChoice.widthAnchor.constraint(equalToConstant: 220).isActive = true
        sensorPopup = sensorChoice

        let contentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        contentPopup.addItems(withTitles: ["Temperature and fan speed", "Temperature only", "Fan speed only"])
        contentPopup.target = self
        contentPopup.action = #selector(menuBarContentChanged(_:))
        contentPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        menuBarContentPopup = contentPopup

        let twoLines = NSButton(checkboxWithTitle: "Display readings in two lines to save space", target: self, action: #selector(twoLinesChanged(_:)))
        twoLinesCheck = twoLines

        let status = NSTextField(labelWithString: "")
        status.textColor = .secondaryLabelColor
        settingsStatus = status

        return formGrid([
            ("", login),
            ("", autoUpdate),
            ("Temperature unit:", temperaturePopup),
            ("Sensor:", sensorChoice),
            ("Menu bar:", contentPopup),
            ("", twoLines),
            ("", status)
        ])
    }

    private func makeFanPane() -> NSView {
        let fans = makeFanTable()

        let automatic = NSButton(radioButtonWithTitle: "Automatic", target: self, action: #selector(fanModeChanged(_:)))
        let manual = NSButton(radioButtonWithTitle: "Manual", target: self, action: #selector(fanModeChanged(_:)))
        automaticMode = automatic
        manualMode = manual
        let mode = NSStackView(views: [automatic, manual])
        mode.spacing = 16

        let value = NSTextField(labelWithString: "4000 rpm")
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        sliderValue = value

        let rpmSlider = NSSlider(value: 4000, minValue: 1000, maxValue: 6000, target: self, action: #selector(sliderChanged(_:)))
        rpmSlider.isContinuous = true
        slider = rpmSlider
        let minimum = NSTextField(labelWithString: "1000 rpm")
        sliderMinimum = minimum
        let maximum = NSTextField(labelWithString: "6000 rpm")
        sliderMaximum = maximum
        for label in [minimum, maximum] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
        }
        let range = NSStackView(views: [minimum, NSView(), maximum])
        let control = NSStackView(views: [rpmSlider, range])
        control.orientation = .vertical
        control.spacing = 2
        NSLayoutConstraint.activate([
            rpmSlider.widthAnchor.constraint(equalToConstant: 260),
            range.widthAnchor.constraint(equalTo: rpmSlider.widthAnchor)
        ])

        let hint = NSTextField(labelWithString: "Automatic lets macOS control the fan speed.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        return formGrid([("Fans:", fans), ("Mode:", mode), ("Target speed:", value), ("", control), ("", hint)])
    }

    /// One row per fan: name, current speed, and the most it can do.
    private func makeFanTable() -> NSView {
        let count = Int(metrics.fanCount)
        fanReadouts = []
        if count == 0 {
            let none = NSTextField(labelWithString: "This Mac has no fans")
            none.textColor = .secondaryLabelColor
            return none
        }
        let rows: [[NSView]] = (0..<count).map { index in
            let name = NSTextField(labelWithString: fanName(index, of: count))
            let current = NSTextField(labelWithString: "-- rpm")
            current.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            current.alignment = .right
            let maximum = NSTextField(labelWithString: "max --")
            maximum.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            maximum.textColor = .secondaryLabelColor
            fanReadouts.append((current, maximum))
            return [name, current, maximum]
        }
        let table = NSGridView(views: rows)
        table.rowSpacing = 4
        table.columnSpacing = 12
        table.column(at: 1).xPlacement = .trailing
        table.rowAlignment = .lastBaseline
        refreshFanReadouts()
        return table
    }

    /// SMC has no fan names on Apple silicon. Two-fan MacBook Pros put fan 0 on
    /// the left, which is how other fan utilities label them too; desktops
    /// (Mac mini, Mac Studio, iMac, Mac Pro) just get numbers.
    private func fanName(_ index: Int, of count: Int) -> String {
        if count == 1 { return "Fan" }
        if count == 2 && sysctlString("hw.model").hasPrefix("MacBookPro") { return index == 0 ? "Left" : "Right" }
        return "Fan \(index + 1)"
    }

    private func refreshFanReadouts() {
        for (index, readout) in fanReadouts.enumerated() {
            var fan = FanBarFan(rpm: 0, minimumRPM: 0, maximumRPM: 0)
            if fanbar_read_fan(UInt32(index), &fan) == 0 {
                readout.current.stringValue = "\(fan.rpm) rpm"
                readout.maximum.stringValue = "max \(fan.maximumRPM)"
            } else {
                readout.current.stringValue = "-- rpm"
                readout.maximum.stringValue = "max --"
            }
        }
    }

    private func makeAboutPane() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64)
        ])
        let name = NSTextField(labelWithString: "FanBar")
        name.font = .systemFont(ofSize: 18, weight: .semibold)
        let about = NSTextField(labelWithString: "Menu bar fan control for MacBook.")
        about.textColor = .secondaryLabelColor
        let version = NSTextField(labelWithString: "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
        version.textColor = .secondaryLabelColor
        version.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let github = NSButton(title: "View on GitHub", target: self, action: #selector(openGitHub))
        github.isBordered = false
        github.contentTintColor = .linkColor

        let check = NSButton(title: "Check for Updates…", target: self, action: #selector(checkForUpdates))
        check.isEnabled = updates.isEnabled
        if !updates.isEnabled { check.toolTip = "Updates are off in local builds." }

        let stack = NSStackView(views: [icon, name, about, version, check, github])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(8, after: icon)
        stack.setCustomSpacing(10, after: version)
        stack.setCustomSpacing(6, after: check)
        return stack
    }

    private func refreshSettingsControls() {
        loginItemCheck?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        autoUpdateCheck?.state = updates.installsAutomatically ? .on : .off
        temperatureUnitPopup?.selectItem(at: usesFahrenheit ? 1 : 0)
        if let sensor = selectedSensor { sensorPopup?.selectItem(withTitle: sensor.name) }
        menuBarContentPopup?.selectItem(at: menuBarContent.rawValue)
        twoLinesCheck?.state = usesSingleLine ? .off : .on
        twoLinesCheck?.isEnabled = menuBarContent == .both
        slider?.minValue = Double(fanMinimumRPM)
        slider?.maxValue = Double(fanMaximumRPM)
        sliderMinimum?.stringValue = "\(fanMinimumRPM) rpm"
        sliderMaximum?.stringValue = "\(fanMaximumRPM) rpm"
        switch preset {
        case .fullBlast: slider?.doubleValue = Double(fanMaximumRPM)
        case .target(let rpm): slider?.doubleValue = Double(rpm)
        case .automatic: break
        }
        if let slider { showTarget(sliderPreset(slider)) }
    }

    // The hardware range when the SMC reports one; the helper only accepts 1000...8000.
    private var fanMaximumRPM: Int {
        metrics.maximumRPM >= 2000 ? min(Int(metrics.maximumRPM), 8000) : 6000
    }

    private var fanMinimumRPM: Int {
        max(1000, min(Int(metrics.minimumRPM), fanMaximumRPM - 1000))
    }

    // Snaps to 100 rpm steps. The track spans the lowest fan minimum to the
    // highest fan maximum; each fan clamps the target to its own range, so the
    // right end runs every fan at its own top speed.
    private func sliderPreset(_ slider: NSSlider) -> FanPreset {
        if slider.doubleValue >= slider.maxValue - 50 { return .target(fanMaximumRPM) }
        if slider.doubleValue <= slider.minValue + 50 { return .target(fanMinimumRPM) }
        return .target(min(max(Int((slider.doubleValue / 100).rounded()) * 100, fanMinimumRPM), fanMaximumRPM))
    }

    private func showTarget(_ target: FanPreset) {
        switch target {
        case .fullBlast: sliderValue?.stringValue = "\(fanMaximumRPM) rpm"
        case .target(let rpm): sliderValue?.stringValue = "\(rpm) rpm"
        case .automatic: break
        }
    }

    @objc private func fanModeChanged(_ sender: NSButton) {
        let selected: FanPreset = sender === automaticMode ? .automatic : slider.map(sliderPreset) ?? .target(4000)
        guard selected != preset else { return }
        preset = selected
        apply(selected)
        updateChecks()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let selected = sliderPreset(sender)
        showTarget(selected)
        guard selected != preset else { return }
        // Force Touch trackpads tick when the thumb reaches either end.
        if selected == .target(fanMaximumRPM) || selected == .target(fanMinimumRPM) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        preset = selected
        apply(selected)
        updateChecks()
    }

    @objc private func toggleAutoUpdate(_ sender: NSButton) {
        updates.installsAutomatically = sender.state == .on
    }

    @objc private func toggleLoginItem(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            settingsStatus?.stringValue = ""
        } catch {
            sender.state = .off
            settingsStatus?.stringValue = "Launch at login requires a bundled FanBar.app."
        }
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/vipinsight/fanbar")!)
    }

    @objc private func temperatureUnitChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem == 1, forKey: "usesFahrenheit")
        refresh()
    }

    @objc private func sensorChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.titleOfSelectedItem, forKey: "temperatureSensor")
        refresh()
    }

    @objc private func menuBarContentChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem, forKey: "menuBarContent")
        twoLinesCheck?.isEnabled = menuBarContent == .both
        refresh()
    }

    @objc private func twoLinesChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .off, forKey: "usesSingleLine")
        refresh()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func refresh() {
        let unit = usesFahrenheit ? "F" : "C"
        var temperatureText = "--°\(unit)"
        var rpmText = "-- rpm"
        let metricsRead = fanbar_read_metrics(&metrics) == 0
        if metricsRead { rpmText = "\(metrics.rpm) rpm" }
        // A chosen sensor that reads nothing (an idle GPU) shows --, not another sensor's value.
        let celsius = selectedSensor.map { $0.read() } ?? (metricsRead && metrics.temperatureC > 0 ? metrics.temperatureC : nil)
        if let celsius {
            let temperature = usesFahrenheit ? (celsius * 9 / 5 + 32) : celsius
            temperatureText = String(format: "%.0f°%@", temperature, unit)
        }
        refreshFanReadouts()
        switch menuBarContent {
        case .both: setTitle(temperatureText + (usesSingleLine ? readoutSeparator : "\n") + rpmText)
        case .temperature: setTitle(temperatureText)
        case .fanSpeed: setTitle(rpmText)
        }
        updateChecks()
    }

    private var usesFahrenheit: Bool {
        UserDefaults.standard.bool(forKey: "usesFahrenheit")
    }

    private var selectedSensor: TemperatureSensor? {
        let name = UserDefaults.standard.string(forKey: "temperatureSensor")
        return sensors.first { $0.name == name } ?? sensors.first
    }

    private var usesSingleLine: Bool {
        UserDefaults.standard.bool(forKey: "usesSingleLine")
    }

    private var menuBarContent: MenuBarContent {
        MenuBarContent(rawValue: UserDefaults.standard.integer(forKey: "menuBarContent")) ?? .both
    }

    private let readoutSeparator = "  |  "

    private func setTitle(_ title: String) {
        // Two stacked lines need a small font and tight lines to fit the menu bar height.
        let stacked = title.contains("\n")
        let font = NSFont.monospacedDigitSystemFont(ofSize: stacked ? 9 : 12, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        if stacked {
            paragraph.minimumLineHeight = 10
            paragraph.maximumLineHeight = 10
        }
        let attributed = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
        let separator = (title as NSString).range(of: readoutSeparator)
        if separator.location != NSNotFound {
            attributed.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: separator)
        }
        readoutField.attributedStringValue = attributed
        // Fit the field to its text so centerY centers one line as well as two.
        readoutHeight.constant = ceil(readoutField.cell?.cellSize.height ?? 22)
        // Size the item to the drawn text; the field stays centered on it.
        statusItem.length = ceil(attributed.size().width) + 4
    }

    private func updateChecks() {
        for (itemPreset, item) in presetItems { item.state = itemPreset == preset ? .on : .off }
        automaticMode?.state = preset == .automatic ? .on : .off
        manualMode?.state = preset == .automatic ? .off : .on
        let hasFans = metrics.fanCount > 0
        manualMode?.isEnabled = hasFans
        slider?.isEnabled = hasFans && preset != .automatic
        sliderValue?.textColor = preset == .automatic ? .disabledControlTextColor : .labelColor
    }
}

if CommandLine.arguments.contains("--automatic") {
    exit(Int32(fanbar_set_automatic()))
}
if let index = CommandLine.arguments.firstIndex(of: "--set-rpm"),
   index + 1 < CommandLine.arguments.count,
   let rpm = UInt32(CommandLine.arguments[index + 1]) {
    exit(Int32(fanbar_set_target_rpm(rpm)))
}

// Spacing is split across both sides (system default 16 = 8pt each). Registered defaults apply to FanBar only and are not persisted.
UserDefaults.standard.register(defaults: ["NSStatusItemSpacing": 6])

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
