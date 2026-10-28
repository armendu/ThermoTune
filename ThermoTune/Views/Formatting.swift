import SwiftUI

extension Double {
    /// A Celsius reading as a whole number in the unit chosen in Preferences, without the unit.
    var degreesNumber: String {
        "\(Int(TemperatureUnit.current.convert(self).rounded()))"
    }
    /// A Celsius reading formatted in the unit chosen in Preferences, unit included.
    var degrees: String { degreesNumber + TemperatureUnit.current.symbol }
    var rpm: String { self < 1 ? "Off" : "\(Int(rounded()).formatted()) RPM" }
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

/// The colour-coded dot beside a single sensor's reading.
struct TemperatureDot: View {
    let value: Double

    var body: some View {
        Circle()
            .fill(Color.temperature(value))
            .frame(width: 6, height: 6)
    }
}
