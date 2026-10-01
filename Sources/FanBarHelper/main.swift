import Foundation
import SMCBridge

// FanBar's root daemon. launchd starts it from inside FanBar.app once the user
// allows FanBar in System Settings (SMAppService), and keeps it alive.
//
// Commands, one per connection, applied to every fan: `auto`, `max` (each fan
// to its own maximum), `rpm <1000-10000>`, `version` (the app
// bundle's CFBundleVersion, so the app can spot a stale daemon after an
// update), and `exit` (launchd restarts it from the current bundle).

let socketPath = "/var/run/com.webtiara.fanbar.daemon.sock"
// Bundle.main is the enclosing FanBar.app: the binary lives in Contents/MacOS.
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"

/// FanBar 1.0.0 installed its helper with an admin password under another
/// label. Remove it so two daemons don't fight over the fans.
func removeLegacyHelper() {
    let plist = "/Library/LaunchDaemons/com.webtiara.fanbar.helper.plist"
    guard FileManager.default.fileExists(atPath: plist) else { return }
    let bootout = Process()
    bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootout.arguments = ["bootout", "system/com.webtiara.fanbar.helper"]
    try? bootout.run()
    bootout.waitUntilExit()
    try? FileManager.default.removeItem(atPath: plist)
    try? FileManager.default.removeItem(atPath: "/Library/PrivilegedHelperTools/com.webtiara.fanbar.helper")
    unlink("/var/run/com.webtiara.fanbar.helper.sock")
}

removeLegacyHelper()

unlink(socketPath)
let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
guard descriptor >= 0 else { exit(1) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &address.sun_path) { bytes in
    socketPath.utf8CString.withUnsafeBytes { source in bytes.copyBytes(from: source) }
}
let addressSize = socklen_t(MemoryLayout<sockaddr_un>.size)
let bound = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, addressSize) }
}
guard bound == 0, listen(descriptor, 4) == 0 else { exit(1) }
chmod(socketPath, 0o660)
chown(socketPath, 0, 20) // root:staff; local logged-in users can control their own helper.

// SMC writes and the owner watch all happen on one queue.
let fans = DispatchQueue(label: "com.webtiara.fanbar.daemon.fans")
var owner: DispatchSourceProcess?

/// Hands the fans back to macOS when the app that set them exits for any
/// reason: quit, crash, force quit, or logout. The app also resets them on a
/// normal quit, but a crashed app can't.
func watch(_ pid: pid_t) {
    if owner?.handle == pid { return }
    owner?.cancel()
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: fans)
    source.setEventHandler {
        _ = fanbar_set_automatic()
        source.cancel()
        if owner?.handle == pid { owner = nil }
    }
    source.resume()
    owner = source
}

func unwatch() {
    owner?.cancel()
    owner = nil
}

func peerPID(_ client: Int32) -> pid_t? {
    var pid: pid_t = 0
    var size = socklen_t(MemoryLayout<pid_t>.size)
    return getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 0 ? pid : nil
}

func handle(_ command: String, from pid: pid_t?) -> String {
    switch command {
    case "auto":
        unwatch()
        return "\(fanbar_set_automatic())"
    case "max":
        if let pid { watch(pid) }
        return "\(fanbar_set_maximum())"
    case "version":
        return version
    default:
        guard command.hasPrefix("rpm "), let value = UInt32(command.dropFirst(4)), value >= 1000, value <= 10000 else { return "-1" }
        if let pid { watch(pid) }
        return "\(fanbar_set_target_rpm(value))"
    }
}

// Nobody has asked for manual control in this daemon's lifetime yet, and
// launchd stopping it (FanBar removed, or disallowed in System Settings)
// shouldn't leave the fans pinned either.
fans.sync { _ = fanbar_set_automatic() }
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: fans)
termination.setEventHandler {
    _ = fanbar_set_automatic()
    exit(0)
}
termination.resume()

Thread.detachNewThread {
    while true {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { continue }
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = read(client, &buffer, buffer.count - 1)
        var shouldExit = false
        if count > 0 {
            let command = String(decoding: buffer[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            shouldExit = command == "exit"
            let pid = peerPID(client)
            var response = shouldExit ? "0" : fans.sync { handle(command, from: pid) }
            response += "\n"
            response.withUTF8 { _ = write(client, $0.baseAddress, $0.count) }
        }
        close(client)
        if shouldExit { exit(0) }
    }
}

dispatchMain()
