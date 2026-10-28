import Foundation
import Observation
import UserNotifications

/// Posts the notifications chosen in Settings › Safety. Each alert fires once
/// per episode and re-arms only once its condition has clearly ended, so a
/// reading hovering at a limit doesn't post one notification per refresh.
@MainActor
@Observable
final class Alerts: NSObject {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private var temperatureSince: Date?
    @ObservationIgnored private var temperatureFired = false
    @ObservationIgnored private var stalledSince: [Int: Date] = [:]
    @ObservationIgnored private var stallFired: Set<Int> = []
    @ObservationIgnored private var thermalFired = false
    @ObservationIgnored private var helperFired = false

    /// A fan given a target gets this long to spin up before it counts as stalled.
    static let stallGrace: TimeInterval = 15

    override init() {
        super.init()
        guard !WindowSnapshot.isActive else { return }
        UNUserNotificationCenter.current().delegate = self
        // Several alerts are on by default, and they post nothing until macOS
        // has been asked, so ask at launch rather than on a first visit to Settings.
        Task {
            await updateAuthorization()
            if authorization == .notDetermined, Self.anyEnabled { requestAuthorization() }
        }
    }

    static var anyEnabled: Bool {
        [PreferenceKey.alertSafetyNet, PreferenceKey.alertTemperature, PreferenceKey.alertFanStall,
         PreferenceKey.alertThermalPressure, PreferenceKey.alertHelper].contains { UserDefaults.standard.bool(forKey: $0) }
    }

    func refreshAuthorization() {
        Task { await updateAuthorization() }
    }

    private func updateAuthorization() async {
        guard !WindowSnapshot.isActive else { return }
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks macOS for permission to post notifications.
    func requestAuthorization() {
        guard !WindowSnapshot.isActive else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await updateAuthorization()
        }
    }

    /// Checks every alert against one refresh's readings.
    func evaluate(_ monitor: HardwareMonitor) {
        guard !WindowSnapshot.isActive else { return }
        let defaults = UserDefaults.standard
        let now = Date()

        if defaults.bool(forKey: PreferenceKey.alertTemperature) {
            let source = defaults.string(forKey: PreferenceKey.alertTemperatureSource).flatMap(SensorSource.init) ?? .hottest
            let limit = defaults.double(forKey: PreferenceKey.alertTemperatureLimit)
            let duration = defaults.double(forKey: PreferenceKey.alertTemperatureDuration)
            if let value = monitor.temperature(source), value >= limit {
                let since = temperatureSince ?? now
                temperatureSince = since
                if !temperatureFired, now.timeIntervalSince(since) >= duration {
                    temperatureFired = true
                    post("temperature", title: "\(source.title) is running hot",
                         body: "\(source.title) has been at \(value.degrees) or more for \(Int(duration)) seconds.")
                }
            } else {
                temperatureSince = nil
                if (monitor.temperature(source) ?? 0) < limit - 5 { temperatureFired = false }
            }
        }

        if defaults.bool(forKey: PreferenceKey.alertFanStall) {
            for fan in monitor.fans {
                let shouldSpin = fan.isManual && fan.target > fan.minimum && !monitor.busyFans.contains(fan.id)
                if shouldSpin, fan.actual < 100 {
                    let since = stalledSince[fan.id] ?? now
                    stalledSince[fan.id] = since
                    if !stallFired.contains(fan.id), now.timeIntervalSince(since) >= Self.stallGrace {
                        stallFired.insert(fan.id)
                        post("stall-\(fan.id)", title: "\(fan.name) isn't spinning",
                             body: "It was set to \(Int(fan.target)) RPM but reads \(Int(fan.actual)) RPM. It may be blocked or failing.")
                    }
                } else {
                    stalledSince[fan.id] = nil
                    if fan.actual >= 100 || !shouldSpin { stallFired.remove(fan.id) }
                }
            }
        }

        if defaults.bool(forKey: PreferenceKey.alertThermalPressure) {
            switch monitor.thermalState {
            case .serious, .critical:
                if !thermalFired {
                    thermalFired = true
                    post("thermal", title: "macOS is slowing your Mac down",
                         body: "Thermal pressure is \(monitor.thermalState.title). macOS is reducing performance to keep the Mac cool.")
                }
            default:
                thermalFired = false
            }
        }

        if defaults.bool(forKey: PreferenceKey.alertHelper), monitor.helperState == .needsUpdate, !helperFired {
            helperFired = true
            post("helper", title: "Update the ThermoTune helper",
                 body: "ThermoTune can't change fan speeds until its helper tool is updated. Open ThermoTune to update it.")
        }
    }

    func postSafetyNet(temperature: Double, action: SafetyAction) {
        guard UserDefaults.standard.bool(forKey: PreferenceKey.alertSafetyNet) else { return }
        let outcome = action == .automatic
            ? "macOS is managing the fans again, and the active profile was switched off."
            : "Every fan is at full speed until it cools down."
        post("safety", title: "Safety net: \(temperature.degrees)", body: outcome)
    }

    private func post(_ id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // A stable identifier per alert, so a new one replaces the last instead of stacking.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

extension Alerts: UNUserNotificationCenterDelegate {
    // Shown even while ThermoTune is the frontmost app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

extension ProcessInfo.ThermalState {
    var title: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}
