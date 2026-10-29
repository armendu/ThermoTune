import SwiftUI

/// The Fans menu in the menu bar.
struct FanCommands: View {
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        Group {
            Button("Set All Fans to Max") { monitor.setAllMax() }
                .disabled(monitor.fans.allSatisfy { monitor.mode(of: $0) == .max })
            Button("Hand All Fans to macOS") { monitor.setAllAutomatic() }
                .disabled(monitor.fansAreSystemControlled)
            Divider()
            ProfilePicker()
        }
        .disabled(!monitor.canControlFans)
    }
}
