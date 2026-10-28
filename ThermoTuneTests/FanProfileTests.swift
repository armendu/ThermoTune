import Foundation
import Testing
@testable import ThermoTune

struct FanBehaviorTests {
    private let fan = FanInfo(id: 0, actual: 0, minimum: 2317, maximum: 6800, target: 0,
                              isManual: false, isControlUnlocked: false)

    @Test func kindsWithoutACurve() {
        #expect(FanBehavior(kind: .automatic).speedFraction(at: 80) == nil)
        #expect(FanBehavior(kind: .max).speedFraction(at: nil) == 1)
        #expect(FanBehavior(kind: .fixed, fixedPercent: 25).speedFraction(at: nil) == 0.25)
        #expect(FanBehavior(kind: .fixed, fixedPercent: 150).speedFraction(at: nil) == 1)
    }

    @Test func curveInterpolatesBetweenPoints() throws {
        let curve = FanBehavior(kind: .curve, curve: [.init(50, 0), .init(70, 40), .init(90, 100)])
        #expect(curve.speedFraction(at: 30) == 0)
        #expect(curve.speedFraction(at: 50) == 0)
        #expect(try #require(curve.speedFraction(at: 60)).isApproximately(0.2))
        #expect(curve.speedFraction(at: 70) == 0.4)
        #expect(try #require(curve.speedFraction(at: 80)).isApproximately(0.7))
        #expect(curve.speedFraction(at: 120) == 1)
        // A curve follows a temperature; without one there is no speed.
        #expect(curve.speedFraction(at: nil) == nil)
    }

    @Test func targetIsAFractionOfTheFansOwnRange() {
        #expect(FanBehavior(kind: .fixed, fixedPercent: 0).targetRPM(for: fan, temperature: nil) == 2317)
        #expect(FanBehavior(kind: .fixed, fixedPercent: 50).targetRPM(for: fan, temperature: nil) == 4558.5)
        #expect(FanBehavior(kind: .max).targetRPM(for: fan, temperature: nil) == 6800)
    }

    @Test func validCurveSortsClampsAndDropsCrowdedPoints() {
        let curve = FanBehavior.validCurve([.init(90, 120), .init(50, -5), .init(50.5, 30), .init(.nan, 50), .init(70, 40)])
        #expect(curve == [.init(50, 0), .init(70, 40), .init(90, 100)])
    }

    @Test func validCurveNeedsTwoPoints() {
        #expect(FanBehavior.validCurve([.init(60, 50)]) == FanBehavior.newCurve)
        #expect(FanBehavior.validCurve([]) == FanBehavior.newCurve)
    }
}

struct FanProfileCodingTests {
    private func decode(_ json: String) throws -> FanProfile {
        try JSONDecoder().decode(FanProfile.self, from: Data(json.utf8))
    }

    /// The shape saved before multi-point curves and per-fan settings.
    @Test func legacyCurveBecomesTwoPoints() throws {
        let profile = try decode("""
            {"id": "6F2C3D4E-0000-4000-8000-000000000001", "name": "Balanced", "kind": "curve",
             "fixedPercent": 50, "source": "hottest", "lowTemperature": 60, "highTemperature": 90}
            """)
        #expect(profile.name == "Balanced")
        #expect(profile.behavior.kind == .curve)
        #expect(profile.behavior.source == .hottest)
        #expect(profile.behavior.curve == [.init(60, 0), .init(90, 100)])
        #expect(!profile.isPerFan)
    }

    @Test func legacyFixedKeepsItsSpeed() throws {
        let profile = try decode("""
            {"id": "6F2C3D4E-0000-4000-8000-000000000002", "name": "Quiet", "kind": "fixed", "fixedPercent": 30}
            """)
        #expect(profile.behavior.kind == .fixed)
        #expect(profile.behavior.fixedPercent == 30)
    }

