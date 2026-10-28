import SwiftUI
import UniformTypeIdentifiers

struct AdvancedSettings: View {
    @Environment(HardwareMonitor.self) private var monitor
    @AppStorage(PreferenceKey.keepsLog) private var keepsLog = false
    @State private var exportedCSV: CSVDocument?

    var body: some View {
        Form {
            Section {
                LabeledContent("Last hour") {
                    Button("Export as CSV…") { exportedCSV = CSVDocument(text: HistoryCSV.document(monitor.history)) }
                        .disabled(monitor.history.isEmpty)
                }
                Toggle("Keep a log file", isOn: $keepsLog)
                if keepsLog {
                    LabeledContent("Saved in") {
                        Button("Show in Finder") {
                            try? FileManager.default.createDirectory(at: HistoryLog.directory, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(HistoryLog.directory)
                        }
                    }
                }
            } header: {
                Text("History")
            } footer: {
                Text("One row per reading: CPU and GPU average and hottest in °C, each fan's speed, thermal pressure and the active profile. The log starts a new file each day.")
            }

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
        .fileExporter(isPresented: Binding(get: { exportedCSV != nil }, set: { if !$0 { exportedCSV = nil } }),
                      document: exportedCSV, contentType: .commaSeparatedText,
                      defaultFilename: "ThermoTune \(Date.now.formatted(.iso8601.year().month().day()))") { _ in }
        .frame(height: 520)
    }
}

private struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
