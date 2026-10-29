import SwiftUI

struct MenuBarSettings: View {
    @Environment(HardwareMonitor.self) private var monitor
    @AppStorage(PreferenceKey.showMenuBarExtra) private var showMenuBar = true
    @AppStorage(PreferenceKey.hideDockIcon) private var hideDockIcon = false
    @AppStorage(PreferenceKey.menuBarContent) private var content: MenuBarContent = .temperature
    @AppStorage(PreferenceKey.menuBarSource) private var source: SensorSource = .cpu
    @AppStorage(PreferenceKey.menuBarUsesAverage) private var usesAverage = false
    @AppStorage(PreferenceKey.menuBarColored) private var colored = false
    @AppStorage(PreferenceKey.menuBarGraph) private var graph = false
    @AppStorage(PreferenceKey.menuBarCompact) private var compact = false

    private var showsTemperature: Bool { content == .temperature || content == .both }

    var body: some View {
        Form {
            Section {
                Toggle("Show ThermoTune in the menu bar", isOn: $showMenuBar)
                    .disabled(hideDockIcon)
                Toggle("Hide ThermoTune from the Dock", isOn: $hideDockIcon)
            } footer: {
                Text(hideDockIcon
                     ? "ThermoTune runs from the menu bar only. Open its window and Settings from the menu bar item."
                     : "With ThermoTune in the menu bar, closing its window keeps it running there.")
            }

            Section {
                LabeledContent("Preview") {
                    MenuBarLabel()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
                Picker("Show", selection: $content) {
                    ForEach(MenuBarContent.allCases) { Text($0.title).tag($0) }
                }
                Group {
                    Picker("Temperature", selection: $source) {
                        ForEach(SensorSource.groups) { Text($0.title).tag($0) }
                    }
                    Picker("Reading", selection: $usesAverage) {
                        Text("Hottest sensor").tag(false)
                        Text("Average").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(!showsTemperature)
                Group {
                    Toggle("Color by temperature", isOn: $colored)
                    Toggle("Show a graph of the last 10 minutes", isOn: $graph)
                    Toggle("Compact", isOn: $compact)
                }
                .disabled(content == .icon)
            } header: {
                Text("Menu Bar Item")
            }
            .disabled(!showMenuBar)
        }
        .formStyle(.grouped)
        .frame(height: 500)
        .onChange(of: hideDockIcon) {
            if hideDockIcon { showMenuBar = true }
            DockIcon.apply()
        }
    }
}

/// Menu-bar-only mode: an accessory app has no Dock icon and no app menu.
enum DockIcon {
    static func apply() {
        let hidden = UserDefaults.standard.bool(forKey: PreferenceKey.hideDockIcon)
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
        if !hidden { NSApp.activate() }
    }
}
