import Foundation

struct FanInfo: Identifiable, Equatable, Sendable {
    let id: Int
    var actual: Double
    var minimum: Double
    var maximum: Double
    var target: Double
    var isManual: Bool
    /// `Ftst` is on: thermal control is suspended for every fan, so even a fan whose
    /// own mode is automatic is held at its minimum.
    var isControlUnlocked: Bool

    var name: String { "Fan \(id + 1)" }

    var isSystemControlled: Bool { !isManual && !isControlUnlocked }
}

extension SMC {
    // Apple silicon uses per-fan mode keys, unlocked by `Ftst` where the Mac has it (not on
    // M5); Intel uses the `FS! ` bitmask.
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

    private var manualModeMask: Int {
        Int((try? read("FS! ")) ?? 0)
    }

    private func hasManualMode(_ index: Int) -> Bool {
        if let key = Self.fanModeKey(index, exists: hasKey), let mode = try? read(key) {
            return mode == Self.manualMode
        }
        return manualModeMask & (1 << index) != 0
    }

    /// `F<n>Md`, or `F<n>md` on some M5 Macs; `nil` on Intel, which has `FS! ` instead.
    static func fanModeKey(_ index: Int, exists: (String) -> Bool) -> String? {
        ["F\(index)Md", "F\(index)md"].first(where: exists)
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
            // A fan left manual, or `Ftst` left set with no fan manual, is a fan nobody manages.
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

    /// The way back to macOS control, so one failed write must not stop the rest:
    /// every fan is tried and `Ftst` is always cleared, then the first error is thrown.
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

    /// Read fresh: `fan(_:)` shows a failed read as 0, and clamping to 0...0 would
    /// park the fan at 0 RPM with thermal control suspended.
    private func speedRange(_ index: Int) throws -> ClosedRange<Double> {
        guard let minimum = try? read("F\(index)Mn"), let maximum = try? read("F\(index)Mx"),
              minimum >= 0, maximum > 0, minimum <= maximum else {
            throw SMCError.noFanRange(fan: index)
        }
        return minimum...maximum
    }

    /// Strict, unlike `fanCount()`: a write over "no fans" would touch none and still succeed.
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

    /// `index` was just written, and writes land asynchronously, so its read-back
    /// can still show the old mode.
    private func relockIfAllAutomatic(except index: Int) throws {
        if hasKey("Ftst"), !(0..<fanCount()).contains(where: { $0 != index && hasManualMode($0) }) {
            try write("Ftst", 0)
        }
    }

    private func setMode(_ index: Int, manual: Bool) throws {
        guard let key = Self.fanModeKey(index, exists: hasKey) else {
            let mask = manualModeMask
            try write("FS! ", Double(manual ? mask | (1 << index) : mask & ~(1 << index)))
            return
        }
        // After `Ftst` is set the SMC answers 0x82 until thermal management hands over,
        // about 5-10 seconds.
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

    /// Most `T*` keys are junk. Runs once at launch, so a sensor reading outside
    /// 5…130 °C then is never found; that's deliberate.
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
