import Foundation

enum RunMode {
    /// A `make shot` snapshot or the test host, either of which can run beside the
    /// owner's copy: it reads, but never touches the fans, notifications, shortcuts,
    /// the Dock or the log.
    static let isReadOnly = WindowSnapshot.isActive
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
