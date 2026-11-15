import AppKit
import Carbon
import Foundation

/// Read-only snapshot of an active registration inside `HotKeyManager`.
struct RegisteredHotKeySnapshot: Identifiable, Sendable {
    let id: UInt32
    let name: String
    let shortcut: ShortcutSpec
    let isArmed: Bool
}

/// Centralized Carbon global hotkey manager supporting multiple named bindings across modules.
@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    private struct Registration {
        let name: String
        let shortcut: ShortcutSpec
        var hotKeyRef: EventHotKeyRef?
        let handler: @MainActor () -> Void
    }

    @Published private(set) var registrationErrors: [String: String] = [:]
    @Published private(set) var isSuspendedForRecording: Bool = false

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

        if shortcut.isEmpty {
            return true
        }

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

        if isSuspendedForRecording {
            registrationErrors.removeValue(forKey: name)
            registrationsByName[name] = id
            registrationsByID[id] = Registration(
                name: name,
                shortcut: shortcut,
                hotKeyRef: nil,
                handler: handler
            )
            return true
        }

        guard let ref = armHotKey(id: id, name: name, shortcut: shortcut, keyCode: keyCode) else {
            return false
        }

        registrationsByName[name] = id
        registrationsByID[id] = Registration(
            name: name,
            shortcut: shortcut,
            hotKeyRef: ref,
            handler: handler
        )
        return true
    }

    func unregister(name: String) {
        registrationErrors.removeValue(forKey: name)
        guard let id = registrationsByName.removeValue(forKey: name),
              let reg = registrationsByID.removeValue(forKey: id) else {
            return
        }
        if let ref = reg.hotKeyRef {
            UnregisterEventHotKey(ref)
        }
    }

    /// Temporarily disarms active Carbon hotkeys while a shortcut recorder is listening,
    /// then re-arms them when recording finishes so existing bindings can be re-recorded.
    func setSuspendedForRecording(_ suspended: Bool) {
        guard suspended != isSuspendedForRecording else { return }
        isSuspendedForRecording = suspended

        if suspended {
            for id in Array(registrationsByID.keys) {
                if let ref = registrationsByID[id]?.hotKeyRef {
                    UnregisterEventHotKey(ref)
                    registrationsByID[id]?.hotKeyRef = nil
                }
            }
        } else {
            installHandlerIfNeeded()
            for id in Array(registrationsByID.keys) {
                guard var reg = registrationsByID[id], reg.hotKeyRef == nil else { continue }
                guard let keyCode = reg.shortcut.carbonKeyCode else { continue }
                if let ref = armHotKey(id: id, name: reg.name, shortcut: reg.shortcut, keyCode: keyCode) {
                    reg.hotKeyRef = ref
                    registrationsByID[id] = reg
                }
            }
        }
    }

    private func armHotKey(
        id: UInt32,
        name: String,
        shortcut: ShortcutSpec,
        keyCode: UInt32
    ) -> EventHotKeyRef? {
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
            DeveloperEventLog.shared.record(.hotkeys, "Failed registering '\(name)'", detail: msg)
            NSLog("Toolbox: \(msg)")
            return nil
        }

        registrationErrors.removeValue(forKey: name)
        return ref
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

    var registeredHotKeys: [RegisteredHotKeySnapshot] {
        registrationsByID
            .map { id, reg in
                RegisteredHotKeySnapshot(
                    id: id,
                    name: reg.name,
                    shortcut: reg.shortcut,
                    isArmed: reg.hotKeyRef != nil
                )
            }
            .sorted { $0.name < $1.name }
    }

    @discardableResult
    func simulateTrigger(name: String) -> Bool {
        guard let id = registrationsByName[name], let reg = registrationsByID[id] else {
            return false
        }
        DeveloperEventLog.shared.record(.hotkeys, "Simulated trigger: \(reg.name)", detail: reg.shortcut.displayString)
        reg.handler()
        return true
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
        guard let reg = registrationsByID[id] else { return }
        DeveloperEventLog.shared.record(.hotkeys, "Triggered hotkey: \(reg.name)", detail: reg.shortcut.displayString)
        reg.handler()
    }

    /// Checks whether `shortcut` collides with another active shortcut in `config`.
    /// `excludingSourceID` is `"clipboard"`, `"keep_awake"`, `"scroll_direction"`,
    /// `"dock_minimize"`, or `"custom_command.<id>"`.
    func inAppConflictDescription(
        for shortcut: ShortcutSpec,
        excludingSourceID: String?,
        in config: ToolboxConfig
    ) -> String? {
        guard !shortcut.isEmpty else { return nil }
        var matches: [String] = []
        if excludingSourceID != "clipboard",
           config.clipboard.enabled,
           !config.clipboard.shortcut.isEmpty,
           config.clipboard.shortcut == shortcut {
            matches.append("Clipboard History")
        }
        if excludingSourceID != "port_killer",
           config.portKiller.enabled,
           !config.portKiller.shortcut.isEmpty,
           config.portKiller.shortcut == shortcut {
            matches.append("Port Killer")
        }
        if excludingSourceID != "keep_awake",
           config.keepAwake.enabled,
           !config.keepAwake.shortcut.isEmpty,
           config.keepAwake.shortcut == shortcut {
            matches.append("Keep Awake")
        }
        if excludingSourceID != "scroll_direction",
           !config.scrollDirection.shortcut.isEmpty,
           config.scrollDirection.shortcut == shortcut {
            matches.append("Scroll Direction")
        }
        if excludingSourceID != "dock_minimize",
           !config.dockMinimize.shortcut.isEmpty,
           config.dockMinimize.shortcut == shortcut {
            matches.append("Dock Click to Minimize")
        }
        if config.customCommands.enabled {
            for cmd in config.customCommands.commands where cmd.enabled && !cmd.shortcut.isEmpty {
                let sourceID = "custom_command.\(cmd.id)"
                if sourceID != excludingSourceID && cmd.shortcut == shortcut {
                    matches.append("Custom Command '\(cmd.name)'")
                }
            }
        }
        guard !matches.isEmpty else { return nil }
        return "Conflicts with \(matches.joined(separator: ", ")) (\(shortcut.displayString))."
    }

    /// Unbinds any other active shortcut in `config` that collides with `shortcut`.
    func clearConflictingShortcuts(
        matching shortcut: ShortcutSpec,
        excludingSourceID: String?,
        in config: inout ToolboxConfig
    ) {
        guard !shortcut.isEmpty else { return }
        if excludingSourceID != "clipboard",
           config.clipboard.enabled,
           config.clipboard.shortcut == shortcut {
            config.clipboard.shortcut = .none
        }
        if excludingSourceID != "port_killer",
           config.portKiller.enabled,
           config.portKiller.shortcut == shortcut {
            config.portKiller.shortcut = .none
        }
        if excludingSourceID != "keep_awake",
           config.keepAwake.enabled,
           config.keepAwake.shortcut == shortcut {
            config.keepAwake.shortcut = .none
        }
        if excludingSourceID != "scroll_direction",
           config.scrollDirection.shortcut == shortcut {
            config.scrollDirection.shortcut = .none
        }
        if excludingSourceID != "dock_minimize",
           config.dockMinimize.shortcut == shortcut {
            config.dockMinimize.shortcut = .none
        }
        if config.customCommands.enabled {
            for idx in config.customCommands.commands.indices {
                let cmd = config.customCommands.commands[idx]
                let sourceID = "custom_command.\(cmd.id)"
                if cmd.enabled && sourceID != excludingSourceID && cmd.shortcut == shortcut {
                    config.customCommands.commands[idx].shortcut = .none
                }
            }
        }
    }

    /// Checks whether `shortcut` collides with a Toolbox main-menu shortcut or an active macOS system shortcut.
    func systemOrMenuConflictDescription(for shortcut: ShortcutSpec) -> String? {
        guard !shortcut.isEmpty else { return nil }

        if let menuTitle = matchingMainMenuItemTitle(for: shortcut) {
            return "Used by Toolbox menu item “\(menuTitle)”."
        }

        if Self.alwaysReservedSystemShortcuts.contains(shortcut),
           let description = Self.wellKnownSystemShortcuts[shortcut] {
            return "Reserved by macOS (\(description))."
        }

        if isEnabledSymbolicHotKey(shortcut) {
            if let description = Self.wellKnownSystemShortcuts[shortcut] {
                return "Active macOS system shortcut (\(description))."
            }
            return "Active macOS system shortcut (System Settings → Keyboard Shortcuts)."
        }

        return nil
    }

    private static let symbolicModifierMask = UInt32(cmdKey | optionKey | shiftKey | controlKey)

    private static let wellKnownSystemShortcuts: [ShortcutSpec: String] = [
        ShortcutSpec(key: "space", modifiers: [.command]): "Spotlight Search",
        ShortcutSpec(key: "space", modifiers: [.command, .option]): "Finder Search Window",
        ShortcutSpec(key: "space", modifiers: [.control]): "Input Source Switching",
        ShortcutSpec(key: "space", modifiers: [.control, .shift]): "Input Source Switching",
        ShortcutSpec(key: "space", modifiers: [.control, .command]): "Emoji & Symbols Picker",
        ShortcutSpec(key: "3", modifiers: [.command, .shift]): "Save Screen Screenshot",
        ShortcutSpec(key: "4", modifiers: [.command, .shift]): "Save Area Screenshot",
        ShortcutSpec(key: "5", modifiers: [.command, .shift]): "Screenshot & Recording Options",
        ShortcutSpec(key: "up", modifiers: [.control]): "Mission Control",
        ShortcutSpec(key: "down", modifiers: [.control]): "Application Windows",
        ShortcutSpec(key: "left", modifiers: [.control]): "Move Left a Space",
        ShortcutSpec(key: "right", modifiers: [.control]): "Move Right a Space",
        ShortcutSpec(key: "tab", modifiers: [.command]): "macOS App Switcher",
        ShortcutSpec(key: "tab", modifiers: [.command, .shift]): "macOS App Switcher (Reverse)",
        ShortcutSpec(key: "q", modifiers: [.control, .command]): "Lock Screen",
        ShortcutSpec(key: "h", modifiers: [.command]): "Hide Active Application",
        ShortcutSpec(key: "h", modifiers: [.command, .option]): "Hide Other Applications",
        ShortcutSpec(key: "m", modifiers: [.command]): "Minimize Window",
        ShortcutSpec(key: "d", modifiers: [.command, .option]): "Toggle Dock Hiding",
        ShortcutSpec(key: "m", modifiers: [.command, .option]): "Minimize All Windows",
        ShortcutSpec(key: "l", modifiers: [.command, .option]): "Downloads / Format Code",
        ShortcutSpec(key: "p", modifiers: [.command, .option]): "Toggle Path Bar (Finder)",
        ShortcutSpec(key: "b", modifiers: [.command, .option]): "Toggle Bookmarks Bar",
        ShortcutSpec(key: "i", modifiers: [.command, .option]): "Inspector / DevTools",
        ShortcutSpec(key: "c", modifiers: [.command, .option]): "DevTools Console / Copy Path"
    ]

    private static let alwaysReservedSystemShortcuts: Set<ShortcutSpec> = [
        ShortcutSpec(key: "tab", modifiers: [.command]),
        ShortcutSpec(key: "tab", modifiers: [.command, .shift]),
        ShortcutSpec(key: "q", modifiers: [.control, .command]),
        ShortcutSpec(key: "space", modifiers: [.control, .command]),
        ShortcutSpec(key: "h", modifiers: [.command]),
        ShortcutSpec(key: "h", modifiers: [.command, .option]),
        ShortcutSpec(key: "m", modifiers: [.command])
    ]

    private func isEnabledSymbolicHotKey(_ shortcut: ShortcutSpec) -> Bool {
        guard let targetCode = shortcut.carbonKeyCode else { return false }
        var rawArray: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&rawArray)
        guard status == noErr,
              let hotKeys = rawArray?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }

        let targetMods = shortcut.carbonModifiers & Self.symbolicModifierMask
        for entry in hotKeys {
            guard let enabled = (entry["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue, enabled,
                  let code = (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value,
                  let mods = (entry["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else {
                continue
            }
            if code == targetCode && (mods & Self.symbolicModifierMask) == targetMods {
                return true
            }
        }
        return false
    }

    private func matchingMainMenuItemTitle(for shortcut: ShortcutSpec) -> String? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        let targetKey = shortcut.key.lowercased()
        let targetLabel = shortcut.keyDisplayLabel.lowercased()
        let targetMods = Set(shortcut.modifiers)

        func search(menu: NSMenu) -> String? {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty {
                    let rawKey = item.keyEquivalent.lowercased()
                    let needsShiftFromUppercase = item.keyEquivalent != rawKey
                    var itemMods = Set(KeyModifier.from(eventFlags: item.keyEquivalentModifierMask))
                    if needsShiftFromUppercase {
                        itemMods.insert(.shift)
                    }
                    let normalizedItemKey: String = {
                        switch rawKey {
                        case " ": return "space"
                        case "\r": return "return"
                        case "\t": return "tab"
                        case "\u{08}", "\u{7F}": return "delete"
                        default: return rawKey
                        }
                    }()
                    if (normalizedItemKey == targetKey || normalizedItemKey == targetLabel),
                       itemMods == targetMods {
                        return item.title.isEmpty ? "Menu Action" : item.title
                    }
                }
                if let submenu = item.submenu, let match = search(menu: submenu) {
                    return match
                }
            }
            return nil
        }

        return search(menu: mainMenu)
    }
}
