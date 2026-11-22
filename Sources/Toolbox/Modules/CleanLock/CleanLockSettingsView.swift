import SwiftUI

struct CleanLockSettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject var module: CleanLockModule

    private let durationPresets: [(Int, String)] = [
        (15, "15s"),
        (30, "30s"),
        (60, "1m"),
        (120, "2m"),
        (180, "3m"),
        (300, "5m")
    ]

    private var clampedDurationSeconds: Int {
        CleanLockConfig.clampedDuration(configManager.config.cleanLock.durationSeconds)
    }

    private var hasCustomDuration: Bool {
        !durationPresets.contains(where: { $0.0 == clampedDurationSeconds })
    }

    private var canStartLock: Bool {
        configManager.config.general.appEnabled && permissions.isAccessibilityGranted
    }

    private var formattedDurationLabel: String {
        let secs = clampedDurationSeconds
        return secs >= 60 && secs % 60 == 0 ? "\(secs / 60)m" : "\(secs)s"
    }

    private var formattedDurationButtonLabel: String {
        if module.isLocked {
            return "Unlock Now (\(module.remainingSeconds)s)"
        }
        return configManager.config.cleanLock.lockMouseAndTrackpad
            ? "Lock Input (\(formattedDurationLabel))"
            : "Lock Keyboard (\(formattedDurationLabel))"
    }

    private var lockActionSubtitle: String {
        if module.isLocked {
            return "Hold ⌃ ⌥ ⌘ Esc for 3s to unlock early, or wait for the countdown."
        }
        if !configManager.config.general.appEnabled {
            return "Resume Toolbox in the top bar before starting a lock session."
        }
        if !permissions.isAccessibilityGranted {
            return "Grant Accessibility permission above to enable Keyboard Lock."
        }
        return "Displays a large center-screen countdown and blocks accidental keypresses while dusting."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            FeatureSection(
                "Lock Controls",
                subtitle: "Choose a duration and start a timed keyboard & trackpad lock."
            ) {
                SettingRow(
                    module.isLocked ? "Keyboard Lock is active" : "Ready to lock input",
                    subtitle: lockActionSubtitle
                ) {
                    let isActionAllowed = module.isLocked || canStartLock
                    Button {
                        if module.isLocked {
                            module.unlock(reason: .killSwitchHeld)
                        } else {
                            _ = module.lock()
                        }
                    } label: {
                        Label(
                            formattedDurationButtonLabel,
                            systemImage: module.isLocked ? "lock.open.fill" : "lock.fill"
                        )
                        .toolboxFont(.callout.weight(.semibold))
                    }
                    .buttonStyle(.toolboxProminent(.red))
                    .controlSize(.large)
                    .disabled(!isActionAllowed)
                    .help(
                        isActionAllowed
                            ? "Start or end the cleaning lock session"
                            : (!configManager.config.general.appEnabled
                                ? "Resume Toolbox first to use Keyboard Lock"
                                : "Grant Accessibility permission first to use Keyboard Lock")
                    )
                    .pointerCursor(isActionAllowed)
                }

                Divider()

                SettingRow(
                    "Lock duration",
                    subtitle: "Bounded timer (10s to 5m) so input always restores automatically."
                ) {
                    HStack(spacing: 6) {
                        ForEach(durationPresets, id: \.0) { seconds, label in
                            let isSelected = clampedDurationSeconds == seconds
                            ToolboxPresetChip(
                                label: label,
                                isSelected: isSelected,
                                accentColor: module.accentColor
                            ) {
                                configManager.config.cleanLock.durationSeconds = seconds
                            }
                        }
                        if hasCustomDuration {
                            ToolboxPresetChip(
                                label: formattedDurationLabel,
                                isSelected: true,
                                accentColor: module.accentColor
                            ) {}
                        }
                    }
                }

                Divider()

                SettingRow(
                    "Also lock mouse & trackpad clicks",
                    subtitle: "Blocks clicks and scrolling while keeping the cursor visible."
                ) {
                    Toggle("", isOn: $configManager.config.cleanLock.lockMouseAndTrackpad)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                }
            }

            FeatureCardGridSection(
                "How Release Works",
                subtitle: "Multiple independent safety layers ensure you can never get trapped."
            ) {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        InfoFeatureCard(
                            title: "Auto Countdown",
                            subtitle: "Restores full keyboard and trackpad input automatically at 0.",
                            symbolName: "timer",
                            accentColor: .red
                        )

                        InfoFeatureCard(
                            title: "Emergency Kill Switch",
                            subtitle: "Hold continuously for 3 seconds to unlock early.",
                            symbolName: "key.fill",
                            accentColor: .orange
                        ) {
                            ShortcutPill(tokens: ["⌃", "⌥", "⌘", "Esc"])
                        }

                        InfoFeatureCard(
                            title: "OS & Hardware Safety",
                            subtitle: "Touch ID, Lock Screen (⌃ ⌘ Q), or quitting Toolbox unlocks input immediately.",
                            symbolName: "checkmark.shield.fill",
                            accentColor: .blue
                        )
                    }
                }
            }
        }
    }
}
