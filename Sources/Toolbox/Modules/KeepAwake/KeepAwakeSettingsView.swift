import SwiftUI

@MainActor
private final class KeepAwakeSettingsDraft: ObservableObject {
    @Published var customMinutesText: String = "45"
}

struct KeepAwakeSettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var hotKeyManager = HotKeyManager.shared
    @ObservedObject var module: KeepAwakeModule
    @StateObject private var draft = KeepAwakeSettingsDraft()

    private let durations = [
        (0, "Indefinite"),
        (15, "15 minutes"),
        (30, "30 minutes"),
        (60, "1 hour"),
        (120, "2 hours"),
        (240, "4 hours")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            FeatureSection("Session Control", subtitle: "Start, stop, or pick a timed awake session.") {
                SettingRow(
                    module.isAwakeActive ? "Keep Awake is active" : "Sleep behavior is normal",
                    subtitle: activeSubtitle
                ) {
                    Button(module.isAwakeActive ? "Allow Sleep" : "Keep Awake Now") {
                        if !module.isAwakeActive && !configManager.config.keepAwake.enabled {
                            configManager.config.keepAwake.enabled = true
                        }
                        module.toggle()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(module.isAwakeActive ? .gray : .orange)
                    .pointerCursor()
                }

                Divider()

                HStack(spacing: 8) {
                    Text("Quick Start:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach([15, 30, 60, 0], id: \.self) { mins in
                        Button(mins == 0 ? "∞" : "\(mins)m") {
                            if !configManager.config.keepAwake.enabled {
                                configManager.config.keepAwake.enabled = true
                            }
                            module.activate(minutes: mins)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        TextField("45", text: $draft.customMinutesText)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            .font(.caption.monospacedDigit())
                            .frame(width: 48)
                            .onChange(of: draft.customMinutesText, initial: false) { _, val in
                                let digits = val.filter(\.isNumber)
                                if let parsed = Int(digits), parsed > 1440 {
                                    draft.customMinutesText = "1440"
                                } else if digits != val {
                                    draft.customMinutesText = digits
                                }
                            }
                            .onSubmit {
                                startCustomDuration()
                            }
                        Text("m")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Start") {
                            startCustomDuration()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled((Int(draft.customMinutesText) ?? 0) <= 0)
                        .pointerCursor((Int(draft.customMinutesText) ?? 0) > 0)
                    }
                }

                if module.isAwakeActive && configManager.config.keepAwake.strategy != .powerAssertion {
                    Divider()

                    HStack(spacing: 14) {
                        Label("Idle: \(module.currentIdleSeconds)s", systemImage: "cursorarrow")
                        if let next = module.nextJiggleInSeconds {
                            Label("Next nudge in \(next)s", systemImage: "timer")
                        }
                        Label("Nudges: \(module.jiggleCount)", systemImage: "arrow.left.and.right")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            FeatureSection("Mac Display Sleep Detection", subtitle: "Reads macOS pmset power settings so nudges fire just before sleep.") {
                SettingRow("Detected Display Sleep", subtitle: module.powerInfo.summaryText) {
                    Button("Refresh") {
                        module.refreshMacSleepSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                }

                Divider()

                SettingRow("Keep Awake Strategy") {
                    Picker("", selection: $configManager.config.keepAwake.strategy) {
                        ForEach(KeepAwakeStrategy.allCases, id: \.self) { strat in
                            Text(strat.label).tag(strat)
                        }
                    }
                    .labelsHidden()
                    .pointerCursor()
                }

                Text(strategyExplanation(configManager.config.keepAwake.strategy))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                if configManager.config.keepAwake.strategy != .powerAssertion {
                    Divider()

                    SettingRow(
                        "Lead time before screen turns off",
                        subtitle: "How many seconds before macOS display sleep to send a tiny cursor nudge."
                    ) {
                        Stepper(value: $configManager.config.keepAwake.jiggleLeadSeconds, in: 5...300, step: 5) {
                            Text("\(configManager.config.keepAwake.jiggleLeadSeconds)s before sleep")
                                .monospacedDigit()
                        }
                        .pointerCursor()
                    }

                    Divider()

                    SettingRow(
                        "Fallback nudge interval",
                        subtitle: "Used when macOS Display Sleep is set to Never (0)."
                    ) {
                        Stepper(value: $configManager.config.keepAwake.fallbackJiggleIntervalSeconds, in: 15...600, step: 15) {
                            Text("Every \(configManager.config.keepAwake.fallbackJiggleIntervalSeconds)s")
                                .monospacedDigit()
                        }
                        .pointerCursor()
                    }
                }
            }

            FeatureSection("Shortcut & Defaults") {
                SettingRow("Toggle shortcut") {
                    ShortcutRecorderView(shortcut: configManager.config.keepAwake.shortcut) { newShortcut in
                        configManager.config.keepAwake.shortcut = newShortcut
                    }
                }

                if let conflict = hotKeyManager.inAppConflictDescription(
                    for: configManager.config.keepAwake.shortcut,
                    excludingSourceID: "keep_awake",
                    in: configManager.config
                ) {
                    Label(conflict, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let err = hotKeyManager.registrationErrors["keep_awake.toggle"] {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Divider()

                SettingRow("Default duration") {
                    Picker("", selection: $configManager.config.keepAwake.defaultDurationMinutes) {
                        ForEach(durations, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .pointerCursor()
                }

                if configManager.config.keepAwake.strategy != .smartMouseJiggle {
                    Divider()

                    SettingRow("Also prevent display sleep", subtitle: "Hold an IOKit display sleep assertion in addition to system sleep.") {
                        Toggle("", isOn: $configManager.config.keepAwake.preventDisplaySleep)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .pointerCursor()
                    }
                }

                Divider()

                SettingRow("Activate when Toolbox launches") {
                    Toggle("", isOn: $configManager.config.keepAwake.activeOnLaunch)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }
            }
        }
    }

    private var activeSubtitle: String {
        guard module.isAwakeActive else {
            return "Turn on anytime to block idle sleep."
        }
        if let expiresAt = module.expiresAt {
            let mins = max(1, Int(ceil(expiresAt.timeIntervalSinceNow / 60)))
            return "Active (\(mins)m remaining) · Your Mac will stay awake according to your chosen strategy."
        }
        return "Active indefinitely (∞) · Your Mac will stay awake according to your chosen strategy."
    }

    private func startCustomDuration() {
        if let mins = Int(draft.customMinutesText), mins > 0 {
            let clamped = min(mins, 1440)
            draft.customMinutesText = String(clamped)
            if !configManager.config.keepAwake.enabled {
                configManager.config.keepAwake.enabled = true
            }
            module.activate(minutes: clamped)
        }
    }

    private func strategyExplanation(_ strategy: KeepAwakeStrategy) -> String {
        switch strategy {
        case .smartMouseJiggle:
            return "Sends a subtle 1px mouse nudge right before macOS would turn off the display. Works even when MDM or corporate policies override power assertions."
        case .powerAssertion:
            return "Holds a native IOKit caffeinate assertion without moving the cursor. Cleanest option on personal Macs."
        case .both:
            return "Combines a native IOKit power assertion with smart cursor nudges as a fallback."
        }
    }
}
