import SwiftUI

struct CapsLockHyperKeySectionView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var hyperKey = ModuleRegistry.shared.hyperKey

    private var configBinding: Binding<HyperKeyConfig> {
        $configManager.config.hyperKey
    }

    private var missingAccessibility: Bool {
        !permissions.isAccessibilityGranted
    }

    private var missingInputMonitoring: Bool {
        !permissions.isInputMonitoringGranted
    }

    var body: some View {
        let isEnabled = configManager.config.hyperKey.enabled
        FeatureSection(
            "Caps Lock Hyper Key",
            subtitle: "Turn Caps Lock into a dual-role modifier key: hold for a chord, or tap quickly for Caps Lock or Escape."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(
                    "Enable Caps Lock Hyper Key",
                    subtitle: isEnabled
                        ? "Hold Caps Lock for \(configManager.config.hyperKey.holdMode.shortLabel); tap for \(configManager.config.hyperKey.tapAction.label)."
                        : "Off — Caps Lock behaves normally. Turn on to use Caps Lock + Key across Toolbox and other apps."
                ) {
                    Toggle("", isOn: configBinding.enabled)
                        .labelsHidden()
                        .toggleStyle(StatusBarSwitchToggleStyle(onColor: .indigo))
                        .pointerCursor()
                }

                if isEnabled {
                    Divider()

                    if missingAccessibility || missingInputMonitoring {
                        permissionsCheckBanner
                        Divider()
                    }

                    if let warning = hyperKey.externalCapsLockWarning {
                        externalWarningBanner(warning)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .toolboxFont(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("Keep System Settings → Keyboard → Modifier Keys → Caps Lock set to “Caps Lock” so macOS delivers raw key presses.")
                                .toolboxFont(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    SettingRow(
                        "Hold Caps Lock Acts As",
                        subtitle: "Toolbox Chord matches all default Toolbox shortcuts out of the box."
                    ) {
                        ToolboxSegmentedControl(
                            options: HyperKeyHoldMode.allCases,
                            selection: configBinding.holdMode,
                            accentColor: .indigo,
                            label: \.label
                        )
                    }

                    Divider()

                    SettingRow(
                        "Single Tap Caps Lock",
                        subtitle: "Action triggered when Caps Lock is pressed and released quickly without another key."
                    ) {
                        ToolboxSegmentedControl(
                            options: HyperKeyTapAction.allCases,
                            selection: configBinding.tapAction,
                            accentColor: .indigo,
                            label: \.label
                        )
                    }

                    if configManager.config.hyperKey.tapAction != .none {
                        Divider()

                        SettingRow(
                            "Tap Speed Threshold",
                            subtitle: "Presses shorter than \(configManager.config.hyperKey.tapThresholdMs) ms count as a tap."
                        ) {
                            HStack(spacing: 10) {
                                Slider(
                                    value: Binding(
                                        get: { Double(configManager.config.hyperKey.tapThresholdMs) },
                                        set: { configManager.config.hyperKey.tapThresholdMs = HyperKeyConfig.clampedTapThresholdMs(Int($0.rounded())) }
                                    ),
                                    in: Double(HyperKeyConfig.minTapThresholdMs)...Double(HyperKeyConfig.maxTapThresholdMs),
                                    step: 10
                                )
                                .frame(width: 150)
                                .pointerCursor()

                                Text("\(configManager.config.hyperKey.tapThresholdMs) ms")
                                    .toolboxFont(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 54, alignment: .trailing)
                            }
                        }
                    }

                    Divider()

                    liveKeyTesterStrip
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isEnabled)
    }

    private var permissionsCheckBanner: some View {
        let isWaiting = missingAccessibility
            ? permissions.isAwaitingAccessibilityGrant
            : permissions.isAwaitingInputMonitoringGrant
        let heading = missingAccessibility
            ? "Accessibility Permission Required"
            : "Input Monitoring Permission Required"
        let detail = missingAccessibility
            ? "Grant Accessibility permission so Caps Lock Hyper Key can remap Caps Lock and dispatch chords."
            : "macOS requires Input Monitoring permission on this system to remap Caps Lock in-process."

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .toolboxFont(.title3.weight(.semibold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(heading)
                            .toolboxFont(.callout.weight(.semibold))
                        if isWaiting {
                            StatusBadge(text: "Waiting…", color: .orange)
                        }
                    }
                    Text(detail)
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                if missingAccessibility {
                    if permissions.isAdHocSigned || permissions.hasAttemptedGrantWithoutSuccess {
                        Button(permissions.isResettingAccessibility ? "Resetting…" : "Reset Accessibility") {
                            permissions.resetAndRegrantAccessibility()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(permissions.isResettingAccessibility)
                        .pointerCursor(!permissions.isResettingAccessibility)
                    }
                    Button(permissions.isAwaitingAccessibilityGrant ? "Open Accessibility…" : "Grant Accessibility…") {
                        permissions.promptAndOpenSettings()
                    }
                    .buttonStyle(.toolboxProminent(.orange))
                    .controlSize(.small)
                    .pointerCursor()
                } else if missingInputMonitoring {
                    if permissions.isAdHocSigned || permissions.hasAttemptedInputMonitoringGrantWithoutSuccess {
                        Button(permissions.isResettingInputMonitoring ? "Resetting…" : "Reset Input Monitoring") {
                            permissions.resetAndRegrantInputMonitoring()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(permissions.isResettingInputMonitoring)
                        .pointerCursor(!permissions.isResettingInputMonitoring)
                    }
                    Button(permissions.isAwaitingInputMonitoringGrant ? "Open Input Monitoring…" : "Grant Input Monitoring…") {
                        permissions.requestInputMonitoringAccess()
                    }
                    .buttonStyle(.toolboxProminent(.orange))
                    .controlSize(.small)
                    .pointerCursor()
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.75)
        )
    }

    private func externalWarningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 1)
            Text(message)
                .toolboxFont(.caption)
                .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.75)
        )
    }

    private var liveKeyTesterStrip: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill((hyperKey.isRunning ? Color.indigo : Color.secondary).opacity(0.18))
                    .frame(width: 26, height: 26)
                Image(systemName: "waveform.path")
                    .toolboxFont(.caption.weight(.semibold))
                    .foregroundStyle(hyperKey.isRunning ? ToolboxTheme.readableAccentText(for: .indigo) : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Live Key Tester")
                    .toolboxFont(.caption.weight(.semibold))
                if let event = hyperKey.lastLiveEvent {
                    Text(event.summary)
                        .toolboxFont(.caption)
                        .foregroundStyle(ToolboxTheme.readableAccentText(for: .indigo))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("Press Caps Lock alone or Caps Lock + Key to see live tap/hold dispatch.")
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            StatusBadge(
                text: hyperKey.isRunning ? "Listening" : "Standby",
                color: hyperKey.isRunning ? .green : .secondary
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.75)
        )
    }
}

struct HyperKeyModuleSettingsView: View {
    @ObservedObject var module: HyperKeyModule

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CapsLockHyperKeySectionView()

            FeatureSection(
                "Keyboard Shortcuts Hub",
                subtitle: "Inspect, search, test, and rebind every Toolbox shortcut from a single command center."
            ) {
                SettingRow(
                    "All Feature Shortcuts",
                    subtitle: "Browse the visual key map, filter unassigned chords, and resolve collisions."
                ) {
                    Button {
                        MainWindowController.shared.navState.navigate(to: .shortcuts)
                    } label: {
                        Label("Open Keyboard Shortcuts", systemImage: "keyboard")
                    }
                    .buttonStyle(.toolboxProminent)
                    .pointerCursor()
                }
            }
        }
    }
}
