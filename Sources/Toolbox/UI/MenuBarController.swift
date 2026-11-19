import AppKit
import SwiftUI

private final class MenuBarPopoverNSPanel: NSPanel {
    // The menu bar popover has no text inputs; refusing key/main status keeps it from
    // flipping NSApp.isActive or raising an open background Dashboard window on another screen.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private final class MenuBarPopoverChromeView: NSVisualEffectView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        }
    }
}

@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: MenuBarPopoverNSPanel?
    private var visualEffectView: MenuBarPopoverChromeView?
    private var hostingView: PointerCursorHostingView<MenuBarPopoverView>?
    private var isAppActive: Bool = true
    private let menuWidth: CGFloat = 340
    private var outsideClickMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var sizeCheckTimer: Timer?
    private var openedAtUptime: TimeInterval = 0
    private var frontmostPIDAtOpen: pid_t?

    internal var attachedMenuForTesting: NSMenu? { statusItem?.menu }
    internal var statusButtonForTesting: NSStatusBarButton? { statusItem?.button }
    internal var popoverPanelForTesting: NSPanel? { panel }
    internal var isPopoverVisibleForTesting: Bool { panel?.isVisible ?? false }
    internal var pointerCursorViewCountForTesting: Int {
        Self.countPointerCursorViews(in: ensurePanelAndHostingView().hostingView)
    }

    override init() {
        super.init()

        NotificationCenter.default.addObserver(
            forName: .toolboxWillPresentUpdateWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closeMenu()
            }
        }
    }

    func setVisible(_ visible: Bool, isActive: Bool = true) {
        self.isAppActive = isActive
        if visible {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                // Present a .nonactivatingPanel popover rather than NSMenu.view so macOS 26
                // does not cancel menu tracking when Toolbox is in the background.
                item.menu = nil
                if let button = item.button {
                    button.target = self
                    button.action = #selector(handleStatusBarButtonClick(_:))
                    button.sendAction(on: [.leftMouseDown, .rightMouseDown])
                }
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

    @objc
    private func handleStatusBarButtonClick(_ sender: Any?) {
        if panel?.isVisible == true {
            closeMenu()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        openedAtUptime = ProcessInfo.processInfo.systemUptime
        frontmostPIDAtOpen = NSWorkspace.shared.frontmostApplication?.processIdentifier
        PermissionsManager.shared.refresh()
        if ConfigManager.shared.config.callControls.enabled {
            ModuleRegistry.shared.callControls.refreshAudioDevices()
        }

        let (panel, hosting) = ensurePanelAndHostingView()
        let size = fitHostingSize(hosting)
        let origin = anchoredOrigin(for: size)

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        hosting.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        installPopoverMonitors(for: panel)
        startSizeSyncTimer()

        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible else { return }
            self.syncPanelSizeToContent()
            PointerCursorNSView.syncCursor(in: panel)
        }
    }

    @discardableResult
    private func ensurePanelAndHostingView() -> (panel: MenuBarPopoverNSPanel, hostingView: PointerCursorHostingView<MenuBarPopoverView>) {
        if let panel, let hostingView {
            return (panel, hostingView)
        }

        let newPanel = MenuBarPopoverNSPanel(
            contentRect: NSRect(x: 0, y: 0, width: menuWidth, height: 320),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        newPanel.becomesKeyOnlyIfNeeded = true
        newPanel.level = .popUpMenu
        newPanel.acceptsMouseMovedEvents = true
        newPanel.isMovableByWindowBackground = false
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let chrome = MenuBarPopoverChromeView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 320))
        chrome.material = .popover
        chrome.blendingMode = .behindWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 12
        chrome.layer?.masksToBounds = true
        chrome.layer?.borderWidth = 1
        chrome.updateBorderColor()

        let rootView = MenuBarPopoverView(
            onOpenDashboard: { [weak self] destination in
                self?.closeMenu()
                MainWindowController.shared.show(destination: destination)
            },
            onClosePopover: { [weak self] _ in
                self?.closeMenu()
            }
        )
        let newHosting = PointerCursorHostingView(rootView: rootView)
        newHosting.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(newHosting)
        NSLayoutConstraint.activate([
            newHosting.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            newHosting.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            newHosting.topAnchor.constraint(equalTo: chrome.topAnchor),
            newHosting.bottomAnchor.constraint(equalTo: chrome.bottomAnchor)
        ])

        newPanel.contentView = chrome
        self.panel = newPanel
        self.visualEffectView = chrome
        self.hostingView = newHosting

        let initialSize = fitHostingSize(newHosting)
        newPanel.setContentSize(initialSize)
        newHosting.layoutSubtreeIfNeeded()

        return (newPanel, newHosting)
    }

    private func fitHostingSize(_ hosting: PointerCursorHostingView<MenuBarPopoverView>) -> NSSize {
        hosting.layoutSubtreeIfNeeded()
        let rawSize = hosting.fittingSize
        let width = menuWidth
        let height = min(760, max(140, rawSize.height))
        return NSSize(width: width, height: height)
    }

    private func anchoredOrigin(for size: NSSize) -> NSPoint {
        let screens = NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
        return Self.popoverOrigin(
            size: size,
            cursorPoint: NSEvent.mouseLocation,
            buttonScreenRect: statusButtonScreenRect(),
            screenFrames: screens,
            fallbackVisibleFrame: NSScreen.main?.visibleFrame
        )
    }

    internal static func popoverOrigin(
        size: NSSize,
        cursorPoint: NSPoint,
        buttonScreenRect: NSRect?,
        screenFrames: [(frame: NSRect, visibleFrame: NSRect)],
        fallbackVisibleFrame: NSRect? = nil
    ) -> NSPoint {
        let cursorScreen = screenFrames.first(where: { NSMouseInRect(cursorPoint, $0.frame, false) })
        let targetVisible = cursorScreen?.visibleFrame ?? fallbackVisibleFrame ?? screenFrames.first?.visibleFrame

        let validButtonOnCursorScreen: NSRect? = {
            guard let rect = buttonScreenRect,
                  rect.width > 1,
                  rect.height > 1 else { return nil }
            if let cursorScreen {
                let center = NSPoint(x: rect.midX, y: rect.midY)
                guard cursorScreen.frame.contains(center) else { return nil }
            }
            return rect
        }()

        if let rect = validButtonOnCursorScreen {
            var originX = rect.midX - size.width / 2
            var originY = rect.minY - 6 - size.height
            if let visible = targetVisible {
                originX = min(max(originX, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
                originY = min(max(originY, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
            }
            return NSPoint(x: round(originX), y: round(originY))
        }

        if let visible = targetVisible {
            let originX = min(max(cursorPoint.x - size.width / 2, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
            let originY = max(visible.minY + 8, visible.maxY - 6 - size.height)
            return NSPoint(x: round(originX), y: round(originY))
        }
        return NSPoint(x: 100, y: 100)
    }

    private func statusButtonScreenRect() -> NSRect? {
        guard let button = statusItem?.button,
              let window = button.window else { return nil }
        let rectInWindow = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        return screenRect.isEmpty ? nil : screenRect
    }

    private func isPointOverStatusButton(_ screenPoint: NSPoint) -> Bool {
        guard let buttonRect = statusButtonScreenRect(),
              buttonRect.width > 1,
              buttonRect.height > 1 else { return false }
        return buttonRect.insetBy(dx: -2, dy: -2).contains(screenPoint)
    }

    private func installPopoverMonitors(for panel: MenuBarPopoverNSPanel) {
        removePopoverMonitors()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak panel] _ in
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel, panel.isVisible else { return }
                let mouse = NSEvent.mouseLocation
                if !panel.frame.contains(mouse), !self.isPointOverStatusButton(mouse) {
                    self.closeMenu()
                }
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }
            let mouse = NSEvent.mouseLocation
            if self.isPointOverStatusButton(mouse) || event.window === self.statusItem?.button?.window {
                return event
            }
            if let window = event.window,
               NSStringFromClass(type(of: window)).contains("StatusBar") {
                return event
            }
            if let window = event.window,
               window !== panel,
               !NSStringFromClass(type(of: window)).contains("Menu"),
               !panel.frame.contains(mouse) {
                self.closeMenu()
            }
            return event
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }
            if event.keyCode == 53 {
                self.closeMenu()
                return nil
            }
            return event
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel, panel.isVisible else { return }
                self.closeMenu()
            }
        }

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activatedBundleID = activatedApp?.bundleIdentifier
            let activatedPID = activatedApp?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, self.panel?.isVisible == true else { return }
                if activatedBundleID != Bundle.main.bundleIdentifier {
                    let elapsed = ProcessInfo.processInfo.systemUptime - self.openedAtUptime
                    if activatedPID == self.frontmostPIDAtOpen && elapsed < 0.35 {
                        return
                    }
                    self.closeMenu()
                }
            }
        }
    }

    private func removePopoverMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
    }

    private func startSizeSyncTimer() {
        stopSizeSyncTimer()
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncPanelSizeToContent()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sizeCheckTimer = timer
    }

    private func stopSizeSyncTimer() {
        sizeCheckTimer?.invalidate()
        sizeCheckTimer = nil
    }

    private func syncPanelSizeToContent() {
        guard let panel, panel.isVisible, let hostingView else { return }
        let targetSize = fitHostingSize(hostingView)
        if abs(panel.frame.width - targetSize.width) > 1 ||
           abs(panel.frame.height - targetSize.height) > 1 {
            let currentTopY = panel.frame.maxY
            var newFrame = NSRect(
                x: panel.frame.origin.x,
                y: round(currentTopY - targetSize.height),
                width: targetSize.width,
                height: targetSize.height
            )
            if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
                newFrame.origin.x = min(max(newFrame.origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - targetSize.width - 8))
                newFrame.origin.y = min(max(newFrame.origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - targetSize.height - 8))
            }
            panel.setFrame(newFrame, display: true)
            visualEffectView?.updateBorderColor()
        }
    }

    private static func countPointerCursorViews(in view: NSView) -> Int {
        var count = (view is PointerCursorNSView) ? 1 : 0
        for subview in view.subviews {
            count += countPointerCursorViews(in: subview)
        }
        return count
    }

    internal func showPopoverForTesting() {
        showPopover()
    }

    internal func hidePopoverForTesting() {
        closeMenu()
    }

    internal func refreshHostedViewSizeForTesting() {
        let (panel, hosting) = ensurePanelAndHostingView()
        let size = fitHostingSize(hosting)
        panel.setContentSize(size)
        hosting.layoutSubtreeIfNeeded()
    }

    private func closeMenu() {
        stopSizeSyncTimer()
        removePopoverMonitors()
        panel?.orderOut(nil)
        NotificationCenter.default.post(name: .toolboxMenuBarPopoverDidClose, object: nil)
        NSCursor.arrow.set()
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
            .menuRowHover(cornerRadius: 8)

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
                .menuRowHover(cornerRadius: 8, borderOpacity: 0)
            }

            let isAppEnabled = configManager.config.general.appEnabled
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
                .opacity(isAppEnabled ? 1.0 : 0.55)
                .disabled(!isAppEnabled)
            }

            if showQuickActions || showQuickCommands {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
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
                            .pointerCursor(isAppEnabled)
                            .menuRowHover(cornerRadius: 8)

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
                            .pointerCursor(isAppEnabled)
                            .menuRowHover(cornerRadius: 8)

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
                            .pointerCursor(isAppEnabled)
                            .menuRowHover(cornerRadius: 8)
                        }

                        if configManager.config.callControls.enabled {
                            HStack(spacing: 8) {
                                Button {
                                    callControls.toggleSmartMicMute()
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
                                .pointerCursor(isAppEnabled)
                                .menuRowHover(cornerRadius: 8)

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
                                .pointerCursor(isAppEnabled)
                                .menuRowHover(cornerRadius: 8)
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
                                .pointerCursor(isAppEnabled)
                                .menuRowHover(cornerRadius: 6)
                            }
                        }
                    }
                }
                .opacity(isAppEnabled ? 1.0 : 0.55)
                .disabled(!isAppEnabled)
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
                .menuRowHover(cornerRadius: 8)
            }

            Divider()

            HStack(spacing: 8) {
                let hasPending = updateManager.pendingUpdateVersion != nil
                if let pendingVer = updateManager.pendingUpdateVersion {
                    let sizeNote = updateManager.formattedPendingSize.map { " · \($0)" } ?? ""
                    Button {
                        onClosePopover(true)
                        updateManager.openPendingUpdateOrCheck()
                    } label: {
                        Label("Update to v\(pendingVer)\(sizeNote)…", systemImage: "arrow.down.circle.fill")
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
                    .menuRowHover(cornerRadius: 7, color: .white, fillOpacity: 0.14, borderOpacity: 0)
                }

                Button {
                    AppDelegate.terminateNow()
                } label: {
                    Label("Quit", systemImage: "power")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: hasPending ? nil : .infinity)
                        .padding(.horizontal, hasPending ? 14 : 0)
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
                .menuRowHover(cornerRadius: 7)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onReceive(NotificationCenter.default.publisher(for: .toolboxMenuBarPopoverDidClose)) { _ in
            headerHover.isDashboardHovered = false
            headerHover.isSettingsHovered = false
        }
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
            .pointerCursor(isAppEnabled)

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
                    .pointerCursor(isAppEnabled)
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
            .pointerCursor(isAppEnabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(isEnabled ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(isEnabled ? 0.07 : 0.03), lineWidth: 0.75)
        )
        .menuRowHover(cornerRadius: 8)
    }
}
