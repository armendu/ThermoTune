import SwiftUI

struct MenuBarSettings: View {
    @AppStorage(PreferenceKey.showMenuBarExtra) private var showMenuBar = true
    @AppStorage(PreferenceKey.menuBarSource) private var menuBarSource: SensorSource = .cpu

    var body: some View {
        Form {
            Section {
                Toggle("Show ThermoTune in the menu bar", isOn: $showMenuBar)
                Picker("Temperature shown", selection: $menuBarSource) {
                    ForEach(SensorSource.groups) { Text($0.title).tag($0) }
                }
                .disabled(!showMenuBar)
            }
        }
        .formStyle(.grouped)
        .frame(height: 200)
    }
}
