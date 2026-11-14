import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class NewCommandDraft: ObservableObject {
    @Published var name = ""
    @Published var kind: CustomCommandKind = .shell
    @Published var payload = ""
    @Published var shortcut = ShortcutSpec(key: "r", modifiers: [.command, .option])
}

struct CustomCommandsSettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var hotKeyManager = HotKeyManager.shared
    @ObservedObject var module: CustomCommandsModule
    @StateObject private var draft = NewCommandDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            FeatureSection("New Command", subtitle: "Bind a global shortcut to run a script, open an app/URL, or paste text.") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Picker("", selection: $draft.kind) {
                            ForEach(CustomCommandKind.allCases, id: \.self) { kind in
                                Text(shortLabel(for: kind)).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .pointerCursor()

                        Menu("Templates") {
                            ForEach(Self.templates, id: \.name) { tpl in
                                Button(tpl.name) {
                                    draft.name = tpl.name
                                    draft.kind = tpl.kind
                                    draft.payload = tpl.payload
                                    draft.shortcut = tpl.shortcut
                                }
                            }
                        }
                        .frame(width: 112)
                        .pointerCursor()
                    }

                    TextField("Command name (e.g. Open VS Code)", text: $draft.name)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        TextField(draft.kind.placeholder, text: $draft.payload)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit {
                                addDraftCommand()
                            }

                        if draft.kind == .openApp {
                            Button("Choose App…") {
                                pickAppPath { path, appName in
                                    draft.payload = path
                                    if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        draft.name = "Open \(appName)"
                                    }
                                }
                            }
                            .pointerCursor()
                        }
                    }

                    HStack(spacing: 10) {
                        Text("Shortcut")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        ShortcutRecorderView(shortcut: draft.shortcut) { newShortcut in
                            draft.shortcut = newShortcut
                        }

                        Spacer()

                        Button("Test") {
                            let cleanPayload = draft.payload.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !cleanPayload.isEmpty else { return }
                            let temp = CustomCommand(
                                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Test" : draft.name,
                                enabled: true,
                                shortcut: draft.shortcut,
                                kind: draft.kind,
                                payload: cleanPayload,
                                showNotification: true
                            )
                            module.runCommand(temp)
                        }
                        .buttonStyle(.bordered)
                        .disabled(draft.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .pointerCursor(!draft.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Add Command") {
                            addDraftCommand()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            draft.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .pointerCursor(
                            !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                            !draft.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }

                    if let conflict = hotKeyManager.inAppConflictDescription(
                        for: draft.shortcut,
                        excludingSourceID: nil,
                        in: configManager.config
                    ) {
                        Label(conflict, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let output = module.lastOutput {
                FeatureSection("Last Run Output") {
                    HStack(alignment: .top, spacing: 10) {
                        Text(output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(output, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy output")
                        .pointerCursor()

                        Button {
                            module.clearLastOutput()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Clear output")
                        .pointerCursor()
                    }
                }
            }

            FeatureSection("Configured Commands", subtitle: "Enable, customize, or run saved commands.") {
                if configManager.config.customCommands.commands.isEmpty {
                    Text("No custom commands yet. Add one above or pick from Templates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach($configManager.config.customCommands.commands) { $cmd in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    Toggle("", isOn: $cmd.enabled)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .pointerCursor()

                                    TextField("Name", text: $cmd.name)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.callout.weight(.semibold))

                                    Picker("", selection: $cmd.kind) {
                                        ForEach(CustomCommandKind.allCases, id: \.self) { kind in
                                            Text(kind.label).tag(kind)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 155)
                                    .pointerCursor()

                                    ShortcutRecorderView(shortcut: cmd.shortcut) { newShortcut in
                                        cmd.shortcut = newShortcut
                                    }

                                    let canRun = !cmd.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    Button {
                                        module.runCommand(cmd)
                                    } label: {
                                        Image(systemName: "play.fill")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(!canRun)
                                    .help("Run now")
                                    .pointerCursor(canRun)

                                    Button {
                                        let copy = CustomCommand(
                                            name: "\(cmd.name) Copy",
                                            enabled: false,
                                            shortcut: cmd.shortcut,
                                            kind: cmd.kind,
                                            payload: cmd.payload,
                                            showNotification: cmd.showNotification
                                        )
                                        configManager.config.customCommands.commands.append(copy)
                                    } label: {
                                        Image(systemName: "plus.square.on.square")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Duplicate command")
                                    .pointerCursor()

                                    Button(role: .destructive) {
                                        let idToRemove = cmd.id
                                        configManager.config.customCommands.commands.removeAll { $0.id == idToRemove }
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Delete command")
                                    .pointerCursor()
                                }

                                HStack(spacing: 8) {
                                    TextField(cmd.kind.placeholder, text: $cmd.payload)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.caption, design: .monospaced))

                                    if cmd.kind == .openApp {
                                        Button("Browse…") {
                                            pickAppPath { path, _ in
                                                cmd.payload = path
                                            }
                                        }
                                        .controlSize(.small)
                                        .pointerCursor()
                                    }

                                    Toggle("Show toast", isOn: $cmd.showNotification)
                                        .font(.caption)
                                        .toggleStyle(.checkbox)
                                        .pointerCursor()
                                }

                                let sourceID = "custom_command.\(cmd.id)"
                                if cmd.enabled,
                                   let conflict = hotKeyManager.inAppConflictDescription(
                                       for: cmd.shortcut,
                                       excludingSourceID: sourceID,
                                       in: configManager.config
                                   ) {
                                    Label(conflict, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                } else if let err = hotKeyManager.registrationErrors[sourceID] {
                                    Label(err, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private func shortLabel(for kind: CustomCommandKind) -> String {
        switch kind {
        case .shell: return "Shell"
        case .openApp: return "Open App"
        case .openURL: return "Open URL"
        case .pasteText: return "Text Snippet"
        }
    }

    private func pickAppPath(onSelect: (String, String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            let appName = url.deletingPathExtension().lastPathComponent
            onSelect(url.path, appName)
        }
    }

    private func addDraftCommand() {
        let cleanName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPayload = draft.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanPayload.isEmpty else { return }

        let cmd = CustomCommand(
            name: cleanName,
            enabled: true,
            shortcut: draft.shortcut,
            kind: draft.kind,
            payload: cleanPayload,
            showNotification: true
        )
        configManager.config.customCommands.commands.append(cmd)
        draft.name = ""
        draft.payload = ""
    }

    private struct CommandTemplate {
        let name: String
        let kind: CustomCommandKind
        let payload: String
        let shortcut: ShortcutSpec
    }

    private static let templates: [CommandTemplate] = [
        CommandTemplate(
            name: "Copy Local IP",
            kind: .shell,
            payload: "(ipconfig getifaddr en0 || ipconfig getifaddr en1) | tr -d '\\n' | pbcopy",
            shortcut: ShortcutSpec(key: "i", modifiers: [.command, .option, .shift])
        ),
        CommandTemplate(
            name: "Copy ISO Timestamp",
            kind: .shell,
            payload: "date -u +\"%Y-%m-%dT%H:%M:%SZ\" | tr -d '\\n' | pbcopy",
            shortcut: ShortcutSpec(key: "d", modifiers: [.command, .option, .shift])
        ),
        CommandTemplate(
            name: "Open Downloads",
            kind: .shell,
            payload: "open ~/Downloads",
            shortcut: ShortcutSpec(key: "l", modifiers: [.command, .option])
        ),
        CommandTemplate(
            name: "Open Activity Monitor",
            kind: .openApp,
            payload: "/System/Applications/Utilities/Activity Monitor.app",
            shortcut: ShortcutSpec(key: "m", modifiers: [.command, .option, .shift])
        ),
        CommandTemplate(
            name: "Open GitHub",
            kind: .openURL,
            payload: "https://github.com",
            shortcut: ShortcutSpec(key: "g", modifiers: [.command, .option, .shift])
        ),
        CommandTemplate(
            name: "Email Sign-off",
            kind: .pasteText,
            payload: "Best regards,",
            shortcut: ShortcutSpec(key: "s", modifiers: [.command, .option, .shift])
        )
    ]
}
