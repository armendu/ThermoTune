import SwiftUI

/// Stored only so items outside Settings can pick its tab before opening it; reset
/// when Settings closes, so plain ⌘, always lands on General.
enum SettingsTab: String {
    case general, profiles, automation, safety, menuBar, advanced, about
    static let storageKey = "settingsTab"

    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

struct SettingsTabButton: View {
    let title: LocalizedStringKey
    let tab: SettingsTab
    @AppStorage(SettingsTab.storageKey) private var selectedTab: SettingsTab = .general
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(title) {
            selectedTab = tab
            openSettings()
        }
    }
}

struct SettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ProfilesSettings()
                .tabItem { Label("Profiles", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.profiles)
            AutomationSettings()
                .tabItem { Label("Automation", systemImage: "wand.and.stars") }
                .tag(SettingsTab.automation)
            SafetySettings()
                .tabItem { Label("Safety", systemImage: "exclamationmark.shield") }
                .tag(SettingsTab.safety)
            MenuBarSettings()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
                .tag(SettingsTab.menuBar)
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
                .tag(SettingsTab.advanced)
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 640)
        .onDisappear(perform: SettingsTab.reset)
    }
}
