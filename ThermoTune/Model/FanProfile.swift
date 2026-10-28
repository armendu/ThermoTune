import Foundation
import Observation

/// A named fan behaviour: the same for every fan, or set per fan.
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
    /// What every fan does, unless `perFan` has an entry for it.
    var behavior: FanBehavior
    /// Per-fan overrides, keyed by fan index. Empty means every fan follows
    /// `behavior`. Never `.automatic`: see `FanBehavior.perFanKinds`.
    var perFan: [Int: FanBehavior] = [:]

    init(name: String, behavior: FanBehavior) {
        self.name = name
        self.behavior = behavior
    }

    var isPerFan: Bool { !perFan.isEmpty }

    func behavior(forFan index: Int) -> FanBehavior {
        perFan[index] ?? behavior
    }

    var symbol: String { isPerFan ? "square.split.2x1" : behavior.kind.symbol }

    static let defaults: [FanProfile] = [
        FanProfile(name: "Automatic", behavior: FanBehavior(kind: .automatic)),
        FanProfile(name: "Balanced", behavior: FanBehavior(kind: .curve, source: .hottest,
                                                           curve: [.init(60, 0), .init(90, 100)])),
        FanProfile(name: "Cool", behavior: FanBehavior(kind: .curve, source: .hottest,
                                                       curve: [.init(45, 0), .init(75, 100)])),
        FanProfile(name: "Full Speed", behavior: FanBehavior(kind: .max)),
    ]

    // Profiles saved before per-fan settings and multi-point curves kept the
    // behaviour's fields at the top level, with a two-point curve as
    // `lowTemperature`/`highTemperature`. They are read into `behavior`.
    private enum CodingKeys: String, CodingKey {
        case id, name, behavior, perFan
        case kind, fixedPercent, source, lowTemperature, highTemperature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        if let behavior = try container.decodeIfPresent(FanBehavior.self, forKey: .behavior) {
            self.behavior = behavior
        } else {
            let low = try container.decodeIfPresent(Double.self, forKey: .lowTemperature) ?? 55
            let high = try container.decodeIfPresent(Double.self, forKey: .highTemperature) ?? 85
            behavior = FanBehavior(
                kind: try container.decode(Kind.self, forKey: .kind),
                fixedPercent: try container.decodeIfPresent(Double.self, forKey: .fixedPercent) ?? 50,
                source: try container.decodeIfPresent(SensorSource.self, forKey: .source) ?? .cpu,
                curve: [.init(low, 0), .init(max(high, low + 1), 100)]
            )
        }
        // JSON object keys are strings, so the fan index is stored as one.
        let perFan = try container.decodeIfPresent([String: FanBehavior].self, forKey: .perFan) ?? [:]
        self.perFan = Dictionary(uniqueKeysWithValues: perFan.compactMap { key, value in
            Int(key).map { ($0, value) }
        })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(behavior, forKey: .behavior)
        if !perFan.isEmpty {
            try container.encode(Dictionary(uniqueKeysWithValues: perFan.map { (String($0.key), $0.value) }),
                                 forKey: .perFan)
        }
    }
}

/// A point on a temperature curve: at `temperature` (°C) the fan runs at
/// `percent` of its range between minimum and maximum speed.
struct CurvePoint: Codable, Hashable {
    var temperature: Double
    var percent: Double

    init(_ temperature: Double, _ percent: Double) {
        self.temperature = temperature
        self.percent = percent
    }
}

/// What one fan, or every fan, does under a profile.
struct FanBehavior: Codable, Hashable {
    var kind: FanProfile.Kind
    /// Fixed speed as a percentage of the fan's min…max range.
    var fixedPercent: Double = 50
    var source: SensorSource = .cpu
    /// Sorted by temperature, at least two points. Below the first point the fan
    /// runs at the first point's speed, above the last at the last point's.
    var curve: [CurvePoint] = FanBehavior.newCurve

    static let newCurve: [CurvePoint] = [.init(50, 0), .init(70, 40), .init(90, 100)]

    /// Kinds a single fan can have when fans differ. Automatic isn't one: on
    /// Apple silicon, one manual fan suspends thermal control for all of them,
    /// so a fan left "automatic" would just be held at its minimum.
    static let perFanKinds: [FanProfile.Kind] = [.fixed, .curve, .max]

    /// Fraction (0…1) of the fan's range asked for at a temperature.
    func speedFraction(at temperature: Double?) -> Double? {
        switch kind {
        case .automatic: return nil
        case .max: return 1
        case .fixed: return min(max(fixedPercent / 100, 0), 1)
        case .curve:
            guard let temperature, let first = curve.first, let last = curve.last else { return nil }
            let percent: Double
            if temperature <= first.temperature {
                percent = first.percent
            } else if temperature >= last.temperature {
                percent = last.percent
            } else {
                let upper = curve.firstIndex { $0.temperature >= temperature }!
                let a = curve[upper - 1], b = curve[upper]
                let t = (temperature - a.temperature) / max(b.temperature - a.temperature, 0.001)
                percent = a.percent + (b.percent - a.percent) * t
            }
            return min(max(percent / 100, 0), 1)
        }
    }

    func targetRPM(for fan: FanInfo, temperature: Double?) -> Double? {
        speedFraction(at: temperature).map { fan.minimum + (fan.maximum - fan.minimum) * $0 }
    }
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
        let profile = FanProfile(name: uniqueName("New Profile"), behavior: FanBehavior(kind: kind))
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

    /// Adds profiles from an exported file. They get new IDs, so importing the
    /// same file twice, or one exported from this Mac, never replaces a profile.
    @discardableResult
    func importProfiles(_ imported: [FanProfile]) -> [FanProfile] {
        let added = imported.map { profile in
            var copy = profile
            copy.id = UUID()
            copy.name = uniqueName(profile.name)
            profiles.append(copy)
            return copy
        }
        return added
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

/// The file format for exported profiles. `version` is bumped whenever a field
/// changes meaning, so a later ThermoTune can still read an older file.
struct ProfileArchive: Codable {
    /// 2: per-fan settings and multi-point curves. Version 1 files still import.
    static let currentVersion = 2

    var app = AppInfo.name
    var version = Self.currentVersion
    var profiles: [FanProfile]
}
