import Foundation
import Observation

/// Polls the SMC for fan and temperature readings, drives the active fan
/// profile, and forwards fan changes to the privileged helper.
@MainActor
@Observable
final class HardwareMonitor {
    /// One refresh's readings, for the chart and the CSV history. `cpu` and
    /// `gpu` are averages, which is what the chart plots.
    struct Sample: Identifiable {
        let id = UUID()
        let date: Date
        let cpu: Double?
        let gpu: Double?
        var cpuMaximum: Double?
        var gpuMaximum: Double?
        var fanRPMs: [Double] = []
        var thermalState: ProcessInfo.ThermalState = .nominal
        var profile: String?
    }

    private(set) var fans: [FanInfo] = []
    private(set) var sensors: [TemperatureSensor] = []
    private(set) var history: [Sample] = []
    private(set) var isDiscoveringSensors = true
    /// Readable names by SMC key; see `TemperatureSensor.names(for:)`.
    private(set) var sensorNames: [String: String] = [:]
    private(set) var helperState = HelperInstaller.state()
    /// An install or uninstall is waiting on the password prompt.
    private(set) var isChangingHelper = false
    /// An uninstall is under way. Fan changes are held off meanwhile: one landing
    /// after its final `auto-all` would leave a fan manual with no helper left to
    /// undo it. An install needs no such gate, because the new helper replaces
    /// the old one in a single rename: a call already running finishes with the
    /// old one, and the profile and safety net keep working behind the prompt.
    private(set) var isRemovingHelper = false
    private(set) var busyFans: Set<Int> = []
    private(set) var pendingModes: [Int: FanMode] = [:]
    var errorMessage: String?

    var canControlFans: Bool { helperState == .ready && !isRemovingHelper }
    var fansAreSystemControlled: Bool { fans.allSatisfy(\.isSystemControlled) }
    /// Counting a mode just asked for, so All Max disables as soon as it's clicked.
    var allFansAtMax: Bool { fans.allSatisfy { mode(of: $0) == .max } }
    /// The fastest fan's speed, which the overview and the menu bar show.
    var fastestFanRPM: Double? { fans.map(\.actual).max() }

    /// Per-core sensors when the Mac has them (Apple Silicon). The `TC*` package
    /// sensors there read well above the cores even at idle, so they would skew
    /// the CPU reading and temperature-curve profiles.
    var cpuSensors: [TemperatureSensor] {
        let cores = sensors.filter { $0.group == .cpuPerformance || $0.group == .cpuEfficiency }
        return cores.isEmpty ? sensors.filter(\.isCPU) : cores
    }
    var gpuSensors: [TemperatureSensor] { sensors.filter(\.isGPU) }
    var cpuSummary: TemperatureSummary? { TemperatureSummary(cpuSensors) }
    var gpuSummary: TemperatureSummary? { TemperatureSummary(gpuSensors) }

    /// Every group that has sensors, in display order.
    var sensorGroups: [(group: TemperatureSensor.Group, sensors: [TemperatureSensor])] {
        let grouped = Dictionary(grouping: sensors, by: \.group)
        return TemperatureSensor.Group.allCases.compactMap { group in
            grouped[group].map { (group, $0) }
        }
    }

    func summary(_ source: SensorSource) -> TemperatureSummary? {
        switch source {
        case .cpu: return cpuSummary
        case .gpu: return gpuSummary
        case .hottest: return [cpuSummary, gpuSummary].compactMap { $0 }.max { $0.maximum < $1.maximum }
        case .sensor(let key): return TemperatureSummary(sensors.filter { $0.key == key })
        }
    }

    func temperature(_ source: SensorSource) -> Double? {
        summary(source)?.maximum
    }

    /// The average of a group's sensors rather than its hottest; a single
    /// sensor is its own average.
    func averageTemperature(_ source: SensorSource) -> Double? {
        switch source {
        case .cpu: return cpuSummary?.average
        case .gpu: return gpuSummary?.average
        case .hottest: return [cpuSummary?.average, gpuSummary?.average].compactMap { $0 }.max()
        case .sensor: return temperature(source)
        }
    }

