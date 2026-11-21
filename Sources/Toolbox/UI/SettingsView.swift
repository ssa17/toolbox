import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var registry = ModuleRegistry.shared
    @ObservedObject private var screenOCR = ModuleRegistry.shared.screenOCR
    @ObservedObject private var developerMode = DeveloperModeManager.shared
    @ObservedObject private var supportState = SupportState.shared
    @StateObject private var dragState = VerticalDragReorderState<String>()

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? short
        return build == short ? "v\(short)" : "v\(short) (build \(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionCard(accentTint: ToolboxTheme.accentBlue) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11)
                                .fill(ToolboxTheme.accentBlue.opacity(0.18))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11)
                                        .strokeBorder(ToolboxTheme.accentBlue.opacity(0.28), lineWidth: 1)
                                )
                            Image(systemName: "gearshape.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(ToolboxTheme.accentBlue)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Settings & About")
                                .font(.title3.bold())
                            Text("Manage app presence, menu bar layout, permissions, and updates.")
                                .font(.callout)
                                .foregroundStyle(Color.primary.opacity(0.74))
                        }
                        .textSelection(.enabled)

                        Spacer()
                    }
                }

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
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: ToolboxTheme.accentBlue))
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
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: ToolboxTheme.accentBlue))
                        .pointerCursor()
                    }

                    Divider()

                    SettingRow("Open Dashboard on launch", subtitle: "Show the Dashboard window when Toolbox starts.") {
                        Toggle("", isOn: $configManager.config.general.openDashboardOnLaunch)
                            .labelsHidden()
                            .toggleStyle(ToolboxSwitchToggleStyle(onColor: ToolboxTheme.accentBlue))
                            .pointerCursor()
                    }

                    Divider()

                    let dockEnabled = configManager.config.general.showInDock
                    SettingRow(
                        "Open Dashboard on Dock click",
                        subtitle: dockEnabled
                            ? "Reopen the window when clicking the Dock icon while Toolbox runs in the background."
                            : "Reopen the window when clicking the Dock icon. Requires \"Show icon in Dock\" above."
                    ) {
                        Toggle("", isOn: $configManager.config.general.openDashboardOnDockClick)
                            .labelsHidden()
                            .toggleStyle(ToolboxSwitchToggleStyle(onColor: ToolboxTheme.accentBlue))
                            .pointerCursor(dockEnabled)
                    }
                    .disabled(!dockEnabled)
                    .opacity(dockEnabled ? 1.0 : 0.48)

                    Divider()

                    SettingRow(
                        "When clicking Quit on Dock",
                        subtitle: dockEnabled
                            ? "Close the Dashboard window when open (keep running in background), or quit Toolbox."
                            : "Choose Dock Quit behavior. Requires \"Show icon in Dock\" above."
                    ) {
                        ToolboxSegmentedControl(
                            options: [DockQuitBehavior.closeWindow, DockQuitBehavior.quitApp],
                            selection: $configManager.config.general.dockQuitBehavior,
                            accentColor: ToolboxTheme.accentBlue,
                            label: { $0 == .closeWindow ? "Close Window" : "Quit Toolbox" }
                        )
                    }
                    .disabled(!dockEnabled)
                    .opacity(dockEnabled ? 1.0 : 0.48)

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
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: ToolboxTheme.accentBlue))
                        .pointerCursor()
                    }
                }

                FeatureSection(
                    "Status Bar Menu",
                    subtitle: "Choose which features appear in the menu bar popover and reorder them."
                ) {
                    statusBarMenuCustomizer
                }

                FeatureCardGridSection("Permissions", subtitle: "System access used locally on your Mac.") {
                    Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                        GridRow {
                            accessibilityPermissionCard
                            screenRecordingPermissionCard
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
                            .toggleStyle(ToolboxSwitchToggleStyle(onColor: ToolboxTheme.accentBlue))
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
                                        .foregroundStyle(ToolboxTheme.readableAccentText(for: .purple))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Color.purple.opacity(0.12), in: Capsule())
                                }
                            }
                            Text("Extensible, lightweight macOS quality-of-life toolkit.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            HStack(spacing: 6) {
                                Text("Config file: \(configManager.configURL.path)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(configManager.configURL.path)
                                    .textSelection(.enabled)
                                Button("Reveal") {
                                    NSWorkspace.shared.activateFileViewerSelecting([configManager.configURL])
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .focusEffectDisabled()
                                .pointerCursor()
                            }
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

    private var accessibilityPermissionCard: some View {
        let granted = permissions.isAccessibilityGranted
        let tint: Color = granted ? .green : .orange

        return SectionCard(accentTint: tint) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(tint.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Image(systemName: "hand.raised.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ToolboxTheme.readableAccentText(for: tint))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Accessibility")
                        .font(.callout.weight(.semibold))
                    StatusBadge(
                        text: granted
                            ? "Granted"
                            : (permissions.isAwaitingAccessibilityGrant ? "Waiting…" : "Not Granted"),
                        color: tint
                    )
                }

                Spacer(minLength: 0)
            }

            Text(
                granted
                    ? "All Accessibility-powered modules (Dock Minimize, Auto-Paste, Call Keybinds, Keyboard Lock, and Scroll Direction) are authorized."
                    : "Used locally for Dock Click to Minimize, auto-pasting (⌘ V), Unified Call Keybinds, Keyboard Lock, and Scroll Direction inversion."
            )
            .font(.caption)
            .foregroundStyle(Color.primary.opacity(0.72))
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)

            Spacer(minLength: 0)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    accessibilityPermissionButtons(granted: granted)
                }
                VStack(alignment: .leading, spacing: 8) {
                    accessibilityPermissionButtons(granted: granted)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func accessibilityPermissionButtons(granted: Bool) -> some View {
        if granted {
            Button("Open Settings…") {
                permissions.promptAndOpenSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .pointerCursor()
        } else {
            if permissions.isAdHocSigned || permissions.hasAttemptedGrantWithoutSuccess {
                Button(permissions.isResettingAccessibility ? "Resetting…" : "Reset Permission") {
                    permissions.resetAndRegrantAccessibility()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(permissions.isResettingAccessibility)
                .pointerCursor(!permissions.isResettingAccessibility)
            }

            Button(permissions.isAwaitingAccessibilityGrant ? "Open Settings…" : "Grant Access…") {
                permissions.promptAndOpenSettings()
            }
            .buttonStyle(.toolboxProminent(.orange))
            .controlSize(.regular)
            .pointerCursor()
        }
    }

    private var screenRecordingPermissionCard: some View {
        let granted = screenOCR.screenRecordingGranted
        let tint: Color = granted ? .green : .orange

        return SectionCard(accentTint: tint) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(tint.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Image(systemName: "text.viewfinder")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ToolboxTheme.readableAccentText(for: tint))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Screen Recording")
                        .font(.callout.weight(.semibold))
                    StatusBadge(
                        text: granted
                            ? "Granted"
                            : (screenOCR.isAwaitingScreenPermission ? "Waiting…" : "Not Granted"),
                        color: tint
                    )
                }

                Spacer(minLength: 0)
            }

            Text(
                granted
                    ? "Screen OCR is authorized to capture selected regions for on-device text and QR recognition."
                    : "Used locally by Screen OCR (⇧ ⌘ 0) to capture the region you drag-select for offline Vision recognition."
            )
            .font(.caption)
            .foregroundStyle(Color.primary.opacity(0.72))
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if !granted {
                    Button(screenOCR.isAwaitingScreenPermission ? "Open Settings…" : "Grant Screen Access…") {
                        if screenOCR.isAwaitingScreenPermission {
                            screenOCR.openScreenSettings()
                        } else {
                            screenOCR.requestScreenAccess()
                        }
                    }
                    .buttonStyle(.toolboxProminent(.orange))
                    .controlSize(.regular)
                    .pointerCursor()
                } else {
                    Button("Open Settings…") {
                        screenOCR.openScreenSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .pointerCursor()
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
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
        let eligibleIDs = registry.modules.filter(\.supportsMenuBar).map(\.id)
        let orderedModules = registry.orderedMenuBarModules(for: configManager.config)
        let orderedIDs = orderedModules.map(\.id)
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
                        dragState.cancelActiveDrag()
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
                        eligibleIDs: eligibleIDs,
                        orderedIDs: orderedIDs
                    )
                }
            }
            .animation(dragState.animatedReorder ? .easeInOut(duration: 0.16) : nil, value: orderedIDs)
            .onPreferenceChange(MenuBarModuleRowHeightKey.self) { heights in
                MainActor.assumeIsolated {
                    dragState.rowHeights = heights
                }
            }
            .onChange(of: orderedIDs) { _, newIDs in
                if let layout = dragState.layout, layout.items.map(\.id) != newIDs {
                    dragState.cancelActiveDrag()
                }
            }
            .onDisappear {
                dragState.clearDragState()
            }

            Divider()

            SettingRow(
                "Show Quick Action buttons",
                subtitle: "Include the one-click Clipboard and Keep Awake buttons at the bottom of the menu."
            ) {
                Toggle("", isOn: $configManager.config.general.showQuickActionsInMenuBar)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: ToolboxTheme.accentBlue))
                    .pointerCursor()
            }

            Divider()

            SettingRow(
                "Show Quick Commands list",
                subtitle: "Include active Custom Commands in the menu when Custom Commands is enabled."
            ) {
                Toggle("", isOn: $configManager.config.general.showQuickCommandsInMenuBar)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: ToolboxTheme.accentBlue))
                    .pointerCursor()
            }
        }
    }

    private func menuBarModuleRow(
        module: any ToolboxModule,
        index: Int,
        totalCount: Int,
        eligibleIDs: [String],
        orderedIDs: [String]
    ) -> some View {
        let isVisible = configManager.config.general.isModuleVisibleInMenuBar(module.id)
        let isModuleEnabled = module.isEnabled(in: configManager.config)
        let canMoveUp = index > 0
        let canMoveDown = index < totalCount - 1
        let canDrag = orderedIDs.count > 1
        let isDragged = dragState.draggedID == module.id
        let isSettling = !isDragged && dragState.settlingID == module.id
        let dragShift = dragState.restingShift(for: module.id)
        let rowOffsetY = isDragged ? dragState.dragOffsetY : (isSettling ? dragState.settlingOffsetY : dragShift)

        return HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isDragged ? Color.blue : Color.secondary)
                    .frame(width: 14, height: 28)

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
                            .foregroundStyle(isVisible ? ToolboxTheme.readableAccentText(for: .blue) : Color.secondary)
                    }
                }

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .menuRowHover(cornerRadius: 6)
            .contentShape(Rectangle())
            .overlay(
                ReorderRowDragSurface(
                    canDrag: canDrag,
                    dragThreshold: 2,
                    hoverCursor: canDrag ? .openHand : .arrow,
                    toolTip: dragState.isDragging ? nil : "Drag to reorder",
                    onClick: nil,
                    onDragStart: { [weak dragState] _, cancelHook in
                        dragState?.beginDrag(
                            id: module.id,
                            itemIDs: orderedIDs,
                            spacing: 8,
                            topInset: 0,
                            fallbackHeight: 52,
                            onExternalCancel: cancelHook
                        )
                    },
                    onDragMove: { [weak dragState] startDocY, currentDocY in
                        dragState?.updateDrag(rawDeltaY: currentDocY - startDocY)
                    },
                    onDragEnd: { [weak dragState] in
                        dragState?.finishDrag { draggedID, targetID, _ in
                            configManager.config.general.moveModuleInMenuBar(
                                fromId: draggedID,
                                toId: targetID,
                                allModuleIDs: eligibleIDs
                            )
                        }
                    },
                    onEscapeCancel: { [weak dragState] in
                        dragState?.cancelActiveDrag()
                    }
                )
            )

            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    Button {
                        dragState.cancelActiveDrag()
                        withAnimation(.easeInOut(duration: 0.16)) {
                            configManager.config.general.moveModuleInMenuBar(
                                id: module.id,
                                direction: -1,
                                allModuleIDs: eligibleIDs
                            )
                        }
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(canMoveUp ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                            .menuRowHover(cornerRadius: 5)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .disabled(!canMoveUp)
                    .help("Move Up")
                    .pointerCursor(canMoveUp)

                    Divider()
                        .frame(height: 16)

                    Button {
                        dragState.cancelActiveDrag()
                        withAnimation(.easeInOut(duration: 0.16)) {
                            configManager.config.general.moveModuleInMenuBar(
                                id: module.id,
                                direction: 1,
                                allModuleIDs: eligibleIDs
                            )
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(canMoveDown ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                            .menuRowHover(cornerRadius: 5)
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
                        dragState.cancelActiveDrag()
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
        .background {
            if isDragged {
                RoundedRectangle(cornerRadius: 9)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.blue.opacity(0.10))
                    )
            } else {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(isVisible ? 0.045 : 0.02))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(
                    isDragged ? Color.blue.opacity(0.65) : Color.primary.opacity(isVisible ? 0.09 : 0.04),
                    lineWidth: isDragged ? 1.5 : 0.75
                )
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: MenuBarModuleRowHeightKey.self, value: [module.id: proxy.size.height])
            }
        )
        .scaleEffect(isDragged ? 1.015 : 1.0)
        .shadow(color: .black.opacity(isDragged ? 0.22 : 0), radius: isDragged ? 10 : 0, y: isDragged ? 4 : 0)
        .animation(.easeOut(duration: 0.12), value: isDragged)
        .offset(y: rowOffsetY)
        .animation(
            dragState.layout != nil && !isDragged
                ? .interactiveSpring(response: 0.22, dampingFraction: 0.86)
                : nil,
            value: dragShift
        )
        .zIndex(isDragged ? 100 : (isSettling ? 50 : 0))
    }
}

private struct MenuBarModuleRowHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}
