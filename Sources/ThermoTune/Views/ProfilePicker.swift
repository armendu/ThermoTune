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

/// The menu bar panel's profile row. A pop-up button there didn't highlight under the pointer
/// like the rows around it, so it's a menu item that opens the choices.
struct ProfileMenu: View {
    @Environment(HardwareMonitor.self) private var monitor

    var body: some View {
        Menu {
            ProfilePicker()
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            HStack {
                Text("Profile")
                Spacer()
                Text(monitor.profiles.activeProfile?.name ?? String(localized: "None"))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        }
        // `.button` draws the label with the surrounding button style, hover included.
        .menuStyle(.button)
        .menuIndicator(.hidden)
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
