import AppKit
import SwiftUI

/// Dedicated Developer Tools section for Screen OCR: environment inspection, a
/// stage-by-stage live capture pipeline test (the thing that actually runs when the
/// hotkey fires), the offline recognition self-check, and OCR event history.
struct DeveloperScreenOCRView: View {
    @ObservedObject private var module = ModuleRegistry.shared.screenOCR
    @ObservedObject private var configManager = ConfigManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            environmentSection
            pipelineTestSection
            failedCaptureSection
            selfCheckSection
        }
        .onAppear {
            module.refreshScreenPermission()
        }
    }

    // MARK: - Failed Capture Evidence

    private var failedCaptureSection: some View {
        FeatureSection(
            "LAST CAPTURE (KEPT ON FAILURE)",
            subtitle: "When a production capture comes back empty, the file is kept — never deleted — so you can inspect exactly what the system returned."
        ) {
            VStack(spacing: 10) {
                if let path = module.lastFailedCapturePath {
                    HStack(spacing: 8) {
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()
                        Button(module.isReanalyzing ? "Analyzing…" : "Re-analyze") {
                            module.reanalyzeFailedCapture()
                        }
                        .buttonStyle(.toolboxProminent)
                        .controlSize(.small)
                        .disabled(module.isReanalyzing || module.isRecognizing)
                        .pointerCursor(!(module.isReanalyzing || module.isRecognizing))
                    }

                    if let note = module.lastFailedCaptureNote {
                        Text(note)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("No failed capture retained yet. When the hotkey flow fails, its file appears here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Environment

    private var environmentSection: some View {
        let tempDir = FileManager.default.temporaryDirectory
        return FeatureSection(
            "ENVIRONMENT & PERMISSION",
            subtitle: "The exact prerequisites the live capture needs. A \"not granted\" permission means macOS renders other apps' content black."
        ) {
            VStack(spacing: 0) {
                SettingRow(
                    "Screen Recording",
                    subtitle: "Required for Toolbox to read the selected region."
                ) {
                    HStack(spacing: 8) {
                        StatusBadge(
                            text: module.screenRecordingGranted ? "Granted" : "Not Granted",
                            color: module.screenRecordingGranted ? .green : .orange
                        )
                        Button("Request Access") { module.requestScreenAccess() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(module.screenRecordingGranted)
                            .focusEffectDisabled()
                            .pointerCursor(!module.screenRecordingGranted)
                        Button("Open Settings") { module.openScreenSettings() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .focusEffectDisabled()
                            .pointerCursor()
                    }
                }

                Divider()

                SettingRow(
                    "Temp Directory",
                    subtitle: "Where capture files land. The child screencapture process must be able to write it."
                ) {
                    Text(tempDir.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Divider()

                SettingRow(
                    "Capture Binary",
                    subtitle: "Apple's signed screencapture; macOS attributes its Screen Recording permission to Toolbox."
                ) {
                    Text("/usr/sbin/screencapture · \(FileManager.default.fileExists(atPath: "/usr/sbin/screencapture") ? "present" : "MISSING")")
                        .font(.caption.monospaced())
                        .foregroundStyle(FileManager.default.fileExists(atPath: "/usr/sbin/screencapture") ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                }

                Divider()

                SettingRow(
                    "Recognition Settings",
                    subtitle: "What the pipeline will use (live from your Screen OCR settings)."
                ) {
                    Text("Accurate · QR \(module.config.detectQRCodes ? "on" : "off") · line breaks \(module.config.preserveLineBreaks ? "on" : "off") · toast \(module.config.showToast ? "on" : "off") · shortcut \(module.config.shortcut.isEmpty ? "unbound" : module.config.shortcut.displayString)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Live Pipeline Test

    private var pipelineTestSection: some View {
        FeatureSection(
            "LIVE CAPTURE PIPELINE TEST",
            subtitle: "Runs the real capture → decode → Vision pipeline stage by stage and shows exactly where it breaks. The captured file is kept for inspection."
        ) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    let isInteractiveRunning = module.isRunningPipelineTest && module.pipelineReport?.kind == .interactive
                    let isFullScreenRunning = module.isRunningPipelineTest && module.pipelineReport?.kind == .fullScreen

                    Button(isInteractiveRunning ? "Capturing…" : "Interactive Region Test") {
                        module.runPipelineTest(interactive: true)
                    }
                    .buttonStyle(.toolboxProminent)
                    .controlSize(.small)
                    .disabled(module.isRunningPipelineTest || module.isCaptureInFlight)
                    .pointerCursor(!module.isRunningPipelineTest && !module.isCaptureInFlight)

                    Button(isFullScreenRunning ? "Capturing…" : "Full-Screen Control") {
                        module.runPipelineTest(interactive: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(module.isRunningPipelineTest || module.isCaptureInFlight)
                    .pointerCursor(!module.isRunningPipelineTest && !module.isCaptureInFlight)

                    if module.isRunningPipelineTest {
                        ProgressView().controlSize(.small)
                        Button("Cancel") {
                            module.cancelPipelineTest()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()
                    }

                    Spacer()

                    if let report = module.pipelineReport, report.isComplete {
                        StatusBadge(
                            text: report.hasFailure ? "Failed" : "Passed",
                            color: report.hasFailure ? .red : .green
                        )
                        Button("Clear") {
                            module.clearPipelineReport()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()
                    }
                }

                Text("Interactive = the exact hotkey flow (drag a box; Esc cancels). Full-Screen = non-interactive control run. If the control passes but interactive fails, the difference is in the region file itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if module.isRunningPipelineTest {
                    Text(
                        module.pipelineReport?.kind == .interactive
                            ? "Wait for the crosshair, then drag a region over text you expect to be recognized."
                            : "Capturing full main screen…"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
                }

                if let report = module.pipelineReport {
                    stageList(report)
                }
            }
        }
    }

    private func stageList(_ report: OCRPipelineReport) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(report.stages.enumerated()), id: \.element.id) { index, stage in
                if index > 0 { Divider() }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: stageSymbol(stage.status))
                        .font(.callout)
                        .foregroundStyle(stageColor(stage.status))
                        .frame(width: 18)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(index + 1). \(stage.name)")
                            .font(.callout.weight(.medium))
                        if let detail = stage.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }

            if let path = report.artifactPath {
                Divider()
                HStack(spacing: 8) {
                    Text("Artifact (kept for inspection):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }

            if let preview = report.outputPreview {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Output")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Button("Copy") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(preview, forType: .string)
                            HUDToast.shared.show(title: "Pipeline output copied", symbol: "doc.on.clipboard", tint: .blue)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .pointerCursor()
                    }
                    Text(preview)
                        .font(.caption.monospaced())
                        .lineLimit(5)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private func stageSymbol(_ status: OCRPipelineStage.Status) -> String {
        switch status {
        case .pending: return "circle.dashed"
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.octagon.fill"
        case .skipped: return "forward.end.alt"
        }
    }

    private func stageColor(_ status: OCRPipelineStage.Status) -> Color {
        switch status {
        case .pending: return .secondary
        case .pass: return .green
        case .fail: return .red
        case .skipped: return .secondary
        }
    }

    // MARK: - Offline Self-Check

    private var selfCheckSection: some View {
        let lastCheck = module.lastSelfCheck
        return FeatureSection(
            "OFFLINE RECOGNITION SELF-CHECK",
            subtitle: "Synthetic sample (3 text lines + a real QR code) through the same engine path — no permission or crosshair involved."
        ) {
            VStack(spacing: 0) {
                SettingRow(
                    "Run OCR Self-Check",
                    subtitle: "Uses accurate recognition (QR \(module.config.detectQRCodes ? "on" : "off"))."
                ) {
                    HStack(spacing: 8) {
                        if module.isRunningSelfCheck {
                            ProgressView().controlSize(.small)
                        }
                        Button(module.isRunningSelfCheck ? "Running…" : "Run OCR Self-Check") {
                            module.runSelfCheck()
                        }
                        .buttonStyle(.toolboxProminent)
                        .controlSize(.small)
                        .disabled(module.isRunningSelfCheck || module.isCaptureInFlight)
                        .pointerCursor(!module.isRunningSelfCheck && !module.isCaptureInFlight)

                        Button("Live Region Capture") {
                            module.captureRegion()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(module.isCaptureInFlight)
                        .pointerCursor(!module.isCaptureInFlight)
                    }
                }

                if let check = lastCheck {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            StatusBadge(
                                text: check.isEmpty ? "No Output" : "Pipeline OK",
                                color: check.isEmpty ? .orange : .green
                            )
                            Text("\(check.lineCount) line(s) · \(check.qrPayloads.count) QR payload(s) · \(check.recognitionDurationMs) ms")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear") {
                                module.clearSelfCheckResults()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointerCursor()
                        }

                        Text(check.recognizedText.isEmpty ? "(no text recognized)" : check.recognizedText)
                            .font(.caption.monospaced())
                            .foregroundStyle(check.recognizedText.isEmpty ? Color.secondary : Color.primary)
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .textSelection(.enabled)

                        if !check.qrPayloads.isEmpty {
                            Text("QR: " + check.qrPayloads.joined(separator: ", "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                }
            }
        }
    }
}
