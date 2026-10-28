import SwiftUI

extension Double {
    /// A Celsius reading formatted in the unit chosen in Preferences, unit included.
    var degrees: String {
        let unit = TemperatureUnit.current
        return "\(Int(unit.convert(self).rounded()))\(unit.symbol)"
    }
    var rpm: String { self < 1 ? "Off" : "\(Int(rounded())) RPM" }
}

extension Color {
    static func temperature(_ value: Double) -> Color {
        switch value {
        case ..<60: return .green
        case ..<80: return .orange
        default: return .red
        }
    }
}
