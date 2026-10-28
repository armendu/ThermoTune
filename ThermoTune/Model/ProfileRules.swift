import AppKit
import IOKit.ps
import Observation

/// "When this is true, use that profile." Rules are checked in order and the
/// first match wins.
struct ProfileRule: Codable, Identifiable, Hashable {
    enum Condition: Codable, Hashable {
        case onBattery
        case onPowerAdapter
        case appRunning(bundleID: String, name: String)
        /// Matches at `limit` (°C) and keeps matching until the reading is
        /// `ProfileRules.temperatureMargin` under it, so it doesn't flap.
        case temperatureAbove(source: SensorSource, limit: Double)

        var title: String {
            switch self {
            case .onBattery: return "On battery"
            case .onPowerAdapter: return "On power adapter"
            case .appRunning(_, let name): return "While \(name) is running"
            case .temperatureAbove(let source, let limit): return "\(source.title) at \(limit.degrees) or more"
            }
        }
    }

    var id = UUID()
    var isEnabled = true
    var condition: Condition
    /// The profile to switch to; `nil` is None, which hands the fans to macOS.
    var profileID: UUID?
}

/// The rules, and which one currently matches.
///
/// Rules act only when the matching rule changes: picking a profile by hand, or
/// the safety net switching one off, holds until the conditions change, instead
/// of being undone on the next refresh.
@MainActor
@Observable
final class ProfileRules {
    static let temperatureMargin: Double = 5

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: PreferenceKey.rulesEnabled)
            matchedRuleID = nil
            hasEvaluated = false
        }
    }
    var rules: [ProfileRule] {
        didSet { save() }
    }
    /// Used when no rule matches; `nil` leaves the profile as it is.
    var fallbackProfileID: UUID? {
        didSet { UserDefaults.standard.set(fallbackProfileID?.uuidString, forKey: PreferenceKey.rulesFallbackProfileID) }
    }
    private(set) var matchedRuleID: UUID?

    @ObservationIgnored private var hasEvaluated = false
    @ObservationIgnored private var hotRules: Set<UUID> = []

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: PreferenceKey.rulesEnabled)
        rules = defaults.data(forKey: PreferenceKey.rules)
            .flatMap { try? JSONDecoder().decode([ProfileRule].self, from: $0) } ?? []
        fallbackProfileID = defaults.string(forKey: PreferenceKey.rulesFallbackProfileID).flatMap(UUID.init)
    }

    enum Decision: Equatable {
        case keep
        /// Switch to this profile; `nil` is None.
        case use(UUID?)
    }

    /// Whether to switch profile now: only when the matching rule has changed
    /// since the last call (or on the first call).
    func decide(temperature: (SensorSource) -> Double?) -> Decision {
        guard isEnabled else { return .keep }
        let match = rules.first { $0.isEnabled && matches($0, temperature: temperature) }
        defer {
            matchedRuleID = match?.id
            hasEvaluated = true
        }
        guard !hasEvaluated || match?.id != matchedRuleID else { return .keep }
        if let match { return .use(match.profileID) }
        return fallbackProfileID.map { .use($0) } ?? .keep
    }

    /// A profile was deleted: rules pointing at it switch to None.
    func profileDeleted(_ id: UUID) {
        for index in rules.indices where rules[index].profileID == id {
            rules[index].profileID = nil
        }
        if fallbackProfileID == id { fallbackProfileID = nil }
    }

    private func matches(_ rule: ProfileRule, temperature: (SensorSource) -> Double?) -> Bool {
        switch rule.condition {
        case .onBattery: return PowerSource.isOnBattery
        case .onPowerAdapter: return !PowerSource.isOnBattery
        case .appRunning(let bundleID, _):
            return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
        case .temperatureAbove(let source, let limit):
            guard let value = temperature(source) else { return hotRules.contains(rule.id) }
            if value >= limit {
                hotRules.insert(rule.id)
            } else if value < limit - Self.temperatureMargin {
                hotRules.remove(rule.id)
            }
            return hotRules.contains(rule.id)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: PreferenceKey.rules)
        }
    }
}

enum PowerSource {
    /// Desktops, which have no battery, always count as on the power adapter.
    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}
