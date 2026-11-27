import Foundation

/// Declarative metadata and read/write accessors for a single configurable shortcut in Toolbox.
struct ShortcutDescriptor: Identifiable {
    let id: String
    let moduleID: String
    let moduleName: String
    let actionTitle: String
    let subtitle: String
    let registrationKey: String?
    let isPrimary: Bool
    let defaultSpec: ShortcutSpec
    let conflictDisplayLabel: String
    let isModuleEnabled: (ToolboxConfig) -> Bool
    let participatesInConflicts: (ToolboxConfig, String?) -> Bool
    let read: (ToolboxConfig) -> ShortcutSpec
    let write: (ShortcutSpec, inout ToolboxConfig) -> Void
}

/// Single declarative source of truth for all configurable shortcuts across Toolbox modules.
enum ShortcutCatalog {
    static let primaryWindowSnapperActions: Set<WindowSnapperHotKeyAction> = [
        .leftHalf,
        .rightHalf,
        .topHalf,
        .bottomHalf,
        .maximize
    ]

    static func descriptors(in config: ToolboxConfig) -> [ShortcutDescriptor] {
        var result: [ShortcutDescriptor] = []

        result.append(ShortcutDescriptor(
            id: "dock_minimize",
            moduleID: "dock_minimize",
            moduleName: "Dock Click to Minimize",
            actionTitle: "Toggle Dock Minimize",
            subtitle: "Enable or disable Dock Click to Minimize globally.",
            registrationKey: "dock_minimize.toggle",
            isPrimary: true,
            defaultSpec: .none,
            conflictDisplayLabel: "Dock Click to Minimize",
            isModuleEnabled: { $0.dockMinimize.enabled },
            participatesInConflicts: { _, _ in true },
            read: { $0.dockMinimize.shortcut },
            write: { spec, cfg in cfg.dockMinimize.shortcut = spec }
        ))

        result.append(ShortcutDescriptor(
            id: "clipboard",
            moduleID: "clipboard",
            moduleName: "Clipboard History",
            actionTitle: "Open Clipboard History",
            subtitle: "Show the searchable floating clipboard history popover.",
            registrationKey: "clipboard.toggle",
            isPrimary: true,
            defaultSpec: ClipboardConfig().shortcut,
            conflictDisplayLabel: "Clipboard History",
            isModuleEnabled: { $0.clipboard.enabled },
            participatesInConflicts: { cfg, _ in cfg.clipboard.enabled },
            read: { $0.clipboard.shortcut },
            write: { spec, cfg in cfg.clipboard.shortcut = spec }
        ))

        result.append(ShortcutDescriptor(
            id: "port_killer",
            moduleID: "port_killer",
            moduleName: "Port Killer",
            actionTitle: "Toggle Port Killer",
            subtitle: "Inspect listening TCP ports and terminate stuck dev servers.",
            registrationKey: "port_killer.toggle",
            isPrimary: true,
            defaultSpec: PortKillerConfig().shortcut,
            conflictDisplayLabel: "Port Killer",
            isModuleEnabled: { $0.portKiller.enabled },
            participatesInConflicts: { cfg, _ in cfg.portKiller.enabled },
            read: { $0.portKiller.shortcut },
            write: { spec, cfg in cfg.portKiller.shortcut = spec }
        ))

        result.append(ShortcutDescriptor(
            id: "screen_ocr",
            moduleID: "screen_ocr",
            moduleName: "Screen OCR",
            actionTitle: "Capture Screen Text / QR",
            subtitle: "Drag-select any screen region to copy text or QR payloads.",
            registrationKey: "screen_ocr.capture",
            isPrimary: true,
            defaultSpec: ScreenOCRConfig().shortcut,
            conflictDisplayLabel: "Screen OCR",
            isModuleEnabled: { $0.screenOCR.enabled },
            participatesInConflicts: { cfg, _ in cfg.screenOCR.enabled },
            read: { $0.screenOCR.shortcut },
            write: { spec, cfg in cfg.screenOCR.shortcut = spec }
        ))

        result.append(ShortcutDescriptor(
            id: "keep_awake",
            moduleID: "keep_awake",
            moduleName: "Keep Awake",
            actionTitle: "Toggle Keep Awake",
            subtitle: "Start or stop preventing Mac and display sleep.",
            registrationKey: "keep_awake.toggle",
            isPrimary: true,
            defaultSpec: KeepAwakeConfig().shortcut,
            conflictDisplayLabel: "Keep Awake",
            isModuleEnabled: { $0.keepAwake.enabled },
            participatesInConflicts: { cfg, _ in cfg.keepAwake.enabled },
            read: { $0.keepAwake.shortcut },
            write: { spec, cfg in cfg.keepAwake.shortcut = spec }
        ))

        let defaultCommandsByID = Dictionary(uniqueKeysWithValues: CustomCommand.defaults.map { ($0.id, $0.shortcut) })
        for cmd in config.customCommands.commands {
            let cmdID = cmd.id
            let cmdName = cmd.name
            result.append(ShortcutDescriptor(
                id: "custom_command.\(cmdID)",
                moduleID: "custom_commands",
                moduleName: "Custom Commands",
                actionTitle: cmdName,
                subtitle: cmd.kind.label,
                registrationKey: "custom_command.\(cmdID)",
                isPrimary: true,
                defaultSpec: defaultCommandsByID[cmdID] ?? .none,
                conflictDisplayLabel: "Custom Command '\(cmdName)'",
                isModuleEnabled: { $0.customCommands.enabled && ($0.customCommands.commands.first(where: { $0.id == cmdID })?.enabled ?? false) },
                participatesInConflicts: { cfg, _ in
                    cfg.customCommands.enabled && (cfg.customCommands.commands.first(where: { $0.id == cmdID })?.enabled ?? false)
                },
                read: { cfg in
                    cfg.customCommands.commands.first(where: { $0.id == cmdID })?.shortcut ?? .none
                },
                write: { spec, cfg in
                    if let idx = cfg.customCommands.commands.firstIndex(where: { $0.id == cmdID }) {
                        cfg.customCommands.commands[idx].shortcut = spec
                    }
                }
            ))
        }

        result.append(ShortcutDescriptor(
            id: "scroll_direction",
            moduleID: "scroll_direction",
            moduleName: "Scroll Direction",
            actionTitle: "Toggle Scroll Inversion",
            subtitle: "Enable or disable scroll wheel inversion globally.",
            registrationKey: "scroll_direction.toggle",
            isPrimary: true,
            defaultSpec: .none,
            conflictDisplayLabel: "Scroll Direction",
            isModuleEnabled: { $0.scrollDirection.enabled },
            participatesInConflicts: { _, _ in true },
            read: { $0.scrollDirection.shortcut },
            write: { spec, cfg in cfg.scrollDirection.shortcut = spec }
        ))

        let callParticipates: (ToolboxConfig, String?) -> Bool = { cfg, excludingSourceID in
            cfg.callControls.enabled || (excludingSourceID?.hasPrefix("call_controls.") == true)
        }
        result.append(ShortcutDescriptor(
            id: "call_controls.mic",
            moduleID: "call_controls",
            moduleName: "Call Controls",
            actionTitle: "Toggle Mic Mute",
            subtitle: "Unified mic mute across macOS and active call apps.",
            registrationKey: nil,
            isPrimary: true,
            defaultSpec: CallControlsConfig.defaultMicShortcut,
            conflictDisplayLabel: "Call Controls (Mic Keybind)",
            isModuleEnabled: { $0.callControls.enabled },
            participatesInConflicts: callParticipates,
            read: { $0.callControls.micShortcut },
            write: { spec, cfg in cfg.callControls.micShortcut = spec }
        ))
        result.append(ShortcutDescriptor(
            id: "call_controls.video",
            moduleID: "call_controls",
            moduleName: "Call Controls",
            actionTitle: "Toggle Camera Video",
            subtitle: "Toggle video in your active or background call app.",
            registrationKey: nil,
            isPrimary: true,
            defaultSpec: CallControlsConfig.defaultVideoShortcut,
            conflictDisplayLabel: "Call Controls (Video Keybind)",
            isModuleEnabled: { $0.callControls.enabled },
            participatesInConflicts: callParticipates,
            read: { $0.callControls.videoShortcut },
            write: { spec, cfg in cfg.callControls.videoShortcut = spec }
        ))
        result.append(ShortcutDescriptor(
            id: "call_controls.os_mute",
            moduleID: "call_controls",
            moduleName: "Call Controls",
            actionTitle: "OS Hardware Mic Mute",
            subtitle: "Directly mute or unmute the default macOS input device.",
            registrationKey: "call_controls.os_mute",
            isPrimary: false,
            defaultSpec: .none,
            conflictDisplayLabel: "Call Controls (OS Mic Mute)",
            isModuleEnabled: { $0.callControls.enabled },
            participatesInConflicts: callParticipates,
            read: { $0.callControls.osMuteShortcut },
            write: { spec, cfg in cfg.callControls.osMuteShortcut = spec }
        ))
        result.append(ShortcutDescriptor(
            id: "call_controls.cycle_output",
            moduleID: "call_controls",
            moduleName: "Call Controls",
            actionTitle: "Cycle Audio Output",
            subtitle: "Switch between your favorite audio output devices.",
            registrationKey: "call_controls.cycle_output",
            isPrimary: false,
            defaultSpec: .none,
            conflictDisplayLabel: "Call Controls (Cycle Output)",
            isModuleEnabled: { $0.callControls.enabled },
            participatesInConflicts: callParticipates,
            read: { $0.callControls.cycleOutputShortcut },
            write: { spec, cfg in cfg.callControls.cycleOutputShortcut = spec }
        ))

        let snapHotKeyParticipates: (ToolboxConfig, String?) -> Bool = { cfg, excludingSourceID in
            (cfg.windowSnapper.enabled && cfg.windowSnapper.keyboardSnappingEnabled)
                || (excludingSourceID?.hasPrefix("window_snapper.") == true)
        }
        let snapHotKeyDefaults = WindowSnapperHotKeys.toolboxSafe
        for action in WindowSnapperHotKeyAction.allCases {
            result.append(ShortcutDescriptor(
                id: action.sourceID,
                moduleID: "window_snapper",
                moduleName: "Window Snapper",
                actionTitle: action.label,
                subtitle: windowSnapperSubtitle(for: action),
                registrationKey: action.registrationName,
                isPrimary: primaryWindowSnapperActions.contains(action),
                defaultSpec: snapHotKeyDefaults.shortcut(for: action),
                conflictDisplayLabel: "Window Snapper (\(action.label))",
                isModuleEnabled: { $0.windowSnapper.enabled && $0.windowSnapper.keyboardSnappingEnabled },
                participatesInConflicts: snapHotKeyParticipates,
                read: { $0.windowSnapper.hotKeys.shortcut(for: action) },
                write: { spec, cfg in cfg.windowSnapper.hotKeys.setShortcut(spec, for: action) }
            ))
        }

        let snapProfileZoneParticipates: (ToolboxConfig, String?) -> Bool = { cfg, excludingSourceID in
            cfg.windowSnapper.enabled || (excludingSourceID?.hasPrefix("window_snapper.") == true)
        }
        for profile in config.windowSnapper.profiles {
            let profileID = profile.id
            let profileName = profile.name
            result.append(ShortcutDescriptor(
                id: "window_snapper.profile.\(profileID)",
                moduleID: "window_snapper",
                moduleName: "Window Snapper",
                actionTitle: "Profile: \(profileName)",
                subtitle: "Apply or restore workspace profile '\(profileName)'.",
                registrationKey: "window_snapper.profile.\(profileID)",
                isPrimary: false,
                defaultSpec: .none,
                conflictDisplayLabel: "Window Snapper Profile '\(profileName)'",
                isModuleEnabled: { $0.windowSnapper.enabled },
                participatesInConflicts: snapProfileZoneParticipates,
                read: { cfg in
                    cfg.windowSnapper.profiles.first(where: { $0.id == profileID })?.shortcut ?? .none
                },
                write: { spec, cfg in
                    if let idx = cfg.windowSnapper.profiles.firstIndex(where: { $0.id == profileID }) {
                        cfg.windowSnapper.profiles[idx].shortcut = spec
                    }
                }
            ))
        }

        for layout in config.windowSnapper.displayLayouts {
            let layoutID = layout.id
            for zone in layout.customZones {
                let zoneID = zone.id
                let zoneName = zone.name
                result.append(ShortcutDescriptor(
                    id: "window_snapper.zone.\(layoutID).\(zoneID)",
                    moduleID: "window_snapper",
                    moduleName: "Window Snapper",
                    actionTitle: "Zone: \(zoneName)",
                    subtitle: "Snap focused window to custom zone '\(zoneName)'.",
                    registrationKey: "window_snapper.zone.\(layoutID).\(zoneID)",
                    isPrimary: false,
                    defaultSpec: .none,
                    conflictDisplayLabel: "Window Snapper Zone '\(zoneName)'",
                    isModuleEnabled: { $0.windowSnapper.enabled },
                    participatesInConflicts: snapProfileZoneParticipates,
                    read: { cfg in
                        cfg.windowSnapper.displayLayouts
                            .first(where: { $0.id == layoutID })?
                            .customZones
                            .first(where: { $0.id == zoneID })?
                            .shortcut ?? .none
                    },
                    write: { spec, cfg in
                        guard let lIdx = cfg.windowSnapper.displayLayouts.firstIndex(where: { $0.id == layoutID }),
                              let zIdx = cfg.windowSnapper.displayLayouts[lIdx].customZones.firstIndex(where: { $0.id == zoneID }) else {
                            return
                        }
                        cfg.windowSnapper.displayLayouts[lIdx].customZones[zIdx].shortcut = spec
                    }
                ))
            }
        }

        result.append(ShortcutDescriptor(
            id: "window_switcher.current_app",
            moduleID: "window_switcher",
            moduleName: "Window Switcher",
            actionTitle: "Switch Current App Windows",
            subtitle: "Open Window Switcher filtered to windows of the frontmost app.",
            registrationKey: "window_switcher.current_app",
            isPrimary: true,
            defaultSpec: .none,
            conflictDisplayLabel: "Window Switcher (Current App Only)",
            isModuleEnabled: { $0.windowSwitcher.enabled },
            participatesInConflicts: { cfg, _ in cfg.windowSwitcher.enabled },
            read: { $0.windowSwitcher.currentAppOnlyShortcut },
            write: { spec, cfg in cfg.windowSwitcher.currentAppOnlyShortcut = spec }
        ))

        return result
    }

