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
}

/// Which temperature a profile curve or the menu bar follows.
enum SensorSource: String, CaseIterable, Identifiable, Codable {
    case cpu
    case gpu
    case hottest

    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .hottest: return "Hottest (CPU or GPU)"
        }
    }
}
