import Darwin
import Foundation
import ServiceManagement

/// Talks to the root daemon that writes fan speeds.
///
/// Changing fan speed needs root, so a small daemon inside the app bundle does
/// it. It is registered with `SMAppService`: macOS asks the user once, in
/// System Settings, to allow FanBar in the background, with no password and no
/// script warning, and the daemon is replaced along with the app on update.
final class FanHelper {
    static let socketPath = "/var/run/com.webtiara.fanbar.daemon.sock"

    enum Outcome: Equatable {
        case done
        /// The user hasn't allowed FanBar in System Settings yet.
        case needsApproval
        case failed(String)
    }

    private let service = SMAppService.daemon(plistName: "com.webtiara.fanbar.daemon.plist")
    private var versionChecked = false
    private let queue = DispatchQueue(label: "com.webtiara.fanbar.fan-helper")
    private let lock = NSLock()
    private var pending: (command: String, completion: (Outcome) -> Void)?

    func setAutomatic(completion: @escaping (Outcome) -> Void) { run("auto", completion) }

    func setMaximum(completion: @escaping (Outcome) -> Void) { run("max", completion) }

    func setTarget(rpm: Int, completion: @escaping (Outcome) -> Void) { run("rpm \(rpm)", completion) }

    /// Runs off the main thread: taking the fans from thermalmonitord can take
    /// seconds. Only the newest command waits, so dragging the slider sends the
    /// speed it lands on, not every step on the way.
    private func run(_ command: String, _ completion: @escaping (Outcome) -> Void) {
        lock.lock()
        pending = (command, completion)
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            let next = pending
            pending = nil
            lock.unlock()
            guard let next else { return }
            let outcome = send(next.command)
            DispatchQueue.main.async { next.completion(outcome) }
        }
    }

    /// Back to automatic on quit, without registering or prompting for anything.
    func restoreAutomaticIfRunning() {
        queue.sync { _ = request("auto") }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func send(_ command: String) -> Outcome {
        if let problem = ensureRegistered() { return problem }
        restartIfOutdated()
        // A freshly registered or restarted daemon takes a moment to open its socket.
        for _ in 0..<30 {
            if let reply = request(command) {
                guard let code = Int32(reply) else { return .failed("The fan helper sent an unexpected reply.") }
                return code == 0 ? .done : .failed("Apple SMC rejected this fan command (error \(code)).")
            }
            usleep(100_000)
        }
        return .failed("FanBar's fan helper isn't responding.")
    }

    private func ensureRegistered() -> Outcome? {
        switch service.status {
        case .enabled:
            return nil
        case .requiresApproval:
            return .needsApproval
        default:
            do {
                try service.register()
            } catch {
                return service.status == .requiresApproval
                    ? .needsApproval
                    : .failed("FanBar couldn't start its fan helper: \(error.localizedDescription)")
            }
            return service.status == .requiresApproval ? .needsApproval : nil
        }
    }

    /// After an update the daemon keeps running the old binary until it exits.
    /// Asked to, it quits and launchd starts the new one from the updated bundle.
    private func restartIfOutdated() {
        guard !versionChecked else { return }
        versionChecked = true
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let running = request("version"), running != current else { return }
        _ = request("exit")
        usleep(300_000)
    }

    /// One command over the daemon's socket; nil when it isn't listening.
    private func request(_ command: String) -> String? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            Self.socketPath.utf8CString.withUnsafeBytes { source in bytes.copyBytes(from: source) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let payload = Array((command + "\n").utf8)
        _ = payload.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        var response = [UInt8](repeating: 0, count: 64)
        let count = read(descriptor, &response, response.count - 1)
        guard count > 0 else { return nil }
        return String(decoding: response[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
