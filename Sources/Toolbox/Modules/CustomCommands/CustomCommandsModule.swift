import AppKit
import Carbon
import SwiftUI

@MainActor
final class CustomCommandsModule: ToolboxModule, ObservableObject {
    let id = "custom_commands"
    let name = "Custom Commands"
    let tagline = "Bind global shortcuts to shell scripts, apps, URLs, or text snippets."
    let aboutSummary = "Create your own global keyboard shortcuts to run zsh commands, launch apps, open URLs, or paste reusable text snippets. Everything is saved cleanly in ~/.config/toolbox/config.json so you can version-control your shortcuts."
    let featureTips = [
        "Enable 'Show toast' on silent shell commands (like flushing DNS) for instant confirmation.",
        "All enabled commands also appear under Quick Commands in the Status Bar popover.",
        "Toolbox warns inline if a shortcut conflicts with another app or macOS system hotkey."
    ]
    let symbolName = "terminal"
    let accentColor = Color.purple
    let category: ModuleCategory = .automation
    let requiresAccessibility = false
    let accessibilityReason = "Optional: only required if a 'Paste Text Snippet' command synthesizes ⌘ V."

    @Published private(set) var isRunning = false
    @Published private(set) var lastOutput: String?

    func clearLastOutput() {
        lastOutput = nil
    }

    private let hotKeyPrefix = "custom_command."
    private var config = CustomCommandsConfig()

    func isEnabled(in config: ToolboxConfig) -> Bool {
        config.customCommands.enabled
    }

    func setEnabled(_ enabled: Bool, in config: inout ToolboxConfig) {
        config.customCommands.enabled = enabled
    }

    func shortcutText(in config: ToolboxConfig) -> String? {
        let count = config.customCommands.commands.filter(\.enabled).count
        return count == 0 ? nil : "\(count) active"
    }

    func reload(with fullConfig: ToolboxConfig) {
        self.config = fullConfig.customCommands
        if config.enabled {
            isRunning = true
            registerAllCommands()
        } else {
            stop()
        }
    }

    func start() {
        isRunning = true
        registerAllCommands()
    }

    func stop() {
        HotKeyManager.shared.unregisterAll(prefix: hotKeyPrefix)
        isRunning = false
    }

    func runCommand(_ command: CustomCommand) {
        switch command.kind {
        case .shell:
            let payload = command.payload
            let name = command.name
            let notify = command.showNotification
            Task.detached(priority: .userInitiated) {
                let result = Self.executeShellSync(payload)
                await MainActor.run {
                    let message = result.output.isEmpty
                        ? "Ran '\(name)' (exit \(result.exitCode))"
                        : result.output
                    self.lastOutput = message
                    if notify || result.exitCode != 0 {
                        HUDToast.shared.show(
                            title: result.exitCode == 0 ? "\(name) done" : "\(name) failed (exit \(result.exitCode))",
                            symbol: result.exitCode == 0 ? "terminal" : "exclamationmark.triangle.fill",
                            tint: result.exitCode == 0 ? .purple : .red
                        )
                    }
                }
            }

        case .openApp:
            let url = URL(fileURLWithPath: command.payload)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            lastOutput = "Opened \(url.lastPathComponent)"
            if command.showNotification {
                HUDToast.shared.show(title: "Opened \(url.lastPathComponent)", symbol: "app.badge.checkmark", tint: .purple)
            }

        case .openURL:
            if let url = URL(string: command.payload) {
                NSWorkspace.shared.open(url)
                lastOutput = "Opened \(command.payload)"
                if command.showNotification {
                    HUDToast.shared.show(title: "Opened \(url.host ?? command.name)", symbol: "safari", tint: .purple)
                }
            } else {
                lastOutput = "Invalid URL: \(command.payload)"
                HUDToast.shared.show(title: "Invalid URL", symbol: "exclamationmark.triangle.fill", tint: .red)
            }

        case .pasteText:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(command.payload, forType: .string)
            if AXIsProcessTrusted() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    let source = CGEventSource(stateID: .hidSystemState)
                    let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
                    let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
                    vDown?.flags = .maskCommand
                    vUp?.flags = .maskCommand
                    vDown?.post(tap: .cghidEventTap)
                    vUp?.post(tap: .cghidEventTap)
                }
            }
            lastOutput = "Copied snippet '\(command.name)'"
            if command.showNotification {
                HUDToast.shared.show(title: "Pasted '\(command.name)'", symbol: "text.insert", tint: .purple)
            }
        }
    }

    nonisolated static func executeShellSync(_ command: String) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    func makeSettingsView() -> AnyView {
        AnyView(CustomCommandsSettingsView(module: self))
    }

    private func registerAllCommands() {
        HotKeyManager.shared.unregisterAll(prefix: hotKeyPrefix)
        for command in config.commands where command.enabled {
            let key = hotKeyPrefix + command.id
            HotKeyManager.shared.register(name: key, shortcut: command.shortcut) { [weak self] in
                self?.runCommand(command)
            }
        }
    }
}
