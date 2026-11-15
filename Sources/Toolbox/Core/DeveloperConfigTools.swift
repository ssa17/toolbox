import Foundation

/// Single flattened leaf difference between two `ToolboxConfig` states.
struct ConfigDiffItem: Identifiable, Equatable, Sendable {
    var id: String { keyPath }
    let keyPath: String
    let baselineValue: String
    let currentValue: String
}

/// Top-level `ToolboxConfig` section selectable for targeted reset.
enum ToolboxConfigSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case dockMinimize
    case clipboard
    case portKiller
    case keepAwake
    case cleanLock
    case customCommands
    case scrollDirection

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .dockMinimize: return "Dock Click to Minimize"
        case .clipboard: return "Clipboard History"
        case .portKiller: return "Port Killer"
        case .keepAwake: return "Keep Awake"
        case .cleanLock: return "Clean Lock"
        case .customCommands: return "Custom Commands"
        case .scrollDirection: return "Scroll Direction"
        }
    }
}

/// Manages in-memory config checkpoints, structural JSON diffs, and single-section resets.
@MainActor
final class ConfigCheckpointStore: ObservableObject {
    static let shared = ConfigCheckpointStore()

    @Published private(set) var checkpointConfig: ToolboxConfig?
    @Published private(set) var checkpointSavedAt: Date?

    private init() {}

    func saveCheckpoint(from config: ToolboxConfig? = nil) {
        checkpointConfig = config ?? ConfigManager.shared.config
        checkpointSavedAt = Date()
    }

    @discardableResult
    func restoreCheckpoint() -> Bool {
        guard let checkpointConfig else { return false }
        ConfigManager.shared.config = checkpointConfig
        return true
    }

    func clearCheckpoint() {
        checkpointConfig = nil
        checkpointSavedAt = nil
    }

    func resetSection(_ section: ToolboxConfigSection) {
        var next = ConfigManager.shared.config
        switch section {
        case .general:
            next.general = GeneralConfig()
        case .dockMinimize:
            next.dockMinimize = DockMinimizeConfig()
        case .clipboard:
            next.clipboard = ClipboardConfig()
        case .portKiller:
            next.portKiller = PortKillerConfig()
        case .keepAwake:
            next.keepAwake = KeepAwakeConfig()
        case .cleanLock:
            next.cleanLock = CleanLockConfig()
        case .customCommands:
            next.customCommands = CustomCommandsConfig()
        case .scrollDirection:
            next.scrollDirection = ScrollDirectionConfig()
        }
        ConfigManager.shared.config = next
    }

    func diffsAgainstCheckpoint(current: ToolboxConfig? = nil) -> [ConfigDiffItem] {
        guard let checkpointConfig else { return [] }
        return Self.diff(from: checkpointConfig, to: current ?? ConfigManager.shared.config)
    }

    func diffsAgainstDisk(current: ToolboxConfig? = nil, diskURL: URL? = nil) -> [ConfigDiffItem] {
        let url = diskURL ?? ConfigManager.shared.configURL
        guard let data = try? Data(contentsOf: url),
              let diskConfig = try? JSONDecoder().decode(ToolboxConfig.self, from: data) else {
            return []
        }
        return Self.diff(from: diskConfig, to: current ?? ConfigManager.shared.config)
    }

    nonisolated static func diff(from baseline: ToolboxConfig, to current: ToolboxConfig) -> [ConfigDiffItem] {
        let baseMap = flattenConfig(baseline)
        let currMap = flattenConfig(current)
        let allKeys = Set(baseMap.keys).union(currMap.keys).sorted()

        var changes: [ConfigDiffItem] = []
        for key in allKeys {
            let baseVal = baseMap[key] ?? "(missing)"
            let currVal = currMap[key] ?? "(missing)"
            if baseVal != currVal {
                changes.append(ConfigDiffItem(keyPath: key, baselineValue: baseVal, currentValue: currVal))
            }
        }
        return changes
    }

    private nonisolated static func flattenConfig(_ config: ToolboxConfig) -> [String: String] {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(config),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var output: [String: String] = [:]
        flatten(value: jsonObject, prefix: "", into: &output)
        return output
    }

    private nonisolated static func flatten(value: Any, prefix: String, into output: inout [String: String]) {
        if let dict = value as? [String: Any] {
            if dict.isEmpty, !prefix.isEmpty {
                output[prefix] = "{}"
                return
            }
            for key in dict.keys.sorted() {
                let nextPrefix = prefix.isEmpty ? key : "\(prefix).\(key)"
                if let nested = dict[key] {
                    flatten(value: nested, prefix: nextPrefix, into: &output)
                }
            }
            return
        }

        if let array = value as? [Any] {
            if let stringItems = array as? [String] {
                output[prefix] = "[\(stringItems.joined(separator: ", "))]"
            } else {
                output[prefix] = "\(array.count) item(s)"
            }
            return
        }

        if let boolVal = value as? NSNumber, CFGetTypeID(boolVal) == CFBooleanGetTypeID() {
            output[prefix] = boolVal.boolValue ? "true" : "false"
            return
        }

        output[prefix] = String(describing: value)
    }
}
