import Foundation
import Combine
import CoreGraphics

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
            return "Hides the active app completely without minimizing, then brings it back when clicked again."
        case .sendToBack:
            return "Switches focus to the window behind the active app while keeping it open underneath."
        case .minimizeAll:
            return "Minimizes all windows of the active app into the Dock tray and focuses the window underneath."
        case .minimizeFrontWindow:
            return "Minimizes only the frontmost window into the Dock tray while keeping its other windows open."
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

enum AppTextSize: String, Codable, CaseIterable, Sendable {
    case small = "small"
    case standard = "standard"
    case large = "large"
    case extraLarge = "extra_large"

    var label: String {
        switch self {
        case .small: return "Small"
        case .standard: return "Standard"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    var summary: String {
        switch self {
        case .small: return "Compact typography for denser layouts."
        case .standard: return "Default macOS-balanced text sizing."
        case .large: return "Larger, easier-to-read text across windows, popovers, and HUDs."
        case .extraLarge: return "Maximum readability across windows, popovers, and HUDs."
        }
    }

    var scaleFactor: CGFloat {
        switch self {
        case .small: return 0.90
        case .standard: return 1.0
        case .large: return 1.15
        case .extraLarge: return 1.28
        }
    }

    func scaledPointSize(_ base: CGFloat) -> CGFloat {
        guard self != .standard else { return base }
        return max(8.0, (base * scaleFactor * 2.0).rounded() / 2.0)
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
        "call_controls",
        "window_snapper",
        "finder_enhancer",
        "window_switcher",
        "hyper_key"
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
    var showModuleCardDetails: Bool = true
    var textSize: AppTextSize = .standard

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
        menuBarModuleOrder = decodedOrder.map { id in
            if id == "audio_guard" { return "call_controls" }
            if id == "window_snapping" { return "window_snapper" }
            return id
        }
        let decodedHidden = try c.decodeIfPresent([String].self, forKey: .menuBarHiddenModules) ?? []
        menuBarHiddenModules = decodedHidden.map { id in
            if id == "audio_guard" { return "call_controls" }
            if id == "window_snapping" { return "window_snapper" }
            return id
        }
        showQuickActionsInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showQuickActionsInMenuBar) ?? true
        showQuickCommandsInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showQuickCommandsInMenuBar) ?? true
        showModuleCardDetails = try c.decodeIfPresent(Bool.self, forKey: .showModuleCardDetails) ?? true
        textSize = try c.decodeIfPresent(AppTextSize.self, forKey: .textSize) ?? .standard
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
    var captureImages: Bool = true
    var maxImageItems: Int = 15
    var maxImageSizeMB: Int = 20

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
        captureImages = try c.decodeIfPresent(Bool.self, forKey: .captureImages) ?? true
        maxImageItems = try c.decodeIfPresent(Int.self, forKey: .maxImageItems) ?? 15
        maxImageSizeMB = try c.decodeIfPresent(Int.self, forKey: .maxImageSizeMB) ?? 20
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
    /// Keeps the system default input off Bluetooth headsets so AirPods stay in high-quality stereo.
    var preventBluetoothMicSwitch: Bool = false
    /// Explicit fallback microphone `deviceUID`; `nil` means `Auto: USB → Built-in`.
    var bluetoothMicLockFallbackUID: String? = nil
    /// Shows a HUD toast each time the guard moves the mic back to the fallback device.
    var showBluetoothMicLockToast: Bool = true

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
        preventBluetoothMicSwitch = try c.decodeIfPresent(Bool.self, forKey: .preventBluetoothMicSwitch) ?? false
        let decodedFallbackUID = try c.decodeIfPresent(String.self, forKey: .bluetoothMicLockFallbackUID)
        bluetoothMicLockFallbackUID = (decodedFallbackUID?.isEmpty == true) ? nil : decodedFallbackUID
        showBluetoothMicLockToast = try c.decodeIfPresent(Bool.self, forKey: .showBluetoothMicLockToast) ?? true
    }

    static func clampedTypingDelayMs(_ ms: Int) -> Int {
        min(max(ms, minTypingDelayMs), maxTypingDelayMs)
    }
}

struct NormalizedRect: Codable, Equatable, Hashable, Sendable {
    static let full = NormalizedRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
    static let leftHalf = NormalizedRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0)
    static let rightHalf = NormalizedRect(x: 0.5, y: 0.0, width: 0.5, height: 1.0)
    static let topHalf = NormalizedRect(x: 0.0, y: 0.0, width: 1.0, height: 0.5)
    static let bottomHalf = NormalizedRect(x: 0.0, y: 0.5, width: 1.0, height: 0.5)
    static let topLeft = NormalizedRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5)
    static let topRight = NormalizedRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5)
    static let bottomLeft = NormalizedRect(x: 0.0, y: 0.5, width: 0.5, height: 0.5)
    static let bottomRight = NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
    static let centerDefault = NormalizedRect(x: 0.15, y: 0.10, width: 0.70, height: 0.80)

    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.0
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 1.0
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 1.0
    }

    var clamped: NormalizedRect {
        let cx = min(max(x, 0.0), 0.98)
        let cy = min(max(y, 0.0), 0.98)
        let cw = min(max(width, 0.02), 1.0 - cx)
        let ch = min(max(height, 0.02), 1.0 - cy)
        return NormalizedRect(x: cx, y: cy, width: cw, height: ch)
    }

    var maxX: Double { x + width }
    var maxY: Double { y + height }
}

struct ZoneDefinition: Codable, Equatable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var normalizedRect: NormalizedRect
    var shortcut: ShortcutSpec = .none
    var isCustom: Bool = false

    init(
        id: String = UUID().uuidString,
        name: String,
        normalizedRect: NormalizedRect,
        shortcut: ShortcutSpec = .none,
        isCustom: Bool = false
    ) {
        self.id = id
        self.name = name
        self.normalizedRect = normalizedRect
        self.shortcut = shortcut
        self.isCustom = isCustom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Zone"
        normalizedRect = try c.decodeIfPresent(NormalizedRect.self, forKey: .normalizedRect) ?? .full
        shortcut = try c.decodeIfPresent(ShortcutSpec.self, forKey: .shortcut) ?? .none
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
    }
}

struct DisplayDivision: Codable, Equatable, Hashable, Sendable {
    var columnWeights: [Double] = [1.0, 1.0]
    var rowWeights: [Double] = [1.0]

    init(columnWeights: [Double] = [1.0, 1.0], rowWeights: [Double] = [1.0]) {
        self.columnWeights = columnWeights.isEmpty ? [1.0] : columnWeights.map { max(0.05, $0) }
        self.rowWeights = rowWeights.isEmpty ? [1.0] : rowWeights.map { max(0.05, $0) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cols = try c.decodeIfPresent([Double].self, forKey: .columnWeights) ?? [1.0, 1.0]
        let rows = try c.decodeIfPresent([Double].self, forKey: .rowWeights) ?? [1.0]
        self.init(columnWeights: cols, rowWeights: rows)
    }
}

enum DisplayPresetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    // 1 Window
    case maximized = "maximized"
    // 2 Windows
    case halves = "halves"
    case asymmetric = "asymmetric"
    case asymmetricRight = "asymmetric_right"
    case verticalStack2 = "vertical_stack_2"
    // 3 Windows
    case leftMainRightStack = "left_main_right_stack"
    case leftStackRightMain = "left_stack_right_main"
    case thirds = "thirds"
    case ultrawideFocus = "ultrawide_focus"
    case verticalStack3 = "vertical_stack_3"
    // 4 & 6 Windows
    case quarters = "quarters"
    case fourColumns = "four_columns"
    case sixths = "sixths"
    // Custom
    case custom = "custom"

    var id: String { rawValue }

    static var builtInTemplates: [DisplayPresetKind] {
        [
            .maximized,
            .halves, .asymmetric, .asymmetricRight, .verticalStack2,
            .leftMainRightStack, .leftStackRightMain, .thirds, .ultrawideFocus, .verticalStack3,
            .quarters, .fourColumns, .sixths
        ]
    }

    static var topEdgeSlotTemplates: [DisplayPresetKind] {
        builtInTemplates.filter { $0 != .maximized }
    }

    var zoneCount: Int {
        switch self {
        case .maximized:
            return 1
        case .halves, .asymmetric, .asymmetricRight, .verticalStack2:
            return 2
        case .leftMainRightStack, .leftStackRightMain, .thirds, .ultrawideFocus, .verticalStack3:
            return 3
        case .quarters, .fourColumns:
            return 4
        case .sixths:
            return 6
        case .custom:
            return 2
        }
    }

    var label: String {
        switch self {
        case .maximized: return "Maximized"
        case .halves: return "Side by Side"
        case .asymmetric: return "Focus Left"
        case .asymmetricRight: return "Focus Right"
        case .verticalStack2: return "Top & Bottom"
        case .leftMainRightStack: return "Left + 2 Right"
        case .leftStackRightMain: return "2 Left + Right"
        case .thirds: return "3 Columns"
        case .ultrawideFocus: return "Center Focus"
        case .verticalStack3: return "3 Rows"
        case .quarters: return "4 Quarters"
        case .fourColumns: return "4 Columns"
        case .sixths: return "6 Grid"
        case .custom: return "Custom"
        }
    }

    var shortBadge: String {
        switch self {
        case .maximized: return "Full Screen"
        case .halves: return "50 / 50"
        case .asymmetric: return "67 / 33"
        case .asymmetricRight: return "33 / 67"
        case .verticalStack2: return "50 / 50"
        case .leftMainRightStack: return "1 + 2 Stack"
        case .leftStackRightMain: return "2 Stack + 1"
        case .thirds: return "33 / 33 / 33"
        case .ultrawideFocus: return "25 / 50 / 25"
        case .verticalStack3: return "1 × 3"
        case .quarters: return "2 × 2"
        case .fourColumns: return "4 × 1"
        case .sixths: return "3 × 2"
        case .custom: return "Custom"
        }
    }

