import Foundation

enum FanMode: String, CaseIterable, Identifiable {
    case automatic = "Auto"
    case manual = "Manual"
    case max = "Max"

    var id: Self { self }
}

extension FanInfo {
    var mode: FanMode {
        guard isManual else { return .automatic }
        return target >= maximum - 1 ? .max : .manual
    }

    /// Whether the fan reads back in a requested mode. A manual speed at the top
    /// of the range reads back as Max, which still counts as manual.
    func isIn(_ requested: FanMode) -> Bool {
        requested == .manual ? isManual : mode == requested
    }
}
