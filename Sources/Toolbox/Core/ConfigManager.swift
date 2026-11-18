import Foundation
import Combine

enum DockActionMode: String, Codable, CaseIterable, Sendable {
    case hideApp = "hide_app"
    case sendToBack = "send_to_back"
    case minimizeAll = "minimize_all"
    case minimizeFrontWindow = "minimize_front_window"

    var label: String {
        switch self {
        case .hideApp: return "Hide & Restore Windows (Windows Style)"
        case .sendToBack: return "Send Behind Previous App (Keep Visible)"
        case .minimizeAll: return "Minimize All to Dock Tray"
        case .minimizeFrontWindow: return "Minimize Front Window to Dock Tray"
        }
    }

    var explanation: String {
        switch self {
        case .hideApp:
            return "Makes the active app's windows disappear completely without using the Dock's minimized tray, focuses the window underneath, and brings the app right back to the front when clicked again."
        case .sendToBack:
            return "Switches focus to the window directly behind the active app while keeping the current window visible on screen underneath."
        case .minimizeAll:
            return "Minimizes every open window of the active app into the right side of the Dock and focuses the window underneath."
        case .minimizeFrontWindow:
            return "Minimizes only the frontmost window into the Dock tray while leaving the app's other windows visible."
        }
    }
}

enum DockClickMode: String, Codable, CaseIterable, Sendable {
    case singleClick = "single_click"
    case doubleClick = "double_click"

    var label: String {
        switch self {
        case .singleClick: return "Single Click"
        case .doubleClick: return "Double Click"
        }
    }
}

enum KeepAwakeStrategy: String, Codable, CaseIterable, Sendable {
    case smartMouseJiggle = "smart_mouse_jiggle"
    case powerAssertion = "power_assertion"
    case both = "both"

    var label: String {
        switch self {
        case .smartMouseJiggle: return "Smart Mouse Jiggle (Before Screen Off)"
        case .powerAssertion: return "Power Assertion (IOKit)"
        case .both: return "Both (Assertion + Smart Jiggle)"
        }
    }
}

enum ScrollTarget: String, Codable, CaseIterable, Sendable {
    case mouse = "mouse"
    case trackpad = "trackpad"

    var label: String {
        switch self {
        case .mouse: return "Mouse"
        case .trackpad: return "Trackpad"
        }
    }

    var explanation: String {
        switch self {
        case .mouse:
            return "Inverts classic mouse wheels. Line based scroll events are flipped; the trackpad keeps the system setting."
        case .trackpad:
            return "Inverts trackpad style (pixel based) scroll events, including high resolution mice such as the Magic Mouse."
        }
    }
}

enum DockQuitBehavior: String, Codable, CaseIterable, Sendable {
    case quitApp = "quit_app"
    case closeWindow = "close_window"

    var displayName: String {
        switch self {
        case .quitApp: return "Quit Toolbox"
        case .closeWindow: return "Close Window (Keep Running)"
        }
    }
}

struct GeneralConfig: Codable, Equatable, Sendable {
    static let defaultMenuBarModuleOrder: [String] = [
        "dock_minimize",
        "clipboard",
        "port_killer",
        "screen_ocr",
        "keep_awake",
        "custom_commands",
        "scroll_direction",
        "call_controls"
    ]