    var defaultDivision: DisplayDivision {
        switch self {
        case .maximized: return DisplayDivision(columnWeights: [1.0], rowWeights: [1.0])
        case .halves: return DisplayDivision(columnWeights: [1.0, 1.0], rowWeights: [1.0])
        case .asymmetric: return DisplayDivision(columnWeights: [2.0, 1.0], rowWeights: [1.0])
        case .asymmetricRight: return DisplayDivision(columnWeights: [1.0, 2.0], rowWeights: [1.0])
        case .verticalStack2: return DisplayDivision(columnWeights: [1.0], rowWeights: [1.0, 1.0])
        case .leftMainRightStack, .leftStackRightMain:
            return DisplayDivision(columnWeights: [1.0, 1.0], rowWeights: [1.0, 1.0])
        case .thirds: return DisplayDivision(columnWeights: [1.0, 1.0, 1.0], rowWeights: [1.0])
        case .ultrawideFocus: return DisplayDivision(columnWeights: [1.0, 2.0, 1.0], rowWeights: [1.0])
        case .verticalStack3: return DisplayDivision(columnWeights: [1.0], rowWeights: [1.0, 1.0, 1.0])
        case .quarters: return DisplayDivision(columnWeights: [1.0, 1.0], rowWeights: [1.0, 1.0])
        case .fourColumns: return DisplayDivision(columnWeights: [1.0, 1.0, 1.0, 1.0], rowWeights: [1.0])
        case .sixths: return DisplayDivision(columnWeights: [1.0, 1.0, 1.0], rowWeights: [1.0, 1.0])
        case .custom: return DisplayDivision(columnWeights: [1.0, 1.0], rowWeights: [1.0])
        }
    }

    var templatePreviewRects: [NormalizedRect] {
        switch self {
        case .maximized:
            return [
                NormalizedRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
            ]
        case .halves:
            return [
                NormalizedRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0),
                NormalizedRect(x: 0.5, y: 0.0, width: 0.5, height: 1.0)
            ]
        case .asymmetric:
            return [
                NormalizedRect(x: 0.0, y: 0.0, width: 2.0 / 3.0, height: 1.0),
                NormalizedRect(x: 2.0 / 3.0, y: 0.0, width: 1.0 / 3.0, height: 1.0)
            ]
        case .asymmetricRight:
            return [
                NormalizedRect(x: 0.0, y: 0.0, width: 1.0 / 3.0, height: 1.0),
                NormalizedRect(x: 1.0 / 3.0, y: 0.0, width: 2.0 / 3.0, height: 1.0)
            ]
        case .verticalStack2:
            return [
                NormalizedRect(x: 0.0, y: 0.0, width: 1.0, height: 0.5),
                NormalizedRect(x: 0.0, y: 0.5, width: 1.0, height: 0.5)
            ]
        case .leftMainRightStack:
            return [
                NormalizedRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0),
                NormalizedRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5),
                NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
            ]
        case .leftStackRightMain:
            return [
                NormalizedRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5),
                NormalizedRect(x: 0.0, y: 0.5, width: 0.5, height: 0.5),
                NormalizedRect(x: 0.5, y: 0.0, width: 0.5, height: 1.0)
            ]
        case .thirds:
            return [
                NormalizedRect(x: 0.0, y: 0.0, width: 1.0 / 3.0, height: 1.0),
                NormalizedRect(x: 1.0 / 3.0, y: 0.0, width: 1.0 / 3.0, height: 1.0),
                NormalizedRect(x: 2.0 / 3.0, y: 0.0, width: 1.0 / 3.0, height: 1.0)
            ]
        case .ultrawideFocus:
            return [
                NormalizedRect(x: 0.0, y: 0.0, width: 0.25, height: 1.0),
                NormalizedRect(x: 0.25, y: 0.0, width: 0.5, height: 1.0),
                NormalizedRect(x: 0.75, y: 0.0, width: 0.25, height: 1.0)
            ]
        case .verticalStack3:
            return [
                NormalizedRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0 / 3.0),
                NormalizedRect(x: 0.0, y: 1.0 / 3.0, width: 1.0, height: 1.0 / 3.0),
                NormalizedRect(x: 0.0, y: 2.0 / 3.0, width: 1.0, height: 1.0 / 3.0)
            ]
        case .quarters:
            return [
                NormalizedRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5),
                NormalizedRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5),
                NormalizedRect(x: 0.0, y: 0.5, width: 0.5, height: 0.5),
                NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
            ]
        case .fourColumns:
            return [
                NormalizedRect(x: 0.0, y: 0.0, width: 0.25, height: 1.0),
                NormalizedRect(x: 0.25, y: 0.0, width: 0.25, height: 1.0),
                NormalizedRect(x: 0.5, y: 0.0, width: 0.25, height: 1.0),
                NormalizedRect(x: 0.75, y: 0.0, width: 0.25, height: 1.0)
            ]
        case .sixths:
            return [
                NormalizedRect(x: 0.0, y: 0.0, width: 1.0 / 3.0, height: 0.5),
                NormalizedRect(x: 1.0 / 3.0, y: 0.0, width: 1.0 / 3.0, height: 0.5),
                NormalizedRect(x: 2.0 / 3.0, y: 0.0, width: 1.0 / 3.0, height: 0.5),
                NormalizedRect(x: 0.0, y: 0.5, width: 1.0 / 3.0, height: 0.5),
                NormalizedRect(x: 1.0 / 3.0, y: 0.5, width: 1.0 / 3.0, height: 0.5),
                NormalizedRect(x: 2.0 / 3.0, y: 0.5, width: 1.0 / 3.0, height: 0.5)
            ]
        case .custom:
            return [
                NormalizedRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0),
                NormalizedRect(x: 0.5, y: 0.0, width: 0.5, height: 1.0)
            ]
        }
    }
}

struct DisplaySignature: Codable, Equatable, Hashable, Sendable {
    var uuidString: String
    var vendorNumber: UInt32
    var modelNumber: UInt32
    var serialNumber: UInt32
    var localizedName: String
    var arrangementIndex: Int

    init(
        uuidString: String = "",
        vendorNumber: UInt32 = 0,
        modelNumber: UInt32 = 0,
        serialNumber: UInt32 = 0,
        localizedName: String = "Display",
        arrangementIndex: Int = 0
    ) {
        self.uuidString = uuidString
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.localizedName = localizedName
        self.arrangementIndex = arrangementIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuidString = try c.decodeIfPresent(String.self, forKey: .uuidString) ?? ""
        vendorNumber = try c.decodeIfPresent(UInt32.self, forKey: .vendorNumber) ?? 0
        modelNumber = try c.decodeIfPresent(UInt32.self, forKey: .modelNumber) ?? 0
        serialNumber = try c.decodeIfPresent(UInt32.self, forKey: .serialNumber) ?? 0
        localizedName = try c.decodeIfPresent(String.self, forKey: .localizedName) ?? "Display"
        arrangementIndex = try c.decodeIfPresent(Int.self, forKey: .arrangementIndex) ?? 0
    }

    var stableStorageKey: String {
        if !uuidString.isEmpty {
            return uuidString
        }
        return "\(vendorNumber):\(modelNumber):\(serialNumber):\(arrangementIndex)"
    }
}

struct DisplayLayoutConfig: Codable, Equatable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var display: DisplaySignature
    var presetID: String = DisplayPresetKind.halves.rawValue
    var division: DisplayDivision = DisplayDivision()
    var customZones: [ZoneDefinition] = []
    var outerMarginPoints: Double? = nil
    var innerGapPoints: Double? = nil

    init(
        id: String = UUID().uuidString,
        display: DisplaySignature,
        presetID: String = DisplayPresetKind.halves.rawValue,
        division: DisplayDivision = DisplayDivision(),
        customZones: [ZoneDefinition] = [],
        outerMarginPoints: Double? = nil,
        innerGapPoints: Double? = nil
    ) {
        self.id = id
        self.display = display
        self.presetID = presetID
        self.division = division
        self.customZones = customZones
        self.outerMarginPoints = outerMarginPoints
        self.innerGapPoints = innerGapPoints
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        display = try c.decodeIfPresent(DisplaySignature.self, forKey: .display) ?? DisplaySignature()
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID) ?? DisplayPresetKind.halves.rawValue
        division = try c.decodeIfPresent(DisplayDivision.self, forKey: .division) ?? DisplayDivision()
        customZones = try c.decodeIfPresent([ZoneDefinition].self, forKey: .customZones) ?? []
        outerMarginPoints = try c.decodeIfPresent(Double.self, forKey: .outerMarginPoints)
        innerGapPoints = try c.decodeIfPresent(Double.self, forKey: .innerGapPoints)
    }

    var presetKind: DisplayPresetKind {
        DisplayPresetKind(rawValue: presetID) ?? .custom
    }

    var hasCustomDividerProportions: Bool {
        let base = presetKind.defaultDivision
        return !Self.normalizedWeightsEqual(division.columnWeights, base.columnWeights)
            || !Self.normalizedWeightsEqual(division.rowWeights, base.rowWeights)
    }

    private static func normalizedWeightsEqual(_ lhs: [Double], _ rhs: [Double], tolerance: Double = 0.01) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
        let lhsSafe = lhs.map { max(0.05, $0) }
        let rhsSafe = rhs.map { max(0.05, $0) }
        let lhsSum = lhsSafe.reduce(0, +)
        let rhsSum = rhsSafe.reduce(0, +)
        guard lhsSum > 0, rhsSum > 0 else { return false }
        for (a, b) in zip(lhsSafe, rhsSafe) {
            if abs((a / lhsSum) - (b / rhsSum)) > tolerance {
                return false
            }
        }
        return true
    }
}

struct GapConfig: Codable, Equatable, Sendable {
    var outerMarginPoints: Double = 0
    var innerGapPoints: Double = 0
    var respectStageManagerStrip: Bool = true
    var stageManagerReservePoints: Double = 78

    init(
        outerMarginPoints: Double = 0,
        innerGapPoints: Double = 0,
        respectStageManagerStrip: Bool = true,
        stageManagerReservePoints: Double = 78
    ) {
        self.outerMarginPoints = Self.clampedGap(outerMarginPoints)
        self.innerGapPoints = Self.clampedGap(innerGapPoints)
        self.respectStageManagerStrip = respectStageManagerStrip
        self.stageManagerReservePoints = Self.clampedStageManagerReserve(stageManagerReservePoints)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let outer = try c.decodeIfPresent(Double.self, forKey: .outerMarginPoints) ?? 0
        let inner = try c.decodeIfPresent(Double.self, forKey: .innerGapPoints) ?? 0
        let respectSM = try c.decodeIfPresent(Bool.self, forKey: .respectStageManagerStrip) ?? true
        let reserve = try c.decodeIfPresent(Double.self, forKey: .stageManagerReservePoints) ?? 78
        self.init(
            outerMarginPoints: outer,
            innerGapPoints: inner,
            respectStageManagerStrip: respectSM,
            stageManagerReservePoints: reserve
        )
    }

    static func clampedGap(_ value: Double) -> Double {
        min(max(value, 0), 32)
    }

    static func clampedStageManagerReserve(_ value: Double) -> Double {
        min(max(value, 48), 140)
    }

    static func spacingPresetLabel(for points: Double) -> String {
        if points <= 0.5 { return "Flush" }
        if points <= 5 { return "Tight" }
        if points <= 9 { return "Cozy" }
        if points <= 13 { return "Relaxed" }
        return "Spacious"
    }
}

