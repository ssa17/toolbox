import SwiftUI

/// Shared Software Updates status block used by both Settings & About and Developer Tools live preview.
struct SoftwareUpdateStatusContent: View {
    @ObservedObject private var updateManager = UpdateManager.shared

    var showActionButton: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                updateStatusIcon

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Toolbox")
                            .toolboxFont(.callout.weight(.semibold))

                        Text("v\(updateManager.currentVersion)")
                            .toolboxFont(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())

                        StatusBadge(text: updateBadgeText, color: updateBadgeColor)
                    }

                    Text(updateSubtitleText)
                        .toolboxFont(.caption)
                        .foregroundStyle(updateManager.lastCheckFailed && !updateManager.isChecking ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if showActionButton {
                    updateActionButton
                }
            }

            if updateManager.isChecking || updateManager.checkProgress > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.10))
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.blue, Color.cyan],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(12, proxy.size.width * min(1.0, max(0.06, updateManager.checkProgress))))
                                .animation(.easeOut(duration: 0.14), value: updateManager.checkProgress)
                        }
                    }
                    .frame(height: 6)

                    HStack {
                        Text("Checking for newer releases…")
                            .toolboxFont(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((min(1.0, updateManager.checkProgress) * 100).rounded()))%")
                            .toolboxFont(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }

            if let newVer = updateManager.pendingUpdateVersion, !updateManager.isChecking {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                        .toolboxFont(.title3)
                        .foregroundStyle(ToolboxTheme.accentBlue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("New update available: Toolbox v\(newVer)")
                            .toolboxFont(.callout.weight(.semibold))
                        Text(pendingUpdateDetailText(newVersion: newVer))
                            .toolboxFont(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            SupportLinks.open(SupportLinks.githubReleaseNotesURL(version: newVer))
                        } label: {
                            Text("View release notes on GitHub")
                                .toolboxFont(.caption2.weight(.semibold))
                                .foregroundStyle(ToolboxTheme.accentBlue)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .padding(.top, 2)
                    }

                    Spacer(minLength: 8)

                    Button("Update to v\(newVer)…") {
                        updateManager.openPendingUpdateOrCheck()
                    }
                    .buttonStyle(.toolboxProminent)
                    .pointerCursor()
                }
                .padding(11)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.blue.opacity(0.32), lineWidth: 1)
                )
            }
        }
    }

    private var updateStatusIcon: some View {
        let symbol: String
        let color: Color
        if updateManager.isChecking {
            symbol = "arrow.triangle.2.circlepath"
            color = ToolboxTheme.accentBlue
        } else if updateManager.pendingUpdateVersion != nil {
            symbol = "arrow.down.circle.fill"
            color = ToolboxTheme.accentBlue
        } else if updateManager.lastCheckFailed {
            symbol = "exclamationmark.triangle.fill"
            color = .orange
        } else {
            symbol = "checkmark.seal.fill"
            color = updateManager.lastCheckedAt != nil ? .green : .secondary
        }
        return ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(color.opacity(0.14))
                .frame(width: 34, height: 34)
            Image(systemName: symbol)
                .toolboxFont(.body.weight(.semibold))
                .foregroundStyle(ToolboxTheme.readableAccentText(for: color))
        }
    }

    private var updateBadgeText: String {
        if updateManager.isChecking {
            return "In Progress"
        }
        if let ver = updateManager.pendingUpdateVersion {
            return "v\(ver) Available"
        }
        if updateManager.lastCheckFailed {
            return "Check Failed"
        }
        if updateManager.lastCheckedAt != nil {
            return "Up to Date"
        }
        return updateManager.isSparkleAvailable ? "Automatic" : "Bundled App Only"
    }

    private var updateBadgeColor: Color {
        if updateManager.isChecking || updateManager.pendingUpdateVersion != nil {
            return .blue
        }
        if updateManager.lastCheckFailed {
            return .orange
        }
        if updateManager.lastCheckedAt != nil {
            return .green
        }
        return .secondary
    }

    private var updateSubtitleText: String {
        if updateManager.isChecking {
            return "Contacting GitHub Releases…"
        }
        if updateManager.lastCheckFailed, let err = updateManager.lastCheckError {
            if updateManager.lastCheckedAt != nil {
                return "\(err) · Last checked: \(updateManager.formattedLastChecked)"
            }
            return err
        }
        if updateManager.lastCheckedAt != nil {
            return "Last checked: \(updateManager.formattedLastChecked)"
        }
        return updateManager.isSparkleAvailable
            ? "Last checked: Never"
            : "Install from Toolbox.app to check GitHub Releases"
    }

    private func pendingUpdateDetailText(newVersion: String) -> String {
        let base = "Installed: v\(updateManager.currentVersion) → v\(newVersion)"
        if let size = updateManager.formattedPendingSize {
            return "\(base) · \(size)"
        }
        return base
    }

    @ViewBuilder
    private var updateActionButton: some View {
        if updateManager.isChecking {
            Button("Checking…") {}
                .buttonStyle(.bordered)
                .disabled(true)
        } else if updateManager.pendingUpdateVersion != nil {
            Button("Recheck") {
                updateManager.checkForUpdates()
            }
            .buttonStyle(.bordered)
            .disabled(!updateManager.isSparkleAvailable)
            .pointerCursor(updateManager.isSparkleAvailable)
        } else {
            Button("Check for Updates") {
                updateManager.checkForUpdates()
            }
            .buttonStyle(.bordered)
            .disabled(!updateManager.isSparkleAvailable)
            .pointerCursor(updateManager.isSparkleAvailable)
        }
    }
}
