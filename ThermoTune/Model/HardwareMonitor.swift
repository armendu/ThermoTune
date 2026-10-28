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
    private(set) var busyFans: Set<Int> = []
    private(set) var pendingModes: [Int: FanMode] = [:]
    var errorMessage: String?

    /// Per-core sensors when the Mac has them (Apple Silicon). The `TC*` package
    /// sensors there read well above the cores even at idle, so they would skew
    /// the CPU reading and temperature-curve profiles.
    var cpuSensors: [TemperatureSensor] {
        let cores = sensors.filter { $0.group == .cpuPerformance || $0.group == .cpuEfficiency }
        return cores.isEmpty ? sensors.filter(\.isCPU) : cores
    }
    var gpuSensors: [TemperatureSensor] { sensors.filter(\.isGPU) }
    var otherSensors: [TemperatureSensor] { sensors.filter { !$0.isCPU && !$0.isGPU } }
    var cpuSummary: TemperatureSummary? { TemperatureSummary(cpuSensors) }
    var gpuSummary: TemperatureSummary? { TemperatureSummary(gpuSensors) }

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

    func temperature(_ source: SensorSource) -> Double? {
        switch source {
        case .cpu: return cpuSummary?.maximum
        case .gpu: return gpuSummary?.maximum
        case .hottest: return [cpuSummary?.maximum, gpuSummary?.maximum].compactMap { $0 }.max()
        case .sensor(let key): return sensors.first { $0.key == key }?.value
        }
    }

    /// Long enough for the chart's widest time range (an hour).
    static let historyDuration: TimeInterval = 3600

    /// A trip of the safety net, shown in the main window until dismissed.
    struct SafetyTrip: Equatable {
        let date: Date
        let temperature: Double
        let action: SafetyAction
    }

    /// For the `.max` action: back to the profile once the hottest reading is
    /// this far under the limit.
    static let safetyClearMargin: Double = 10

    let profiles: ProfileStore
    let alerts = Alerts()
    let rules = ProfileRules()
    let hotKeys = HotKeys()
    @ObservationIgnored private let logger = HistoryLog()
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private(set) var safetyTrip: SafetyTrip?

    @ObservationIgnored private var smc: SMC?
    @ObservationIgnored private var sensorKeys: [String] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var helperQueue: Task<Void, Never>?
    /// A Fixed, Curve or Max profile is driving the fans. If it stops other than
    /// by the user taking a fan over (None, deleted, a helper error), the fans go
    /// back to macOS instead of staying at the profile's last speed.
    @ObservationIgnored private var profileHoldsFans = false
    /// The `.max` safety action is holding every fan at full speed.
    @ObservationIgnored private var isOverheating = false
    @ObservationIgnored private var overLimitSince: Date?
    /// No helper calls while uninstalling: one landing after the final
    /// `auto-all` would leave a fan manual with no helper left to undo it.
    @ObservationIgnored private var isUninstalling = false

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

    /// (Re)starts polling at the interval chosen in Preferences.
    func scheduleRefresh() {
        timer?.invalidate()
        let interval = max(UserDefaults.standard.double(forKey: PreferenceKey.refreshInterval), 0.5)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
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
        fans = smc.fans()
        for fan in fans where pendingModes[fan.id] == fan.mode && !busyFans.contains(fan.id) {
            pendingModes[fan.id] = nil
        }
        // Sensors can read 0 (or below) instead of failing, most likely while
        // powered down. That is no reading, not a temperature: averaged in, it
        // dragged the GPU line on the chart to 0° and the axis down to -25°.
        sensors = sensorKeys.compactMap { key in
            guard let value = try? smc.read(key), value > 1 else { return nil }
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
        // Even with no readings: a profile that has lost its sensors must let go
        // of the fans rather than hold its last speed.
        if !checkSafetyNet() {
            applyActiveProfile()
        }
        alerts.evaluate(self)
    }

    // MARK: Rules

    private func applyRules() {
        guard !WindowSnapshot.isActive, !isDiscoveringSensors, helperState == .ready else { return }
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

    /// Manual speeds and Fixed or Curve profiles stay where they are however hot
    /// the Mac gets. Once the hottest reading has stayed at the limit for the
    /// chosen time while ThermoTune holds the fans, this takes them off it.
    /// Returns whether it is acting this refresh, so the profile doesn't undo it.
    private func checkSafetyNet() -> Bool {
        let defaults = UserDefaults.standard
        guard !WindowSnapshot.isActive, !isUninstalling, helperState == .ready, !fans.isEmpty,
              defaults.bool(forKey: PreferenceKey.safetyNetEnabled),
              let hottest = temperature(.hottest) else {
            overLimitSince = nil
            isOverheating = false
            return false
        }
        let limit = defaults.double(forKey: PreferenceKey.safetyLimit)
        let action = defaults.string(forKey: PreferenceKey.safetyAction).flatMap(SafetyAction.init) ?? .automatic

        if isOverheating {
            if hottest <= limit - Self.safetyClearMargin {
                isOverheating = false
                return false
            }
            if busyFans.isEmpty, pendingModes.isEmpty, fans.contains(where: { $0.mode != .max }) { sendAllMax() }
            return true
        }

        let holdsFans = profileHoldsFans || !fans.allSatisfy(\.isSystemControlled)
        guard hottest >= limit, holdsFans else {
            overLimitSince = nil
            return false
        }
        let since = overLimitSince ?? Date()
        overLimitSince = since
        // Fans already all at full speed can't cool any harder, and handing them
        // back would let macOS slow them down.
        guard Date().timeIntervalSince(since) >= defaults.double(forKey: PreferenceKey.safetyDelay),
              busyFans.isEmpty, pendingModes.isEmpty,
              fans.contains(where: { mode(of: $0) != .max }) else { return false }

        overLimitSince = nil
        safetyTrip = SafetyTrip(date: .now, temperature: hottest, action: action)
        alerts.postSafetyNet(temperature: hottest, action: action)
        switch action {
        case .automatic:
            takeOverFromProfile()
            sendAllAutomatic()
        case .max:
            isOverheating = true
            sendAllMax()
        }
        return true
    }

    // MARK: Profiles

    func activate(_ profile: FanProfile?) {
        profiles.activeProfileID = profile?.id
        if profile != nil, helperState != .ready {
            errorMessage = "Install the helper tool to use fan profiles."
            profiles.activeProfileID = nil
            return
        }
        applyActiveProfile()
    }

    /// Brings the fans in line with the active profile. Runs after every refresh
    /// so curves follow temperature and the profile is re-applied if macOS takes
    /// control back.
    private func applyActiveProfile() {
        guard !WindowSnapshot.isActive, !isDiscoveringSensors, !isUninstalling, helperState == .ready,
              busyFans.isEmpty, pendingModes.isEmpty, !fans.isEmpty else { return }
        guard let profile = profiles.activeProfile else {
            smoothing = [:]
            if profileHoldsFans {
                profileHoldsFans = false
                isOverheating = false
                sendAllAutomatic()
            }
            return
        }
        let behaviors = fans.map { profile.behavior(forFan: $0.id) }
        profileHoldsFans = behaviors.contains { $0.kind != .automatic }

        if !profileHoldsFans {
            smoothing = [:]
            if !fans.allSatisfy(\.isSystemControlled) { sendAllAutomatic() }
            return
        }
        if behaviors.allSatisfy({ $0.kind == .max }) {
            smoothing = [:]
            if fans.contains(where: { $0.mode != .max }) { sendAllMax() }
            return
        }

        // Fixed and curve fans, possibly mixed with Max ones. With no temperature
        // at all, nothing would notice the Mac overheating: macOS gets the fans
        // until there is a reading again.
        guard let hottest = temperature(.hottest) else {
            smoothing = [:]
            if !fans.allSatisfy(\.isSystemControlled) { sendAllAutomatic() }
            return
        }
        for (fan, behavior) in zip(fans, behaviors) {
            // GPU sensors can all drop out while it is powered down, and a chosen
            // sensor can stop reading. Following the hottest reading meanwhile
            // errs towards more cooling, and avoids a ~10 second hand-over to
            // macOS and back each time.
            let temperature = temperature(behavior.source) ?? hottest
            guard let rpm = smoothedRPM(for: fan, behavior: behavior, temperature: temperature) else { continue }
            // Skip small changes so a curve doesn't call the helper every tick,
            // but always land exactly on where the ramp ends.
            if !fan.isManual || abs(fan.target - rpm) >= 100
                || (rpm == smoothing[fan.id]?.goal && abs(fan.target - rpm) >= 1) {
                sendMode(.manual, fan: fan, rpm: rpm)
            }
        }
    }

    // MARK: Smoothing

    /// Per fan: the temperature the curve last followed, the speed being ramped
    /// towards, and where the ramp has got to.
    private struct Smoothing {
        var temperature: Double
        var goal: Double
        var rpm: Double
        var date: Date
    }

    /// A falling temperature has to drop this far before fans slow down, so a
    /// reading wobbling across a curve point doesn't make them hunt.
    static let hysteresis: Double = 3
    /// Fans speed up quickly and slow down gently: a sudden load needs cooling
    /// now, but a fan dropping 1,000 RPM at once is more noticeable than heat.
    static let rampUpRPMPerSecond: Double = 1000
    static let rampDownRPMPerSecond: Double = 150

    @ObservationIgnored private var smoothing: [Int: Smoothing] = [:]

    private func smoothedRPM(for fan: FanInfo, behavior: FanBehavior, temperature: Double) -> Double? {
        let now = Date()
        var state = smoothing[fan.id]
            ?? Smoothing(temperature: temperature, goal: 0,
                         rpm: fan.isManual ? fan.target : max(fan.actual, fan.minimum), date: now)

        if temperature >= state.temperature {
            state.temperature = temperature
        } else if state.temperature - temperature > Self.hysteresis {
            state.temperature = temperature + Self.hysteresis
        }
        guard let goal = behavior.targetRPM(for: fan, temperature: state.temperature) else {
            smoothing[fan.id] = nil
            return nil
        }
        // Bounded, so a long gap (sleep) doesn't turn into one large jump.
        let elapsed = min(now.timeIntervalSince(state.date), 10)
        if goal > state.rpm {
            state.rpm = min(goal, state.rpm + Self.rampUpRPMPerSecond * elapsed)
        } else {
            state.rpm = max(goal, state.rpm - Self.rampDownRPMPerSecond * elapsed)
        }
        state.goal = goal
        state.date = now
        smoothing[fan.id] = state
        return state.rpm.rounded()
    }

    // MARK: Fan control

    /// The mode to show for a fan: a just-requested mode wins until the SMC
    /// reports it, since entering manual mode can take ~10 seconds.
    func mode(of fan: FanInfo) -> FanMode {
        pendingModes[fan.id] ?? fan.mode
    }

    // User actions take over from any active profile.

    func setMode(_ mode: FanMode, fan: FanInfo, rpm: Double? = nil) {
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
        smoothing = [:]
        profileHoldsFans = false
        isOverheating = false
        profiles.activeProfileID = nil
    }

    private func sendMode(_ mode: FanMode, fan: FanInfo, rpm: Double? = nil) {
        let id = String(fan.id)
        switch mode {
        case .automatic: runHelper(fans: [fan.id], mode: mode, ["auto", id])
        case .manual: runHelper(fans: [fan.id], mode: mode, ["set", id, String(Int((rpm ?? fan.minimum).rounded()))])
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
        guard !isUninstalling else { return }
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
            try? await Task.sleep(for: .seconds(5))
            for id in ids where pendingModes[id] == mode && !busyFans.contains(id) {
                pendingModes[id] = nil
            }
        }
    }

    // MARK: Helper installation

    func installHelper() {
        Task {
            do {
                try await Task.detached { try HelperInstaller.install() }.value
            } catch {
                // osascript reports "User canceled." (-128) when the prompt is dismissed.
                if !error.localizedDescription.contains("-128") {
                    errorMessage = error.localizedDescription
                }
            }
            helperState = HelperInstaller.state()
        }
    }

    func uninstallHelper() {
        takeOverFromProfile()
        isUninstalling = true
        Task {
            defer { isUninstalling = false }
            await helperQueue?.value
            do {
                try await HelperInstaller.runInBackground(["auto-all"])
            } catch {
                refresh()
                // Nothing could hand them back once the helper is gone.
                if !fans.allSatisfy(\.isSystemControlled) {
                    errorMessage = "The fans could not be handed back to macOS, so the helper was left installed. "
                        + error.localizedDescription
                    return
                }
            }
            do {
                try await Task.detached { try HelperInstaller.uninstall() }.value
            } catch {
                if !error.localizedDescription.contains("-128") {
                    errorMessage = error.localizedDescription
                }
            }
            helperState = HelperInstaller.state()
            refresh()
        }
    }

    /// Hands fans back to the system. Called synchronously when the app quits
    /// so a manual speed never outlives the app.
    nonisolated static func restoreAutomaticFans() {
        guard !WindowSnapshot.isActive,
              UserDefaults.standard.bool(forKey: PreferenceKey.restoreAutomaticOnQuit) else { return }
        // A `set` still running would otherwise land after the decision below,
        // and outlive the app. Its writes also apply asynchronously, so reading
        // the fans straight after it can still show them automatic: if one was
        // running, hand back regardless.
        let helperWasRunning = HelperInstaller.waitForRunningCalls(timeout: 30)
        // Any installed root helper can run `auto-all`, even one out of date.
        guard HelperInstaller.isInstalledAsRoot else { return }
        if !helperWasRunning {
            guard let smc = try? SMC(), !smc.fans().allSatisfy(\.isSystemControlled) else { return }
        }
        _ = try? HelperInstaller.run(["auto-all"])
    }
}
