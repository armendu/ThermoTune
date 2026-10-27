import Foundation

/// Installs and runs the setuid-root `ThermoTuneHelper`, which performs all SMC
/// writes. Reading sensors needs no privileges; changing fan speed does.
enum HelperInstaller {
    enum State {
        case notInstalled
        case needsUpdate
        case ready
    }

    enum HelperError: LocalizedError {
        case missingFromBundle
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingFromBundle: return "The helper tool is missing from the app bundle."
            case .failed(let message): return message
            }
        }
    }

    static let installURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.armend.ThermoTune.Helper")

    /// Where the app installed its helper before it was renamed to ThermoTune.
    /// Removed during install so no stale setuid-root copy is left behind.
    static let legacyInstallURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.armend.FanControl.Helper")

    static var bundledURL: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "ThermoTuneHelper")
    }

    static func state() -> State {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: installURL.path) else { return .notInstalled }
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard owner == 0, mode & 0o4000 != 0 else { return .needsUpdate }
        if let bundledURL, let bundled = try? Data(contentsOf: bundledURL),
           bundled != (try? Data(contentsOf: installURL)) {
            return .needsUpdate
        }
        return .ready
    }

    /// Copies the helper into place and marks it setuid root. Shows the standard
    /// macOS administrator password prompt.
    static func install() throws {
        guard let bundledURL else { throw HelperError.missingFromBundle }
        let src = shellQuoted(bundledURL.path)
        let dst = shellQuoted(installURL.path)
        let command = [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/cp -f \(src) \(dst)",
            "/usr/sbin/chown root:wheel \(dst)",
            "/bin/chmod 4755 \(dst)",
            "/bin/rm -f \(shellQuoted(legacyInstallURL.path))",
        ].joined(separator: " && ")
        try runAsAdministrator(command)
    }

    static func uninstall() throws {
        try runAsAdministrator("/bin/rm -f \(shellQuoted(installURL.path)) \(shellQuoted(legacyInstallURL.path))")
    }

    /// Runs the installed helper with the given arguments and waits for it.
    @discardableResult
    static func run(_ arguments: [String]) throws -> String {
        try runProcess(installURL, arguments)
    }

    // MARK: Private

    private static func runAsAdministrator(_ command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        try runProcess(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script])
    }

    @discardableResult
    private static func runProcess(_ url: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HelperError.failed(message.isEmpty ? "Helper exited with status \(process.terminationStatus)." : message)
        }
        return output
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
