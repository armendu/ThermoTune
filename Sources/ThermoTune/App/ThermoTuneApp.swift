import SwiftUI

@main
struct ThermoTuneApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor: HardwareMonitor
    @AppStorage(PreferenceKey.showMenuBarExtra) private var showMenuBarExtra = true

    init() {
        PreferenceKey.registerDefaults()
        // Left over from a quit with Settings open, or from `make shot TAB=…`.
        SettingsTab.reset()
        _monitor = State(initialValue: HardwareMonitor(profiles: ProfileStore()))
    }

    var body: some Scene {
        Window(AppInfo.windowTitle, id: Self.mainWindowID) {
            ContentView()
                .environment(monitor)
        }
        .defaultSize(width: 900, height: 640)
        .commands {
            // The About tab, not the standard panel: one About screen to keep current.
            CommandGroup(replacing: .appInfo) {
                SettingsTabButton(title: "About \(AppInfo.name)", tab: .about)
            }
            CommandMenu("Fans") {
                FanCommands()
                    .environment(monitor)
            }
            // The default Help item only says help isn't available.
            CommandGroup(replacing: .help) {
                Link("\(AppInfo.name) Help", destination: AppInfo.helpURL)
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
        if UserDefaults.standard.bool(forKey: PreferenceKey.hideDockIcon), !RunMode.isReadOnly {
            // With neither a Dock icon nor a menu bar item, there'd be no way back in.
            UserDefaults.standard.set(true, forKey: PreferenceKey.showMenuBarExtra)
            DockIcon.apply()
        }
        // SIGTERM (`kill`) would otherwise skip applicationWillTerminate and leave fans manual.
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
