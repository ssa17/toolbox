import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class MenuBarCustomizationDragState: ObservableObject {
    @Published var draggedModuleID: String?
}

struct SettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var registry = ModuleRegistry.shared
    @ObservedObject private var screenOCR = ModuleRegistry.shared.screenOCR
    @ObservedObject private var developerMode = DeveloperModeManager.shared
    @ObservedObject private var supportState = SupportState.shared
    @StateObject private var dragState = MenuBarCustomizationDragState()

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? short
        return build == short ? "v\(short)" : "v\(short) (build \(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                FeatureSection("App Presence & Startup", subtitle: "Choose where Toolbox appears and when it opens.") {
                    SettingRow("Show icon in Menu Bar", subtitle: "Quick toggles and shortcuts from the top status bar.") {
                        Toggle("", isOn: Binding(
                            get: { configManager.config.general.showInMenuBar },
                            set: { newVal in
                                configManager.config.general.showInMenuBar = newVal
                                if !newVal && !configManager.config.general.showInDock {
                                    configManager.config.general.showInDock = true
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                    }

                    Divider()

                    SettingRow("Show icon in Dock", subtitle: "Switch quickly with ⌘ Tab or click the Dock icon to reopen.") {
                        Toggle("", isOn: Binding(
                            get: { configManager.config.general.showInDock },
                            set: { newVal in
                                configManager.config.general.showInDock = newVal
                                if !newVal && !configManager.config.general.showInMenuBar {
                                    configManager.config.general.showInMenuBar = true
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                    }

                    Divider()

                    SettingRow("Open Dashboard on launch", subtitle: "Show the Dashboard window when Toolbox starts.") {
                        Toggle("", isOn: $configManager.config.general.openDashboardOnLaunch)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .pointerCursor()
                    }

                    Divider()

                    SettingRow(
                        "Open Dashboard on Dock click",
                        subtitle: "Reopen the window when clicking the Dock icon while Toolbox runs in the background."
                    ) {
                        Toggle("", isOn: $configManager.config.general.openDashboardOnDockClick)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .pointerCursor()
                    }

                    Divider()

                    SettingRow(
                        "When clicking Quit on Dock",
                        subtitle: "Close the Dashboard window when open (keep running in background), or quit Toolbox."
                    ) {
                        Picker("", selection: $configManager.config.general.dockQuitBehavior) {
                            ForEach(DockQuitBehavior.allCases, id: \.self) { behavior in
                                Text(behavior.displayName).tag(behavior)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .pointerCursor()
                    }

                    Divider()

                    SettingRow("Launch Toolbox at login") {
                        Toggle("", isOn: Binding(
                            get: { configManager.config.general.launchAtLogin },
                            set: { newVal in
                                configManager.config.general.launchAtLogin = newVal
                                updateLoginItem(enabled: newVal)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                    }
                }

                FeatureSection(
                    "Status Bar Menu",
                    subtitle: "Choose which features appear in the menu bar popover and reorder them."
                ) {
                    statusBarMenuCustomizer
                }

                FeatureSection("Permissions", subtitle: "System access used locally on your Mac.") {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Accessibility (Device Control & Data Access)")
                                    .font(.callout.weight(.semibold))
                                StatusBadge(
                                    text: permissions.isAccessibilityGranted
                                        ? "Granted"
                                        : (permissions.isAwaitingAccessibilityGrant ? "Waiting for permission…" : "Not Granted"),
                                    color: permissions.isAccessibilityGranted ? .green : .orange
                                )
                            }
                            Text(
                                permissions.isAccessibilityGranted
                                    ? "All Accessibility-powered modules (Dock Minimize, Auto-Paste, Call Keybinds, Keyboard Lock, and Scroll Direction) are authorized."
                                    : "Used locally for Dock Click to Minimize, auto-pasting (⌘ V), Unified Call Keybinds, Keyboard Lock, and Scroll Direction inversion."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Button(permissions.isResettingAccessibility ? "Resetting…" : "Reset Entry") {
                                permissions.resetAndRegrantAccessibility()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(permissions.isResettingAccessibility)
                            .pointerCursor(!permissions.isResettingAccessibility)
                            if !permissions.isAccessibilityGranted {
                                Button(permissions.isAwaitingAccessibilityGrant ? "Open Settings…" : "Grant Access…") {
                                    permissions.promptAndOpenSettings()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .tint(.orange)
                                .pointerCursor()
                            }
                        }
                    }

                    Divider()

                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Screen Recording (Screen OCR)")
                                    .font(.callout.weight(.semibold))
                                StatusBadge(
                                    text: screenOCR.screenRecordingGranted
                                        ? "Granted"
                                        : (screenOCR.isAwaitingScreenPermission ? "Waiting for permission…" : "Not Granted"),
                                    color: screenOCR.screenRecordingGranted ? .green : .orange
                                )
                            }
                            Text(
                                screenOCR.screenRecordingGranted
                                    ? "Screen OCR is authorized to capture selected regions for on-device text and QR recognition."
                                    : "Used locally by Screen OCR (⇧ ⌘ 0) to capture the region you drag-select for offline Vision recognition."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !screenOCR.screenRecordingGranted {
                            Button(screenOCR.isAwaitingScreenPermission ? "Open Settings…" : "Grant Screen Access…") {
                                if screenOCR.isAwaitingScreenPermission {
                                    screenOCR.openScreenSettings()
                                } else {
                                    screenOCR.requestScreenAccess()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(.orange)
                            .pointerCursor()
                        } else {
                            Button("Open Settings…") {
                                screenOCR.openScreenSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .pointerCursor()
                        }
                    }
                }

                FeatureSection("Software Updates", subtitle: "Checks GitHub Releases silently in the background.") {
                    SoftwareUpdateStatusContent()

                    if updateManager.isSparkleAvailable {
                        Divider()

                        SettingRow("Automatically check for updates", subtitle: "Checks hourly in the background and alerts you when an update is ready.") {
                            Toggle("", isOn: Binding(
                                get: { updateManager.automaticallyChecksForUpdates },
                                set: { updateManager.automaticallyChecksForUpdates = $0 }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .pointerCursor()
                        }
                    }
                }

                FeatureSection("About Toolbox") {
                    HStack(spacing: 14) {
                        Button {
                            developerMode.registerAboutHeaderTap()
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color(red: 0.16, green: 0.18, blue: 0.22), Color(red: 0.08, green: 0.09, blue: 0.11)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: 42, height: 42)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                                    )
                                ToolboxBentoMark(size: 22, primaryColor: .white, accentColor: Color(red: 0.29, green: 0.62, blue: 1.0))
                            }
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text("Toolbox \(versionString)")
                                    .font(.headline)
                                    .onTapGesture {
                                        developerMode.registerAboutHeaderTap()
                                    }

                                if supportState.isSupporterUnlocked {
                                    StatusBadge(text: "Supporter ♥", color: .pink)
                                }

                                if let hint = developerMode.unlockProgressHint {
                                    Text(hint)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.purple)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Color.purple.opacity(0.12), in: Capsule())
                                }
                            }
                            Text("Extensible, lightweight macOS quality-of-life toolkit.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("Config file: \(configManager.configURL.path)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                        Spacer()

                        if developerMode.isUnlocked {
                            HStack(spacing: 6) {
                                Button("Developer Tools") {
                                    MainWindowController.shared.show(destination: .developer(.updates))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .pointerCursor()

                                Button("Lock") {
                                    developerMode.lock()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .pointerCursor()
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
        .onAppear {
            permissions.refresh()
        }
        .sheet(isPresented: $developerMode.isPinPromptPresented) {
            DeveloperPinPromptView(
                onUnlocked: {
                    HUDToast.shared.show(
                        title: "Developer Tools unlocked",
                        symbol: "wrench.and.screwdriver.fill",
                        tint: .purple
                    )
                    MainWindowController.shared.show(destination: .developer(.updates))
                },
                onCancel: {
                    developerMode.dismissPinPrompt()
                }
            )
        }
    }

    private func updateLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Toolbox: SMAppService update failed: \(error.localizedDescription)")
            configManager.config.general.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    @ViewBuilder
    private var statusBarMenuCustomizer: some View {
        let allIDs = registry.modules.map(\.id)
        let orderedModules = registry.orderedMenuBarModules(for: configManager.config)
        let visibleModules = orderedModules.filter {
            configManager.config.general.isModuleVisibleInMenuBar($0.id)
        }

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Displayed Features")
                            .font(.callout.weight(.semibold))
                        StatusBadge(
                            text: "\(visibleModules.count) of \(orderedModules.count) shown",
                            color: visibleModules.isEmpty ? .orange : .blue
                        )
                    }
                    Text("Hiding a feature here only removes its row from the status bar menu. Enabled features keep running in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if configManager.config.general.hasCustomMenuBarLayout {
                    Button("Reset Layout") {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            configManager.config.general.resetMenuBarLayout()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                }
            }

            VStack(spacing: 8) {
                ForEach(Array(orderedModules.enumerated()), id: \.element.id) { index, module in
                    menuBarModuleRow(
                        module: module,
                        index: index,
                        totalCount: orderedModules.count,
                        allIDs: allIDs
                    )
                }
            }
            .onHover { _ in
                if dragState.draggedModuleID != nil && NSEvent.pressedMouseButtons == 0 {
                    dragState.draggedModuleID = nil
                }
            }

            Divider()

            SettingRow(
                "Show Quick Action buttons",
                subtitle: "Include the one-click Clipboard and Keep Awake buttons at the bottom of the menu."
            ) {
                Toggle("", isOn: $configManager.config.general.showQuickActionsInMenuBar)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .pointerCursor()
            }

            Divider()

            SettingRow(
                "Show Quick Commands list",
                subtitle: "Include active Custom Commands in the menu when Custom Commands is enabled."
            ) {
                Toggle("", isOn: $configManager.config.general.showQuickCommandsInMenuBar)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .pointerCursor()
            }
        }
    }

    private func menuBarModuleRow(
        module: any ToolboxModule,
        index: Int,
        totalCount: Int,
        allIDs: [String]
    ) -> some View {
        let isVisible = configManager.config.general.isModuleVisibleInMenuBar(module.id)
        let isModuleEnabled = module.isEnabled(in: configManager.config)
        let canMoveUp = index > 0
        let canMoveDown = index < totalCount - 1
        let isDragged = dragState.draggedModuleID == module.id

        return HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")

            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(module.accentColor.opacity(isVisible ? 0.16 : 0.08))
                    .frame(width: 28, height: 28)
                Image(systemName: module.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isVisible ? module.accentColor : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(module.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isVisible ? .primary : .secondary)

                HStack(spacing: 5) {
                    Circle()
                        .fill(isModuleEnabled ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 5, height: 5)
                    Text(isModuleEnabled ? "Module enabled" : "Module disabled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(isVisible ? "Shown in menu" : "Hidden from menu")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isVisible ? Color.blue : Color.secondary)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            configManager.config.general.moveModuleInMenuBar(
                                id: module.id,
                                direction: -1,
                                allModuleIDs: allIDs
                            )
                        }
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(canMoveUp ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .disabled(!canMoveUp)
                    .help("Move Up")
                    .pointerCursor(canMoveUp)

                    Divider()
                        .frame(height: 14)

                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            configManager.config.general.moveModuleInMenuBar(
                                id: module.id,
                                direction: 1,
                                allModuleIDs: allIDs
                            )
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(canMoveDown ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .disabled(!canMoveDown)
                    .help("Move Down")
                    .pointerCursor(canMoveDown)
                }
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
                )

                Toggle("", isOn: Binding(
                    get: { configManager.config.general.isModuleVisibleInMenuBar(module.id) },
                    set: { newVal in
                        withAnimation(.easeInOut(duration: 0.16)) {
                            configManager.config.general.setModuleVisibleInMenuBar(module.id, visible: newVal)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(StatusBarSwitchToggleStyle(onColor: .blue))
                .help(isVisible ? "Hide from Status Bar Menu" : "Show in Status Bar Menu")
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color.primary.opacity(isVisible ? 0.045 : 0.02),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(
                    isDragged ? Color.blue.opacity(0.55) : Color.primary.opacity(isVisible ? 0.09 : 0.04),
                    lineWidth: isDragged ? 1.25 : 0.75
                )
        )
        .opacity(isDragged ? 0.65 : 1.0)
        .onDrag {
            dragState.draggedModuleID = module.id
            return NSItemProvider(object: module.id as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: MenuBarModuleDropDelegate(
                targetModuleID: module.id,
                dragState: dragState
            ) { fromID, toID in
                withAnimation(.easeInOut(duration: 0.16)) {
                    configManager.config.general.moveModuleInMenuBar(
                        fromId: fromID,
                        toId: toID,
                        allModuleIDs: allIDs
                    )
                }
            }
        )
    }
}

private struct MenuBarModuleDropDelegate: DropDelegate {
    let targetModuleID: String
    let dragState: MenuBarCustomizationDragState
    let onMove: @MainActor (String, String) -> Void

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let draggedID = dragState.draggedModuleID, draggedID != targetModuleID else { return }
            onMove(draggedID, targetModuleID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            dragState.draggedModuleID = nil
        }
        return true
    }
}
