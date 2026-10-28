import Charts
import SwiftUI

struct ContentView: View {
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        Form {
            Section {
                OverviewTiles()
                TemperatureChart()
            }

            Section {
                if monitor.fans.isEmpty {
                    Text("No fans detected on this Mac.")
                        .foregroundStyle(.secondary)
                }
                ForEach(monitor.fans) { fan in
                    FanRow(fan: fan)
                }
            } header: {
                HStack(spacing: 12) {
                    Text("Fans")
                    Spacer()
                    if monitor.helperState == .ready {
                        ProfilePicker()
                            .fixedSize()
                        EditProfilesButton()
                            .buttonStyle(.link)
                        if monitor.fans.count > 1 {
                            Button("All Max") { monitor.setAllMax() }
                                .buttonStyle(.link)
                                .disabled(monitor.fans.allSatisfy { monitor.mode(of: $0) == .max })
                        }
                        Button("All Auto") { monitor.setAllAutomatic() }
                            .buttonStyle(.link)
                            .disabled(monitor.fans.allSatisfy(\.isSystemControlled))
                            .help("Hand every fan back to macOS")
                    }
                }
            } footer: {
                HelperFooter()
            }

            SensorsSection()
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 600, idealHeight: 800)
        .alert("ThermoTune", isPresented: errorBinding) {
            Button("OK") { monitor.errorMessage = nil }
        } message: {
            Text(monitor.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { monitor.errorMessage != nil },
                set: { if !$0 { monitor.errorMessage = nil } })
    }
}

// MARK: - Overview

private struct OverviewTiles: View {
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        HStack(spacing: 12) {
            StatTile(title: "CPU", symbol: "cpu", summary: monitor.cpuSummary)
            StatTile(title: "GPU", symbol: "square.stack.3d.up", summary: monitor.gpuSummary)
            FanTile(fans: monitor.fans)
        }
        .padding(.vertical, 4)
    }
}

private struct StatTile: View {
    let title: String
    let symbol: String
    let summary: TemperatureSummary?

    var body: some View {
        if let summary {
            Tile(title: title, symbol: symbol, value: summary.maximum.degrees,
                 valueColor: .temperature(summary.maximum), caption: "max · avg \(summary.average.degrees)")
        } else {
            Tile(title: title, symbol: symbol, value: "–", caption: "reading…")
        }
    }
}

private struct FanTile: View {
    let fans: [FanInfo]

    var body: some View {
        let fastest = fans.map(\.actual).max() ?? 0
        let mode = fans.allSatisfy(\.isSystemControlled) ? "automatic" : "manual"
        Tile(title: "Fans", symbol: "fan",
             value: fastest < 1 ? "Off" : "\(Int(fastest))",
             caption: fastest < 1 ? mode : "RPM · \(mode)")
    }
}

private struct Tile: View {
    let title: String
    let symbol: String
    let value: String
    var valueColor: Color = .primary
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .contentTransition(.numericText())
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct TemperatureChart: View {
    @Environment(HardwareMonitor.self) private var monitor
    @AppStorage(PreferenceKey.chartWindowMinutes) private var windowMinutes = 5

    private static let windows = [1, 5, 15, 30, 60]

    private static func title(minutes: Int) -> String {
        switch minutes {
        case 1: return "Last minute"
        case 60: return "Last hour"
        default: return "Last \(minutes) minutes"
        }
    }

    private var windowStart: Date {
        Date.now.addingTimeInterval(-Double(windowMinutes) * 60)
    }

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let series: String
        let value: Double
    }

    private var points: [Point] {
        let unit = TemperatureUnit.current
        let start = windowStart
        return monitor.history.filter { $0.date >= start }.flatMap { sample in
            [("CPU", sample.cpu), ("GPU", sample.gpu)].compactMap { series, value in
                value.map { Point(id: "\(sample.id)-\(series)", date: sample.date, series: series, value: unit.convert($0)) }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Average temperature")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Time range", selection: $windowMinutes) {
                    ForEach(Self.windows, id: \.self) { Text(Self.title(minutes: $0)).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            Chart(points) { point in
                LineMark(x: .value("Time", point.date),
                         y: .value("Temperature", point.value))
                    .foregroundStyle(by: .value("Sensor", point.series))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(["CPU": Color.accentColor, "GPU": Color.purple])
            .chartYAxis { AxisMarks(position: .leading) }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 80)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Helper footer

private struct HelperFooter: View {
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        switch monitor.helperState {
        case .ready:
            Text("Fans return to automatic when ThermoTune quits.")
        case .notInstalled, .needsUpdate:
            HStack(alignment: .firstTextBaseline) {
                Text(monitor.helperState == .notInstalled
                     ? "Changing fan speed needs a helper tool, installed once with your administrator password."
                     : "The installed helper tool is out of date.")
                Spacer()
                Button(monitor.helperState == .notInstalled ? "Install Helper…" : "Update Helper…") {
                    monitor.installHelper()
                }
            }
        }
    }
}
