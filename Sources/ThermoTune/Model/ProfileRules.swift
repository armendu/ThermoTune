import AppKit
import IOKit.ps
import Observation

/// "When this is true, use that profile." The first match wins.
struct ProfileRule: Codable, Identifiable, Hashable {
    enum Condition: Codable, Hashable {
        case onBattery
        case onPowerAdapter
        case appRunning(bundleID: String, name: String)
        /// Keeps matching until `ProfileRules.temperatureMargin` under `limit` (°C).
        case temperatureAbove(source: SensorSource, limit: Double)

        var title: String {
            switch self {
            case .onBattery: return String(localized: "On battery")
            case .onPowerAdapter: return String(localized: "On power adapter")
            case .appRunning(_, let name): return String(localized: "While \(name) is running")
            case .temperatureAbove(let source, let limit): return String(localized: "\(source.title) at \(limit.degrees) or more")
            }
        }
    }

    var id = UUID()
    var isEnabled = true
    var condition: Condition
    /// `nil` is None, which hands the fans to macOS.
    var profileID: UUID?
}

/// Rules act only when the matching rule changes, so a profile picked by hand,
/// or switched off by the safety net, isn't undone on the next refresh.
@MainActor
@Observable
final class ProfileRules {
    static let temperatureMargin: Double = 5

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: PreferenceKey.rulesEnabled)
            matchedRuleID = nil
            hasEvaluated = false
        }
    }
    var rules: [ProfileRule] {
        didSet { save() }
    }
    /// When no rule matches; `nil` leaves the profile as it is.
    var fallbackProfileID: UUID? {
        didSet { defaults.set(fallbackProfileID?.uuidString, forKey: PreferenceKey.rulesFallbackProfileID) }
    }
    private(set) var matchedRuleID: UUID?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var hasEvaluated = false
    @ObservationIgnored private var hotRules: Set<UUID> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: PreferenceKey.rulesEnabled)
        rules = defaults.lenientArray(of: ProfileRule.self, forKey: PreferenceKey.rules) ?? []
        fallbackProfileID = defaults.string(forKey: PreferenceKey.rulesFallbackProfileID).flatMap(UUID.init)
    }

    enum Decision: Equatable {
        case keep
        case use(UUID?)
    }

    func decide(temperature: (SensorSource) -> Double?) -> Decision {
        guard isEnabled else { return .keep }
        // Every rule is checked, so later temperature rules keep their hysteresis
        // while an earlier one wins.
        let state = SystemState()
        let match = rules.filter { $0.isEnabled && matches($0, state: state, temperature: temperature) }.first
        defer {
            matchedRuleID = match?.id
            hasEvaluated = true
        }
        guard !hasEvaluated || match?.id != matchedRuleID else { return .keep }
        if let match { return .use(match.profileID) }
        return fallbackProfileID.map { .use($0) } ?? .keep
    }

    func profileDeleted(_ id: UUID) {
        for index in rules.indices where rules[index].profileID == id {
            rules[index].profileID = nil
        }
        if fallbackProfileID == id { fallbackProfileID = nil }
    }

    private func matches(_ rule: ProfileRule, state: SystemState, temperature: (SensorSource) -> Double?) -> Bool {
        switch rule.condition {
        case .onBattery: return state.isOnBattery
        case .onPowerAdapter: return !state.isOnBattery
        case .appRunning(let bundleID, _): return state.runningApps.contains(bundleID)
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
            defaults.set(data, forKey: PreferenceKey.rules)
        }
    }

    private final class SystemState {
        lazy var isOnBattery = PowerSource.isOnBattery
        lazy var runningApps = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

enum PowerSource {
    /// Desktops have no battery, so they always count as on the power adapter.
    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}
