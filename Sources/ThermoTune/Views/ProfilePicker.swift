import SwiftUI

/// "None" hands the fans back to macOS.
struct ProfilePicker: View {
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        Picker("Profile", selection: selection) {
            ProfileOptions()
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { monitor.profiles.activeProfileID },
            set: { id in monitor.activate(monitor.profiles.profiles.first { $0.id == id }) }
        )
    }
}

/// A picker's choices: `noneTitle`, then every profile.
struct ProfileOptions: View {
    var noneTitle: LocalizedStringKey = "None"
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        Text(noneTitle).tag(UUID?.none)
        Divider()
        ForEach(monitor.profiles.profiles) { profile in
            Label(profile.name, systemImage: profile.symbol).tag(Optional(profile.id))
        }
    }
}
