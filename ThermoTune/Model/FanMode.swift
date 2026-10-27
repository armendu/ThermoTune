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
}
