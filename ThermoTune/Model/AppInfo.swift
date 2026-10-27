import Foundation

/// Facts about the app shown in About, kept in one place.
enum AppInfo {
    static let name = "ThermoTune"
    static let creator = "Armend Ukëhaxhaj"
    static let creatorURL = URL(string: "https://github.com/armendu")!
    static let repositoryURL = URL(string: "https://github.com/armendu/ThermoTune")!
    static let licenseName = "MIT License"
    static let licenseURL = URL(string: "https://github.com/armendu/ThermoTune/blob/main/LICENSE")!
    static let issuesURL = URL(string: "https://github.com/armendu/ThermoTune/issues/new/choose")!
    static let securityURL = URL(string: "https://github.com/armendu/ThermoTune/blob/main/SECURITY.md")!

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }
}