    var appEnabled: Bool = true
    var showInMenuBar: Bool = true
    var showInDock: Bool = true
    var openDashboardOnLaunch: Bool = true
    var openDashboardOnDockClick: Bool = true
    var dockQuitBehavior: DockQuitBehavior = .closeWindow
    var launchAtLogin: Bool = false
    var hasSeenAccessibilityOnboarding: Bool = false
    var menuBarModuleOrder: [String] = GeneralConfig.defaultMenuBarModuleOrder
    var menuBarHiddenModules: [String] = []
    var showQuickActionsInMenuBar: Bool = true
    var showQuickCommandsInMenuBar: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appEnabled = try c.decodeIfPresent(Bool.self, forKey: .appEnabled) ?? true
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? true
        openDashboardOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .openDashboardOnLaunch) ?? true
        openDashboardOnDockClick = try c.decodeIfPresent(Bool.self, forKey: .openDashboardOnDockClick) ?? true
        dockQuitBehavior = try c.decodeIfPresent(DockQuitBehavior.self, forKey: .dockQuitBehavior) ?? .closeWindow
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        hasSeenAccessibilityOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasSeenAccessibilityOnboarding) ?? false
        let decodedOrder = try c.decodeIfPresent([String].self, forKey: .menuBarModuleOrder) ?? Self.defaultMenuBarModuleOrder
        menuBarModuleOrder = decodedOrder.map { $0 == "audio_guard" ? "call_controls" : $0 }
        let decodedHidden = try c.decodeIfPresent([String].self, forKey: .menuBarHiddenModules) ?? []
        menuBarHiddenModules = decodedHidden.map { $0 == "audio_guard" ? "call_controls" : $0 }
        showQuickActionsInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showQuickActionsInMenuBar) ?? true
        showQuickCommandsInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showQuickCommandsInMenuBar) ?? true
    }

    func normalizedMenuBarModuleOrder(allModuleIDs: [String] = GeneralConfig.defaultMenuBarModuleOrder) -> [String] {
        let validSet = Set(allModuleIDs)
        var seen = Set<String>()
        var result: [String] = []

        for id in menuBarModuleOrder where validSet.contains(id) && !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        for id in allModuleIDs where !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    func isModuleVisibleInMenuBar(_ id: String) -> Bool {
        !menuBarHiddenModules.contains(id)
    }

    mutating func setModuleVisibleInMenuBar(_ id: String, visible: Bool) {
        if visible {
            menuBarHiddenModules.removeAll { $0 == id }
        } else if !menuBarHiddenModules.contains(id) {
            menuBarHiddenModules.append(id)
        }
    }

    mutating func moveModuleInMenuBar(
        id: String,
        direction: Int,
        allModuleIDs: [String] = GeneralConfig.defaultMenuBarModuleOrder
    ) {
        var order = normalizedMenuBarModuleOrder(allModuleIDs: allModuleIDs)
        guard direction != 0,
              let index = order.firstIndex(of: id) else { return }
        let targetIndex = index + direction
        guard targetIndex >= 0 && targetIndex < order.count else { return }
        order.swapAt(index, targetIndex)
        menuBarModuleOrder = order
    }

    mutating func moveModuleInMenuBar(
        fromId: String,
        toId: String,
        allModuleIDs: [String] = GeneralConfig.defaultMenuBarModuleOrder
    ) {
        var order = normalizedMenuBarModuleOrder(allModuleIDs: allModuleIDs)
        guard let fromIndex = order.firstIndex(of: fromId),
              let toIndex = order.firstIndex(of: toId),
              fromIndex != toIndex else { return }
        let item = order.remove(at: fromIndex)
        order.insert(item, at: toIndex)
        menuBarModuleOrder = order
    }

    var hasCustomMenuBarLayout: Bool {
        normalizedMenuBarModuleOrder() != Self.defaultMenuBarModuleOrder
            || !menuBarHiddenModules.isEmpty
            || !showQuickActionsInMenuBar
            || !showQuickCommandsInMenuBar
    }

    mutating func resetMenuBarLayout() {
        menuBarModuleOrder = Self.defaultMenuBarModuleOrder
        menuBarHiddenModules = []
        showQuickActionsInMenuBar = true
        showQuickCommandsInMenuBar = true
    }
}

struct DockMinimizeConfig: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var actionMode: DockActionMode = .hideApp
    var clickMode: DockClickMode = .singleClick
    var ignoreModifiedClicks: Bool = true
    var excludedBundleIDs: [String] = []
    var shortcut: ShortcutSpec = .none

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        if let mode = try c.decodeIfPresent(DockActionMode.self, forKey: .actionMode) {
            actionMode = mode
        } else if let legacyHide = try c.decodeIfPresent(Bool.self, forKey: .hideInsteadOfMinimize) {
            actionMode = legacyHide ? .hideApp : .minimizeAll
        } else {
            actionMode = .hideApp
        }
        clickMode = try c.decodeIfPresent(DockClickMode.self, forKey: .clickMode) ?? .singleClick
        ignoreModifiedClicks = try c.decodeIfPresent(Bool.self, forKey: .ignoreModifiedClicks) ?? true
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? []
        shortcut = try c.decodeIfPresent(ShortcutSpec.self, forKey: .shortcut) ?? .none
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(actionMode, forKey: .actionMode)
        try c.encode(clickMode, forKey: .clickMode)
        try c.encode(ignoreModifiedClicks, forKey: .ignoreModifiedClicks)
        try c.encode(excludedBundleIDs, forKey: .excludedBundleIDs)
        try c.encode(shortcut, forKey: .shortcut)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, actionMode, clickMode, ignoreModifiedClicks, excludedBundleIDs, shortcut
        case hideInsteadOfMinimize
    }
}

