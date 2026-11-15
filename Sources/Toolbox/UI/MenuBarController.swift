import AppKit
import SwiftUI

private final class MenuHostingContainerView: NSView {
    override func mouseUp(with event: NSEvent) {
        // Swallow mouseUp inside the embedded SwiftUI view so AppKit's NSMenu
        // tracking loop does not treat toggle/button clicks as menu item selection.
    }
}

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let contentMenuItem = NSMenuItem(title: "Toolbox", action: nil, keyEquivalent: "")
    private let containerView = MenuHostingContainerView()
    private let hostingController: NSHostingController<MenuBarPopoverView>
    private var isAppActive: Bool = true
    private let menuWidth: CGFloat = 340
    private var previousFrontmostApp: NSRunningApplication?
    private var hiddenDashboardWindow: NSWindow?
    private var keepAppActiveOnClose = false
    private var cursorSyncTimer: Timer?

    internal var attachedMenuForTesting: NSMenu? { statusItem?.menu }
    internal var menuInstanceForTesting: NSMenu { menu }
    internal var statusButtonForTesting: NSStatusBarButton? { statusItem?.button }
    internal var pointerCursorViewCountForTesting: Int { Self.countPointerCursorViews(in: hostingController.view) }

    override init() {
        var controllerRef: MenuBarController?
        let rootView = MenuBarPopoverView(
            onOpenDashboard: { destination in
                controllerRef?.keepAppActiveOnClose = true
                controllerRef?.closeMenu()
                MainWindowController.shared.show(destination: destination)
            },
            onClosePopover: { keepActive in
                if keepActive {
                    controllerRef?.keepAppActiveOnClose = true
                }
                controllerRef?.closeMenu()
            }
        )
        self.hostingController = NSHostingController(rootView: rootView)

        super.init()
        controllerRef = self

        menu.autoenablesItems = false
        menu.delegate = self
        menu.minimumWidth = menuWidth

        hostingController.sizingOptions = []
        hostingController.view.autoresizingMask = [.width, .height]
        containerView.addSubview(hostingController.view)
        updateHostedViewSize()
        contentMenuItem.view = containerView
        menu.addItem(contentMenuItem)

        NotificationCenter.default.addObserver(
            forName: .toolboxWillPresentUpdateWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.keepAppActiveOnClose = true
                self.closeMenu()
            }
        }
    }

    func setVisible(_ visible: Bool, isActive: Bool = true) {
        self.isAppActive = isActive
        if visible {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                // Attach the NSMenu directly and let AppKit present/toggle it natively (same pattern as Pulse).
                // AppKit guarantees click-to-open, second-click-to-close, outside-click dismiss, and zero delay.
                item.menu = menu
                self.statusItem = item
            }
            updateAppearance(isActive: isActive)
        } else {
            closeMenu()
            if let item = statusItem {
                item.menu = nil
                NSStatusBar.system.removeStatusItem(item)
                self.statusItem = nil
            }
        }
    }

    func updateAppearance(isActive: Bool) {
        self.isAppActive = isActive
        guard let button = statusItem?.button else { return }
        let icon = Self.makeStatusBarIcon(isActive: isActive)
        button.image = icon
        button.image?.isTemplate = true
        button.alphaValue = isActive ? 1.0 : 0.68
        button.toolTip = isActive ? "Toolbox (Active)" : "Toolbox (Paused)"
    }

    func menuWillOpen(_ menu: NSMenu) {
        PermissionsManager.shared.refresh()
        if ConfigManager.shared.config.callControls.enabled {
            ModuleRegistry.shared.callControls.refreshAudioDevices()
        }
        updateHostedViewSize()

        keepAppActiveOnClose = false
        if !NSApp.isActive {
            let front = NSWorkspace.shared.frontmostApplication
            previousFrontmostApp = (front?.bundleIdentifier != Bundle.main.bundleIdentifier) ? front : nil

            // WindowServer only honors NSCursor changes from the active app. If the main Dashboard
            // window is fully covered behind another app, keep it out of sight while briefly
            // activating Toolbox for the duration of the status bar menu.
            if let mainWin = MainWindowController.shared.currentWindow,
               mainWin.isVisible,
               !mainWin.isMiniaturized,
               !mainWin.occlusionState.contains(.visible) {
                mainWin.orderOut(nil)
                hiddenDashboardWindow = mainWin
            }
            NSApp.activate(ignoringOtherApps: true)
        } else {
            previousFrontmostApp = nil
            hiddenDashboardWindow = nil
        }

        startCursorSync()
    }

    func menuDidClose(_ menu: NSMenu) {
        stopCursorSync()
        NSCursor.arrow.set()

        if let hiddenWin = hiddenDashboardWindow {
            hiddenDashboardWindow = nil
            if !keepAppActiveOnClose {
                hiddenWin.orderBack(nil)
            }
        }

        if !keepAppActiveOnClose, let prev = previousFrontmostApp {
            previousFrontmostApp = nil
            prev.activate()
        } else {
            previousFrontmostApp = nil
        }
    }

    private func startCursorSync() {
        stopCursorSync()
        updateMenuCursor()
        // NSMenu's modal tracking loop resets the cursor to arrow on clicks without firing
        // local mouse monitors or mouseEntered; keep the cursor synced while the menu is open.
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hostingController.view.window != nil else { return }
                self.updateMenuCursor()
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        cursorSyncTimer = timer
    }

    private func stopCursorSync() {
        cursorSyncTimer?.invalidate()
        cursorSyncTimer = nil
    }

    private func updateMenuCursor() {
        guard let window = hostingController.view.window else { return }
        let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let isOverInteractive = PointerCursorNSView.containsPointerCursorView(in: hostingController.view, atWindowPoint: ptInWindow)
        if isOverInteractive {
            PointerCursorNSView.forcePointingHandCursor()
        } else {
            NSCursor.arrow.set()
        }
    }

    private static func countPointerCursorViews(in view: NSView) -> Int {
        var count = (view is PointerCursorNSView) ? 1 : 0
        for subview in view.subviews {
            count += countPointerCursorViews(in: subview)
        }
        return count
    }

    private func updateHostedViewSize() {
        let fitting = hostingController.sizeThatFits(in: NSSize(width: menuWidth, height: 760))
        let targetSize = NSSize(width: menuWidth, height: max(140, fitting.height))
        containerView.frame = NSRect(origin: .zero, size: targetSize)
        hostingController.view.frame = containerView.bounds
        hostingController.view.layoutSubtreeIfNeeded()
    }

    internal func refreshHostedViewSizeForTesting() {
        updateHostedViewSize()
    }

    private func closeMenu() {
        menu.cancelTrackingWithoutAnimation()
    }

    internal static func makeStatusBarIcon(isActive: Bool = true) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // Monochrome Option C Bento emblem: 3 squares on top + 1 wide bottom bar.
            // Uses full 1.0 alpha ink so template rendering matches native menu bar brightness.
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let inkColor: NSColor = isDark ? .white : .black

            let sq: CGFloat = 4.6
            let gapX: CGFloat = 1.8
            let gapY: CGFloat = 2.2
            let barH: CGFloat = 5.0
            let wideW: CGFloat = sq * 3 + gapX * 2
            let leftX: CGFloat = (size.width - wideW) / 2
            let bottomY: CGFloat = (size.height - (sq + gapY + barH)) / 2
            let topY: CGFloat = bottomY + barH + gapY
            let r: CGFloat = 1.25

            let rects = [
                NSRect(x: leftX, y: topY, width: sq, height: sq),
                NSRect(x: leftX + sq + gapX, y: topY, width: sq, height: sq),
                NSRect(x: leftX + (sq + gapX) * 2, y: topY, width: sq, height: sq),
                NSRect(x: leftX, y: bottomY, width: wideW, height: barH)
            ]

            if isActive {
                inkColor.setFill()
                for rect in rects {
                    NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
                }
            } else {
                let lw: CGFloat = 1.35
                inkColor.setStroke()
                for rect in rects {
                    let inset = rect.insetBy(dx: lw / 2, dy: lw / 2)
                    let path = NSBezierPath(roundedRect: inset, xRadius: max(0.65, r - 0.3), yRadius: max(0.65, r - 0.3))
                    path.lineWidth = lw
                    path.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
private final class MenuBarHeaderHoverState: ObservableObject {
    @Published var isDashboardHovered = false
    @Published var isSettingsHovered = false
}

struct MenuBarPopoverView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var registry = ModuleRegistry.shared
    @ObservedObject private var keepAwake = ModuleRegistry.shared.keepAwake
    @ObservedObject private var clipboard = ModuleRegistry.shared.clipboard
    @ObservedObject private var portKiller = ModuleRegistry.shared.portKiller
    @ObservedObject private var callControls = ModuleRegistry.shared.callControls
    @ObservedObject private var updateManager = UpdateManager.shared
    @StateObject private var headerHover = MenuBarHeaderHoverState()

    let onOpenDashboard: (SidebarDestination) -> Void
    let onClosePopover: (Bool) -> Void

    private var versionText: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(short)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    ToolboxBentoMark(size: 16, primaryColor: .primary, accentColor: .accentColor)
                    Text("Toolbox")
                        .font(.headline)
                    Text(versionText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Button {
                        headerHover.isDashboardHovered = false
                        onOpenDashboard(.dashboard)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.blue)
                            Text("Dashboard")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(
                            Color.blue.opacity(headerHover.isDashboardHovered ? 0.22 : 0.14),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(
                                    Color.blue.opacity(headerHover.isDashboardHovered ? 0.48 : 0.30),
                                    lineWidth: 0.75
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .onHover { headerHover.isDashboardHovered = $0 }
                    .pointerCursor()

                    Button {
                        headerHover.isSettingsHovered = false
                        onOpenDashboard(.settings)
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(headerHover.isSettingsHovered ? .primary : .secondary)
                            .frame(width: 26, height: 26)
                            .background(
                                Color.primary.opacity(headerHover.isSettingsHovered ? 0.10 : 0.055),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(
                                        Color.primary.opacity(headerHover.isSettingsHovered ? 0.18 : 0.10),
                                        lineWidth: 0.75
                                    )
                            )
                            .overlay(alignment: .topTrailing) {
                                if updateManager.pendingUpdateVersion != nil {
                                    Circle()
                                        .fill(Color.blue)
                                        .frame(width: 7, height: 7)
                                        .offset(x: 2, y: -2)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Settings")
                    .onHover { headerHover.isSettingsHovered = $0 }
                    .pointerCursor()
                }
            }

            // Top-level master power toggle to pause/resume all Toolbox modules at once
            HStack(spacing: 10) {
                Image(systemName: configManager.config.general.appEnabled ? "power.circle.fill" : "pause.circle")
                    .font(.body)
                    .foregroundStyle(configManager.config.general.appEnabled ? Color.green : Color.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(configManager.config.general.appEnabled ? "Toolbox Active" : "Toolbox Paused")
                        .font(.callout.weight(.semibold))
                    Text(configManager.config.general.appEnabled ? "Enabled features are running" : "All modules temporarily suspended")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $configManager.config.general.appEnabled)
                    .labelsHidden()
                    .toggleStyle(StatusBarSwitchToggleStyle(onColor: .green))
                    .pointerCursor()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                (configManager.config.general.appEnabled ? Color.green : Color.secondary).opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
            )

            if !permissions.isAccessibilityGranted {
                Button {
                    onClosePopover(true)
                    permissions.promptAndOpenSettings()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Enable Accessibility")
                                .font(.caption.weight(.semibold))
                            Text("Needed for Dock Minimize, Auto-Paste & Scroll")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(9)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
        .focusEffectDisabled()
                .pointerCursor()
            }

            let visibleModules = registry.visibleMenuBarModules(for: configManager.config)
            let showQuickActions = configManager.config.general.showQuickActionsInMenuBar
            let activeCommands = configManager.config.customCommands.commands.filter {
                $0.enabled &&
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !$0.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let showQuickCommands = configManager.config.general.showQuickCommandsInMenuBar
                && configManager.config.customCommands.enabled
                && !activeCommands.isEmpty

            if !visibleModules.isEmpty {
                Divider()

                VStack(spacing: 8) {
                    ForEach(visibleModules, id: \.id) { module in
                        moduleRow(module)
                    }
                }
                .opacity(configManager.config.general.appEnabled ? 1.0 : 0.62)
            }

            if showQuickActions || showQuickCommands {
                Divider()

                if showQuickActions {
                    HStack(spacing: 8) {
                        Button {
                            onClosePopover(false)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                clipboard.showPopover()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.cyan)
                                Text("Clipboard")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("\(clipboard.entries.count)")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.08), in: Capsule())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.75)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .pointerCursor()

                        Button {
                            onClosePopover(false)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                portKiller.showPopover()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "network")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.indigo)
                                Text("Ports")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.75)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .pointerCursor()

                        Button {
                            keepAwake.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: keepAwake.isAwakeActive ? "bolt.fill" : "bolt")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(keepAwake.isAwakeActive ? .orange : .secondary)
                                Text("Keep Awake")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                if keepAwake.isAwakeActive {
                                    Text("ON")
                                        .font(.system(size: 9, weight: .bold, design: .rounded))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Color.orange.opacity(0.2), in: Capsule())
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                keepAwake.isAwakeActive ? Color.orange.opacity(0.14) : Color.primary.opacity(0.055),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        keepAwake.isAwakeActive ? Color.orange.opacity(0.42) : Color.primary.opacity(0.09),
                                        lineWidth: 0.75
                                    )
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help(keepAwake.isAwakeActive ? "Turn Keep Awake Off" : "Turn Keep Awake On")
                        .pointerCursor()
                    }

                    if configManager.config.callControls.enabled && configManager.config.general.appEnabled {
                        HStack(spacing: 8) {
                            Button {
                                callControls.toggleHardwareMicMute()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: callControls.isInputMuted ? "mic.slash.fill" : "mic.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(callControls.isInputMuted ? .red : .green)
                                    Text(callControls.isInputMuted ? "Mic Muted" : "Mic Live")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(
                                    (callControls.isInputMuted ? Color.red : Color.green).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(
                                            (callControls.isInputMuted ? Color.red : Color.green).opacity(0.35),
                                            lineWidth: 0.75
                                        )
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .help(callControls.isInputMuted ? "Unmute default microphone" : "Mute default microphone")
                            .pointerCursor()

                            Button {
                                callControls.cycleOutputDevice()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: callControls.defaultOutputDevice?.transport.symbolName(isInput: false) ?? "speaker.wave.2")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.blue)
                                    Text(callControls.defaultOutputDevice?.name ?? "Cycle Output")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.75)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .help("Cycle favorite output audio devices")
                            .pointerCursor()
                        }
                    }
                }

                if showQuickCommands {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quick Commands")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(activeCommands.prefix(4)) { cmd in
                            Button {
                                onClosePopover(false)
                                registry.customCommands.runCommand(cmd)
                            } label: {
                                HStack {
                                    Image(systemName: "play.circle")
                                        .foregroundStyle(.purple)
                                    Text(cmd.name)
                                        .font(.caption)
                                    Spacer()
                                    if !cmd.shortcut.isEmpty {
                                        ShortcutPill(text: cmd.shortcut.displayString)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .pointerCursor()
                        }
                    }
                }
            }

            if visibleModules.isEmpty && !showQuickActions && !showQuickCommands {
                Divider()

                Button {
                    onOpenDashboard(.settings)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("All menu sections hidden · Customize in Settings")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerCursor()
            }

            Divider()

            HStack(spacing: 8) {
                if let pendingVer = updateManager.pendingUpdateVersion {
                    Button {
                        onClosePopover(true)
                        updateManager.openPendingUpdateOrCheck()
                    } label: {
                        Label("Update to v\(pendingVer)…", systemImage: "arrow.down.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .pointerCursor()
                } else {
                    Button {
                        updateManager.checkForUpdates()
                    } label: {
                        VStack(spacing: 0) {
                            Label(
                                updateManager.isChecking ? "Checking…" : "Check for Updates",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(updateManager.lastCheckFailed ? .orange : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)

                            if updateManager.isChecking || updateManager.checkProgress > 0 {
                                GeometryReader { proxy in
                                    Capsule()
                                        .fill(Color.blue)
                                        .frame(width: max(8, proxy.size.width * min(1.0, updateManager.checkProgress)), height: 2)
                                }
                                .frame(height: 2)
                            }
                        }
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.75)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .disabled(updateManager.isChecking)
                    .pointerCursor(!updateManager.isChecking)
                }

                Button {
                    AppDelegate.terminateNow()
                } label: {
                    Label("Quit", systemImage: "power")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.75)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
        .focusEffectDisabled()
                .pointerCursor()
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func moduleRow(_ module: any ToolboxModule) -> some View {
        let isEnabled = module.isEnabled(in: configManager.config)
        let isAppEnabled = configManager.config.general.appEnabled
        let needsAccessibility = isEnabled && isAppEnabled && module.requiresAccessibility && !permissions.isAccessibilityGranted
        let status = module.statusText(in: configManager.config, accessibilityGranted: permissions.isAccessibilityGranted)

        return HStack(spacing: 9) {
            Button {
                onOpenDashboard(.module(module.id))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: module.symbolName)
                        .foregroundStyle(isEnabled ? module.accentColor : Color.secondary.opacity(0.65))
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(module.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(isEnabled ? .primary : .secondary)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(
                                    !isEnabled ? Color.secondary.opacity(0.45) :
                                    needsAccessibility ? Color.orange :
                                    isAppEnabled ? Color.green : Color.secondary.opacity(0.6)
                                )
                                .frame(width: 5, height: 5)
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(
                                    needsAccessibility ? Color.orange :
                                    (isEnabled && isAppEnabled) ? Color.secondary : Color.secondary.opacity(0.75)
                                )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        .focusEffectDisabled()
            .pointerCursor()

            if module.id == "call_controls" {
                if isEnabled {
                    let pillOn = configManager.config.callControls.showFloatingMicIndicator
                    Button {
                        callControls.toggleFloatingPillVisibility()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: pillOn ? "capsule.inset.filled" : "capsule")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(pillOn ? .green : .secondary)
                            Text("Pill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(pillOn ? .primary : .secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            pillOn ? Color.green.opacity(0.14) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    pillOn ? Color.green.opacity(0.32) : Color.primary.opacity(0.10),
                                    lineWidth: 0.75
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(pillOn ? "Hide floating status pill" : "Show floating status pill")
                    .pointerCursor()
                }
            } else if let shortcut = module.shortcutText(in: configManager.config) {
                ShortcutPill(text: shortcut)
                    .opacity(isEnabled ? 1.0 : 0.6)
            }

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { newVal in
                    module.setEnabled(newVal, in: &configManager.config)
                    if newVal && module.requiresAccessibility && !permissions.isAccessibilityGranted {
                        onClosePopover(true)
                        permissions.promptAndOpenSettings()
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(StatusBarSwitchToggleStyle(onColor: .green))
            .pointerCursor()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(isEnabled ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(isEnabled ? 0.07 : 0.03), lineWidth: 0.75)
        )
    }
}
