import SwiftUI

enum ModuleCategory: String, CaseIterable, Identifiable {
    case windowAndDock = "Window & Dock"
    case productivity = "Clipboard & Text"
    case developer = "Developer Tools"
    case system = "System & Power"
    case automation = "Commands & Shortcuts"

    var id: String { rawValue }
}

/// Protocol for all Toolbox utility modules.
/// Adding a new feature only requires implementing this protocol and registering it in `ModuleRegistry`.
@MainActor
protocol ToolboxModule: AnyObject {
    var id: String { get }
    var name: String { get }
    var tagline: String { get }
    var aboutSummary: String { get }
    var featureTips: [String] { get }
    var symbolName: String { get }
    var accentColor: Color { get }
    var category: ModuleCategory { get }

    var requiresAccessibility: Bool { get }
    var accessibilityReason: String { get }

    var isRunning: Bool { get }

    func isEnabled(in config: ToolboxConfig) -> Bool
    func setEnabled(_ enabled: Bool, in config: inout ToolboxConfig)

    func statusText(in config: ToolboxConfig, accessibilityGranted: Bool) -> String
    func shortcutText(in config: ToolboxConfig) -> String?

    func start()
    func stop()
    func reload(with config: ToolboxConfig)

    /// Return the module's SwiftUI customization view.
    func makeSettingsView() -> AnyView
}

extension ToolboxModule {
    var aboutSummary: String { tagline }
    var featureTips: [String] { [] }

    var accessibilityReason: String {
        "Required to observe system-wide events for this module."
    }

    func shortcutText(in config: ToolboxConfig) -> String? {
        nil
    }

    func statusText(in config: ToolboxConfig, accessibilityGranted: Bool) -> String {
        if !isEnabled(in: config) { return "Disabled" }
        if !config.general.appEnabled { return "Paused" }
        if requiresAccessibility && !accessibilityGranted { return "Needs Accessibility" }
        return isRunning ? "Active" : "Standby"
    }
}
