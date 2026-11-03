import Foundation
import Testing
@testable import ThermoTune

/// Each test gets its own defaults suite: the test host is the real app, and
/// `.standard` would be the user's own settings.
@MainActor
struct ProfileRulesTests {
    private let cool = UUID(), full = UUID(), fallback = UUID()

    private func makeRules(_ rules: [ProfileRule]) -> ProfileRules {
        let defaults = UserDefaults(suiteName: "ThermoTuneTests.\(UUID().uuidString)")!
        let store = ProfileRules(defaults: defaults)
        store.rules = rules
        store.isEnabled = true
        return store
    }

    private func hot(_ source: SensorSource, _ limit: Double, use id: UUID) -> ProfileRule {
        ProfileRule(condition: .temperatureAbove(source: source, limit: limit), profileID: id)
    }

    @Test func actsOnlyWhenTheMatchChanges() {
        let rules = makeRules([hot(.cpu, 80, use: full)])
        rules.fallbackProfileID = cool
        #expect(rules.decide { _ in 60 } == .use(cool))
        // Same outcome again: a profile picked by hand meanwhile is left alone.
        #expect(rules.decide { _ in 62 } == .keep)
        #expect(rules.decide { _ in 85 } == .use(full))
        #expect(rules.decide { _ in 86 } == .keep)
    }

    @Test func temperatureRuleHoldsUntilWellBelowItsLimit() {
        let rules = makeRules([hot(.cpu, 80, use: full)])
        #expect(rules.decide { _ in 81 } == .use(full))
        // 5° of margin: 77 still counts as hot, 74 doesn't.
        #expect(rules.decide { _ in 77 } == .keep)
        #expect(rules.matchedRuleID != nil)
        #expect(rules.decide { _ in 74 } == .keep)
        #expect(rules.matchedRuleID == nil)
    }

    @Test func noMatchAndNoFallbackLeavesTheProfile() {
        let rules = makeRules([hot(.cpu, 80, use: full)])
        #expect(rules.decide { _ in 50 } == .keep)
    }

    @Test func disabledRulesNeverAct() {
        let rules = makeRules([hot(.cpu, 80, use: full)])
        rules.isEnabled = false
        #expect(rules.decide { _ in 99 } == .keep)
    }

    /// A later temperature rule keeps tracking its reading while an earlier rule
    /// wins, so it doesn't come back stale when that rule stops matching.
    @Test func laterRulesKeepTheirHysteresis() {
        let rules = makeRules([hot(.cpu, 50, use: cool), hot(.gpu, 80, use: full)])
        func reading(cpu: Double, gpu: Double) -> (SensorSource) -> Double? {
            { $0 == .cpu ? cpu : gpu }
        }
        #expect(rules.decide(temperature: reading(cpu: 60, gpu: 85)) == .use(cool))
        // The GPU cools well below its rule while the CPU rule still wins.
        #expect(rules.decide(temperature: reading(cpu: 60, gpu: 70)) == .keep)
        // CPU rule ends; at 77° the GPU rule is not hot any more.
        #expect(rules.decide(temperature: reading(cpu: 30, gpu: 77)) == .keep)
        #expect(rules.matchedRuleID == nil)
    }

    @Test func deletedProfileBecomesNone() {
        let rules = makeRules([hot(.cpu, 80, use: full)])
        rules.fallbackProfileID = full
        rules.profileDeleted(full)
        #expect(rules.rules[0].profileID == nil)
        #expect(rules.fallbackProfileID == nil)
    }
}

struct HistoryCSVTests {
    private let sample = HardwareMonitor.Sample(
        date: Date(timeIntervalSince1970: 0), cpu: 45.04, gpu: nil, cpuMaximum: 60, gpuMaximum: nil,
        fanRPMs: [0, 2316.6], thermalState: .serious, profile: #"Quiet "night", 2"#)

    @Test func headerNamesEveryFan() {
        #expect(HistoryCSV.header(fanCount: 2)
                == "time,cpu_avg_c,cpu_max_c,gpu_avg_c,gpu_max_c,fan1_rpm,fan2_rpm,thermal_pressure,profile")
    }

    @Test func rowQuotesTheProfileAndLeavesMissingReadingsEmpty() {
        let row = HistoryCSV.row(sample)
        #expect(row.hasSuffix(#",45.0,60.0,,,0,2317,serious,"Quiet ""night"", 2""#))
    }

    @Test func thermalPressureIsNotTranslated() {
        #expect(HistoryCSV.token(.nominal) == "nominal")
        #expect(HistoryCSV.token(.critical) == "critical")
    }

    @Test func documentHasAHeaderAndOneLinePerSample() {
        let lines = HistoryCSV.document([sample, sample]).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("time,"))
    }
}

struct SensorNameTests {
    @Test func sharedLabelsAreNumberedInKeyOrder() {
        let sensors = ["Tp09", "Tp01", "TB1T", "Tp05"].map { TemperatureSensor(key: $0, value: 50) }
        let names = TemperatureSensor.names(for: sensors)
        #expect(names.count == 4)
        #expect(Set(["Tp01", "Tp05", "Tp09"].compactMap { names[$0] }).count == 3)
        #expect(names["Tp01"]!.hasSuffix("1"))
        #expect(names["Tp09"]!.hasSuffix("3"))
        // Alone with its label, so not numbered.
        #expect(names["TB1T"] == TemperatureSensor(key: "TB1T", value: 0).label)
    }

    @Test func groupsComeFromTheKeyPrefix() {
        #expect(TemperatureSensor(key: "Tp01", value: 0).group == .cpuPerformance)
        #expect(TemperatureSensor(key: "Te05", value: 0).group == .cpuEfficiency)
        #expect(TemperatureSensor(key: "Tg0f", value: 0).group == .gpu)
        #expect(TemperatureSensor(key: "TB1T", value: 0).group == .other)
    }
}
