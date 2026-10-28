import Foundation

/// UserDefaults keys shared by `@AppStorage` in views and the model layer.
enum PreferenceKey {
    static let temperatureUnit = "temperatureUnit"
    static let refreshInterval = "refreshInterval"
    static let restoreAutomaticOnQuit = "restoreAutomaticOnQuit"
    static let showMenuBarExtra = "showMenuBarExtra"
    static let menuBarSource = "menuBarSource"
    static let chartWindowMinutes = "chartWindowMinutes"
    static let profiles = "profiles"
    static let activeProfileID = "activeProfileID"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            temperatureUnit: TemperatureUnit.celsius.rawValue,
            refreshInterval: 2.0,
            restoreAutomaticOnQuit: true,
            showMenuBarExtra: true,
            menuBarSource: SensorSource.cpu.rawValue,
            chartWindowMinutes: 5,
        ])
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius
    case fahrenheit

    var id: Self { self }
    var title: String { self == .celsius ? "Celsius (°C)" : "Fahrenheit (°F)" }
    var symbol: String { self == .celsius ? "°C" : "°F" }

    static var current: TemperatureUnit {
        UserDefaults.standard.string(forKey: PreferenceKey.temperatureUnit).flatMap(Self.init) ?? .celsius
    }

    func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    func toCelsius(_ value: Double) -> Double {
        self == .celsius ? value : (value - 32) * 5 / 9
    }
}

/// Which temperature a profile curve or the menu bar follows. The CPU and GPU
/// readings are the hottest sensor in each group.
enum SensorSource: Hashable, Identifiable {
    case cpu
    case gpu
    case hottest
    /// One sensor, by SMC key.
    case sensor(String)

    /// The grouped readings; a single sensor is picked from the sensor list.
    static let groups: [SensorSource] = [.cpu, .gpu, .hottest]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .hottest: return "Hottest (CPU or GPU)"
        case .sensor(let key): return "Sensor \(key)"
        }
    }
}

// A string raw value, so `@AppStorage` and saved profiles keep reading the
// values written before single sensors existed ("cpu", "gpu", "hottest").
extension SensorSource: RawRepresentable, Codable {
    private static let sensorPrefix = "sensor:"

    init?(rawValue: String) {
        switch rawValue {
        case "cpu": self = .cpu
        case "gpu": self = .gpu
        case "hottest": self = .hottest
        case let value where value.hasPrefix(Self.sensorPrefix) && value.count > Self.sensorPrefix.count:
            self = .sensor(String(value.dropFirst(Self.sensorPrefix.count)))
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "gpu"
        case .hottest: return "hottest"
        case .sensor(let key): return Self.sensorPrefix + key
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let source = Self(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown sensor source \(raw)"))
        }
        self = source
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
