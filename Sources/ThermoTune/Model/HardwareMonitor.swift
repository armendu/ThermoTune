import Foundation
import Observation

/// Polls the SMC, drives the active profile, and sends fan changes to the helper.
@MainActor
@Observable
final class HardwareMonitor {
    /// One refresh's readings. `cpu` and `gpu` are averages.
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
    private(set) var sensorNames: [String: String] = [:]
    private(set) var helperState = HelperInstaller.state()
    /// An install or uninstall is waiting on the password prompt.
    private(set) var isChangingHelper = false
    /// Fan changes are held off during an uninstall: one landing after its final
    /// `auto-all` would leave a fan manual with no helper left to undo it.
    private(set) var isRemovingHelper = false
    private(set) var busyFans: Set<Int> = []
    private(set) var pendingModes: [Int: FanMode] = [:]
    var errorMessage: String?

    var canControlFans: Bool { helperState == .ready && !isRemovingHelper }
    var fansAreSystemControlled: Bool { fans.allSatisfy(\.isSystemControlled) }
    /// Counting a mode just asked for, so All Max disables as soon as it's clicked.
    var allFansAtMax: Bool { fans.allSatisfy { mode(of: $0) == .max } }
    var fastestFanRPM: Double? { fans.map(\.actual).max() }

    /// Per-core sensors where there are any: the `TC*` package sensors read well
    /// above the cores, even at idle.
    var cpuSensors: [TemperatureSensor] {
        let cores = sensors.filter { $0.group == .cpuPerformance || $0.group == .cpuEfficiency }
        return cores.isEmpty ? sensors.filter(\.isCPU) : cores
    }
    var gpuSensors: [TemperatureSensor] { sensors.filter(\.isGPU) }
    var cpuSummary: TemperatureSummary? { TemperatureSummary(cpuSensors) }
    var gpuSummary: TemperatureSummary? { TemperatureSummary(gpuSensors) }

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
        // `.common`, so readings keep updating while a menu is held open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func discoverSensors() {
        Task {
            // ~2,000 keys: off the main thread, on a connection of its own.
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
        // A sensor reading 0 or below (powered down) is no reading: averaged in, it
        // dragged the chart down to -25°.
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

    // Deletions also update rules and shortcuts.

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

    /// A requested mode wins until the SMC reports it, ~10 s for manual.
    func mode(of fan: FanInfo) -> FanMode {
        pendingModes[fan.id] ?? fan.mode
    }

    // Shortcuts can fire while the controls are disabled. Taking over then would
    // leave the fans manual with nothing in charge.

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

    /// The caller is about to set the fans, so they aren't handed back.
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
        // One at a time: concurrent unlocks would each wait out the ~10 s hand-over.
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
            // The profile stays until the helper is gone, so cancelling the prompt changes nothing.
            if await runAsAdministrator({ try HelperInstaller.uninstall() }) {
                takeOverFromProfile()
            }
            helperState = HelperInstaller.state()
            refresh()
        }
    }

    /// Off the main thread. A dismissed password prompt isn't an error.
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

    /// Runs as the app quits, so a manual speed never outlives it.
    nonisolated static func restoreAutomaticFans() {
        guard !RunMode.isReadOnly,
              UserDefaults.standard.bool(forKey: PreferenceKey.restoreAutomaticOnQuit) else { return }
        // Wait for a running call, and hand back regardless if one ran recently: its
        // writes may not have landed, so the fans can still read automatic.
        let helperRanRecently = HelperInstaller.waitForRecentCalls(timeout: 30)
        // Any installed root helper can run `auto-all`, even one out of date.
        guard HelperInstaller.isInstalledAsRoot else { return }
        if !helperRanRecently {
            guard let smc = try? SMC(), !smc.fans().allSatisfy(\.isSystemControlled) else { return }
        }
        try? HelperInstaller.run(["auto-all"])
    }
}
