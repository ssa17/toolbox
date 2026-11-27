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

    // MARK: - Editor & Export

    private var editorAndExportSection: some View {
        let cfg = configManager.config.quickScreenshot

        return FeatureSection(
            "Editor & Export",
            subtitle: "Defaults for redaction, file format, destination folder, and HUD confirmation."
        ) {
            SettingRow(
                "Default Redaction Style",
                subtitle: "Solid Opaque Box overwrites pixels irreversibly with pure black; Smooth Blur softens the region; Pixelate applies a fine mosaic."
            ) {
                Picker("", selection: $configManager.config.quickScreenshot.defaultRedactMode) {
                    ForEach(RedactStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .pointerCursor()
            }

            Divider()

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