struct ClipboardConfig: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var shortcut: ShortcutSpec = ShortcutSpec(key: "v", modifiers: [.command, .option])
    var maxItems: Int = 25
    var pollIntervalMs: Int = 300
    var pasteAutomatically: Bool = true
    var deduplicate: Bool = true
    var ignoreConcealedTypes: Bool = true
    var persistHistory: Bool = true
    var popoverWidth: Int = 420
    var popoverHeight: Int = 460

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        shortcut = try c.decodeIfPresent(ShortcutSpec.self, forKey: .shortcut)
            ?? ShortcutSpec(key: "v", modifiers: [.command, .option])
        maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? 25
        pollIntervalMs = try c.decodeIfPresent(Int.self, forKey: .pollIntervalMs) ?? 300
        pasteAutomatically = try c.decodeIfPresent(Bool.self, forKey: .pasteAutomatically) ?? true
        deduplicate = try c.decodeIfPresent(Bool.self, forKey: .deduplicate) ?? true
        ignoreConcealedTypes = try c.decodeIfPresent(Bool.self, forKey: .ignoreConcealedTypes) ?? true
        persistHistory = try c.decodeIfPresent(Bool.self, forKey: .persistHistory) ?? true
        popoverWidth = try c.decodeIfPresent(Int.self, forKey: .popoverWidth) ?? 420
        popoverHeight = try c.decodeIfPresent(Int.self, forKey: .popoverHeight) ?? 460
    }
}

struct KeepAwakeConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var activeOnLaunch: Bool = false
    var strategy: KeepAwakeStrategy = .both
    var shortcut: ShortcutSpec = ShortcutSpec(key: "k", modifiers: [.command, .option])
    var defaultDurationMinutes: Int = 60 // 0 = indefinite
    var preventDisplaySleep: Bool = true
    var jiggleLeadSeconds: Int = 20
    var fallbackJiggleIntervalSeconds: Int = 240

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        activeOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .activeOnLaunch) ?? false
        strategy = try c.decodeIfPresent(KeepAwakeStrategy.self, forKey: .strategy) ?? .both
        shortcut = try c.decodeIfPresent(ShortcutSpec.self, forKey: .shortcut)
            ?? ShortcutSpec(key: "k", modifiers: [.command, .option])
        defaultDurationMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultDurationMinutes) ?? 60
        preventDisplaySleep = try c.decodeIfPresent(Bool.self, forKey: .preventDisplaySleep) ?? true
        jiggleLeadSeconds = try c.decodeIfPresent(Int.self, forKey: .jiggleLeadSeconds) ?? 20
        fallbackJiggleIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .fallbackJiggleIntervalSeconds) ?? 240
    }
}

enum CustomCommandKind: String, Codable, CaseIterable, Sendable {
    case shell = "shell"
    case openApp = "open_app"
    case openURL = "open_url"
    case pasteText = "paste_text"

    var label: String {
        switch self {
        case .shell: return "Shell Command"
        case .openApp: return "Open Application"
        case .openURL: return "Open URL"
        case .pasteText: return "Paste Text Snippet"
        }
    }

    var placeholder: String {
        switch self {
        case .shell: return "e.g. open ~/Projects"
        case .openApp: return "e.g. /Applications/Visual Studio Code.app"
        case .openURL: return "e.g. https://github.com"
        case .pasteText: return "e.g. Best regards,"
        }
    }
}

