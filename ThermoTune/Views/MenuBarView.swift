import SwiftUI

/// The menu bar item. Plain text and symbols draw as a template, so they follow
/// the menu bar's light or dark look; colour and the graph need an image.
struct MenuBarLabel: View {
    @Environment(HardwareMonitor.self) private var monitor
    @AppStorage(PreferenceKey.menuBarSource) private var source: SensorSource = .cpu
    @AppStorage(PreferenceKey.menuBarContent) private var content: MenuBarContent = .temperature
    @AppStorage(PreferenceKey.menuBarUsesAverage) private var usesAverage = false
    @AppStorage(PreferenceKey.menuBarColored) private var colored = false
    @AppStorage(PreferenceKey.menuBarGraph) private var graph = false
    @AppStorage(PreferenceKey.menuBarCompact) private var compact = false
    @AppStorage(PreferenceKey.temperatureUnit) private var unit: TemperatureUnit = .celsius

    private var temperature: Double? {
        usesAverage ? monitor.averageTemperature(source) : monitor.temperature(source)
    }

    private var temperatureText: String? {
        guard let temperature else { return nil }
        return compact ? "\(Int(unit.convert(temperature).rounded()))°" : temperature.degrees
    }

    private var fanText: String? {
        guard let fastest = monitor.fans.map(\.actual).max() else { return nil }
        if fastest < 1 { return compact ? String(localized: "Off") : String(localized: "Fans off") }
        return compact ? String(format: "%.1fk", fastest / 1000) : "\(Int(fastest).formatted()) RPM"
    }

    private var text: String? {
        switch content {
        case .temperature: return temperatureText
        case .fanSpeed: return fanText
        case .both: return [temperatureText, fanText].compactMap { $0 }.joined(separator: " · ")
        case .icon: return nil
        }
    }

    private var symbol: String { content == .fanSpeed ? "fan" : "thermometer.medium" }

    var body: some View {
        if content != .icon, colored || graph {
            Image(nsImage: rendered)
        } else if let text, content != .icon {
            if compact {
                Text(text)
            } else {
                Label(text, systemImage: symbol).labelStyle(.titleAndIcon)
            }
        } else {
            Image(systemName: "fan")
        }
    }

    /// The last ten minutes of the chosen reading, for the graph.
    private var graphValues: [Double] {
        let start = Date.now.addingTimeInterval(-600)
        return monitor.history.filter { $0.date >= start }.compactMap { sample in
            switch source {
            case .gpu: return sample.gpu
            case .cpu: return sample.cpu
            default: return [sample.cpu, sample.gpu].compactMap { $0 }.max()
            }
        }
    }

    private var rendered: NSImage {
        let view = HStack(spacing: 3) {
            if !compact {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
            }
            if graph {
                Sparkline(values: graphValues)
                    .stroke(colored ? AnyShapeStyle(Color.temperature(temperature ?? 0)) : AnyShapeStyle(.black),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 26, height: 12)
            }
            // Only the temperature takes the colour; a red fan speed would say nothing.
            if content != .fanSpeed, let temperatureText {
                Text(temperatureText)
                    .foregroundStyle(colored ? AnyShapeStyle(Color.temperature(temperature ?? 0)) : AnyShapeStyle(.black))
            }
            if content == .both, temperatureText != nil, fanText != nil {
                Text("·")
            }
            if content != .temperature, let fanText {
                Text(fanText)
            }
        }
        .font(.system(size: 13, weight: .medium).monospacedDigit())
        .foregroundStyle(colored ? AnyShapeStyle(.primary) : AnyShapeStyle(.black))
        .padding(.vertical, 2)
        // The status bar follows the appearance of what's behind it; the app's
        // appearance is the nearest available guess for the parts not coloured.
        .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)

        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        // Without colour it stays a template, so macOS tints it like any other item.
        image.isTemplate = !colored
        return image
    }
}

/// A line through `values`, scaled to fill the frame.
struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, let low = values.min(), let high = values.max() else {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
        let span = max(high - low, 2)
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1),
                                y: rect.maxY - rect.height * CGFloat((value - low) / span))
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

struct MenuBarView: View {
    @Environment(HardwareMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("CPU", symbol: "cpu", summary: monitor.cpuSummary)
            row("GPU", symbol: "square.stack.3d.up", summary: monitor.gpuSummary)
            ThermalStateBadge(state: monitor.thermalState)
            ForEach(monitor.fans) { fan in
                LabeledContent {
                    Text(fan.isManual ? "\(fan.actual.rpm) · manual" : fan.actual.rpm)
                        .monospacedDigit()
                } label: {
                    Label(fan.title, systemImage: "fan")
                }
            }

            Divider()

            if monitor.helperState == .ready {
                ProfilePicker()
                Divider()
                Button("Set All Fans to Max") { monitor.setAllMax() }
                if !monitor.fans.allSatisfy(\.isSystemControlled) {
                    Button("Reset Fans to Automatic") { monitor.setAllAutomatic() }
                }
            }
            Button("Open ThermoTune…") {
                openWindow(id: ThermoTuneApp.mainWindowID)
                NSApp.activate()
            }
            SettingsLink { Text("Preferences…") }
                .keyboardShortcut(",")
            Button("Quit ThermoTune") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .padding(12)
        .frame(width: 260)
    }

    private func row(_ title: String, symbol: String, summary: TemperatureSummary?) -> some View {
        LabeledContent {
            if let summary {
                Text("\(summary.maximum.degrees) max · \(summary.average.degrees) avg")
                    .monospacedDigit()
                    .foregroundStyle(Color.temperature(summary.maximum))
            } else {
                Text("–")
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}
