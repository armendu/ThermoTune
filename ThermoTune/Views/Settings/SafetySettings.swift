import SwiftUI
import UserNotifications

struct SafetySettings: View {
    @Environment(HardwareMonitor.self) private var monitor
    @AppStorage(PreferenceKey.safetyNetEnabled) private var safetyEnabled = true
    @AppStorage(PreferenceKey.safetyLimit) private var safetyLimit = 95.0
    @AppStorage(PreferenceKey.safetyDelay) private var safetyDelay = 10.0
    @AppStorage(PreferenceKey.safetyAction) private var safetyAction: SafetyAction = .automatic
    @AppStorage(PreferenceKey.alertSafetyNet) private var alertSafetyNet = true
    @AppStorage(PreferenceKey.alertTemperature) private var alertTemperature = false
    @AppStorage(PreferenceKey.alertTemperatureSource) private var temperatureSource: SensorSource = .hottest
    @AppStorage(PreferenceKey.alertTemperatureLimit) private var temperatureLimit = 90.0
    @AppStorage(PreferenceKey.alertTemperatureDuration) private var temperatureDuration = 30.0
    @AppStorage(PreferenceKey.alertFanStall) private var alertFanStall = true
    @AppStorage(PreferenceKey.alertThermalPressure) private var alertThermalPressure = true
    @AppStorage(PreferenceKey.alertHelper) private var alertHelper = true

    private var anyAlertOn: Bool {
        alertSafetyNet || alertTemperature || alertFanStall || alertThermalPressure || alertHelper
    }

    var body: some View {
        Form {
            Section {
                Toggle("Protect against overheating", isOn: $safetyEnabled)
                Group {
                    LabeledContent("When the hottest sensor reaches") {
                        HStack {
                            Slider(value: $safetyLimit, in: 80...105, step: 1)
                            Text(safetyLimit.degrees)
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    Picker("For at least", selection: $safetyDelay) {
                        Text("Any time").tag(0.0)
                        Text("5 seconds").tag(5.0)
                        Text("10 seconds").tag(10.0)
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                    }
                    Picker("Then", selection: $safetyAction) {
                        ForEach(SafetyAction.allCases) { Text($0.title).tag($0) }
                    }
                }
                .disabled(!safetyEnabled)
            } header: {
                Text("Safety Net")
            } footer: {
                Text(safetyEnabled
                     ? "Only acts while ThermoTune is controlling the fans, with a manual speed or a profile. Fans already all at full speed are left alone."
                     : "Manual speeds and profiles will stay where they are, however hot the Mac gets.")
                    .foregroundStyle(safetyEnabled ? .secondary : Color.orange)
            }

            Section {
                if monitor.alerts.authorization == .denied, anyAlertOn {
                    HStack {
                        Label("Notifications are turned off for ThermoTune.", systemImage: "bell.slash")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                Toggle("When the safety net steps in", isOn: $alertSafetyNet)
                Toggle("When a fan isn't spinning", isOn: $alertFanStall)
                Toggle("When macOS slows the Mac to cool it", isOn: $alertThermalPressure)
                Toggle("When the helper needs updating", isOn: $alertHelper)
                Toggle("When a temperature stays high", isOn: $alertTemperature)
                if alertTemperature {
                    Picker("Temperature", selection: $temperatureSource) {
                        ForEach(SensorSource.groups) { Text($0.title).tag($0) }
                    }
                    LabeledContent("At or above") {
                        HStack {
                            Slider(value: $temperatureLimit, in: 60...105, step: 1)
                            Text(temperatureLimit.degrees)
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    Picker("For at least", selection: $temperatureDuration) {
                        Text("10 seconds").tag(10.0)
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                        Text("5 minutes").tag(300.0)
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Each notification is sent once, and again only after the problem has gone away and come back.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .onAppear(perform: monitor.alerts.refreshAuthorization)
        .onChange(of: anyAlertOn) {
            if anyAlertOn, monitor.alerts.authorization == .notDetermined { monitor.alerts.requestAuthorization() }
        }
    }
}
