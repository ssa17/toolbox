import AppKit
import SwiftUI

@MainActor
private final class DeveloperCallControlsUIState: ObservableObject {
    @Published var scannedBundleID: String = ""
    @Published var scannedAppName: String = ""
    @Published var inspectedControls: CallShortcutRemapper.InspectedAppControls?
    @Published var showAllScannedShortcuts = false
}

struct DeveloperCallControlsView: View {
    @ObservedObject private var callControls = ModuleRegistry.shared.callControls
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @StateObject private var uiState = DeveloperCallControlsUIState()
    @StateObject private var previewPillState = FloatingMicIndicatorState()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            pillPreviewSection
            simulationScenarioSection
            routingTesterSection
            axScannerProbeSection
            liveTelemetrySection
        }
        .onAppear {
            syncPreviewState()
            callControls.refreshAudioDevices()
            callControls.refreshMicStreamActivity()
            callControls.refreshCameraStatus()
            callControls.refreshRunningApplications()
        }
        .onChange(of: callControls.developerSimulation) { _, _ in syncPreviewState() }
        .onChange(of: callControls.isInputMuted) { _, _ in syncPreviewState() }
        .onChange(of: callControls.isTypingMuted) { _, _ in syncPreviewState() }
        .onChange(of: callControls.isCameraActive) { _, _ in syncPreviewState() }
        .onChange(of: configManager.config.callControls) { _, _ in syncPreviewState() }
    }

    // MARK: - 1. Interactive Pill Preview & Desktop Panel

    private var pillPreviewSection: some View {
        let isSimulating = callControls.developerSimulation != nil
        let showVideo = configManager.config.callControls.showVideoInFloatingIndicator

        return FeatureSection(
            "Floating Pill Preview & Stage",
            subtitle: "Live interactive preview mirroring either your active Call Simulation or real CoreAudio/Camera hardware. Click Mic or Video directly on the pill to test."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 10) {
                    HStack {
                        StatusBadge(
                            text: isSimulating ? "Simulated State" : "Live Hardware",
                            color: isSimulating ? .orange : .green
                        )

                        Spacer()

                        if let frame = callControls.floatingPillFrameSnapshot ?? callControls.floatingPillFrame,
                           callControls.isFloatingPillVisible {
                            Text("Desktop Pill: \(Int(frame.origin.x)), \(Int(frame.origin.y)) · \(Int(frame.width))×\(Int(frame.height))")
                                .toolboxFont(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Desktop Pill: Hidden")
                                .toolboxFont(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(nsColor: .windowBackgroundColor).opacity(0.95),
                                        Color.black.opacity(0.45)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                            )

                        FloatingMicIndicatorView(
                            state: previewPillState,
                            onToggleMute: {
                                if isSimulating {
                                    callControls.toggleSimulatedMicFromPill()
                                } else {
                                    callControls.toggleHardwareMicMute()
                                }
                            },
                            onToggleVideo: {
                                if isSimulating {
                                    callControls.triggerSimulatedAction(.video, fallbackToDefaultIfUnbound: true, respectSimulatedAccessibility: true)
                                } else {
                                    callControls.toggleCallVideo()
                                }
                            },
                            onToggleShowVideo: {
                                configManager.config.callControls.showVideoInFloatingIndicator.toggle()
                            },
                            onOpenSettings: {
                                MainWindowController.shared.show(destination: .module(callControls.id))
                            },
                            onResetPosition: {
                                callControls.resetFloatingPillPosition()
                            },
                            onHidePill: {
                                if isSimulating {
                                    callControls.developerSimulation?.pillVisibilityMode = .forceHide
                                } else {
                                    configManager.config.callControls.showFloatingMicIndicator = false
                                }
                            }
                        )
                        .padding(.vertical, 18)
                        .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity)
                }

                Divider()

                HStack(spacing: 8) {
                    if isSimulating {
                        Picker("", selection: simulationBinding(\.pillVisibilityMode, default: .forceShow)) {
                            ForEach(CallSimulationState.PillVisibilityMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 212)
                        .help("Force show/hide the desktop pill, or follow active call stream state")
                        .pointerCursor()
                    } else {
                        Button("Show Desktop Pill") {
                            callControls.applyDeveloperSimulationPreset(.zoomCall)
                        }
                        .buttonStyle(.toolboxProminent)
                        .controlSize(.small)
                        .pointerCursor()
                    }

                    Button(showVideo ? "Hide Cam in Pill" : "Show Cam in Pill") {
                        configManager.config.callControls.showVideoInFloatingIndicator.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()

                    Button("Reset Top-Right Corner") {
                        callControls.resetFloatingPillPosition()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()

                    Spacer()

                    if isSimulating {
                        Button("Exit Simulation") {
                            callControls.clearDeveloperSimulation()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.orange)
                        .pointerCursor()
                    }
                }
            }
        }
    }

    // MARK: - 2. Real App & Call Simulation Controls

    private var simulationScenarioSection: some View {
        let cfg = configManager.config.callControls
        let builtInIDs = Set(CallAppShortcutMapping.defaults.map(\.id))
        let customMappings = cfg.appShortcutMappings.filter { !builtInIDs.contains($0.id) }

        return FeatureSection(
            "Simulate Real Call Apps & States",
            subtitle: "Pick a one-click call scenario to test keybinds, scopes, device truncation, and the floating pill without changing saved settings."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("One-Click Scenarios")
                        .toolboxFont(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 138), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(CallSimulationState.Preset.allCases) { preset in
                            let expected = CallSimulationState.preset(preset)
                            let isSelected: Bool = {
                                guard let sim = callControls.developerSimulation else { return false }
                                if preset == .typingAutoMuted {
                                    return sim.isTypingMuted
                                }
                                return !sim.isTypingMuted && sim.targetAppID == expected.targetAppID
                            }()
                            scenarioChipButton(title: preset.label, isSelected: isSelected) {
                                callControls.applyDeveloperSimulationPreset(preset)
                            }
                        }

                        ForEach(customMappings) { mapping in
                            let isSelected: Bool = {
                                guard let sim = callControls.developerSimulation else { return false }
                                return !sim.isTypingMuted && sim.targetAppID == mapping.id
                            }()
                            scenarioChipButton(title: mapping.appName, isSelected: isSelected) {
                                callControls.applyDeveloperSimulation(for: mapping)
                            }
                        }
                    }
                }

                if let sim = callControls.developerSimulation {
                    let mappedTarget = callControls.simulatedTargetMapping(in: cfg)

                    if sim.targetAppID != "none" {
                        Divider()

                        SettingRow(
                            "App Window Placement",
                            subtitle: "Test Frontmost vs. Background relay when another app such as Xcode has focus."
                        ) {
                            Picker("", selection: simulationBinding(\.appPlacement, default: .frontmost)) {
                                ForEach(CallSimulationState.AppPlacement.allCases) { placement in
                                    Text(placement.label).tag(placement)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 270)
                            .pointerCursor()
                        }
                    }

                    if let reqTitle = mappedTarget?.requiredWindowTitleSubstring, !reqTitle.isEmpty {
                        Divider()

                        SettingRow(
                            "Browser Tab Context",
                            subtitle: "\(mappedTarget?.appName ?? "Browser call") only matches tabs containing \"\(reqTitle)\"."
                        ) {
                            let matchedTitle = "\(reqTitle) - Daily Standup"
                            let nonCallTitle = "GitHub - Pull Requests"
                            let isMatched = sim.customWindowTitle.localizedCaseInsensitiveContains(reqTitle)
                            Picker("", selection: Binding(
                                get: { isMatched ? matchedTitle : nonCallTitle },
                                set: { callControls.developerSimulation?.customWindowTitle = $0 }
                            )) {
                                Text("Matching (\(reqTitle))").tag(matchedTitle)
                                Text("Non-Call Tab").tag(nonCallTitle)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 245)
                            .pointerCursor()
                        }
                    }

                    Divider()

                    SettingRow(
                        "Simulated Override Scope",
                        subtitle: "Preview how Everywhere, Background, and Active App Only behave without editing your saved setting."
                    ) {
                        Picker("", selection: simulationBinding(\.simulatedScopeOverride, default: nil)) {
                            Text("Saved (\(shortScopeLabel(cfg.overrideScope)))").tag(CallOverrideScope?.none)
                            ForEach(CallOverrideScope.allCases, id: \.self) { scope in
                                Text(shortScopeLabel(scope)).tag(CallOverrideScope?.some(scope))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .pointerCursor()
                    }

                    Divider()

                    SettingRow(
                        "Audio & Camera Profile",
                        subtitle: "Switch between long device names, short headset names, and no-hardware fallback states."
                    ) {
                        Picker("", selection: simulationBinding(\.deviceProfile, default: .macBookPro)) {
                            ForEach(CallSimulationState.DeviceProfile.allCases) { profile in
                                Text(profile.label).tag(profile)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 290)
                        .pointerCursor()
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Simulated Hardware & Stream Flags")
                                .toolboxFont(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                callControls.simulateTypingBurst()
                            } label: {
                                Label("Test Typing Burst", systemImage: "keyboard")
                                    .toolboxFont(.caption.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Simulate a typing pause cycle using your Typing Restore Delay (\(cfg.typingUnmuteDelayMs) ms)")
                            .pointerCursor()
                        }

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 195), spacing: 10)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            Toggle("Mic Stream Active", isOn: simulationBinding(\.isMicStreamActive, default: false))
                                .toolboxFont(.caption)
                                .toggleStyle(.checkbox)
                                .disabled(!sim.hasInputDevice)
                                .pointerCursor(sim.hasInputDevice)

                            Toggle("Mic Muted", isOn: Binding(
                                get: { callControls.developerSimulation?.isMuted ?? false },
                                set: { newVal in
                                    callControls.developerSimulation?.isMuted = newVal
                                    if !newVal {
                                        callControls.developerSimulation?.isTypingMuted = false
                                    }
                                }
                            ))
                            .toolboxFont(.caption)
                            .toggleStyle(.checkbox)
                            .disabled(!sim.hasInputDevice)
                            .pointerCursor(sim.hasInputDevice)

                            Toggle("Typing Auto-Mute", isOn: Binding(
                                get: { callControls.developerSimulation?.isTypingMuted ?? false },
                                set: { newVal in
                                    callControls.developerSimulation?.isTypingMuted = newVal
                                    if newVal {
                                        callControls.developerSimulation?.isMuted = true
                                    }
                                }
                            ))
                            .toolboxFont(.caption)
                            .toggleStyle(.checkbox)
                            .disabled(!sim.hasInputDevice)
                            .pointerCursor(sim.hasInputDevice)

                            Toggle("Camera Live", isOn: simulationBinding(\.isCameraActive, default: false))
                                .toolboxFont(.caption)
                                .toggleStyle(.checkbox)
                                .disabled(!sim.hasCameraDevice)
                                .pointerCursor(sim.hasCameraDevice)

                            Toggle("Simulate Accessibility", isOn: simulationBinding(\.simulateAccessibilityGranted, default: true))
                                .toolboxFont(.caption)
                                .toggleStyle(.checkbox)
                                .pointerCursor()
                        }
                    }
                }
            }
        }
    }

    private func scenarioChipButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "play.circle")
                    .toolboxFont(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(title)
                    .toolboxFont(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                (isSelected ? Color.accentColor : Color.primary).opacity(isSelected ? 0.14 : 0.05),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        (isSelected ? Color.accentColor : Color.primary).opacity(isSelected ? 0.45 : 0.09),
                        lineWidth: 0.75
                    )
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerCursor()
    }

    private func shortScopeLabel(_ scope: CallOverrideScope) -> String {
        switch scope {
        case .everywhere: return "Everywhere"
        case .activeOrRunningBackground: return "Active / Bg"
        case .activeCallAppOnly: return "Active App Only"
        }
    }

    // MARK: - 3. Unified Keybind Routing Dry-Run & Trigger

    private var routingTesterSection: some View {
        let cfg = configManager.config.callControls
        let isSimulating = callControls.developerSimulation != nil

        return FeatureSection(
            "Keybind Routing Dry-Run & Action Tester",
            subtitle: "Inspect how CallShortcutRemapper routes your Mic & Video keybinds under the current simulation and trigger simulated actions with real HUD toasts."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if !isSimulating {
                    HStack(spacing: 10) {
                        Text("Start any scenario above to test Mic and Video keybind routing offline without affecting your real apps.")
                            .toolboxFont(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Load Zoom Scenario") {
                            callControls.applyDeveloperSimulationPreset(.zoomCall)
                        }
                        .buttonStyle(.toolboxProminent)
                        .controlSize(.small)
                        .pointerCursor()
                    }
                } else {
                    HStack(spacing: 8) {
                        if !permissions.actualAccessibilityGranted {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(.orange)
                            Text("Grant real Accessibility in System Settings to press physical keybinds during simulation (buttons & pill clicks work anytime).")
                                .toolboxFont(.caption)
                                .foregroundStyle(.orange)
                        } else if callControls.isRemapperTapInstalled {
                            Image(systemName: "keyboard.badge.eye")
                                .foregroundStyle(.green)
                            Text("Live keybind capture active: pressing your physical Mic / Video keybind now updates this simulation and the pill.")
                                .toolboxFont(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "keyboard")
                                .foregroundStyle(.secondary)
                            Text("Assign a Mic or Video shortcut in Call Controls to test physical keybind presses.")
                                .toolboxFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(
                        (!permissions.actualAccessibilityGranted ? Color.orange : Color.primary).opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 7)
                    )

                    Divider()

                    routingDecisionRow(
                        label: "Mic Keybind",
                        configuredShortcut: cfg.micShortcut,
                        action: .mic,
                        decision: callControls.simulatedRoutingDecision(for: .mic)
                    )

                    Divider()

                    routingDecisionRow(
                        label: "Video Keybind",
                        configuredShortcut: cfg.videoShortcut,
                        action: .video,
                        decision: callControls.simulatedRoutingDecision(for: .video)
                    )

                    if let outcome = callControls.lastSimulationOutcome {
                        Divider()
                        HStack(spacing: 8) {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .foregroundStyle(.blue)
                            Text("Last Action Result:")
                                .toolboxFont(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(outcome)
                                .toolboxFont(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func routingDecisionRow(
        label: String,
        configuredShortcut: ShortcutSpec,
        action: CallActionKind,
        decision: CallRemapDecision
    ) -> some View {
        let badge = decisionBadge(for: decision, action: action, configuredShortcut: configuredShortcut)

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(label)
                        .toolboxFont(.callout.weight(.medium))
                    if !configuredShortcut.isEmpty {
                        ShortcutPill(shortcut: configuredShortcut)
                    } else {
                        Text("Unbound")
                            .toolboxFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    StatusBadge(text: badge.title, color: badge.color)
                }

                Text(badge.detail)
                    .toolboxFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Simulate \(action.label)") {
                callControls.triggerSimulatedAction(
                    action,
                    fallbackToDefaultIfUnbound: true,
                    respectSimulatedAccessibility: true
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursor()
        }
    }

    private func decisionBadge(
        for decision: CallRemapDecision,
        action: CallActionKind,
        configuredShortcut: ShortcutSpec
    ) -> (title: String, color: Color, detail: String) {
        let cfg = configManager.config.callControls
        let sim = callControls.developerSimulation
        let effectiveScope = sim?.simulatedScopeOverride ?? cfg.overrideScope
        let mapped = callControls.simulatedTargetMapping(in: cfg)
        let simAccessibility = sim?.simulateAccessibilityGranted ?? true

        if action == .mic && sim?.hasInputDevice == false {
            return (
                "No Microphone",
                .orange,
                "Audio & Camera profile has no microphone connected — mic actions show unavailable feedback."
            )
        }

        if action == .video && sim?.hasCameraDevice == false {
            return (
                "No Camera",
                .orange,
                "Audio & Camera profile has no camera connected — video controls stay monitor-disabled."
            )
        }

        if configuredShortcut.isEmpty {
            return (
                "Unbound",
                .secondary,
                "No physical \(action.label.lowercased()) keybind assigned in Call Controls. Click Simulate \(action.label) to preview default behavior."
            )
        }

        if !simAccessibility {
            return (
                "Needs Accessibility",
                .orange,
                "Simulated Accessibility is unchecked — physical \(action.label.lowercased()) keybind is blocked until permission is granted."
            )
        }

        switch decision {
        case .remap(_, let app, _, let targetShortcut, let focusRestore):
            let deliveryNote = focusRestore
                ? "background AXMenuBar press or brief focus restore"
                : "direct frontmost relay"
            return (
                "Remap -> \(app.appName)",
                .green,
                "Translates keybind to \(targetShortcut.displayString) via \(deliveryNote)."
            )
        case .passThroughWithHardwareSync:
            return (
                "Same-Key Sync",
                .teal,
                "Configured shortcut matches \(mapped?.appName ?? "app")'s native key; lets app handle it + syncs hardware state."
            )
        case .globalHardwareOnly:
            if action == .video {
                return (
                    "Video Blocked",
                    .orange,
                    "\(mapped?.appName ?? "Current scenario") has no video shortcut and macOS has no global camera mute."
                )
            }
            return (
                "Global Hardware Only",
                .blue,
                "Everywhere scope toggles macOS default input mic even when no video-call target is active."
            )
        case .passThrough:
            if let mapped, !mapped.enabled {
                return (
                    "App Disabled",
                    .secondary,
                    "\(mapped.appName) is toggled off in Call Controls; event passes through untouched."
                )
            }
            if let mapped,
               let req = mapped.requiredWindowTitleSubstring,
               !req.isEmpty,
               let title = sim?.customWindowTitle,
               !title.localizedCaseInsensitiveContains(req) {
                return (
                    "Tab Not Matched",
                    .orange,
                    "\(mapped.appName) requires \"\(req)\" in tab title; current tab is \"\(title)\"."
                )
            }
            return (
                "Pass Through",
                .secondary,
                "Event passes untouched to the frontmost app under \(effectiveScope.label) scope."
            )
        }
    }

    // MARK: - 4. AX Menu Bar Scanner Probe

    private var axScannerProbeSection: some View {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !($0.bundleIdentifier ?? "").isEmpty }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }

        return FeatureSection(
            "Accessibility Menu Bar Control Probe",
            subtitle: "Inspect live AXMenuBar shortcuts discovered for any running app—matches what 'Add Call App…' uses to auto-detect Mic & Video controls."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            if let bundleID = app.bundleIdentifier {
                                Button(app.localizedName ?? bundleID) {
                                    uiState.scannedBundleID = bundleID
                                    uiState.scannedAppName = app.localizedName ?? bundleID
                                    uiState.inspectedControls = CallShortcutRemapper.scanMenuBarControls(forBundleID: bundleID)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "app.badge.checkmark")
                                .foregroundStyle(.secondary)
                            Text(uiState.scannedAppName.isEmpty ? "Pick Running App to Inspect…" : uiState.scannedAppName)
                                .toolboxFont(.callout)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .toolboxFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: 280)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .pointerCursor()

                    Button("Rescan AXMenuBar") {
                        guard !uiState.scannedBundleID.isEmpty else { return }
                        uiState.inspectedControls = CallShortcutRemapper.scanMenuBarControls(forBundleID: uiState.scannedBundleID)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(uiState.scannedBundleID.isEmpty)
                    .pointerCursor(!uiState.scannedBundleID.isEmpty)

                    Spacer()
                }

                if let inspected = uiState.inspectedControls {
                    Divider()

                    if !inspected.accessibilityGranted {
                        Text("Accessibility permission is required for live AXMenuBar scanning.")
                            .toolboxFont(.caption)
                            .foregroundStyle(.orange)
                    } else if !inspected.isRunning {
                        Text("\(uiState.scannedAppName) is not currently running.")
                            .toolboxFont(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 12) {
                            scanSummaryBadge(label: "Mic Guess", shortcut: inspected.suggestedMic)
                            scanSummaryBadge(label: "Video Guess", shortcut: inspected.suggestedVideo)
                            Spacer()
                            Text("\(inspected.allShortcutControls.count) shortcut item(s)")
                                .toolboxFont(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        if !inspected.allShortcutControls.isEmpty {
                            DisclosureGroup(
                                "Discovered Menu Bar Shortcuts (\(inspected.allShortcutControls.count))",
                                isExpanded: $uiState.showAllScannedShortcuts
                            ) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(inspected.allShortcutControls) { item in
                                            HStack(spacing: 8) {
                                                Text(item.menuPath)
                                                    .toolboxFont(.caption)
                                                    .lineLimit(1)
                                                Spacer()
                                                if let kind = item.kind {
                                                    StatusBadge(text: kind.label, color: kind == .mic ? .green : .blue)
                                                }
                                                ShortcutPill(shortcut: item.shortcut)
                                            }
                                        }
                                    }
                                    .padding(.top, 6)
                                }
                                .frame(maxHeight: 160)
                            }
                            .toolboxFont(.caption.weight(.medium))
                            .pointerCursor()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func scanSummaryBadge(label: String, shortcut: ShortcutSpec) -> some View {
        HStack(spacing: 5) {
            Text("\(label):")
                .toolboxFont(.caption)
                .foregroundStyle(.secondary)
            if shortcut.isEmpty {
                Text("None")
                    .toolboxFont(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
            } else {
                ShortcutPill(shortcut: shortcut)
            }
        }
    }

    // MARK: - 5. Live Hardware & Tap Telemetry

    private var liveTelemetrySection: some View {
        let runningCallApps = configManager.config.callControls.appShortcutMappings.filter {
            callControls.isAppRunning(for: $0)
        }

        return FeatureSection(
            "Live Subsystems & Stream Telemetry",
            subtitle: "Real CoreAudio, CoreMediaIO, and background CGEventTap state regardless of active simulations."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    telemetryCell("Module Running", value: callControls.isRunning ? "Yes" : "No")
                    telemetryCell("CoreAudio Mic Stream", value: callControls.isMicStreamActive ? "Active" : "Idle")
                    telemetryCell("CMIO Camera", value: callControls.isCameraActive ? "Active" : (callControls.hasCameraDevice ? "Off" : "None"))
                    telemetryCell("Accessibility", value: permissions.actualAccessibilityGranted ? "Trusted" : "Denied")
                }

                Divider()

                HStack(spacing: 14) {
                    telemetryCell("Remapper Tap", value: callControls.isRemapperTapInstalled ? "Installed" : "Off")
                    telemetryCell("Typing Guard Tap", value: callControls.isTypingTapInstalled ? "Installed" : "Off")
                    telemetryCell("Hardware Mute", value: callControls.isInputMuted ? "Muted" : "Live")
                    telemetryCell("Desktop Pill", value: callControls.isFloatingPillVisible ? "Visible" : "Hidden")
                }

                Divider()

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Running Configured Call Apps")
                            .toolboxFont(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(
                            runningCallApps.isEmpty
                                ? "None running right now"
                                : runningCallApps.map(\.appName).joined(separator: ", ")
                        )
                        .toolboxFont(.caption)
                        .foregroundStyle(.primary)
                    }

                    Spacer()

                    Button("Refresh Streams") {
                        callControls.refreshAudioDevices()
                        callControls.refreshMicStreamActivity()
                        callControls.refreshCameraStatus()
                        callControls.refreshRunningApplications()
                        HUDToast.shared.show(title: "Refreshed CoreAudio & camera telemetry", symbol: "arrow.clockwise", tint: .blue)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                }
            }
        }
    }

    private func telemetryCell(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .toolboxFont(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .toolboxFont(.caption.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func simulationBinding<Value>(
        _ keyPath: WritableKeyPath<CallSimulationState, Value>,
        default fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { callControls.developerSimulation?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                callControls.developerSimulation?[keyPath: keyPath] = newValue
            }
        )
    }

    private func syncPreviewState() {
        callControls.populateFloatingState(previewPillState)
    }
}
