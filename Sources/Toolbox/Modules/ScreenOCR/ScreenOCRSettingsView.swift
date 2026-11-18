import AppKit
import SwiftUI

@MainActor
private final class ScreenOCRSettingsUIState: ObservableObject {
    @Published var permissionPollTask: Task<Void, Never>?
}

struct ScreenOCRSettingsView: View {
    @ObservedObject var module: ScreenOCRModule
    @ObservedObject private var configManager = ConfigManager.shared

    @StateObject private var uiState = ScreenOCRSettingsUIState()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
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
        FeatureSection(
            "CAPTURE & SHORTCUT",
            subtitle: "Grab text or QR codes from anywhere on screen with a single crosshair selection."
        ) {
            VStack(spacing: 0) {
                SettingRow(
                    "Global Capture Shortcut",
                    subtitle: "Opens the crosshair region selector. Release to copy; Esc cancels."
                ) {
                    HStack(spacing: 8) {
                        ShortcutRecorderView(
                            shortcut: configManager.config.screenOCR.shortcut,
                            defaultShortcut: ShortcutSpec(key: "0", modifiers: [.command, .shift]),
                            sourceID: "screen_ocr",
                            registrationKey: module.hotKeyName
                        ) { newShortcut in
                            configManager.config.screenOCR.shortcut = newShortcut
                        }

                        Button {
                            module.captureRegion()
                        } label: {
                            HStack(spacing: 5) {
                                if module.isCaptureInFlight {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(module.isCapturing ? "Selecting region..." : module.isRecognizing ? "Recognizing..." : "Capture Region Now")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(module.isCaptureInFlight)
                        .focusEffectDisabled()
                        .pointerCursor(!module.isCaptureInFlight)
                    }
                }

                Divider()

                SettingRow(
                    "Screen Recording Permission",
                    subtitle: "macOS must allow Toolbox to capture the region you select. Recognition runs on-device and never uploads anything."
                ) {
                    HStack(spacing: 8) {
                        StatusBadge(
                            text: module.screenRecordingGranted ? "Granted" : "Not Granted",
                            color: module.screenRecordingGranted ? .green : .orange
                        )

                        Button("Request Access") {
                            module.requestScreenAccess()
                        }
                        .buttonStyle(.bordered)
                        .disabled(module.screenRecordingGranted)
                        .focusEffectDisabled()
                        .pointerCursor(!module.screenRecordingGranted)

                        Button("Open Settings") {
                            module.openScreenSettings()
                        }
                        .buttonStyle(.bordered)
                        .focusEffectDisabled()
                        .pointerCursor()
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    // MARK: - Recognition Options

    private var recognitionOptionsSection: some View {
        FeatureSection(
            "RECOGNITION OPTIONS",
            subtitle: "Tune how Apple Vision reads the selected region."
        ) {
            VStack(spacing: 0) {
                SettingRow(
                    "Preserve Line Breaks",
                    subtitle: "Off joins wrapped paragraph lines with spaces instead of newlines."
                ) {
                    Toggle("", isOn: $configManager.config.screenOCR.preserveLineBreaks)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }

                Divider()

                SettingRow(
                    "Detect QR & Barcodes",
                    subtitle: "Decodes QR and barcode payloads in the same recognition pass."
                ) {
                    Toggle("", isOn: $configManager.config.screenOCR.detectQRCodes)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }

                Divider()

                SettingRow(
                    "Show Toast Notification",
                    subtitle: "Confirms each capture with a short status toast."
                ) {
                    Toggle("", isOn: $configManager.config.screenOCR.showToast)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }
            }
        }
    }

    // MARK: - Recent Captures (Session Only)

    private var recentCapturesSection: some View {
        FeatureSection(
            "RECENT CAPTURES",
            subtitle: "Session only: kept in memory for this Toolbox session and never written to disk."
        ) {
            VStack(spacing: 0) {
                if module.recentCaptures.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "text.viewfinder")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No captures yet this session")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("Press the shortcut or Capture Region Now to grab text or a QR code.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(module.recentCaptures.enumerated()), id: \.element.id) { idx, capture in
                            if idx > 0 {
                                Divider()
                            }
                            recentRow(capture)
                        }
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Text("Text is processed locally by Apple Vision and the screenshot is deleted right after capture.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button("Clear Session") {
                            module.clearRecentCaptures()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .focusEffectDisabled()
                        .pointerCursor()
                    }
                    .padding(12)
                }
            }
        }
    }

    private func recentRow(_ capture: RecentOCRCapture) -> some View {
        HStack(spacing: 10) {
            Image(systemName: capture.isQR ? "qrcode" : "text.viewfinder")
                .font(.body.weight(.medium))
                .foregroundStyle(module.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(capture.text)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)

                HStack(spacing: 5) {
                    Text(capture.isQR ? "QR code" : "\(capture.lineCount) \(capture.lineCount == 1 ? "line" : "lines")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(capture.createdAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Copy") {
                module.copyRecent(capture)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .focusEffectDisabled()
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
