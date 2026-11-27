import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class WindowSwitcherSettingsInputState: ObservableObject {
    @Published var newBundleID = ""
    @Published var showExcludedSection = false
    @Published var showManualBundleEntry = false
    @Published var entryError: String?
}

struct WindowSwitcherSettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @StateObject private var inputState = WindowSwitcherSettingsInputState()
    @ObservedObject var module: WindowSwitcherModule

    private var cfg: WindowSwitcherConfig {
        configManager.config.windowSwitcher
    }

    private var runningRegularApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular,
                      let bundleID = app.bundleIdentifier,
                      !bundleID.isEmpty else {
                    return false
                }
                return true
            }
            .sorted {
                ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if permissions.isAccessibilityGranted, let err = module.lastError {
                SectionCard(accentTint: .orange) {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .toolboxFont(.callout)
                        .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                }
            }

            shortcutAndTriggerSection
            appearanceAndActionsSection
            windowsShownSection
        }
        .onAppear {
            module.refreshScreenPermission()
            module.probeLiveScreenPermission()
        }
    }

    // MARK: - Shortcut & Trigger

    private var shortcutAndTriggerSection: some View {
        FeatureSection(
            "Shortcut & Trigger",
            subtitle: "Hold the modifier and press Tab to cycle windows; release to switch."
        ) {
            SettingRow(
                "Trigger Modifier",
                subtitle: cfg.triggerModifier.explanation
            ) {
                ToolboxSegmentedControl(
                    options: Array(SwitcherTriggerModifier.allCases),
                    selection: $configManager.config.windowSwitcher.triggerModifier,
                    accentColor: module.accentColor,
                    label: { $0.label },
                    symbol: { _ in nil }
                )
                .pointerCursor()
            }

            if cfg.triggerModifier == .command {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .toolboxFont(.caption)
                        .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                    Text("Using ⌘ Command replaces macOS's native ⌘ Tab application switcher while Window Switcher is enabled.")
                        .toolboxFont(.caption)
                        .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }

            Divider()

            SettingRow(
                "Current App Windows Only",
                subtitle: "Optional global shortcut to open the switcher filtered to windows of the active app."
            ) {
                ShortcutRecorderView(
                    shortcut: configManager.config.windowSwitcher.currentAppOnlyShortcut,
                    defaultShortcut: ShortcutSpec.none,
                    sourceID: "window_switcher.current_app",
                    registrationKey: module.currentAppHotKeyName
                ) { newShortcut in
                    configManager.config.windowSwitcher.currentAppOnlyShortcut = newShortcut
                }
            }

            Divider()

            SettingRow(
                "Test HUD",
                subtitle: "Open the switcher overlay now to inspect your layout and thumbnails."
            ) {
                Button {
                    module.openPreviewHUD()
                } label: {
                    Label("Preview Switcher", systemImage: "rectangle.stack")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!configManager.config.general.appEnabled)
                .pointerCursor(configManager.config.general.appEnabled)
            }
        }
        .id(ModuleFocusAnchor.shortcuts.rawValue)
    }

    // MARK: - Appearance & Actions

    private var appearanceAndActionsSection: some View {
        FeatureSection(
            "Appearance & Actions",
            subtitle: "Choose a ⌘ Tab-style thumbnail strip or compact list, plus keyboard quick actions."
        ) {
            SettingRow(
                "Switcher Style",
                subtitle: "Thumbnail Strip mirrors macOS ⌘ Tab horizontally; Compact List shows vertical window rows."
            ) {
                ToolboxSegmentedControl(
                    options: Array(SwitcherLayoutStyle.allCases),
                    selection: $configManager.config.windowSwitcher.layoutStyle,
                    accentColor: module.accentColor,
                    label: { $0.label },
                    symbol: { $0.symbolName }
                )
                .pointerCursor()
            }

            Divider()

            SettingRow(
                "Live Window Thumbnails",
                subtitle: "Shows live window previews like ⌘ Tab when Screen Recording is granted; falls back cleanly to app icons otherwise."
            ) {
                Toggle("", isOn: $configManager.config.windowSwitcher.showThumbnails)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            if cfg.showThumbnails && !module.screenRecordingGranted {
                Divider()

                SettingRow(
                    "Screen Recording Permission",
                    subtitle: "Optional for thumbnails only. Toolbox never prompts unexpectedly while cycling windows."
                ) {
                    HStack(spacing: 8) {
                        StatusBadge(
                            text: module.isAwaitingScreenPermission ? "Waiting…" : "Not Granted",
                            color: .orange
                        )

                        Button("Grant Access…") {
                            module.requestScreenAccess()
                        }
                        .buttonStyle(.toolboxProminent(.orange))
                        .controlSize(.regular)
                        .focusEffectDisabled()
                        .pointerCursor()

                        Button("Open Settings") {
                            module.openScreenSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .focusEffectDisabled()
                        .pointerCursor()
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            Divider()

            SettingRow(
                "Quick Actions (W / M / H / Q)",
                subtitle: "While the HUD is open, press W to close, M to minimize/restore, H to hide, Q to quit, or / to filter."
            ) {
                Toggle("", isOn: $configManager.config.windowSwitcher.enableQuickActions)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }
        }
    }

    // MARK: - Windows Shown

    private var windowsShownSection: some View {
        FeatureSection(
            "Windows Shown",
            subtitle: "Control which windows appear in the switcher."
        ) {
            SettingRow(
                "Include Minimized Windows",
                subtitle: "List minimized Dock windows and restore them automatically when selected."
            ) {
                Toggle("", isOn: $configManager.config.windowSwitcher.includeMinimized)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            Divider()

            SettingRow(
                "Include Hidden Apps",
                subtitle: "Show windows belonging to apps hidden via ⌘ H or Dock Click to Minimize."
            ) {
                Toggle("", isOn: $configManager.config.windowSwitcher.includeHiddenApps)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            Divider()

            SettingRow(
                "Active Space Only",
                subtitle: "Only show visible on-screen windows on your current macOS desktop Space (excludes minimized and hidden windows)."
            ) {
                Toggle("", isOn: $configManager.config.windowSwitcher.activeSpaceOnly)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            Divider()

            SettingRow(
                "Active Display Only",
                subtitle: "Only show windows located on the monitor under your cursor."
            ) {
                Toggle("", isOn: $configManager.config.windowSwitcher.activeDisplayOnly)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            Divider()

            excludedAppsDisclosure
        }
    }

    private var excludedAppsDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    inputState.showExcludedSection.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            Text("Excluded Applications")
                                .toolboxFont(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                            if !cfg.excludedBundleIDs.isEmpty {
                                Text("\(cfg.excludedBundleIDs.count)")
                                    .toolboxFont(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(ToolboxTheme.readableAccentText(for: module.accentColor))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(module.accentColor.opacity(0.18), in: Capsule())
                            }
                        }
                        Text(cfg.excludedBundleIDs.isEmpty
                             ? "Hide specific apps from Window Switcher."
                             : "\(cfg.excludedBundleIDs.count) excluded app(s).")
                            .toolboxFont(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Text(inputState.showExcludedSection ? "Hide" : "Configure")
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .toolboxFont(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(inputState.showExcludedSection ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerCursor()

            if inputState.showExcludedSection {
                excludedAppsContent
            }
        }
    }

    private var excludedAppsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    excludedAppsActionControls
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    excludedAppsActionControls
                }
            }

            if inputState.showManualBundleEntry {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Bundle ID (e.g. com.apple.Preview)", text: $inputState.newBundleID)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: inputState.newBundleID) {
                                if inputState.entryError != nil {
                                    inputState.entryError = nil
                                }
                            }
                            .onSubmit {
                                submitManualBundleID()
                            }

                        let hasInput = !inputState.newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        Button("Add") {
                            submitManualBundleID()
                        }
                        .buttonStyle(.toolboxProminent)
                        .disabled(!hasInput)
                        .pointerCursor(hasInput)
                    }

                    if let entryError = inputState.entryError {
                        Label(entryError, systemImage: "exclamationmark.circle.fill")
                            .toolboxFont(.caption)
                            .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                    }
                }
            } else if let entryError = inputState.entryError {
                Label(entryError, systemImage: "exclamationmark.circle.fill")
                    .toolboxFont(.caption)
                    .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
            }

            if cfg.excludedBundleIDs.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .toolboxFont(.callout)
                        .foregroundStyle(.secondary)
                    Text("No excluded apps. Windows from all regular apps are eligible.")
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            } else {
                VStack(spacing: 6) {
                    ForEach(cfg.excludedBundleIDs, id: \.self) { bundleID in
                        excludedAppRow(bundleID: bundleID)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var excludedAppsActionControls: some View {
        Menu("Add Running App…") {
            if runningRegularApps.isEmpty {
                Text("No running apps found")
            } else {
                ForEach(runningRegularApps, id: \.processIdentifier) { app in
                    if let bundleID = app.bundleIdentifier {
                        let alreadyAdded = isBundleExcluded(bundleID)
                        let label = alreadyAdded
                            ? "\(app.localizedName ?? bundleID) (Excluded)"
                            : (app.localizedName ?? bundleID)
                        Button(label) {
                            addExcludedBundleID(bundleID, validateFormat: false)
                        }
                        .disabled(alreadyAdded)
                    }
                }
            }
        }
        .pointerCursor()

        Button("Choose Application…") {
            pickAppBundle()
        }
        .pointerCursor()

        Button(inputState.showManualBundleEntry ? "Hide Bundle ID" : "Enter Bundle ID…") {
            withAnimation(.easeInOut(duration: 0.16)) {
                inputState.showManualBundleEntry.toggle()
                inputState.entryError = nil
            }
        }
        .buttonStyle(.borderless)
        .toolboxFont(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
        .pointerCursor()
    }

    private func excludedAppRow(bundleID: String) -> some View {
        let appIcon: NSImage? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            NSWorkspace.shared.icon(forFile: $0.path)
        }
        let appName = resolvedAppName(for: bundleID)

        return HStack(spacing: 10) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 24, height: 24)
                    Image(systemName: "app.dashed")
                        .toolboxFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let appName {
                VStack(alignment: .leading, spacing: 1) {
                    Text(appName)
                        .toolboxFont(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(bundleID)
                        .toolboxFont(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text(bundleID)
                    .toolboxFont(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button {
                removeExcludedBundleID(bundleID)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .toolboxFont(.callout)
                    .foregroundStyle(ToolboxTheme.readableAccentText(for: .red).opacity(0.9))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuRowHover(cornerRadius: 6)
            .help("Remove \(appName ?? bundleID) from exclusions")
            .accessibilityLabel("Remove \(appName ?? bundleID)")
            .pointerCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
    }

    // MARK: - Helpers

    private func pickAppBundle() {
        let panel = NSOpenPanel()
        panel.title = "Choose Application to Exclude"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let bundleID = Bundle(url: url)?.bundleIdentifier {
                    addExcludedBundleID(bundleID, validateFormat: false)
                }
            }
        }
    }

    private func resolvedAppName(for bundleID: String) -> String? {
        if let running = runningRegularApps.first(where: {
            $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame
        })?.localizedName {
            return running
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url) {
            return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        }
        return nil
    }

    private func isBundleExcluded(_ bundleID: String) -> Bool {
        cfg.excludedBundleIDs.contains {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }
    }

    private func submitManualBundleID() {
        if addExcludedBundleID(inputState.newBundleID, validateFormat: true) {
            inputState.newBundleID = ""
            inputState.entryError = nil
        }
    }

    @discardableResult
    private func addExcludedBundleID(_ raw: String, validateFormat: Bool) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if validateFormat && !Self.isLikelyBundleID(trimmed) {
            inputState.entryError = "Enter a valid bundle ID such as com.apple.Preview."
            return false
        }

        if isBundleExcluded(trimmed) {
            inputState.entryError = "\(trimmed) is already excluded."
            return false
        }

        configManager.config.windowSwitcher.excludedBundleIDs.append(trimmed)
        inputState.entryError = nil
        return true
    }

    private func removeExcludedBundleID(_ bundleID: String) {
        configManager.config.windowSwitcher.excludedBundleIDs.removeAll {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }
    }

    private static func isLikelyBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}
