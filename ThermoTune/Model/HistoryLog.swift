import Foundation

/// Readings as CSV: one row per refresh, temperatures in °C whatever the
/// display unit, so files from different Macs and settings line up.
enum HistoryCSV {
    static func header(fanCount: Int) -> String {
        (["time", "cpu_avg_c", "cpu_max_c", "gpu_avg_c", "gpu_max_c"]
            + (0..<fanCount).map { "fan\($0 + 1)_rpm" }
            + ["thermal_pressure", "profile"]).joined(separator: ",")
    }

    static func row(_ sample: HardwareMonitor.Sample) -> String {
        func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "" }
        let profile = sample.profile.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" } ?? ""
        return ([timestamp.string(from: sample.date), number(sample.cpu), number(sample.cpuMaximum),
                 number(sample.gpu), number(sample.gpuMaximum)]
            + sample.fanRPMs.map { String(Int($0.rounded())) }
            + [token(sample.thermalState), profile]).joined(separator: ",")
    }

    /// The same in every language, so logs from different Macs line up.
    static func token(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func document(_ samples: [HardwareMonitor.Sample]) -> String {
        let fanCount = samples.map(\.fanRPMs.count).max() ?? 0
        return ([header(fanCount: fanCount)] + samples.map(row)).joined(separator: "\n") + "\n"
    }

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        formatter.timeZone = .current
        return formatter
    }()
}

/// Appends every refresh to a daily CSV file in ~/Library/Logs/ThermoTune when
/// "Keep a log file" is on.
final class HistoryLog {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ThermoTune", isDirectory: true)

    private var handle: FileHandle?
    private var day: String?

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Gregorian whatever the user's calendar, so file names sort and match the timestamps.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    func append(_ sample: HardwareMonitor.Sample) {
        guard UserDefaults.standard.bool(forKey: PreferenceKey.keepsLog), !RunMode.isReadOnly else {
            close()
            return
        }
        let today = Self.dayFormatter.string(from: sample.date)
        if today != day { open(day: today, fanCount: sample.fanRPMs.count) }
        // The throwing `write(contentsOf:)`: the older `write(_:)` raises an
        // Objective-C exception on a full disk, and a crash would skip handing
        // the fans back on quit. A failed write closes the file, and the next
        // sample tries to open it again.
        do {
            try handle?.write(contentsOf: Data((HistoryCSV.row(sample) + "\n").utf8))
        } catch {
            close()
        }
    }

    private func open(day: String, fanCount: Int) {
        close()
        self.day = day
        let url = Self.directory.appendingPathComponent("ThermoTune \(day).csv")
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: Data((HistoryCSV.header(fanCount: fanCount) + "\n").utf8))
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func close() {
        try? handle?.close()
        handle = nil
        day = nil
    }
}
