import Foundation

struct TemperatureSensor: Identifiable, Equatable {
    enum Group: String, CaseIterable {
        case cpuPerformance = "Performance Cores"
        case cpuEfficiency = "Efficiency Cores"
        case cpu = "CPU"
        case gpu = "GPU"
        case other = "Other"

        var title: String {
            switch self {
            case .cpuPerformance: return String(localized: "Performance Cores")
            case .cpuEfficiency: return String(localized: "Efficiency Cores")
            // The whole package, as opposed to the per-core groups.
            case .cpu: return String(localized: "CPU Package")
            case .gpu: return String(localized: "GPU")
            case .other: return String(localized: "Other")
            }
        }
    }

    let key: String
    var value: Double

    var id: String { key }

    /// Where a sensor most likely sits, by key prefix. Apple doesn't publish what each
    /// key measures; these are the community's best guesses for Apple silicon, with
    /// Intel's `TC` and `TG`.
    private static let prefixes: [String: (group: Group, label: String)] = [
        "Tp": (.cpuPerformance, String(localized: "Performance cores")),
        "Te": (.cpuEfficiency, String(localized: "Efficiency cores")),
        "TC": (.cpu, String(localized: "CPU package")),
        "Tg": (.gpu, String(localized: "GPU")),
        "TG": (.gpu, String(localized: "GPU")),
        "TB": (.other, String(localized: "Battery")),
        "TH": (.other, String(localized: "SSD")),
        "TW": (.other, String(localized: "Wi-Fi")),
        "Ts": (.other, String(localized: "Palm rest")),
        "Ta": (.other, String(localized: "Airflow")),
        "TA": (.other, String(localized: "Ambient")),
        "Tm": (.other, String(localized: "Memory")),
    ]

    var group: Group { Self.prefixes[String(key.prefix(2))]?.group ?? .other }
    var label: String { Self.prefixes[String(key.prefix(2))]?.label ?? String(localized: "Sensor") }

    var isCPU: Bool { [.cpuPerformance, .cpuEfficiency, .cpu].contains(group) }
    var isGPU: Bool { group == .gpu }

    /// A readable name per key: the label, numbered when several sensors share it
    /// ("Performance cores 3"), in key order so numbers stay stable between launches.
    static func names(for sensors: [TemperatureSensor]) -> [String: String] {
        var names: [String: String] = [:]
        for (_, group) in Dictionary(grouping: sensors, by: \.label) {
            let sorted = group.sorted { $0.key < $1.key }
            for (index, sensor) in sorted.enumerated() {
                names[sensor.key] = sorted.count == 1 ? sensor.label : String(localized: "\(sensor.label) \(index + 1)", comment: "A sensor name numbered among several with the same name, e.g. Performance cores 3")
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
