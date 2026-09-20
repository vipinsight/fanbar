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

private final class StatusReadoutView: NSView {
    var readout = "--°C\n--rpm" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let lines = readout.split(separator: "\n", omittingEmptySubsequences: false)
        let temp = String(lines.first ?? "--°C") as NSString
        let rpm = String(lines.dropFirst().first ?? "--rpm") as NSString
        let textRect = NSRect(x: 0, y: 1, width: 40, height: 20)
        let tempAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let rpmAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let tempSize = temp.size(withAttributes: tempAttributes)
        let rpmSize = rpm.size(withAttributes: rpmAttributes)
        temp.draw(at: NSPoint(x: textRect.midX - tempSize.width / 2, y: 8), withAttributes: tempAttributes)
        rpm.draw(at: NSPoint(x: textRect.midX - rpmSize.width / 2, y: 0), withAttributes: rpmAttributes)

    }

    override func mouseDown(with event: NSEvent) {
        menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: self)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let helperSocket = "/var/run/com.webtiara.fanbar.helper.sock"
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusView = StatusReadoutView(frame: NSRect(x: 0, y: 0, width: 42, height: 22))
    private let menu = NSMenu()
    private var timer: Timer?
    private var preset: FanPreset = .automatic
    private var metrics = FanBarMetrics(temperatureC: 0, rpm: 0, minimumRPM: 0, maximumRPM: 0, fanCount: 0)
    private var presetItems: [(FanPreset, NSMenuItem)] = []
    private var settingsWindow: NSWindow?
    private var loginItemCheck: NSButton?
    private var slider: NSSlider?
    private var sliderValue: NSTextField?
    private var settingsStatus: NSTextField?
    private var customPresetItem: NSMenuItem?

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
        statusItem.length = 42
        statusItem.view = statusView
        statusView.menu = menu
        statusView.toolTip = "FanBar"
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        let open = NSMenuItem(title: "Open FanBar", action: #selector(openSettings), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let presets: [FanPreset] = [.automatic, .fullBlast, .target(1000), .target(2000), .target(4000), .target(6000)]
        for preset in presets {
            let item = NSMenuItem(title: preset.title, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            presetItems.append((preset, item))
        }
        let custom = NSMenuItem(title: "Custom RPM…", action: #selector(openSettings), keyEquivalent: "")
        custom.target = self
        customPresetItem = custom
        menu.addItem(custom)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FanBar", action: #selector(quit), keyEquivalent: "q")
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
        guard let helper = Bundle.main.path(forResource: "com.webtiara.fanbar.helper", ofType: nil, inDirectory: "Contents/Library/PrivilegedHelperTools"),
              let plist = Bundle.main.path(forResource: "com.webtiara.fanbar.helper", ofType: "plist", inDirectory: "Contents/Library/LaunchDaemons") else { return -1 }
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "FanBar Settings"
        window.center()
        window.isReleasedWhenClosed = false

        let aboutTitle = NSTextField(labelWithString: "FanBar")
        aboutTitle.font = .systemFont(ofSize: 24, weight: .bold)
        let about = NSTextField(labelWithString: "Menu bar fan control for MacBook.\nReads Apple SMC temperature and fan speed.")
        about.textColor = .secondaryLabelColor
        about.maximumNumberOfLines = 2

        let generalTitle = NSTextField(labelWithString: "General")
        generalTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let login = NSButton(checkboxWithTitle: "Start FanBar at system boot", target: self, action: #selector(toggleLoginItem(_:)))
        loginItemCheck = login

        let presetTitle = NSTextField(labelWithString: "Custom preset")
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

        let stack = NSStackView(views: [aboutTitle, about, NSView(), generalTitle, login, NSView(), presetTitle, value, rpmSlider, rangeRow, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.setCustomSpacing(2, after: aboutTitle)
        stack.setCustomSpacing(14, after: about)
        stack.setCustomSpacing(2, after: generalTitle)
        stack.setCustomSpacing(14, after: login)
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
            status.widthAnchor.constraint(equalToConstant: 382)
        ])
        return window
    }

    private func refreshSettingsControls() {
        loginItemCheck?.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
        customPresetItem?.state = .on
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

    @objc private func quit() { NSApp.terminate(nil) }

    private func refresh() {
        guard fanbar_read_metrics(&metrics) == 0 else {
            setTitle("--°C\n--rpm")
            return
        }
        setTitle(String(format: "%.0f°C\n%drpm", metrics.temperatureC, metrics.rpm))
        updateChecks()
    }

    private func setTitle(_ title: String) {
        statusView.readout = title
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
