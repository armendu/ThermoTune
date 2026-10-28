import AppKit

/// Writes PNGs of the app's own windows for `make shot`.
///
/// `screencapture` needs Screen Recording permission, which agents and CI don't
/// have, but a window can always render itself with `cacheDisplay`. Driven by
/// environment variables and inert without them. It is compiled into Release on
/// purpose: `make shot` captures the build users run, and a Debug app reports the
/// installed (Release) helper as out of date.
///
///   THERMOTUNE_SNAPSHOT_DIR   where to write window-<n>.png
///   THERMOTUNE_SETTINGS_TAB   general | profiles | safety | menuBar | advanced | about: also open Preferences on that tab
enum WindowSnapshot {
    /// A snapshot run is read-only: it doesn't apply the active profile or hand the
    /// fans back on quit, because it runs beside a copy of the app someone is using.
    static let isActive = ProcessInfo.processInfo.environment["THERMOTUNE_SNAPSHOT_DIR"] != nil

    static func scheduleIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["THERMOTUNE_SNAPSHOT_DIR"] else { return }

        if let tab = environment["THERMOTUNE_SETTINGS_TAB"], !tab.isEmpty {
            UserDefaults.standard.set(tab, forKey: SettingsTab.storageKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                // `showSettingsWindow:` sent through the responder chain does nothing
                // for SwiftUI's Settings scene; the ⌘, menu item does work.
                let items = NSApp.mainMenu?.items.first?.submenu?.items ?? []
                if let item = items.first(where: { $0.keyEquivalent == "," }), let menu = item.menu {
                    menu.performActionForItem(at: menu.index(of: item))
                }
            }
        }

        // Late enough for sensor discovery and a few chart samples.
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for (index, window) in NSApp.windows.enumerated() where window.isVisible && window.frame.height > 100 {
                guard let view = window.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(fileURLWithPath: directory).appendingPathComponent("window-\(index).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
}
