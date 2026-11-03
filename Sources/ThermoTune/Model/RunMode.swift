import Foundation

enum RunMode {
    /// A `make shot` snapshot or the unit tests' host app. Either can run beside a
    /// copy of ThermoTune someone is using, so it shows readings but never drives
    /// or hands back the fans, posts notifications, registers shortcuts, changes
    /// the Dock or writes the log.
    static let isReadOnly = WindowSnapshot.isActive
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