enum OverlayTintColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case indigo = "indigo"
    case blue = "blue"
    case teal = "teal"
    case purple = "purple"
    case pink = "pink"
    case neutral = "neutral"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .indigo: return "Indigo"
        case .blue: return "Blue"
        case .teal: return "Teal"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .neutral: return "Neutral"
        }
    }
}

struct OverlayStyleConfig: Codable, Equatable, Sendable {
    var tintColor: OverlayTintColor = .indigo
    var fillOpacity: Double = 0.16
    var borderWidthPoints: Double = 2.0
    var cornerRadiusPoints: Double = 10.0
    var showZoneLabelsAndDimensions: Bool = true

    var useAccentTint: Bool {
        get { tintColor != .neutral }
        set { tintColor = newValue ? .indigo : .neutral }
    }

    private enum CodingKeys: String, CodingKey {
        case tintColor
        case useAccentTint
        case fillOpacity
        case borderWidthPoints
        case cornerRadiusPoints
        case showZoneLabelsAndDimensions
    }

    init(
        tintColor: OverlayTintColor = .indigo,
        fillOpacity: Double = 0.16,
        borderWidthPoints: Double = 2.0,
        cornerRadiusPoints: Double = 10.0,
        showZoneLabelsAndDimensions: Bool = true
    ) {
        self.tintColor = tintColor
        self.fillOpacity = min(max(fillOpacity, 0.0), 0.35)
        self.borderWidthPoints = min(max(borderWidthPoints, 1.0), 8.0)
        self.cornerRadiusPoints = min(max(cornerRadiusPoints, 0.0), 20.0)
        self.showZoneLabelsAndDimensions = showZoneLabelsAndDimensions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedTint: OverlayTintColor
        if let explicit = try c.decodeIfPresent(OverlayTintColor.self, forKey: .tintColor) {
            decodedTint = explicit
        } else if let legacyAccent = try c.decodeIfPresent(Bool.self, forKey: .useAccentTint) {
            decodedTint = legacyAccent ? .indigo : .neutral
        } else {
            decodedTint = .indigo
        }
        self.init(
            tintColor: decodedTint,
            fillOpacity: try c.decodeIfPresent(Double.self, forKey: .fillOpacity) ?? 0.16,
            borderWidthPoints: try c.decodeIfPresent(Double.self, forKey: .borderWidthPoints) ?? 2.0,
            cornerRadiusPoints: try c.decodeIfPresent(Double.self, forKey: .cornerRadiusPoints) ?? 10.0,
            showZoneLabelsAndDimensions: try c.decodeIfPresent(Bool.self, forKey: .showZoneLabelsAndDimensions) ?? true
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tintColor, forKey: .tintColor)
        try c.encode(tintColor != .neutral, forKey: .useAccentTint)
        try c.encode(fillOpacity, forKey: .fillOpacity)
        try c.encode(borderWidthPoints, forKey: .borderWidthPoints)
        try c.encode(cornerRadiusPoints, forKey: .cornerRadiusPoints)
        try c.encode(showZoneLabelsAndDimensions, forKey: .showZoneLabelsAndDimensions)
    }

    static func borderThicknessLabel(for points: Double) -> String {
        if points <= 1.5 { return "Thin" }
        if points <= 3.0 { return "Medium" }
        if points <= 5.5 { return "Thick" }
        return "Bold"
    }
}

enum DragModifierChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "none"
    case shift = "shift"
    case option = "option"
    case controlOption = "control_option"
    case optionCommand = "option_command"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Off"
        case .shift: return "⇧ Shift"
        case .option: return "⌥ Option"
        case .controlOption: return "⌃ ⌥ Ctrl+Opt"
        case .optionCommand: return "⌥ ⌘ Opt+Cmd"
        }
    }

    var shortSymbol: String {
        switch self {
        case .none: return "Off"
        case .shift: return "⇧"
        case .option: return "⌥"
        case .controlOption: return "⌃⌥"
        case .optionCommand: return "⌥⌘"
        }
    }
}

struct DragSnapConfig: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var edgeProximityPoints: Double = 12
    var cornerBandPoints: Double = 48
    var gridModifier: DragModifierChoice = .shift
    var restoreSizeOnDragAway: Bool = true

    private enum CodingKeys: String, CodingKey {
        case enabled
        case edgeProximityPoints
        case cornerBandPoints
        case gridModifier
        case restoreSizeOnDragAway
    }

    init(
        enabled: Bool = true,
        edgeProximityPoints: Double = 12,
        cornerBandPoints: Double = 48,
        gridModifier: DragModifierChoice = .shift,
        restoreSizeOnDragAway: Bool = true
    ) {
        self.enabled = enabled
        self.edgeProximityPoints = min(max(edgeProximityPoints, 0), 32)
        self.cornerBandPoints = min(max(cornerBandPoints, 24), 96)
        self.gridModifier = gridModifier
        self.restoreSizeOnDragAway = restoreSizeOnDragAway
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            edgeProximityPoints: try c.decodeIfPresent(Double.self, forKey: .edgeProximityPoints) ?? 12,
            cornerBandPoints: try c.decodeIfPresent(Double.self, forKey: .cornerBandPoints) ?? 48,
            gridModifier: try c.decodeIfPresent(DragModifierChoice.self, forKey: .gridModifier) ?? .shift,
            restoreSizeOnDragAway: try c.decodeIfPresent(Bool.self, forKey: .restoreSizeOnDragAway) ?? true
        )
    }

    static func edgeProximityLabel(for points: Double) -> String {
        if points <= 0.5 { return "Touch Edge" }
        if points <= 9 { return "Tight" }
        if points <= 15 { return "Medium" }
        return "Wide"
    }

    static func cornerBandLabel(for points: Double) -> String {
        if points <= 36 { return "Small" }
        if points <= 54 { return "Medium" }
        if points <= 70 { return "Large" }
        return "Extra Large"
    }
}

enum TopEdgeTriggerWidth: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact = "compact"
    case matchPanel = "match_panel"
    case wide = "wide"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "Compact"
        case .matchPanel: return "Match Panel"
        case .wide: return "Wide"
        }
    }
}

struct TopEdgePanelConfig: Codable, Equatable, Sendable {
    static let slotCount = 6
    static let defaultSlots: [DisplayPresetKind?] = [
        .halves,
        .asymmetric,
        .asymmetricRight,
        .leftMainRightStack,
        .leftStackRightMain,
        .quarters
    ]

    var enabled: Bool = true
    var triggerDistancePoints: Double = 24
    var triggerWidth: TopEdgeTriggerWidth = .matchPanel
    var slots: [DisplayPresetKind?] = TopEdgePanelConfig.defaultSlots
    var showAppCards: Bool = true
    var showWindowThumbnails: Bool = true

    private enum CodingKeys: String, CodingKey {
        case enabled
        case triggerDistancePoints
        case triggerWidth
        case slots
        case showAppCards
        case showWindowThumbnails
    }

    init(
        enabled: Bool = true,
        triggerDistancePoints: Double = 24,
        triggerWidth: TopEdgeTriggerWidth = .matchPanel,
        slots: [DisplayPresetKind?] = TopEdgePanelConfig.defaultSlots,
        showAppCards: Bool = true,
        showWindowThumbnails: Bool = true
    ) {
        self.enabled = enabled
        self.triggerDistancePoints = Self.clampedTriggerDistance(triggerDistancePoints)
        self.triggerWidth = triggerWidth
        self.slots = Self.normalizedSlots(slots)
        self.showAppCards = showAppCards
        self.showWindowThumbnails = showWindowThumbnails
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEnabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let decodedDistance = try c.decodeIfPresent(Double.self, forKey: .triggerDistancePoints) ?? 24
        let decodedWidth = try c.decodeIfPresent(TopEdgeTriggerWidth.self, forKey: .triggerWidth) ?? .matchPanel
        let decodedShowCards = try c.decodeIfPresent(Bool.self, forKey: .showAppCards) ?? true
        let decodedThumbnails = try c.decodeIfPresent(Bool.self, forKey: .showWindowThumbnails) ?? true

        let decodedSlots: [DisplayPresetKind?]
        if let rawSlotStrings = try c.decodeIfPresent([String?].self, forKey: .slots) {
            decodedSlots = rawSlotStrings.map { raw in
                guard let raw, let preset = DisplayPresetKind(rawValue: raw), preset != .custom else {
                    return nil
                }
                return preset
            }
        } else {
            decodedSlots = Self.defaultSlots
        }

        self.init(
            enabled: decodedEnabled,
            triggerDistancePoints: decodedDistance,
            triggerWidth: decodedWidth,
            slots: decodedSlots,
            showAppCards: decodedShowCards,
            showWindowThumbnails: decodedThumbnails
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(triggerDistancePoints, forKey: .triggerDistancePoints)
        try c.encode(triggerWidth, forKey: .triggerWidth)
        try c.encode(Self.normalizedSlots(slots), forKey: .slots)
        try c.encode(showAppCards, forKey: .showAppCards)
        try c.encode(showWindowThumbnails, forKey: .showWindowThumbnails)
    }

    static func triggerDistanceLabel(for points: Double) -> String {
        if points <= 0.5 { return "Edge Only" }
        if points <= 16 { return "Close" }
        if points <= 32 { return "Medium" }
        return "Generous"
    }

    static func clampedTriggerDistance(_ value: Double) -> Double {
        min(max(value, 0), 64)
    }

    static func normalizedSlots(_ raw: [DisplayPresetKind?]) -> [DisplayPresetKind?] {
        var result: [DisplayPresetKind?] = Array(repeating: nil, count: slotCount)
        var seen: Set<DisplayPresetKind> = []
        for idx in 0..<slotCount {
            guard idx < raw.count, let candidate = raw[idx], candidate != .custom else {
                continue
            }
            if !seen.contains(candidate) {
                seen.insert(candidate)
                result[idx] = candidate
            }
        }
        return result
    }

    func slotIndex(for template: DisplayPresetKind) -> Int? {
        guard template != .custom else { return nil }
        return Self.normalizedSlots(slots).firstIndex(where: { $0 == template })
    }

    @discardableResult
    mutating func setSlot(_ template: DisplayPresetKind?, at index: Int) -> Bool {
        var normalized = Self.normalizedSlots(slots)
        guard index >= 0, index < Self.slotCount else { return false }
        if let template {
            guard template != .custom else { return false }
            if let existingIdx = normalized.firstIndex(where: { $0 == template }), existingIdx != index {
                return false
            }
        }
        normalized[index] = template
        slots = normalized
        return true
    }

    @discardableResult
    mutating func assignOrSwapSlot(_ template: DisplayPresetKind?, at index: Int) -> Bool {
        var normalized = Self.normalizedSlots(slots)
        guard index >= 0, index < Self.slotCount else { return false }
        if let template {
            guard template != .custom else { return false }
            if let existingIdx = normalized.firstIndex(where: { $0 == template }), existingIdx != index {
                let displaced = normalized[index]
                normalized[index] = template
                normalized[existingIdx] = displaced
                slots = normalized
                return true
            }
        }
        normalized[index] = template
        slots = normalized
        return true
    }

    @discardableResult
    mutating func swapSlots(_ lhs: Int, _ rhs: Int) -> Bool {
        var normalized = Self.normalizedSlots(slots)
        guard lhs >= 0, lhs < Self.slotCount, rhs >= 0, rhs < Self.slotCount else { return false }
        if lhs == rhs { return true }
        normalized.swapAt(lhs, rhs)
        slots = normalized
        return true
    }

    mutating func resetSlotsToDefault() {
        slots = Self.defaultSlots
    }
}

enum WindowSnapperShortcutPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case toolboxSafe = "toolbox_safe"
    case rectangleStyle = "rectangle_style"
    case manual = "manual"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .toolboxSafe: return "Toolbox Safe (⌃⌥⌘)"
        case .rectangleStyle: return "Rectangle Style (⌃⌥)"
        case .manual: return "Unbind All"
        }
    }
}

