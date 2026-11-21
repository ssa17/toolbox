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
    @Published var showNotification = true
    @Published var copiedOutput = false

    private var copiedOutputTask: Task<Void, Never>?

    func markOutputCopied() {
        copiedOutput = true
        copiedOutputTask?.cancel()
        copiedOutputTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.copiedOutput = false
        }
    }
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
            FeatureSection("Configured Commands", subtitle: "Enable, customize, or run saved commands.") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        if commands.isEmpty {
                            Text("Add your first command below or pick from Templates.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            StatusBadge(
                                text: "\(enabledCount) of \(commands.count) enabled",
                                color: enabledCount > 0 ? module.accentColor : .secondary
                            )
                            Text("Click a command to edit")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

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
                            .focusEffectDisabled()
                            .pointerCursor()
                        }
                    }

                    if showingBuilder {
                        newCommandBuilder(canCancel: !commands.isEmpty)
                    }

                    if !commands.isEmpty {
                        VStack(spacing: 8) {
                            ForEach($configManager.config.customCommands.commands) { $cmd in
                                commandRow(for: $cmd)
                            }
                        }
                    }
                }
            }

            if let output = module.lastOutput {
                FeatureSection("Last Run Output") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(output, forType: .string)
                                draft.markOutputCopied()
                            } label: {
                                if draft.copiedOutput {
                                    Label("Copied", systemImage: "checkmark")
                                } else {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .focusEffectDisabled()
                            .pointerCursor()

                            Button {
                                module.clearLastOutput()
                            } label: {
                                Label("Clear", systemImage: "xmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .focusEffectDisabled()
                            .pointerCursor()
                        }

                        ScrollView(.vertical) {
                            Text(output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                        .padding(10)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            FeatureSection("Menu Bar") {
                SettingRow(
                    "Show Quick Commands list",
                    subtitle: "Shows up to 4 enabled Custom Commands in the status bar menu when Custom Commands is enabled."
                ) {
                    Toggle("", isOn: $configManager.config.general.showQuickCommandsInMenuBar)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                }
            }
        }
    }

    @ViewBuilder
    private func newCommandBuilder(canCancel: Bool) -> some View {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPayload = draft.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let canAdd = !trimmedName.isEmpty && !trimmedPayload.isEmpty

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("New Command")
                    .font(.callout.weight(.semibold))

                Spacer()

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
                .pointerCursor()

                if canCancel {
                    Button("Cancel") {
                        draft.isAddingNew = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusEffectDisabled()
                    .pointerCursor()
                }
            }

            ToolboxSegmentedControl(
                options: Array(CustomCommandKind.allCases),
                selection: $draft.kind,
                accentColor: module.accentColor,
                isFullWidth: true,
                label: { shortLabel(for: $0) },
                symbol: { iconName(for: $0) }
            )

            TextField("Command name (e.g. Open VS Code)", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            HStack(alignment: .top, spacing: 8) {
                TextField(draft.kind.placeholder, text: $draft.payload, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit {
                        if canAdd {
                            addDraftCommand()
                        }
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
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Toggle("", isOn: $draft.showNotification)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                    Text("Show toast")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
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
                        showNotification: draft.showNotification
                    )
                    module.runCommand(temp)
                }
                .buttonStyle(.bordered)
                .disabled(trimmedPayload.isEmpty)
                .focusEffectDisabled()
                .pointerCursor(!trimmedPayload.isEmpty)

                Button("Add Command") {
                    addDraftCommand()
                }
                .buttonStyle(.toolboxProminent(.purple))
                .disabled(!canAdd)
                .focusEffectDisabled()
                .pointerCursor(canAdd)
            }

            if !canAdd {
                Text(
                    trimmedName.isEmpty && trimmedPayload.isEmpty
                        ? "Enter a command name and payload to enable Add Command."
                        : (trimmedName.isEmpty
                            ? "Enter a command name to enable Add Command."
                            : "Enter a command, app path, URL, or text snippet to enable Add Command.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !draft.shortcut.isEmpty {
                ShortcutConflictStatusView(
                    shortcut: draft.shortcut,
                    sourceID: nil,
                    onAssignHere: nil
                )
            }
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
        let kindTint = kindColor(for: cmd.kind)
        let readableKindTint = ToolboxTheme.readableAccentText(for: kindTint)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    draft.expandedCommandID = isExpanded ? nil : cmd.id
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(kindTint.opacity(cmd.enabled ? 0.16 : 0.08))
                                .frame(width: 30, height: 30)
                            Image(systemName: iconName(for: cmd.kind))
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(cmd.enabled ? readableKindTint : .secondary)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(displayTitle)
                                    .font(.callout.weight(.semibold))
                                    .opacity(cmd.enabled ? 1.0 : 0.65)
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
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(cmd.enabled ? readableKindTint : .secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(
                                        cmd.enabled ? kindTint.opacity(0.14) : Color.primary.opacity(0.06),
                                        in: Capsule()
                                    )
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
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(canRun ? .primary : .secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .menuRowHover(cornerRadius: 6)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRun)
                    .help("Run now")
                    .pointerCursor(canRun)

                    Button {
                        draft.expandedCommandID = isExpanded ? nil : cmd.id
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(isExpanded ? ToolboxTheme.readableAccentText(for: module.accentColor) : Color.secondary)
                            .background(
                                isExpanded ? module.accentColor.opacity(0.14) : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .contentShape(Rectangle())
                            .menuRowHover(cornerRadius: 6)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse editor" : "Edit command")
                    .pointerCursor()

                    Toggle("", isOn: cmdBinding.enabled)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                }
            }

            if !cmd.shortcut.isEmpty {
                ShortcutConflictStatusView(
                    shortcut: cmd.shortcut,
                    sourceID: sourceID,
                    registrationKey: sourceID,
                    onAssignHere: nil
                )
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Command name", text: cmdBinding.name)
                        .textFieldStyle(.roundedBorder)

                    ToolboxSegmentedControl(
                        options: Array(CustomCommandKind.allCases),
                        selection: cmdBinding.kind,
                        accentColor: module.accentColor,
                        isFullWidth: true,
                        label: { shortLabel(for: $0) },
                        symbol: { iconName(for: $0) }
                    )

                    HStack(alignment: .top, spacing: 8) {
                        TextField(cmd.kind.placeholder, text: cmdBinding.payload, axis: .vertical)
                            .lineLimit(1...4)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))

                        if cmd.kind == .openApp {
                            Button("Choose App…") {
                                pickAppPath { path, _ in
                                    cmdBinding.wrappedValue.payload = path
                                }
                            }
                            .controlSize(.small)
                            .pointerCursor()
                        }
                    }

                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Toggle("", isOn: cmdBinding.showNotification)
                                .labelsHidden()
                                .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                                .pointerCursor()
                            Text("Show toast")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            let copy = CustomCommand(
                                name: "\(cmd.name) Copy",
                                enabled: false,
                                shortcut: .none,
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
                        .focusEffectDisabled()
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
                        .buttonStyle(.toolboxDestructive)
                        .focusEffectDisabled()
                        .pointerCursor()

                        Button("Done") {
                            draft.expandedCommandID = nil
                        }
                        .controlSize(.small)
                        .buttonStyle(.toolboxProminent(.purple))
                        .focusEffectDisabled()
                        .pointerCursor()
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            cmd.enabled ? module.accentColor.opacity(0.045) : Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isExpanded
                        ? module.accentColor.opacity(0.45)
                        : (cmd.enabled ? module.accentColor.opacity(0.20) : Color.primary.opacity(0.08)),
                    lineWidth: 1
                )
        )
        .menuRowHover(cornerRadius: 10)
    }

    private func kindColor(for kind: CustomCommandKind) -> Color {
        switch kind {
        case .shell: return .purple
        case .openApp: return .blue
        case .openURL: return .cyan
        case .pasteText: return .orange
        }
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
