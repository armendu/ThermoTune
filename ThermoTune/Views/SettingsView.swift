import Charts
import ServiceManagement
import SwiftUI

/// Which tab Settings shows. Stored only so menu items in other scenes (About,
/// Edit Profiles…) can pick the tab before opening Settings; it is reset to
/// General whenever Settings closes, so plain ⌘, always lands on General.
enum SettingsTab: String {
    case general, profiles, helper, about
    static let storageKey = "settingsTab"

    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

/// Opens Settings on a given tab, for menu items and buttons outside Settings.
struct SettingsTabButton: View {
    let title: String
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
            HelperSettings()
                .tabItem { Label("Helper", systemImage: "lock.shield") }
                .tag(SettingsTab.helper)
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 640)
        .onDisappear(perform: SettingsTab.reset)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(HardwareMonitor.self) private var monitor
    @AppStorage(PreferenceKey.temperatureUnit) private var unit: TemperatureUnit = .celsius
    @AppStorage(PreferenceKey.refreshInterval) private var refreshInterval = 2.0
    @AppStorage(PreferenceKey.restoreAutomaticOnQuit) private var restoreOnQuit = true
    @AppStorage(PreferenceKey.showMenuBarExtra) private var showMenuBar = true
    @AppStorage(PreferenceKey.menuBarSource) private var menuBarSource: SensorSource = .cpu
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

