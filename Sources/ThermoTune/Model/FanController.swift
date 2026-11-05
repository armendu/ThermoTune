import Foundation

/// What the safety net and the active profile do with the fans, decided from one
/// refresh's readings. Pure, so it can be tested; `HardwareMonitor` acts on it.
struct FanController {
    /// A Max trip ends once the hottest reading is this far under the limit.
    static let safetyClearMargin: Double = 10
    /// The limit with the safety net off, and the highest it can be set to.
    static let backstopTemperature: Double = 105
    static let backstopDelay: TimeInterval = 10
    /// Longer than any unlock takes to hand over: the helper waits up to 20 s for one.
    static let strandedDelay: TimeInterval = 25

    struct SafetyTrip: Equatable {
        let date: Date
        let temperature: Double
        let action: SafetyAction
    }

    /// Switched off, the safety net still applies the backstop.
    struct Safety: Equatable {
        let limit: Double
        let delay: TimeInterval
        let action: SafetyAction

        init(isEnabled: Bool, limit: Double, delay: TimeInterval, action: SafetyAction) {
            self.limit = isEnabled ? min(limit, FanController.backstopTemperature) : FanController.backstopTemperature
            self.delay = isEnabled ? delay : FanController.backstopDelay
            self.action = isEnabled ? action : .automatic
        }

        init(_ defaults: UserDefaults) {
            self.init(isEnabled: defaults.bool(forKey: PreferenceKey.safetyNetEnabled),
                      limit: defaults.double(forKey: PreferenceKey.safetyLimit),
                      delay: defaults.double(forKey: PreferenceKey.safetyDelay),
                      action: defaults.string(forKey: PreferenceKey.safetyAction).flatMap(SafetyAction.init) ?? .automatic)
        }
    }

    struct Input {
        var fans: [FanInfo]
        var temperatures: [SensorSource: Double]
        var profile: FanProfile?
        var safety: Safety
        var now: Date
        var helperIsReady = true
        var isRemovingHelper = false
        var isDiscoveringSensors = false
        /// No helper call running, and no requested mode still waiting to read back.
        var isIdle = true
    }

    enum Command: Equatable {
        case autoAll
        case maxAll
        case set(fan: Int, rpm: Double)
    }

    struct Decision: Equatable {
        var commands: [Command] = []
        var trip: SafetyTrip?
        var endsProfile = false
    }

    /// Set while a profile drives the fans. Set with no profile, it makes the next
    /// refresh hand them back: whenever ThermoTune stops driving them, macOS gets them.
    private(set) var profileHoldsFans = false
    /// A Max trip is holding every fan at full speed.
    private(set) var isOverheating = false
    private(set) var overLimitSince: Date?
    private(set) var smoothing: [Int: FanSmoothing] = [:]
    /// A failed Max trip still owes a hand-back. Without it, a zero-delay safety
    /// net would trip again first and retry the failing call every refresh.
    private var handBackDue = false
    /// When `Ftst` was first seen on with no fan manual.
    private var strandedSince: Date?

    /// The safety net runs first so the profile can't undo it, and runs even with
    /// no readings, so a profile that lost its sensors lets go of the fans.
    mutating func refresh(_ input: Input) -> Decision {
        checkSafetyNet(input) ?? Decision(commands: applyProfile(input))
    }

    // MARK: Safety net

    /// `nil` when the safety net isn't acting this refresh.
    private mutating func checkSafetyNet(_ input: Input) -> Decision? {
        // Nothing can be sent during an uninstall; clearing a trip then would let
        // the profile slow the fans afterwards, however hot the Mac still is.
        if input.isRemovingHelper { return isOverheating ? Decision() : nil }
        let fans = input.fans
        guard input.helperIsReady, !fans.isEmpty, let hottest = input.temperatures[.hottest] else {
            overLimitSince = nil
            // Nothing can tell a Max trip it has cooled down, so it ends as if it had.
            if isOverheating, input.profile == nil { profileHoldsFans = true }
            isOverheating = false
            return nil
        }
        let safety = input.safety

        if isOverheating {
            if hottest <= safety.limit - Self.safetyClearMargin {
                isOverheating = false
                // A profile carries on. Manual speeds aren't restored: macOS gets the fans.
                if input.profile == nil { profileHoldsFans = true }
                return nil
            }
            if input.isIdle, fans.contains(where: { $0.mode != .max }) { return Decision(commands: [.maxAll]) }
            return Decision()
        }

        let holdsFans = profileHoldsFans || !fans.allSatisfy(\.isSystemControlled)
        guard hottest >= safety.limit, holdsFans, !handBackDue else {
            overLimitSince = nil
            return nil
        }
        let since = overLimitSince ?? input.now
        overLimitSince = since
        // Fans all at full speed can't cool harder, and handing them back would let them slow.
        guard input.now.timeIntervalSince(since) >= safety.delay, input.isIdle,
              fans.contains(where: { $0.mode != .max }) else { return nil }

        overLimitSince = nil
        let trip = SafetyTrip(date: input.now, temperature: hottest, action: safety.action)
        switch safety.action {
        case .automatic:
            takeOver()
            return Decision(commands: [.autoAll], trip: trip, endsProfile: true)
        case .max:
            isOverheating = true
            // The profile ramps down from full speed afterwards, not from its old ramp.
            smoothing = [:]
            return Decision(commands: [.maxAll], trip: trip)
        }
    }