    static var allStaticDefaults: [ShortcutDescriptor] {
        descriptors(in: ToolboxConfig())
    }

    static func inAppConflictDescription(
        for shortcut: ShortcutSpec,
        excludingSourceID: String?,
        in config: ToolboxConfig
    ) -> String? {
        guard !shortcut.isEmpty else { return nil }
        var matches: [String] = []
        for descriptor in descriptors(in: config) {
            guard descriptor.id != excludingSourceID,
                  descriptor.participatesInConflicts(config, excludingSourceID) else {
                continue
            }
            let current = descriptor.read(config)
            if !current.isEmpty && current == shortcut {
                matches.append(descriptor.conflictDisplayLabel)
            }
        }
        guard !matches.isEmpty else { return nil }
        return "Conflicts with \(matches.joined(separator: ", ")) (\(shortcut.displayString))."
    }

    static func clearConflictingShortcuts(
        matching shortcut: ShortcutSpec,
        excludingSourceID: String?,
        in config: inout ToolboxConfig
    ) {
        guard !shortcut.isEmpty else { return }
        let snapshot = descriptors(in: config)
        for descriptor in snapshot {
            guard descriptor.id != excludingSourceID,
                  descriptor.participatesInConflicts(config, excludingSourceID) else {
                continue
            }
            if descriptor.read(config) == shortcut {
                descriptor.write(.none, &config)
            }
        }
    }

