import SwiftUI

struct MenuBarLabel: View {
    @Environment(HardwareMonitor.self) private var monitor
    @AppStorage(PreferenceKey.menuBarSource) private var source: SensorSource = .cpu

    var body: some View {
        if let temperature = monitor.temperature(source) {
            Label(temperature.degrees, systemImage: "thermometer.medium")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "fan")
        }
    }
}

struct MenuBarView: View {
    @Environment(HardwareMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("CPU", symbol: "cpu", summary: monitor.cpuSummary)
            row("GPU", symbol: "square.stack.3d.up", summary: monitor.gpuSummary)
            ForEach(monitor.fans) { fan in
                LabeledContent {
                    Text(fan.isManual ? "\(fan.actual.rpm) · manual" : fan.actual.rpm)
                        .monospacedDigit()
                } label: {
                    Label(fan.name, systemImage: "fan")
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
