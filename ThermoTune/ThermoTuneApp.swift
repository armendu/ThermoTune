import SwiftUI

@main
struct ThermoTuneApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor: HardwareMonitor
    @AppStorage(PreferenceKey.showMenuBarExtra) private var showMenuBarExtra = true

    init() {
        PreferenceKey.registerDefaults()
        _monitor = State(initialValue: HardwareMonitor(profiles: ProfileStore()))
    }

    var body: some Scene {
        Window("ThermoTune", id: Self.mainWindowID) {
            ContentView()
                .environment(monitor)
        }
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
        }

        Settings {
            SettingsView()
                .environment(monitor)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarView()
                .environment(monitor)
        } label: {
            MenuBarLabel()
                .environment(monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowSnapshot.scheduleIfRequested()
        // `kill`/`pkill` send SIGTERM, which would otherwise skip
        // applicationWillTerminate and leave fans under manual control.
        signal(SIGTERM, SIG_IGN)
        terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSource?.setEventHandler { NSApp.terminate(nil) }
        terminationSource?.resume()
    }

    // Keep running in the menu bar after the window is closed, if it's shown there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: PreferenceKey.showMenuBarExtra)
    }

    func applicationWillTerminate(_ notification: Notification) {
        HardwareMonitor.restoreAutomaticFans()
    }
}