enum WindowSnapperHotKeyAction: String, CaseIterable, Identifiable, Sendable {
    case leftHalf = "left_half"
    case rightHalf = "right_half"
    case topHalf = "top_half"
    case bottomHalf = "bottom_half"
    case topLeft = "top_left"
    case topRight = "top_right"
    case bottomLeft = "bottom_left"
    case bottomRight = "bottom_right"
    case maximize = "maximize"
    case center = "center"
    case previousDisplay = "previous_display"
    case nextDisplay = "next_display"
    case restorePreSnap = "restore_pre_snap"

    var id: String { rawValue }
    var sourceID: String { "window_snapper.\(rawValue)" }
    var registrationName: String { sourceID }

    var label: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left Quarter"
        case .topRight: return "Top Right Quarter"
        case .bottomLeft: return "Bottom Left Quarter"
        case .bottomRight: return "Bottom Right Quarter"
        case .maximize: return "Maximize"
        case .center: return "Center"
        case .previousDisplay: return "Previous Display"
        case .nextDisplay: return "Next Display"
        case .restorePreSnap: return "Restore Window Size"
        }
    }

    var symbolName: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.inset.filled"
        case .rightHalf: return "rectangle.righthalf.inset.filled"
        case .topHalf: return "rectangle.tophalf.inset.filled"
        case .bottomHalf: return "rectangle.bottomhalf.inset.filled"
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        case .maximize: return "rectangle.inset.filled"
        case .center: return "rectangle.center.inset.filled"
        case .previousDisplay: return "display.and.arrow.down"
        case .nextDisplay: return "display.2"
        case .restorePreSnap: return "arrow.down.right.and.arrow.up.left"
        }
    }
}

struct WindowSnapperHotKeys: Codable, Equatable, Sendable {
    var leftHalf: ShortcutSpec = ShortcutSpec(key: "left", modifiers: [.control, .option, .command])
    var rightHalf: ShortcutSpec = ShortcutSpec(key: "right", modifiers: [.control, .option, .command])
    var topHalf: ShortcutSpec = ShortcutSpec(key: "up", modifiers: [.control, .option, .command])
    var bottomHalf: ShortcutSpec = ShortcutSpec(key: "down", modifiers: [.control, .option, .command])
    var topLeft: ShortcutSpec = ShortcutSpec(key: "1", modifiers: [.control, .option, .command])
    var topRight: ShortcutSpec = ShortcutSpec(key: "2", modifiers: [.control, .option, .command])
    var bottomLeft: ShortcutSpec = ShortcutSpec(key: "3", modifiers: [.control, .option, .command])
    var bottomRight: ShortcutSpec = ShortcutSpec(key: "4", modifiers: [.control, .option, .command])
    var maximize: ShortcutSpec = ShortcutSpec(key: "return", modifiers: [.control, .option, .command])
    var center: ShortcutSpec = ShortcutSpec(key: "c", modifiers: [.control, .option, .command])
    var previousDisplay: ShortcutSpec = ShortcutSpec(key: "[", modifiers: [.control, .option, .command])
    var nextDisplay: ShortcutSpec = ShortcutSpec(key: "]", modifiers: [.control, .option, .command])
    var undo: ShortcutSpec = ShortcutSpec(key: "z", modifiers: [.control, .option, .command])
    var restorePreSnap: ShortcutSpec = ShortcutSpec(key: "delete", modifiers: [.control, .option, .command])

    static let toolboxSafe = WindowSnapperHotKeys()

    static let rectangleStyle = WindowSnapperHotKeys(
        leftHalf: ShortcutSpec(key: "left", modifiers: [.control, .option]),
        rightHalf: ShortcutSpec(key: "right", modifiers: [.control, .option]),
        topHalf: ShortcutSpec(key: "up", modifiers: [.control, .option]),
        bottomHalf: ShortcutSpec(key: "down", modifiers: [.control, .option]),
        topLeft: ShortcutSpec(key: "u", modifiers: [.control, .option]),
        topRight: ShortcutSpec(key: "i", modifiers: [.control, .option]),
        bottomLeft: ShortcutSpec(key: "j", modifiers: [.control, .option]),
        bottomRight: ShortcutSpec(key: "k", modifiers: [.control, .option]),
        maximize: ShortcutSpec(key: "return", modifiers: [.control, .option]),
        center: ShortcutSpec(key: "c", modifiers: [.control, .option]),
        previousDisplay: ShortcutSpec(key: "left", modifiers: [.control, .option, .command]),
        nextDisplay: ShortcutSpec(key: "right", modifiers: [.control, .option, .command]),
        undo: ShortcutSpec(key: "z", modifiers: [.control, .option, .command]),
        restorePreSnap: ShortcutSpec(key: "delete", modifiers: [.control, .option])
    )

    static let unbound = WindowSnapperHotKeys(
        leftHalf: .none,
        rightHalf: .none,
        topHalf: .none,
        bottomHalf: .none,
        topLeft: .none,
        topRight: .none,
        bottomLeft: .none,
        bottomRight: .none,
        maximize: .none,
        center: .none,
        previousDisplay: .none,
        nextDisplay: .none,
        undo: .none,
        restorePreSnap: .none
    )

    init(
        leftHalf: ShortcutSpec = ShortcutSpec(key: "left", modifiers: [.control, .option, .command]),
        rightHalf: ShortcutSpec = ShortcutSpec(key: "right", modifiers: [.control, .option, .command]),
        topHalf: ShortcutSpec = ShortcutSpec(key: "up", modifiers: [.control, .option, .command]),
        bottomHalf: ShortcutSpec = ShortcutSpec(key: "down", modifiers: [.control, .option, .command]),
        topLeft: ShortcutSpec = ShortcutSpec(key: "1", modifiers: [.control, .option, .command]),
        topRight: ShortcutSpec = ShortcutSpec(key: "2", modifiers: [.control, .option, .command]),
        bottomLeft: ShortcutSpec = ShortcutSpec(key: "3", modifiers: [.control, .option, .command]),
        bottomRight: ShortcutSpec = ShortcutSpec(key: "4", modifiers: [.control, .option, .command]),
        maximize: ShortcutSpec = ShortcutSpec(key: "return", modifiers: [.control, .option, .command]),
        center: ShortcutSpec = ShortcutSpec(key: "c", modifiers: [.control, .option, .command]),
        previousDisplay: ShortcutSpec = ShortcutSpec(key: "[", modifiers: [.control, .option, .command]),
        nextDisplay: ShortcutSpec = ShortcutSpec(key: "]", modifiers: [.control, .option, .command]),
        undo: ShortcutSpec = ShortcutSpec(key: "z", modifiers: [.control, .option, .command]),
        restorePreSnap: ShortcutSpec = ShortcutSpec(key: "delete", modifiers: [.control, .option, .command])
    ) {
        self.leftHalf = leftHalf
        self.rightHalf = rightHalf
        self.topHalf = topHalf
        self.bottomHalf = bottomHalf
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
        self.maximize = maximize
        self.center = center
        self.previousDisplay = previousDisplay
        self.nextDisplay = nextDisplay
        self.undo = undo
        self.restorePreSnap = restorePreSnap
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WindowSnapperHotKeys.toolboxSafe
        leftHalf = try c.decodeIfPresent(ShortcutSpec.self, forKey: .leftHalf) ?? d.leftHalf
        rightHalf = try c.decodeIfPresent(ShortcutSpec.self, forKey: .rightHalf) ?? d.rightHalf
        topHalf = try c.decodeIfPresent(ShortcutSpec.self, forKey: .topHalf) ?? d.topHalf
        bottomHalf = try c.decodeIfPresent(ShortcutSpec.self, forKey: .bottomHalf) ?? d.bottomHalf
        topLeft = try c.decodeIfPresent(ShortcutSpec.self, forKey: .topLeft) ?? d.topLeft
        topRight = try c.decodeIfPresent(ShortcutSpec.self, forKey: .topRight) ?? d.topRight
        bottomLeft = try c.decodeIfPresent(ShortcutSpec.self, forKey: .bottomLeft) ?? d.bottomLeft
        bottomRight = try c.decodeIfPresent(ShortcutSpec.self, forKey: .bottomRight) ?? d.bottomRight
        maximize = try c.decodeIfPresent(ShortcutSpec.self, forKey: .maximize) ?? d.maximize
        center = try c.decodeIfPresent(ShortcutSpec.self, forKey: .center) ?? d.center
        previousDisplay = try c.decodeIfPresent(ShortcutSpec.self, forKey: .previousDisplay) ?? d.previousDisplay
        nextDisplay = try c.decodeIfPresent(ShortcutSpec.self, forKey: .nextDisplay) ?? d.nextDisplay
        undo = try c.decodeIfPresent(ShortcutSpec.self, forKey: .undo) ?? d.undo
        restorePreSnap = try c.decodeIfPresent(ShortcutSpec.self, forKey: .restorePreSnap) ?? d.restorePreSnap
    }

    func shortcut(for action: WindowSnapperHotKeyAction) -> ShortcutSpec {
        switch action {
        case .leftHalf: return leftHalf
        case .rightHalf: return rightHalf
        case .topHalf: return topHalf
        case .bottomHalf: return bottomHalf
        case .topLeft: return topLeft
        case .topRight: return topRight
        case .bottomLeft: return bottomLeft
        case .bottomRight: return bottomRight
        case .maximize: return maximize
        case .center: return center
        case .previousDisplay: return previousDisplay
        case .nextDisplay: return nextDisplay
        case .restorePreSnap: return restorePreSnap
        }
    }

