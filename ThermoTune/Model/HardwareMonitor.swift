import Foundation
import Observation

/// Polls the SMC for fan and temperature readings, drives the active fan
/// profile, and forwards fan changes to the privileged helper.
@MainActor
@Observable
final class HardwareMonitor {
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

    func temperature(_ source: SensorSource) -> Double? {
        switch source {
        case .cpu: return cpuSummary?.maximum
        case .gpu: return gpuSummary?.maximum
        case .hottest: return [cpuSummary?.maximum, gpuSummary?.maximum].compactMap { $0 }.max()
        }
    }

    static let historyDuration: TimeInterval = 300

    let profiles: ProfileStore

    @ObservationIgnored private var smc: SMC?
    @ObservationIgnored private var sensorKeys: [String] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var helperQueue: Task<Void, Never>?

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
        sensors = sensorKeys.compactMap { key in
            (try? smc.read(key)).map { TemperatureSensor(key: key, value: $0) }
        }
        guard !sensors.isEmpty else { return }
        history.append(Sample(date: .now, cpu: cpuSummary?.maximum, gpu: gpuSummary?.maximum))
        history.removeAll { $0.date.timeIntervalSinceNow < -Self.historyDuration }
        applyActiveProfile()
    }

    // MARK: Profiles

    func activate(_ profile: FanProfile?) {
        profiles.activeProfileID = profile?.id
        if profile == nil { return }
        guard helperState == .ready else {
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
        guard let profile = profiles.activeProfile, helperState == .ready,
              busyFans.isEmpty, pendingModes.isEmpty, !fans.isEmpty else { return }

        switch profile.kind {
        case .automatic:
            if !fans.allSatisfy(\.isSystemControlled) { sendAllAutomatic() }
        case .max:
            if fans.contains(where: { $0.mode != .max }) { sendAllMax() }
        case .fixed, .curve:
            let temperature = temperature(profile.source)
            for fan in fans {
                guard let rpm = profile.targetRPM(for: fan, temperature: temperature) else { continue }
                // Skip small changes so a curve doesn't call the helper every tick.
                if !fan.isManual || abs(fan.target - rpm) >= 100 {
                    sendMode(.manual, fan: fan, rpm: rpm)
                }
            }
        }
    }

    // MARK: Fan control

    // MARK: Fan control

    /// The mode to show for a fan: a just-requested mode wins until the SMC
    /// reports it, since entering manual mode can take ~10 seconds.
    func mode(of fan: FanInfo) -> FanMode {
        pendingModes[fan.id] ?? fan.mode
    }

    // User actions take over from any active profile.

    func setMode(_ mode: FanMode, fan: FanInfo, rpm: Double? = nil) {
        profiles.activeProfileID = nil
        sendMode(mode, fan: fan, rpm: rpm)
    }

    func setAllMax() {
        profiles.activeProfileID = nil
        sendAllMax()
    }

    func setAllAutomatic() {
        profiles.activeProfileID = nil
        sendAllAutomatic()
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
                try await Task.detached { _ = try HelperInstaller.run(arguments) }.value
            } catch {
                errorMessage = error.localizedDescription
                for id in ids { pendingModes[id] = nil }
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
        Task {
            _ = try? await Task.detached { try HelperInstaller.run(["auto-all"]) }.value
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
        guard UserDefaults.standard.bool(forKey: PreferenceKey.restoreAutomaticOnQuit),
              HelperInstaller.state() == .ready,
              let smc = try? SMC(),
              !smc.fans().allSatisfy(\.isSystemControlled) else { return }
        _ = try? HelperInstaller.run(["auto-all"])
    }
}
