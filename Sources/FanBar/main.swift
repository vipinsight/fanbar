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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let helperSocket = "/var/run/com.webtiara.fanbar.helper.sock"
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let readoutField = NSTextField(labelWithString: "--°C\n-- rpm")
    private let menu = NSMenu()
    private var timer: Timer?
    private var preset: FanPreset = .automatic
    private var metrics = FanBarMetrics(temperatureC: 0, rpm: 0, minimumRPM: 0, maximumRPM: 0, fanCount: 0)
    private var presetItems: [(FanPreset, NSMenuItem)] = []
    private var settingsWindow: NSWindow?
    private var loginItemCheck: NSButton?
    private var temperatureUnitPopup: NSPopUpButton?
    private var slider: NSSlider?
    private var sliderValue: NSTextField?
    private var settingsStatus: NSTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if preset != .automatic { _ = runPrivileged(arguments: ["--automatic"]) }
    }

    private func configureStatusItem() {
        statusItem.length = 62
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
                readoutField.widthAnchor.constraint(equalTo: button.widthAnchor),
                readoutField.heightAnchor.constraint(equalToConstant: 22)
            ])
        }
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        let open = NSMenuItem(title: "Open FanBar", action: #selector(openSettings), keyEquivalent: "")
        open.target = self
        open.image = nil
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
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let selected = presetItems.first(where: { $0.1 === sender })?.0 else { return }
        preset = selected
        let result = apply(selected)
        if result != 0 { showControlError(result) }
        updateChecks()
        refresh()
    }

    @discardableResult
    private func apply(_ selected: FanPreset) -> Int32 {
        switch selected {
        case .automatic: return runPrivileged(arguments: ["--automatic"])
        case .target(let rpm): return runPrivileged(arguments: ["--set-rpm", "\(rpm)"])
        case .fullBlast:
            let maximum = max(metrics.maximumRPM, 6000)
            return runPrivileged(arguments: ["--set-rpm", "\(maximum)"])
        }
    }

    private func runPrivileged(arguments: [String]) -> Int32 {
        if !FileManager.default.fileExists(atPath: helperSocket) {
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

    private func installHelper() -> Int32 {
        let bundleRoot = Bundle.main.bundleURL
        let helper = bundleRoot.appendingPathComponent("Contents/Library/PrivilegedHelperTools/com.webtiara.fanbar.helper").path
        let plist = bundleRoot.appendingPathComponent("Contents/Library/LaunchDaemons/com.webtiara.fanbar.helper.plist").path
        guard FileManager.default.fileExists(atPath: helper), FileManager.default.fileExists(atPath: plist) else { return -1 }
        let command = "mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons && cp \(shellQuote(helper)) /Library/PrivilegedHelperTools/com.webtiara.fanbar.helper && cp \(shellQuote(plist)) /Library/LaunchDaemons/com.webtiara.fanbar.helper.plist && chown root:wheel /Library/PrivilegedHelperTools/com.webtiara.fanbar.helper /Library/LaunchDaemons/com.webtiara.fanbar.helper.plist && chmod 755 /Library/PrivilegedHelperTools/com.webtiara.fanbar.helper && (launchctl print system/com.webtiara.fanbar.helper >/dev/null 2>&1 || launchctl bootstrap system /Library/LaunchDaemons/com.webtiara.fanbar.helper.plist)"
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

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = makeSettingsWindow() }
        refreshSettingsControls()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 390), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "FanBar"
        window.center()
        window.isReleasedWhenClosed = false

        let aboutTitle = NSTextField(labelWithString: "FanBar")
        aboutTitle.font = .systemFont(ofSize: 24, weight: .semibold)
        let about = NSTextField(labelWithString: "Menu bar fan control for MacBook.\nMonitor temperature and control fan speed.")
        about.textColor = .secondaryLabelColor
        about.maximumNumberOfLines = 2

        let generalTitle = NSTextField(labelWithString: "General")
        generalTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let login = NSButton(title: "Launch FanBar at login", target: self, action: #selector(toggleLoginItem(_:)))
        login.setButtonType(.switch)
        login.controlSize = .regular
        loginItemCheck = login

        let temperatureLabel = NSTextField(labelWithString: "Temperature unit")
        let temperaturePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        temperaturePopup.addItems(withTitles: ["Celsius (°C)", "Fahrenheit (°F)"])
        temperaturePopup.target = self
        temperaturePopup.action = #selector(temperatureUnitChanged(_:))
        temperatureUnitPopup = temperaturePopup
        temperaturePopup.widthAnchor.constraint(equalToConstant: 145).isActive = true
        let temperatureRow = NSStackView(views: [temperatureLabel, NSView(), temperaturePopup])
        temperatureRow.distribution = .fill
        temperatureRow.alignment = .centerY

        let presetTitle = NSTextField(labelWithString: "Custom fan speed")
        presetTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let value = NSTextField(labelWithString: "4000 rpm")
        value.alignment = .right
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sliderValue = value
        let rpmSlider = NSSlider(value: 4000, minValue: 1000, maxValue: 6000, target: self, action: #selector(sliderChanged(_:)))
        rpmSlider.isContinuous = true
        slider = rpmSlider
        let range = NSTextField(labelWithString: "1000 rpm")
        range.textColor = .secondaryLabelColor
        let maxRange = NSTextField(labelWithString: "6000 rpm")
        maxRange.textColor = .secondaryLabelColor
        let rangeRow = NSStackView(views: [range, NSView(), maxRange])
        rangeRow.distribution = .fill
        let status = NSTextField(labelWithString: "")
        status.textColor = .secondaryLabelColor
        settingsStatus = status

        let stack = NSStackView(views: [aboutTitle, about, NSView(), generalTitle, login, temperatureRow, NSView(), presetTitle, value, rpmSlider, rangeRow, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.setCustomSpacing(2, after: aboutTitle)
        stack.setCustomSpacing(14, after: about)
        stack.setCustomSpacing(2, after: generalTitle)
        stack.setCustomSpacing(8, after: login)
        stack.setCustomSpacing(14, after: temperatureRow)
        stack.setCustomSpacing(2, after: presetTitle)
        stack.setCustomSpacing(0, after: rpmSlider)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            rpmSlider.widthAnchor.constraint(equalToConstant: 382),
            rangeRow.widthAnchor.constraint(equalToConstant: 382),
            temperatureRow.widthAnchor.constraint(equalToConstant: 382),
            status.widthAnchor.constraint(equalToConstant: 382)
        ])
        return window
    }

    private func refreshSettingsControls() {
        loginItemCheck?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        temperatureUnitPopup?.selectItem(at: usesFahrenheit ? 1 : 0)
        let value = customRPM()
        slider?.doubleValue = Double(value)
        sliderValue?.stringValue = "\(value) rpm"
    }

    private func customRPM() -> Int {
        if case .target(let rpm) = preset { return rpm }
        return 4000
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let rpm = Int(sender.doubleValue.rounded() / 100) * 100
        sliderValue?.stringValue = "\(rpm) rpm"
        preset = .target(rpm)
        let result = apply(.target(rpm))
        if result != 0 { showControlError(result) }
        updateChecks()
    }

    @objc private func toggleLoginItem(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            settingsStatus?.stringValue = "Launch at login updated."
        } catch {
            sender.state = .off
            settingsStatus?.stringValue = "Launch at login requires a bundled FanBar.app."
        }
    }

    @objc private func temperatureUnitChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem == 1, forKey: "usesFahrenheit")
        refresh()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func refresh() {
        guard fanbar_read_metrics(&metrics) == 0 else {
            setTitle("--°\(usesFahrenheit ? "F" : "C")\n-- rpm")
            return
        }
        let temperature = usesFahrenheit ? (metrics.temperatureC * 9 / 5 + 32) : metrics.temperatureC
        let unit = usesFahrenheit ? "F" : "C"
        setTitle(String(format: "%.0f°%@\n%d rpm", temperature, unit, metrics.rpm))
        updateChecks()
    }

    private var usesFahrenheit: Bool {
        UserDefaults.standard.bool(forKey: "usesFahrenheit")
    }

    private func setTitle(_ title: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = -2
        readoutField.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular)
        ]
        let width = title
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { (String($0) as NSString).size(withAttributes: attributes).width }
            .max() ?? 0
        statusItem.length = max(40, ceil(width) + 4)
    }

    private func updateChecks() {
        for (itemPreset, item) in presetItems { item.state = itemPreset == preset ? .on : .off }
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