    mutating func setShortcut(_ spec: ShortcutSpec, for action: WindowSnapperHotKeyAction) {
        switch action {
        case .leftHalf: leftHalf = spec
        case .rightHalf: rightHalf = spec
        case .topHalf: topHalf = spec
        case .bottomHalf: bottomHalf = spec
        case .topLeft: topLeft = spec
        case .topRight: topRight = spec
        case .bottomLeft: bottomLeft = spec
        case .bottomRight: bottomRight = spec
        case .maximize: maximize = spec
        case .center: center = spec
        case .previousDisplay: previousDisplay = spec
        case .nextDisplay: nextDisplay = spec
        case .restorePreSnap: restorePreSnap = spec
        }
    }

    static func forPreset(_ preset: WindowSnapperShortcutPreset) -> WindowSnapperHotKeys {
        switch preset {
        case .toolboxSafe: return .toolboxSafe
        case .rectangleStyle: return .rectangleStyle
        case .manual: return .unbound
        }
    }
}

enum DisplayConnectMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case systemDefault = "system_default"
    case alwaysExtend = "always_extend"
    case alwaysMirror = "always_mirror"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .systemDefault: return "System Default"
        case .alwaysExtend: return "Always Extend"
        case .alwaysMirror: return "Always Mirror"
        }
    }

    var explanation: String {
        switch self {
        case .systemDefault:
            return "Keep macOS's current extend or mirror setting when monitors connect."
        case .alwaysExtend:
            return "Automatically un-mirror newly connected displays so each screen has its own workspace."
        case .alwaysMirror:
            return "Automatically mirror newly connected displays to your built-in or main display."
        }
    }
}

enum ProfileDisplayRole: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case main = "main"
    case external1 = "external_1"
    case external2 = "external_2"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .main: return "Main Display"
        case .external1: return "External 1"
        case .external2: return "External 2"
        }
    }

    var shortLabel: String {
        switch self {
        case .main: return "Main"
        case .external1: return "External 1"
        case .external2: return "External 2"
        }
    }

    var targetDisplay: ProfileTargetDisplay {
        switch self {
        case .main: return .main
        case .external1: return .externalSlot(0)
        case .external2: return .externalSlot(1)
        }
    }

    static func roles(forDisplayCount count: Int) -> [ProfileDisplayRole] {
        switch count {
        case ...1: return [.main]
        case 2: return [.main, .external1]
        default: return [.main, .external1, .external2]
        }
    }
}

enum ProfileTargetDisplay: Codable, Equatable, Hashable, Sendable {
    case main
    case anyExternal
    case externalSlot(Int)
    case specific(DisplaySignature)

    var label: String {
        switch self {
        case .main: return "Main Display"
        case .anyExternal: return "Any External Display"
        case .externalSlot(let idx): return "External \(idx + 1)"
        case .specific(let sig): return sig.localizedName
        }
    }
}

enum ProfileWindowPolicy: Codable, Equatable, Hashable, Sendable {
    case frontmost
    case largest
    case titleContains(String)
    case allTiledInZone

    var label: String {
        switch self {
        case .frontmost: return "Frontmost Window"
        case .largest: return "Largest Window"
        case .titleContains(let query): return "Title Contains '\(query)'"
        case .allTiledInZone: return "All Windows Tiled"
        }
    }
}

enum ProfileDisconnectedFallback: String, Codable, CaseIterable, Identifiable, Sendable {
    case moveToMainDisplay = "move_to_main"
    case moveToNextAvailableDisplay = "move_to_next"
    case skipRule = "skip"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .moveToMainDisplay: return "Move to Main Display"
        case .moveToNextAvailableDisplay: return "Move to Next Available"
        case .skipRule: return "Skip Rule"
        }
    }
}

enum DisplayTopologyTriggerMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off = "off"
    case askViaHUD = "ask_via_hud"
    case autoApply = "auto_apply"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Manual Only"
        case .askViaHUD: return "Prompt via HUD"
        case .autoApply: return "Auto-Apply"
        }
    }
}

struct ProfileAppRule: Codable, Equatable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var bundleIdentifier: String
    var appName: String
    var enabled: Bool = true
    var targetDisplay: ProfileTargetDisplay = .main
    var targetZoneID: String
    var fallbackRect: NormalizedRect? = nil
    var windowPolicy: ProfileWindowPolicy = .frontmost
    var launchIfNotRunning: Bool = true
    var autoPlaceNewWindowsWhileActive: Bool = false

    init(
        id: String = UUID().uuidString,
        bundleIdentifier: String,
        appName: String,
        enabled: Bool = true,
        targetDisplay: ProfileTargetDisplay = .main,
        targetZoneID: String,
        fallbackRect: NormalizedRect? = nil,
        windowPolicy: ProfileWindowPolicy = .frontmost,
        launchIfNotRunning: Bool = true,
        autoPlaceNewWindowsWhileActive: Bool = false
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.enabled = enabled
        self.targetDisplay = targetDisplay
        self.targetZoneID = targetZoneID
        self.fallbackRect = fallbackRect
        self.windowPolicy = windowPolicy
        self.launchIfNotRunning = launchIfNotRunning
        self.autoPlaceNewWindowsWhileActive = autoPlaceNewWindowsWhileActive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? "Application"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        targetDisplay = try c.decodeIfPresent(ProfileTargetDisplay.self, forKey: .targetDisplay) ?? .main
        targetZoneID = try c.decodeIfPresent(String.self, forKey: .targetZoneID) ?? "cell:0:0"
        fallbackRect = try c.decodeIfPresent(NormalizedRect.self, forKey: .fallbackRect)
        windowPolicy = try c.decodeIfPresent(ProfileWindowPolicy.self, forKey: .windowPolicy) ?? .frontmost
        launchIfNotRunning = try c.decodeIfPresent(Bool.self, forKey: .launchIfNotRunning) ?? true
        autoPlaceNewWindowsWhileActive = try c.decodeIfPresent(Bool.self, forKey: .autoPlaceNewWindowsWhileActive) ?? false
    }
}

struct ProfileDisplaySlotLayout: Codable, Equatable, Hashable, Sendable {
    var role: ProfileDisplayRole
    var presetID: String = DisplayPresetKind.halves.rawValue
    var division: DisplayDivision = DisplayDivision()
    var customZones: [ZoneDefinition] = []
    var outerMarginPoints: Double? = nil
    var innerGapPoints: Double? = nil

    init(
        role: ProfileDisplayRole,
        presetID: String = DisplayPresetKind.halves.rawValue,
        division: DisplayDivision = DisplayDivision(),
        customZones: [ZoneDefinition] = [],
        outerMarginPoints: Double? = nil,
        innerGapPoints: Double? = nil
    ) {
        self.role = role
        self.presetID = presetID
        self.division = division
        self.customZones = customZones
        self.outerMarginPoints = outerMarginPoints
        self.innerGapPoints = innerGapPoints
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(ProfileDisplayRole.self, forKey: .role) ?? .main
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID) ?? DisplayPresetKind.halves.rawValue
        division = try c.decodeIfPresent(DisplayDivision.self, forKey: .division) ?? DisplayDivision()
        customZones = try c.decodeIfPresent([ZoneDefinition].self, forKey: .customZones) ?? []
        outerMarginPoints = try c.decodeIfPresent(Double.self, forKey: .outerMarginPoints)
        innerGapPoints = try c.decodeIfPresent(Double.self, forKey: .innerGapPoints)
    }

    var presetKind: DisplayPresetKind {
        DisplayPresetKind(rawValue: presetID) ?? .custom
    }

    var hasCustomDividerProportions: Bool {
        let base = presetKind.defaultDivision
        return !Self.normalizedWeightsEqual(division.columnWeights, base.columnWeights)
            || !Self.normalizedWeightsEqual(division.rowWeights, base.rowWeights)
    }

    func asDisplayLayoutConfig(for signature: DisplaySignature) -> DisplayLayoutConfig {
        DisplayLayoutConfig(
            id: "slot-\(role.rawValue)-\(signature.stableStorageKey)",
            display: signature,
            presetID: presetID,
            division: division,
            customZones: customZones,
            outerMarginPoints: outerMarginPoints,
            innerGapPoints: innerGapPoints
        )
    }

    private static func normalizedWeightsEqual(_ lhs: [Double], _ rhs: [Double], tolerance: Double = 0.01) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
        let lhsSafe = lhs.map { max(0.05, $0) }
        let rhsSafe = rhs.map { max(0.05, $0) }
        let lhsSum = lhsSafe.reduce(0, +)
        let rhsSum = rhsSafe.reduce(0, +)
        guard lhsSum > 0, rhsSum > 0 else { return false }
        for (a, b) in zip(lhsSafe, rhsSafe) {
            if abs((a / lhsSum) - (b / rhsSum)) > tolerance {
                return false
            }
        }
        return true
    }
}

struct ProfileDisplayVariant: Codable, Equatable, Identifiable, Hashable, Sendable {
    var displayCount: Int
    var slotLayouts: [ProfileDisplaySlotLayout] = []
    var appRules: [ProfileAppRule] = []

    var id: Int { displayCount }

    init(
        displayCount: Int,
        slotLayouts: [ProfileDisplaySlotLayout] = [],
        appRules: [ProfileAppRule] = []
    ) {
        self.displayCount = min(max(displayCount, 1), 3)
        self.slotLayouts = slotLayouts
        self.appRules = Self.deduplicatedRules(appRules)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawCount = try c.decodeIfPresent(Int.self, forKey: .displayCount) ?? 1
        displayCount = min(max(rawCount, 1), 3)
        slotLayouts = try c.decodeIfPresent([ProfileDisplaySlotLayout].self, forKey: .slotLayouts) ?? []
        let decodedRules = try c.decodeIfPresent([ProfileAppRule].self, forKey: .appRules) ?? []
        appRules = Self.deduplicatedRules(decodedRules)
    }

    static func deduplicatedRules(_ rules: [ProfileAppRule]) -> [ProfileAppRule] {
        var seen = Set<String>()
        var result: [ProfileAppRule] = []
        for rule in rules {
            let roleKey: String
            switch rule.targetDisplay {
            case .main:
                roleKey = "main"
            case .anyExternal, .externalSlot(0):
                roleKey = "ext:0"
            case .externalSlot(let idx):
                roleKey = "ext:\(idx)"
            case .specific(let sig):
                roleKey = "spec:\(sig.stableStorageKey)"
            }
            let dedupKey = "\(roleKey)|\(rule.targetZoneID)"
            if seen.insert(dedupKey).inserted {
                result.append(rule)
            }
        }
        return result
    }

