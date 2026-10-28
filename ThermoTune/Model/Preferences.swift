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
    static let safetyNetEnabled = "safetyNetEnabled"
    static let safetyLimit = "safetyLimit"
    static let safetyDelay = "safetyDelay"
    static let safetyAction = "safetyAction"
    static let alertSafetyNet = "alertSafetyNet"
    static let alertTemperature = "alertTemperature"
    static let alertTemperatureSource = "alertTemperatureSource"
    static let alertTemperatureLimit = "alertTemperatureLimit"
    static let alertTemperatureDuration = "alertTemperatureDuration"
    static let alertFanStall = "alertFanStall"
    static let alertThermalPressure = "alertThermalPressure"
    static let alertHelper = "alertHelper"
    static let rulesEnabled = "rulesEnabled"
    static let rules = "profileRules"
    static let rulesFallbackProfileID = "rulesFallbackProfileID"
    static let shortcuts = "shortcuts"
    static let menuBarContent = "menuBarContent"
    static let menuBarUsesAverage = "menuBarUsesAverage"
    static let menuBarColored = "menuBarColored"
    static let menuBarGraph = "menuBarGraph"
    static let menuBarCompact = "menuBarCompact"
    static let hideDockIcon = "hideDockIcon"
    static let keepsLog = "keepsLog"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            temperatureUnit: TemperatureUnit.celsius.rawValue,
            refreshInterval: 2.0,
            restoreAutomaticOnQuit: true,
            showMenuBarExtra: true,
            menuBarSource: SensorSource.cpu.rawValue,
            menuBarContent: MenuBarContent.temperature.rawValue,
            menuBarUsesAverage: false,
            menuBarColored: false,
            menuBarGraph: false,
            menuBarCompact: false,
            hideDockIcon: false,
            keepsLog: false,
            chartWindowMinutes: 5,
            safetyNetEnabled: true,
            safetyLimit: 95.0,
            safetyDelay: 10.0,
            safetyAction: SafetyAction.automatic.rawValue,
            alertSafetyNet: true,
            alertTemperature: false,
            alertTemperatureSource: SensorSource.hottest.rawValue,
            alertTemperatureLimit: 90.0,
            alertTemperatureDuration: 30.0,
            alertFanStall: true,
            alertThermalPressure: true,
            alertHelper: true,
        ])
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius
    case fahrenheit

    var id: Self { self }
    var title: String { self == .celsius ? String(localized: "Celsius (°C)") : String(localized: "Fahrenheit (°F)") }
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
        case .cpu: return String(localized: "CPU")
        case .gpu: return String(localized: "GPU")
        case .hottest: return String(localized: "Hottest (CPU or GPU)")
        case .sensor(let key): return String(localized: "Sensor \(key)")
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

/// What the safety net does once a reading has stayed over its limit.
enum SafetyAction: String, CaseIterable, Identifiable {
    /// Let go of the fans: macOS's own thermal management ramps them and
    /// throttles the Mac as designed. The active profile is switched off.
    case automatic
    /// Every fan to full speed until the reading is 10° under the limit, then
    /// the profile carries on.
    case max

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: return String(localized: "Hand the fans back to macOS")
        case .max: return String(localized: "Run every fan at full speed")
        }
    }
}

/// What the menu bar item shows.
enum MenuBarContent: String, CaseIterable, Identifiable {
    case temperature
    case fanSpeed
    case both
    case icon

    var id: Self { self }

    var title: String {
        switch self {
        case .temperature: return String(localized: "Temperature")
        case .fanSpeed: return String(localized: "Fan speed")
        case .both: return String(localized: "Temperature and fan speed")
        case .icon: return String(localized: "Icon only")
        }
    }
}
