import AppKit
import SwiftUI

@MainActor
private final class ScreenOCRSettingsUIState: ObservableObject {
    @Published var permissionPollTask: Task<Void, Never>?
    @Published var copiedCaptureID: String?
    @Published var expandedCaptureID: String?

    private var copiedResetTask: Task<Void, Never>?

    func markCopied(_ id: String) {
        copiedCaptureID = id
        copiedResetTask?.cancel()
        copiedResetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            if self?.copiedCaptureID == id {
                self?.copiedCaptureID = nil
            }
        }
    }
}

struct ScreenOCRSettingsView: View {
    @ObservedObject var module: ScreenOCRModule
    @ObservedObject private var configManager = ConfigManager.shared

    @StateObject private var uiState = ScreenOCRSettingsUIState()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            captureAndShortcutSection
            recognitionOptionsSection
            recentCapturesSection
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

    /// Re-checks the Screen Recording grant a few times after open so the badge flips
    /// promptly when the user approves the permission (macOS applies it asynchronously).
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

        return FeatureSection(
            "Capture & Permission",
            subtitle: "Grab text or QR codes from anywhere on screen with a single crosshair selection."
        ) {
            SettingRow(
                "On-Screen Text & QR Capture",
                subtitle: appEnabled
                    ? "Select any region on screen to copy recognized text or QR codes immediately."
                    : "Resume Toolbox in the top bar before capturing on-screen text or QR codes."
            ) {
                Button {
                    if !configManager.config.screenOCR.enabled {
                        configManager.config.screenOCR.enabled = true
                    }
                    module.captureRegion()
                } label: {
                    HStack(spacing: 6) {
                        if module.isCaptureInFlight {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "text.viewfinder")
                        }
                        Text(module.isCapturing ? "Selecting region…" : module.isRecognizing ? "Recognizing…" : "Capture Region Now")
                    }
                }
                .buttonStyle(.toolboxProminent(.teal))
                .controlSize(.regular)
                .disabled(!appEnabled || module.isCaptureInFlight)
                .focusEffectDisabled()
                .help(appEnabled ? "Capture a screen region now" : "Resume Toolbox first to capture")
                .pointerCursor(appEnabled && !module.isCaptureInFlight)
            }

            Divider()

            SettingRow(
                "Global Capture Shortcut",
                subtitle: "Opens the crosshair region selector from anywhere. Release to copy; Esc cancels."
            ) {
                ShortcutRecorderView(
                    shortcut: configManager.config.screenOCR.shortcut,
                    defaultShortcut: ShortcutSpec(key: "0", modifiers: [.command, .shift]),
                    sourceID: "screen_ocr",
                    registrationKey: module.hotKeyName
                ) { newShortcut in
                    configManager.config.screenOCR.shortcut = newShortcut
                }
            }

            Divider()

            SettingRow(
                "Screen Recording Permission",
                subtitle: "macOS must allow Toolbox to capture your selected region. Recognition runs on-device."
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
        }
        .id(ModuleFocusAnchor.shortcuts.rawValue)
    }

    // MARK: - Recognition Options

    private var recognitionOptionsSection: some View {
        FeatureSection(
            "Recognition Options",
            subtitle: "Tune how Apple Vision reads selected regions."
        ) {
            SettingRow(
                "Preserve Line Breaks",
                subtitle: "Off joins wrapped lines with spaces instead of keeping newlines."
            ) {
                Toggle("", isOn: $configManager.config.screenOCR.preserveLineBreaks)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            Divider()

            SettingRow(
                "Detect QR & Barcodes",
                subtitle: "Decodes QR and barcode payloads in the same capture pass."
            ) {
                Toggle("", isOn: $configManager.config.screenOCR.detectQRCodes)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            Divider()

            SettingRow(
                "Show Toast Notification",
                subtitle: "Confirms each capture with a short status toast."
            ) {
                Toggle("", isOn: $configManager.config.screenOCR.showToast)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }
        }
    }

    // MARK: - Recent Captures (Session Only)

    private var recentCapturesSection: some View {
        FeatureSection(
            "Recent Captures",
            subtitle: "Session only: kept in memory for this Toolbox session and never written to disk."
        ) {
            if module.recentCaptures.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.viewfinder")
                        .toolboxFont(.title2)
                        .foregroundStyle(.secondary)
                    Text("No captures yet this session")
                        .toolboxFont(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    if !configManager.config.screenOCR.shortcut.isEmpty {
                        HStack(spacing: 6) {
                            Text("Press")
                                .toolboxFont(.caption)
                                .foregroundStyle(.secondary)
                            ShortcutPill(text: configManager.config.screenOCR.shortcut.displayString)
                            Text("or Capture Region Now to grab text or a QR code.")
                                .toolboxFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Use Capture Region Now above to grab text or a QR code.")
                            .toolboxFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 8) {
                    ForEach(module.recentCaptures) { capture in
                        recentRow(capture)
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    Text("Text is processed locally by Apple Vision and the screenshot is deleted right after capture.")
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Clear Session", role: .destructive) {
                        module.clearRecentCaptures()
                    }
                    .buttonStyle(.toolboxDestructive)
                    .controlSize(.small)
                    .focusEffectDisabled()
                    .pointerCursor()
                }
            }
        }
    }

    private func recentRow(_ capture: RecentOCRCapture) -> some View {
        let accentText = ToolboxTheme.readableAccentText(for: module.accentColor)
        let canExpand = capture.lineCount > 2 || capture.text.count > 110
        let isExpanded = uiState.expandedCaptureID == capture.id
        let isCopied = uiState.copiedCaptureID == capture.id

        let rowContent = HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(module.accentColor.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: capture.isQR ? "qrcode" : "text.viewfinder")
                    .toolboxFont(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accentText)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(capture.text)
                    .toolboxFont(.caption.monospaced())
                    .lineLimit(isExpanded ? nil : 2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: isExpanded)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Text(capture.isQR ? "QR Code" : "\(capture.lineCount) \(capture.lineCount == 1 ? "line" : "lines")")
                        .toolboxFont(.caption2.weight(.semibold))
                        .foregroundStyle(accentText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(module.accentColor.opacity(0.14), in: Capsule())
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(capture.createdAt.formatted(.relative(presentation: .named)))
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                    if canExpand {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(isExpanded ? "Show less" : "Show more")
                            .toolboxFont(.caption2.weight(.medium))
                            .foregroundStyle(accentText)
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                module.copyRecent(capture)
                uiState.markCopied(capture.id)
            } label: {
                if isCopied {
                    Label("Copied", systemImage: "checkmark")
                } else {
                    Text("Copy")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .focusEffectDisabled()
            .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        )

        return Group {
            if canExpand {
                rowContent
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .menuRowHover(cornerRadius: 8)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            uiState.expandedCaptureID = isExpanded ? nil : capture.id
                        }
                    }
                    .pointerCursor()
            } else {
                rowContent
            }
        }
    }
}
