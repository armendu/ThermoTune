import SwiftUI

/// Chooses the active fan profile. "None" hands the fans back to macOS.
struct ProfilePicker: View {
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        Picker("Profile", selection: selection) {
            Text("None").tag(UUID?.none)
            Divider()
            ForEach(monitor.profiles.profiles) { profile in
                Label(profile.name, systemImage: profile.symbol).tag(Optional(profile.id))
            }
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { monitor.profiles.activeProfileID },
            set: { id in monitor.activate(monitor.profiles.profiles.first { $0.id == id }) }
        )
    }
}
