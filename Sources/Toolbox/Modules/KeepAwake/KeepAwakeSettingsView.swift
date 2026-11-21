import SwiftUI

@MainActor
private final class KeepAwakeSettingsDraft: ObservableObject {
    @Published var customMinutesText: String = ""
}

struct KeepAwakeSettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject var module: KeepAwakeModule
    @StateObject private var draft = KeepAwakeSettingsDraft()

    private let durations: [(minutes: Int, shortLabel: String)] = [
        (15, "15m"),
        (30, "30m"),
        (60, "1h"),
        (120, "2h"),
        (240, "4h"),
        (0, "∞")
    ]

    private var defaultDurationLabel: String {
        let mins = configManager.config.keepAwake.defaultDurationMinutes
        if mins == 0 { return "∞" }
        return mins >= 60 && mins % 60 == 0 ? "\(mins / 60)h" : "\(mins)m"
    }

    var body: some View {
        let appEnabled = configManager.config.general.appEnabled

        VStack(alignment: .leading, spacing: 22) {
            FeatureSection("Session Control", subtitle: "Start, stop, or pick a timed awake session.") {
                SettingRow(
                    module.isAwakeActive ? "Keep Awake is active" : "Sleep behavior is normal",
                    subtitle: activeSubtitle
                ) {
                    let canPress = module.isAwakeActive || appEnabled
                    Button(module.isAwakeActive ? "Allow Sleep" : "Keep Awake (\(defaultDurationLabel))") {
                        if !module.isAwakeActive && !configManager.config.keepAwake.enabled {
                            configManager.config.keepAwake.enabled = true
                        }
                        module.toggle()
                    }
                    .buttonStyle(.toolboxProminent(module.isAwakeActive ? .neutral : .orange))
                    .disabled(!canPress)
                    .help(canPress ? "Toggle Keep Awake session" : "Resume Toolbox first to start Keep Awake")
                    .pointerCursor(canPress)
                }

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        quickStartChips(enabled: appEnabled)
                        Spacer(minLength: 8)
                        customDurationControls(enabled: appEnabled)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        quickStartChips(enabled: appEnabled)
                        customDurationControls(enabled: appEnabled)
                    }
                }

                if module.isAwakeActive {
                    Divider()

                    if configManager.config.keepAwake.strategy == .powerAssertion {
                        HStack(spacing: 10) {
                            Label(
                                configManager.config.keepAwake.preventDisplaySleep
                                    ? "Power assertion active (System & Display sleep blocked)"
                                    : "Power assertion active (System sleep blocked)",
                                systemImage: "bolt.shield.fill"
                            )
                            Spacer(minLength: 0)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ToolboxTheme.readableAccentText(for: module.accentColor))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        HStack(spacing: 14) {
                            Label("Idle: \(module.currentIdleSeconds)s", systemImage: "cursorarrow")
                            if let next = module.nextJiggleInSeconds {
                                Label("Next nudge in \(formattedCountdown(next))", systemImage: "timer")
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
            }

            FeatureCardGridSection("Keep Awake Strategy", subtitle: "Choose how Toolbox keeps your Mac awake.") {
                ToolboxAdaptiveCardGrid(wideColumns: 3, narrowColumns: 1, wideMinWidth: 560, spacing: 12) {
                    strategyCard(.both, title: "Both", subtitle: "Combines a native power assertion with subtle cursor nudges as a fallback.", symbolName: "bolt.shield.fill", badge: "Best")
                    strategyCard(.smartMouseJiggle, title: "Smart Mouse Jiggle", subtitle: "Sends a subtle 1px nudge right before display sleep. Works even under strict corporate policies.", symbolName: "cursorarrow.motionlines", badge: "Policy-Safe")
                    strategyCard(.powerAssertion, title: "Power Assertion", subtitle: "Holds a native macOS power assertion without moving your cursor.", symbolName: "battery.100.bolt", badge: "Zero Cursor")
                }
            }

            FeatureSection("Display Sleep & Timing", subtitle: "Reads your Mac power settings so nudges fire just before the screen turns off.") {
                SettingRow("Detected Display Sleep", subtitle: module.powerInfo.summaryText) {
                    Button("Refresh") {
                        module.refreshMacSleepSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusEffectDisabled()
                    .pointerCursor()
                }

                if configManager.config.keepAwake.strategy != .powerAssertion {
                    Divider()

                    SettingRow(
                        "Lead time before screen turns off",
                        subtitle: "How many seconds before macOS display sleep to send a tiny cursor nudge."
                    ) {
                        HStack(spacing: 8) {
                            Text("\(configManager.config.keepAwake.jiggleLeadSeconds)s before sleep")
                                .font(.callout.monospacedDigit())
                            Stepper("", value: $configManager.config.keepAwake.jiggleLeadSeconds, in: 5...300, step: 5)
                                .labelsHidden()
                                .pointerCursor()
                        }
                    }

                    Divider()

                    SettingRow(
                        "Fallback nudge interval",
                        subtitle: module.powerInfo.activeDisplaySleepMinutes == 0
                            ? "Used when macOS Display Sleep is set to Never (0)."
                            : "Used when macOS Display Sleep is set to Never (0). (Unused while Display Sleep is set.)"
                    ) {
                        HStack(spacing: 8) {
                            Text(formattedFallbackInterval(configManager.config.keepAwake.fallbackJiggleIntervalSeconds))
                                .font(.callout.monospacedDigit())
                            Stepper("", value: $configManager.config.keepAwake.fallbackJiggleIntervalSeconds, in: 15...600, step: 15)
                                .labelsHidden()
                                .pointerCursor()
                        }
                    }
                }
            }

            FeatureSection("Shortcut & Defaults") {
                SettingRow("Toggle shortcut") {
                    ShortcutRecorderView(
                        shortcut: configManager.config.keepAwake.shortcut,
                        defaultShortcut: ShortcutSpec(key: "k", modifiers: [.command, .option]),
                        sourceID: "keep_awake",
                        registrationKey: "keep_awake.toggle"
                    ) { newShortcut in
                        configManager.config.keepAwake.shortcut = newShortcut
                    }
                }

                Divider()

                SettingRow("Default duration", subtitle: "Duration used when toggling Keep Awake from the shortcut or menu bar.") {
                    HStack(spacing: 6) {
                        ForEach(durations, id: \.minutes) { option in
                            ToolboxPresetChip(
                                label: option.shortLabel,
                                isSelected: configManager.config.keepAwake.defaultDurationMinutes == option.minutes,
                                accentColor: module.accentColor
                            ) {
                                configManager.config.keepAwake.defaultDurationMinutes = option.minutes
                            }
                        }
                    }
                }

                if configManager.config.keepAwake.strategy != .smartMouseJiggle {
                    Divider()

                    SettingRow("Also prevent display sleep", subtitle: "Keeps your screen from dimming or turning off while Keep Awake is active.") {
                        Toggle("", isOn: $configManager.config.keepAwake.preventDisplaySleep)
                            .labelsHidden()
                            .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                            .pointerCursor()
                    }
                }

                Divider()

                SettingRow("Activate when Toolbox launches") {
                    Toggle("", isOn: $configManager.config.keepAwake.activeOnLaunch)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                }
            }
        }
    }

    private func strategyCard(
        _ strategy: KeepAwakeStrategy,
        title: String,
        subtitle: String,
        symbolName: String,
        badge: String
    ) -> some View {
        SelectableOptionCard(
            title: title,
            subtitle: subtitle,
            symbolName: symbolName,
            accentColor: module.accentColor,
            badge: badge,
            isSelected: configManager.config.keepAwake.strategy == strategy
        ) {
            configManager.config.keepAwake.strategy = strategy
        }
    }

    private func quickStartChips(enabled appEnabled: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Quick Start:")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach([15, 30, 60, 0], id: \.self) { mins in
                ToolboxPresetChip(
                    label: mins == 0 ? "∞" : (mins == 60 ? "1h" : "\(mins)m"),
                    isSelected: module.isAwakeActive && module.activePresetMinutes == mins,
                    accentColor: module.accentColor
                ) {
                    guard appEnabled else { return }
                    if !configManager.config.keepAwake.enabled {
                        configManager.config.keepAwake.enabled = true
                    }
                    module.activate(minutes: mins)
                }
                .disabled(!appEnabled)
                .opacity(appEnabled ? 1.0 : 0.5)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func customDurationControls(enabled appEnabled: Bool) -> some View {
        let canStartCustom = appEnabled && (Int(draft.customMinutesText) ?? 0) > 0
        return HStack(spacing: 5) {
            TextField("Min", text: $draft.customMinutesText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .font(.caption.monospacedDigit())
                .frame(width: 50)
                .help("Enter custom duration (1–1440m)")
                .onChange(of: draft.customMinutesText, initial: false) { _, val in
                    let digits = val.filter(\.isNumber)
                    if let parsed = Int(digits), parsed > 1440 {
                        draft.customMinutesText = "1440"
                    } else if digits != val {
                        draft.customMinutesText = digits
                    }
                }
                .onSubmit {
                    if canStartCustom {
                        startCustomDuration()
                    }
                }
            Text("min")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Start") {
                startCustomDuration()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .focusEffectDisabled()
            .disabled(!canStartCustom)
            .help("Start custom Keep Awake timer (1–1440 min)")
            .pointerCursor(canStartCustom)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var activeSubtitle: String {
        if !configManager.config.general.appEnabled && !module.isAwakeActive {
            return "Resume Toolbox in the top bar before starting Keep Awake."
        }
        guard module.isAwakeActive else {
            return "Turn on anytime to block idle sleep."
        }
        if let expiresAt = module.expiresAt {
            let mins = max(1, Int(ceil(expiresAt.timeIntervalSinceNow / 60)))
            return "Active (\(mins)m remaining) · Your Mac will stay awake according to your chosen strategy."
        }
        return "Active indefinitely (∞) · Your Mac will stay awake according to your chosen strategy."
    }

    private func formattedCountdown(_ totalSeconds: Int) -> String {
        if totalSeconds >= 60 {
            return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
        }
        return "\(totalSeconds)s"
    }

    private func formattedFallbackInterval(_ seconds: Int) -> String {
        if seconds >= 60 {
            let mins = seconds / 60
            let rem = seconds % 60
            return rem == 0 ? "Every \(mins)m" : "Every \(mins)m \(rem)s"
        }
        return "Every \(seconds)s"
    }

    private func startCustomDuration() {
        guard configManager.config.general.appEnabled else { return }
        if let mins = Int(draft.customMinutesText), mins > 0 {
            let clamped = min(mins, 1440)
            draft.customMinutesText = String(clamped)
            if !configManager.config.keepAwake.enabled {
                configManager.config.keepAwake.enabled = true
            }
            module.activate(minutes: clamped)
        }
    }
}
