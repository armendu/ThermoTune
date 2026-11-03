import SwiftUI

/// The Fans menu, also shown in the menu bar item's panel.
struct FanCommands: View {
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        Group {
            Button("Set All Fans to Max") { monitor.setAllMax() }
                .disabled(monitor.allFansAtMax)
            Button("Hand All Fans to macOS") { monitor.setAllAutomatic() }
                .disabled(monitor.fansAreSystemControlled)
            Divider()
            ProfilePicker()
        }
        .disabled(!monitor.canControlFans)
    }
}
