import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct SelectableCallAppCandidate: Identifiable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    let name: String
    let bundleIdentifier: String
    let iconURL: URL?
    let isRunning: Bool
}

@MainActor
private final class CallControlsSettingsUIState: ObservableObject {
    @Published var isAddingCustomApp = false
    @Published var availableApps: [SelectableCallAppCandidate] = []
    @Published var selectedAppName = ""
    @Published var selectedBundleID = ""
    @Published var selectedAppIconURL: URL?
    @Published var customMicShortcut: ShortcutSpec = .none
    @Published var customVideoShortcut: ShortcutSpec = .none
    @Published var customAllowFocusRestore = true
    @Published var inspectedControls: CallShortcutRemapper.InspectedAppControls?
    @Published var showManualShortcutFallback = false
    @Published var isLaunchingAndScanning = false
}

struct CallControlsSettingsView: View {
    @ObservedObject var module: CallControlsModule
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @StateObject private var uiState = CallControlsSettingsUIState()

    var body: some View {
        let cfg = configManager.config.callControls
        let showAccessibilityBanner = module.needsAccessibilityForConfiguredFeatures(cfg) && !permissions.isAccessibilityGranted

        VStack(alignment: .leading, spacing: 20) {
            liveStatusSection

            if showAccessibilityBanner {
                accessibilityInlineBanner
            }

            unifiedCallKeybindsSection
            callAppsSection
            hardwareMicAndTypingSection
            audioDevicesSection
        }
        .onAppear {
            permissions.refresh()
            module.refreshAudioDevices()
            module.refreshMicStreamActivity()
            module.refreshCameraStatus()
        }
    }

    // MARK: - Live Status & Quick Controls

    private var liveStatusSection: some View {
        let input = module.defaultInputDevice
        let output = module.defaultOutputDevice

        return FeatureSection(
            "LIVE CALL & AUDIO STATUS",
            subtitle: "Control your macOS microphone, check camera state, and switch audio outputs immediately."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    // Microphone Quick Card
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill((module.isInputMuted ? Color.red : Color.green).opacity(0.15))
                                .frame(width: 34, height: 34)
                            Image(systemName: module.isTypingMuted ? "keyboard" : (module.isInputMuted ? "mic.slash.fill" : "mic.fill"))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(module.isTypingMuted ? .orange : (module.isInputMuted ? .red : .green))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Microphone")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                StatusBadge(
                                    text: module.isTypingMuted ? "Typing Mute" : (module.isInputMuted ? "Muted" : "Live"),
                                    color: module.isTypingMuted ? .orange : (module.isInputMuted ? .red : .green)
                                )
                            }
                            Text(input?.name ?? "No input device")
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        Spacer(minLength: 6)

                        Button {
                            module.toggleHardwareMicMute()
                        } label: {
                            Label(
                                module.isInputMuted ? "Unmute" : "Mute",
                                systemImage: module.isInputMuted ? "mic.fill" : "mic.slash.fill"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(module.isInputMuted ? .green : .red)
                        .controlSize(.small)
                        .disabled(input == nil)
                        .pointerCursor(input != nil)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                    // Output Quick Card
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.blue.opacity(0.15))
                                .frame(width: 34, height: 34)
                            Image(systemName: output?.transport.symbolName(isInput: false) ?? "speaker.wave.2.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.blue)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Output")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                if let transport = output?.transport {
                                    Text(transport.label)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Text(output?.name ?? "No output device")
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        Spacer(minLength: 6)

                        Button {
                            module.cycleOutputDevice()
                        } label: {
                            Label("Cycle", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(module.outputDevices.count < 2)
                        .help("Switch to the next favorite output device")
                        .pointerCursor(module.outputDevices.count >= 2)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }

                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: module.isCameraActive ? "video.fill" : "video.slash.fill")
                            .font(.caption)
                            .foregroundStyle(module.hasCameraDevice ? (module.isCameraActive ? .green : .red) : .secondary)
                        Text(
                            !module.hasCameraDevice
                                ? "No camera detected"
                                : (module.isCameraActive
                                    ? "Camera Live: \(module.activeCameraName ?? "Active")"
                                    : "Camera Off")
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (module.isCameraActive ? Color.green : Color.red).opacity(module.hasCameraDevice ? 0.10 : 0.05),
                        in: Capsule()
                    )

                    if let lastAction = module.lastRelayedActionLabel {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.horizontal.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text("Last relayed: \(lastAction)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Spacer()
                }
            }
        }
    }

    // MARK: - Inline Accessibility Banner

