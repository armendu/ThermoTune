import Foundation

enum AppInfo {
    static let name = "ThermoTune"
    static let creator = "Armend Ukëhaxhaj"
    static let creatorURL = URL(string: "https://github.com/armendu")!
    static let repositoryURL = URL(string: "https://github.com/armendu/ThermoTune")!
    static let licenseName = "MIT License"
    static let licenseURL = URL(string: "https://github.com/armendu/ThermoTune/blob/main/LICENSE")!
    static let helpURL = URL(string: "https://github.com/armendu/ThermoTune#readme")!
    static let issuesURL = URL(string: "https://github.com/armendu/ThermoTune/issues/new/choose")!
    static let securityURL = URL(string: "https://github.com/armendu/ThermoTune/blob/main/SECURITY.md")!

    /// Raised by every pull request, so the window title says which build is running.
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var version: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Version \(shortVersion) (\(build))")
    }

    static var windowTitle: String { "\(name) v\(shortVersion)" }

    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }
}
