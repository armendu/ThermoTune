import Foundation
import Testing
@testable import ThermoTune

/// `SMC.decode` and `SMC.encode` for every type the app reads or writes. Byte
/// order differs by type, and a wrong conversion compiles and runs: these are
/// the cheapest place to catch either.
struct SMCCodecTests {
    @Test func floatIsLittleEndian() {
        let bits = Float(72.5).bitPattern
        let bytes = [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)]
        #expect(SMC.decode(bytes, type: "flt ") == 72.5)
        #expect(SMC.encode(72.5, type: "flt ", size: 4) == bytes)
    }

    @Test func sp78IsSignedBigEndian() {
        #expect(SMC.decode([0x48, 0x80], type: "sp78") == 72.5)
        #expect(SMC.decode([0xFF, 0x00], type: "sp78") == -1)
    }

    @Test func fpe2IsBigEndianQuarters() {
        #expect(SMC.decode([0x24, 0x34], type: "fpe2") == 2317)
        #expect(SMC.encode(2317, type: "fpe2", size: 2) == [0x24, 0x34])
    }

    @Test func fp88IsBigEndian() {
        #expect(SMC.decode([0x01, 0x80], type: "fp88") == 1.5)
    }

    /// `#KEY` on the development machine. `.map(Double.init)` once decoded this
    /// as 1.2e-320, through `Double(bitPattern:)`, and key enumeration found nothing.
    @Test func integersAreValuesNotBitPatterns() {
        #expect(SMC.decode([0x00, 0x00, 0x09, 0x76], type: "ui32") == 2422)
        #expect(SMC.decode([0x01, 0x02], type: "ui16") == 258)
        #expect(SMC.decode([0x03], type: "ui8 ") == 3)
        #expect(SMC.decode([0x01], type: "flag") == 1)
    }

    @Test func integerEncodingIsBigEndianAndClamped() {
        #expect(SMC.encode(2422, type: "ui32", size: 4) == [0x00, 0x00, 0x09, 0x76])
        #expect(SMC.encode(258, type: "ui16", size: 2) == [0x01, 0x02])
        #expect(SMC.encode(300, type: "ui8 ", size: 1) == [0xFF])
    }

    @Test func shortBuffersAndUnknownTypesDecodeToNil() {
        #expect(SMC.decode([0x01], type: "sp78") == nil)
        #expect(SMC.decode([0x00, 0x00, 0x00], type: "flt ") == nil)
        #expect(SMC.decode([0x00, 0x00], type: "ioft") == nil)
    }

    @Test func encodingRefusesWhatCantBeWritten() {
        #expect(SMC.encode(-1, type: "ui8 ", size: 1) == nil)
        #expect(SMC.encode(.nan, type: "flt ", size: 4) == nil)
        #expect(SMC.encode(.infinity, type: "fpe2", size: 2) == nil)
        // The key's own size wins: a mismatch is not written at all.
        #expect(SMC.encode(1, type: "ui16", size: 4) == nil)
        #expect(SMC.encode(1, type: "sp78", size: 2) == nil)
    }
}

struct FanInfoTests {
    private func fan(target: Double, manual: Bool, unlocked: Bool = false) -> FanInfo {
        FanInfo(id: 0, actual: 3000, minimum: 2317, maximum: 6800, target: target,
                isManual: manual, isControlUnlocked: unlocked)
    }

    @Test func modeFollowsTheFansOwnFlagAndTarget() {
        #expect(fan(target: 3000, manual: false).mode == .automatic)
        #expect(fan(target: 3000, manual: true).mode == .manual)
        #expect(fan(target: 6800, manual: true).mode == .max)
    }

    /// A manual speed at the top of the range reads back as Max. It must still
    /// count as the manual mode that was asked for, or it stays pending.
    @Test func manualAtFullSpeedCountsAsManual() {
        #expect(fan(target: 6800, manual: true).isIn(.manual))
        #expect(!fan(target: 3000, manual: false).isIn(.manual))
        #expect(fan(target: 6800, manual: true).isIn(.max))
    }

    /// `Ftst = 1` with this fan automatic: macOS is not managing it.
    @Test func unlockedFanIsNotSystemControlled() {
        #expect(fan(target: 0, manual: false, unlocked: true).isSystemControlled == false)
        #expect(fan(target: 0, manual: false).isSystemControlled)
    }

    @Test func nonFiniteReadingsBecomeZero() {
        var broken = fan(target: .nan, manual: true)
        broken.actual = .infinity
        let fixed = broken.withFiniteReadings
        #expect(fixed.actual == 0)
        #expect(fixed.target == 0)
        #expect(fixed.minimum == 2317)
    }
}