            Section("Menu Bar") {
                Toggle("Show ThermoTune in the menu bar", isOn: $showMenuBar)
                Picker("Temperature shown", selection: $menuBarSource) {
                    ForEach(SensorSource.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!showMenuBar)
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

// MARK: - Profiles

private struct ProfilesSettings: View {
    @Environment(HardwareMonitor.self) private var monitor
    @State private var selection: UUID?

    private var store: ProfileStore { monitor.profiles }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.profiles) { profile in
                        HStack {
                            Image(systemName: profile.kind.symbol)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(profile.name)
                            Spacer()
                            if profile.id == store.activeProfileID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .help("Active profile")
                            }
                        }
                        .tag(profile.id)
                    }
                    .onMove { store.profiles.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack(spacing: 2) {
                    Button {
                        selection = store.add().id
                    } label: {
                        Image(systemName: "plus").frame(width: 22, height: 18)
                    }
                    .help("New profile")
                    Button {
                        if let selection { store.delete(selection) }
                        selection = store.profiles.first?.id
                    } label: {
                        Image(systemName: "minus").frame(width: 22, height: 18)
                    }
                    .help("Delete profile")
                    .disabled(selection == nil)
                    Spacer()
                    Menu {
                        Button("Duplicate") {
                            if let profile = store.profiles.first(where: { $0.id == selection }) {
                                selection = store.duplicate(profile).id
                            }
                        }
                        .disabled(selection == nil)
                        Divider()
                        Button("Restore Default Profiles") {
                            store.restoreDefaults()
                            selection = store.profiles.first?.id
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 210)

            Divider()

            if let index = store.profiles.firstIndex(where: { $0.id == selection }) {
                ProfileEditor(profile: Bindable(store).profiles[index])
                    .id(store.profiles[index].id)
            } else {
                ContentUnavailableView("No Profile Selected", systemImage: "slider.horizontal.3",
                                       description: Text("Select a profile, or click + to create one."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 460)
        .onAppear {
            selection = selection ?? store.activeProfileID ?? store.profiles.first?.id
        }
    }
}

private struct ProfileEditor: View {
    @Binding var profile: FanProfile
    @Environment(HardwareMonitor.self) private var monitor

    private var isActive: Bool { monitor.profiles.activeProfileID == profile.id }

    private var summary: String {
        switch profile.kind {
        case .automatic: return "macOS manages the fans, as if ThermoTune weren't running."
        case .fixed: return "Every fan runs at a constant share of its speed range."
        case .curve: return "Fans speed up as the chosen temperature rises: minimum speed at the low point, full speed at the high point."
        case .max: return "Every fan runs at its maximum speed."
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name)
                Picker("Behavior", selection: $profile.kind) {
                    ForEach(FanProfile.Kind.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(kind)
                    }
                }
            } footer: {
                Text(summary)
            }

            switch profile.kind {
            case .fixed:
                Section("Speed") {
                    LabeledContent("Speed") {
                        HStack {
                            Slider(value: $profile.fixedPercent, in: 0...100, step: 5)
                            Text("\(Int(profile.fixedPercent))%")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    if let fan = monitor.fans.first, let rpm = profile.targetRPM(for: fan, temperature: nil) {
                        LabeledContent("Fan speed", value: rpm.rpm)
                    }
                }
            case .curve:
                Section("Curve") {
                    Picker("Follow", selection: $profile.source) {
                        ForEach(SensorSource.allCases) { Text($0.title).tag($0) }
                    }
                    TemperatureSlider(title: "Minimum speed up to", value: $profile.lowTemperature, range: 30...95)
                    TemperatureSlider(title: "Full speed from", value: $profile.highTemperature, range: 40...105)
                    CurvePreview(profile: profile,
                                 current: monitor.temperature(profile.source),
                                 fan: monitor.fans.first)
                }
            case .automatic, .max:
                EmptyView()
            }

            Section {
                HStack {
                    if monitor.helperState != .ready, profile.kind != .automatic {
                        Text("Install the helper (Helper tab) to use profiles.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isActive {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    } else {
                        Button("Use This Profile") { monitor.activate(profile) }
                            .disabled(!monitor.canControlFans)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: profile.lowTemperature) {
            if profile.highTemperature < profile.lowTemperature + 5 {
                profile.highTemperature = profile.lowTemperature + 5
            }
        }
        .onChange(of: profile.highTemperature) {
            if profile.lowTemperature > profile.highTemperature - 5 {
                profile.lowTemperature = profile.highTemperature - 5
            }
        }
    }
}

private struct TemperatureSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: 1)
                Text(value.degrees)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

private struct CurvePreview: View {
    let profile: FanProfile
    let current: Double?
    let fan: FanInfo?

    private struct Point: Identifiable {
        let id = UUID()
        let temperature: Double
        let percent: Double
    }

    private var unit: TemperatureUnit { .current }

    private var points: [Point] {
        let low = profile.lowTemperature, high = profile.highTemperature
        return [(min(low - 10, 30), 0), (low, 0), (high, 100), (max(high + 10, 105), 100)]
            .map { Point(temperature: unit.convert($0.0), percent: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Temperature", point.temperature),
                             y: .value("Fan speed", point.percent))
                    AreaMark(x: .value("Temperature", point.temperature),
                             y: .value("Fan speed", point.percent))
                        .foregroundStyle(.tint.opacity(0.12))
                }
                if let current, let fraction = profile.speedFraction(at: current) {
                    RuleMark(x: .value("Now", unit.convert(current)))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value("Now", unit.convert(current)),
                              y: .value("Fan speed", fraction * 100))
                        .foregroundStyle(Color.temperature(current))
                }
            }
            .chartXScale(domain: (points.first?.temperature ?? 0)...(points.last?.temperature ?? 100))
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                }
            }
            .chartXAxisLabel(unit.symbol)
            .frame(height: 110)

            if let current, let fan, let rpm = profile.targetRPM(for: fan, temperature: current) {
                Text("Now \(current.degrees) → \(rpm.rpm)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Helper

private struct HelperSettings: View {
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    switch monitor.helperState {
                    case .ready:
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .needsUpdate:
                        Label("Out of date", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case .notInstalled:
                        Label("Not installed", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Location") {
                    Text(HelperInstaller.installURL.path)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            } footer: {
                Text("Reading temperatures needs no special access, but changing fan speed does. The helper is a small tool that only changes fan settings. Installing it asks for your administrator password once.")
            }

            Section {
                HStack {
                    Spacer()
                    if monitor.helperState != .ready {
                        HelperInstallButton()
                    }
                    Button("Uninstall Helper…", role: .destructive) {
                        monitor.uninstallHelper()
                    }
                    .disabled(monitor.helperState == .notInstalled || monitor.isChangingHelper)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }
}

/// Install or Update, whichever the helper needs.
struct HelperInstallButton: View {
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        Button(monitor.helperState == .notInstalled ? "Install Helper…" : "Update Helper…") {
            monitor.installHelper()
        }
        .disabled(monitor.isChangingHelper)
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
                        .frame(width: 64, height: 64)
                        .overlay {
                            Image(systemName: "fan.fill")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppInfo.name)
                            .font(.title2.weight(.semibold))
                        Text(AppInfo.version)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("See your Mac's temperatures and control its fans.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Created by") {
                    Link(AppInfo.creator, destination: AppInfo.creatorURL)
                }
                LabeledContent("License") {
                    Link(AppInfo.licenseName, destination: AppInfo.licenseURL)
                }
                LabeledContent("Source code") {
                    Link("github.com/armendu/ThermoTune", destination: AppInfo.repositoryURL)
                }
            } footer: {
                Text("ThermoTune is free and open source. Bug reports, pull requests and reports of which Macs it works on are all welcome.")
            }

            Section {
                HStack {
                    Link("Report an Issue…", destination: AppInfo.issuesURL)
                    Spacer()
                    Link("Security Policy", destination: AppInfo.securityURL)
                }
            } footer: {
                Text("\(AppInfo.copyright) Not affiliated with Apple.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
    }
}
