import SwiftUI

struct AdvancedSettings: View {
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
            } header: {
                Text("Helper")
            } footer: {
                Text("Reading temperatures needs no special access, but changing fan speed does. The helper is a small tool that only changes fan settings. Installing it asks for your administrator password once.")
            }

            Section {
                HStack {
                    Spacer()
                    if monitor.helperState != .ready {
                        Button(monitor.helperState == .notInstalled ? "Install Helper…" : "Update Helper…") {
                            monitor.installHelper()
                        }
                    }
                    Button("Uninstall Helper…", role: .destructive) {
                        monitor.uninstallHelper()
                    }
                    .disabled(monitor.helperState == .notInstalled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }
}
