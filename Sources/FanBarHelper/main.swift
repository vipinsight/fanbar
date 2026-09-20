import Foundation
import SMCBridge

let socketPath = "/var/run/com.webtiara.fanbar.helper.sock"
unlink(socketPath)
let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
guard descriptor >= 0 else { exit(1) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &address.sun_path) { bytes in
    _ = socketPath.utf8CString.withUnsafeBytes { source in bytes.copyBytes(from: source) }
}
let addressSize = socklen_t(MemoryLayout<sockaddr_un>.size)
let bound = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, addressSize) }
}
guard bound == 0, listen(descriptor, 4) == 0 else { exit(1) }
chmod(socketPath, 0o660)
chown(socketPath, 0, 20) // root:staff; local logged-in users can control their own helper.

while true {
    let client = accept(descriptor, nil, nil)
    guard client >= 0 else { continue }
    var buffer = [UInt8](repeating: 0, count: 128)
    let count = read(client, &buffer, buffer.count - 1)
    if count > 0 {
        let command = String(decoding: buffer[..<count], as: UTF8.self)
        var result: Int32 = -1
        if command.trimmingCharacters(in: .whitespacesAndNewlines) == "auto" {
            result = fanbar_set_automatic()
        } else if let rpm = command.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").last,
                  command.hasPrefix("rpm "), let value = UInt32(rpm), value >= 1000, value <= 8000 {
            result = fanbar_set_target_rpm(value)
        }
        var response = "\(result)\n"
        response.withUTF8 { _ = write(client, $0.baseAddress, $0.count) }
    }
    close(client)
}