struct CustomCommand: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var enabled: Bool = true
    var shortcut: ShortcutSpec
    var kind: CustomCommandKind
    var payload: String
    var showNotification: Bool = false

    static var defaults: [CustomCommand] {
        [
            CustomCommand(
                id: "open-terminal",
                name: "Open Terminal",
                enabled: false,
                shortcut: ShortcutSpec(key: "t", modifiers: [.command, .option]),
                kind: .openApp,
                payload: "/System/Applications/Utilities/Terminal.app",
                showNotification: false
            ),
            CustomCommand(
                id: "copy-local-ip",
                name: "Copy Local IP",
                enabled: false,
                shortcut: ShortcutSpec(key: "i", modifiers: [.command, .option, .shift]),
                kind: .shell,
                payload: "(ipconfig getifaddr en0 || ipconfig getifaddr en1) | tr -d '\\n' | pbcopy",
                showNotification: true
            ),
            CustomCommand(
                id: "copy-iso-timestamp",
                name: "Copy ISO Timestamp",
                enabled: false,
                shortcut: ShortcutSpec(key: "d", modifiers: [.command, .option, .shift]),
                kind: .shell,
                payload: "date -u +\"%Y-%m-%dT%H:%M:%SZ\" | tr -d '\\n' | pbcopy",
                showNotification: true
            )
        ]
    }
}

struct CustomCommandsConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var commands: [CustomCommand] = CustomCommand.defaults

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        commands = try c.decodeIfPresent([CustomCommand].self, forKey: .commands) ?? CustomCommand.defaults
    }
}

struct ScrollDirectionConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var target: ScrollTarget = .mouse
    var shortcut: ShortcutSpec = .none

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        target = try c.decodeIfPresent(ScrollTarget.self, forKey: .target) ?? .mouse
        shortcut = try c.decodeIfPresent(ShortcutSpec.self, forKey: .shortcut) ?? .none
    }
}

enum PortKillSignal: String, Codable, CaseIterable, Sendable {
    case sigterm = "sigterm"
    case sigkill = "sigkill"

    var label: String {
        switch self {
        case .sigterm: return "Graceful Stop (SIGTERM)"
        case .sigkill: return "Force Kill (SIGKILL)"
        }
    }

    var shortLabel: String {
        switch self {
        case .sigterm: return "Stop"
        case .sigkill: return "Kill"
        }
    }

    var posixSignal: Int32 {
        switch self {
        case .sigterm: return SIGTERM
        case .sigkill: return SIGKILL
        }
    }

    var posixNumber: Int32 {
        posixSignal
    }
}

struct PortKillerConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var shortcut: ShortcutSpec = ShortcutSpec(key: "p", modifiers: [.control, .option, .command])
    var refreshIntervalSeconds: Int = 5
    var hideSystemProcesses: Bool = true
    var favoritePorts: [Int] = [3000, 5173, 8000, 8080]
    var defaultSignal: PortKillSignal = .sigterm
    var popoverWidth: Int = 480
    var popoverHeight: Int = 500

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        shortcut = try c.decodeIfPresent(ShortcutSpec.self, forKey: .shortcut)
            ?? ShortcutSpec(key: "p", modifiers: [.control, .option, .command])
        refreshIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? 5
        hideSystemProcesses = try c.decodeIfPresent(Bool.self, forKey: .hideSystemProcesses) ?? true
        favoritePorts = try c.decodeIfPresent([Int].self, forKey: .favoritePorts) ?? [3000, 5173, 8000, 8080]
        defaultSignal = try c.decodeIfPresent(PortKillSignal.self, forKey: .defaultSignal) ?? .sigterm
        popoverWidth = try c.decodeIfPresent(Int.self, forKey: .popoverWidth) ?? 480
        popoverHeight = try c.decodeIfPresent(Int.self, forKey: .popoverHeight) ?? 500
    }
}

struct ScreenOCRConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var shortcut: ShortcutSpec = ShortcutSpec(key: "0", modifiers: [.command, .shift])
    var preserveLineBreaks: Bool = true
    var detectQRCodes: Bool = true
    var showToast: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        shortcut = try c.decodeIfPresent(ShortcutSpec.self, forKey: .shortcut)
            ?? ShortcutSpec(key: "0", modifiers: [.command, .shift])
        preserveLineBreaks = try c.decodeIfPresent(Bool.self, forKey: .preserveLineBreaks) ?? true
        detectQRCodes = try c.decodeIfPresent(Bool.self, forKey: .detectQRCodes) ?? true
        showToast = try c.decodeIfPresent(Bool.self, forKey: .showToast) ?? true
    }
}

