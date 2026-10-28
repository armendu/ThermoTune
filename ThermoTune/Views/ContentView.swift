import Charts
import SwiftUI

struct ContentView: View {
    @Environment(HardwareMonitor.self) private var monitor

    /// Wide enough for a fan row's name, speed and mode picker on one line.
    static let fansMinWidth: CGFloat = 450
    static let sensorsWidth: CGFloat = 340

    var body: some View {
        // The columns stretch to fill a tall window; only a window too short
        // for their rows scrolls.
        ViewThatFits(in: .vertical) {
            layout
            ScrollView { layout }
        }
        .frame(minWidth: Self.fansMinWidth + Self.sensorsWidth + 60, minHeight: 480)
        .alert("ThermoTune", isPresented: errorBinding) {
            Button("OK") { monitor.errorMessage = nil }
        } message: {
            Text(monitor.errorMessage ?? "")
        }
    }

    private var layout: some View {
        VStack(spacing: 20) {
            Panel {
                OverviewTiles()
                TemperatureChart()
            }

            HStack(alignment: .top, spacing: 20) {
                FansPanel()
                    .frame(minWidth: Self.fansMinWidth, maxWidth: .infinity)
                SensorsSection()
                    .frame(width: Self.sensorsWidth)
            }
        }
        .padding(20)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { monitor.errorMessage != nil },
                set: { if !$0 { monitor.errorMessage = nil } })
    }
}

// MARK: - Fans

private struct FansPanel: View {
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        Panel {
            if let trip = monitor.safetyTrip {
                SafetyBanner(trip: trip)
            }
            if monitor.fans.isEmpty {
                Text("No fans detected on this Mac.")
                    .foregroundStyle(.secondary)
            }
            ForEach(monitor.fans) { fan in
                FanRow(fan: fan)
            }
        } header: {
            HStack(spacing: 12) {
                Text("Fans").font(.headline)
                Spacer()
                if monitor.helperState == .ready {
                    Group {
                        ProfilePicker()
                            .fixedSize()
                        SettingsTabButton(title: "Edit…", tab: .profiles)
                            .buttonStyle(.link)
                            .help("Create and edit fan profiles")
                        if monitor.fans.count > 1 {
                            Button("All Max") { monitor.setAllMax() }
                                .buttonStyle(.link)
                                .disabled(monitor.fans.allSatisfy { monitor.mode(of: $0) == .max })
                        }
                        Button("All Auto") { monitor.setAllAutomatic() }
                            .buttonStyle(.link)
                            .disabled(monitor.fansAreSystemControlled)
                            .help("Hand every fan back to macOS")
                    }
                    .disabled(!monitor.canControlFans)
                }
            }
        } footer: {
            HelperFooter()
        }
        .fillingHeight()
    }
}

/// Shown at the top of the Fans panel after the safety net has stepped in.
private struct SafetyBanner: View {
    let trip: HardwareMonitor.SafetyTrip
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("The safety net stepped in at \(trip.temperature.degrees)")
                    .fontWeight(.semibold)
                Text(trip.action == .automatic
                     ? "macOS is managing the fans again, and the profile was switched off. \(trip.date.formatted(date: .omitted, time: .shortened))"
                     : "Every fan runs at full speed until it cools down. \(trip.date.formatted(date: .omitted, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dismiss") { monitor.dismissSafetyTrip() }
                .controlSize(.small)
        }
    }
}

/// macOS's own measure of how hard it is working to stay cool. From Serious up,
/// it slows the Mac down.
struct ThermalStateBadge: View {
    let state: ProcessInfo.ThermalState

    private var color: Color {
        switch state {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("Thermal pressure: \(state.title)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("How hard macOS is working to keep the Mac cool. At Serious and Critical it slows the Mac down.")
    }
}

// MARK: - Overview

private struct OverviewTiles: View {
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        HStack(spacing: 12) {
            StatTile(source: .cpu)
            StatTile(source: .gpu)
            FanTile()
        }
        .padding(.vertical, 4)
    }
}

private struct StatTile: View {
    let source: SensorSource
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        if let summary = monitor.summary(source) {
            Tile(title: source.title, symbol: source.symbol,
                 value: summary.average.degreesNumber,
                 unit: TemperatureUnit.current.symbol,
                 valueColor: .temperature(summary.average), caption: String(localized: "average · hottest \(summary.maximum.degrees)"))
        } else {
            Tile(title: source.title, symbol: source.symbol, value: "–", caption: String(localized: "reading…"))
        }
    }
}

