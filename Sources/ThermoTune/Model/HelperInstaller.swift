import Foundation
import os

/// Installs and runs the setuid-root helper, which makes every SMC write.
enum HelperInstaller {
    enum State {
        case notInstalled
        case needsUpdate
        case ready
    }

    enum HelperError: LocalizedError {
        case missingFromBundle
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingFromBundle: return String(localized: "The helper tool is missing from the app bundle.")
            case .cancelled: return String(localized: "Cancelled.")
            case .failed(let message): return message
            }
        }
    }

    static let installURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.armend.ThermoTune.Helper")

    /// The helper's name before the rename; removed on install.
    static let legacyInstallURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.armend.FanControl.Helper")

    static var bundledURL: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "ThermoTuneHelper")
    }

    static func state() -> State {
        guard FileManager.default.fileExists(atPath: installURL.path) else { return .notInstalled }
        guard isInstalledAsRoot else { return .needsUpdate }
        if let bundledURL, let bundled = try? Data(contentsOf: bundledURL),
           bundled != (try? Data(contentsOf: installURL)) {
            return .needsUpdate
        }
        return .ready
    }

    /// Any root helper, current or not: even an old one can run `auto-all`.
    static var isInstalledAsRoot: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: installURL.path) else { return false }
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return owner == 0 && mode & 0o4000 != 0
    }

    /// Asks for the administrator password. The copy is renamed over the old
    /// helper, so a call already running finishes with the old file, and its
    /// quarantine flag is cleared, which could otherwise get it refused later.
    static func install() throws {
        guard let bundledURL else { throw HelperError.missingFromBundle }
        let src = shellQuoted(bundledURL.path)
        let dst = shellQuoted(installURL.path)
        let tmp = shellQuoted(installURL.path + ".new")
        let command = [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/cp -f \(src) \(tmp)",
            "/usr/bin/xattr -c \(tmp)",
            "/usr/sbin/chown root:wheel \(tmp)",
            "/bin/chmod 4755 \(tmp)",
            "/bin/mv -f \(tmp) \(dst)",
            "/bin/rm -f \(shellQuoted(legacyInstallURL.path))",
        ].joined(separator: " && ")
        try runAsAdministrator(command)
    }

    static func uninstall() throws {
        try runAsAdministrator("/bin/rm -f \(shellQuoted(installURL.path)) \(shellQuoted(installURL.path + ".new")) "
                               + shellQuoted(legacyInstallURL.path))
    }

    static func run(_ arguments: [String]) throws {
        try runProcess(installURL, arguments)
    }

    /// Until this long after a call, the fans can still read back the old state.
    static let writeSettleTime: TimeInterval = 5

    /// Counts as running from the call on the main actor, so quitting before a
    /// background thread picks it up still waits for it.
    @MainActor
    static func runInBackground(_ arguments: [String]) async throws {
        runningCalls.enter()
        try await Task.detached {
            defer {
                lastCallEnded.withLock { $0 = .now }
                runningCalls.leave()
            }
            try run(arguments)
        }.value
    }

    /// Whether a call was running or ended within `writeSettleTime`: whether the
    /// fans can't yet be trusted to read back what it wrote.
    static func waitForRecentCalls(timeout: TimeInterval) -> Bool {
        let wasRunning = runningCalls.wait(timeout: .now()) == .timedOut
        _ = runningCalls.wait(timeout: .now() + timeout)
        return wasRunning || lastCallEnded.withLock { $0.timeIntervalSinceNow > -writeSettleTime }
    }

    // MARK: Private

    private static let runningCalls = DispatchGroup()
    private static let lastCallEnded = OSAllocatedUnfairLock(initialState: Date.distantPast)

    private static func runAsAdministrator(_ command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        do {
            try runProcess(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script])
        } catch HelperError.failed(let message) where message.contains("(-128)") {
            throw HelperError.cancelled
        }
    }

    private static func runProcess(_ url: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HelperError.failed(message.isEmpty ? "Helper exited with status \(process.terminationStatus)." : message)
        }
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