    // MARK: Profiles

    mutating func applyProfile(_ input: Input) -> [Command] {
        let fans = input.fans
        guard input.helperIsReady, !input.isRemovingHelper, !input.isDiscoveringSensors,
              input.isIdle, !fans.isEmpty else { return [] }
        handBackDue = false
        let handBack: [Command] = fans.allSatisfy(\.isSystemControlled) ? [] : [.autoAll]
        guard let profile = input.profile else {
            smoothing = [:]
            // `Ftst` on with no fan manual is a fan nobody manages. Two quick per-fan Auto
            // switches leave it: the second reads the first fan's mode before its write lands.
            // Every unlock starts that way too, another app's included, and a hand-back reads
            // that way until its last write lands, so it has to last first.
            let isStranded = !fans.contains(where: \.isManual) && fans.contains(where: \.isControlUnlocked)
            strandedSince = isStranded ? strandedSince ?? input.now : nil
            let strandedTooLong = strandedSince.map { input.now.timeIntervalSince($0) >= Self.strandedDelay } ?? false
            guard profileHoldsFans || strandedTooLong else { return [] }
            profileHoldsFans = false
            isOverheating = false
            strandedSince = nil
            return [.autoAll]
        }
        strandedSince = nil
        let behaviors = fans.map { profile.behavior(forFan: $0.id) }
        profileHoldsFans = behaviors.contains { $0.kind != .automatic }

        if !profileHoldsFans {
            smoothing = [:]
            return handBack
        }
        if behaviors.allSatisfy({ $0.kind == .max }) {
            smoothing = [:]
            return fans.contains(where: { $0.mode != .max }) ? [.maxAll] : []
        }

        // With no temperature at all nothing would notice overheating, so macOS gets the fans.
        guard let hottest = input.temperatures[.hottest] else {
            smoothing = [:]
            return handBack
        }
        var commands: [Command] = []
        for (fan, behavior) in zip(fans, behaviors) {
            // A source that stops reading (a powered-down GPU) follows the hottest
            // reading: more cooling, and no ~10 s hand-over to macOS and back.
            let temperature = input.temperatures[behavior.source] ?? hottest
            guard let rpm = smoothedRPM(for: fan, behavior: behavior, temperature: temperature, now: input.now) else { continue }
            // Small changes are skipped, except the ramp's last step.
            if !fan.isManual || abs(fan.target - rpm) >= 100
                || (rpm == smoothing[fan.id]?.goal && abs(fan.target - rpm) >= 1) {
                commands.append(.set(fan: fan.id, rpm: rpm))
            }
        }
        return commands
    }

    private mutating func smoothedRPM(for fan: FanInfo, behavior: FanBehavior, temperature: Double, now: Date) -> Double? {
        var state = smoothing[fan.id] ?? FanSmoothing(fan: fan, temperature: temperature, date: now)
        let rpm = state.step(behavior: behavior, fan: fan, temperature: temperature, now: now)
        smoothing[fan.id] = rpm == nil ? nil : state
        return rpm
    }

    // MARK: Events

    /// The user sets the fans themselves: the profile ends without handing them back.
    mutating func takeOver() {
        smoothing = [:]
        profileHoldsFans = false
        isOverheating = false
        handBackDue = false
        strandedSince = nil
    }

    /// A failed Max trip hands the fans back on the next refresh rather than retrying.
    mutating func helperFailed() {
        guard isOverheating else { return }
        isOverheating = false
        profileHoldsFans = true
        handBackDue = true
    }
}
