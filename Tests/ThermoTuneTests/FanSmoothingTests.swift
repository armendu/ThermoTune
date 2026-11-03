import Foundation
import Testing
@testable import ThermoTune

struct FanSmoothingTests {
    private let fan = FanInfo(id: 0, actual: 0, minimum: 2000, maximum: 6000, target: 0,
                              isManual: false, isControlUnlocked: false)
    /// 0% at 50°, 100% at 90°: 100 RPM per degree.
    private let curve = FanBehavior(kind: .curve, curve: [.init(50, 0), .init(90, 100)])
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func stoppedFanStartsFromItsMinimum() {
        var ramp = FanSmoothing(fan: fan, temperature: 50, date: start)
        #expect(ramp.step(behavior: curve, fan: fan, temperature: 50, now: start) == 2000)
    }

    @Test func speedsUpQuicklyAndArrivesExactly() {
        var ramp = FanSmoothing(fan: fan, temperature: 50, date: start)
        // 90° asks for 6000: 1000 RPM a second from 2000.
        #expect(ramp.step(behavior: curve, fan: fan, temperature: 90, now: start + 1) == 3000)
        #expect(ramp.step(behavior: curve, fan: fan, temperature: 90, now: start + 2) == 4000)
        #expect(ramp.step(behavior: curve, fan: fan, temperature: 90, now: start + 9) == 6000)
        #expect(ramp.goal == 6000)
    }

    @Test func slowsDownGently() {
        var manual = fan
        manual.isManual = true
        manual.target = 6000
        var ramp = FanSmoothing(fan: manual, temperature: 90, date: start)
        // Down to 50° asks for 2000 eventually, at 150 RPM a second.
        #expect(ramp.step(behavior: curve, fan: manual, temperature: 50, now: start + 2) == 5700)
    }

    /// A falling reading has to drop more than 3° before the fans follow it, and
    /// then they follow it from 3° above.
    @Test func hysteresisHoldsSmallDrops() {
        var ramp = FanSmoothing(fan: fan, temperature: 70, date: start)
        _ = ramp.step(behavior: curve, fan: fan, temperature: 70, now: start)
        _ = ramp.step(behavior: curve, fan: fan, temperature: 68, now: start + 1)
        #expect(ramp.temperature == 70)
        _ = ramp.step(behavior: curve, fan: fan, temperature: 60, now: start + 2)
        #expect(ramp.temperature == 63)
    }

    /// The goal is a whole RPM like the speeds returned, so the caller can see
    /// the ramp has arrived: 2000 + 4000 × 0.4 × … isn't always whole.
    @Test func goalIsRounded() {
        var ramp = FanSmoothing(fan: fan, temperature: 50, date: start)
        let fixed = FanBehavior(kind: .fixed, fixedPercent: 33.33)
        let rpm = ramp.step(behavior: fixed, fan: fan, temperature: 50, now: start + 10)
        #expect(rpm == ramp.goal)
        #expect(ramp.goal == (2000 + 4000 * 0.3333).rounded())
    }

    @Test func longGapsAreBounded() {
        var ramp = FanSmoothing(fan: fan, temperature: 50, date: start)
        let fixed = FanBehavior(kind: .fixed, fixedPercent: 100)
        // After a night asleep: one step's worth, not the whole night's.
        var manual = fan
        manual.isManual = true
        manual.target = 6000
        var down = FanSmoothing(fan: manual, temperature: 50, date: start)
        #expect(down.step(behavior: FanBehavior(kind: .fixed, fixedPercent: 0), fan: manual, temperature: 50,
                          now: start + 36_000) == 6000 - 150 * FanSmoothing.maximumStep)
        #expect(ramp.step(behavior: fixed, fan: fan, temperature: 50, now: start - 5) == 2000)
    }

    @Test func automaticSetsNoSpeed() {
        var ramp = FanSmoothing(fan: fan, temperature: 50, date: start)
        #expect(ramp.step(behavior: FanBehavior(kind: .automatic), fan: fan, temperature: 80, now: start) == nil)
    }
}
