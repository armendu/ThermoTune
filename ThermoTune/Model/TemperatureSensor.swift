import Foundation

struct TemperatureSensor: Identifiable, Equatable {
    enum Group: String, CaseIterable {
        case cpuPerformance = "Performance Cores"
        case cpuEfficiency = "Efficiency Cores"
        case cpu = "CPU"
        case gpu = "GPU"
        case other = "Other"
    }

    let key: String
    var value: Double

    var id: String { key }

    /// Grouping is based on the SMC key prefix: `Tp`/`Te` are the Apple Silicon
    /// P/E-core clusters, `Tg` the Apple Silicon GPU, `TC`/`TG` Intel CPU/GPU.
    var group: Group {
        switch key.prefix(2) {
        case "Tp": return .cpuPerformance
        case "Te": return .cpuEfficiency
        case "TC": return .cpu
        case "Tg", "TG": return .gpu
        default: return .other
        }
    }

    var isCPU: Bool { [.cpuPerformance, .cpuEfficiency, .cpu].contains(group) }
    var isGPU: Bool { group == .gpu }

    /// Where the sensor most likely sits, from its key's prefix. Apple doesn't
    /// publish what each key measures; these are the community's best guesses
    /// for Apple silicon, and unknown prefixes stay a plain "Sensor".
    var label: String {
        switch key.prefix(2) {
        case "Tp": return "Performance cores"
        case "Te": return "Efficiency cores"
        case "Tg", "TG": return "GPU"
        case "TC": return "CPU package"
        case "TB": return "Battery"
        case "TH": return "SSD"
        case "TW": return "Wi-Fi"
        case "Ts": return "Palm rest"
        case "Ta": return "Airflow"
        case "TA": return "Ambient"
        case "Tm": return "Memory"
        default: return "Sensor"
        }
    }

    /// A readable name per key: the label, numbered when several sensors share it
    /// ("Performance cores 3"), in key order so numbers stay stable between launches.
    static func names(for sensors: [TemperatureSensor]) -> [String: String] {
        var names: [String: String] = [:]
        for (_, group) in Dictionary(grouping: sensors, by: \.label) {
            let sorted = group.sorted { $0.key < $1.key }
            for (index, sensor) in sorted.enumerated() {
                names[sensor.key] = sorted.count == 1 ? sensor.label : "\(sensor.label) \(index + 1)"
            }
        }
        return names
    }
}

struct TemperatureSummary {
    let average: Double
    let maximum: Double

    init?(_ sensors: [TemperatureSensor]) {
        guard !sensors.isEmpty else { return nil }
        average = sensors.map(\.value).reduce(0, +) / Double(sensors.count)
        maximum = sensors.map(\.value).max() ?? 0
    }
}
