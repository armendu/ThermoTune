import SwiftUI

/// Every sensor behind one temperature group, hottest first. Shown when hovering
/// a group's numbers in the Temperatures section.
struct SensorBreakdown: View {
    let title: String
    let sensors: [TemperatureSensor]

    private static let rowHeight: CGFloat = 22
    private static let maxListHeight: CGFloat = 380

    private var sorted: [TemperatureSensor] {
        sensors.sorted { $0.value > $1.value }
    }

    private var columnCount: Int {
        switch sensors.count {
        case ...6: return 1
        case ...16: return 2
        default: return 3
        }
    }

    private var needsScrolling: Bool {
        let rows = (sensors.count + columnCount - 1) / columnCount
        return CGFloat(rows) * Self.rowHeight > Self.maxListHeight
    }

    private var list: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
            ForEach(Array(stride(from: 0, to: sorted.count, by: columnCount)), id: \.self) { start in
                GridRow {
                    ForEach(sorted[start ..< min(start + columnCount, sorted.count)]) { sensor in
                        row(sensor)
                    }
                }
            }
        }
    }

    private func row(_ sensor: TemperatureSensor) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.temperature(sensor.value))
                .frame(width: 6, height: 6)
            Text(sensor.key)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(sensor.value.degrees)
                .font(.callout.monospacedDigit())
        }
        .frame(height: Self.rowHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text("\(sensors.count) sensors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let summary = TemperatureSummary(sensors), let coolest = sorted.last {
                HStack(spacing: 18) {
                    stat("Max", summary.maximum)
                    stat("Avg", summary.average)
                    stat("Min", coolest.value)
                }
            }

            Divider()

            // Only long lists scroll (the Other group runs past a hundred sensors); a
            // ScrollView around a short one would just add a scroller that does nothing.
            if needsScrolling {
                ScrollView { list }
                    .frame(height: Self.maxListHeight)
            } else {
                list
            }

            Text("Hottest first. Names are SMC keys; Apple doesn't publish where each sensor sits. Click the numbers to keep this open.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: columnCount == 1 ? 230 : CGFloat(columnCount) * 140 + 28)
    }

    private func stat(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.degrees)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.temperature(value))
        }
    }
}
