import AppKit
import SwiftUI

@MainActor
private final class QuickScreenshotSettingsUIState: ObservableObject {
    @Published var permissionPollTask: Task<Void, Never>?
}

struct QuickScreenshotSettingsView: View {
    @ObservedObject var module: QuickScreenshotModule
    @ObservedObject private var configManager = ConfigManager.shared

    @StateObject private var uiState = QuickScreenshotSettingsUIState()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            captureAndShortcutSection
            toolDefaultsSection
            editorAndExportSection
        }
        .onAppear {
            module.refreshScreenPermission()
            startPermissionPolling()
        }
        .onDisappear {
            uiState.permissionPollTask?.cancel()
            uiState.permissionPollTask = nil
        }
    }

    private func startPermissionPolling() {
        uiState.permissionPollTask?.cancel()
        uiState.permissionPollTask = Task { @MainActor in
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                module.refreshScreenPermission()
            }
        }
    }

    // MARK: - Capture & Shortcut

    private var captureAndShortcutSection: some View {
        let appEnabled = configManager.config.general.appEnabled
        let cfg = configManager.config.quickScreenshot

        return FeatureSection(
            "Capture & Shortcut",
            subtitle: "Capture an area or window straight into Quick Editor or directly to your clipboard."
        ) {
            SettingRow(
                "Capture Screenshot",
                subtitle: appEnabled
                    ? "Drag an area or press Space to capture a window. Esc cancels cleanly."
                    : "Resume Toolbox in the top bar before taking a screenshot."
            ) {
                Button {
                    if !configManager.config.quickScreenshot.enabled {
                        configManager.config.quickScreenshot.enabled = true
                    }
                    module.captureRegion()
                } label: {
                    HStack(spacing: 6) {
                        if module.isCapturing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "camera.viewfinder")
                        }
                        Text(module.isCapturing ? "Selecting area…" : "Capture Now")
                    }
                }
                .buttonStyle(.toolboxProminent(.red))
                .controlSize(.regular)
                .disabled(!appEnabled || module.isCaptureInFlight)
                .focusEffectDisabled()
                .pointerCursor(appEnabled && !module.isCaptureInFlight)
            }

            Divider()

            SettingRow(
                "Global Capture Shortcut",
                subtitle: "Zero-permission hotkey to start Quick Screenshot from any app."
            ) {
                ShortcutRecorderView(
                    shortcut: cfg.shortcut,
                    defaultShortcut: QuickScreenshotConfig.defaultShortcut,
                    sourceID: "quick_screenshot",
                    registrationKey: module.hotKeyName
                ) { newShortcut in
                    configManager.config.quickScreenshot.shortcut = newShortcut
                }
            }

            Divider()

            SettingRow(
                "Screen Recording Permission",
                subtitle: "macOS must allow Toolbox to capture your screen. Redaction and OCR run locally."
            ) {
                HStack(spacing: 8) {
                    StatusBadge(
                        text: module.screenRecordingGranted ? "Granted" : "Not Granted",
                        color: module.screenRecordingGranted ? .green : .orange
                    )

                    if !module.screenRecordingGranted {
                        Button("Grant Access…") {
                            module.requestScreenAccess()
                        }
                        .buttonStyle(.toolboxProminent(.orange))
                        .controlSize(.regular)
                        .focusEffectDisabled()
                        .pointerCursor()
                    }

                    Button("Open Settings") {
                        module.openScreenSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .focusEffectDisabled()
                    .pointerCursor()
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            Divider()

            SettingRow(
                "Open Editor After Capture",
                subtitle: cfg.openEditorAfterCapture
                    ? "Opens Quick Editor so you can annotate or redact secrets before copying."
                    : "Copies the raw unredacted capture straight to Clipboard (and Clipboard Image History) with a quick Annotate card."
            ) {
                Toggle("", isOn: $configManager.config.quickScreenshot.openEditorAfterCapture)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            Divider()

            SettingRow(
                "Close Editor After Copy",
                subtitle: "Automatically closes Quick Editor right after pressing Copy (⌘ C / Return)."
            ) {
                Toggle("", isOn: $configManager.config.quickScreenshot.closeEditorAfterCopy)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            Divider()

            SettingRow(
                "Exclude Window Shadow",
                subtitle: "When capturing a single window (press Space after starting capture), leave out the transparent macOS drop shadow around the window."
            ) {
                Toggle("", isOn: $configManager.config.quickScreenshot.omitWindowShadow)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }
        }
        .id(ModuleFocusAnchor.shortcuts.rawValue)
    }

    // MARK: - Tool Defaults & Behavior

    private var toolDefaultsSection: some View {
        let cfg = configManager.config.quickScreenshot
        let presets = cfg.toolPresets

        return FeatureSection(
            "Tool Defaults & Behavior",
            subtitle: "Customize starting tools, per-tool defaults, and whether Quick Editor remembers your last picks."
        ) {
            SettingRow(
                "Remember Last Tool Styles",
                subtitle: cfg.rememberLastToolSettings
                    ? "Automatically saves color, size, and style changes you make in Quick Editor for the next capture."
                    : "Each capture starts fresh with your configured defaults below."
            ) {
                Toggle("", isOn: $configManager.config.quickScreenshot.rememberLastToolSettings)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            Divider()

            SettingRow(
                "Default Starting Tool",
                subtitle: "Which tool is active immediately when Quick Editor opens."
            ) {
                Picker("", selection: $configManager.config.quickScreenshot.defaultTool) {
                    ForEach(ScreenshotStartingTool.allCases) { startingTool in
                        Text(startingTool.label).tag(startingTool)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .pointerCursor()
            }

            Divider()

            SettingRow(
                "Default Redaction Style",
                subtitle: "Pixelate applies a mosaic; Smooth Blur softens; Solid Box paints an opaque block; Smart Erase fills from the surrounding background. Auto-Redact scans 100% on-device with Apple Vision and flattens pixels permanently on Copy or Save."
            ) {
                Picker("", selection: $configManager.config.quickScreenshot.defaultRedactMode) {
                    ForEach(RedactStyle.allCases) { style in
                        Text(style.shortLabel).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 248)
                .pointerCursor()
            }

            if presets.redact.style == .pixelate || presets.redact.style == .blur {
                Divider()

                SettingRow(
                    "Redaction Strength",
                    subtitle: "Controls mosaic block size or blur radius for manual and Auto-Redact boxes."
                ) {
                    Picker("", selection: $configManager.config.quickScreenshot.toolPresets.redact.strength) {
                        ForEach(RedactStrength.allCases) { strength in
                            Text(strength.fullLabel).tag(strength)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .pointerCursor()
                }
            } else if presets.redact.style == .solidBlack {
                Divider()

                SettingRow(
                    "Solid Box Color",
                    subtitle: "Opaque fill color used by Solid Box redactions."
                ) {
                    Picker("", selection: $configManager.config.quickScreenshot.toolPresets.redact.solidColor) {
                        ForEach(RedactSolidColor.allCases) { solidColor in
                            Text(solidColor.label).tag(solidColor)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .pointerCursor()
                }
            }

            Divider()

            SettingRow(
                "Default Annotation Color",
                subtitle: "Used by Arrow, Rectangle, and Ellipse tools."
            ) {
                HStack(spacing: 5) {
                    ForEach(AnnotationColor.allCases) { color in
                        let isSelected = presets.arrow.color == color
                        Button {
                            var next = configManager.config.quickScreenshot.toolPresets
                            next.arrow.color = color
                            next.rectangle.color = color
                            next.ellipse.color = color
                            configManager.config.quickScreenshot.toolPresets = next
                        } label: {
                            Circle()
                                .fill(color.swiftUIColor)
                                .frame(width: 15, height: 15)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            isSelected ? Color.white : Color.white.opacity(0.28),
                                            lineWidth: isSelected ? 2.2 : 1
                                        )
                                )
                                .padding(2)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help(color.label)
                        .pointerCursor()
                    }
                }
            }

            Divider()

            SettingRow(
                "Default Highlighter",
                subtitle: "Color and mode (Freehand marker vs straight Box highlight)."
            ) {
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        ForEach([AnnotationColor.yellow, .green, .blue, .orange, .red, .purple], id: \.self) { color in
                            let isSelected = presets.highlighter.color == color
                            Button {
                                configManager.config.quickScreenshot.toolPresets.highlighter.color = color
                            } label: {
                                Circle()
                                    .fill(color.swiftUIColor)
                                    .frame(width: 13, height: 13)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(
                                                isSelected ? Color.white : Color.white.opacity(0.28),
                                                lineWidth: isSelected ? 2 : 1
                                            )
                                    )
                                    .padding(1.5)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .help(color.label)
                            .pointerCursor()
                        }
                    }

                    Picker("", selection: $configManager.config.quickScreenshot.toolPresets.highlighter.mode) {
                        ForEach(HighlighterMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 146)
                    .pointerCursor()
                }
            }

            Divider()

            SettingRow(
                "Default Text Callout",
                subtitle: "Backdrop style for new text annotations."
            ) {
                Picker("", selection: $configManager.config.quickScreenshot.toolPresets.text.backgroundStyle) {
                    ForEach(TextBackgroundStyle.allCases) { bg in
                        Text(bg.label).tag(bg)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
                .pointerCursor()
            }

            Divider()

            SettingRow(
                "Default Beautify Backdrop",
                subtitle: "Wrap copied and saved screenshots in a gradient frame with rounded corners and soft shadow."
            ) {
                HStack(spacing: 10) {
                    if presets.beautify.enabled {
                        Picker("", selection: $configManager.config.quickScreenshot.toolPresets.beautify.backdrop) {
                            ForEach(BeautifyBackdrop.allCases.filter { $0 != .none }) { backdrop in
                                Text(backdrop.label).tag(backdrop)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        .pointerCursor()
                    }

                    Toggle("", isOn: $configManager.config.quickScreenshot.toolPresets.beautify.enabled)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                }
            }

            Divider()

            SettingRow(
                "Reset Tool Defaults",
                subtitle: "Restore factory tool presets (Red arrows, Black text pill, White numbers, Yellow highlighter, Pixelate redaction)."
            ) {
                Button("Reset to Defaults") {
                    configManager.config.quickScreenshot.defaultTool = .arrow
                    configManager.config.quickScreenshot.lastUsedTool = .arrow
                    configManager.config.quickScreenshot.toolPresets = ScreenshotToolPresets()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(
                    cfg.defaultTool == .arrow
                    && cfg.toolPresets == ScreenshotToolPresets()
                )
                .focusEffectDisabled()
                .pointerCursor(
                    cfg.defaultTool != .arrow
                    || cfg.toolPresets != ScreenshotToolPresets()
                )
            }
        }
    }

    // MARK: - Editor & Export

    private var editorAndExportSection: some View {
        let cfg = configManager.config.quickScreenshot

        return FeatureSection(
            "Export & Notifications",
            subtitle: "File format, destination folder, and HUD confirmation."
        ) {
            SettingRow(
                "Save Format",
                subtitle: "File format used by Save (⌘ S) and Save As… (⇧ ⌘ S)."
            ) {
                Picker("", selection: $configManager.config.quickScreenshot.saveFormat) {
                    ForEach(ScreenshotSaveFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
                .pointerCursor()
            }

            if cfg.saveFormat == .jpeg {
                Divider()

                SettingRow(
                    "JPEG Quality (\(Int((cfg.jpegQuality * 100).rounded()))%)",
                    subtitle: "Higher quality preserves sharper text; transparent areas composite over white."
                ) {
                    Slider(
                        value: $configManager.config.quickScreenshot.jpegQuality,
                        in: 0.1...1.0,
                        step: 0.05
                    )
                    .frame(width: 180)
                    .pointerCursor()
                }
            }

            Divider()

            SettingRow(
                "Default Save Folder",
                subtitle: "Used when saving immediately with ⌘ S or the Save button."
            ) {
                HStack(spacing: 8) {
                    Text(cfg.defaultSaveDirectory)
                        .toolboxFont(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 190, alignment: .trailing)

                    Button("Choose…") {
                        chooseSaveDirectory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .fixedSize(horizontal: true, vertical: false)
                    .focusEffectDisabled()
                    .pointerCursor()
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            Divider()

            SettingRow(
                "Show Toast Notification",
                subtitle: "Shows a brief confirmation pill when screenshots are copied or saved."
            ) {
                Toggle("", isOn: $configManager.config.quickScreenshot.showToast)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }
        }
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let current = (configManager.config.quickScreenshot.defaultSaveDirectory as NSString).expandingTildeInPath
        panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if url.path.hasPrefix(home) {
                let suffix = String(url.path.dropFirst(home.count))
                configManager.config.quickScreenshot.defaultSaveDirectory = suffix.isEmpty ? "~" : "~\(suffix)"
            } else {
                configManager.config.quickScreenshot.defaultSaveDirectory = url.path
            }
        }
    }
}