private struct FanTile: View {
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        let fastest = monitor.fans.map(\.actual).max() ?? 0
        let mode = monitor.fansAreSystemControlled ? String(localized: "automatic") : String(localized: "manual")
        Tile(title: String(localized: "Fans"), symbol: "fan",
             value: fastest < 1 ? String(localized: "Off") : Int(fastest).formatted(),
             unit: fastest < 1 ? nil : "RPM",
             caption: fastest < 1 || monitor.fans.count < 2 ? mode : String(localized: "fastest · \(mode)"))
    }
}

private struct Tile: View {
    let title: String
    let symbol: String
    let value: String
    var unit: String?
    var valueColor: Color = .primary
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(valueColor)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
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
        case 1: return String(localized: "Last minute")
        case 60: return String(localized: "Last hour")
        default: return String(localized: "Last \(minutes) minutes")
        }
    }

    private var windowStart: Date {
        Date.now.addingTimeInterval(-Double(windowMinutes) * 60)
    }

    @AppStorage(PreferenceKey.temperatureUnit) private var unit = TemperatureUnit.celsius
    @AppStorage(PreferenceKey.refreshInterval) private var refreshInterval = 2.0

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let series: String
        /// A run of readings with no gap; each is drawn as its own line.
        let segment: String
        let value: Double
    }

    /// Readings further apart than this (the Mac slept, or the series had no
    /// reading) start a new line, rather than one drawn straight across the gap.
    private var maximumGap: TimeInterval { max(refreshInterval * 3, 10) }

    private var points: [Point] {
        let samples = monitor.history.filter { $0.date >= windowStart }
        var points: [Point] = []
        for (series, value) in [("CPU", \HardwareMonitor.Sample.cpu), ("GPU", \.gpu)] {
            var segment = 0
            var previous: Date?
            for sample in samples {
                guard let reading = sample[keyPath: value] else {
                    previous = nil
                    continue
                }
                if previous.map({ sample.date.timeIntervalSince($0) > maximumGap }) ?? true {
                    segment += 1
                }
                previous = sample.date
                points.append(Point(id: "\(sample.id)-\(series)", date: sample.date, series: series,
                                    segment: "\(series)-\(segment)", value: unit.convert(reading)))
            }
        }
        return points
    }

    /// The y-axis range and the values labelled on it. The range is rounded out
    /// around the readings so the lines sit inside the chart, and stretched to a
    /// whole number of steps so both ends get a label: left to Swift Charts, the
    /// bottom gridline was often unlabelled and the lines couldn't be read off.
    private func yAxis(_ points: [Point]) -> (domain: ClosedRange<Double>, ticks: [Double]) {
        let values = points.map(\.value)
        var low = max((((values.min() ?? unit.convert(30)) - 5) / 10).rounded(.down) * 10, 0)
        var high = (((values.max() ?? unit.convert(70)) + 5) / 10).rounded(.up) * 10
        let step: Double = high - low > 60 ? 20 : 10
        low = (low / step).rounded(.down) * step
        high = (high / step).rounded(.up) * step
        return (low...high, Array(stride(from: low, through: high, by: step)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Average temperature (\(unit.symbol))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ThermalStateBadge(state: monitor.thermalState)
                Picker("Time range", selection: $windowMinutes) {
                    ForEach(Self.windows, id: \.self) { Text(Self.title(minutes: $0)).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            let points = points
            let yAxis = yAxis(points)
            Chart(points) { point in
                LineMark(x: .value("Time", point.date),
                         y: .value("Temperature", point.value),
                         series: .value("Segment", point.segment))
                    .foregroundStyle(by: .value("Sensor", point.series))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(["CPU": Color.accentColor, "GPU": Color.purple])
            .chartYAxis {
                AxisMarks(position: .leading, values: yAxis.ticks) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let degrees = value.as(Double.self) {
                            Text("\(Int(degrees))")
                        }
                    }
                }
            }
            .chartYScale(domain: yAxis.domain)
            .frame(height: 110)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Helper footer

private struct HelperFooter: View {
    @Environment(HardwareMonitor.self) private var monitor
    @AppStorage(PreferenceKey.restoreAutomaticOnQuit) private var restoreOnQuit = true

    var body: some View {
        switch monitor.helperState {
        case .ready:
            Text(restoreOnQuit
                 ? "Fans return to automatic when ThermoTune quits."
                 : "Fans keep their speeds when ThermoTune quits.")
        case .notInstalled, .needsUpdate:
            HStack(alignment: .firstTextBaseline) {
                Text(monitor.helperState == .notInstalled
                     ? "Changing fan speed needs a helper tool, installed once with your administrator password."
                     : "The installed helper tool is out of date.")
                Spacer()
                HelperInstallButton()
            }
        }
    }
}
