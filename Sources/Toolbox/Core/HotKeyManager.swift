import Carbon
import Foundation

/// Centralized Carbon global hotkey manager supporting multiple named bindings across modules.
@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    private struct Registration {
        let hotKeyRef: EventHotKeyRef
        let handler: @MainActor () -> Void
    }

    @Published private(set) var registrationErrors: [String: String] = [:]

    private var nextID: UInt32 = 1
    private var registrationsByName: [String: UInt32] = [:]
    private var registrationsByID: [UInt32: Registration] = [:]
    private var eventHandlerRef: EventHandlerRef?

    private init() {
        installHandlerIfNeeded()
    }

    @discardableResult
    func register(name: String, shortcut: ShortcutSpec, handler: @escaping @MainActor () -> Void) -> Bool {
        unregister(name: name)

        guard let keyCode = shortcut.carbonKeyCode else {
            let msg = "Unknown key '\(shortcut.key)'"
            registrationErrors[name] = msg
            NSLog("Toolbox: \(msg) for shortcut '\(name)'")
            return false
        }

        installHandlerIfNeeded()

        let id = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }

        let hotKeyID = EventHotKeyID(signature: OSType(0x544C4258), id: id) // 'TLBX'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            let msg = status == OSStatus(eventHotKeyExistsErr)
                ? "Shortcut \(shortcut.displayString) is already in use by another app or macOS."
                : "Failed to register \(shortcut.displayString) (OSStatus \(status))."
            registrationErrors[name] = msg
            NSLog("Toolbox: \(msg)")
            return false
        }

        registrationErrors.removeValue(forKey: name)
        registrationsByName[name] = id
        registrationsByID[id] = Registration(hotKeyRef: ref, handler: handler)
        return true
    }

    func unregister(name: String) {
        registrationErrors.removeValue(forKey: name)
        guard let id = registrationsByName.removeValue(forKey: name),
              let reg = registrationsByID.removeValue(forKey: id) else {
            return
        }
        UnregisterEventHotKey(reg.hotKeyRef)
    }

    func unregisterAll(prefix: String) {
        let matching = registrationsByName.keys.filter { $0.hasPrefix(prefix) }
        for name in matching {
            unregister(name: name)
        }
    }

    func isRegistered(name: String) -> Bool {
        registrationsByName[name] != nil
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr else { return noErr }

                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                let triggeredID = hotKeyID.id
                Task { @MainActor in
                    manager.dispatch(id: triggeredID)
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }

    private func dispatch(id: UInt32) {
        registrationsByID[id]?.handler()
    }

    /// Checks whether `shortcut` collides with another enabled shortcut in `config`.
    /// `excludingSourceID` is `"clipboard"`, `"keep_awake"`, or `"custom_command.<id>"`.
    func inAppConflictDescription(
        for shortcut: ShortcutSpec,
        excludingSourceID: String?,
        in config: ToolboxConfig
    ) -> String? {
        var matches: [String] = []
        if excludingSourceID != "clipboard",
           config.clipboard.enabled,
           config.clipboard.shortcut == shortcut {
            matches.append("Clipboard History")
        }
        if excludingSourceID != "keep_awake",
           config.keepAwake.enabled,
           config.keepAwake.shortcut == shortcut {
            matches.append("Keep Awake")
        }
        if config.customCommands.enabled {
            for cmd in config.customCommands.commands where cmd.enabled {
                let sourceID = "custom_command.\(cmd.id)"
                if sourceID != excludingSourceID && cmd.shortcut == shortcut {
                    matches.append("Custom Command '\(cmd.name)'")
                }
            }
        }
        guard !matches.isEmpty else { return nil }
        return "Conflicts with \(matches.joined(separator: ", ")) (\(shortcut.displayString))."
    }
}
