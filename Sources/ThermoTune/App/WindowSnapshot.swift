import AppKit

/// Writes PNGs of the app's own windows for `make shot`: `screencapture` needs
/// Screen Recording permission, but a window can always render itself. In Release
/// on purpose, since a Debug app reports the installed helper as out of date.
///
///   THERMOTUNE_SNAPSHOT_DIR   where to write window-<n>.png
///   THERMOTUNE_SETTINGS_TAB   also open Settings on that tab
enum WindowSnapshot {
    static let isActive = ProcessInfo.processInfo.environment["THERMOTUNE_SNAPSHOT_DIR"] != nil

    static func scheduleIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["THERMOTUNE_SNAPSHOT_DIR"] else { return }

        if let tab = environment["THERMOTUNE_SETTINGS_TAB"], !tab.isEmpty {
            UserDefaults.standard.set(tab, forKey: SettingsTab.storageKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                // `showSettingsWindow:` does nothing for SwiftUI's Settings scene; the ⌘, item does.
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
