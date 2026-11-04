import AppKit
import Carbon.HIToolbox
import Observation

struct Shortcut: Codable, Hashable {
    /// `kVK_…`
    var keyCode: UInt32
    /// Device-independent `NSEvent.ModifierFlags` bits.
    var modifiers: UInt
    /// As typed when recorded, for display.
    var key: String

    var title: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var title = ""
        if flags.contains(.control) { title += "⌃" }
        if flags.contains(.option) { title += "⌥" }
        if flags.contains(.shift) { title += "⇧" }
        if flags.contains(.command) { title += "⌘" }
        return title + key.uppercased()
    }

    fileprivate var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

enum ShortcutAction: Hashable {
    case profile(UUID)
    case allMax
    case allAutomatic

    var storageKey: String {
        switch self {
        case .profile(let id): return "profile:\(id.uuidString)"
        case .allMax: return "allMax"
        case .allAutomatic: return "allAutomatic"
        }
    }
}

/// Carbon's `RegisterEventHotKey` works in any app without Accessibility permission.
@MainActor
@Observable
final class HotKeys {
    private(set) var shortcuts: [String: Shortcut]
    /// Usually because another app owns the combination.
    private(set) var failed: Set<String> = []
    /// The action whose shortcut is being recorded. One row at a time: only the
    /// first key monitor sees a keypress, so a second would never stop.
    var recording: String?

    @ObservationIgnored private var registered: [String: EventHotKeyRef] = [:]
    @ObservationIgnored private var idsByNumber: [UInt32: String] = [:]
    @ObservationIgnored private var nextNumber: UInt32 = 1
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored var perform: ((String) -> Void)?

    private static let signature: OSType = 0x5454_4b59 // "TTKY"

    init() {
        shortcuts = UserDefaults.standard.lenientDictionary(of: Shortcut.self, forKey: PreferenceKey.shortcuts) ?? [:]
    }

    func shortcut(for action: ShortcutAction) -> Shortcut? {
        shortcuts[action.storageKey]
    }

    func set(_ shortcut: Shortcut?, for action: ShortcutAction) {
        if let shortcut {
            for (key, existing) in shortcuts where existing.keyCode == shortcut.keyCode && existing.modifiers == shortcut.modifiers {
                shortcuts[key] = nil
            }
        }
        shortcuts[action.storageKey] = shortcut
        save()
    }

    func prune(profileIDs: Set<UUID>) {
        let stale = shortcuts.keys.filter { key in
            key.hasPrefix("profile:") && UUID(uuidString: String(key.dropFirst(8))).map { !profileIDs.contains($0) } ?? true
        }
        guard !stale.isEmpty else { return }
        for key in stale { shortcuts[key] = nil }
        save()
    }

    private func save() {
        UserDefaults.standard.setEncoded(shortcuts, forKey: PreferenceKey.shortcuts)
        registerAll()
    }

    func registerAll() {
        guard !RunMode.isReadOnly else { return }
        installHandler()
        unregisterAll()
        failed = []
        for (key, shortcut) in shortcuts {
            let number = nextNumber
            nextNumber += 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers,
                                             EventHotKeyID(signature: Self.signature, id: number),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[key] = ref
                idsByNumber[number] = key
            } else {
                failed.insert(key)
            }
        }
    }

    func unregisterAll() {
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered = [:]
        idsByNumber = [:]
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            // Carbon calls this on the main thread.
            MainActor.assumeIsolated {
                if let key = hotKeys.idsByNumber[id.id] { hotKeys.perform?(key) }
            }
            return noErr
        }, 1, &spec, context, &handler)
    }
}
