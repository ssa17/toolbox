import SwiftUI

struct CleanLockSettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject var module: CleanLockModule

    private let durationPresets: [(Int, String)] = [
        (15, "15s"),
        (30, "30s"),
        (60, "1m"),
        (120, "2m"),
        (180, "3m")
    ]

    private var formattedDurationButtonLabel: String {
        let secs = CleanLockConfig.clampedDuration(configManager.config.cleanLock.durationSeconds)
        let durationLabel = secs >= 60 && secs % 60 == 0 ? "\(secs / 60)m" : "\(secs)s"
        if module.isLocked {
            return "Locked (\(module.remainingSeconds)s)"
        }
        return configManager.config.cleanLock.lockMouseAndTrackpad
            ? "Lock Keyboard & Mouse (\(durationLabel))"
            : "Lock Keyboard (\(durationLabel))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            FeatureSection(
                "Lock Controls",
                subtitle: "Choose a duration and start a timed cleaning lock."
            ) {
                SettingRow(
                    module.isLocked ? "Cleaning Lock is active" : "Ready to lock input",
                    subtitle: module.isLocked
                        ? "Hold ⌃ ⌥ ⌘ Esc for 3s to unlock early, or wait for the countdown."
                        : "Displays a large center-screen countdown and blocks accidental keypresses."
                ) {
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
                        .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                    .pointerCursor()
                }

                Divider()

                SettingRow(
                    "Lock duration",
                    subtitle: "Bounded timer (15s – 3m) so input always restores automatically."
                ) {
                    HStack(spacing: 6) {
                        ForEach(durationPresets, id: \.0) { seconds, label in
                            let isSelected = CleanLockConfig.clampedDuration(configManager.config.cleanLock.durationSeconds) == seconds
                            Button {
                                configManager.config.cleanLock.durationSeconds = seconds
                            } label: {
                                Text(label)
                                    .font(.caption.monospacedDigit().weight(isSelected ? .semibold : .medium))
                                    .foregroundStyle(isSelected ? .white : .primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        isSelected ? Color.red : Color.primary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(
                                                isSelected ? Color.red.opacity(0.9) : Color.primary.opacity(0.1),
                                                lineWidth: 0.75
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                    }
                }

                Divider()

                SettingRow(
                    "Also lock mouse & trackpad clicks",
                    subtitle: "Swallows clicks and scrolling while keeping the cursor visible."
                ) {
                    Toggle("", isOn: $configManager.config.cleanLock.lockMouseAndTrackpad)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }
            }

            FeatureSection(
                "How Release Works",
                subtitle: "Multiple independent safety layers ensure you can never get trapped."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    releaseRow(
                        icon: "timer",
                        tint: .red,
                        title: "Automatic Countdown Release",
                        detail: "A large monospaced countdown appears in the center of your screen and automatically restores full keyboard and trackpad control at 0."
                    )

                    Divider()

                    releaseRow(
                        icon: "escape",
                        tint: .orange,
                        title: "Emergency Kill Switch: Hold ⌃ ⌥ ⌘ Esc (3s)",
                        detail: "Press and hold Control + Option + Command + Escape continuously for 3 seconds to unlock early. Quick taps or accidental cloth brushes reset immediately."
                    )

                    Divider()

                    releaseRow(
                        icon: "power",
                        tint: .secondary,
                        title: "Hardware & OS Safety Net",
                        detail: "macOS Power / Touch ID, Ctrl+Cmd+Q, and quitting Toolbox immediately tear down the input tap."
                    )
                }
            }
        }
    }

    private func releaseRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
