import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class DockSettingsInputState: ObservableObject {
    @Published var newBundleID = ""
    @Published var showManualBundleEntry = false
    @Published var entryError: String?
}

struct DockMinimizeSettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var inputState = DockSettingsInputState()
    @ObservedObject var module: DockMinimizeModule

    private var runningApps: [NSRunningApplication] {
        let selfBundleID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular
                    && $0.bundleIdentifier != nil
                    && $0.bundleIdentifier != selfBundleID
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
                        .font(.callout)
                        .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                }
            }

            FeatureCardGridSection("Click Action", subtitle: "What happens when you click the active app's Dock icon.") {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        clickActionCard(
                            mode: .hideApp,
                            title: "Hide & Restore",
                            badge: "Windows Style",
                            symbol: "eye.slash.fill"
                        )
                        clickActionCard(
                            mode: .sendToBack,
                            title: "Send Behind App",
                            badge: "Keep Visible",
                            symbol: "square.2.layers.3d.bottom.filled"
                        )
                    }
                    GridRow {
                        clickActionCard(
                            mode: .minimizeAll,
                            title: "Minimize All Windows",
                            badge: "Dock Tray",
                            symbol: "rectangle.stack.badge.minus"
                        )
                        clickActionCard(
                            mode: .minimizeFrontWindow,
                            title: "Minimize Front Window",
                            badge: "Single Window",
                            symbol: "rectangle.badge.minus"
                        )
                    }
                }
            }

            FeatureSection("Trigger & Modifiers", subtitle: "Fine-tune how Dock clicks are recognized.") {
                SettingRow(
                    "Activation click",
                    subtitle: "Single-click acts right away; double-click preserves normal single-click switching."
                ) {
                    ToolboxSegmentedControl(
                        options: Array(DockClickMode.allCases),
                        selection: $configManager.config.dockMinimize.clickMode,
                        accentColor: module.accentColor,
                        label: { $0.label },
                        symbol: { $0 == .singleClick ? "cursorarrow.click" : "cursorarrow.click.2" }
                    )
                }

                Divider()

                SettingRow(
                    "Ignore modified clicks",
                    subtitle: "Hold ⌘, ⌥, ⌃, or ⇧ to keep native macOS Dock click behaviors."
                ) {
                    Toggle("", isOn: $configManager.config.dockMinimize.ignoreModifiedClicks)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                }

                Divider()

                SettingRow(
                    "Toggle shortcut",
                    subtitle: "Optional global shortcut to turn Dock Click to Minimize on or off."
                ) {
                    ShortcutRecorderView(
                        shortcut: configManager.config.dockMinimize.shortcut,
                        defaultShortcut: ShortcutSpec.none,
                        sourceID: "dock_minimize",
                        registrationKey: module.hotKeyName
                    ) { newShortcut in
                        configManager.config.dockMinimize.shortcut = newShortcut
                    }
                }
            }

            FeatureSection("Excluded Applications", subtitle: "Apps listed here keep default macOS Dock click behavior.") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Menu("Add Running App…") {
                            if runningApps.isEmpty {
                                Text("No other running apps")
                            } else {
                                ForEach(runningApps, id: \.processIdentifier) { app in
                                    if let bundleID = app.bundleIdentifier {
                                        let isExcluded = isBundleExcluded(bundleID)
                                        Button(isExcluded ? "\(app.localizedName ?? bundleID) (Excluded)" : (app.localizedName ?? bundleID)) {
                                            addExclusion(bundleID, validateBundleFormat: false)
                                        }
                                        .disabled(isExcluded)
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
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .pointerCursor()

                        Spacer(minLength: 0)
                    }

                    if inputState.showManualBundleEntry {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("Bundle ID (e.g. com.apple.finder)", text: $inputState.newBundleID)
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
                                    .font(.caption)
                                    .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                            }
                        }
                    }
                }

                Divider()

                if configManager.config.dockMinimize.excludedBundleIDs.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("No excluded apps. Works for all apps including Finder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } else {
                    VStack(spacing: 6) {
                        ForEach(configManager.config.dockMinimize.excludedBundleIDs, id: \.self) { bundleID in
                            excludedAppRow(bundleID: bundleID)
                        }
                    }
                }
            }
        }
    }

    private func clickActionCard(
        mode: DockActionMode,
        title: String,
        badge: String?,
        symbol: String
    ) -> some View {
        SelectableOptionCard(
            title: title,
            subtitle: mode.explanation,
            symbolName: symbol,
            accentColor: module.accentColor,
            badge: badge,
            isSelected: configManager.config.dockMinimize.actionMode == mode
        ) {
            configManager.config.dockMinimize.actionMode = mode
        }
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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let appName {
                VStack(alignment: .leading, spacing: 1) {
                    Text(appName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(bundleID)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text(bundleID)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button {
                configManager.config.dockMinimize.excludedBundleIDs.removeAll {
                    $0.caseInsensitiveCompare(bundleID) == .orderedSame
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.callout)
                    .foregroundStyle(ToolboxTheme.readableAccentText(for: .red).opacity(0.9))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuRowHover(cornerRadius: 6)
            .help("Remove \(appName ?? bundleID) from exclusions")
            .accessibilityLabel("Remove \(appName ?? bundleID) from exclusions")
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
                    addExclusion(bundleID, validateBundleFormat: false)
                }
            }
        }
    }

    private func resolvedAppName(for bundleID: String) -> String? {
        if let running = runningApps.first(where: {
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
        configManager.config.dockMinimize.excludedBundleIDs.contains {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }
    }

    private func submitManualBundleID() {
        if addExclusion(inputState.newBundleID, validateBundleFormat: true) {
            inputState.newBundleID = ""
            inputState.entryError = nil
        }
    }

    @discardableResult
    private func addExclusion(_ raw: String, validateBundleFormat: Bool) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if validateBundleFormat && !Self.isLikelyBundleID(trimmed) {
            inputState.entryError = "Enter a valid bundle ID such as com.apple.finder."
            return false
        }

        if isBundleExcluded(trimmed) {
            inputState.entryError = "\(trimmed) is already excluded."
            return false
        }

        configManager.config.dockMinimize.excludedBundleIDs.append(trimmed)
        inputState.entryError = nil
        return true
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
