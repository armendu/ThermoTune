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
        return compact ? temperature.degreesNumber + "°" : temperature.degrees
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
        // Read so a change of unit redraws the label straight away, not at the next refresh.
        let _ = unit
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

    /// The last ten minutes of the reading the label shows, for the graph.
    private var graphValues: [Double] {
        let start = Date.now.addingTimeInterval(-600)
        // History is in time order, so only its tail needs looking at.
        return monitor.history.reversed().prefix { $0.date >= start }.reversed().compactMap { sample in
            let cpu = usesAverage ? sample.cpu : sample.cpuMaximum
            let gpu = usesAverage ? sample.gpu : sample.gpuMaximum
            switch source {
            case .cpu: return cpu
            case .gpu: return gpu
            default: return [cpu, gpu].compactMap { $0 }.max()
            }
        }
    }

    /// The last image drawn, keyed by everything that went into it. With colour
    /// on and no graph, most refreshes change nothing worth drawing again.
    @MainActor private static var cache: (key: String, image: NSImage)?

    private var rendered: NSImage {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let values = graph ? graphValues : []
        let key = [temperatureText ?? "", fanText ?? "", "\(content)", "\(unit)", "\(colored)", "\(graph)", "\(compact)", "\(isDark)",
                   values.map { String(Int($0.rounded())) }.joined(separator: ",")].joined(separator: "|")
        if let cache = Self.cache, cache.key == key { return cache.image }
        let image = render(values: values, isDark: isDark)
        Self.cache = (key, image)
        return image
    }

    private func render(values: [Double], isDark: Bool) -> NSImage {
        let view = HStack(spacing: 3) {
            if !compact {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
            }
            if graph {
                Sparkline(values: values)
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
        .environment(\.colorScheme, isDark ? .dark : .light)

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
            row(.cpu)
            row(.gpu)
            ThermalStateBadge(state: monitor.thermalState)
            ForEach(monitor.fans) { fan in
                LabeledContent {
                    Text(fan.isSystemControlled ? fan.actual.rpm : "\(fan.actual.rpm) · manual")
                        .monospacedDigit()
                } label: {
                    Label(fan.title, systemImage: "fan")
                }
            }

            Divider()

            if monitor.helperState == .ready {
                Group {
                    ProfilePicker()
                    Divider()
                    Button("Set All Fans to Max") { monitor.setAllMax() }
                        .disabled(monitor.fans.allSatisfy { monitor.mode(of: $0) == .max })
                    if !monitor.fansAreSystemControlled {
                        Button("Hand All Fans to macOS") { monitor.setAllAutomatic() }
                    }
                }
                .disabled(!monitor.canControlFans)
            }
            Button("Open ThermoTune") {
                openWindow(id: ThermoTuneApp.mainWindowID)
                NSApp.activate()
            }
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Button("Quit ThermoTune") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .padding(12)
        .frame(width: 260)
    }

    private func row(_ source: SensorSource) -> some View {
        LabeledContent {
            if let summary = monitor.summary(source) {
                Text("\(summary.maximum.degrees) max · \(summary.average.degrees) avg")
                    .monospacedDigit()
                    .foregroundStyle(Color.temperature(summary.maximum))
            } else {
                Text("–")
            }
        } label: {
            Label(source.title, systemImage: source.symbol)
        }
    }
}
