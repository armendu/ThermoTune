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
}
