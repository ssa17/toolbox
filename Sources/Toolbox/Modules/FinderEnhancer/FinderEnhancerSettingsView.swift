import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class FinderEnhancerSettingsInputState: ObservableObject {
    @Published var newBundleID = ""
    @Published var showManualBundleEntry = false
    @Published var entryError: String?
}

struct FinderEnhancerSettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @StateObject private var inputState = FinderEnhancerSettingsInputState()
    @ObservedObject var module: FinderEnhancerModule

    private var cfg: FinderEnhancerConfig {
        configManager.config.finderEnhancer
    }

    private var currentAppList: [String] {
        switch cfg.autoQuitMode {
        case .allowlistOnly:
            return cfg.autoQuitAllowlistBundleIDs
        case .allExceptExcluded:
            return cfg.autoQuitExcludedBundleIDs
        }
    }

    private var runningEligibleApps: [NSRunningApplication] {
        let selfBundleID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular,
                      let bundleID = app.bundleIdentifier,
                      !LastWindowQuitPolicy.isProtected(bundleID: bundleID, selfBundleID: selfBundleID) else {
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

            if cfg.enabled && configManager.config.general.appEnabled && permissions.isAccessibilityGranted {
                liveStatusCard
            }

            FeatureSection(
                "Finder Cut & Paste",
                subtitle: "Move files in Finder with familiar ⌘ X and ⌘ V shortcuts."
            ) {
                SettingRow(
                    "Enable ⌘ X / ⌘ V file move",
                    subtitle: "Press ⌘ X on selected items in Finder, then ⌘ V to move them using Finder's native Move Item Here."
                ) {
                    Toggle("", isOn: $configManager.config.finderEnhancer.enableCutAndPaste)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                }

                Divider()

                SettingRow(
                    "Show toast on cut",
                    subtitle: "Display a brief HUD pill confirming how many items are ready to move."
                ) {
                    Toggle("", isOn: $configManager.config.finderEnhancer.showCutToast)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .disabled(!cfg.enableCutAndPaste)
                        .pointerCursor(cfg.enableCutAndPaste)
                }
                .opacity(cfg.enableCutAndPaste ? 1.0 : 0.55)
            }

            FeatureSection(
                "Finder Navigation",
                subtitle: "Customize Return and F2 in Finder file lists without interrupting inline renaming, search, or dialogs."
            ) {
                SettingRow(
                    "Return opens selected item",
                    subtitle: "Press Return to open selected files or folders (⌘ O) instead of starting rename."
                ) {
                    Toggle("", isOn: $configManager.config.finderEnhancer.enableReturnToOpen)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                }

                Divider()

                SettingRow(
                    "F2 renames selected item",
                    subtitle: "Press F2 to begin inline filename editing when no text field or sheet is focused."
                ) {
                    Toggle("", isOn: $configManager.config.finderEnhancer.enableF2ToRename)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                }
            }

            FeatureSection(
                "Auto-Quit on Last Window Close",
                subtitle: "Gracefully quit applications after their last open window closes. Minimized and fullscreen windows keep the app running."
            ) {
                SettingRow(
                    "Enable Auto-Quit",
                    subtitle: "Uses standard app termination so unsaved-document prompts can cancel safely."
                ) {
                    Toggle("", isOn: $configManager.config.finderEnhancer.enableAutoQuitOnLastWindowClose)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                }

                Divider()

                SettingRow(
                    "App Scope",
                    subtitle: cfg.autoQuitMode.explanation
                ) {
                    ToolboxSegmentedControl(
                        options: Array(AutoQuitAppMode.allCases),
                        selection: $configManager.config.finderEnhancer.autoQuitMode,
                        accentColor: module.accentColor,
                        label: { $0.label },
                        symbol: { $0 == .allowlistOnly ? "checkmark.shield" : "nosign" }
                    )
                    .disabled(!cfg.enableAutoQuitOnLastWindowClose)
                    .pointerCursor(cfg.enableAutoQuitOnLastWindowClose)
                }
                .opacity(cfg.enableAutoQuitOnLastWindowClose ? 1.0 : 0.55)

                Divider()

                SettingRow(
                    "Grace delay",
                    subtitle: "Wait briefly after the last window closes before requesting quit."
                ) {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(cfg.autoQuitDelayMs) },
                                set: { newVal in
                                    configManager.config.finderEnhancer.autoQuitDelayMs = FinderEnhancerConfig.clampedAutoQuitDelayMs(Int(newVal.rounded()))
                                }
                            ),
                            in: Double(FinderEnhancerConfig.minAutoQuitDelayMs)...Double(FinderEnhancerConfig.maxAutoQuitDelayMs),
                            step: 50
                        )
                        .frame(width: 150)
                        .tint(module.accentColor)
                        .disabled(!cfg.enableAutoQuitOnLastWindowClose)
                        .pointerCursor(cfg.enableAutoQuitOnLastWindowClose)

                        Text("\(cfg.autoQuitDelayMs) ms")
                            .toolboxFont(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                            .frame(minWidth: 64)
                    }
                }
                .opacity(cfg.enableAutoQuitOnLastWindowClose ? 1.0 : 0.55)

                Divider()

                autoQuitAppListBlock
            }
        }
    }

    // MARK: - Live Status Card

    private var liveStatusCard: some View {
        SectionCard(accentTint: module.accentColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Label("Live Runtime Status", systemImage: "waveform.path.ecg")
                        .toolboxFont(.callout.weight(.semibold))
                        .foregroundStyle(ToolboxTheme.readableAccentText(for: module.accentColor))

                    Spacer(minLength: 8)

                    if module.armedCutItemCount > 0 {
                        Button("Disarm Cut") {
                            module.disarmCutState()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        statusPill(
                            title: "Finder Tap",
                            value: cfg.needsKeyTap ? (module.isKeyTapInstalled ? "Active" : "Standby") : "Off",
                            tint: (cfg.needsKeyTap && module.isKeyTapInstalled) ? .green : .secondary
                        )
                        statusPill(
                            title: "Cut State",
                            value: module.armedCutItemCount > 0 ? "Armed (\(module.armedCutItemCount))" : "Idle",
                            tint: module.armedCutItemCount > 0 ? .blue : .secondary
                        )
                        statusPill(
                            title: "Auto-Quit",
                            value: cfg.enableAutoQuitOnLastWindowClose ? "Watching \(module.watchedAutoQuitAppCount)" : "Off",
                            tint: cfg.enableAutoQuitOnLastWindowClose ? .mint : .secondary
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        statusPill(
                            title: "Finder Tap",
                            value: cfg.needsKeyTap ? (module.isKeyTapInstalled ? "Active" : "Standby") : "Off",
                            tint: (cfg.needsKeyTap && module.isKeyTapInstalled) ? .green : .secondary
                        )
                        statusPill(
                            title: "Cut State",
                            value: module.armedCutItemCount > 0 ? "Armed (\(module.armedCutItemCount))" : "Idle",
                            tint: module.armedCutItemCount > 0 ? .blue : .secondary
                        )
                        statusPill(
                            title: "Auto-Quit",
                            value: cfg.enableAutoQuitOnLastWindowClose ? "Watching \(module.watchedAutoQuitAppCount)" : "Off",
                            tint: cfg.enableAutoQuitOnLastWindowClose ? .mint : .secondary
                        )
                    }
                }

                let totalActions = module.movesCompletedCount + module.itemsOpenedCount + module.itemsRenamedCount + module.appsAutoQuitCount
                if totalActions > 0 {
                    Text("Session activity: \(module.movesCompletedCount) moved · \(module.itemsOpenedCount) opened · \(module.itemsRenamedCount) renamed · \(module.appsAutoQuitCount) auto-quit")
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusPill(title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text("\(title):")
                .toolboxFont(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .toolboxFont(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
    }

    // MARK: - Auto-Quit App List

    private var autoQuitAppListBlock: some View {
        let isAllowlist = (cfg.autoQuitMode == .allowlistOnly)
        let headerTitle = isAllowlist ? "Allowed Applications" : "Excluded Applications"
        let headerSubtitle = isAllowlist
            ? "Only these apps will quit automatically when their last window closes."
            : "Apps listed here stay running even after their last window closes."
        let allowlistDiffersFromDefault = isAllowlist
            && cfg.autoQuitAllowlistBundleIDs != FinderEnhancerConfig.defaultAllowlistBundleIDs

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .toolboxFont(.callout.weight(.semibold))
                    Text(headerSubtitle)
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if allowlistDiffersFromDefault {
                    Button("Reset Defaults") {
                        configManager.config.finderEnhancer.autoQuitAllowlistBundleIDs = FinderEnhancerConfig.defaultAllowlistBundleIDs
                        inputState.entryError = nil
                    }
                    .buttonStyle(.borderless)
                    .toolboxFont(.caption.weight(.medium))
                    .foregroundStyle(ToolboxTheme.readableAccentText(for: module.accentColor))
                    .pointerCursor()
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    appListActionControls
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    appListActionControls
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

            if currentAppList.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: isAllowlist ? "tray" : "checkmark.circle")
                        .toolboxFont(.callout)
                        .foregroundStyle(.secondary)
                    Text(isAllowlist
                         ? "Allowlist is empty. No apps will auto-quit until you add one."
                         : "No excluded apps. All regular non-system apps will auto-quit when their last window closes.")
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            } else {
                VStack(spacing: 6) {
                    ForEach(currentAppList, id: \.self) { bundleID in
                        appRow(bundleID: bundleID, isAllowlist: isAllowlist)
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .toolboxFont(.caption)
                    .foregroundStyle(.secondary)
                Text("Finder, Dock, Toolbox, and macOS system UI processes are always protected and never auto-quit.")
                    .toolboxFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .onChange(of: cfg.autoQuitMode) {
            inputState.entryError = nil
        }
    }

    @ViewBuilder
    private var appListActionControls: some View {
        Menu("Add Running App…") {
            if runningEligibleApps.isEmpty {
                Text("No other running apps")
            } else {
                ForEach(runningEligibleApps, id: \.processIdentifier) { app in
                    if let bundleID = app.bundleIdentifier {
                        let alreadyAdded = isBundleInCurrentList(bundleID)
                        let label = alreadyAdded
                            ? "\(app.localizedName ?? bundleID) (Added)"
                            : (app.localizedName ?? bundleID)
                        Button(label) {
                            addBundleID(bundleID, validateBundleFormat: false)
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

    private func appRow(bundleID: String, isAllowlist: Bool) -> some View {
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
                removeBundleID(bundleID)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .toolboxFont(.callout)
                    .foregroundStyle(ToolboxTheme.readableAccentText(for: .red).opacity(0.9))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuRowHover(cornerRadius: 6)
            .help("Remove \(appName ?? bundleID) from \(isAllowlist ? "allowlist" : "exclusions")")
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

    // MARK: - List Management Helpers

    private func pickAppBundle() {
        let panel = NSOpenPanel()
        panel.title = cfg.autoQuitMode == .allowlistOnly
            ? "Choose Application to Auto-Quit"
            : "Choose Application to Exclude"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let bundleID = Bundle(url: url)?.bundleIdentifier {
                    addBundleID(bundleID, validateBundleFormat: false)
                }
            }
        }
    }

    private func resolvedAppName(for bundleID: String) -> String? {
        if let running = runningEligibleApps.first(where: {
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

    private func isBundleInCurrentList(_ bundleID: String) -> Bool {
        currentAppList.contains {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }
    }

    private func submitManualBundleID() {
        if addBundleID(inputState.newBundleID, validateBundleFormat: true) {
            inputState.newBundleID = ""
            inputState.entryError = nil
        }
    }

    @discardableResult
    private func addBundleID(_ raw: String, validateBundleFormat: Bool) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if validateBundleFormat && !Self.isLikelyBundleID(trimmed) {
            inputState.entryError = "Enter a valid bundle ID such as com.apple.Preview."
            return false
        }

        if LastWindowQuitPolicy.isProtected(bundleID: trimmed) {
            inputState.entryError = "\(trimmed) is a protected system app and cannot be added."
            return false
        }

        if isBundleInCurrentList(trimmed) {
            inputState.entryError = "\(trimmed) is already in this list."
            return false
        }

        switch cfg.autoQuitMode {
        case .allowlistOnly:
            configManager.config.finderEnhancer.autoQuitAllowlistBundleIDs.append(trimmed)
        case .allExceptExcluded:
            configManager.config.finderEnhancer.autoQuitExcludedBundleIDs.append(trimmed)
        }
        inputState.entryError = nil
        return true
    }

    private func removeBundleID(_ bundleID: String) {
        switch cfg.autoQuitMode {
        case .allowlistOnly:
            configManager.config.finderEnhancer.autoQuitAllowlistBundleIDs.removeAll {
                $0.caseInsensitiveCompare(bundleID) == .orderedSame
            }
        case .allExceptExcluded:
            configManager.config.finderEnhancer.autoQuitExcludedBundleIDs.removeAll {
                $0.caseInsensitiveCompare(bundleID) == .orderedSame
            }
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
