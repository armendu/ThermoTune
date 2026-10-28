import Foundation
import Observation

/// Polls the SMC for fan and temperature readings, drives the active fan
/// profile, and forwards fan changes to the privileged helper.
@MainActor
@Observable
final class HardwareMonitor {
    /// Average CPU and GPU temperature at one refresh, for the chart.
    struct Sample: Identifiable {
        let id = UUID()
        let date: Date
        let cpu: Double?
        let gpu: Double?
    }

    private(set) var fans: [FanInfo] = []
    private(set) var sensors: [TemperatureSensor] = []
    private(set) var history: [Sample] = []
    private(set) var isDiscoveringSensors = true
    private(set) var helperState = HelperInstaller.state()
    /// An install or uninstall is waiting on the queue or the password prompt.
    /// Fan changes are held off meanwhile: one landing after the final
    /// `auto-all` of an uninstall would leave a fan manual with no helper left
    /// to undo it.
    private(set) var isChangingHelper = false
    private(set) var busyFans: Set<Int> = []
    private(set) var pendingModes: [Int: FanMode] = [:]
    var errorMessage: String?

    var canControlFans: Bool { helperState == .ready && !isChangingHelper }
    var fansAreSystemControlled: Bool { fans.allSatisfy(\.isSystemControlled) }

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
        }
    }

    func temperature(_ source: SensorSource) -> Double? {
        summary(source)?.maximum
    }

    /// Long enough for the chart's widest time range (an hour).
    static let historyDuration: TimeInterval = 3600

    /// A Fixed or Curve profile can hold fans near minimum at any temperature,
    /// with macOS's thermal control suspended. Past this the fans go to full
    /// speed whatever the profile says, until the hottest sensor is back under
    /// `overheatClearTemperature`.
    static let overheatTemperature: Double = 95
    static let overheatClearTemperature: Double = 85

    let profiles: ProfileStore

    @ObservationIgnored private var smc: SMC?
    @ObservationIgnored private var sensorKeys: [String] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var helperQueue: Task<Void, Never>?
    /// A Fixed, Curve or Max profile is driving the fans. If it stops other than
    /// by the user taking a fan over (None, deleted, a helper error), the fans go
    /// back to macOS instead of staying at the profile's last speed.
    @ObservationIgnored private var profileHoldsFans = false
    @ObservationIgnored private var isOverheating = false

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
            isDiscoveringSensors = false
            refresh()
        }
    }

    func refresh() {
        guard let smc else { return }
        fans = smc.fans()
        for fan in fans where !busyFans.contains(fan.id) {
            if let pending = pendingModes[fan.id], fan.isIn(pending) { pendingModes[fan.id] = nil }
        }
        // Sensors can read 0 (or below) instead of failing, most likely while
        // powered down. That is no reading, not a temperature: averaged in, it
        // dragged the GPU line on the chart to 0° and the axis down to -25°.
        sensors = sensorKeys.compactMap { key in
            guard let value = try? smc.read(key), value > 1 else { return nil }
            return TemperatureSensor(key: key, value: value)
        }
        if !sensors.isEmpty {
            history.append(Sample(date: .now, cpu: cpuSummary?.average, gpu: gpuSummary?.average))
            history.removeAll { $0.date.timeIntervalSinceNow < -Self.historyDuration }
        }
        // Even with no readings: a profile that has lost its sensors must let go
        // of the fans rather than hold its last speed.
        applyActiveProfile()
    }

    // MARK: Profiles

    func activate(_ profile: FanProfile?) {
        if profile != nil, helperState != .ready {
            errorMessage = "Install the helper tool to use fan profiles."
            return
        }
        profiles.activeProfileID = profile?.id
        applyActiveProfile()
    }

    /// Brings the fans in line with the active profile. Runs after every refresh
    /// so curves follow temperature and the profile is re-applied if macOS takes
    /// control back.
    private func applyActiveProfile() {
        guard !WindowSnapshot.isActive, !isDiscoveringSensors, canControlFans,
              busyFans.isEmpty, pendingModes.isEmpty, !fans.isEmpty else { return }
        guard let profile = profiles.activeProfile else {
            if profileHoldsFans {
                profileHoldsFans = false
                isOverheating = false
                sendAllAutomatic()
            }
            return
        }
        profileHoldsFans = profile.kind != .automatic

        switch profile.kind {
        case .automatic:
            handBackIfNeeded()
        case .max:
            maxAllIfNeeded()
        case .fixed, .curve:
            // With no temperature at all, nothing would notice the Mac
            // overheating: macOS gets the fans until there is a reading again.
            guard let hottest = temperature(.hottest) else {
                handBackIfNeeded()
                return
            }
            if hottest >= Self.overheatTemperature {
                isOverheating = true
            } else if hottest <= Self.overheatClearTemperature {
                isOverheating = false
            }
            if isOverheating {
                maxAllIfNeeded()
                return
            }
            // GPU sensors can all drop out while it is powered down. Following
            // the hottest reading meanwhile errs towards more cooling, and avoids
            // a ~10 second hand-over to macOS and back each time.
            let temperature = temperature(profile.source) ?? hottest
            for fan in fans {
                guard let rpm = profile.targetRPM(for: fan, temperature: temperature) else { continue }
                // Skip small changes so a curve doesn't call the helper every tick.
                if !fan.isManual || abs(fan.target - rpm) >= 100 {
                    sendMode(.manual, fan: fan, rpm: rpm)
                }
            }
        }
    }

    private func handBackIfNeeded() {
        if !fansAreSystemControlled { sendAllAutomatic() }
    }

    private func maxAllIfNeeded() {
        if fans.contains(where: { $0.mode != .max }) { sendAllMax() }
    }

    // MARK: Fan control

    /// The mode to show for a fan: a just-requested mode wins until the SMC
    /// reports it, since entering manual mode can take ~10 seconds.
    func mode(of fan: FanInfo) -> FanMode {
        pendingModes[fan.id] ?? fan.mode
    }

    func setMode(_ mode: FanMode, fan: FanInfo, rpm: Double) {
        takeOverFromProfile()
        sendMode(mode, fan: fan, rpm: rpm)
    }

    func setAllMax() {
        takeOverFromProfile()
        sendAllMax()
    }

    func setAllAutomatic() {
        takeOverFromProfile()
        sendAllAutomatic()
    }

    /// Ends the active profile without handing the fans back, because the
    /// caller is about to set them itself.
    private func takeOverFromProfile() {
        profileHoldsFans = false
        isOverheating = false
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
        guard !isChangingHelper else { return }
        guard helperState == .ready else {
            errorMessage = "Install the helper tool to control fan speed."
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
                // With `profileHoldsFans` still set, the next refresh hands the
                // fans back to macOS.
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
            await helperQueue?.value
            await runAsAdministrator { try HelperInstaller.install() }
            helperState = HelperInstaller.state()
        }
    }

    func uninstallHelper() {
        isChangingHelper = true
        Task {
            defer { isChangingHelper = false }
            await helperQueue?.value
            do {
                try await HelperInstaller.runInBackground(["auto-all"])
            } catch {
                refresh()
                // Nothing could hand them back once the helper is gone.
                if !fansAreSystemControlled {
                    errorMessage = "The fans could not be handed back to macOS, so the helper was left installed. "
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
        guard !WindowSnapshot.isActive,
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
