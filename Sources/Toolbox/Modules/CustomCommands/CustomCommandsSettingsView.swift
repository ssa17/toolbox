import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class NewCommandDraft: ObservableObject {
    @Published var isAddingNew = false
    @Published var expandedCommandID: String?
    @Published var name = ""
    @Published var kind: CustomCommandKind = .shell
    @Published var payload = ""
    @Published var shortcut = ShortcutSpec(key: "r", modifiers: [.command, .option])
}

struct CustomCommandsSettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject var module: CustomCommandsModule
    @StateObject private var draft = NewCommandDraft()

    var body: some View {
        let commands = configManager.config.customCommands.commands
        let enabledCount = commands.filter(\.enabled).count
        let showingBuilder = draft.isAddingNew || commands.isEmpty

        VStack(alignment: .leading, spacing: 22) {
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
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text(
                            commands.isEmpty
                                ? "Add your first command below or pick from Templates."
                                : "\(enabledCount) of \(commands.count) enabled · Click a command to edit"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Spacer()

                        if !commands.isEmpty {
                            Button {
                                if draft.isAddingNew {
                                    draft.isAddingNew = false
                                } else {
                                    draft.expandedCommandID = nil
                                    draft.isAddingNew = true
                                }
                            } label: {
                                Label(
                                    draft.isAddingNew ? "Cancel" : "Add Command",
                                    systemImage: draft.isAddingNew ? "xmark" : "plus"
                                )
                                .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointerCursor()
                        }
                    }

                    if showingBuilder {
                        newCommandBuilder(canCancel: !commands.isEmpty)
                    }

                    if !commands.isEmpty {
                        VStack(spacing: 0) {
                            ForEach($configManager.config.customCommands.commands) { $cmd in
                                if cmd.id != commands.first?.id {
                                    Divider()
                                }
                                commandRow(for: $cmd)
                            }
                        }
                    }
                }
            }

            FeatureSection("Menu Bar") {
                SettingRow(
                    "Show Quick Commands list",
                    subtitle: "Include active Custom Commands in the status bar menu when Custom Commands is enabled."
                ) {
                    Toggle("", isOn: $configManager.config.general.showQuickCommandsInMenuBar)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }
            }
        }
    }

    @ViewBuilder
    private func newCommandBuilder(canCancel: Bool) -> some View {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPayload = draft.payload.trimmingCharacters(in: .whitespacesAndNewlines)

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

                if canCancel {
                    Button("Cancel") {
                        draft.isAddingNew = false
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .pointerCursor()
                }
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

                ShortcutRecorderView(
                    shortcut: draft.shortcut,
                    defaultShortcut: ShortcutSpec(key: "r", modifiers: [.command, .option]),
                    sourceID: nil,
                    showConflictWarnings: false
                ) { newShortcut in
                    draft.shortcut = newShortcut
                }

                Spacer()

                Button("Test") {
                    guard !trimmedPayload.isEmpty else { return }
                    let temp = CustomCommand(
                        name: trimmedName.isEmpty ? "Test" : draft.name,
                        enabled: true,
                        shortcut: draft.shortcut,
                        kind: draft.kind,
                        payload: trimmedPayload,
                        showNotification: true
                    )
                    module.runCommand(temp)
                }
                .buttonStyle(.bordered)
                .disabled(trimmedPayload.isEmpty)
                .pointerCursor(!trimmedPayload.isEmpty)

                Button("Add Command") {
                    addDraftCommand()
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty || trimmedPayload.isEmpty)
                .pointerCursor(!trimmedName.isEmpty && !trimmedPayload.isEmpty)
            }

            ShortcutConflictStatusView(
                shortcut: draft.shortcut,
                sourceID: nil,
                onAssignHere: nil
            )
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func commandRow(for cmdBinding: Binding<CustomCommand>) -> some View {
        let cmd = cmdBinding.wrappedValue
        let isExpanded = (draft.expandedCommandID == cmd.id)
        let sourceID = "custom_command.\(cmd.id)"
        let canRun = !cmd.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let displayTitle = cmd.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled Command"
            : cmd.name

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    draft.expandedCommandID = isExpanded ? nil : cmd.id
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.primary.opacity(cmd.enabled ? 0.07 : 0.035))
                                .frame(width: 28, height: 28)
                            Image(systemName: iconName(for: cmd.kind))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(displayTitle)
                                    .font(.callout.weight(.medium))
                                    .opacity(cmd.enabled ? 1.0 : 0.55)
                                    .lineLimit(1)

                                if cmd.showNotification {
                                    Image(systemName: "bell.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                        .help("Shows notification toast")
                                }
                            }

                            HStack(spacing: 5) {
                                Text(shortLabel(for: cmd.kind))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(payloadPreview(for: cmd))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerCursor()

                HStack(spacing: 8) {
                    ShortcutRecorderView(
                        shortcut: cmd.shortcut,
                        defaultShortcut: ShortcutSpec.none,
                        sourceID: sourceID,
                        registrationKey: sourceID,
                        showConflictWarnings: false
                    ) { newShortcut in
                        cmdBinding.wrappedValue.shortcut = newShortcut
                    }

                    Button {
                        module.runCommand(cmd)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canRun)
                    .help("Run now")
                    .pointerCursor(canRun)

                    Button {
                        draft.expandedCommandID = isExpanded ? nil : cmd.id
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "pencil")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(isExpanded ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(isExpanded ? "Collapse editor" : "Edit command")
                    .pointerCursor()

                    Toggle("", isOn: cmdBinding.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .pointerCursor()
                }
            }

            if cmd.enabled {
                ShortcutConflictStatusView(
                    shortcut: cmd.shortcut,
                    sourceID: sourceID,
                    registrationKey: sourceID,
                    onAssignHere: nil
                )
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Command name", text: cmdBinding.name)
                            .textFieldStyle(.roundedBorder)

                        Picker("", selection: cmdBinding.kind) {
                            ForEach(CustomCommandKind.allCases, id: \.self) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 155)
                        .pointerCursor()
                    }

                    HStack(spacing: 8) {
                        TextField(cmd.kind.placeholder, text: cmdBinding.payload)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))

                        if cmd.kind == .openApp {
                            Button("Browse…") {
                                pickAppPath { path, _ in
                                    cmdBinding.wrappedValue.payload = path
                                }
                            }
                            .controlSize(.small)
                            .pointerCursor()
                        }
                    }

                    HStack(spacing: 10) {
                        Toggle("Show toast", isOn: cmdBinding.showNotification)
                            .font(.caption)
                            .toggleStyle(.checkbox)
                            .pointerCursor()

                        Spacer()

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
                            draft.expandedCommandID = copy.id
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .pointerCursor()

                        Button(role: .destructive) {
                            let idToRemove = cmd.id
                            if draft.expandedCommandID == idToRemove {
                                draft.expandedCommandID = nil
                            }
                            configManager.config.customCommands.commands.removeAll { $0.id == idToRemove }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .pointerCursor()

                        Button("Done") {
                            draft.expandedCommandID = nil
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .pointerCursor()
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
            }
        }
        .padding(.vertical, 10)
    }

    private func iconName(for kind: CustomCommandKind) -> String {
        switch kind {
        case .shell: return "terminal"
        case .openApp: return "app.badge"
        case .openURL: return "globe"
        case .pasteText: return "doc.on.clipboard"
        }
    }

    private func payloadPreview(for cmd: CustomCommand) -> String {
        let flattened = cmd.payload
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? "No command set" : flattened
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
        draft.isAddingNew = false
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