    @MainActor
    static func activeConflictDescriptorIDs(
        in config: ToolboxConfig,
        hotKeyManager: HotKeyManager
    ) -> Set<String> {
        var conflicts = Set<String>()
        for descriptor in descriptors(in: config) {
            let shortcut = descriptor.read(config)
            guard !shortcut.isEmpty, descriptor.participatesInConflicts(config, nil) else { continue }
            if hotKeyManager.inAppConflictDescription(for: shortcut, excludingSourceID: descriptor.id, in: config) != nil {
                conflicts.insert(descriptor.id)
                continue
            }
            if let regKey = descriptor.registrationKey, hotKeyManager.registrationErrors[regKey] != nil {
                conflicts.insert(descriptor.id)
                continue
            }
            if hotKeyManager.systemOrMenuConflictDescription(for: shortcut) != nil {
                conflicts.insert(descriptor.id)
            }
        }
        return conflicts
    }

    static func activeBindingCount(in config: ToolboxConfig) -> Int {
        descriptors(in: config).reduce(0) { count, descriptor in
            let shortcut = descriptor.read(config)
            return count + (descriptor.isModuleEnabled(config) && !shortcut.isEmpty ? 1 : 0)
        }
    }

    static func resetAllShortcutsToDefaults(in config: inout ToolboxConfig) {
        let snapshot = descriptors(in: config)
        for descriptor in snapshot {
            descriptor.write(descriptor.defaultSpec, &config)
        }
    }

    private static func windowSnapperSubtitle(for action: WindowSnapperHotKeyAction) -> String {
        switch action {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf:
            return "Cycles 1/2, 2/3, 1/3 on repeated presses."
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return "Snaps window into display quadrant."
        case .maximize:
            return "Fills the usable display area edge-to-edge."
        case .center:
            return "Centers window using your configured size fraction."
        case .previousDisplay, .nextDisplay:
            return "Moves window to adjacent display preserving zone proportion."
        case .restorePreSnap:
            return "Returns focused window to its pre-snap frame."
        }
    }
}
