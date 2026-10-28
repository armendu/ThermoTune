import ServiceManagement
import SwiftUI

struct GeneralSettings: View {
    @Environment(HardwareMonitor.self) private var monitor
    @AppStorage(PreferenceKey.temperatureUnit) private var unit: TemperatureUnit = .celsius
    @AppStorage(PreferenceKey.refreshInterval) private var refreshInterval = 2.0
    @AppStorage(PreferenceKey.restoreAutomaticOnQuit) private var restoreOnQuit = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                Toggle("Restore automatic fan control when quitting", isOn: $restoreOnQuit)
            } footer: {
                if !restoreOnQuit {
                    Text("Manual speeds and profiles keep running after ThermoTune quits, and macOS won't manage the fans until you switch them back to Automatic.")
                        .foregroundStyle(.orange)
                }
            }

            Section("Display") {
                Picker("Temperature unit", selection: $unit) {
                    ForEach(TemperatureUnit.allCases) { Text($0.title).tag($0) }
                }
                Picker("Update readings every", selection: $refreshInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
        .onChange(of: refreshInterval) { monitor.scheduleRefresh() }
        .alert("Launch at Login", isPresented: Binding(get: { loginItemError != nil }, set: { if !$0 { loginItemError = nil } })) {
            Button("OK") {}
        } message: {
            Text(loginItemError ?? "")
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    loginItemError = error.localizedDescription
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        )
    }
}