struct CleanLockConfig: Codable, Equatable, Sendable {
    static let minDurationSeconds = 10
    static let maxDurationSeconds = 300

    var durationSeconds: Int = 60
    var lockMouseAndTrackpad: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedDuration = try c.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 60
        durationSeconds = Self.clampedDuration(decodedDuration)
        lockMouseAndTrackpad = try c.decodeIfPresent(Bool.self, forKey: .lockMouseAndTrackpad) ?? true
    }

    static func clampedDuration(_ seconds: Int) -> Int {
        min(max(seconds, minDurationSeconds), maxDurationSeconds)
    }
}

enum CallOverrideScope: String, Codable, CaseIterable, Sendable {
    case everywhere = "everywhere"
    case activeOrRunningBackground = "active_or_running_background"
    case activeCallAppOnly = "active_call_app_only"

    var label: String {
        switch self {
        case .everywhere:
            return "Everywhere (any app + macOS mic)"
        case .activeOrRunningBackground:
            return "Active or background call apps"
        case .activeCallAppOnly:
            return "Active call app only"
        }
    }

    var explanation: String {
        switch self {
        case .everywhere:
            return "Use My Mic Keybind in whichever app you are in: toggles your macOS microphone globally and also relays to any active or running call app."
        case .activeOrRunningBackground:
            return "Intercepts only while an enabled call app is active or running in the background; passes through in other apps when idle."
        case .activeCallAppOnly:
            return "Zero interference: intercepts only when an enabled call app is the active frontmost window."
        }
    }
}

