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
            row(.cpu)
            row(.gpu)
            ForEach(monitor.fans) { fan in
                LabeledContent {
                    Text(fan.isSystemControlled ? fan.actual.rpm : "\(fan.actual.rpm) · manual")
                        .monospacedDigit()
                } label: {
                    Label(fan.name, systemImage: "fan")
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
                        Button("Reset Fans to Automatic") { monitor.setAllAutomatic() }
                    }
                }
                .disabled(!monitor.canControlFans)
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
