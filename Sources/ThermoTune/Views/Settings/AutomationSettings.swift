import SwiftUI
import UniformTypeIdentifiers

struct AutomationSettings: View {
    @Environment(HardwareMonitor.self) private var monitor
    @State private var isChoosingApp = false

    private var rules: ProfileRules { monitor.rules }
    private var profiles: [FanProfile] { monitor.profiles.profiles }

    var body: some View {
        @Bindable var rules = rules
        Form {
            Section {
                Toggle("Switch profiles automatically", isOn: $rules.isEnabled)
                ForEach($rules.rules) { $rule in
                    RuleRow(rule: $rule, profiles: profiles,
                            isMatched: rules.isEnabled && rules.matchedRuleID == rule.id,
                            move: { move(rule.id, by: $0) },
                            delete: { rules.rules.removeAll { $0.id == rule.id } })
                }
                .disabled(!rules.isEnabled)
                Picker("When no rule matches", selection: $rules.fallbackProfileID) {
                    Text("Leave as it is").tag(UUID?.none)
                    Divider()
                    ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                .disabled(!rules.isEnabled)
                Menu("Add Rule") {
                    Button("On Battery") { add(.onBattery) }
                    Button("On Power Adapter") { add(.onPowerAdapter) }
                    Button("While an App Is Running…") { isChoosingApp = true }
                    Button("When a Temperature Is High") { add(.temperatureAbove(source: .hottest, limit: 80)) }
                }
                .fixedSize()
                .disabled(!rules.isEnabled)
            } header: {
                Text("Rules")
            } footer: {
                Text("The first rule that matches picks the profile. A rule only switches when what matches changes, so a profile you pick by hand stays until then.")
            }

            Section {
                ShortcutRow(title: "Set All Fans to Max", action: .allMax)
                ShortcutRow(title: "Hand All Fans to macOS", action: .allAutomatic)
                ForEach(profiles) { profile in
                    ShortcutRow(title: "Use \(profile.name)", action: .profile(profile.id))
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("These work from any app. Use at least one of ⌘, ⌥ or ⌃.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .fileImporter(isPresented: $isChoosingApp, allowedContentTypes: [.application]) { result in
            guard let url = try? result.get(), let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            add(.appRunning(bundleID: id, name: name))
        }
    }

    private func add(_ condition: ProfileRule.Condition) {
        rules.rules.append(ProfileRule(condition: condition, profileID: profiles.first?.id))
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = rules.rules.firstIndex(where: { $0.id == id }),
              rules.rules.indices.contains(index + offset) else { return }
        rules.rules.swapAt(index, index + offset)
    }
}

private struct RuleRow: View {
    @Binding var rule: ProfileRule
    let profiles: [FanProfile]
    let isMatched: Bool
    let move: (Int) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Enabled", isOn: $rule.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
            condition
            Spacer()
            if isMatched {
                Text("Active").font(.caption).foregroundStyle(.tint)
            }
            Picker("Use", selection: $rule.profileID) {
                Text("None").tag(UUID?.none)
                Divider()
                ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .fixedSize()
            Menu {
                Button("Move Up") { move(-1) }
                Button("Move Down") { move(1) }
                Divider()
                Button("Delete Rule", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder private var condition: some View {
        if case .temperatureAbove(let source, let limit) = rule.condition {
            HStack(spacing: 6) {
                Picker("Temperature", selection: Binding(
                    get: { source },
                    set: { rule.condition = .temperatureAbove(source: $0, limit: limit) }
                )) {
                    ForEach(SensorSource.groups) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Text("at \(limit.degrees) or more").monospacedDigit()
                Stepper("Limit", value: Binding(
                    get: { limit },
                    set: { rule.condition = .temperatureAbove(source: source, limit: $0) }
                ), in: 40...105, step: 5)
                .labelsHidden()
            }
        } else {
            Text(rule.condition.title)
        }
    }
}

/// Click, then press a key combination; Esc cancels and Delete clears.
private struct ShortcutRow: View {
    let title: LocalizedStringKey
    let action: ShortcutAction
    @Environment(HardwareMonitor.self) private var monitor
    @State private var isRecording = false
    @State private var monitorToken: Any?

    private var shortcut: Shortcut? { monitor.hotKeys.shortcut(for: action) }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                if monitor.hotKeys.failed.contains(action.storageKey) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("macOS didn't accept this shortcut; another app may already use it.")
                }
                Button {
                    isRecording ? stopRecording() : startRecording()
                } label: {
                    if isRecording {
                        Text("Type shortcut…")
                    } else if let shortcut {
                        Text(verbatim: shortcut.title)
                    } else {
                        Text("Record Shortcut")
                    }
                }
                .monospacedDigit()
                if shortcut != nil, !isRecording {
                    Button {
                        monitor.hotKeys.set(nil, for: action)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove shortcut")
                }
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        // Otherwise typing a combination that is already set runs its action,
        // since Carbon takes the key before this monitor sees it.
        monitor.hotKeys.unregisterAll()
        monitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case 53: // Esc
                stopRecording()
            case 51, 117: // Delete, Forward Delete
                monitor.hotKeys.set(nil, for: action)
                stopRecording()
            default:
                guard !flags.intersection([.command, .option, .control]).isEmpty,
                      let key = event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
                monitor.hotKeys.set(Shortcut(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue, key: key),
                                    for: action)
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitorToken { NSEvent.removeMonitor(monitorToken) }
        monitorToken = nil
        monitor.hotKeys.registerAll()
    }
}