struct CallAppShortcutMapping: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var appName: String
    var bundleIdentifier: String
    var enabled: Bool = true
    var micShortcut: ShortcutSpec = .none
    var videoShortcut: ShortcutSpec = .none
    var requiredWindowTitleSubstring: String? = nil
    var allowBriefFocusRestore: Bool = false

    init(
        id: String = UUID().uuidString,
        appName: String,
        bundleIdentifier: String,
        enabled: Bool = true,
        micShortcut: ShortcutSpec = .none,
        videoShortcut: ShortcutSpec = .none,
        requiredWindowTitleSubstring: String? = nil,
        allowBriefFocusRestore: Bool = false
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.enabled = enabled
        self.micShortcut = micShortcut
        self.videoShortcut = videoShortcut
        self.requiredWindowTitleSubstring = requiredWindowTitleSubstring
        self.allowBriefFocusRestore = allowBriefFocusRestore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? "Custom App"
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        micShortcut = try c.decodeIfPresent(ShortcutSpec.self, forKey: .micShortcut) ?? .none
        videoShortcut = try c.decodeIfPresent(ShortcutSpec.self, forKey: .videoShortcut) ?? .none
        requiredWindowTitleSubstring = try c.decodeIfPresent(String.self, forKey: .requiredWindowTitleSubstring)
        allowBriefFocusRestore = try c.decodeIfPresent(Bool.self, forKey: .allowBriefFocusRestore) ?? false
    }

    var bundleIdentifiers: [String] {
        bundleIdentifier
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func matches(bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else {
            return false
        }
        return bundleIdentifiers.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    static var defaults: [CallAppShortcutMapping] {
        [
            CallAppShortcutMapping(
                id: "teams",
                appName: "Microsoft Teams",
                bundleIdentifier: "com.microsoft.teams2,com.microsoft.teams",
                enabled: true,
                micShortcut: ShortcutSpec(key: "m", modifiers: [.command, .shift]),
                videoShortcut: ShortcutSpec(key: "o", modifiers: [.command, .shift]),
                requiredWindowTitleSubstring: nil,
                allowBriefFocusRestore: true
            ),
            CallAppShortcutMapping(
                id: "zoom",
                appName: "Zoom",
                bundleIdentifier: "us.zoom.xos",
                enabled: true,
                micShortcut: ShortcutSpec(key: "a", modifiers: [.command, .shift]),
                videoShortcut: ShortcutSpec(key: "v", modifiers: [.command, .shift]),
                requiredWindowTitleSubstring: nil,
                allowBriefFocusRestore: true
            ),
            CallAppShortcutMapping(
                id: "slack",
                appName: "Slack",
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                enabled: true,
                micShortcut: ShortcutSpec(key: "space", modifiers: [.command, .shift]),
                videoShortcut: .none,
                requiredWindowTitleSubstring: nil,
                allowBriefFocusRestore: true
            ),
            CallAppShortcutMapping(
                id: "google_meet",
                appName: "Google Meet (Browsers)",
                bundleIdentifier: "com.google.Chrome,company.thebrowser.Browser,com.apple.Safari,com.brave.Browser",
                enabled: true,
                micShortcut: ShortcutSpec(key: "d", modifiers: [.command]),
                videoShortcut: ShortcutSpec(key: "e", modifiers: [.command]),
                requiredWindowTitleSubstring: "Meet",
                allowBriefFocusRestore: true
            ),
            CallAppShortcutMapping(
                id: "discord",
                appName: "Discord",
                bundleIdentifier: "com.hnc.Discord",
                enabled: true,
                micShortcut: ShortcutSpec(key: "m", modifiers: [.command, .shift]),
                videoShortcut: .none,
                requiredWindowTitleSubstring: nil,
                allowBriefFocusRestore: true
            ),
            CallAppShortcutMapping(
                id: "facetime",
                appName: "FaceTime",
                bundleIdentifier: "com.apple.FaceTime",
                enabled: true,
                micShortcut: ShortcutSpec(key: "m", modifiers: [.command, .shift]),
                videoShortcut: .none,
                requiredWindowTitleSubstring: nil,
                allowBriefFocusRestore: true
            )
        ]
    }
}

struct CallControlsConfig: Codable, Equatable, Sendable {
    static let minTypingDelayMs = 150
    static let maxTypingDelayMs = 2000
    static let defaultMicShortcut = ShortcutSpec(key: "m", modifiers: [.control, .option, .command])
    static let defaultVideoShortcut = ShortcutSpec(key: "v", modifiers: [.control, .option, .command])

    var enabled: Bool = false
    var micShortcut: ShortcutSpec = CallControlsConfig.defaultMicShortcut
    var videoShortcut: ShortcutSpec = CallControlsConfig.defaultVideoShortcut
    var osMuteShortcut: ShortcutSpec = .none
    var cycleOutputShortcut: ShortcutSpec = .none
    var overrideScope: CallOverrideScope = .everywhere
    var syncHardwareMuteWithAppMicToggle: Bool = false
    var autoMuteWhileTyping: Bool = false
    var typingUnmuteDelayMs: Int = 450
    var showFloatingMicIndicator: Bool = true
    var showVideoInFloatingIndicator: Bool = true
    var showFloatingPillOnlyDuringCalls: Bool = true
    var showToasts: Bool = true
    var favoriteOutputUIDs: [String] = []
    var favoriteInputUIDs: [String] = []
    var appShortcutMappings: [CallAppShortcutMapping] = CallAppShortcutMapping.defaults

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        micShortcut = try c.decodeIfPresent(ShortcutSpec.self, forKey: .micShortcut) ?? Self.defaultMicShortcut
        videoShortcut = try c.decodeIfPresent(ShortcutSpec.self, forKey: .videoShortcut) ?? Self.defaultVideoShortcut
        osMuteShortcut = try c.decodeIfPresent(ShortcutSpec.self, forKey: .osMuteShortcut) ?? .none
        cycleOutputShortcut = try c.decodeIfPresent(ShortcutSpec.self, forKey: .cycleOutputShortcut) ?? .none
        overrideScope = try c.decodeIfPresent(CallOverrideScope.self, forKey: .overrideScope) ?? .everywhere
        syncHardwareMuteWithAppMicToggle = try c.decodeIfPresent(Bool.self, forKey: .syncHardwareMuteWithAppMicToggle) ?? false
        autoMuteWhileTyping = try c.decodeIfPresent(Bool.self, forKey: .autoMuteWhileTyping) ?? false
        let decodedDelay = try c.decodeIfPresent(Int.self, forKey: .typingUnmuteDelayMs) ?? 450
        typingUnmuteDelayMs = Self.clampedTypingDelayMs(decodedDelay)
        showFloatingMicIndicator = try c.decodeIfPresent(Bool.self, forKey: .showFloatingMicIndicator) ?? true
        showVideoInFloatingIndicator = try c.decodeIfPresent(Bool.self, forKey: .showVideoInFloatingIndicator) ?? true
        showFloatingPillOnlyDuringCalls = try c.decodeIfPresent(Bool.self, forKey: .showFloatingPillOnlyDuringCalls) ?? true
        showToasts = try c.decodeIfPresent(Bool.self, forKey: .showToasts) ?? true
        favoriteOutputUIDs = try c.decodeIfPresent([String].self, forKey: .favoriteOutputUIDs) ?? []
        favoriteInputUIDs = try c.decodeIfPresent([String].self, forKey: .favoriteInputUIDs) ?? []
        appShortcutMappings = try c.decodeIfPresent([CallAppShortcutMapping].self, forKey: .appShortcutMappings) ?? CallAppShortcutMapping.defaults
    }

    static func clampedTypingDelayMs(_ ms: Int) -> Int {
        min(max(ms, minTypingDelayMs), maxTypingDelayMs)
    }
}

