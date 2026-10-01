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

private struct TemperatureSensor {
    let name: String
    let keys: [String]

    // Averages every key that currently reads a plausible temperature.
    func read() -> Double? {
        let values = keys.compactMap(readTemperature)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    static func available() -> [TemperatureSensor] {
        var sensors: [TemperatureSensor] = []
        // Core keys differ per chip generation; this table is M1 family only.
        if sysctlString("machdep.cpu.brand_string").contains("Apple M1") {
            let efficiency = Array(["Tp09", "Tp0T"].prefix(sysctlInt("hw.perflevel1.physicalcpu")))
            let performance = Array(["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"].prefix(sysctlInt("hw.perflevel0.physicalcpu")))
            let gpu = ["Tg05", "Tg0D", "Tg0L", "Tg0T"].filter { readTemperature($0) != nil }
            sensors.append(TemperatureSensor(name: "CPU Core Average", keys: efficiency + performance))
            sensors += efficiency.enumerated().map { TemperatureSensor(name: "CPU Efficiency Core \($0.offset + 1)", keys: [$0.element]) }
            sensors += performance.enumerated().map { TemperatureSensor(name: "CPU Performance Core \($0.offset + 1)", keys: [$0.element]) }
            sensors += gpu.enumerated().map { TemperatureSensor(name: "GPU Cluster \($0.offset + 1)", keys: [$0.element]) }
            if gpu.count > 1 { sensors.append(TemperatureSensor(name: "GPU Cluster Average", keys: gpu)) }
        }
        sensors += [
            TemperatureSensor(name: "CPU Proximity", keys: ["TC0P"]),
            TemperatureSensor(name: "CPU Die", keys: ["TC0D"]),
            TemperatureSensor(name: "GPU Proximity", keys: ["TG0P"]),
            TemperatureSensor(name: "Battery", keys: ["TB0T"]),
            TemperatureSensor(name: "Airport Proximity", keys: ["TW0P"]),
            TemperatureSensor(name: "SSD", keys: ["TH0x"]),
            TemperatureSensor(name: "Palm Rest", keys: ["Ts0P"])
        ]
        return sensors.filter { $0.read() != nil }
    }
}

private func readTemperature(_ key: String) -> Double? {
    var value = 0.0
    guard fanbar_read_temperature(key, &value) == 0, value > 0, value < 130 else { return nil }
    return value
}

private func sysctlInt(_ name: String) -> Int {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
}

private func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: size)
    return sysctlbyname(name, &buffer, &size, nil, 0) == 0 ? String(cString: buffer) : ""
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let helperSocket = "/var/run/com.webtiara.fanbar.helper.sock"
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
    private var currentSpeed: NSTextField?
    private var settingsStatus: NSTextField?
    private var autoUpdateCheck: NSButton?
    private let updates = Updates()
    private let updateItem = NSMenuItem(title: "", action: #selector(installUpdate), keyEquivalent: "")
    private let updateSeparator = NSMenuItem.separator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        updates.canRestartNow = { [weak self] in self?.preset == .automatic }
        updates.onAvailableChange = { [weak self] _ in self?.showUpdateAvailable() }
        updates.start()
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
        if preset != .automatic { _ = runPrivileged(arguments: ["--automatic"]) }
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
        let result = apply(selected)
        if result != 0 { showControlError(result) }
        updateChecks()
        refreshSettingsControls()
        refresh()
    }

    @discardableResult
    private func apply(_ selected: FanPreset) -> Int32 {
        switch selected {
        case .automatic: return runPrivileged(arguments: ["--automatic"])
        case .target(let rpm): return runPrivileged(arguments: ["--set-rpm", "\(rpm)"])
        case .fullBlast: return runPrivileged(arguments: ["--set-rpm", "\(fanMaximumRPM)"])
        }
    }

    private func runPrivileged(arguments: [String]) -> Int32 {
        if !FileManager.default.fileExists(atPath: helperSocket) || helperIsOutdated {
            let installResult = installHelper()
            if installResult != 0 { return installResult }
        }
        let command = arguments.first == "--automatic" ? "auto" : "rpm \(arguments.last ?? "0")"
        for _ in 0..<20 {
            if let result = sendToHelper(command) { return result }
            usleep(100_000)
        }
        return -1
    }

    private let installedHelper = "/Library/PrivilegedHelperTools/com.webtiara.fanbar.helper"
    private var bundledHelper: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/PrivilegedHelperTools/com.webtiara.fanbar.helper").path
    }

    /// An app update ships a new helper, but the installed copy stays until replaced.
    private var helperIsOutdated: Bool {
        FileManager.default.fileExists(atPath: bundledHelper)
            && !FileManager.default.contentsEqual(atPath: installedHelper, andPath: bundledHelper)
    }

    private func installHelper() -> Int32 {
        let bundleRoot = Bundle.main.bundleURL
        let helper = bundledHelper
        let plist = bundleRoot.appendingPathComponent("Contents/Library/LaunchDaemons/com.webtiara.fanbar.helper.plist").path
        guard FileManager.default.fileExists(atPath: helper), FileManager.default.fileExists(atPath: plist) else { return -1 }
        let command = "mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons && cp \(shellQuote(helper)) /Library/PrivilegedHelperTools/com.webtiara.fanbar.helper && cp \(shellQuote(plist)) /Library/LaunchDaemons/com.webtiara.fanbar.helper.plist && chown root:wheel /Library/PrivilegedHelperTools/com.webtiara.fanbar.helper /Library/LaunchDaemons/com.webtiara.fanbar.helper.plist && chmod 755 /Library/PrivilegedHelperTools/com.webtiara.fanbar.helper && if launchctl print system/com.webtiara.fanbar.helper >/dev/null 2>&1; then launchctl kickstart -k system/com.webtiara.fanbar.helper; else launchctl bootstrap system /Library/LaunchDaemons/com.webtiara.fanbar.helper.plist; fi"
        return runAsAdmin(command)
    }

    private func runAsAdmin(_ command: String) -> Int32 {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch { return -1 }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func sendToHelper(_ command: String) -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            _ = helperSocket.utf8CString.withUnsafeBytes { source in bytes.copyBytes(from: source) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        let payload = Array((command + "\n").utf8)
        _ = payload.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        var response = [UInt8](repeating: 0, count: 32)
        let count = read(descriptor, &response, response.count - 1)
        guard count > 0 else { return -1 }
        return Int32(String(decoding: response[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func showControlError(_ result: Int32) {
        let message = result == -2
            ? "FanBar needs administrator permission to change fan speed."
            : "Apple SMC rejected this fan command (error \(result))."
        let alert = NSAlert()
        alert.messageText = "Fan speed not changed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func showSettingsWindow() {
        if settingsWindow == nil { settingsWindow = makeSettingsWindow() }
        refreshSettingsControls()
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
        window.center()
        return window
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
        let current = NSTextField(labelWithString: "-- rpm")
        current.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        currentSpeed = current

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
        let maximum = NSTextField(labelWithString: "Max")
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

        return formGrid([("Current speed:", current), ("Mode:", mode), ("Target speed:", value), ("", control), ("", hint)])
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

    // Snaps to 100 rpm steps; the ends of the track are the fan's minimum and Max.
    private func sliderPreset(_ slider: NSSlider) -> FanPreset {
        if slider.doubleValue >= slider.maxValue - 50 { return .fullBlast }
        if slider.doubleValue <= slider.minValue + 50 { return .target(fanMinimumRPM) }
        return .target(min(Int((slider.doubleValue / 100).rounded()) * 100, fanMaximumRPM - 100))
    }

    private func showTarget(_ target: FanPreset) {
        switch target {
        case .fullBlast: sliderValue?.stringValue = "Max (\(fanMaximumRPM) rpm)"
        case .target(let rpm): sliderValue?.stringValue = "\(rpm) rpm"
        case .automatic: break
        }
    }

    @objc private func fanModeChanged(_ sender: NSButton) {
        let selected: FanPreset = sender === automaticMode ? .automatic : slider.map(sliderPreset) ?? .target(4000)
        guard selected != preset else { return }
        preset = selected
        let result = apply(selected)
        if result != 0 { showControlError(result) }
        updateChecks()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let selected = sliderPreset(sender)
        showTarget(selected)
        guard selected != preset else { return }
        // Force Touch trackpads tick when the thumb snaps to Max or to the minimum.
        if selected == .fullBlast || selected == .target(fanMinimumRPM) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        preset = selected
        let result = apply(selected)
        if result != 0 { showControlError(result) }
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
        if let celsius = selectedSensor?.read() ?? (metricsRead ? metrics.temperatureC : nil) {
            let temperature = usesFahrenheit ? (celsius * 9 / 5 + 32) : celsius
            temperatureText = String(format: "%.0f°%@", temperature, unit)
        }
        currentSpeed?.stringValue = rpmText
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
        slider?.isEnabled = preset != .automatic
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
