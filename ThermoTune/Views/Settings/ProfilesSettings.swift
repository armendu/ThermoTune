import Charts
import SwiftUI
import UniformTypeIdentifiers

struct ProfilesSettings: View {
    @Environment(HardwareMonitor.self) private var monitor
    @State private var selection: UUID?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var transferError: String?

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
                        Button("Export Profiles…") { isExporting = true }
                        Button("Import Profiles…") { isImporting = true }
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
        .fileExporter(isPresented: $isExporting, document: ProfilesDocument(profiles: store.profiles),
                      contentType: .json, defaultFilename: "\(AppInfo.name) Profiles") { result in
            if case .failure(let error) = result { transferError = error.localizedDescription }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                let added = store.importProfiles(try ProfilesDocument(data: Data(contentsOf: url)).profiles)
                selection = added.first?.id ?? selection
            } catch {
                transferError = error.localizedDescription
            }
        }
        .alert("Profiles", isPresented: Binding(get: { transferError != nil },
                                                set: { if !$0 { transferError = nil } })) {
            Button("OK") {}
        } message: {
            Text(transferError ?? "")
        }
    }
}

/// Every profile as one JSON file, to back up or move to another Mac.
private struct ProfilesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    enum ReadError: LocalizedError {
        case unsupported(version: Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupported(let version):
                return "This file was made by a newer version of \(AppInfo.name) (format \(version)). Update \(AppInfo.name) to import it."
            case .empty:
                return "This file has no profiles in it."
            }
        }
    }

    let profiles: [FanProfile]

    init(profiles: [FanProfile]) {
        self.profiles = profiles
    }

    init(data: Data) throws {
        let archive = try JSONDecoder().decode(ProfileArchive.self, from: data)
        guard archive.version <= ProfileArchive.currentVersion else {
            throw ReadError.unsupported(version: archive.version)
        }
        guard !archive.profiles.isEmpty else { throw ReadError.empty }
        profiles = archive.profiles
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        try self.init(data: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(ProfileArchive(profiles: profiles)))
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
                        LabeledContent("Fan speed", value: "\(Int(rpm)) RPM")
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
                        Text("Install the helper (Advanced tab) to use profiles.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isActive {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    } else {
                        Button("Use This Profile") { monitor.activate(profile) }
                            .disabled(monitor.helperState != .ready)
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
                Text("Now \(current.degrees) → \(Int(rpm)) RPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
