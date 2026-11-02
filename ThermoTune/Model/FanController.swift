import Foundation

/// Decides what the safety net and the active profile do with the fans, from
/// one refresh's readings. It calls nothing and holds no references, so the
/// tests can take it through a trip, a profile ending or a helper error;
/// `HardwareMonitor` gathers the input and carries out the decision.
struct FanController {
    /// For the `.max` action: back to the profile once the hottest reading is
    /// this far under the limit.
    static let safetyClearMargin: Double = 10
    /// The limit even with the safety net off, and the highest it can be set to.
    static let backstopTemperature: Double = 105
    static let backstopDelay: TimeInterval = 10

    /// A trip of the safety net, shown in the main window until dismissed.
    struct SafetyTrip: Equatable {
        let date: Date
        let temperature: Double
        let action: SafetyAction
    }

    /// The safety net's settings as they apply. Switched off, it still has a
    /// fixed backstop: nothing should hold a laptop's fans down at a
    /// temperature where it is about to throttle.
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
        /// The hottest reading of every source that has one.
        var temperatures: [SensorSource: Double]
        var profile: FanProfile?
        var safety: Safety
        var now: Date
        /// The helper is installed and current, and this copy may drive fans.
        var helperIsReady = true
        var isRemovingHelper = false
        var isDiscoveringSensors = false
        /// No helper call is running, and none is waiting for the SMC to report
        /// the mode it asked for.
        var isIdle = true
    }

    enum Command: Equatable {
        case autoAll
        case maxAll
        case set(fan: Int, rpm: Double)
    }

    struct Decision: Equatable {
        var commands: [Command] = []
        /// The safety net tripped: show it, and post the alert.
        var trip: SafetyTrip?
        /// Switch the active profile off. The commands say what the fans do instead.
        var endsProfile = false
    }

    /// A Fixed, Curve or Max profile is driving the fans. If it stops other than
    /// by the user taking a fan over (None, deleted, a helper error), the fans go
    /// back to macOS instead of staying at the profile's last speed.
    private(set) var profileHoldsFans = false
    /// The `.max` safety action is holding every fan at full speed.
    private(set) var isOverheating = false
    private(set) var overLimitSince: Date?
    private(set) var smoothing: [Int: FanSmoothing] = [:]
    /// A Max trip's `max-all` failed and the fans are owed a hand-back. The
    /// safety net waits for it: with no delay, it would otherwise trip again
    /// first and retry the failing call on every refresh.
    private var handBackDue = false

    /// One refresh: the safety net first, and the profile only if the safety
    /// net isn't acting, so the profile can't undo it. Even with no readings: a
    /// profile that has lost its sensors must let go of the fans rather than
    /// hold its last speed.
    mutating func refresh(_ input: Input) -> Decision {
        checkSafetyNet(input) ?? Decision(commands: applyProfile(input))
    }

    // MARK: Safety net

    /// Manual speeds and Fixed or Curve profiles stay where they are however hot
    /// the Mac gets. Once the hottest reading has stayed at the limit for the
    /// chosen time while ThermoTune holds the fans, this takes them off it.
    /// Returns `nil` when it isn't acting this refresh.
    private mutating func checkSafetyNet(_ input: Input) -> Decision? {
        // No helper calls can go out during an uninstall. A trip holds as it is
        // meanwhile: clearing it would let the profile slow the fans, however hot
        // the Mac still is.
        if input.isRemovingHelper { return isOverheating ? Decision() : nil }
        let fans = input.fans
        guard input.helperIsReady, !fans.isEmpty, let hottest = input.temperatures[.hottest] else {
            overLimitSince = nil
            isOverheating = false
            return nil
        }
        let safety = input.safety

        if isOverheating {
            if hottest <= safety.limit - Self.safetyClearMargin {
                isOverheating = false
                // A profile carries on from here. Manual speeds aren't put back:
                // with nothing in charge, the fans would stay at full speed for
                // good, so macOS gets them (`applyProfile` lets go).
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
        // Fans already all at full speed can't cool any harder, and handing them
        // back would let macOS slow them down.
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
            // So the profile ramps down from full speed when the trip clears,
            // instead of jumping back to where its ramp was before.
            smoothing = [:]
            return Decision(commands: [.maxAll], trip: trip)
        }
    }

    // MARK: Profiles

    /// Brings the fans in line with the active profile. Runs after every refresh
    /// so curves follow temperature and the profile is re-applied if macOS takes
    /// control back.
    mutating func applyProfile(_ input: Input) -> [Command] {
        let fans = input.fans
        guard input.helperIsReady, !input.isRemovingHelper, !input.isDiscoveringSensors,
              input.isIdle, !fans.isEmpty else { return [] }
        // From here the fans are either handed back or driven by a profile.
        handBackDue = false
        let handBack: [Command] = fans.allSatisfy(\.isSystemControlled) ? [] : [.autoAll]
        guard let profile = input.profile else {
            smoothing = [:]
            guard profileHoldsFans else { return [] }
            profileHoldsFans = false
            isOverheating = false
            return [.autoAll]
        }
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

        // Fixed and curve fans, possibly mixed with Max ones. With no temperature
        // at all, nothing would notice the Mac overheating: macOS gets the fans
        // until there is a reading again.
        guard let hottest = input.temperatures[.hottest] else {
            smoothing = [:]
            return handBack
        }
        var commands: [Command] = []
        for (fan, behavior) in zip(fans, behaviors) {
            // GPU sensors can all drop out while it is powered down, and a chosen
            // sensor can stop reading. Following the hottest reading meanwhile
            // errs towards more cooling, and avoids a ~10 second hand-over to
            // macOS and back each time.
            let temperature = input.temperatures[behavior.source] ?? hottest
            guard let rpm = smoothedRPM(for: fan, behavior: behavior, temperature: temperature, now: input.now) else { continue }
            // Skip small changes so a curve doesn't call the helper every tick,
            // but always land exactly on where the ramp ends.
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

    /// The user is setting the fans themselves, so the profile ends without
    /// handing them back.
    mutating func takeOver() {
        smoothing = [:]
        profileHoldsFans = false
        isOverheating = false
        handBackDue = false
    }

    /// A helper call failed, and the profile is switched off. With
    /// `profileHoldsFans` set, the next refresh hands the fans back to macOS.
    /// That includes a Max safety trip whose `max-all` failed: retrying it every
    /// refresh would only repeat the error.
    mutating func helperFailed() {
        guard isOverheating else { return }
        isOverheating = false
        profileHoldsFans = true
        handBackDue = true
    }
}