    func name(of key: String) -> String {
        sensorNames[key] ?? key
    }

    /// Long enough for the chart's widest time range (an hour).
    static let historyDuration: TimeInterval = 3600

    let profiles: ProfileStore
    let alerts = Alerts()
    let rules = ProfileRules()
    let hotKeys = HotKeys()
    @ObservationIgnored private let logger = HistoryLog()
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private(set) var safetyTrip: FanController.SafetyTrip?

    @ObservationIgnored private var smc: SMC?
    @ObservationIgnored private var sensorKeys: [String] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var helperQueue: Task<Void, Never>?
    @ObservationIgnored private var controller = FanController()

    init(profiles: ProfileStore) {
        self.profiles = profiles
        do {
            smc = try SMC()
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
        discoverSensors()
        scheduleRefresh()
        hotKeys.perform = { [weak self] key in self?.performShortcut(key) }
        hotKeys.prune(profileIDs: Set(profiles.profiles.map(\.id)))
        hotKeys.registerAll()
    }

    private func performShortcut(_ key: String) {
        switch key {
        case ShortcutAction.allMax.storageKey: setAllMax()
        case ShortcutAction.allAutomatic.storageKey: setAllAutomatic()
        default:
            if let profile = profiles.profiles.first(where: { ShortcutAction.profile($0.id).storageKey == key }) {
                activate(profile)
            }
        }
    }

    func scheduleRefresh() {
        timer?.invalidate()
        let interval = max(UserDefaults.standard.double(forKey: PreferenceKey.refreshInterval), 0.5)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // `.common`, not the default mode, so readings and the active profile
        // keep updating while a menu is held open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func discoverSensors() {
        Task {
            // Enumerating ~2,000 SMC keys takes a moment, so do it off the main
            // thread on a separate connection.
            let keys = await Task.detached(priority: .userInitiated) {
                (try? SMC())?.discoverTemperatureKeys() ?? []
            }.value
            sensorKeys = keys
            sensorNames = TemperatureSensor.names(for: keys.map { TemperatureSensor(key: $0, value: 0) })
            isDiscoveringSensors = false
            refresh()
        }
    }

    func refresh() {
        guard let smc else { return }
        fans = smc.fans().map(\.withFiniteReadings)
        for fan in fans where !busyFans.contains(fan.id) {
            if let pending = pendingModes[fan.id], fan.isIn(pending) { pendingModes[fan.id] = nil }
        }
        // Sensors can read 0 (or below) instead of failing, most likely while
        // powered down. That is no reading, not a temperature: averaged in, it
        // dragged the GPU line on the chart to 0° and the axis down to -25°.
        sensors = sensorKeys.compactMap { key in
            guard let value = try? smc.read(key), value.isFinite, value > 1 else { return nil }
            return TemperatureSensor(key: key, value: value)
        }
        if !sensors.isEmpty {
            let sample = Sample(date: .now, cpu: cpuSummary?.average, gpu: gpuSummary?.average,
                                cpuMaximum: cpuSummary?.maximum, gpuMaximum: gpuSummary?.maximum,
                                fanRPMs: fans.map(\.actual), thermalState: ProcessInfo.processInfo.thermalState,
                                profile: profiles.activeProfile?.name)
            history.append(sample)
            history.removeAll { $0.date.timeIntervalSinceNow < -Self.historyDuration }
            logger.append(sample)
        }
        thermalState = ProcessInfo.processInfo.thermalState
        applyRules()
        perform(controller.refresh(controllerInput()))
        alerts.evaluate(self)
    }

    // MARK: Rules

    private func applyRules() {
        guard !RunMode.isReadOnly, !isDiscoveringSensors, canControlFans else { return }
        guard case .use(let id) = rules.decide(temperature: temperature) else { return }
        let profile = id.flatMap { id in profiles.profiles.first { $0.id == id } }
        if profile?.id != profiles.activeProfileID {
            profiles.activeProfileID = profile?.id
        }
    }

    // MARK: Safety net

    func dismissSafetyTrip() {
        safetyTrip = nil
    }

    /// What `FanController` decides from: this refresh's readings, the
    /// settings, and whether a helper call can go out.
    private func controllerInput() -> FanController.Input {
        var temperatures: [SensorSource: Double] = [:]
        for source in SensorSource.groups + sensors.map({ .sensor($0.key) }) {
            temperatures[source] = temperature(source)
        }
        return FanController.Input(fans: fans, temperatures: temperatures, profile: profiles.activeProfile,
                                   safety: FanController.Safety(.standard), now: .now,
                                   helperIsReady: !RunMode.isReadOnly && helperState == .ready,
                                   isRemovingHelper: isRemovingHelper, isDiscoveringSensors: isDiscoveringSensors,
                                   isIdle: busyFans.isEmpty && pendingModes.isEmpty)
    }

    private func perform(_ decision: FanController.Decision) {
        if let trip = decision.trip {
            safetyTrip = trip
            alerts.postSafetyNet(temperature: trip.temperature, action: trip.action)
        }
        if decision.endsProfile { profiles.activeProfileID = nil }
        perform(decision.commands)
    }

    private func perform(_ commands: [FanController.Command]) {
        for command in commands {
            switch command {
            case .autoAll: sendAllAutomatic()
            case .maxAll: sendAllMax()
            case .set(let id, let rpm):
                if let fan = fans.first(where: { $0.id == id }) { sendMode(.manual, fan: fan, rpm: rpm) }
            }
        }
    }

    // MARK: Profiles

    // Deleting a profile goes through here, so rules and shortcuts never point
    // at one that's gone.

    func deleteProfile(_ id: UUID) {
        profiles.delete(id)
        rules.profileDeleted(id)
        hotKeys.prune(profileIDs: Set(profiles.profiles.map(\.id)))
    }

    func restoreDefaultProfiles() {
        let old = profiles.profiles.map(\.id)
        profiles.restoreDefaults()
        old.forEach(rules.profileDeleted)
        hotKeys.prune(profileIDs: Set(profiles.profiles.map(\.id)))
    }

    func activate(_ profile: FanProfile?) {
        // A shortcut can still fire during an uninstall, with the controls disabled.
        guard !isRemovingHelper else { return }
        if profile != nil, helperState != .ready {
            errorMessage = String(localized: "Install the helper tool to use fan profiles.")
            return
        }
        profiles.activeProfileID = profile?.id
        applyActiveProfile()
    }

    private func applyActiveProfile() {
        perform(controller.applyProfile(controllerInput()))
    }

    // MARK: Fan control

    /// The mode to show for a fan: a just-requested mode wins until the SMC
    /// reports it, since entering manual mode can take ~10 seconds.
    func mode(of fan: FanInfo) -> FanMode {
        pendingModes[fan.id] ?? fan.mode
    }

    // A shortcut can still fire while the controls are disabled. Taking over
    // from the profile without sending anything would leave the fans manual
    // with nothing in charge of them.

    func setMode(_ mode: FanMode, fan: FanInfo, rpm: Double) {
        guard !isRemovingHelper else { return }
        takeOverFromProfile()
        sendMode(mode, fan: fan, rpm: rpm)
    }

    func setAllMax() {
        guard !isRemovingHelper else { return }
        takeOverFromProfile()
        sendAllMax()
    }

    func setAllAutomatic() {
        guard !isRemovingHelper else { return }
        takeOverFromProfile()
        sendAllAutomatic()
    }

    /// Ends the active profile without handing the fans back, because the
    /// caller is about to set them itself.
    private func takeOverFromProfile() {
        controller.takeOver()
        profiles.activeProfileID = nil
    }

    private func sendMode(_ mode: FanMode, fan: FanInfo, rpm: Double) {
        let id = String(fan.id)
        switch mode {
        case .automatic: runHelper(fans: [fan.id], mode: mode, ["auto", id])
        case .manual: runHelper(fans: [fan.id], mode: mode, ["set", id, String(Int(rpm.rounded()))])
        case .max: runHelper(fans: [fan.id], mode: mode, ["set", id, String(Int(fan.maximum))])
        }
    }

    private func sendAllMax() {
        runHelper(fans: fans.map(\.id), mode: .max, ["max-all"])
    }

    private func sendAllAutomatic() {
        runHelper(fans: fans.map(\.id), mode: .automatic, ["auto-all"])
    }

    private func runHelper(fans ids: [Int], mode: FanMode, _ arguments: [String]) {
        guard !RunMode.isReadOnly, !isRemovingHelper else { return }
        guard helperState == .ready else {
            errorMessage = String(localized: "Install the helper tool to control fan speed.")
            return
        }
        for id in ids {
            busyFans.insert(id)
            pendingModes[id] = mode
        }
        // Run helper commands one at a time: concurrent unlocks would each wait
        // out the SMC's ~10 second hand-over.
        let previous = helperQueue
        let run = Task {
            await previous?.value
            do {
                try await HelperInstaller.runInBackground(arguments)
            } catch {
                errorMessage = error.localizedDescription
                for id in ids { pendingModes[id] = nil }
                controller.helperFailed()
                profiles.activeProfileID = nil
            }
            for id in ids { busyFans.remove(id) }
            refresh()
        }
        helperQueue = run
        Task {
            await run.value
            // The SMC applies writes asynchronously; stop overriding after a grace period.
            try? await Task.sleep(for: .seconds(HelperInstaller.writeSettleTime))
            for id in ids where pendingModes[id] == mode && !busyFans.contains(id) {
                pendingModes[id] = nil
            }
        }
    }

    // MARK: Helper installation

    func installHelper() {
        isChangingHelper = true
        Task {
            defer { isChangingHelper = false }
            await runAsAdministrator { try HelperInstaller.install() }
            helperState = HelperInstaller.state()
        }
    }

    func uninstallHelper() {
        isChangingHelper = true
        isRemovingHelper = true
        Task {
            defer {
                isChangingHelper = false
                isRemovingHelper = false
            }
            await helperQueue?.value
            do {
                try await HelperInstaller.runInBackground(["auto-all"])
            } catch {
                refresh()
                // Nothing could hand them back once the helper is gone.
                if !fansAreSystemControlled {
                    errorMessage = String(localized: "The fans could not be handed back to macOS, so the helper was left installed.") + " "
                        + error.localizedDescription
                    return
                }
            }
            // The profile stays until the helper is really gone, so cancelling
            // the password prompt leaves things as they were.
            if await runAsAdministrator({ try HelperInstaller.uninstall() }) {
                takeOverFromProfile()
            }
            helperState = HelperInstaller.state()
            refresh()
        }
    }

    /// Runs an install or uninstall off the main thread. Dismissing the password
    /// prompt is not an error worth an alert.
    @discardableResult
    private func runAsAdministrator(_ work: @escaping @Sendable () throws -> Void) async -> Bool {
        do {
            try await Task.detached { try work() }.value
            return true
        } catch HelperInstaller.HelperError.cancelled {
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    /// Hands fans back to the system. Called synchronously when the app quits
    /// so a manual speed never outlives the app.
    nonisolated static func restoreAutomaticFans() {
        guard !RunMode.isReadOnly,
              UserDefaults.standard.bool(forKey: PreferenceKey.restoreAutomaticOnQuit) else { return }
        // A `set` still running would otherwise land after the decision below,
        // and outlive the app. Its writes also apply asynchronously, so reading
        // the fans just after one can still show them automatic: hand back
        // regardless.
        let helperRanRecently = HelperInstaller.waitForRecentCalls(timeout: 30)
        // Any installed root helper can run `auto-all`, even one out of date.
        guard HelperInstaller.isInstalledAsRoot else { return }
        if !helperRanRecently {
            guard let smc = try? SMC(), !smc.fans().allSatisfy(\.isSystemControlled) else { return }
        }
        try? HelperInstaller.run(["auto-all"])
    }
}
