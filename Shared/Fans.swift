import Foundation

struct FanInfo: Identifiable, Equatable, Sendable {
    let id: Int
    var actual: Double
    var minimum: Double
    var maximum: Double
    var target: Double
    var isManual: Bool

    var name: String { "Fan \(id + 1)" }
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
        (0..<fanCount()).compactMap { fan($0) }
    }

    func fan(_ index: Int) -> FanInfo? {
        guard let actual = try? read("F\(index)Ac") else { return nil }
        return FanInfo(
            id: index,
            actual: max(actual, 0),
            minimum: (try? read("F\(index)Mn")) ?? 0,
            maximum: (try? read("F\(index)Mx")) ?? 0,
            target: (try? read("F\(index)Tg")) ?? 0,
            isManual: isFanManual(index)
        )
    }

    /// True when macOS is not managing this fan: it is in manual mode, or the
    /// `Ftst` unlock is active, which suspends thermal control for every fan.
    func isFanManual(_ index: Int) -> Bool {
        isFanControlUnlocked || hasManualMode(index)
    }

    var isFanControlUnlocked: Bool {
        (try? read("Ftst")) == 1
    }

    private func hasManualMode(_ index: Int) -> Bool {
        if let mode = try? read("F\(index)Md") {
            return mode == Self.manualMode
        }
        let mask = Int((try? read("FS! ")) ?? 0)
        return mask & (1 << index) != 0
    }

    // MARK: Writes (require root)

    func setFanManual(_ index: Int, rpm: Double) throws {
        guard let fan = fan(index) else { throw SMCError.smcResult(key: "F\(index)Ac", code: 0x84) }
        let rpm = min(max(rpm, fan.minimum), fan.maximum)

        try unlockManualControl()
        do {
            try setMode(index, manual: true)
        } catch {
            try? relockIfAllAutomatic(except: index)
            throw error
        }
        try write("F\(index)Tg", rpm)
    }

    /// Puts every fan in manual mode at its maximum speed.
    func setAllFansMax() throws {
        try unlockManualControl()
        do {
            for fan in fans() {
                try setMode(fan.id, manual: true)
                try write("F\(fan.id)Tg", fan.maximum)
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

    func setAllFansAuto() throws {
        for index in 0..<fanCount() {
            try setMode(index, manual: false)
        }
        if hasKey("Ftst") {
            try write("Ftst", 0)
        }
    }

    private func unlockManualControl() throws {
        if hasKey("Ftst"), (try? read("Ftst")) != 1 {
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
            var mask = Int((try? read("FS! ")) ?? 0)
            mask = manual ? mask | (1 << index) : mask & ~(1 << index)
            try write("FS! ", Double(mask))
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

    /// Returns every temperature key that currently reports a plausible value.
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
