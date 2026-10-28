import SwiftUI

struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
                        .frame(width: 64, height: 64)
                        .overlay {
                            Image(systemName: "fan.fill")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppInfo.name)
                            .font(.title2.weight(.semibold))
                        Text(AppInfo.version)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("See your Mac's temperatures and control its fans.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Created by") {
                    Link(AppInfo.creator, destination: AppInfo.creatorURL)
                }
                LabeledContent("License") {
                    Link(AppInfo.licenseName, destination: AppInfo.licenseURL)
                }
                LabeledContent("Source code") {
                    Link("github.com/armendu/ThermoTune", destination: AppInfo.repositoryURL)
                }
            } footer: {
                Text("ThermoTune is free and open source. Bug reports, pull requests and reports of which Macs it works on are all welcome.")
            }

            Section {
                HStack {
                    Link("Report an Issue…", destination: AppInfo.issuesURL)
                    Spacer()
                    Link("Security Policy", destination: AppInfo.securityURL)
                }
            } footer: {
                Text("\(AppInfo.copyright) Not affiliated with Apple.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
    }
}
