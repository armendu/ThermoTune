import SwiftUI

/// One compact row per sensor group, with every individual sensor in a popover.
struct SensorsSection: View {
    @Environment(HardwareMonitor.self) private var monitor
    @State private var showsAllSensors = false

    private var groups: [(TemperatureSensor.Group, [TemperatureSensor])] {
        let grouped = Dictionary(grouping: monitor.sensors, by: \.group)
        return TemperatureSensor.Group.allCases.compactMap { group in
            grouped[group].map { (group, $0) }
        }
    }

    var body: some View {
        Panel {
            if monitor.sensors.isEmpty {
                Text(monitor.isDiscoveringSensors ? "Discovering sensors…" : "No sensors found.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.0) { group, sensors in
                GroupRow(group: group, sensors: sensors)
            }
        } header: {
            HStack {
                Text("Temperatures").font(.headline)
                Spacer()
                Button("All Sensors…") { showsAllSensors = true }
                    .buttonStyle(.link)
                    .disabled(monitor.sensors.isEmpty)
                    .popover(isPresented: $showsAllSensors, arrowEdge: .trailing) {
                        AllSensorsView()
                    }
            }
        }
    }
}

private struct GroupRow: View {
    let group: TemperatureSensor.Group
    let sensors: [TemperatureSensor]

    private var title: String {
        switch group {
        case .cpu: return "CPU Package"
        default: return group.rawValue
        }
    }

    @State private var isHovering = false
    @State private var showsBreakdown = false
    /// Set by a click, so the breakdown stays open when the pointer moves into it
    /// (the Other group has too many sensors to read without scrolling).
    @State private var isPinned = false
    @State private var hoverDelay: Task<Void, Never>?

    var body: some View {
        if let summary = TemperatureSummary(sensors) {
            HStack(spacing: 12) {
                Text(title)
                    .lineLimit(1)
                    .help(group == .other ? "Battery, SSD, chassis and every other sensor" : title)
                Text("\(sensors.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .background(.quaternary, in: Capsule())
                Spacer()
                HStack(spacing: 12) {
                    Text("avg \(summary.average.degrees)")
                        .foregroundStyle(.secondary)
                    Text(summary.maximum.degrees)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.temperature(summary.maximum))
                        .frame(width: 48, alignment: .trailing)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isHovering || showsBreakdown ? Color.primary.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onHover(perform: hover)
                .onTapGesture {
                    isPinned = true
                    showsBreakdown = true
                }
                .popover(isPresented: $showsBreakdown, arrowEdge: .trailing) {
                    SensorBreakdown(title: title, sensors: sensors)
                }
                .onChange(of: showsBreakdown) {
                    if !showsBreakdown { isPinned = false }
                }
            }
            .monospacedDigit()
            .padding(.trailing, -6)
        }
    }

    private func hover(_ hovering: Bool) {
        isHovering = hovering
        hoverDelay?.cancel()
        if hovering {
            // A short delay, so sweeping the pointer across the list doesn't flash popovers.
            hoverDelay = Task {
                try? await Task.sleep(for: .milliseconds(350))
                if !Task.isCancelled { showsBreakdown = true }
            }
        } else if !isPinned {
            showsBreakdown = false
        }
    }
}

private struct AllSensorsView: View {
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(TemperatureSensor.Group.allCases, id: \.self) { group in
                    let sensors = monitor.sensors.filter { $0.group == group }
                    if !sensors.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.rawValue).font(.headline)
                            SensorGrid(sensors: sensors)
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
    }
}

private struct SensorGrid: View {
    let sensors: [TemperatureSensor]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
            ForEach(sensors) { sensor in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.temperature(sensor.value))
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(sensor.label)
                            .font(.caption)
                            .lineLimit(1)
                        Text(sensor.key)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    Text(sensor.value.degrees)
                        .font(.callout.monospacedDigit())
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .help("SMC key \(sensor.key): \(String(format: "%.1f", sensor.value)) °C")
            }
        }
    }
}