struct ToolboxConfig: Codable, Equatable, Sendable {
    private enum LegacyCodingKeys: String, CodingKey {
        case audioGuard
    }

    var schemaVersion: Int = 10
    var general: GeneralConfig = GeneralConfig()
    var dockMinimize: DockMinimizeConfig = DockMinimizeConfig()
    var clipboard: ClipboardConfig = ClipboardConfig()
    var portKiller: PortKillerConfig = PortKillerConfig()
    var screenOCR: ScreenOCRConfig = ScreenOCRConfig()
    var keepAwake: KeepAwakeConfig = KeepAwakeConfig()
    var cleanLock: CleanLockConfig = CleanLockConfig()
    var customCommands: CustomCommandsConfig = CustomCommandsConfig()
    var scrollDirection: ScrollDirectionConfig = ScrollDirectionConfig()
    var callControls: CallControlsConfig = CallControlsConfig()
    var extensions: [String: JSONValue] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchema = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 6
        general = try c.decodeIfPresent(GeneralConfig.self, forKey: .general) ?? GeneralConfig()
        dockMinimize = try c.decodeIfPresent(DockMinimizeConfig.self, forKey: .dockMinimize) ?? DockMinimizeConfig()
        clipboard = try c.decodeIfPresent(ClipboardConfig.self, forKey: .clipboard) ?? ClipboardConfig()
        portKiller = try c.decodeIfPresent(PortKillerConfig.self, forKey: .portKiller) ?? PortKillerConfig()
        screenOCR = try c.decodeIfPresent(ScreenOCRConfig.self, forKey: .screenOCR) ?? ScreenOCRConfig()
        keepAwake = try c.decodeIfPresent(KeepAwakeConfig.self, forKey: .keepAwake) ?? KeepAwakeConfig()
        cleanLock = try c.decodeIfPresent(CleanLockConfig.self, forKey: .cleanLock) ?? CleanLockConfig()
        customCommands = try c.decodeIfPresent(CustomCommandsConfig.self, forKey: .customCommands) ?? CustomCommandsConfig()
        scrollDirection = try c.decodeIfPresent(ScrollDirectionConfig.self, forKey: .scrollDirection) ?? ScrollDirectionConfig()

        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        var decodedCallControls = try c.decodeIfPresent(CallControlsConfig.self, forKey: .callControls)
            ?? legacyContainer.decodeIfPresent(CallControlsConfig.self, forKey: .audioGuard)
            ?? CallControlsConfig()
        if decodedSchema < 7 {
            if decodedCallControls.overrideScope == .activeCallAppOnly {
                decodedCallControls.overrideScope = .everywhere
            }
            for idx in decodedCallControls.appShortcutMappings.indices where decodedCallControls.appShortcutMappings[idx].id == "facetime" {
                decodedCallControls.appShortcutMappings[idx].allowBriefFocusRestore = true
            }
        }
        if decodedSchema < 8 {
            decodedCallControls.showFloatingPillOnlyDuringCalls = true
        }
        schemaVersion = max(decodedSchema, 10)
        callControls = decodedCallControls
        extensions = try c.decodeIfPresent([String: JSONValue].self, forKey: .extensions) ?? [:]
    }
}

