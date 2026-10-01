import Darwin
import SMCBridge

/// A temperature the menu bar can show: one SMC key, or the average of several.
struct TemperatureSensor {
    let name: String
    let keys: [String]

    /// Averages every key that currently reads a plausible temperature.
    func read() -> Double? {
        let values = keys.compactMap(readTemperature)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// The sensors this Mac reports. On Apple silicon "CPU Core Average" always
    /// comes first, so it is the default and the menu bar never shows something
    /// like the palm rest as the headline temperature.
    static func available(
        brand: String = sysctlString("machdep.cpu.brand_string"),
        coreCounts: (top: Int, second: Int) = (sysctlInt("hw.perflevel0.physicalcpu"), sysctlInt("hw.perflevel1.physicalcpu"))
    ) -> [TemperatureSensor] {
        var sensors: [TemperatureSensor] = []
        if brand.hasPrefix("Apple") {
            sensors += appleSiliconSensors(chip: ChipLayout.forBrand(brand), coreCounts: coreCounts)
        }
        sensors += [
            TemperatureSensor(name: "CPU Proximity", keys: ["TC0P"]),
            TemperatureSensor(name: "CPU Die", keys: ["TC0D"]),
            TemperatureSensor(name: "GPU Proximity", keys: ["TG0P"]),
            TemperatureSensor(name: "Battery", keys: ["TB0T", "TB1T", "TB2T"]),
            TemperatureSensor(name: "Airport Proximity", keys: ["TW0P"]),
            TemperatureSensor(name: "SSD", keys: ["TH0x"]),
            TemperatureSensor(name: "Palm Rest", keys: ["Ts0P"])
        ]
        return sensors.filter { $0.keys.contains(where: isPresent) }
    }

    private static func appleSiliconSensors(chip: ChipLayout?, coreCounts: (top: Int, second: Int)) -> [TemperatureSensor] {
        let present: (String) -> Bool = isPresent
        // Binned chips report keys for cores they don't have, so list only as
        // many as macOS says exist.
        func cores(_ keys: [String], count: Int) -> [String] {
            let found = keys.filter(present)
            return count > 0 ? Array(found.prefix(count)) : found
        }

        var sensors: [TemperatureSensor] = []
        var cpu: [(label: String, keys: [String])] = []
        var gpu: [String] = []
        if let chip {
            cpu = [
                (chip.second.label, cores(chip.second.keys, count: coreCounts.second)),
                (chip.top.label, cores(chip.top.keys, count: coreCounts.top))
            ]
            gpu = chip.gpu.filter(present)
        }

        let cpuKeys = cpu.flatMap(\.keys)
        if cpuKeys.isEmpty {
            // A chip newer than these tables, or one whose keys moved: average
            // whatever CPU die sensors it reports rather than show none.
            sensors.append(TemperatureSensor(name: "CPU Core Average", keys: discoveredCPUKeys()))
        } else {
            sensors.append(TemperatureSensor(name: "CPU Core Average", keys: cpuKeys))
            for cluster in cpu {
                sensors += cluster.keys.enumerated().map {
                    TemperatureSensor(name: "CPU \(cluster.label) Core \($0.offset + 1)", keys: [$0.element])
                }
            }
        }
        sensors += gpu.enumerated().map { TemperatureSensor(name: "GPU Cluster \($0.offset + 1)", keys: [$0.element]) }
        if gpu.count > 1 { sensors.append(TemperatureSensor(name: "GPU Cluster Average", keys: gpu)) }
        return sensors
    }

    /// SMC keys that look like CPU die sensors on Apple silicon (`Tp*`, `Te*`).
    private static func discoveredCPUKeys() -> [String] {
        var count: UInt32 = 0
        guard fanbar_key_count(&count) == 0 else { return [] }
        var keys: [String] = []
        var name = [CChar](repeating: 0, count: 5)
        for index in 0..<count where fanbar_key_at(index, &name) == 0 {
            let key = String(cString: name)
            if (key.hasPrefix("Tp") || key.hasPrefix("Te")) && readTemperature(key) != nil { keys.append(key) }
        }
        return keys
    }
}

/// Where each Apple silicon generation keeps its core and GPU temperatures.
///
/// The keys move between generations, so each needs its own table. Mapping
/// from the Stats app (github.com/exelban/stats, MIT), Modules/Sensors/values.swift.
struct ChipLayout {
    typealias Cluster = (label: String, keys: [String])

    /// `hw.perflevel0`: the fastest cores.
    let top: Cluster
    /// `hw.perflevel1`: the second tier.
    let second: Cluster
    let gpu: [String]

    static func forBrand(_ brand: String) -> ChipLayout? {
        if brand.contains("Apple M1") { return m1 }
        if brand.contains("Apple M2") { return m2 }
        if brand.contains("Apple M3") { return m3 }
        if brand.contains("Apple M4") { return m4 }
        if brand.contains("Apple M5") { return m5 }
        return nil
    }

    static let m1 = ChipLayout(
        top: ("Performance", ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]),
        second: ("Efficiency", ["Tp09", "Tp0T"]),
        gpu: ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
    )

    static let m2 = ChipLayout(
        top: ("Performance", ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]),
        second: ("Efficiency", ["Tp1h", "Tp1t", "Tp1p", "Tp1l"]),
        gpu: ["Tg0f", "Tg0j"]
    )

    static let m3 = ChipLayout(
        top: ("Performance", ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]),
        second: ("Efficiency", ["Te05", "Te0L", "Te0P", "Te0S"]),
        gpu: ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
    )

    // Base M4 and M4 Pro/Max name their first two GPU sensors differently;
    // only the ones this Mac reports survive the presence check.
    static let m4 = ChipLayout(
        top: ("Performance", ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]),
        second: ("Efficiency", ["Te05", "Te0S", "Te09", "Te0H"]),
        gpu: ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]
    )

    // M5 renames the tiers: super cores, then performance cores.
    static let m5 = ChipLayout(
        top: ("Super", ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K"]),
        second: ("Performance", ["Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]),
        gpu: ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]
    )
}

/// A plausible die or surface temperature. A powered-down GPU keeps reporting
/// a stale low value (around 9 °C), so anything under 15 °C reads as unknown.
func readTemperature(_ key: String) -> Double? {
    var value = 0.0
    guard fanbar_read_temperature(key, &value) == 0, value >= 15, value < 130 else { return nil }
    return value
}

/// Whether this Mac has the sensor, even if it reads nothing useful right now.
/// Keys that exist only as 0 are placeholders for hardware this model lacks.
func isPresent(_ key: String) -> Bool {
    var value = 0.0
    return fanbar_read_temperature(key, &value) == 0 && value != 0
}

func sysctlInt(_ name: String) -> Int {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: size)
    return sysctlbyname(name, &buffer, &size, nil, 0) == 0 ? String(cString: buffer) : ""
}
