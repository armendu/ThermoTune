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

    var label: String {
        switch key.prefix(2) {
        case "TB": return "Battery"
        case "TH": return "SSD"
        case "TW": return "Wireless"
        default: return group == .other ? "Sensor" : group.rawValue
        }
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