    func layout(for role: ProfileDisplayRole) -> ProfileDisplaySlotLayout {
        slotLayouts.first(where: { $0.role == role }) ?? ProfileDisplaySlotLayout(role: role)
    }
}

struct WorkspaceProfile: Codable, Equatable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var symbolName: String = "rectangle.3.group"
    var shortcut: ShortcutSpec = .none
    var displayLayoutOverrides: [DisplayLayoutConfig] = []
    var appRules: [ProfileAppRule] = []
    var disconnectedFallback: ProfileDisconnectedFallback = .moveToMainDisplay
    var unminimizeAndUnhideApps: Bool = true
    var hideUnlistedApps: Bool = false
    var boundDisplaySignatures: [DisplaySignature] = []
    var topologyTriggerMode: DisplayTopologyTriggerMode = .off
    var maxDisplayCount: Int = 1
    var displayVariants: [ProfileDisplayVariant] = []

    init(
        id: String = UUID().uuidString,
        name: String,
        symbolName: String = "rectangle.3.group",
        shortcut: ShortcutSpec = .none,
        displayLayoutOverrides: [DisplayLayoutConfig] = [],
        appRules: [ProfileAppRule] = [],
        disconnectedFallback: ProfileDisconnectedFallback = .moveToMainDisplay,
        unminimizeAndUnhideApps: Bool = true,
        hideUnlistedApps: Bool = false,
        boundDisplaySignatures: [DisplaySignature] = [],
        topologyTriggerMode: DisplayTopologyTriggerMode = .off,
        maxDisplayCount: Int = 1,
        displayVariants: [ProfileDisplayVariant] = []
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.shortcut = shortcut
        self.displayLayoutOverrides = displayLayoutOverrides
        self.appRules = appRules
        self.disconnectedFallback = disconnectedFallback
        self.unminimizeAndUnhideApps = unminimizeAndUnhideApps
        self.hideUnlistedApps = hideUnlistedApps
        self.boundDisplaySignatures = boundDisplaySignatures
        self.topologyTriggerMode = topologyTriggerMode
        self.maxDisplayCount = min(max(maxDisplayCount, 1), 3)
        self.displayVariants = displayVariants
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Workspace Profile"
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName) ?? "rectangle.3.group"
        shortcut = try c.decodeIfPresent(ShortcutSpec.self, forKey: .shortcut) ?? .none
        displayLayoutOverrides = try c.decodeIfPresent([DisplayLayoutConfig].self, forKey: .displayLayoutOverrides) ?? []
        appRules = try c.decodeIfPresent([ProfileAppRule].self, forKey: .appRules) ?? []
        disconnectedFallback = try c.decodeIfPresent(ProfileDisconnectedFallback.self, forKey: .disconnectedFallback) ?? .moveToMainDisplay
        unminimizeAndUnhideApps = try c.decodeIfPresent(Bool.self, forKey: .unminimizeAndUnhideApps) ?? true
        hideUnlistedApps = try c.decodeIfPresent(Bool.self, forKey: .hideUnlistedApps) ?? false
        boundDisplaySignatures = try c.decodeIfPresent([DisplaySignature].self, forKey: .boundDisplaySignatures) ?? []
        topologyTriggerMode = try c.decodeIfPresent(DisplayTopologyTriggerMode.self, forKey: .topologyTriggerMode) ?? .off
        let rawMax = try c.decodeIfPresent(Int.self, forKey: .maxDisplayCount) ?? 1
        maxDisplayCount = min(max(rawMax, 1), 3)
        displayVariants = try c.decodeIfPresent([ProfileDisplayVariant].self, forKey: .displayVariants) ?? []
    }

    func resolvedVariant(forDisplayCount connectedCount: Int) -> ProfileDisplayVariant? {
        guard !displayVariants.isEmpty else { return nil }
        let targetCount = min(max(connectedCount, 1), min(max(maxDisplayCount, 1), 3))
        if let exact = displayVariants.first(where: { $0.displayCount == targetCount }) {
            return exact
        }
        if let lower = displayVariants
            .filter({ $0.displayCount <= targetCount })
            .max(by: { $0.displayCount < $1.displayCount }) {
            return lower
        }
        return displayVariants.min(by: { $0.displayCount < $1.displayCount })
    }

    func effectiveAppRules(forDisplayCount connectedCount: Int) -> [ProfileAppRule] {
        let raw = resolvedVariant(forDisplayCount: connectedCount)?.appRules ?? appRules
        return ProfileDisplayVariant.deduplicatedRules(raw)
    }

    func effectiveDisplayLayoutOverrides(
        for displays: [ConnectedDisplay],
        swapExternalDisplays: Bool
    ) -> [DisplayLayoutConfig] {
        guard let variant = resolvedVariant(forDisplayCount: displays.count) else {
            return displayLayoutOverrides
        }
        let rolesByDisplayID = Dictionary(
            uniqueKeysWithValues: DisplayRegistry.assignLogicalRoles(
                for: displays,
                swapExternalDisplays: swapExternalDisplays
            ).map { ($0.value.displayID, $0.key) }
        )
        return displays.map { disp in
            let role = rolesByDisplayID[disp.displayID] ?? .main
            return variant.layout(for: role).asDisplayLayoutConfig(for: disp.signature)
        }
    }

    mutating func ensureVariantsUpToMaxDisplayCount(defaultPreset: DisplayPresetKind = .leftMainRightStack) {
        maxDisplayCount = min(max(maxDisplayCount, 1), 3)
        if displayVariants.isEmpty {
            let legacyMainLayout = displayLayoutOverrides.first
            let mainSlot = ProfileDisplaySlotLayout(
                role: .main,
                presetID: legacyMainLayout?.presetID ?? defaultPreset.rawValue,
                division: legacyMainLayout?.division ?? defaultPreset.defaultDivision,
                customZones: legacyMainLayout?.customZones ?? [],
                outerMarginPoints: legacyMainLayout?.outerMarginPoints,
                innerGapPoints: legacyMainLayout?.innerGapPoints
            )
            let legacyMainRules = ProfileDisplayVariant.deduplicatedRules(
                appRules.filter {
                    if case .main = $0.targetDisplay { return true }
                    return false
                }
            )
            let legacyExternalRules = ProfileDisplayVariant.deduplicatedRules(
                appRules.compactMap { rule -> ProfileAppRule? in
                    if case .main = rule.targetDisplay { return nil }
                    var copy = rule
                    copy.targetDisplay = .externalSlot(0)
                    return copy
                }
            )
            var seededVariants = [
                ProfileDisplayVariant(displayCount: 1, slotLayouts: [mainSlot], appRules: legacyMainRules)
            ]
            if !legacyExternalRules.isEmpty {
                maxDisplayCount = max(maxDisplayCount, 2)
                let v2Rules = ProfileDisplayVariant.deduplicatedRules(
                    legacyMainRules.map { rule in
                        var copy = rule
                        copy.id = UUID().uuidString
                        return copy
                    } + legacyExternalRules
                )
                seededVariants.append(
                    ProfileDisplayVariant(
                        displayCount: 2,
                        slotLayouts: [mainSlot, ProfileDisplaySlotLayout(role: .external1)],
                        appRules: v2Rules
                    )
                )
            }
            displayVariants = seededVariants
        }

        let v1 = displayVariants.first(where: { $0.displayCount == 1 }) ?? displayVariants[0]
        let v1MainSlot = v1.layout(for: .main)
        let v1MainRules = v1.appRules.filter {
            if case .main = $0.targetDisplay { return true }
            return false
        }

        var normalized: [ProfileDisplayVariant] = []
        for count in 1...maxDisplayCount {
            var variant = displayVariants.first(where: { $0.displayCount == count })
                ?? ProfileDisplayVariant(
                    displayCount: count,
                    slotLayouts: [v1MainSlot],
                    appRules: v1MainRules.map { rule in
                        var copy = rule
                        copy.id = UUID().uuidString
                        return copy
                    }
                )
            let expectedRoles = ProfileDisplayRole.roles(forDisplayCount: count)
            var slots: [ProfileDisplaySlotLayout] = []
            for role in expectedRoles {
                if let existing = variant.slotLayouts.first(where: { $0.role == role }) {
                    slots.append(existing)
                } else if role == .main {
                    slots.append(v1MainSlot)
                } else {
                    slots.append(ProfileDisplaySlotLayout(role: role))
                }
            }
            variant.slotLayouts = slots
            variant.appRules = ProfileDisplayVariant.deduplicatedRules(variant.appRules)
            normalized.append(variant)
        }
        displayVariants = normalized
    }

    static var defaultTemplates: [WorkspaceProfile] {
        [
            WorkspaceProfile(
                id: "template-coding-split",
                name: "Coding & Terminal",
                symbolName: "chevron.left.forwardslash.chevron.right",
                appRules: [
                    ProfileAppRule(
                        bundleIdentifier: "com.microsoft.VSCode",
                        appName: "Visual Studio Code",
                        targetDisplay: .main,
                        targetZoneID: "cell:0:0",
                        fallbackRect: NormalizedRect(x: 0, y: 0, width: 0.667, height: 1.0)
                    ),
                    ProfileAppRule(
                        bundleIdentifier: "com.apple.Terminal",
                        appName: "Terminal",
                        targetDisplay: .main,
                        targetZoneID: "cell:1:0",
                        fallbackRect: NormalizedRect(x: 0.667, y: 0, width: 0.333, height: 1.0)
                    )
                ]
            ),
            WorkspaceProfile(
                id: "template-research-docs",
                name: "Research & Notes",
                symbolName: "book.pages",
                appRules: [
                    ProfileAppRule(
                        bundleIdentifier: "com.apple.Safari",
                        appName: "Safari",
                        targetDisplay: .main,
                        targetZoneID: "cell:0:0",
                        fallbackRect: .leftHalf
                    ),
                    ProfileAppRule(
                        bundleIdentifier: "com.apple.Notes",
                        appName: "Notes",
                        targetDisplay: .main,
                        targetZoneID: "cell:1:0",
                        fallbackRect: .rightHalf
                    )
                ]
            ),
            WorkspaceProfile(
                id: "template-focus-finder",
                name: "Side-by-Side Finder",
                symbolName: "macwindow.on.rectangle",
                appRules: [
                    ProfileAppRule(
                        bundleIdentifier: "com.apple.finder",
                        appName: "Finder",
                        targetDisplay: .main,
                        targetZoneID: "cell:0:0",
                        fallbackRect: .leftHalf,
                        windowPolicy: .allTiledInZone
                    )
                ]
            )
        ]
    }
}

struct WindowSnapperShortcutEntry: Sendable {
    let sourceID: String
    let label: String
    let shortcut: ShortcutSpec
}

