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
                            Image(systemName: profile.symbol)
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
                        if let selection {
                            store.delete(selection)
                            monitor.rules.profileDeleted(selection)
                            monitor.hotKeys.prune(profileIDs: Set(store.profiles.map(\.id)))
                        }
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
                            let old = store.profiles.map(\.id)
                            store.restoreDefaults()
                            old.forEach(monitor.rules.profileDeleted)
                            monitor.hotKeys.prune(profileIDs: Set(store.profiles.map(\.id)))
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
        .frame(height: 580)
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
    /// The fan being edited when fans have their own settings.
    @State private var fanIndex = 0

    private var isActive: Bool { monitor.profiles.activeProfileID == profile.id }
    private var fans: [FanInfo] { monitor.fans }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name)
                if fans.count > 1 {
                    Toggle("Different settings for each fan", isOn: perFanBinding)
                }
            } footer: {
                if profile.isPerFan {
                    Text("System Automatic isn't available per fan: while any fan is under manual control, macOS stops managing all of them.")
                }
            }

            if profile.isPerFan {
                Section {
                    Picker("Fan", selection: $fanIndex) {
                        ForEach(fans) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                }
                BehaviorEditor(behavior: perFanBehavior(fanIndex), kinds: FanBehavior.perFanKinds,
                               fan: fans.first { $0.id == fanIndex })
                    .id(fanIndex)
            } else {
                BehaviorEditor(behavior: $profile.behavior, kinds: FanProfile.Kind.allCases, fan: fans.first)
            }

            Section {
                HStack {
                    if monitor.helperState != .ready, profile.isPerFan || profile.behavior.kind != .automatic {
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
        .onAppear { fanIndex = fans.first?.id ?? 0 }
    }

    private var perFanBinding: Binding<Bool> {
        Binding(
            get: { profile.isPerFan },
            set: { enabled in
                guard enabled else {
                    profile.perFan = [:]
                    return
                }
                // Start every fan from the shared settings, swapping Automatic
                // for a curve since it can't be set per fan.
                var start = profile.behavior
                if !FanBehavior.perFanKinds.contains(start.kind) { start.kind = .curve }
                profile.perFan = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, start) })
            }
        )
    }

    private func perFanBehavior(_ index: Int) -> Binding<FanBehavior> {
        Binding(
            get: { profile.perFan[index] ?? profile.behavior },
            set: { profile.perFan[index] = $0 }
        )
    }
}

/// The settings of one behaviour: its kind, and the speed or curve that goes with it.
private struct BehaviorEditor: View {
    @Binding var behavior: FanBehavior
    let kinds: [FanProfile.Kind]
    /// The fan shown in RPM previews.
    let fan: FanInfo?
    @Environment(HardwareMonitor.self) private var monitor

    private var summary: String {
        switch behavior.kind {
        case .automatic: return "macOS manages the fans, as if ThermoTune weren't running."
        case .fixed: return "The fan runs at a constant share of its speed range."
        case .curve: return "The fan follows the curve as the chosen temperature changes. Drag the points, or double-click the chart to add one."
        case .max: return "The fan runs at its maximum speed."
        }
    }

    var body: some View {
        Section {
            Picker("Behavior", selection: $behavior.kind) {
                ForEach(kinds) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
        } footer: {
            Text(summary)
        }

        switch behavior.kind {
        case .fixed:
            Section("Speed") {
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $behavior.fixedPercent, in: 0...100, step: 5)
                        Text("\(Int(behavior.fixedPercent))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                if let fan, let rpm = behavior.targetRPM(for: fan, temperature: nil) {
                    LabeledContent("Fan speed", value: "\(Int(rpm)) RPM")
                }
            }
        case .curve:
            Section("Curve") {
                SourcePicker(source: $behavior.source)
                CurveEditor(curve: $behavior.curve,
                            current: monitor.temperature(behavior.source),
                            behavior: behavior, fan: fan)
            }
        case .automatic, .max:
            EmptyView()
        }
    }
}

