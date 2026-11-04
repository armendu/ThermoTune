import SwiftUI

extension Double {
    /// In the unit chosen in Settings, without the unit.
    var degreesNumber: String {
        "\(Int(TemperatureUnit.current.convert(self).rounded()))"
    }
    /// In the unit chosen in Settings, unit included.
    var degrees: String { degreesNumber + TemperatureUnit.current.symbol }
    var rpm: String { self < 1 ? String(localized: "Off") : "\(Int(rounded()).formatted()) RPM" }
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

struct TemperatureDot: View {
    let value: Double

    var body: some View {
        Circle()
            .fill(Color.temperature(value))
            .frame(width: 6, height: 6)
    }
}

extension Binding where Value == Bool {
    /// True while `optional` holds a value; setting it to false clears it.
    init<Wrapped>(isPresent optional: Binding<Wrapped?>) {
        self.init(get: { optional.wrappedValue != nil },
                  set: { if !$0 { optional.wrappedValue = nil } })
    }
}

/// CPU, GPU and the hottest of the two, as a picker's choices.
struct SensorGroupOptions: View {
    var body: some View {
        ForEach(SensorSource.groups) { Text($0.title).tag($0) }
    }
}
