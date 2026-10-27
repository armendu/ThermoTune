import Foundation
import Observation

/// A named fan behaviour applied to every fan.
struct FanProfile: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case automatic
        case fixed
        case curve
        case max

        var id: Self { self }

        var title: String {
            switch self {
            case .automatic: return "System Automatic"
            case .fixed: return "Fixed Speed"
            case .curve: return "Temperature Curve"
            case .max: return "Full Speed"
            }
        }

        var symbol: String {
            switch self {
            case .automatic: return "a.circle"
            case .fixed: return "gauge.with.dots.needle.33percent"
            case .curve: return "chart.line.uptrend.xyaxis"
            case .max: return "wind"
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    /// Fixed speed as a percentage of each fan's min…max range.
    var fixedPercent: Double = 50
    var source: SensorSource = .cpu
    /// At or below this temperature (°C) fans run at their minimum speed.
    var lowTemperature: Double = 55
    /// At or above this temperature (°C) fans run at their maximum speed.
    var highTemperature: Double = 85

    /// Fraction (0…1) of the fan's range the profile asks for at a temperature.
    func speedFraction(at temperature: Double?) -> Double? {
        switch kind {
        case .automatic: return nil
        case .max: return 1
        case .fixed: return min(max(fixedPercent / 100, 0), 1)
        case .curve:
            guard let temperature else { return nil }
            let span = max(highTemperature - lowTemperature, 1)
            return min(max((temperature - lowTemperature) / span, 0), 1)
        }
    }

    func targetRPM(for fan: FanInfo, temperature: Double?) -> Double? {
        speedFraction(at: temperature).map { fan.minimum + (fan.maximum - fan.minimum) * $0 }
    }

    static let defaults: [FanProfile] = [
        FanProfile(name: "Automatic", kind: .automatic),
        FanProfile(name: "Balanced", kind: .curve, source: .hottest, lowTemperature: 60, highTemperature: 90),
        FanProfile(name: "Cool", kind: .curve, source: .hottest, lowTemperature: 45, highTemperature: 75),
        FanProfile(name: "Full Speed", kind: .max),
    ]
}

/// Persists profiles and which one is active in UserDefaults.
@MainActor
@Observable
final class ProfileStore {
    var profiles: [FanProfile] {
        didSet { save() }
    }

    var activeProfileID: UUID? {
        didSet { UserDefaults.standard.set(activeProfileID?.uuidString, forKey: PreferenceKey.activeProfileID) }
    }

    var activeProfile: FanProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: PreferenceKey.profiles),
           let saved = try? JSONDecoder().decode([FanProfile].self, from: data) {
            profiles = saved
        } else {
            // Save right away so the defaults keep stable IDs across launches.
            profiles = FanProfile.defaults
            save()
        }
        activeProfileID = defaults.string(forKey: PreferenceKey.activeProfileID).flatMap(UUID.init)
    }

    @discardableResult
    func add(kind: FanProfile.Kind = .curve) -> FanProfile {
        let profile = FanProfile(name: uniqueName("New Profile"), kind: kind)
        profiles.append(profile)
        return profile
    }

    @discardableResult
    func duplicate(_ profile: FanProfile) -> FanProfile {
        var copy = profile
        copy.id = UUID()
        copy.name = uniqueName("\(profile.name) Copy")
        profiles.insert(copy, at: (profiles.firstIndex(of: profile) ?? profiles.count - 1) + 1)
        return copy
    }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = nil }
    }

    func restoreDefaults() {
        activeProfileID = nil
        profiles = FanProfile.defaults.map { profile in
            var fresh = profile
            fresh.id = UUID()
            return fresh
        }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(profiles.map(\.name))
        guard names.contains(base) else { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !names.contains($0) }!
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: PreferenceKey.profiles)
        }
    }
}