    private var accessibilityInlineBanner: some View {
        SectionCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Accessibility Required for Keybind Override & Typing Guard")
                        .font(.headline)
                    Text(module.accessibilityReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Button("Grant Permission…") {
                        permissions.promptAndOpenSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                    .pointerCursor()

                    Button("Reset Entry") {
                        permissions.resetAndRegrantAccessibility()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                }
            }
        }
    }

    // MARK: - Unified Call Keybinds

    private var unifiedCallKeybindsSection: some View {
        let cfg = configManager.config.callControls

        return FeatureSection(
            "MY MIC & VIDEO KEYBINDS",
            subtitle: "Set your own Mic and Video shortcuts once and use them in whichever app you're in — Toolbox toggles your mic and overrides enabled call apps."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                keybindReadinessStrip(cfg: cfg)

                SettingRow(
                    "My Mic Keybind",
                    subtitle: cfg.overrideScope == .everywhere
                        ? "Works anywhere: toggles your macOS mic and overrides enabled call apps (FaceTime, Teams, Zoom, Slack, Meet)."
                        : "Translated to each enabled call app's native mute shortcut (e.g. ⌘ ⇧ M in FaceTime/Teams, ⌘ ⇧ A in Zoom)."
                ) {
                    HStack(spacing: 6) {
                        Menu("Presets") {
                            Button("⌃ ⌥ ⌘ M (Global-safe)") {
                                configManager.config.callControls.micShortcut = ShortcutSpec(key: "m", modifiers: [.control, .option, .command])
                                promptAccessibilityIfNeeded()
                            }
                            Button("⌘ ⇧ Space (Slack style)") {
                                configManager.config.callControls.micShortcut = ShortcutSpec(key: "space", modifiers: [.command, .shift])
                                promptAccessibilityIfNeeded()
                            }
                            Button("⌥ ⇧ M (Option + Shift + M)") {
                                configManager.config.callControls.micShortcut = ShortcutSpec(key: "m", modifiers: [.option, .shift])
                                promptAccessibilityIfNeeded()
                            }
                        }
                        .menuStyle(.borderedButton)
                        .controlSize(.small)
                        .fixedSize()
                        .pointerCursor()

                        ShortcutRecorderView(
                            shortcut: configManager.config.callControls.micShortcut,
                            sourceID: "call_controls.mic"
                        ) { newShortcut in
                            configManager.config.callControls.micShortcut = newShortcut
                            promptAccessibilityIfNeeded()
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 10)

                SettingRow(
                    "My Video Keybind",
                    subtitle: "Toggles camera inside apps with a native video shortcut (\(CallControlsModule.videoCapableAppsSummary(from: cfg.appShortcutMappings))). macOS and FaceTime have no OS/app camera mute."
                ) {
                    HStack(spacing: 6) {
                        Menu("Presets") {
                            Button("⌃ ⌥ ⌘ V (Global-safe)") {
                                configManager.config.callControls.videoShortcut = ShortcutSpec(key: "v", modifiers: [.control, .option, .command])
                                promptAccessibilityIfNeeded()
                            }
                            Button("⌘ ⇧ V (Zoom style)") {
                                configManager.config.callControls.videoShortcut = ShortcutSpec(key: "v", modifiers: [.command, .shift])
                                promptAccessibilityIfNeeded()
                            }
                        }
                        .menuStyle(.borderedButton)
                        .controlSize(.small)
                        .fixedSize()
                        .pointerCursor()

                        ShortcutRecorderView(
                            shortcut: configManager.config.callControls.videoShortcut,
                            sourceID: "call_controls.video"
                        ) { newShortcut in
                            configManager.config.callControls.videoShortcut = newShortcut
                            promptAccessibilityIfNeeded()
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 10)

                VStack(alignment: .leading, spacing: 6) {
                    SettingRow("Where Keybinds Apply") {
                        Picker("", selection: $configManager.config.callControls.overrideScope) {
                            ForEach(CallOverrideScope.allCases, id: \.self) { scope in
                                Text(scope.label).tag(scope)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .pointerCursor()
                    }
                    Text(configManager.config.callControls.overrideScope.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if cfg.overrideScope != .everywhere {
                    Divider()
                        .padding(.vertical, 10)

                    SettingRow(
                        "Also Mute macOS Hardware Mic",
                        subtitle: "Toggles your system input mute via CoreAudio whenever My Mic Keybind relays to a call app."
                    ) {
                        Toggle("", isOn: $configManager.config.callControls.syncHardwareMuteWithAppMicToggle)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .pointerCursor()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keybindReadinessStrip(cfg: CallControlsConfig) -> some View {
        let hasShortcut = !cfg.micShortcut.isEmpty || !cfg.videoShortcut.isEmpty
        let matchingMicApps = cfg.micShortcut.isEmpty
            ? []
            : cfg.appShortcutMappings.filter { $0.enabled && $0.micShortcut == cfg.micShortcut }.map(\.appName)

        if hasShortcut {
            VStack(alignment: .leading, spacing: 5) {
                if !permissions.isAccessibilityGranted {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("Waiting for Accessibility permission before your keybinds can intercept.")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                } else {
                    if !cfg.micShortcut.isEmpty {
                        micReadinessRow(cfg: cfg)
                    }
                    if !cfg.videoShortcut.isEmpty {
                        videoReadinessRow(cfg: cfg)
                    }
                }

                if !matchingMicApps.isEmpty {
                    Text("Same shortcut as \(matchingMicApps.joined(separator: ", "))'s native binding — passes cleanly through.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if !cfg.micShortcut.isEmpty && cfg.micShortcut == cfg.osMuteShortcut {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("Warning: My Mic Keybind and Hardware-Only Mic Shortcut both use \(cfg.micShortcut.displayString). Clear one so they don't collide.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func micReadinessRow(cfg: CallControlsConfig) -> some View {
        if cfg.overrideScope == .everywhere {
            if let readiness = module.targetReadinessNote(for: .mic) {
                let text = readiness.isMenuReady == false
                    ? "Mic \(cfg.micShortcut.displayString) active everywhere · toggles macOS mic (\(readiness.appName) mute enables in a live call)"
                    : "Mic \(cfg.micShortcut.displayString) active everywhere · toggles macOS mic & overrides \(readiness.appName)"
                readinessDotRow(color: .green, text: text)
            } else {
                readinessDotRow(
                    color: .green,
                    text: "Mic \(cfg.micShortcut.displayString) active everywhere · toggles your macOS mic in any app"
                )
            }
        } else if let target = module.currentTargetSummary(for: .mic) {
            readinessDotRow(
                color: .green,
                text: "Mic \(cfg.micShortcut.displayString) ready · overrides \(target.appName) (sends \(target.shortcut.displayString))"
            )
        } else {
            readinessDotRow(
                color: .secondary.opacity(0.6),
                text: "Mic \(cfg.micShortcut.displayString) armed · open an enabled call app, or switch scope above to 'Everywhere'."
            )
        }
    }

    @ViewBuilder
    private func videoReadinessRow(cfg: CallControlsConfig) -> some View {
        if let target = module.currentTargetSummary(for: .video) {
            readinessDotRow(
                color: .green,
                text: "Video \(cfg.videoShortcut.displayString) ready · overrides \(target.appName) (sends \(target.shortcut.displayString))"
            )
        } else if let unsupported = module.runningVideoUnsupportedApp() {
            readinessDotRow(
                color: .orange,
                text: "Video \(cfg.videoShortcut.displayString) unavailable in \(unsupported.appName) · no app camera shortcut (macOS has no OS camera mute)"
            )
        } else {
            let apps = CallControlsModule.videoCapableAppsSummary(from: cfg.appShortcutMappings)
            readinessDotRow(
                color: .secondary.opacity(0.6),
                text: "Video \(cfg.videoShortcut.displayString) standby · works in \(apps) (macOS has no OS camera mute)"
            )
        }
    }

    private func readinessDotRow(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Call Apps to Override

    private var callAppsSection: some View {
        let mappings = configManager.config.callControls.appShortcutMappings
        let enabledCount = mappings.filter(\.enabled).count

        return FeatureSection(
            "CALL APPS TO OVERRIDE",
            subtitle: "Toggle which apps respond to your unified keybinds. Built-in presets stay ready; added apps scan menu bar controls automatically."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("\(enabledCount) of \(mappings.count) call apps active")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Reset Presets") {
                        module.resetMappingsToDefaults()
                        refreshSelectableApps()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()

                    Button {
                        if uiState.isAddingCustomApp {
                            resetAddAppState()
                        } else {
                            refreshSelectableApps()
                            uiState.isAddingCustomApp = true
                        }
                    } label: {
                        Label(
                            uiState.isAddingCustomApp ? "Cancel" : "Add Call App…",
                            systemImage: uiState.isAddingCustomApp ? "xmark" : "plus"
                        )
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                }

                if uiState.isAddingCustomApp {
                    addCustomAppBuilder
                }

                VStack(spacing: 0) {
                    ForEach($configManager.config.callControls.appShortcutMappings) { $mapping in
                        if mapping.id != mappings.first?.id {
                            Divider()
                        }
                        callAppRow(for: $mapping)
                    }
                }
            }
        }
    }

    private var addCustomAppBuilder: some View {
        let runningApps = uiState.availableApps.filter(\.isRunning)
        let installedApps = uiState.availableApps.filter { !$0.isRunning }
        let hasSelection = !uiState.selectedBundleID.isEmpty
        let hasAnyShortcut = !uiState.customMicShortcut.isEmpty || !uiState.customVideoShortcut.isEmpty
        let canAdd = hasSelection && !uiState.selectedAppName.isEmpty && hasAnyShortcut

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    if !runningApps.isEmpty {
                        Section("Running Apps") {
                            ForEach(runningApps) { candidate in
                                candidateMenuButton(candidate)
                            }
                        }
                    }

                    if !installedApps.isEmpty {
                        Section("Installed Apps") {
                            ForEach(installedApps) { candidate in
                                candidateMenuButton(candidate)
                            }
                        }
                    }

                    Divider()

                    Button {
                        pickApplicationFromFinder()
                    } label: {
                        Label("Browse Finder…", systemImage: "folder")
                    }
                } label: {
                    HStack(spacing: 8) {
                        if let iconURL = uiState.selectedAppIconURL {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: iconURL.path))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "app.dashed")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }

                        Text(hasSelection ? uiState.selectedAppName : "Select a Call Application…")
                            .font(.callout.weight(hasSelection ? .medium : .regular))
                            .foregroundStyle(hasSelection ? .primary : .secondary)

                        Spacer()

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .pointerCursor()

                if hasSelection {
                    Button {
                        scanSelectedAppControls()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Re-read the app's menu bar controls")
                    .pointerCursor()
                }
            }

            if !permissions.isAccessibilityGranted {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.orange)
                    Text("Accessibility access is required to inspect another app's menu bar controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Grant Access") {
                        permissions.promptAndOpenSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                }
                .padding(8)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            if hasSelection, let inspected = uiState.inspectedControls {
                if !inspected.isRunning {
                    HStack(spacing: 10) {
                        Image(systemName: "play.circle")
                            .foregroundStyle(.secondary)
                        Text("Open \(uiState.selectedAppName) so Toolbox can read its menu bar mic and camera controls.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(uiState.isLaunchingAndScanning ? "Scanning…" : "Launch & Scan") {
                            launchAndScanSelectedApp()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(uiState.isLaunchingAndScanning)
                        .pointerCursor(!uiState.isLaunchingAndScanning)
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    scannedControlsPicker(for: inspected)
                }

                DisclosureGroup(
                    "Manual Shortcut Fallback",
                    isExpanded: $uiState.showManualShortcutFallback
                ) {
                    HStack(spacing: 14) {
                        HStack(spacing: 6) {
                            Text("Mic")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ShortcutRecorderView(
                                shortcut: uiState.customMicShortcut,
                                showConflictWarnings: false
                            ) { newVal in
                                uiState.customMicShortcut = newVal
                            }
                        }

                        HStack(spacing: 6) {
                            Text("Video")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ShortcutRecorderView(
                                shortcut: uiState.customVideoShortcut,
                                showConflictWarnings: false
                            ) { newVal in
                                uiState.customVideoShortcut = newVal
                            }
                        }

                        Spacer()
                    }
                    .padding(.top, 6)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .pointerCursor()
            }

            HStack(spacing: 10) {
                Toggle("Brief focus switch in background", isOn: $uiState.customAllowFocusRestore)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .help("Recommended for Electron/browser apps so shortcuts still land when another window is focused.")
                    .pointerCursor()

                Spacer()

                Button("Add App") {
                    let cleanName = uiState.selectedAppName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleanBundle = uiState.selectedBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanName.isEmpty, !cleanBundle.isEmpty else { return }

                    let entry = CallAppShortcutMapping(
                        appName: cleanName,
                        bundleIdentifier: cleanBundle,
                        enabled: true,
                        micShortcut: uiState.customMicShortcut,
                        videoShortcut: uiState.customVideoShortcut,
                        allowBriefFocusRestore: uiState.customAllowFocusRestore
                    )
                    configManager.config.callControls.appShortcutMappings.append(entry)
                    resetAddAppState()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
                .pointerCursor(canAdd)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func candidateMenuButton(_ candidate: SelectableCallAppCandidate) -> some View {
        Button {
            selectCandidateApp(
                name: candidate.name,
                bundleID: candidate.bundleIdentifier,
                iconURL: candidate.iconURL
            )
        } label: {
            HStack {
                Text(candidate.name)
                if candidate.isRunning {
                    Text("(Running)")
                }
            }
        }
    }

    @ViewBuilder
    private func scannedControlsPicker(
        for inspected: CallShortcutRemapper.InspectedAppControls
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if inspected.allShortcutControls.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("No menu bar keyboard shortcuts detected for \(uiState.selectedAppName). Expand Manual Shortcut Fallback below if this app uses in-window hotkeys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Detected \(inspected.allShortcutControls.count) menu bar shortcut\(inspected.allShortcutControls.count == 1 ? "" : "s") in \(uiState.selectedAppName):")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    controlChoiceMenu(
                        label: "Mic Control",
                        primaryCandidates: inspected.micCandidates,
                        allCandidates: inspected.allShortcutControls,
                        selectedShortcut: $uiState.customMicShortcut
                    )

                    controlChoiceMenu(
                        label: "Video Control",
                        primaryCandidates: inspected.videoCandidates,
                        allCandidates: inspected.allShortcutControls,
                        selectedShortcut: $uiState.customVideoShortcut
                    )

                    Spacer()
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func controlChoiceMenu(
        label: String,
        primaryCandidates: [CallShortcutRemapper.DetectedMenuControl],
        allCandidates: [CallShortcutRemapper.DetectedMenuControl],
        selectedShortcut: Binding<ShortcutSpec>
    ) -> some View {
        let matched = (primaryCandidates + allCandidates).first { $0.shortcut == selectedShortcut.wrappedValue }
        let summaryText: String = {
            if let matched {
                return "\(matched.title) (\(matched.shortcut.displayString))"
            }
            if !selectedShortcut.wrappedValue.isEmpty {
                return "Custom (\(selectedShortcut.wrappedValue.displayString))"
            }
            return "None"
        }()

        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                if !primaryCandidates.isEmpty {
                    Section("Suggested Matches") {
                        ForEach(primaryCandidates) { item in
                            Button("\(item.menuPath) — \(item.shortcut.displayString)") {
                                selectedShortcut.wrappedValue = item.shortcut
                            }
                        }
                    }
                }

                let secondaryIDs = Set(primaryCandidates.map(\.id))
                let remaining = allCandidates.filter { !secondaryIDs.contains($0.id) }
                if !remaining.isEmpty {
                    Menu("All Menu Controls") {
                        ForEach(remaining) { item in
                            Button("\(item.menuPath) — \(item.shortcut.displayString)") {
                                selectedShortcut.wrappedValue = item.shortcut
                            }
                        }
                    }
                }

                Divider()

                Button("None (Not Supported)") {
                    selectedShortcut.wrappedValue = .none
                }
            } label: {
                HStack(spacing: 4) {
                    Text(summaryText)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton)
            .pointerCursor()
        }
    }

    @ViewBuilder
    private func callAppRow(for mappingBinding: Binding<CallAppShortcutMapping>) -> some View {
        let mapping = mappingBinding.wrappedValue
        let isRunning = module.isAppRunning(for: mapping)
        let isBuiltIn = CallAppShortcutMapping.defaults.contains { $0.id == mapping.id }
        let capabilityText: String = {
            switch (!mapping.micShortcut.isEmpty, !mapping.videoShortcut.isEmpty) {
            case (true, true): return "Mic & Video"
            case (true, false): return "Mic Only"
            case (false, true): return "Video Only"
            case (false, false): return "No Controls"
            }
        }()

        HStack(spacing: 10) {
            appIconBadge(for: mapping)

            HStack(spacing: 6) {
                Text(mapping.appName)
                    .font(.callout.weight(.medium))
                    .opacity(mapping.enabled ? 1.0 : 0.55)
                    .lineLimit(1)

                if isRunning {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                        Text("Running")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.green.opacity(0.12), in: Capsule())
                }

                if let titleGate = mapping.requiredWindowTitleSubstring, !titleGate.isEmpty {
                    Text("Title: \"\(titleGate)\"")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Text(capabilityText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.primary.opacity(0.05), in: Capsule())

                if !isBuiltIn {
                    Button(role: .destructive) {
                        let idToRemove = mapping.id
                        configManager.config.callControls.appShortcutMappings.removeAll { $0.id == idToRemove }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(mapping.appName)")
                    .pointerCursor()
                }

                Toggle("", isOn: mappingBinding.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .pointerCursor()
            }
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func appIconBadge(for mapping: CallAppShortcutMapping) -> some View {
        let icon: NSImage? = mapping.bundleIdentifiers.lazy.compactMap { bundleID -> NSImage? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return nil
            }
            return NSWorkspace.shared.icon(forFile: url.path)
        }.first

        if let icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
                .opacity(mapping.enabled ? 1.0 : 0.45)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(mapping.enabled ? 0.08 : 0.04))
                    .frame(width: 26, height: 26)
                Image(systemName: "video.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - OS Hardware Mic & Typing Guard

    private var hardwareMicAndTypingSection: some View {
        FeatureSection(
            "FLOATING PILL, TYPING GUARD & FALLBACK HOTKEY",
            subtitle: "Customize the floating Mic & Camera status pill, toast notifications, Auto-Mute While Typing, or an optional separate hardware mute key."
        ) {
            VStack(spacing: 0) {
                SettingRow(
                    "Floating Call Status Pill",
                    subtitle: "Keeps a small, draggable Mic & Camera badge on screen (defaults to top-right). Also toggleable from the Menu Bar."
                ) {
                    HStack(spacing: 8) {
                        if configManager.config.callControls.showFloatingMicIndicator {
                            Button("Reset Corner") {
                                module.resetFloatingPillPosition()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Move floating pill back to the top-right corner")
                            .pointerCursor()
                        }

                        Toggle("", isOn: $configManager.config.callControls.showFloatingMicIndicator)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .pointerCursor()
                    }
                }

                if configManager.config.callControls.showFloatingMicIndicator {
                    Divider()
                        .padding(.vertical, 10)

                    VStack(alignment: .leading, spacing: 6) {
                        SettingRow(
                            "Only Show During Active Calls",
                            subtitle: "Automatically shows the pill when your microphone or camera is in use, and hides it when idle."
                        ) {
                            Toggle("", isOn: $configManager.config.callControls.showFloatingPillOnlyDuringCalls)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .pointerCursor()
                        }

                        if configManager.config.callControls.showFloatingPillOnlyDuringCalls {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(module.isCallOrMediaActive ? Color.green : Color.secondary.opacity(0.6))
                                    .frame(width: 6, height: 6)
                                Text(
                                    module.isCallOrMediaActive
                                        ? "Call or media stream active now — pill is visible."
                                        : "No mic or camera stream active right now — pill stays hidden until a call starts."
                                )
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()
                        .padding(.vertical, 10)

                    SettingRow(
                        "Include Video Camera Status in Pill",
                        subtitle: "Shows live green/red camera status via CoreMediaIO. Clickable to toggle video in \(CallControlsModule.videoCapableAppsSummary(from: configManager.config.callControls.appShortcutMappings)); monitor-only elsewhere."
                    ) {
                        Toggle("", isOn: $configManager.config.callControls.showVideoInFloatingIndicator)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .pointerCursor()
                    }
                }

                Divider()
                    .padding(.vertical, 10)

                SettingRow(
                    "Show Toast Notifications",
                    subtitle: "Displays a brief HUD confirmation when toggling mic mute, relaying a call shortcut, or switching audio devices."
                ) {
                    Toggle("", isOn: $configManager.config.callControls.showToasts)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }

                Divider()
                    .padding(.vertical, 10)

                SettingRow(
                    "Auto-Mute Mic While Typing",
                    subtitle: "Passively mutes your OS mic while typing and unmutes after a pause. Manual mute always takes precedence."
                ) {
                    Toggle("", isOn: Binding(
                        get: { configManager.config.callControls.autoMuteWhileTyping },
                        set: { newVal in
                            configManager.config.callControls.autoMuteWhileTyping = newVal
                            if newVal && !permissions.isAccessibilityGranted {
                                permissions.promptAndOpenSettings()
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .pointerCursor()
                }

                if configManager.config.callControls.autoMuteWhileTyping {
                    Divider()
                        .padding(.vertical, 10)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Typing Restore Delay")
                                    .font(.callout.weight(.medium))
                                Text("How long after your last keystroke Toolbox waits before unmuting the microphone.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(configManager.config.callControls.typingUnmuteDelayMs) ms")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                        }

                        Slider(
                            value: Binding(
                                get: { Double(configManager.config.callControls.typingUnmuteDelayMs) },
                                set: { configManager.config.callControls.typingUnmuteDelayMs = Int($0.rounded()) }
                            ),
                            in: 250...1000,
                            step: 50
                        )
                        .pointerCursor()
                    }
                }

                Divider()
                    .padding(.vertical, 10)

                SettingRow(
                    "Hardware-Only Mic Shortcut (Optional)",
                    subtitle: "Separate macOS-only mic mute shortcut (works without Accessibility; leaves call apps untouched)."
                ) {
                    ShortcutRecorderView(
                        shortcut: configManager.config.callControls.osMuteShortcut,
                        sourceID: "call_controls.os_mute",
                        registrationKey: module.osMuteHotKeyName
                    ) { newShortcut in
                        configManager.config.callControls.osMuteShortcut = newShortcut
                    }
                }
            }
        }
    }

    // MARK: - Audio Devices & Quick Switching

    private var audioDevicesSection: some View {
        let outputs = module.outputDevices
        let inputs = module.inputDevices
        let favOutputs = Set(configManager.config.callControls.favoriteOutputUIDs)
        let favInputs = Set(configManager.config.callControls.favoriteInputUIDs)

        return FeatureSection(
            "AUDIO DEVICES & QUICK SWITCHING",
            subtitle: "Click any device to make it default, or star favorite outputs to cycle between them with one shortcut."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                SettingRow(
                    "Cycle Favorite Outputs Shortcut",
                    subtitle: "Cycles through your starred output devices (or all outputs if fewer than 2 are starred)."
                ) {
                    HStack(spacing: 8) {
                        ShortcutRecorderView(
                            shortcut: configManager.config.callControls.cycleOutputShortcut,
                            sourceID: "call_controls.cycle_output",
                            registrationKey: module.cycleOutputHotKeyName
                        ) { newShortcut in
                            configManager.config.callControls.cycleOutputShortcut = newShortcut
                        }

                        Button("Refresh") {
                            module.refreshAudioDevices()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("OUTPUT DEVICES (\(outputs.count))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.4)

                    if outputs.isEmpty {
                        Text("No output devices detected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(outputs.enumerated()), id: \.element.id) { idx, device in
                                if idx > 0 { Divider() }
                                deviceRow(
                                    device: device,
                                    isInput: false,
                                    isDefault: device.isDefaultOutput,
                                    isFavorite: favOutputs.contains(device.uid),
                                    onSelect: { _ = module.selectOutputDevice(device) },
                                    onToggleFavorite: { module.toggleFavoriteOutput(device.uid) }
                                )
                            }
                        }
                        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("INPUT DEVICES (\(inputs.count))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.4)

                    if inputs.isEmpty {
                        Text("No input devices detected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(inputs.enumerated()), id: \.element.id) { idx, device in
                                if idx > 0 { Divider() }
                                deviceRow(
                                    device: device,
                                    isInput: true,
                                    isDefault: device.isDefaultInput,
                                    isFavorite: favInputs.contains(device.uid),
                                    onSelect: { _ = module.selectInputDevice(device) },
                                    onToggleFavorite: { module.toggleFavoriteInput(device.uid) }
                                )
                            }
                        }
                        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    private func deviceRow(
        device: AudioDeviceInfo,
        isInput: Bool,
        isDefault: Bool,
        isFavorite: Bool,
        onSelect: @escaping () -> Void,
        onToggleFavorite: @escaping () -> Void
    ) -> some View {
        let volumePct: Int? = {
            let scalar = isInput ? device.inputVolumeScalar : device.outputVolumeScalar
            return scalar.map { Int(($0 * 100).rounded()) }
        }()
        let isMuted = isInput ? device.isInputMuted : device.isOutputMuted

        return HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: device.transport.symbolName(isInput: isInput))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isDefault ? (isInput ? Color.green : Color.blue) : .secondary)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(device.name)
                                .font(.callout.weight(isDefault ? .semibold : .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if isDefault {
                                StatusBadge(text: "Active", color: isInput ? .green : .blue)
                            }
                        }

                        HStack(spacing: 6) {
                            Text(device.transport.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)

                            Text("\(isInput ? device.inputChannelCount : device.outputChannelCount) ch")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            if isMuted {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text("Muted")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.red)
                            } else if let volumePct {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text("\(volumePct)%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(isDefault ? "Currently active device" : "Click to set as default")
            .pointerCursor()

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(isFavorite ? Color.orange : Color.secondary.opacity(0.55))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove from favorites" : "Star as favorite")
            .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func promptAccessibilityIfNeeded() {
        let cfg = configManager.config.callControls
        if module.needsAccessibilityForConfiguredFeatures(cfg) && !permissions.isAccessibilityGranted {
            permissions.promptAndOpenSettings()
        }
    }

    private func resetAddAppState() {
        uiState.isAddingCustomApp = false
        uiState.selectedAppName = ""
        uiState.selectedBundleID = ""
        uiState.selectedAppIconURL = nil
        uiState.customMicShortcut = .none
        uiState.customVideoShortcut = .none
        uiState.customAllowFocusRestore = true
        uiState.inspectedControls = nil
        uiState.showManualShortcutFallback = false
        uiState.isLaunchingAndScanning = false
    }

    private func selectCandidateApp(name: String, bundleID: String, iconURL: URL?) {
        uiState.selectedAppName = name
        uiState.selectedBundleID = bundleID
        uiState.selectedAppIconURL = iconURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        uiState.customMicShortcut = .none
        uiState.customVideoShortcut = .none
        uiState.showManualShortcutFallback = false
        uiState.isLaunchingAndScanning = false
        scanSelectedAppControls(replaceSelections: true)
    }

    private func scanSelectedAppControls(replaceSelections: Bool = false) {
        let bundleID = uiState.selectedBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else {
            uiState.inspectedControls = nil
            return
        }

        let inspected = CallShortcutRemapper.scanMenuBarControls(forBundleID: bundleID)
        uiState.inspectedControls = inspected

        if replaceSelections || uiState.customMicShortcut.isEmpty {
            uiState.customMicShortcut = inspected.suggestedMic
        }
        if replaceSelections || uiState.customVideoShortcut.isEmpty {
            uiState.customVideoShortcut = inspected.suggestedVideo
        }
        if inspected.isRunning && inspected.allShortcutControls.isEmpty {
            uiState.showManualShortcutFallback = true
        }
    }

    private func launchAndScanSelectedApp() {
        let targetBundleID = uiState.selectedBundleID
        guard !targetBundleID.isEmpty,
              let appURL = uiState.selectedAppIconURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: targetBundleID)
        else { return }

        uiState.isLaunchingAndScanning = true
        let openConfig = NSWorkspace.OpenConfiguration()
        openConfig.activates = false

        NSWorkspace.shared.openApplication(at: appURL, configuration: openConfig) { _, _ in
            Task { @MainActor in
                for attempt in 0..<4 {
                    try? await Task.sleep(nanoseconds: attempt == 0 ? 1_000_000_000 : 750_000_000)
                    guard uiState.selectedBundleID == targetBundleID else { return }
                    let inspected = CallShortcutRemapper.scanMenuBarControls(forBundleID: targetBundleID)
                    uiState.inspectedControls = inspected
                    if inspected.isRunning && (!inspected.allShortcutControls.isEmpty || attempt == 3) {
                        if uiState.customMicShortcut.isEmpty {
                            uiState.customMicShortcut = inspected.suggestedMic
                        }
                        if uiState.customVideoShortcut.isEmpty {
                            uiState.customVideoShortcut = inspected.suggestedVideo
                        }
                        if inspected.allShortcutControls.isEmpty {
                            uiState.showManualShortcutFallback = true
                        }
                        uiState.isLaunchingAndScanning = false
                        return
                    }
                }
                if uiState.selectedBundleID == targetBundleID {
                    uiState.isLaunchingAndScanning = false
                }
            }
        }
    }

    private func refreshSelectableApps() {
        let configuredBundleIDs = Set(
            configManager.config.callControls.appShortcutMappings
                .flatMap(\.bundleIdentifiers)
                .map { $0.lowercased() }
        )
        let selfBundleID = Bundle.main.bundleIdentifier?.lowercased()

        var byBundleID: [String: SelectableCallAppCandidate] = [:]

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { continue }
            let lower = bundleID.lowercased()
            if lower == selfBundleID || configuredBundleIDs.contains(lower) { continue }
            let name = app.localizedName ?? bundleID
            byBundleID[lower] = SelectableCallAppCandidate(
                name: name,
                bundleIdentifier: bundleID,
                iconURL: app.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                isRunning: true
            )
        }

        let fm = FileManager.default
        let appRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        for root in appRoots {
            guard let topLevel = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            var appURLs: [URL] = []
            for item in topLevel {
                if item.pathExtension.lowercased() == "app" {
                    appURLs.append(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let nested = try? fm.contentsOfDirectory(
                              at: item,
                              includingPropertiesForKeys: nil,
                              options: [.skipsHiddenFiles]
                          ) {
                    appURLs.append(contentsOf: nested.filter { $0.pathExtension.lowercased() == "app" })
                }
            }

            for url in appURLs {
                guard let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier,
                      !bundleID.isEmpty
                else { continue }
                let lower = bundleID.lowercased()
                if lower == selfBundleID || configuredBundleIDs.contains(lower) || byBundleID[lower] != nil {
                    continue
                }
                let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                byBundleID[lower] = SelectableCallAppCandidate(
                    name: displayName,
                    bundleIdentifier: bundleID,
                    iconURL: url,
                    isRunning: false
                )
            }
        }

        uiState.availableApps = byBundleID.values.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning {
                return lhs.isRunning && !rhs.isRunning
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func pickApplicationFromFinder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Call Application"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url),
           let bundleID = bundle.bundleIdentifier,
           !bundleID.isEmpty {
            let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            selectCandidateApp(name: appName, bundleID: bundleID, iconURL: url)
        }
    }
}