enum WindowAnimationSpeed: String, Codable, CaseIterable, Identifiable, Sendable {
    case off = "off"
    case snappy = "snappy"
    case smooth = "smooth"
    case gentle = "gentle"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .snappy: return "Snappy"
        case .smooth: return "Smooth"
        case .gentle: return "Gentle"
        }
    }

    var snapDuration: TimeInterval {
        switch self {
        case .off: return 0
        case .snappy: return 0.10
        case .smooth: return 0.22
        case .gentle: return 0.42
        }
    }

    var unsnapResizeDuration: TimeInterval {
        switch self {
        case .off: return 0
        case .snappy: return 0.09
        case .smooth: return 0.18
        case .gentle: return 0.34
        }
    }

    var isAnimated: Bool {
        self != .off
    }
}

struct WindowSnapperConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var keyboardSnappingEnabled: Bool = true
    var cycleRepeatedDirectionShortcuts: Bool = true
    var showSnapHUDToasts: Bool = true
    var windowAnimationSpeed: WindowAnimationSpeed = .smooth
    var centerWidthFraction: Double = 0.70
    var centerHeightFraction: Double = 0.80
    var undoStackDepth: Int = 25
    var ignoredBundleIDs: [String] = []
    var gaps: GapConfig = GapConfig()
    var overlayStyle: OverlayStyleConfig = OverlayStyleConfig()
    var drag: DragSnapConfig = DragSnapConfig()
    var topEdgePanel: TopEdgePanelConfig = TopEdgePanelConfig()
    var hotKeys: WindowSnapperHotKeys = WindowSnapperHotKeys()
    var displayLayouts: [DisplayLayoutConfig] = []
    var profiles: [WorkspaceProfile] = []
    var activeProfileID: String? = nil
    var restorePreviousWorkspaceOnShortcutToggle: Bool = true
    var displayConnectMode: DisplayConnectMode = .systemDefault
    var autoApplyProfileID: String? = nil
    var swapExternalDisplays: Bool = false

    var animateWindowTransitions: Bool {
        get { windowAnimationSpeed.isAnimated }
        set { windowAnimationSpeed = newValue ? (windowAnimationSpeed == .off ? .smooth : windowAnimationSpeed) : .off }
    }

    private struct LegacyDragTopEdgeFields: Decodable {
        var showTopEdgeDropBar: Bool?
        var topDropBarTriggerDistancePoints: Double?
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case keyboardSnappingEnabled
        case cycleRepeatedDirectionShortcuts
        case showSnapHUDToasts
        case windowAnimationSpeed
        case animateWindowTransitions
        case centerWidthFraction
        case centerHeightFraction
        case undoStackDepth
        case ignoredBundleIDs
        case gaps
        case overlayStyle
        case drag
        case topEdgePanel
        case hotKeys
        case displayLayouts
        case profiles
        case activeProfileID
        case restorePreviousWorkspaceOnShortcutToggle
        case displayConnectMode
        case autoApplyProfileID
        case swapExternalDisplays
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        keyboardSnappingEnabled = try c.decodeIfPresent(Bool.self, forKey: .keyboardSnappingEnabled) ?? true
        cycleRepeatedDirectionShortcuts = try c.decodeIfPresent(Bool.self, forKey: .cycleRepeatedDirectionShortcuts) ?? true
        showSnapHUDToasts = try c.decodeIfPresent(Bool.self, forKey: .showSnapHUDToasts) ?? true
        if let speed = try c.decodeIfPresent(WindowAnimationSpeed.self, forKey: .windowAnimationSpeed) {
            windowAnimationSpeed = speed
        } else if let legacyAnimate = try c.decodeIfPresent(Bool.self, forKey: .animateWindowTransitions) {
            windowAnimationSpeed = legacyAnimate ? .smooth : .off
        } else {
            windowAnimationSpeed = .smooth
        }
        let cw = try c.decodeIfPresent(Double.self, forKey: .centerWidthFraction) ?? 0.70
        let ch = try c.decodeIfPresent(Double.self, forKey: .centerHeightFraction) ?? 0.80
        centerWidthFraction = min(max(cw, 0.25), 0.98)
        centerHeightFraction = min(max(ch, 0.25), 0.98)
        let depth = try c.decodeIfPresent(Int.self, forKey: .undoStackDepth) ?? 25
        undoStackDepth = Self.clampedUndoDepth(depth)
        ignoredBundleIDs = try c.decodeIfPresent([String].self, forKey: .ignoredBundleIDs) ?? []
        gaps = try c.decodeIfPresent(GapConfig.self, forKey: .gaps) ?? GapConfig()
        overlayStyle = try c.decodeIfPresent(OverlayStyleConfig.self, forKey: .overlayStyle) ?? OverlayStyleConfig()
        drag = try c.decodeIfPresent(DragSnapConfig.self, forKey: .drag) ?? DragSnapConfig()
        if let decodedPanel = try c.decodeIfPresent(TopEdgePanelConfig.self, forKey: .topEdgePanel) {
            topEdgePanel = decodedPanel
        } else if let legacyDrag = try c.decodeIfPresent(LegacyDragTopEdgeFields.self, forKey: .drag) {
            topEdgePanel = TopEdgePanelConfig(
                enabled: legacyDrag.showTopEdgeDropBar ?? true,
                triggerDistancePoints: legacyDrag.topDropBarTriggerDistancePoints ?? 24
            )
        } else {
            topEdgePanel = TopEdgePanelConfig()
        }
        hotKeys = try c.decodeIfPresent(WindowSnapperHotKeys.self, forKey: .hotKeys) ?? WindowSnapperHotKeys()
        displayLayouts = try c.decodeIfPresent([DisplayLayoutConfig].self, forKey: .displayLayouts) ?? []
        profiles = try c.decodeIfPresent([WorkspaceProfile].self, forKey: .profiles) ?? []
        activeProfileID = try c.decodeIfPresent(String.self, forKey: .activeProfileID)
        restorePreviousWorkspaceOnShortcutToggle = try c.decodeIfPresent(Bool.self, forKey: .restorePreviousWorkspaceOnShortcutToggle) ?? true
        displayConnectMode = try c.decodeIfPresent(DisplayConnectMode.self, forKey: .displayConnectMode) ?? .systemDefault
        autoApplyProfileID = try c.decodeIfPresent(String.self, forKey: .autoApplyProfileID)
        swapExternalDisplays = try c.decodeIfPresent(Bool.self, forKey: .swapExternalDisplays) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(keyboardSnappingEnabled, forKey: .keyboardSnappingEnabled)
        try c.encode(cycleRepeatedDirectionShortcuts, forKey: .cycleRepeatedDirectionShortcuts)
        try c.encode(showSnapHUDToasts, forKey: .showSnapHUDToasts)
        try c.encode(windowAnimationSpeed, forKey: .windowAnimationSpeed)
        try c.encode(windowAnimationSpeed.isAnimated, forKey: .animateWindowTransitions)
        try c.encode(centerWidthFraction, forKey: .centerWidthFraction)
        try c.encode(centerHeightFraction, forKey: .centerHeightFraction)
        try c.encode(undoStackDepth, forKey: .undoStackDepth)
        try c.encode(ignoredBundleIDs, forKey: .ignoredBundleIDs)
        try c.encode(gaps, forKey: .gaps)
        try c.encode(overlayStyle, forKey: .overlayStyle)
        try c.encode(drag, forKey: .drag)
        try c.encode(topEdgePanel, forKey: .topEdgePanel)
        try c.encode(hotKeys, forKey: .hotKeys)
        try c.encode(displayLayouts, forKey: .displayLayouts)
        try c.encode(profiles, forKey: .profiles)
        try c.encodeIfPresent(activeProfileID, forKey: .activeProfileID)
        try c.encode(restorePreviousWorkspaceOnShortcutToggle, forKey: .restorePreviousWorkspaceOnShortcutToggle)
        try c.encode(displayConnectMode, forKey: .displayConnectMode)
        try c.encodeIfPresent(autoApplyProfileID, forKey: .autoApplyProfileID)
        try c.encode(swapExternalDisplays, forKey: .swapExternalDisplays)
    }

    static func clampedUndoDepth(_ depth: Int) -> Int {
        min(max(depth, 5), 100)
    }

    func allShortcutEntries(includeHotKeys: Bool = true, includeProfilesAndZones: Bool = true) -> [WindowSnapperShortcutEntry] {
        var entries: [WindowSnapperShortcutEntry] = []
        if includeHotKeys {
            for action in WindowSnapperHotKeyAction.allCases {
                let spec = hotKeys.shortcut(for: action)
                if !spec.isEmpty {
                    entries.append(WindowSnapperShortcutEntry(
                        sourceID: action.sourceID,
                        label: "Window Snapper (\(action.label))",
                        shortcut: spec
                    ))
                }
            }
        }
        if includeProfilesAndZones {
            for profile in profiles where !profile.shortcut.isEmpty {
                entries.append(WindowSnapperShortcutEntry(
                    sourceID: "window_snapper.profile.\(profile.id)",
                    label: "Window Snapper Profile '\(profile.name)'",
                    shortcut: profile.shortcut
                ))
            }
            for layout in displayLayouts {
                for zone in layout.customZones where !zone.shortcut.isEmpty {
                    entries.append(WindowSnapperShortcutEntry(
                        sourceID: "window_snapper.zone.\(layout.id).\(zone.id)",
                        label: "Window Snapper Zone '\(zone.name)'",
                        shortcut: zone.shortcut
                    ))
                }
            }
        }
        return entries
    }
}

enum AutoQuitAppMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case allowlistOnly = "allowlist_only"
    case allExceptExcluded = "all_except_excluded"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allowlistOnly: return "Allowlist Only"
        case .allExceptExcluded: return "All Except Excluded"
        }
    }

    var explanation: String {
        switch self {
        case .allowlistOnly:
            return "Only apps in your allowlist auto-quit when their last window closes (recommended so browsers, terminals, and IDEs stay running)."
        case .allExceptExcluded:
            return "Any regular app auto-quits when its last window closes unless excluded below. Finder, Dock, Toolbox, and system UI processes are always protected."
        }
    }
}

struct FinderEnhancerConfig: Codable, Equatable, Sendable {
    static let minAutoQuitDelayMs = 200
    static let maxAutoQuitDelayMs = 2000
    static let defaultAutoQuitDelayMs = 500
    static let defaultAllowlistBundleIDs: [String] = [
        "com.apple.Preview",
        "com.apple.TextEdit",
        "com.apple.QuickTimePlayerX",
        "com.apple.systempreferences",
        "com.apple.calculator",
        "com.apple.FontBook"
    ]

