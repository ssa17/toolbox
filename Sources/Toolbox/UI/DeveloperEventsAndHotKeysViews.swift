import AppKit
import Combine
import SwiftUI

// MARK: - Events & Taps View

@MainActor
private final class EventsAndTapsUIState: ObservableObject {
    @Published var selectedCategory: DeveloperEventCategory? = nil
    @Published var searchQuery: String = ""
    @Published var windowStack: [DockMinimizeModule.WindowStackEntry] = []
    @Published var stackCapturedAt: Date? = nil
    @Published var autoRefreshStack: Bool = false
}

struct DeveloperEventsAndTapsView: View {
    @ObservedObject private var eventLog = DeveloperEventLog.shared
    @ObservedObject private var scrollModule = ModuleRegistry.shared.scrollDirection
    @ObservedObject private var keepAwakeModule = ModuleRegistry.shared.keepAwake
    @ObservedObject private var permissions = PermissionsManager.shared
    @StateObject private var uiState = EventsAndTapsUIState()

    private let stackTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            eventConsoleSection
            scrollTapMonitorSection
            dockWindowStackSection
        }
        .onAppear {
            refreshWindowStack()
        }
        .onReceive(stackTimer) { _ in
            if uiState.autoRefreshStack {
                refreshWindowStack()
            }
        }
    }

    private var eventConsoleSection: some View {
        let filtered = eventLog.filteredEntries(
            category: uiState.selectedCategory,
            query: uiState.searchQuery
        )

        return FeatureSection(
            "Live Event & Action Console",
            subtitle: "In-memory ring buffer (latest \(DeveloperEventLog.maxEntries)) tracking real Dock clicks, hotkeys, assertions, config saves, and update state transitions."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TextField("Filter message or category…", text: $uiState.searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .toolboxFont(.callout)

                    Button("Copy Log") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(
                            eventLog.formattedExport(
                                category: uiState.selectedCategory,
                                query: uiState.searchQuery
                            ),
                            forType: .string
                        )
                        HUDToast.shared.show(title: "Copied event log", symbol: "doc.on.doc.fill", tint: .blue)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()

                    Button("Clear") {
                        eventLog.clear()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(eventLog.entries.isEmpty)
                    .pointerCursor(!eventLog.entries.isEmpty)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        categoryChip(title: "All (\(eventLog.entries.count))", category: nil)
                        ForEach(DeveloperEventCategory.allCases) { category in
                            categoryChip(title: category.rawValue, category: category)
                        }
                    }
                }

                Divider()

                if filtered.isEmpty {
                    VStack(spacing: 6) {
                        Text(eventLog.entries.isEmpty ? "No internal events captured yet." : "No events match the current filter.")
                            .toolboxFont(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("Trigger a hotkey, click a Dock icon, save config, or toggle an update simulation to see live entries here.")
                            .toolboxFont(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(filtered.prefix(60).enumerated()), id: \.element.id) { index, entry in
                                if index > 0 {
                                    Divider()
                                }
                                HStack(alignment: .top, spacing: 10) {
                                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                        .toolboxFont(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 72, alignment: .leading)

                                    StatusBadge(text: entry.category.rawValue, color: categoryColor(entry.category))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.message)
                                            .toolboxFont(.caption.weight(.medium))
                                            .textSelection(.enabled)
                                        if let detail = entry.detail, !detail.isEmpty {
                                            Text(detail)
                                                .toolboxFont(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        }
                                    }

                                    Spacer(minLength: 8)
                                }
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 260)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
            }
        }
    }

    private func categoryChip(title: String, category: DeveloperEventCategory?) -> some View {
        let selected = uiState.selectedCategory == category
        return Button {
            uiState.selectedCategory = category
        } label: {
            Text(title)
                .toolboxFont(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(
                    selected ? Color.accentColor : Color.primary.opacity(0.06),
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerCursor()
    }

    private var scrollTapMonitorSection: some View {
        FeatureSection(
            "Scroll Event Tap & Keep Awake Internals",
            subtitle: "Live CoreGraphics scrollWheel tap statistics and macOS power assertion / idle state."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Scroll Direction Event Tap")
                        .toolboxFont(.callout.weight(.medium))
                    Spacer()
                    StatusBadge(
                        text: scrollModule.isTapInstalled ? "Tap Active" : "Tap Inactive",
                        color: scrollModule.isTapInstalled ? .green : .secondary
                    )
                }

                Divider()

                HStack(spacing: 16) {
                    metricBlock("Events Observed", value: "\(scrollModule.eventsObserved)")
                    metricBlock("Events Inverted", value: "\(scrollModule.eventsInverted)")
                    metricBlock("Last Observed", value: scrollModule.lastObservedClass?.label ?? "None")
                    metricBlock("Last Inverted", value: scrollModule.lastInvertedClass?.label ?? "None")
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep Awake Assertion & Idle Monitor")
                            .toolboxFont(.callout.weight(.medium))
                        Text(keepAwakeModule.powerInfo.summaryText)
                            .toolboxFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(
                        text: keepAwakeModule.isAwakeActive ? "Active" : "Standby",
                        color: keepAwakeModule.isAwakeActive ? .orange : .secondary
                    )
                }

                HStack(spacing: 16) {
                    metricBlock("Idle Seconds", value: "\(keepAwakeModule.currentIdleSeconds)s")
                    metricBlock("Jiggles Fired", value: "\(keepAwakeModule.jiggleCount)")
                    metricBlock("Accessibility", value: permissions.actualAccessibilityGranted ? "Trusted" : "Not Granted")
                }
            }
        }
    }

    private var dockWindowStackSection: some View {
        FeatureSection(
            "Live Window Z-Order Stack",
            subtitle: "Front-to-back CGWindowListCopyWindowInfo layer-0 regular apps inspected by Dock Click to Minimize."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Toggle("Auto-refresh (1.5s)", isOn: $uiState.autoRefreshStack)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .pointerCursor()

                    Spacer()

                    if let captured = uiState.stackCapturedAt {
                        Text("Updated \(captured.formatted(date: .omitted, time: .standard))")
                            .toolboxFont(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Button("Refresh Stack") {
                        refreshWindowStack()
                    }
                    .buttonStyle(.toolboxProminent)
                    .controlSize(.small)
                    .pointerCursor()
                }

                Divider()

                if uiState.windowStack.isEmpty {
                    Text("No visible regular application windows reported on this Space.")
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(Array(uiState.windowStack.prefix(12).enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider()
                        }
                        HStack(spacing: 10) {
                            Text("#\(index + 1)")
                                .toolboxFont(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .leading)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.appName)
                                    .toolboxFont(.callout.weight(.medium))
                                Text("\(item.bundleIdentifier ?? "(no bundle id)") · PID \(item.pid)")
                                    .toolboxFont(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if item.isFrontmost {
                                StatusBadge(text: "Frontmost", color: .blue)
                            }
                            if item.isHidden {
                                StatusBadge(text: "Hidden", color: .orange)
                            }
                        }
                    }
                }
            }
        }
    }

    private func metricBlock(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .toolboxFont(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .toolboxFont(.caption.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refreshWindowStack() {
        uiState.windowStack = ModuleRegistry.shared.dockMinimize.liveWindowStackSnapshot()
        uiState.stackCapturedAt = Date()
    }

    private func categoryColor(_ category: DeveloperEventCategory) -> Color {
        switch category {
        case .dock: return .blue
        case .scroll: return .pink
        case .hotkeys: return .purple
        case .keepAwake: return .orange
        case .cleanLock: return .red
        case .callControls: return .mint
        case .windowSnapper: return .indigo
        case .finderEnhancer: return .blue
        case .ocr: return .cyan
        case .config: return .teal
        case .updates: return .green
        }
    }
}

// MARK: - HotKeys & Config View

@MainActor
private final class HotKeysAndConfigUIState: ObservableObject {
    @Published var testShortcut = ShortcutSpec.none
    @Published var diffMode: Int = 0 // 0 = Saved Checkpoint, 1 = Disk config.json
    @Published var selectedResetSection: ToolboxConfigSection = .general
}

struct DeveloperHotKeysAndConfigView: View {
    @ObservedObject private var hotKeys = HotKeyManager.shared
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var checkpoints = ConfigCheckpointStore.shared
    @StateObject private var uiState = HotKeysAndConfigUIState()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            registeredHotKeysSection
            conflictTesterSection
            configCheckpointSection
        }
    }

    private var registeredHotKeysSection: some View {
        let registrations = hotKeys.registeredHotKeys
        return FeatureSection(
            "Registered Carbon HotKeys",
            subtitle: "Live bindings inside HotKeyManager. Click Trigger to fire a registered handler without pressing keys."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if !hotKeys.registrationErrors.isEmpty {
                    ForEach(hotKeys.registrationErrors.sorted(by: { $0.key < $1.key }), id: \.key) { name, message in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("\(name): \(message)")
                                .toolboxFont(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Divider()
                }

                if registrations.isEmpty {
                    Text("No active global hotkeys are currently registered.")
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(Array(registrations.enumerated()), id: \.element.id) { index, reg in
                        if index > 0 {
                            Divider()
                        }
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(reg.name)
                                        .toolboxFont(.callout.weight(.medium))
                                    StatusBadge(
                                        text: reg.isArmed ? "Armed" : "Suspended",
                                        color: reg.isArmed ? .green : .orange
                                    )
                                }
                                Text("ID #\(reg.id) · keyCode: \(reg.shortcut.carbonKeyCode.map(String.init) ?? "n/a")")
                                    .toolboxFont(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            ShortcutPill(shortcut: reg.shortcut)

                            Button("Trigger") {
                                _ = hotKeys.simulateTrigger(name: reg.name)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointerCursor()
                        }
                    }
                }
            }
        }
    }

    private var conflictTesterSection: some View {
        let cfg = configManager.config
        let inAppConflict = uiState.testShortcut.isEmpty
            ? nil
            : hotKeys.inAppConflictDescription(for: uiState.testShortcut, excludingSourceID: "__dev_probe__", in: cfg)
        let systemConflict = uiState.testShortcut.isEmpty
            ? nil
            : hotKeys.systemOrMenuConflictDescription(for: uiState.testShortcut)

        return FeatureSection(
            "Shortcut Conflict Probe",
            subtitle: "Record any key combination to check collisions against Toolbox bindings and reserved macOS shortcuts without saving."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(
                    "Probe Shortcut",
                    subtitle: "Press any shortcut combo to test conflict rules."
                ) {
                    ShortcutRecorderView(
                        shortcut: uiState.testShortcut,
                        showConflictWarnings: false
                    ) { next in
                        uiState.testShortcut = next
                    }
                }

                if !uiState.testShortcut.isEmpty {
                    Divider()

                    HStack(spacing: 8) {
                        if inAppConflict == nil && systemConflict == nil {
                            StatusBadge(text: "Clear", color: .green)
                            Text("\(uiState.testShortcut.displayString) has no detected in-app or reserved macOS conflicts.")
                                .toolboxFont(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            StatusBadge(text: "Conflict", color: .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                if let inAppConflict {
                                    Text("In-App: \(inAppConflict)")
                                        .toolboxFont(.caption)
                                        .foregroundStyle(.orange)
                                }
                                if let systemConflict {
                                    Text("macOS / Menu: \(systemConflict)")
                                        .toolboxFont(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var configCheckpointSection: some View {
        let diffs: [ConfigDiffItem] = uiState.diffMode == 0
            ? checkpoints.diffsAgainstCheckpoint(current: configManager.config)
            : checkpoints.diffsAgainstDisk(current: configManager.config)

        return FeatureSection(
            "Config Checkpoint, Diff & Section Reset",
            subtitle: "Snapshot config.json in memory before testing changes, inspect key-path diffs, or reset a single module."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(
                    "In-Memory Checkpoint",
                    subtitle: checkpoints.checkpointSavedAt.map {
                        "Saved \($0.formatted(date: .omitted, time: .standard))"
                    } ?? "No checkpoint saved yet for this session."
                ) {
                    HStack(spacing: 8) {
                        Button("Save Checkpoint") {
                            checkpoints.saveCheckpoint()
                            HUDToast.shared.show(title: "Saved config checkpoint", symbol: "bookmark.fill", tint: .blue)
                        }
                        .buttonStyle(.toolboxProminent)
                        .controlSize(.small)
                        .pointerCursor()

                        if checkpoints.checkpointConfig != nil {
                            Button("Restore") {
                                if checkpoints.restoreCheckpoint() {
                                    HUDToast.shared.show(title: "Restored config checkpoint", symbol: "arrow.uturn.backward", tint: .green)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointerCursor()
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Live Config Diff")
                            .toolboxFont(.callout.weight(.medium))
                        Spacer()
                        Picker("", selection: $uiState.diffMode) {
                            Text("vs Checkpoint").tag(0)
                            Text("vs Disk").tag(1)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 210)
                        .pointerCursor()
                    }

                    if uiState.diffMode == 0 && checkpoints.checkpointConfig == nil {
                        Text("Save a checkpoint above to track diffs as you modify settings.")
                            .toolboxFont(.caption)
                            .foregroundStyle(.secondary)
                    } else if diffs.isEmpty {
                        HStack(spacing: 6) {
                            StatusBadge(text: "In Sync", color: .green)
                            Text(uiState.diffMode == 0 ? "Live config matches saved checkpoint." : "Live config matches config.json on disk.")
                                .toolboxFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(diffs) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(item.keyPath)
                                        .toolboxFont(.caption2.monospaced().weight(.semibold))
                                    Spacer(minLength: 8)
                                    Text("\(item.baselineValue) → \(item.currentValue)")
                                        .toolboxFont(.caption2.monospaced())
                                        .foregroundStyle(.orange)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                }

                Divider()

                SettingRow(
                    "Reset Single Config Section",
                    subtitle: "Restores defaults for the chosen module only, leaving all other settings untouched."
                ) {
                    HStack(spacing: 8) {
                        Picker("", selection: $uiState.selectedResetSection) {
                            ForEach(ToolboxConfigSection.allCases) { sec in
                                Text(sec.label).tag(sec)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        .pointerCursor()

                        Button("Reset Section") {
                            checkpoints.resetSection(uiState.selectedResetSection)
                            HUDToast.shared.show(
                                title: "Reset \(uiState.selectedResetSection.label) defaults",
                                symbol: "arrow.counterclockwise",
                                tint: .orange
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()
                    }
                }
            }
        }
    }
}
