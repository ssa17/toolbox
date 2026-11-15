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
        "keep_awake",
        "custom_commands",
        "scroll_direction"
    ]

    var appEnabled: Bool = true
    var showInMenuBar: Bool = true
    var showInDock: Bool = true
    var openDashboardOnLaunch: Bool = true
    var openDashboardOnDockClick: Bool = true
    var dockQuitBehavior: DockQuitBehavior = .closeWindow
    var launchAtLogin: Bool = false
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
        menuBarModuleOrder = try c.decodeIfPresent([String].self, forKey: .menuBarModuleOrder) ?? Self.defaultMenuBarModuleOrder
        menuBarHiddenModules = try c.decodeIfPresent([String].self, forKey: .menuBarHiddenModules) ?? []
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
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(actionMode, forKey: .actionMode)
        try c.encode(clickMode, forKey: .clickMode)
        try c.encode(ignoreModifiedClicks, forKey: .ignoreModifiedClicks)
        try c.encode(excludedBundleIDs, forKey: .excludedBundleIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, actionMode, clickMode, ignoreModifiedClicks, excludedBundleIDs
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

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        target = try c.decodeIfPresent(ScrollTarget.self, forKey: .target) ?? .mouse
    }
}

struct ToolboxConfig: Codable, Equatable, Sendable {
    var schemaVersion: Int = 3
    var general: GeneralConfig = GeneralConfig()
    var dockMinimize: DockMinimizeConfig = DockMinimizeConfig()
    var clipboard: ClipboardConfig = ClipboardConfig()
    var keepAwake: KeepAwakeConfig = KeepAwakeConfig()
    var customCommands: CustomCommandsConfig = CustomCommandsConfig()
    var scrollDirection: ScrollDirectionConfig = ScrollDirectionConfig()
    var extensions: [String: JSONValue] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 3
        general = try c.decodeIfPresent(GeneralConfig.self, forKey: .general) ?? GeneralConfig()
        dockMinimize = try c.decodeIfPresent(DockMinimizeConfig.self, forKey: .dockMinimize) ?? DockMinimizeConfig()
        clipboard = try c.decodeIfPresent(ClipboardConfig.self, forKey: .clipboard) ?? ClipboardConfig()
        keepAwake = try c.decodeIfPresent(KeepAwakeConfig.self, forKey: .keepAwake) ?? KeepAwakeConfig()
        customCommands = try c.decodeIfPresent(CustomCommandsConfig.self, forKey: .customCommands) ?? CustomCommandsConfig()
        scrollDirection = try c.decodeIfPresent(ScrollDirectionConfig.self, forKey: .scrollDirection) ?? ScrollDirectionConfig()
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
            let decoded = try JSONDecoder().decode(ToolboxConfig.self, from: data)
            isReloadingFromDisk = true
            self.config = decoded
            isReloadingFromDisk = false
            lastConfigError = nil
            lastReloadedAt = Date()
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
