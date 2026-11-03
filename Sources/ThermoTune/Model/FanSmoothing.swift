import Foundation

/// One fan's ramp towards what its profile asks for.
struct FanSmoothing {
    /// A falling reading must drop this far before fans slow, so they don't hunt.
    static let hysteresis: Double = 3
    /// Up quickly for a sudden load, down gently, since a sudden drop is noticeable.
    static let rampUpRPMPerSecond: Double = 1000
    static let rampDownRPMPerSecond: Double = 150
    /// So a long gap (sleep) isn't one large jump.
    static let maximumStep: TimeInterval = 10

    private(set) var temperature: Double
    /// Rounded like `step`'s speeds, so the caller can tell the ramp has arrived.
    private(set) var goal: Double = 0
    private(set) var rpm: Double
    private(set) var date: Date

    /// From the manual target, or the current speed but at least the minimum.
    init(fan: FanInfo, temperature: Double, date: Date = .now) {
        self.temperature = temperature
        rpm = fan.isManual ? fan.target : max(fan.actual, fan.minimum)
        self.date = date
    }

    /// The speed to ask for now, or `nil` when the behaviour sets none.
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