    var enabled: Bool = false
    var enableCutAndPaste: Bool = true
    var showCutToast: Bool = true
    var enableReturnToOpen: Bool = false
    var enableF2ToRename: Bool = false
    var enableAutoQuitOnLastWindowClose: Bool = false
    var autoQuitMode: AutoQuitAppMode = .allowlistOnly
    var autoQuitDelayMs: Int = FinderEnhancerConfig.defaultAutoQuitDelayMs
    var autoQuitAllowlistBundleIDs: [String] = FinderEnhancerConfig.defaultAllowlistBundleIDs
    var autoQuitExcludedBundleIDs: [String] = []

    var needsKeyTap: Bool {
        enableCutAndPaste || enableReturnToOpen || enableF2ToRename
    }

    var hasAnyFeatureEnabled: Bool {
        needsKeyTap || enableAutoQuitOnLastWindowClose
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        enableCutAndPaste = try c.decodeIfPresent(Bool.self, forKey: .enableCutAndPaste) ?? true
        showCutToast = try c.decodeIfPresent(Bool.self, forKey: .showCutToast) ?? true
        enableReturnToOpen = try c.decodeIfPresent(Bool.self, forKey: .enableReturnToOpen) ?? false
        enableF2ToRename = try c.decodeIfPresent(Bool.self, forKey: .enableF2ToRename) ?? false
        enableAutoQuitOnLastWindowClose = try c.decodeIfPresent(Bool.self, forKey: .enableAutoQuitOnLastWindowClose) ?? false
        autoQuitMode = try c.decodeIfPresent(AutoQuitAppMode.self, forKey: .autoQuitMode) ?? .allowlistOnly
        let rawDelay = try c.decodeIfPresent(Int.self, forKey: .autoQuitDelayMs) ?? Self.defaultAutoQuitDelayMs
        autoQuitDelayMs = Self.clampedAutoQuitDelayMs(rawDelay)
        autoQuitAllowlistBundleIDs = try c.decodeIfPresent([String].self, forKey: .autoQuitAllowlistBundleIDs)
            ?? Self.defaultAllowlistBundleIDs
        autoQuitExcludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .autoQuitExcludedBundleIDs) ?? []
    }

    static func clampedAutoQuitDelayMs(_ ms: Int) -> Int {
        min(max(ms, minAutoQuitDelayMs), maxAutoQuitDelayMs)
    }
}

enum SwitcherTriggerModifier: String, Codable, CaseIterable, Identifiable, Sendable {
    case option
    case control
    case command

    var id: String { rawValue }

    var label: String {
        switch self {
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .command: return "⌘ Command"
        }
    }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .control: return "⌃"
        case .command: return "⌘"
        }
    }

    var cgEventFlag: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .command: return .maskCommand
        }
    }

    var keyModifier: KeyModifier {
        switch self {
        case .option: return .option
        case .control: return .control
        case .command: return .command
        }
    }

    var explanation: String {
        switch self {
        case .option:
            return "Hold ⌥ Option and press Tab (or ⇧ Tab) to cycle windows without replacing macOS ⌘ Tab."
        case .control:
            return "Hold ⌃ Control and press Tab (or ⇧ Tab) to cycle windows cleanly across apps."
        case .command:
            return "Replaces macOS's built-in ⌘ Tab app switcher with Toolbox's window-level switcher while active."
        }
    }
}

enum SwitcherLayoutStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case strip
    case list

    var id: String { rawValue }

    var label: String {
        switch self {
        case .strip: return "Thumbnail Strip"
        case .list: return "Compact List"
        }
    }

    var symbolName: String {
        switch self {
        case .strip: return "rectangle.split.3x1"
        case .list: return "list.bullet"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "strip"
        switch raw {
        case "list": self = .list
        case "strip", "grid": self = .strip
        default: self = .strip
        }
    }
}

struct WindowSwitcherConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var triggerModifier: SwitcherTriggerModifier = .option
    var triggerKey: String = "tab"
    var currentAppOnlyShortcut: ShortcutSpec = .none
    var layoutStyle: SwitcherLayoutStyle = .strip
    var showThumbnails: Bool = true
    var includeMinimized: Bool = true
    var includeHiddenApps: Bool = true
    var activeSpaceOnly: Bool = false
    var activeDisplayOnly: Bool = false
    var enableQuickActions: Bool = true
    var excludedBundleIDs: [String] = []

    var normalizedTriggerKey: String {
        let trimmed = triggerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "tab" : trimmed
    }

    var triggerShortcutSpec: ShortcutSpec {
        ShortcutSpec(key: normalizedTriggerKey, modifiers: [triggerModifier.keyModifier])
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        triggerModifier = try c.decodeIfPresent(SwitcherTriggerModifier.self, forKey: .triggerModifier) ?? .option
        let rawKey = (try c.decodeIfPresent(String.self, forKey: .triggerKey) ?? "tab")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        triggerKey = rawKey.isEmpty ? "tab" : rawKey
        currentAppOnlyShortcut = try c.decodeIfPresent(ShortcutSpec.self, forKey: .currentAppOnlyShortcut) ?? .none
        layoutStyle = try c.decodeIfPresent(SwitcherLayoutStyle.self, forKey: .layoutStyle) ?? .strip
        showThumbnails = try c.decodeIfPresent(Bool.self, forKey: .showThumbnails) ?? true
        includeMinimized = try c.decodeIfPresent(Bool.self, forKey: .includeMinimized) ?? true
        includeHiddenApps = try c.decodeIfPresent(Bool.self, forKey: .includeHiddenApps) ?? true
        activeSpaceOnly = try c.decodeIfPresent(Bool.self, forKey: .activeSpaceOnly) ?? false
        activeDisplayOnly = try c.decodeIfPresent(Bool.self, forKey: .activeDisplayOnly) ?? false
        enableQuickActions = try c.decodeIfPresent(Bool.self, forKey: .enableQuickActions) ?? true
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? []
    }
}

enum HyperKeyHoldMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case toolboxChord = "toolbox_chord"
    case classicHyper = "classic_hyper"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .toolboxChord: return "⌃ ⌥ ⌘ (Toolbox Chord)"
        case .classicHyper: return "⌃ ⌥ ⇧ ⌘ (Classic Hyper)"
        }
    }

    var shortLabel: String {
        switch self {
        case .toolboxChord: return "⌃ ⌥ ⌘"
        case .classicHyper: return "⌃ ⌥ ⇧ ⌘"
        }
    }

    var modifiers: [KeyModifier] {
        switch self {
        case .toolboxChord: return [.control, .option, .command]
        case .classicHyper: return [.control, .option, .shift, .command]
        }
    }

    var cgEventFlags: CGEventFlags {
        switch self {
        case .toolboxChord: return [.maskControl, .maskAlternate, .maskCommand]
        case .classicHyper: return [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        }
    }
}

enum HyperKeyTapAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case capsLock = "caps_lock"
    case escape = "escape"
    case none = "none"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .capsLock: return "Toggle Caps Lock"
        case .escape: return "Escape"
        case .none: return "Disabled"
        }
    }
}

struct HyperKeyConfig: Codable, Equatable, Sendable {
    static let minTapThresholdMs = 120
    static let maxTapThresholdMs = 400
    static let defaultTapThresholdMs = 250

    var enabled: Bool = false
    var holdMode: HyperKeyHoldMode = .toolboxChord
    var tapAction: HyperKeyTapAction = .capsLock
    var tapThresholdMs: Int = HyperKeyConfig.defaultTapThresholdMs

    init(
        enabled: Bool = false,
        holdMode: HyperKeyHoldMode = .toolboxChord,
        tapAction: HyperKeyTapAction = .capsLock,
        tapThresholdMs: Int = HyperKeyConfig.defaultTapThresholdMs
    ) {
        self.enabled = enabled
        self.holdMode = holdMode
        self.tapAction = tapAction
        self.tapThresholdMs = Self.clampedTapThresholdMs(tapThresholdMs)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        holdMode = try c.decodeIfPresent(HyperKeyHoldMode.self, forKey: .holdMode) ?? .toolboxChord
        tapAction = try c.decodeIfPresent(HyperKeyTapAction.self, forKey: .tapAction) ?? .capsLock
        let decodedThreshold = try c.decodeIfPresent(Int.self, forKey: .tapThresholdMs) ?? Self.defaultTapThresholdMs
        tapThresholdMs = Self.clampedTapThresholdMs(decodedThreshold)
    }

    static func clampedTapThresholdMs(_ ms: Int) -> Int {
        min(max(ms, minTapThresholdMs), maxTapThresholdMs)
    }
}

struct ToolboxConfig: Codable, Equatable, Sendable {
    private enum LegacyCodingKeys: String, CodingKey {
        case audioGuard
        case windowSnapping
    }

    var schemaVersion: Int = 17
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
    var windowSnapper: WindowSnapperConfig = WindowSnapperConfig()
    var finderEnhancer: FinderEnhancerConfig = FinderEnhancerConfig()
    var windowSwitcher: WindowSwitcherConfig = WindowSwitcherConfig()
    var hyperKey: HyperKeyConfig = HyperKeyConfig()
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
        schemaVersion = max(decodedSchema, 17)
        callControls = decodedCallControls
        windowSnapper = try c.decodeIfPresent(WindowSnapperConfig.self, forKey: .windowSnapper)
            ?? legacyContainer.decodeIfPresent(WindowSnapperConfig.self, forKey: .windowSnapping)
            ?? WindowSnapperConfig()
        finderEnhancer = try c.decodeIfPresent(FinderEnhancerConfig.self, forKey: .finderEnhancer) ?? FinderEnhancerConfig()
        windowSwitcher = try c.decodeIfPresent(WindowSwitcherConfig.self, forKey: .windowSwitcher) ?? WindowSwitcherConfig()
        hyperKey = try c.decodeIfPresent(HyperKeyConfig.self, forKey: .hyperKey) ?? HyperKeyConfig()
        extensions = try c.decodeIfPresent([String: JSONValue].self, forKey: .extensions) ?? [:]
    }

    /// Returns `true` when two configs are identical for all runtime module and
    /// app-presence behaviors (ignoring purely visual Dashboard layout preferences).
    func runtimeBehaviorEquals(_ other: ToolboxConfig) -> Bool {
        var lhs = self
        var rhs = other
        lhs.general.showModuleCardDetails = true
        rhs.general.showModuleCardDetails = true
        lhs.general.textSize = .standard
        rhs.general.textSize = .standard
        return lhs == rhs
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

    func loadFromDisk(onlyIfChanged: Bool = false) {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            saveToDisk()
            return
        }

        do {
            let data = try Data(contentsOf: configURL)
            let rawSchemaVersion = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int ?? 0
            let decoded = try JSONDecoder().decode(ToolboxConfig.self, from: data)
            if onlyIfChanged && decoded == self.config && rawSchemaVersion >= decoded.schemaVersion {
                return
            }
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
            self.loadFromDisk(onlyIfChanged: true)
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
