import Foundation

/// One fan's ramp towards what its profile asks for: the temperature the curve
/// last followed, the speed being ramped towards, and where the ramp has got to.
struct FanSmoothing {
    /// A falling temperature has to drop this far before fans slow down, so a
    /// reading wobbling across a curve point doesn't make them hunt.
    static let hysteresis: Double = 3
    /// Fans speed up quickly and slow down gently: a sudden load needs cooling
    /// now, but a fan dropping 1,000 RPM at once is more noticeable than heat.
    static let rampUpRPMPerSecond: Double = 1000
    static let rampDownRPMPerSecond: Double = 150
    /// The longest gap one step covers, so a long one (sleep) doesn't turn into
    /// one large jump.
    static let maximumStep: TimeInterval = 10

    private(set) var temperature: Double
    /// Rounded, like the speeds `step` returns, so the caller can tell when the
    /// ramp has arrived.
    private(set) var goal: Double = 0
    private(set) var rpm: Double
    private(set) var date: Date

    /// Starts from where the fan is now: its manual target, or its current speed
    /// (at least its minimum, since a stopped fan can't be set below it).
    init(fan: FanInfo, temperature: Double, date: Date = .now) {
        self.temperature = temperature
        rpm = fan.isManual ? fan.target : max(fan.actual, fan.minimum)
        self.date = date
    }

    /// Advances the ramp to `now` and returns the speed to ask for, rounded to
    /// a whole RPM, or `nil` when the behaviour sets no speed.
    mutating func step(behavior: FanBehavior, fan: FanInfo, temperature reading: Double,
                       now: Date = .now) -> Double? {
        if reading >= temperature {
            temperature = reading
        } else if temperature - reading > Self.hysteresis {
            temperature = reading + Self.hysteresis
        }
        guard let target = behavior.targetRPM(for: fan, temperature: temperature)?.rounded() else { return nil }
        let elapsed = min(max(now.timeIntervalSince(date), 0), Self.maximumStep)
        if target > rpm {
            rpm = min(target, rpm + Self.rampUpRPMPerSecond * elapsed)
        } else {
            rpm = max(target, rpm - Self.rampDownRPMPerSecond * elapsed)
        }
        goal = target
        date = now
        return rpm.rounded()
    }
}