/// CPU, GPU or the hottest of the two, or any single sensor.
private struct SourcePicker: View {
    @Binding var source: SensorSource
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        Picker("Follow", selection: $source) {
            ForEach(SensorSource.groups) { Text($0.title).tag($0) }
            Divider()
            ForEach(TemperatureSensor.Group.allCases, id: \.self) { group in
                let sensors = monitor.sensors.filter { $0.group == group }
                if !sensors.isEmpty {
                    Menu(group.rawValue) {
                        ForEach(sensors) { sensor in
                            Text("\(sensor.key) · \(sensor.value.degrees)").tag(SensorSource.sensor(sensor.key))
                        }
                    }
                }
            }
            // A saved sensor that isn't reading right now still needs a tag to show.
            if case .sensor(let key) = source, !monitor.sensors.contains(where: { $0.key == key }) {
                Text("\(key) (no reading)").tag(source)
            }
        }
    }
}

/// A temperature curve: drag points to move them, double-click to add one,
/// select one and press Remove to delete it. The rows below edit the same
/// points precisely.
private struct CurveEditor: View {
    @Binding var curve: [CurvePoint]
    let current: Double?
    let behavior: FanBehavior
    let fan: FanInfo?

    @State private var selected: Int?
    @State private var dragging: Int?

    private var unit: TemperatureUnit { .current }
    /// The editable range, in °C.
    private static let temperatures: ClosedRange<Double> = 20...110
    /// Points keep at least this far apart, so the curve stays a function.
    private static let minimumGap: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            chart
            pointRows
            HStack {
                Button("Add Point") { addPoint(near: nil) }
                Button("Remove Point") {
                    if let selected { removePoint(selected) }
                }
                .disabled(selected == nil || curve.count <= 2)
                Spacer()
                if let current, let fan, let rpm = behavior.targetRPM(for: fan, temperature: current) {
                    Text("Now \(current.degrees) → \(Int(rpm)) RPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var chart: some View {
        Chart {
            ForEach(Array(extended.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Temperature", unit.convert(point.temperature)),
                         y: .value("Fan speed", point.percent))
                AreaMark(x: .value("Temperature", unit.convert(point.temperature)),
                         y: .value("Fan speed", point.percent))
                    .foregroundStyle(.tint.opacity(0.12))
            }
            ForEach(Array(curve.enumerated()), id: \.offset) { index, point in
                PointMark(x: .value("Temperature", unit.convert(point.temperature)),
                          y: .value("Fan speed", point.percent))
                    .symbolSize(index == selected ? 140 : 70)
                    .foregroundStyle(index == selected ? Color.accentColor : Color.primary)
            }
            if let current, let fraction = behavior.speedFraction(at: current) {
                RuleMark(x: .value("Now", unit.convert(current)))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("Now", unit.convert(current)),
                          y: .value("Fan speed", fraction * 100))
                    .foregroundStyle(Color.temperature(current))
            }
        }
        .chartXScale(domain: unit.convert(Self.temperatures.lowerBound)...unit.convert(Self.temperatures.upperBound))
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)°") }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                guard let frame = proxy.plotFrame.map({ geometry[$0] }) else { return }
                                let location = CGPoint(x: drag.location.x - frame.minX, y: drag.location.y - frame.minY)
                                if dragging == nil {
                                    dragging = nearestPoint(to: location, proxy: proxy)
                                    selected = dragging
                                }
                                if let dragging, let value = value(at: location, proxy: proxy) {
                                    move(dragging, to: value)
                                }
                            }
                            .onEnded { _ in dragging = nil }
                    )
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2).onEnded { tap in
                            guard let frame = proxy.plotFrame.map({ geometry[$0] }) else { return }
                            let location = CGPoint(x: tap.location.x - frame.minX, y: tap.location.y - frame.minY)
                            if let value = value(at: location, proxy: proxy) { addPoint(near: value) }
                        }
                    )
            }
        }
        .frame(height: 150)
        .accessibilityLabel("Fan curve")
        .accessibilityValue(curve.map { "\(Int($0.percent))% at \($0.temperature.degrees)" }.joined(separator: ", "))
    }

    /// The curve with flat lines out to the chart's edges, as the fan behaves.
    private var extended: [CurvePoint] {
        guard let first = curve.first, let last = curve.last else { return [] }
        return [CurvePoint(Self.temperatures.lowerBound, first.percent)] + curve
            + [CurvePoint(Self.temperatures.upperBound, last.percent)]
    }

    private var pointRows: some View {
        VStack(spacing: 4) {
            ForEach(curve.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Image(systemName: index == selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(index == selected ? Color.accentColor : .secondary)
                        .onTapGesture { selected = index }
                    Text(curve[index].temperature.degrees)
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                    Stepper("Temperature", value: temperatureBinding(index), in: Self.temperatures, step: 1)
                        .labelsHidden()
                    Text("→").foregroundStyle(.secondary).padding(.horizontal, 6)
                    Text("\(Int(curve[index].percent))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                    Stepper("Fan speed", value: percentBinding(index), in: 0...100, step: 5)
                        .labelsHidden()
                    Spacer()
                }
                .font(.callout)
            }
        }
    }

    private func temperatureBinding(_ index: Int) -> Binding<Double> {
        Binding(get: { curve[index].temperature },
                set: { move(index, to: CurvePoint($0, curve[index].percent)) })
    }

    private func percentBinding(_ index: Int) -> Binding<Double> {
        Binding(get: { curve[index].percent },
                set: { move(index, to: CurvePoint(curve[index].temperature, $0)) })
    }

    /// Moves a point, keeping it between its neighbours so the order never changes.
    private func move(_ index: Int, to point: CurvePoint) {
        guard curve.indices.contains(index) else { return }
        let low = index > 0 ? curve[index - 1].temperature + Self.minimumGap : Self.temperatures.lowerBound
        let high = index < curve.count - 1 ? curve[index + 1].temperature - Self.minimumGap : Self.temperatures.upperBound
        curve[index] = CurvePoint(min(max(point.temperature.rounded(), low), high),
                                  min(max(point.percent.rounded(), 0), 100))
    }

    /// Adds a point at `value`, or halfway along the widest gap when there's none.
    private func addPoint(near value: CurvePoint?) {
        var point = value ?? {
            let gaps = zip(curve, curve.dropFirst()).enumerated().max {
                ($0.element.1.temperature - $0.element.0.temperature) < ($1.element.1.temperature - $1.element.0.temperature)
            }
            guard let (a, b) = gaps?.element else { return CurvePoint(70, 50) }
            return CurvePoint(((a.temperature + b.temperature) / 2).rounded(), ((a.percent + b.percent) / 2).rounded())
        }()
        point.temperature = point.temperature.rounded()
        guard !curve.contains(where: { abs($0.temperature - point.temperature) < Self.minimumGap }) else { return }
        let index = curve.firstIndex { $0.temperature > point.temperature } ?? curve.count
        curve.insert(CurvePoint(point.temperature, min(max(point.percent.rounded(), 0), 100)), at: index)
        selected = index
    }

    private func removePoint(_ index: Int) {
        guard curve.count > 2, curve.indices.contains(index) else { return }
        curve.remove(at: index)
        selected = nil
    }

    private func value(at location: CGPoint, proxy: ChartProxy) -> CurvePoint? {
        guard let (temperature, percent) = proxy.value(at: location, as: (Double, Double).self) else { return nil }
        return CurvePoint(unit.toCelsius(temperature), percent)
    }

    /// The point within 14 pt of `location`, if any.
    private func nearestPoint(to location: CGPoint, proxy: ChartProxy) -> Int? {
        curve.indices
            .compactMap { index -> (Int, CGFloat)? in
                guard let position = proxy.position(for: (unit.convert(curve[index].temperature), curve[index].percent))
                else { return nil }
                return (index, hypot(position.x - location.x, position.y - location.y))
            }
            .filter { $0.1 <= 14 }
            .min { $0.1 < $1.1 }?
            .0
    }
}