    @Test func roundTripKeepsPerFanSettings() throws {
        var profile = FanProfile(name: "Split", behavior: FanBehavior(kind: .curve, source: .sensor("Tp01")))
        profile.perFan = [0: FanBehavior(kind: .max), 1: FanBehavior(kind: .fixed, fixedPercent: 40)]
        let decoded = try JSONDecoder().decode(FanProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        #expect(decoded.behavior(forFan: 1).fixedPercent == 40)
        #expect(decoded.behavior(forFan: 5) == profile.behavior)
    }

    /// One fan automatic while the others are manual would sit at its minimum,
    /// so a file asking for it loses that entry instead.
    @Test func perFanAutomaticIsDropped() throws {
        let profile = try decode("""
            {"id": "6F2C3D4E-0000-4000-8000-000000000003", "name": "Odd", "behavior": {"kind": "curve"},
             "perFan": {"0": {"kind": "max"}, "1": {"kind": "automatic"}, "-1": {"kind": "max"}, "x": {"kind": "max"}}}
            """)
        #expect(profile.perFan.keys.sorted() == [0])
    }

    /// "1" and "01" are the same fan. `Dictionary(uniqueKeysWithValues:)` trapped on that.
    @Test func duplicateFanIndicesDontCrash() throws {
        let profile = try decode("""
            {"id": "6F2C3D4E-0000-4000-8000-000000000004", "name": "Dup", "behavior": {"kind": "curve"},
             "perFan": {"1": {"kind": "max"}, "01": {"kind": "fixed", "fixedPercent": 10}}}
            """)
        #expect(profile.perFan.count == 1)
    }

    @Test func hostileValuesAreNormalised() throws {
        let profile = try decode("""
            {"id": "6F2C3D4E-0000-4000-8000-000000000005", "name": "Hand-edited",
             "behavior": {"kind": "fixed", "fixedPercent": 900, "curve": [{"temperature": 90, "percent": 100},
                                                                          {"temperature": 40, "percent": 0}]}}
            """)
        #expect(profile.behavior.fixedPercent == 100)
        #expect(profile.behavior.curve == [.init(40, 0), .init(90, 100)])
    }

    /// One unreadable profile, say from a newer ThermoTune, must not cost the rest.
    @Test func savedListSkipsWhatItCantRead() throws {
        let good = FanProfile(name: "Good", behavior: FanBehavior(kind: .max))
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        let data = Data("[\(goodJSON), {\"id\": \"not a uuid\"}]".utf8)
        let (profiles, isComplete) = ProfileStore.decode(data)
        #expect(profiles == [good])
        #expect(!isComplete)
        #expect(ProfileStore.decode(try JSONEncoder().encode([good])).isComplete)
    }

    @Test func archiveRecordsItsVersion() throws {
        let archive = ProfileArchive(profiles: FanProfile.defaults)
        let decoded = try JSONDecoder().decode(ProfileArchive.self, from: JSONEncoder().encode(archive))
        #expect(decoded.version == ProfileArchive.currentVersion)
        #expect(decoded.profiles == FanProfile.defaults)
    }
}

struct SensorSourceTests {
    @Test func rawValuesRoundTrip() {
        for source in [SensorSource.cpu, .gpu, .hottest, .sensor("TC0P")] {
            #expect(SensorSource(rawValue: source.rawValue) == source)
        }
        // The values saved before single sensors existed.
        #expect(SensorSource(rawValue: "hottest") == .hottest)
        #expect(SensorSource(rawValue: "sensor:") == nil)
        #expect(SensorSource(rawValue: "fan") == nil)
    }

    @Test func codesAsAPlainString() throws {
        let data = try JSONEncoder().encode([SensorSource.sensor("Tg0f")])
        #expect(String(decoding: data, as: UTF8.self) == #"["sensor:Tg0f"]"#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([SensorSource].self, from: Data(#"["nope"]"#.utf8)) }
    }
}

extension Double {
    func isApproximately(_ other: Double) -> Bool { abs(self - other) < 1e-9 }
}
