import AppKit
import SwiftUI

@MainActor
private final class DeveloperToolsUIState: ObservableObject {
    @Published var selectedAnimatedResult: UpdateSimulationPreset = .updateAvailable
    @Published var selectedToastPreset: ToastPreviewPreset = .success
    @Published var isDesignatedRequirementExpanded = false
}

struct DeveloperToolsView: View {
    let section: DeveloperSection

    @ObservedObject private var developerMode = DeveloperModeManager.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var registry = ModuleRegistry.shared
    @ObservedObject private var hotKeys = HotKeyManager.shared
    @ObservedObject private var healthChecks = DeveloperHealthCheckRunner.shared
    @StateObject private var uiState = DeveloperToolsUIState()

    private var diagnostics: RuntimeDiagnosticsSnapshot {
        _ = registry.revision
        _ = hotKeys.registrationErrors
        _ = permissions.isAccessibilityGranted
        _ = updateManager.isSparkleAvailable
        return RuntimeDiagnosticsSnapshot.capture()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard

                switch section {
                case .updates:
                    updateSimulationSection
                    updateDialogSection
                    backgroundScheduleSection
                    liveAppcastProbeSection
                case .uiAndModules:
                    uiFeedbackSection
                    moduleInspectorSection
                case .screenOCR:
                    DeveloperScreenOCRView()
                case .callControls:
                    DeveloperCallControlsView()
                case .eventsAndTaps:
                    DeveloperEventsAndTapsView()
                case .hotKeysAndConfig:
                    DeveloperHotKeysAndConfigView()
                case .checksAndDiagnostics:
                    healthChecksSection
                    signingAndPackagingSection
                    diagnosticsSection
                    securitySessionSection
                }
            }
            .padding(22)
        }
        .id(section)
        .onAppear {
            permissions.refresh()
            if section == .checksAndDiagnostics {
                healthChecks.runAllChecks()
            }
        }
    }

    // MARK: - Section Header

    private var headerCard: some View {
        SectionCard {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.purple.opacity(0.16))
                        .frame(width: 44, height: 44)
                    Image(systemName: section.symbolName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.purple)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(section.title)
                            .font(.title3.bold())
                        StatusBadge(
                            text: developerMode.hasActiveSimulation ? "Simulation Active" : "Developer",
                            color: developerMode.hasActiveSimulation ? .orange : .purple
                        )
                    }
                    Text(section.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    Button("Lock Now") {
                        developerMode.lock()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()

                    if developerMode.hasActiveSimulation {
                        Button("Reset Simulations") {
                            developerMode.resetAllSimulations()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                        .pointerCursor()
                    }
                }
            }
        }
    }

    // MARK: - Updates Section

    private var updateSimulationSection: some View {
        FeatureSection(
            "App-Wide Update State",
            subtitle: "Overrides UpdateManager in-memory so you can inspect how Settings, the top window banner, sidebar, and menu bar popover react."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                SettingRow(
                    "Simulated Release Metadata",
                    subtitle: "Version string and package size used when simulating an available update."
                ) {
                    HStack(spacing: 8) {
                        TextField("1.2.0", text: $developerMode.simulatedUpdateVersion)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .frame(width: 96)

                        Stepper(
                            value: $developerMode.simulatedUpdateSizeMB,
                            in: 0.5...50.0,
                            step: 0.5
                        ) {
                            Text(String(format: "%.1f MB", developerMode.simulatedUpdateSizeMB))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 54, alignment: .trailing)
                        }
                        .pointerCursor()
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Simulate State")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Button("View in Settings →") {
                            MainWindowController.shared.show(destination: .settings)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()

                        if updateManager.isSimulatingState {
                            Button("Restore Live State") {
                                updateManager.clearSimulation()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointerCursor()
                        }
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 132), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(UpdateSimulationPreset.allCases) { preset in
                            let isActive = updateManager.isSimulatingState && updateManager.activeSimulationPreset == preset
                            Button {
                                updateManager.applySimulationPreset(
                                    preset,
                                    version: developerMode.simulatedUpdateVersion,
                                    sizeBytes: developerMode.simulatedUpdateSizeBytes,
                                    errorMessage: developerMode.simulatedUpdateError
                                )
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(isActive ? Color.white : presetColor(preset))
                                        .frame(width: 6, height: 6)
                                    Text(preset.label)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .foregroundStyle(isActive ? Color.white : Color.primary)
                                .background(
                                    isActive ? Color.blue : Color.primary.opacity(0.055),
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(
                                            isActive ? Color.blue : Color.primary.opacity(0.10),
                                            lineWidth: 0.75
                                        )
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .pointerCursor()
                        }
                    }

                    Text(
                        updateManager.activeSimulationPreset?.summary
                            ?? "Live state active. Pick any preset above to preview how Settings, the top banner, and the menu bar popover render."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                // Embedded live preview of Settings' Software Updates card
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("SETTINGS CARD LIVE PREVIEW")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
                        Spacer()
                        StatusBadge(
                            text: updateManager.isSimulatingState ? "Simulated" : "Live",
                            color: updateManager.isSimulatingState ? .orange : .green
                        )
                    }

                    SoftwareUpdateStatusContent(showActionButton: false)
                }
                .padding(12)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )

                Divider()

                SettingRow(
                    "Animated Check Transition",
                    subtitle: "Watch the inline progress bar fill from 0% to 100% before settling into the chosen outcome."
                ) {
                    HStack(spacing: 8) {
                        Picker("", selection: $uiState.selectedAnimatedResult) {
                            Text("Update Available").tag(UpdateSimulationPreset.updateAvailable)
                            Text("Up to Date").tag(UpdateSimulationPreset.upToDate)
                            Text("Check Failed").tag(UpdateSimulationPreset.checkFailed)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .pointerCursor()

                        Button("Run Check") {
                            updateManager.runAnimatedSimulatedCheck(
                                result: uiState.selectedAnimatedResult,
                                version: developerMode.simulatedUpdateVersion,
                                sizeBytes: developerMode.simulatedUpdateSizeBytes,
                                errorMessage: developerMode.simulatedUpdateError
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .pointerCursor()
                    }
                }
            }
        }
    }

    private var updateDialogSection: some View {
        FeatureSection(
            "Update Dialog Window",
            subtitle: "Preview every stage of the custom dark Sparkle window. \"Update Available\" runs a full simulated install flow when clicked."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(
                    "Interactive Update Flow",
                    subtitle: "Opens the release-notes dialog. Clicking \"Update & Relaunch\" simulates download, verification, and restart safely."
                ) {
                    HStack(spacing: 8) {
                        Button("Dismiss Dialog") {
                            updateManager.dismissUpdateDialog()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()

                        Button("Open Update Dialog…") {
                            updateManager.presentUpdateDialogPreview(
                                .updateAvailable,
                                version: developerMode.simulatedUpdateVersion,
                                sizeBytes: developerMode.simulatedUpdateSizeBytes,
                                errorMessage: developerMode.simulatedUpdateError,
                                releaseNotesHTML: developerMode.effectiveReleaseNotes(for: developerMode.simulatedUpdateVersion)
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .pointerCursor()
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Jump to Specific Dialog State")
                        .font(.callout.weight(.medium))

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 132), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(UpdateDialogPreviewKind.allCases) { kind in
                            Button {
                                updateManager.presentUpdateDialogPreview(
                                    kind,
                                    version: developerMode.simulatedUpdateVersion,
                                    sizeBytes: developerMode.simulatedUpdateSizeBytes,
                                    errorMessage: developerMode.simulatedUpdateError,
                                    releaseNotesHTML: developerMode.effectiveReleaseNotes(for: developerMode.simulatedUpdateVersion)
                                )
                            } label: {
                                Text(kind.label)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7)
                                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .pointerCursor()
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    SettingRow(
                        "Release Notes Content",
                        subtitle: "Test standard, long scrollable, or custom HTML release notes inside the update dialog."
                    ) {
                        Picker("", selection: $developerMode.selectedReleaseNotesPreset) {
                            ForEach(ReleaseNotesPreset.allCases) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 175)
                        .pointerCursor()
                    }

                    if developerMode.selectedReleaseNotesPreset == .custom {
                        TextEditor(text: $developerMode.customReleaseNotesHTML)
                            .font(.caption.monospaced())
                            .frame(height: 92)
                            .padding(6)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                            )
                    }
                }

                Divider()

                SettingRow(
                    "Simulated Error Scenario",
                    subtitle: "Message shown by \"Check Failed\" and \"Update Error\" presets."
                ) {
                    Picker("", selection: $developerMode.selectedErrorPreset) {
                        ForEach(UpdateErrorPreset.allCases) { errPreset in
                            Text(errPreset.label).tag(errPreset)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .pointerCursor()
                }
            }
        }
    }

    private var backgroundScheduleSection: some View {
        let interval = Int(updateManager.scheduledCheckIntervalSeconds)
        let intervalLabel: String = {
            if interval < 60 { return "\(interval)s" }
            if interval % 3600 == 0 { return "\(interval / 3600)h" }
            if interval % 60 == 0 { return "\(interval / 60)m" }
            return "\(interval)s"
        }()

        return FeatureSection(
            "Background Check Schedule",
            subtitle: "Watch Sparkle's countdown live, shorten the polling interval without waiting an hour, and verify background check completions."
        ) {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                let nextText: String = {
                    guard updateManager.automaticallyChecksForUpdates else { return "Automatic checks disabled" }
                    guard let next = updateManager.nextScheduledCheckDate else { return "Pending first check" }
                    let remaining = next.timeIntervalSince(context.date)
                    if remaining <= 0 {
                        return updateManager.isUsingCustomScheduleInterval ? "Checking…" : "Due now"
                    }
                    let totalSecs = Int(ceil(remaining))
                    let mins = totalSecs / 60
                    let secs = totalSecs % 60
                    let countdown = mins > 0 ? "in \(mins)m \(secs)s" : "in \(secs)s"
                    return "\(next.formatted(date: .omitted, time: .shortened)) (\(countdown))"
                }()

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sparkle Auto-Check Cycle")
                                .font(.callout.weight(.medium))
                            Text("Last: \(updateManager.formattedLastChecked(relativeTo: context.date)) · Next: \(nextText)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        StatusBadge(
                            text: updateManager.isUsingCustomScheduleInterval
                                ? "Every \(intervalLabel) (Dev)"
                                : "Every \(intervalLabel)",
                            color: updateManager.isUsingCustomScheduleInterval ? .orange : (updateManager.automaticallyChecksForUpdates ? .green : .secondary)
                        )
                    }

                    // Live activity & outcome banner for scheduled/triggered background checks
                    HStack(spacing: 8) {
                        if updateManager.isBackgroundCheckActive {
                            ProgressView()
                                .controlSize(.small)
                            Text("Running background check…")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.blue)
                        } else if let bgAt = updateManager.lastBackgroundCheckAt,
                                  let outcome = updateManager.lastBackgroundCheckOutcome {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text("Last background check at \(bgAt.formatted(date: .omitted, time: .standard)): \(outcome)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "clock")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text("No background check observed yet this session. Schedule in 5s or click Run Background Check.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer(minLength: 8)

                        StatusBadge(
                            text: "\(updateManager.backgroundChecksCount) check\(updateManager.backgroundChecksCount == 1 ? "" : "s")",
                            color: updateManager.backgroundChecksCount > 0 ? .green : .secondary
                        )
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                    Divider()

                    SettingRow(
                        "Scheduled Check Test (5s)",
                        subtitle: "Counts down 5 seconds, runs Sparkle's background check once, then returns to the 1h default."
                    ) {
                        if updateManager.isUsingCustomScheduleInterval {
                            Button("Cancel") {
                                updateManager.setDeveloperScheduleInterval(nil)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointerCursor()
                        } else {
                            Button("Schedule in 5s") {
                                updateManager.setDeveloperScheduleInterval(5)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointerCursor()
                        }
                    }

                    Divider()

                    SettingRow(
                        "Run Background Check Now",
                        subtitle: "Calls SPUUpdater.checkForUpdatesInBackground() directly (silent unless a release is found)."
                    ) {
                        Button("Run Background Check") {
                            updateManager.triggerBackgroundUpdateCheck()
                            HUDToast.shared.show(
                                title: updateManager.isSparkleAvailable
                                    ? "Sparkle background check triggered"
                                    : "Sparkle requires running from Toolbox.app",
                                symbol: "arrow.clockwise.circle.fill",
                                tint: updateManager.isSparkleAvailable ? .blue : .orange
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .pointerCursor()
                    }
                }
            }
        }
    }

    private var liveAppcastProbeSection: some View {
        FeatureSection(
            "Live Appcast Feed Probe",
            subtitle: "Directly fetch SUFeedURL and parse release versions without mutating Sparkle or update UI state."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(
                    "Appcast Endpoint",
                    subtitle: (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? "Available when running from packaged Toolbox.app"
                ) {
                    Button(healthChecks.isProbingAppcast ? "Checking…" : "Ping Live Feed") {
                        Task {
                            await healthChecks.probeLiveAppcastFeed()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(healthChecks.isProbingAppcast)
                    .pointerCursor(!healthChecks.isProbingAppcast)
                }

                if let probe = healthChecks.appcastProbe {
                    Divider()

                    HStack(spacing: 10) {
                        StatusBadge(
                            text: probe.errorMessage == nil ? "HTTP \(probe.httpStatus ?? 200)" : "Error",
                            color: probe.errorMessage == nil ? .green : .orange
                        )

                        if let latest = probe.latestVersion {
                            Text("Latest feed version: v\(latest) (\(probe.itemCount) item\(probe.itemCount == 1 ? "" : "s"))")
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text(probe.isNewerThanCurrent ? "Newer than v\(updateManager.currentVersion)" : "Matches/older than v\(updateManager.currentVersion)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(probe.isNewerThanCurrent ? .blue : .secondary)
                        } else if let err = probe.errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    // MARK: - UI & Modules Section

    private var uiFeedbackSection: some View {
        FeatureSection(
            "UI States & Feedback",
            subtitle: "Test permission banners, HUD toasts, and floating module popovers."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(
                    "Accessibility Banner Override",
                    subtitle: "Overrides UI permission banners without altering macOS TCC trust or background event taps."
                ) {
                    Picker("", selection: Binding<Int>(
                        get: {
                            switch permissions.simulatedAccessibilityGranted {
                            case nil: return 0
                            case true: return 1
                            case false: return 2
                            }
                        },
                        set: { idx in
                            switch idx {
                            case 1: permissions.setSimulatedAccessibilityGranted(true)
                            case 2: permissions.setSimulatedAccessibilityGranted(false)
                            default: permissions.setSimulatedAccessibilityGranted(nil)
                            }
                        }
                    )) {
                        Text("Live (\(permissions.actualAccessibilityGranted ? "On" : "Off"))").tag(0)
                        Text("Force Granted").tag(1)
                        Text("Force Denied").tag(2)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    .pointerCursor()
                }

                Divider()

                SettingRow(
                    "First-Open Permission Prompt & Banner",
                    subtitle: "Preview the first-launch Accessibility explanation modal, inspect the Dashboard banner, or reset the seen flag."
                ) {
                    HStack(spacing: 8) {
                        Button("Preview Prompt") {
                            permissions.presentOnboardingModal()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .pointerCursor()

                        Button("Dashboard Banner") {
                            permissions.setSimulatedAccessibilityGranted(false)
                            MainWindowController.shared.show(destination: .dashboard)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()

                        Button("Reset Seen Flag") {
                            configManager.config.general.hasSeenAccessibilityOnboarding = false
                            HUDToast.shared.show(
                                title: "First-open permission prompt reset",
                                symbol: "arrow.counterclockwise",
                                tint: .blue
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!configManager.config.general.hasSeenAccessibilityOnboarding)
                        .pointerCursor(configManager.config.general.hasSeenAccessibilityOnboarding)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    SettingRow(
                        "HUD Toast Preview",
                        subtitle: "Triggers the floating top-center notification pill."
                    ) {
                        Picker("", selection: $uiState.selectedToastPreset) {
                            ForEach(ToastPreviewPreset.allCases) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 118)
                        .pointerCursor()
                    }

                    HStack(spacing: 8) {
                        TextField("Toast message", text: $developerMode.toastPreviewMessage)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout)

                        Button("Show Toast") {
                            let message = developerMode.toastPreviewMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                            HUDToast.shared.show(
                                title: message.isEmpty ? uiState.selectedToastPreset.defaultMessage : message,
                                symbol: uiState.selectedToastPreset.symbol,
                                tint: toastColor(uiState.selectedToastPreset)
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .pointerCursor()
                    }
                    .onChange(of: uiState.selectedToastPreset) { _, newPreset in
                        let current = developerMode.toastPreviewMessage
                        let isDefaultText = current.isEmpty
                            || current == "Simulated action completed"
                            || ToastPreviewPreset.allCases.contains(where: { $0.defaultMessage == current })
                        if isDefaultText {
                            developerMode.toastPreviewMessage = newPreset.defaultMessage
                        }
                    }
                }

                Divider()

                SettingRow(
                    "Quick Surface Triggers",
                    subtitle: "Open floating popovers, preview the floating call pill, or toggle master pause state."
                ) {
                    HStack(spacing: 8) {
                        Button("Clipboard") {
                            registry.clipboard.showPopover()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()

                        Button("Port Killer") {
                            registry.portKiller.showPopover()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()

                        Button(registry.callControls.isFloatingPillVisible ? "Hide Pill" : "Call Pill") {
                            if registry.callControls.developerSimulation != nil {
                                registry.callControls.clearDeveloperSimulation()
                            } else {
                                registry.callControls.applyDeveloperSimulationPreset(.zoomCall)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()

                        Button(configManager.config.general.appEnabled ? "Pause App" : "Resume App") {
                            configManager.config.general.appEnabled.toggle()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private var moduleInspectorSection: some View {
        FeatureSection(
            "Live Module Inspector",
            subtitle: "Inspect runtime state for each module and reload or jump to its settings."
        ) {
            VStack(spacing: 10) {
                ForEach(Array(registry.modules.enumerated()), id: \.element.id) { index, module in
                    if index > 0 {
                        Divider()
                    }
                    moduleInspectorRow(module)
                }
            }
        }
    }

    private func moduleInspectorRow(_ module: any ToolboxModule) -> some View {
        let isEnabled = module.isEnabled(in: configManager.config)
        let status = module.statusText(in: configManager.config, accessibilityGranted: permissions.actualAccessibilityGranted)

        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(module.accentColor.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: module.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(module.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(module.name)
                        .font(.callout.weight(.medium))
                    StatusBadge(
                        text: status,
                        color: module.isRunning ? .green : (isEnabled ? .orange : .secondary)
                    )
                }
                Text("id: \(module.id) · running: \(module.isRunning ? "true" : "false")")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let shortcut = module.shortcutText(in: configManager.config) {
                ShortcutPill(text: shortcut)
            }

            Button("Reload") {
                module.reload(with: configManager.config)
                HUDToast.shared.show(title: "Reloaded \(module.name)", symbol: "arrow.clockwise", tint: .blue)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursor()

            Button("Open") {
                MainWindowController.shared.show(destination: .module(module.id))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursor()
        }
    }

    // MARK: - Checks & Diagnostics Section

    private var healthChecksSection: some View {
        FeatureSection(
            "Preflight Health Checks",
            subtitle: "Non-destructive runtime verification of signing, Sparkle, config schema, hotkeys, and module lifecycles."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusBadge(text: "\(healthChecks.passCount) Passed", color: .green)
                    if healthChecks.warningCount > 0 {
                        StatusBadge(text: "\(healthChecks.warningCount) Warning\(healthChecks.warningCount == 1 ? "" : "s")", color: .orange)
                    }
                    if healthChecks.failCount > 0 {
                        StatusBadge(text: "\(healthChecks.failCount) Failed", color: .red)
                    }
                    Spacer()
                    Button("Re-run Checks") {
                        healthChecks.runAllChecks()
                        HUDToast.shared.show(
                            title: healthChecks.failCount == 0 ? "All critical checks passed" : "\(healthChecks.failCount) check(s) failed",
                            symbol: healthChecks.failCount == 0 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                            tint: healthChecks.failCount == 0 ? .green : .orange
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointerCursor()
                }

                Divider()

                ForEach(Array(healthChecks.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider()
                    }
                    healthCheckRow(item)
                }
            }
        }
    }

    private func healthCheckRow(_ item: HealthCheckItem) -> some View {
        let color = severityColor(item.severity)
        let symbol: String = {
            switch item.severity {
            case .pass: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .fail: return "xmark.octagon.fill"
            }
        }()

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(color)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                    Text(item.category.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }

                Text(item.summary)
                    .font(.caption)
                    .foregroundStyle(item.severity == .pass ? Color.secondary : color)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)
        }
    }

    private var signingAndPackagingSection: some View {
        let diag = diagnostics
        let signing = diag.signing
        let chainText = signing.authorityChain.isEmpty
            ? "Self-signed / None"
            : signing.authorityChain.joined(separator: " → ")
        let sparkleText: String = {
            if let fw = diag.sparkleFrameworkVersion {
                let helper = diag.hasUpdaterHelperApp ? "Updater.app OK" : "Updater.app missing"
                let key = diag.sparklePublicKeySummary ?? "No EdDSA key"
                return "v\(fw) · \(helper) · \(key)"
            }
            return diag.isBundledApp ? "Sparkle.framework missing" : "Unbundled (Sparkle inactive)"
        }()
        let quarantineText: String = {
            if diag.isAppTranslocated { return "App Translocated (Warning)" }
            if diag.hasQuarantineAttribute { return "Quarantined (com.apple.quarantine)" }
            return "Clean (no quarantine / translocation)"
        }()

        return FeatureSection(
            "Signing, Entitlements & Packaging",
            subtitle: "Deep macOS Security.framework inspection of the running binary, TCC requirement, Sparkle keys, and Gatekeeper status."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                diagnosticRow(
                    "Code Signature",
                    value: signing.summary,
                    valueColor: signing.isValid ? .secondary : .red
                )
                Divider()
                diagnosticRow("Authority Chain", value: chainText, allowWrap: true)
                Divider()
                HStack(alignment: .center, spacing: 12) {
                    Text("Hardened Runtime & Sandbox")
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 12)
                    StatusBadge(
                        text: signing.isHardenedRuntime ? "Hardened Runtime On" : "Hardened Runtime Off",
                        color: signing.isHardenedRuntime ? .green : .orange
                    )
                    StatusBadge(
                        text: signing.isSandboxed ? "Sandboxed" : "Unsandboxed",
                        color: .secondary
                    )
                }
                Divider()
                diagnosticRow(
                    "CDHash",
                    value: signing.cdHashHex ?? "(unavailable)",
                    monospaced: true
                )
                if let signedAt = signing.signedTimestamp {
                    Divider()
                    diagnosticRow(
                        "Signed Timestamp",
                        value: signedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                Divider()
                diagnosticRow(
                    "Quarantine & Translocation",
                    value: quarantineText,
                    valueColor: (diag.isAppTranslocated || diag.hasQuarantineAttribute) ? .orange : .secondary
                )
                Divider()
                diagnosticRow(
                    "Entitlements",
                    value: signing.entitlements.isEmpty
                        ? "None (unsandboxed direct distribution)"
                        : signing.entitlements.keys.sorted().map { "\($0)=\(signing.entitlements[$0] ?? "")" }.joined(separator: ", "),
                    monospaced: !signing.entitlements.isEmpty
                )
                Divider()
                diagnosticRow("Sparkle Binary & Key", value: sparkleText)
                if let dr = signing.designatedRequirement {
                    Divider()
                    DisclosureGroup(isExpanded: $uiState.isDesignatedRequirementExpanded) {
                        HStack(alignment: .top, spacing: 8) {
                            Text(dr)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button("Copy") {
                                copyToClipboard(dr, toast: "Designated requirement copied")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .pointerCursor()
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                        .padding(.top, 4)
                    } label: {
                        HStack {
                            Text("Designated Requirement (TCC Binding)")
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text(uiState.isDesignatedRequirementExpanded ? "Hide" : "Inspect")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .pointerCursor()
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    SettingRow(
                        "Gatekeeper & Notarization Check",
                        subtitle: "Runs spctl --assess asynchronously against the running bundle."
                    ) {
                        Button(healthChecks.isProbingGatekeeper ? "Checking…" : "Verify Gatekeeper") {
                            Task { await healthChecks.probeGatekeeperAssessment() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(healthChecks.isProbingGatekeeper)
                        .pointerCursor()
                    }

                    if let probe = healthChecks.gatekeeperProbe {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                StatusBadge(
                                    text: probe.accepted ? "Accepted" : "Rejected",
                                    color: probe.accepted ? .green : .orange
                                )
                                Text(probe.sourceLabel)
                                    .font(.caption.weight(.medium))
                                Spacer()
                                Text(probe.checkedAt.formatted(date: .omitted, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(probe.rawOutput)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    Button("Copy Signing Info") {
                        copyToClipboard(diag.formattedSigningReport(), toast: "Signing report copied to clipboard")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()

                    Button("Reveal App Bundle") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()

                    Spacer()
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        let diag = diagnostics
        let configSizeText = diag.configFileSizeBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "Unsaved"
        return FeatureSection(
            "Runtime, Architecture & Storage",
            subtitle: "Live process internals, login item registration, permission hooks, and config persistence."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                diagnosticRow(
                    "Version & Process",
                    value: "v\(diag.version) (build \(diag.buildNumber)) · PID \(diag.pid) · Up \(diag.formattedUptime)"
                )
                Divider()
                diagnosticRow(
                    "Architecture & OS",
                    value: "\(diag.architectureSummary) · \(diag.macOSVersion) · \(diag.physicalMemoryFormatted) RAM"
                )
                Divider()
                diagnosticRow(
                    "Bundle & Policy",
                    value: "\(diag.isBundledApp ? ".app Bundle" : "Raw Binary") · \(diag.activationPolicyLabel) · LSUIElement=\(diag.isLSUIElement ? "true" : "false") · Instances=\(diag.runningInstancesCount)",
                    allowWrap: true
                )
                Divider()
                diagnosticRow("Launch at Login (SMAppService)", value: diag.loginItemStatusLabel)
                Divider()
                diagnosticRow(
                    "Live Accessibility",
                    value: diag.actualAccessibilityGranted ? "Granted (AXIsProcessTrusted)" : "Not Granted",
                    valueColor: diag.actualAccessibilityGranted ? .secondary : .orange
                )
                Divider()
                diagnosticRow(
                    "Live Hooks & Buffers",
                    value: "Clipboard: \(diag.clipboardEntryCount) (\(diag.pinnedClipboardCount) pinned) · Scroll Tap: \(diag.scrollObservedCount) seen / \(diag.scrollInvertedCount) inverted · Commands: \(diag.customCommandsCount)",
                    allowWrap: true
                )
                Divider()
                diagnosticRow(
                    "HotKey Errors",
                    value: diag.hotkeyErrorCount == 0 ? "None" : "\(diag.hotkeyErrorCount) conflict(s)",
                    valueColor: diag.hotkeyErrorCount == 0 ? .secondary : .orange
                )
                Divider()
                diagnosticRow(
                    "Config Store",
                    value: "\(diag.configPath) (\(configSizeText)\(diag.isConfigIsolated ? " · Isolated" : ""))",
                    monospaced: true
                )
                Divider()
                diagnosticRow("Executable Path", value: diag.executablePath, monospaced: true)

                Divider()

                HStack(spacing: 8) {
                    Button("Copy Full Report") {
                        let checks = healthChecks.items.isEmpty ? healthChecks.runAllChecks() : healthChecks.items
                        copyToClipboard(
                            diag.formattedReport(healthChecks: checks),
                            toast: "Diagnostics report copied to clipboard"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointerCursor()

                    Button("Reveal Config Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([configManager.configURL])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()

                    Spacer()
                }
            }
        }
    }

    private func copyToClipboard(_ text: String, toast: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        HUDToast.shared.show(title: toast, symbol: "doc.on.doc.fill", tint: .blue)
    }

    private var securitySessionSection: some View {
        FeatureSection(
            "Security & Session",
            subtitle: "Control how Developer Tools unlocks and automatically resets."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(
                    "Keep unlocked across app launches",
                    subtitle: "When off, Developer Tools locks automatically on quit and requires the PIN again."
                ) {
                    Toggle("", isOn: $developerMode.stayUnlockedAcrossLaunches)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }

                Divider()

                SettingRow(
                    "Lock Developer Tools",
                    subtitle: "Clears all active simulations and hides Developer Tools behind the PIN gate."
                ) {
                    Button("Lock & Hide") {
                        developerMode.lock()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                }
            }
        }
    }

    private func diagnosticRow(
        _ label: String,
        value: String,
        monospaced: Bool = false,
        valueColor: Color = .secondary,
        allowWrap: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout.weight(.medium))
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(allowWrap ? nil : 1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: allowWrap)
                .textSelection(.enabled)
        }
    }

    private func severityColor(_ severity: HealthCheckSeverity) -> Color {
        switch severity {
        case .pass: return .green
        case .warning: return .orange
        case .fail: return .red
        }
    }

    private func presetColor(_ preset: UpdateSimulationPreset) -> Color {
        switch preset {
        case .upToDate: return .green
        case .checking: return .blue
        case .updateAvailable: return .blue
        case .checkFailed: return .orange
        case .neverChecked: return .secondary
        }
    }

    private func toastColor(_ preset: ToastPreviewPreset) -> Color {
        switch preset {
        case .success: return .green
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}
