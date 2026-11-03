import Foundation
import Testing
@testable import ThermoTune

struct FanControllerTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    /// Limit 90°, 10 seconds, hand the fans back.
    private let handBack = FanController.Safety(isEnabled: true, limit: 90, delay: 10, action: .automatic)
    /// Limit 90°, 10 seconds, full speed.
    private let fullSpeed = FanController.Safety(isEnabled: true, limit: 90, delay: 10, action: .max)
    /// 0% at 50°, 100% at 90°: 100 RPM per degree between 2000 and 6000.
    private let curve = FanBehavior(kind: .curve, source: .hottest, curve: [.init(50, 0), .init(90, 100)])

    private enum State { case auto, manual(Double), max }

    /// Two fans, 2000–6000 RPM.
    private func fans(_ state: State) -> [FanInfo] {
        (0..<2).map { id in
            switch state {
            case .auto:
                return FanInfo(id: id, actual: 0, minimum: 2000, maximum: 6000, target: 0,
                               isManual: false, isControlUnlocked: false)
            case .manual(let rpm):
                return FanInfo(id: id, actual: rpm, minimum: 2000, maximum: 6000, target: rpm,
                               isManual: true, isControlUnlocked: true)
            case .max:
                return FanInfo(id: id, actual: 6000, minimum: 2000, maximum: 6000, target: 6000,
                               isManual: true, isControlUnlocked: true)
            }
        }
    }

    private func input(_ fans: [FanInfo], hottest: Double?, profile: FanProfile? = nil,
                       safety: FanController.Safety? = nil, at seconds: TimeInterval = 0) -> FanController.Input {
        FanController.Input(fans: fans, temperatures: hottest.map { [.hottest: $0] } ?? [:], profile: profile,
                            safety: safety ?? handBack, now: start + seconds)
    }

    private func profile(_ behavior: FanBehavior) -> FanProfile {
        FanProfile(name: "Test", behavior: behavior)
    }

    // MARK: Safety net

    @Test func tripsOnceTheReadingHasStayedAtTheLimitForTheDelay() {
        var controller = FanController()
        let manual = fans(.manual(3000))
        #expect(controller.refresh(input(manual, hottest: 90, at: 0)) == .init())
        #expect(controller.refresh(input(manual, hottest: 92, at: 9)) == .init())
        let decision = controller.refresh(input(manual, hottest: 93, at: 10))
        #expect(decision.commands == [.autoAll])
        #expect(decision.trip == .init(date: start + 10, temperature: 93, action: .automatic))
        #expect(decision.endsProfile)
    }

    @Test func dippingUnderTheLimitRestartsTheDelay() {
        var controller = FanController()
        let manual = fans(.manual(3000))
        _ = controller.refresh(input(manual, hottest: 95, at: 0))
        _ = controller.refresh(input(manual, hottest: 89, at: 5))
        #expect(controller.refresh(input(manual, hottest: 95, at: 10)) == .init())
        #expect(controller.refresh(input(manual, hottest: 95, at: 20)).commands == [.autoAll])
    }

    @Test func leavesFansMacOSIsAlreadyRunningAlone() {
        var controller = FanController()
        _ = controller.refresh(input(fans(.auto), hottest: 100, at: 0))
        #expect(controller.refresh(input(fans(.auto), hottest: 100, at: 60)) == .init())
    }

    /// Fans at full speed can't cool any harder, and handing them back would let
    /// macOS slow them down.
    @Test func neverTripsWhenEveryFanIsAlreadyAtMax() {
        var controller = FanController()
        _ = controller.refresh(input(fans(.max), hottest: 100, at: 0))
        #expect(controller.refresh(input(fans(.max), hottest: 100, at: 60)) == .init())
    }

    @Test func waitsForHelperCallsInFlight() {
        var controller = FanController()
        var busy = input(fans(.manual(3000)), hottest: 95, at: 0)
        busy.isIdle = false
        _ = controller.refresh(busy)
        busy.now = start + 30
        #expect(controller.refresh(busy) == .init())
        #expect(controller.refresh(input(fans(.manual(3000)), hottest: 95, at: 31)).commands == [.autoAll])
    }

    @Test func maxHoldsUntilTenDegreesUnderTheLimitThenTheProfileCarriesOn() {
        var controller = FanController()
        let balanced = profile(curve)
        // The curve is running the fans at 70°'s 4000 RPM.
        _ = controller.refresh(input(fans(.auto), hottest: 70, profile: balanced, safety: fullSpeed, at: 0))
        #expect(controller.profileHoldsFans)

        _ = controller.refresh(input(fans(.manual(4000)), hottest: 95, profile: balanced, safety: fullSpeed, at: 1))
        let trip = controller.refresh(input(fans(.manual(4000)), hottest: 95, profile: balanced, safety: fullSpeed, at: 11))
        #expect(trip.commands == [.maxAll])
        #expect(trip.trip?.action == .max)
        #expect(!trip.endsProfile)
        #expect(controller.isOverheating)

        // Still hot: nothing more to send, and the curve doesn't get a say.
        #expect(controller.refresh(input(fans(.max), hottest: 85, profile: balanced, safety: fullSpeed, at: 12)) == .init())
        // macOS took a fan back meanwhile: full speed again.
        #expect(controller.refresh(input(fans(.manual(4000)), hottest: 85, profile: balanced, safety: fullSpeed, at: 13))
                .commands == [.maxAll])

        // 80° is 10 under: the curve takes over again, ramping down from full speed.
        let after = controller.refresh(input(fans(.max), hottest: 80, profile: balanced, safety: fullSpeed, at: 14))
        #expect(!controller.isOverheating)
        #expect(after.trip == nil)
        // The ramp starts from full speed, where the fans already are.
        #expect(after.commands.isEmpty)
        let ramp = controller.refresh(input(fans(.max), hottest: 80, profile: balanced, safety: fullSpeed, at: 20))
        #expect(ramp.commands == [.set(fan: 0, rpm: 5100), .set(fan: 1, rpm: 5100)])
    }

    /// Manual speeds aren't put back after a full-speed trip: with nothing in
    /// charge, the fans would stay at full speed for good.
    @Test func maxTripOnManualSpeedsEndsByHandingTheFansBack() {
        var controller = FanController()
        _ = controller.refresh(input(fans(.manual(3000)), hottest: 95, safety: fullSpeed, at: 0))
        #expect(controller.refresh(input(fans(.manual(3000)), hottest: 95, safety: fullSpeed, at: 10)).commands == [.maxAll])
        #expect(controller.refresh(input(fans(.max), hottest: 85, safety: fullSpeed, at: 11)) == .init())
        #expect(controller.refresh(input(fans(.max), hottest: 80, safety: fullSpeed, at: 12)).commands == [.autoAll])
        #expect(controller.refresh(input(fans(.auto), hottest: 60, safety: fullSpeed, at: 13)) == .init())
        #expect(!controller.profileHoldsFans)
    }

    @Test func helperErrorDuringAMaxTripEndsItInsteadOfRetrying() {
        var controller = FanController()
        let balanced = profile(curve)
        _ = controller.refresh(input(fans(.manual(4000)), hottest: 95, profile: balanced, safety: fullSpeed, at: 0))
        #expect(controller.refresh(input(fans(.manual(4000)), hottest: 95, profile: balanced, safety: fullSpeed, at: 10))
                .commands == [.maxAll])

        // `max-all` failed; the monitor switches the profile off.
        controller.helperFailed()
        #expect(!controller.isOverheating)
        #expect(controller.refresh(input(fans(.manual(4000)), hottest: 95, safety: fullSpeed, at: 11)).commands == [.autoAll])
        #expect(controller.refresh(input(fans(.auto), hottest: 95, safety: fullSpeed, at: 30)) == .init())
    }

    /// With no delay, the next refresh used to trip again before the hand-back
    /// went out, retrying the failed `max-all` and alerting on every refresh.
    @Test func helperErrorDuringAMaxTripWithNoDelayHandsBackOnce() {
        var controller = FanController()
        let noDelay = FanController.Safety(isEnabled: true, limit: 90, delay: 0, action: .max)
        #expect(controller.refresh(input(fans(.manual(3000)), hottest: 95, safety: noDelay, at: 0)).commands == [.maxAll])

        controller.helperFailed()
        #expect(controller.refresh(input(fans(.manual(3000)), hottest: 95, safety: noDelay, at: 1)) == .init(commands: [.autoAll]))
        #expect(controller.refresh(input(fans(.auto), hottest: 95, safety: noDelay, at: 2)) == .init())
    }

    @Test func helperErrorOutsideATripLeavesNothingToHandBack() {
        var controller = FanController()
        controller.helperFailed()
        #expect(!controller.profileHoldsFans)
        #expect(controller.refresh(input(fans(.manual(3000)), hottest: 60, at: 0)) == .init())
    }

    /// Switched off, the safety net still hands the fans back at 105°.
    @Test func backstopActsWithTheSafetyNetOff() {
        let off = FanController.Safety(isEnabled: false, limit: 80, delay: 0, action: .max)
        #expect(off == FanController.Safety(isEnabled: true, limit: 105, delay: 10, action: .automatic))

        var controller = FanController()
        _ = controller.refresh(input(fans(.manual(3000)), hottest: 104, safety: off, at: 0))
        #expect(controller.refresh(input(fans(.manual(3000)), hottest: 104, safety: off, at: 60)) == .init())
        _ = controller.refresh(input(fans(.manual(3000)), hottest: 105, safety: off, at: 61))
        let decision = controller.refresh(input(fans(.manual(3000)), hottest: 105, safety: off, at: 71))
        #expect(decision.commands == [.autoAll])
        #expect(decision.trip?.action == .automatic)
    }

    @Test func limitIsNeverAboveTheBackstop() {
        let safety = FanController.Safety(isEnabled: true, limit: 120, delay: 5, action: .max)
        #expect(safety.limit == FanController.backstopTemperature)
        #expect(safety.delay == 5)
    }

    /// No helper calls go out during an uninstall, and a trip holds rather than
    /// letting the profile slow the fans.
    @Test func tripHoldsWhileTheHelperIsRemoved() {
        var controller = FanController()
        let balanced = profile(curve)
        _ = controller.refresh(input(fans(.manual(4000)), hottest: 95, profile: balanced, safety: fullSpeed, at: 0))
        _ = controller.refresh(input(fans(.manual(4000)), hottest: 95, profile: balanced, safety: fullSpeed, at: 10))
        var removing = input(fans(.manual(4000)), hottest: 60, profile: balanced, safety: fullSpeed, at: 11)
        removing.isRemovingHelper = true
        #expect(controller.refresh(removing) == .init())
        #expect(controller.isOverheating)
    }

    // MARK: Profiles

    /// With no temperature at all nothing would notice the Mac overheating.
    @Test func fixedAndCurveProfilesHandBackWithNoTemperature() {
        for behavior in [FanBehavior(kind: .fixed, fixedPercent: 50), curve] {
            var controller = FanController()
            let running = profile(behavior)
            #expect(controller.refresh(input(fans(.manual(4000)), hottest: nil, profile: running)).commands == [.autoAll])
            #expect(controller.refresh(input(fans(.auto), hottest: nil, profile: running, at: 1)) == .init())
            // A reading again: the profile takes the fans back.
            #expect(controller.refresh(input(fans(.auto), hottest: 70, profile: running, at: 2)).commands.count == 2)
        }
    }

    @Test func maxProfileDoesNotNeedATemperature() {
        var controller = FanController()
        let full = profile(FanBehavior(kind: .max))
        #expect(controller.refresh(input(fans(.auto), hottest: nil, profile: full)).commands == [.maxAll])
        #expect(controller.refresh(input(fans(.max), hottest: nil, profile: full, at: 1)) == .init())
    }

    @Test func automaticProfileHandsBackWhatWasSetByHand() {
        var controller = FanController()
        let automatic = profile(FanBehavior(kind: .automatic))
        #expect(controller.refresh(input(fans(.manual(3000)), hottest: 60, profile: automatic)).commands == [.autoAll])
        #expect(!controller.profileHoldsFans)
    }

    @Test func perFanProfilesMixMaxWithCurves() {
        var mixed = profile(FanBehavior(kind: .fixed))
        mixed.perFan = [0: FanBehavior(kind: .max), 1: curve]
        var controller = FanController()
        // Both start from their minimum, the stopped fans' speed, and ramp from there.
        let first = controller.refresh(input(fans(.auto), hottest: 70, profile: mixed, at: 0))
        #expect(first.commands == [.set(fan: 0, rpm: 2000), .set(fan: 1, rpm: 2000)])
        let later = controller.refresh(input(fans(.manual(2000)), hottest: 70, profile: mixed, at: 10))
        #expect(later.commands == [.set(fan: 0, rpm: 6000), .set(fan: 1, rpm: 4000)])
    }

    @Test func perFanSourceFallsBackToTheHottestReading() {
        var split = profile(FanBehavior(kind: .fixed))
        split.perFan = [0: FanBehavior(kind: .curve, source: .gpu, curve: curve.curve), 1: curve]
        var controller = FanController()
        var readings = input(fans(.manual(2000)), hottest: 80, profile: split)
        readings.temperatures[.gpu] = 60
        _ = controller.refresh(readings)
        readings.now = start + 10
        #expect(controller.refresh(readings).commands == [.set(fan: 0, rpm: 3000), .set(fan: 1, rpm: 5000)])

        // The GPU stops reading: fan 0 follows the hottest reading meanwhile.
        readings.temperatures[.gpu] = nil
        readings.fans = [fans(.manual(3000))[0], fans(.manual(5000))[1]]
        readings.now = start + 20
        #expect(controller.refresh(readings).commands == [.set(fan: 0, rpm: 5000)])
    }

    @Test func smallCurveChangesAreSkippedButTheRampLandsExactly() {
        var controller = FanController()
        let balanced = profile(curve)
        _ = controller.refresh(input(fans(.manual(4000)), hottest: 70, profile: balanced, at: 0))
        // 70.5° asks for 4050: under 100 RPM away, but where the ramp ends.
        #expect(controller.refresh(input(fans(.manual(4000)), hottest: 70.5, profile: balanced, at: 1)).commands
                == [.set(fan: 0, rpm: 4050), .set(fan: 1, rpm: 4050)])
        #expect(controller.refresh(input(fans(.manual(4050)), hottest: 70.5, profile: balanced, at: 2)) == .init())
    }

    /// None, or the active profile deleted, look the same here: no profile.
    @Test func profileEndingHandsTheFansBackExactlyOnce() {
        var controller = FanController()
        let balanced = profile(curve)
        _ = controller.refresh(input(fans(.auto), hottest: 70, profile: balanced, at: 0))
        #expect(controller.refresh(input(fans(.manual(4000)), hottest: 70, at: 1)).commands == [.autoAll])
        // The write hasn't landed yet: the fans still read manual.
        #expect(controller.refresh(input(fans(.manual(4000)), hottest: 70, at: 2)) == .init())
        #expect(controller.refresh(input(fans(.auto), hottest: 70, at: 3)) == .init())
    }

    @Test func takingAFanOverEndsTheProfileWithoutHandingBack() {
        var controller = FanController()
        _ = controller.refresh(input(fans(.auto), hottest: 70, profile: profile(curve), at: 0))
        controller.takeOver()
        #expect(controller.refresh(input(fans(.manual(3000)), hottest: 70, at: 1)) == .init())
        #expect(controller.smoothing.isEmpty)
    }

    @Test func profileWaitsForHelperCallsAndSensorDiscovery() {
        var controller = FanController()
        var readings = input(fans(.auto), hottest: 70, profile: profile(curve))
        readings.isIdle = false
        #expect(controller.applyProfile(readings) == [])
        readings.isIdle = true
        readings.isDiscoveringSensors = true
        #expect(controller.applyProfile(readings) == [])
        readings.isDiscoveringSensors = false
        readings.helperIsReady = false
        #expect(controller.applyProfile(readings) == [])
        #expect(!controller.profileHoldsFans)
    }
}
