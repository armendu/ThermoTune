import Foundation

struct FanInfo: Identifiable, Equatable, Sendable {
    let id: Int
    var actual: Double
    var minimum: Double
    var maximum: Double
    var target: Double
    /// This fan's own mode is manual.
    var isManual: Bool
    /// The `Ftst` unlock is on. That suspends macOS thermal control for every fan,
    /// so a fan whose own mode is automatic is still not being managed: it is held
    /// at its minimum speed until every fan is back on automatic.
    var isControlUnlocked: Bool

    var name: String { "Fan \(id + 1)" }

    /// True when macOS is managing this fan, i.e. nothing needs handing back.
    var isSystemControlled: Bool { !isManual && !isControlUnlocked }
}

extension SMC {
    // Apple Silicon (M1+) uses per-fan `F<n>Md` mode keys. Newer firmware also
    // requires the `Ftst` key to be set before it accepts a manual mode. Intel
    // Macs use the `FS! ` bitmask instead.
    private static let manualMode: Double = 1
    private static let autoMode: Double = 0

    func fanCount() -> Int {
        Int((try? read("FNum")) ?? 0)
    }

    func fans() -> [FanInfo] {
        let isControlUnlocked = isFanControlUnlocked
        return (0..<fanCount()).compactMap { index in
            guard let actual = try? read("F\(index)Ac") else { return nil }
            return FanInfo(
                id: index,
                actual: max(actual, 0),
                minimum: (try? read("F\(index)Mn")) ?? 0,
                maximum: (try? read("F\(index)Mx")) ?? 0,
                target: (try? read("F\(index)Tg")) ?? 0,
                isManual: hasManualMode(index),
                isControlUnlocked: isControlUnlocked
            )
        }
    }

    private var isFanControlUnlocked: Bool {
        (try? read("Ftst")) == 1
    }

    /// Intel's `FS! `: one manual-mode bit per fan.
    private var manualModeMask: Int {
        Int((try? read("FS! ")) ?? 0)
    }

    private func hasManualMode(_ index: Int) -> Bool {
        if let mode = try? read("F\(index)Md") {
            return mode == Self.manualMode
        }
        return manualModeMask & (1 << index) != 0
    }

    // MARK: Writes (require root)

    func setFanManual(_ index: Int, rpm: Double) throws {
        let range = try speedRange(index)
        let rpm = min(max(rpm, range.lowerBound), range.upperBound)

        try unlockManualControl()
        var isManual = false
        do {
            try setMode(index, manual: true)
            isManual = true
            try write("F\(index)Tg", rpm)
        } catch {
            // A fan left manual at whatever target it had, or `Ftst` left set
            // with no fan manual, is a fan nobody is managing.
            if isManual { try? setMode(index, manual: false) }
            try? relockIfAllAutomatic(except: index)
            throw error
        }
    }

    func setAllFansMax() throws {
        let fans = try (0..<writableFanCount()).map { (index: $0, maximum: try speedRange($0).upperBound) }

        try unlockManualControl()
        do {
            for fan in fans {
                try setMode(fan.index, manual: true)
                try write("F\(fan.index)Tg", fan.maximum)
            }
        } catch {
            try? setAllFansAuto()
            throw error
        }
    }

    func setFanAuto(_ index: Int) throws {
        try setMode(index, manual: false)
        try relockIfAllAutomatic(except: index)
    }

    /// The way back to macOS control, used by All Auto, quitting and `make
    /// fans-auto`, so one failed write must not stop the rest: every fan is
    /// tried and `Ftst` is always cleared, then the first error is reported.
    func setAllFansAuto() throws {
        var firstError: Error?
        let count: Int
        do { count = try writableFanCount() } catch { count = 0; firstError = error }
        for index in 0..<count {
            do { try setMode(index, manual: false) } catch { firstError = firstError ?? error }
        }
        if hasKey("Ftst") {
            do { try write("Ftst", 0) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    /// A fan's speed range, read fresh for a write. `fan(_:)` shows a failed read
    /// as 0, but clamping to 0...0 would park the fan at 0 RPM with thermal
    /// control suspended.
    private func speedRange(_ index: Int) throws -> ClosedRange<Double> {
        guard let minimum = try? read("F\(index)Mn"), let maximum = try? read("F\(index)Mx"),
              minimum >= 0, maximum > 0, minimum <= maximum else {
            throw SMCError.noFanRange(fan: index)
        }
        return minimum...maximum
    }

    /// `fanCount()` reads a failed `FNum` as no fans, which suits display. A write
    /// over every fan would then touch none and still report success.
    private func writableFanCount() throws -> Int {
        let count = Int(try read("FNum"))
        guard count > 0 else { throw SMCError.noFans }
        return count
    }

    private func unlockManualControl() throws {
        if hasKey("Ftst"), !isFanControlUnlocked {
            try write("Ftst", 1)
        }
    }

    /// Clears `Ftst` once no fan is left in manual mode. `index` is the fan that
    /// was just switched: SMC writes apply asynchronously, so reading its mode
    /// back right away can still report the old value.
    private func relockIfAllAutomatic(except index: Int) throws {
        if hasKey("Ftst"), !(0..<fanCount()).contains(where: { $0 != index && hasManualMode($0) }) {
            try write("Ftst", 0)
        }
    }

    private func setMode(_ index: Int, manual: Bool) throws {
        let key = "F\(index)Md"
        guard hasKey(key) else {
            let mask = manualModeMask
            try write("FS! ", Double(manual ? mask | (1 << index) : mask & ~(1 << index)))
            return
        }
        // After `Ftst` is set, Apple Silicon SMCs reject manual mode with 0x82
        // (bad command) until thermal management has handed over, which takes
        // roughly 8-10 seconds on an M3 Pro.
        let deadline = Date().addingTimeInterval(20)
        while true {
            do {
                try write(key, manual ? Self.manualMode : Self.autoMode)
                return
            } catch SMCError.smcResult(_, 0x82) where Date() < deadline {
                usleep(250_000)
            }
        }
    }

    // MARK: Temperatures

    /// Most `T*` keys are junk (constant zeros, negatives, `ioft` types). This runs
    /// once at launch, so a real sensor that happens to read outside 5…130 °C then
    /// is never found; that trade-off is deliberate.
    func discoverTemperatureKeys() -> [String] {
        allKeys().filter { key in
            guard key.hasPrefix("T"),
                  let info = try? keyInfo(key),
                  info.type == "flt " || info.type == "sp78",
                  let value = try? read(key) else { return false }
            return (5...130).contains(value)
        }
    }
}