@MainActor
final class ConfigManager: ObservableObject {
    static let shared = ConfigManager()

    @Published var config: ToolboxConfig {
        didSet {
            guard !isReloadingFromDisk else { return }
            saveToDisk()
            onConfigChanged?(config)
        }
    }

    @Published private(set) var lastConfigError: String?
    @Published private(set) var lastReloadedAt: Date = Date()

    var onConfigChanged: ((ToolboxConfig) -> Void)?
    let configURL: URL

    private var fileMonitorSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isReloadingFromDisk = false

    private init() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let isDiagnosticMode = CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--snapshot-ui")
        let dir: URL
        if let overridePath = ProcessInfo.processInfo.environment["TOOLBOX_CONFIG_DIR"], !overridePath.isEmpty {
            dir = URL(fileURLWithPath: overridePath, isDirectory: true)
        } else if isDiagnosticMode {
            dir = fm.temporaryDirectory.appendingPathComponent("toolbox-isolated-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            dir = home.appendingPathComponent(".config/toolbox", isDirectory: true)
        }
        self.configURL = dir.appendingPathComponent("config.json")
        self.config = ToolboxConfig()

        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if !isDiagnosticMode && ProcessInfo.processInfo.environment["TOOLBOX_CONFIG_DIR"] == nil {
            // Seamless one-time migration from legacy ~/.config/tuner/
            let legacyDir = home.appendingPathComponent(".config/tuner", isDirectory: true)
            for filename in ["config.json", "pinned_clipboard.json"] {
                let legacyFile = legacyDir.appendingPathComponent(filename)
                let newFile = dir.appendingPathComponent(filename)
                if fm.fileExists(atPath: legacyFile.path) && !fm.fileExists(atPath: newFile.path) {
                    try? fm.copyItem(at: legacyFile, to: newFile)
                }
            }
        }

        loadFromDisk()
        if !isDiagnosticMode {
            startWatchingFile()
        }
    }

    func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            saveToDisk()
            return
        }

        do {
            let data = try Data(contentsOf: configURL)
            let rawSchemaVersion = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int ?? 0
            let decoded = try JSONDecoder().decode(ToolboxConfig.self, from: data)
            isReloadingFromDisk = true
            self.config = decoded
            isReloadingFromDisk = false
            if rawSchemaVersion < decoded.schemaVersion {
                saveToDisk()
            }
            lastConfigError = nil
            lastReloadedAt = Date()
            DeveloperEventLog.shared.record(.config, "Reloaded config.json from disk")
            onConfigChanged?(decoded)
        } catch {
            lastConfigError = "Invalid config.json: \(error.localizedDescription)"
            NSLog("Toolbox: \(lastConfigError ?? "")")
        }
    }

    func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
            lastConfigError = nil
            lastReloadedAt = Date()
            DeveloperEventLog.shared.record(.config, "Saved config.json")
        } catch {
            lastConfigError = "Failed to save config.json: \(error.localizedDescription)"
            NSLog("Toolbox: \(lastConfigError ?? "")")
        }
    }

    func formattedJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(config),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    @discardableResult
    func applyRawJSON(_ jsonText: String) -> Bool {
        guard let data = jsonText.data(using: .utf8) else {
            lastConfigError = "Config text is not valid UTF-8."
            return false
        }
        do {
            let decoded = try JSONDecoder().decode(ToolboxConfig.self, from: data)
            lastConfigError = nil
            self.config = decoded
            return true
        } catch {
            lastConfigError = "JSON error: \(error.localizedDescription)"
            return false
        }
    }

    func resetToDefaults() {
        config = ToolboxConfig()
    }

    private func startWatchingFile() {
        fileDescriptor = open(configURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.loadFromDisk()
            self.fileMonitorSource?.cancel()
            self.startWatchingFile()
        }
        source.setCancelHandler { [fd = fileDescriptor] in
            if fd >= 0 { close(fd) }
        }
        source.resume()
        fileMonitorSource = source
    }
}
