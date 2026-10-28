import Foundation

enum FanMode: String, CaseIterable, Identifiable {
    case automatic = "Auto"
    case manual = "Manual"
    case max = "Max"

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: return String(localized: "Auto")
        case .manual: return String(localized: "Manual")
        case .max: return String(localized: "Max")
        }
    }
}

extension FanInfo {
    /// `name`, translated. `FanInfo` lives in Shared/, which the helper also
    /// builds, so localisation stays on the app side.
    var title: String { String(localized: "Fan \(id + 1)") }

    var mode: FanMode {
        guard isManual else { return .automatic }
        return target >= maximum - 1 ? .max : .manual
    }

    /// Whether the fan reads back in a requested mode. A manual speed at the top
    /// of the range reads back as Max, which still counts as manual.
    func isIn(_ requested: FanMode) -> Bool {
        requested == .manual ? isManual : mode == requested
    }

    /// The same fan with a NaN or infinite reading as 0. Every RPM label converts
    /// to `Int`, which traps on those, and a crash skips handing the fans back.
    var withFiniteReadings: FanInfo {
        var fan = self
        for keyPath in [\FanInfo.actual, \.minimum, \.maximum, \.target] where !fan[keyPath: keyPath].isFinite {
            fan[keyPath: keyPath] = 0
        }
        return fan
    }
}
