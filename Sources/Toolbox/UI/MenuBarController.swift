import AppKit
import Combine
import QuartzCore
import SwiftUI

internal struct MenuBarPopoverSectionVisibility: Equatable {
    let showQuickActions: Bool
    let showCallControlsActions: Bool
    let showCallControlsPill: Bool
    let showQuickCommands: Bool
    let showWindowProfiles: Bool

    var hasAnyActions: Bool {
        showQuickActions || showQuickCommands || showWindowProfiles
    }

    var showGapAfterQuickActions: Bool {
        showQuickActions && (showQuickCommands || showWindowProfiles)
    }

    var showGapAfterQuickCommands: Bool {
        showQuickCommands && showWindowProfiles
    }

    static func evaluate(for config: ToolboxConfig) -> MenuBarPopoverSectionVisibility {
        let showQuickActions = config.general.showQuickActionsInMenuBar
        let showCallControlsActions = showQuickActions && config.callControls.enabled
        let showCallControlsPill = config.callControls.enabled
        let activeCommands = config.customCommands.commands.filter {
            $0.enabled &&
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let showQuickCommands = config.general.showQuickCommandsInMenuBar
            && config.customCommands.enabled
            && !activeCommands.isEmpty
        let showWindowProfiles = config.windowSnapper.enabled
            && !config.windowSnapper.profiles.isEmpty
        return MenuBarPopoverSectionVisibility(
            showQuickActions: showQuickActions,
            showCallControlsActions: showCallControlsActions,
            showCallControlsPill: showCallControlsPill,
            showQuickCommands: showQuickCommands,
            showWindowProfiles: showWindowProfiles
        )
    }
}

internal struct MenuBarSectionProgress: Equatable {
    var actionsDivider: CGFloat
    var quickActions: CGFloat
    var callControlsActions: CGFloat
    var callControlsPill: CGFloat
    var gapAfterQuickActions: CGFloat
    var quickCommands: CGFloat
    var gapAfterQuickCommands: CGFloat
    var windowProfiles: CGFloat

    var hasAnyVisibleActionSection: Bool {
        actionsDivider > 0.001
            || quickActions > 0.001
            || callControlsActions > 0.001
            || quickCommands > 0.001
            || windowProfiles > 0.001
    }

    static func forVisibility(_ visibility: MenuBarPopoverSectionVisibility) -> MenuBarSectionProgress {
        MenuBarSectionProgress(
            actionsDivider: visibility.hasAnyActions ? 1 : 0,
            quickActions: visibility.showQuickActions ? 1 : 0,
            callControlsActions: visibility.showCallControlsActions ? 1 : 0,
            callControlsPill: visibility.showCallControlsPill ? 1 : 0,
            gapAfterQuickActions: visibility.showGapAfterQuickActions ? 1 : 0,
            quickCommands: visibility.showQuickCommands ? 1 : 0,
            gapAfterQuickCommands: visibility.showGapAfterQuickCommands ? 1 : 0,
            windowProfiles: visibility.showWindowProfiles ? 1 : 0
        )
    }

    static func interpolate(from a: MenuBarSectionProgress, to b: MenuBarSectionProgress, t: CGFloat) -> MenuBarSectionProgress {
        let clamped = min(1, max(0, t))
        func lerp(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
            start + (end - start) * clamped
        }
        return MenuBarSectionProgress(
            actionsDivider: lerp(a.actionsDivider, b.actionsDivider),
            quickActions: lerp(a.quickActions, b.quickActions),
            callControlsActions: lerp(a.callControlsActions, b.callControlsActions),
            callControlsPill: lerp(a.callControlsPill, b.callControlsPill),
            gapAfterQuickActions: lerp(a.gapAfterQuickActions, b.gapAfterQuickActions),
            quickCommands: lerp(a.quickCommands, b.quickCommands),
            gapAfterQuickCommands: lerp(a.gapAfterQuickCommands, b.gapAfterQuickCommands),
            windowProfiles: lerp(a.windowProfiles, b.windowProfiles)
        )
    }

    func maxDelta(to other: MenuBarSectionProgress) -> CGFloat {
        max(
            abs(actionsDivider - other.actionsDivider),
            max(
                abs(quickActions - other.quickActions),
                max(
                    abs(callControlsActions - other.callControlsActions),
                    max(
                        abs(callControlsPill - other.callControlsPill),
                        max(
                            abs(gapAfterQuickActions - other.gapAfterQuickActions),
                            max(
                                abs(quickCommands - other.quickCommands),
                                max(
                                    abs(gapAfterQuickCommands - other.gapAfterQuickCommands),
                                    abs(windowProfiles - other.windowProfiles)
                                )
                            )
                        )
                    )
                )
            )
        )
    }
}

@MainActor
internal final class MenuBarPopoverLayoutAnimator: ObservableObject {
    // Closely matches StatusBarSwitchToggleStyle's 0.16s easeInOut thumb animation.
    static let baseDuration: TimeInterval = 0.18

    static func easeInOut(_ x: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, x))
        return 0.5 - 0.5 * cos(.pi * clamped)
    }

    @Published private(set) var progress: MenuBarSectionProgress
    private(set) var revision: Int = 0
    private(set) var targetVisibility: MenuBarPopoverSectionVisibility
    private(set) var isAnimating: Bool = false
    internal var reduceMotionOverrideForTesting: Bool? = nil

    private var startProgress: MenuBarSectionProgress
    private var targetProgress: MenuBarSectionProgress
    private var animationStartTime: CFTimeInterval?
    private var animationDuration: TimeInterval = baseDuration

    init(config: ToolboxConfig) {
        let visibility = MenuBarPopoverSectionVisibility.evaluate(for: config)
        let initial = MenuBarSectionProgress.forVisibility(visibility)
        self.targetVisibility = visibility
        self.progress = initial
        self.startProgress = initial
        self.targetProgress = initial
    }

    @discardableResult
    func updateTargets(for config: ToolboxConfig, animated: Bool) -> Bool {
        let nextVisibility = MenuBarPopoverSectionVisibility.evaluate(for: config)
        targetVisibility = nextVisibility
        let nextTarget = MenuBarSectionProgress.forVisibility(nextVisibility)
        let delta = progress.maxDelta(to: nextTarget)
        if delta < 0.001 {
            if progress != nextTarget {
                progress = nextTarget
                revision &+= 1
            }
            startProgress = nextTarget
            targetProgress = nextTarget
            animationStartTime = nil
            isAnimating = false
            return false
        }
        let reduceMotion = reduceMotionOverrideForTesting ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animated || reduceMotion {
            progress = nextTarget
            revision &+= 1
            startProgress = nextTarget
            targetProgress = nextTarget
            animationStartTime = nil
            isAnimating = false
            return false
        }
        startProgress = progress
        targetProgress = nextTarget
        animationDuration = max(0.10, Self.baseDuration * Double(max(0.55, delta)))
        animationStartTime = nil
        isAnimating = true
        return true
    }

    func snapToTargets(for config: ToolboxConfig) {
        _ = updateTargets(for: config, animated: false)
    }

    func step(timestamp: CFTimeInterval, frameDuration: CFTimeInterval) -> Bool {
        guard isAnimating else { return false }
        let clampedFrame = min(1.0 / 60.0, max(1.0 / 240.0, frameDuration))
        if animationStartTime == nil {
            animationStartTime = timestamp - clampedFrame
        }
        let elapsed = max(0, timestamp - (animationStartTime ?? timestamp))
        let rawFraction = CGFloat(min(1.0, elapsed / max(0.001, animationDuration)))
        let eased = Self.easeInOut(rawFraction)
        progress = MenuBarSectionProgress.interpolate(from: startProgress, to: targetProgress, t: eased)
        revision &+= 1
        if rawFraction >= 1.0 {
            progress = targetProgress
            startProgress = targetProgress
            animationStartTime = nil
            isAnimating = false
            return false
        }
        return true
    }

    internal func advanceForTesting(fraction: CGFloat) {
        let clamped = min(1, max(0, fraction))
        let eased = Self.easeInOut(clamped)
        progress = MenuBarSectionProgress.interpolate(from: startProgress, to: targetProgress, t: eased)
        revision &+= 1
        if clamped >= 1.0 {
            progress = targetProgress
            startProgress = targetProgress
            animationStartTime = nil
            isAnimating = false
        }
    }
}

private struct CollapsibleLayout: Layout {
    var progress: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let clamped = min(1, max(0, progress))
        let natural = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(
            width: proposal.width ?? natural.width,
            height: natural.height * clamped
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let natural = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: natural.height)
        )
    }
}

private struct CollapsibleBlock<Content: View>: View {
    let progress: CGFloat
    var isInteractive: Bool = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        let clamped = min(1, max(0, progress))
        if clamped > 0.001 {
            CollapsibleLayout(progress: clamped) {
                content()
            }
            .opacity(Double(clamped))
            .clipped()
            .allowsHitTesting(isInteractive && clamped > 0.99)
            .accessibilityHidden(clamped < 0.01)
        }
    }
}

@MainActor
private final class DisplayLinkProxy: NSObject {
    var onTick: ((CADisplayLink) -> Void)?

    @objc func handleTick(_ link: CADisplayLink) {
        onTick?(link)
    }
}

private final class MenuBarPopoverNSPanel: PointerCursorNSPanel {
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
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
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
    private let layoutAnimator = MenuBarPopoverLayoutAnimator(config: ConfigManager.shared.config)
    private var configCancellable: AnyCancellable?
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
    private var anchoredTopY: CGFloat?

    internal var attachedMenuForTesting: NSMenu? { statusItem?.menu }
    internal var statusButtonForTesting: NSStatusBarButton? { statusItem?.button }
    internal var popoverPanelForTesting: NSPanel? { panel }
    internal var visualEffectMaterialForTesting: NSVisualEffectView.Material? { visualEffectView?.material }
    internal var isPopoverVisibleForTesting: Bool { panel?.isVisible ?? false }
    internal var layoutAnimatorForTesting: MenuBarPopoverLayoutAnimator { layoutAnimator }
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

        stopLayoutAnimation()
        layoutAnimator.snapToTargets(for: ConfigManager.shared.config)

        let (panel, hosting) = ensurePanelAndHostingView()
        syncHostingRootViewProgress(hosting)

        let screens = NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let cursorPoint = NSEvent.mouseLocation
        let buttonRect = statusButtonScreenRect()
        let fallbackVisible = NSScreen.main?.visibleFrame
        let visibleFrame = Self.targetVisibleFrame(
            cursorPoint: cursorPoint,
            screenFrames: screens,
            fallbackVisibleFrame: fallbackVisible
        )
        let estimatedTopY = Self.estimatedPopoverTopY(
            cursorPoint: cursorPoint,
            buttonScreenRect: buttonRect,
            screenFrames: screens,
            fallbackVisibleFrame: fallbackVisible
        )
        let maxHeight = Self.maxAllowedPanelHeight(forTopY: estimatedTopY, visibleFrame: visibleFrame)
        let size = fitHostingSize(hosting, maxHeight: maxHeight)
        let origin = Self.popoverOrigin(
            size: size,
            cursorPoint: cursorPoint,
            buttonScreenRect: buttonRect,
            screenFrames: screens,
            fallbackVisibleFrame: fallbackVisible
        )
        anchoredTopY = round(origin.y + size.height)

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        hosting.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        installPopoverMonitors(for: panel)
        startObservingConfigChanges()
        startSizeSyncTimer()

        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible else { return }
            if !self.layoutAnimator.isAnimating {
                self.syncPanelSizeToContent()
            }
            PointerCursorNSView.syncCursor(in: panel)
        }
    }

    private func makeRootView() -> MenuBarPopoverView {
        MenuBarPopoverView(
            layoutAnimator: layoutAnimator,
            layoutRevision: layoutAnimator.revision,
            onOpenDashboard: { [weak self] destination in
                self?.closeMenu()
                MainWindowController.shared.show(destination: destination)
            },
            onClosePopover: { [weak self] _ in
                self?.closeMenu()
            }
        )
    }

    private func syncHostingRootViewProgress(_ hosting: PointerCursorHostingView<MenuBarPopoverView>) {
        hosting.rootView = makeRootView()
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
        ToolboxTheme.applyDarkAppearance(to: newPanel)

        let chrome = MenuBarPopoverChromeView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 320))
        chrome.appearance = ToolboxTheme.darkAppearance
        chrome.material = .windowBackground
        chrome.blendingMode = .behindWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layerContentsPlacement = .topLeft
        chrome.layer?.cornerRadius = 12
        chrome.layer?.masksToBounds = true
        chrome.layer?.borderWidth = 1
        chrome.updateBorderColor()

        let newHosting = PointerCursorHostingView(rootView: makeRootView())
        newHosting.translatesAutoresizingMaskIntoConstraints = false
        newHosting.sizingOptions = [.minSize, .intrinsicContentSize]
        chrome.addSubview(newHosting)
        let bottomConstraint = newHosting.bottomAnchor.constraint(equalTo: chrome.bottomAnchor)
        bottomConstraint.priority = NSLayoutConstraint.Priority(490)
        NSLayoutConstraint.activate([
            newHosting.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            newHosting.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            newHosting.topAnchor.constraint(equalTo: chrome.topAnchor),
            bottomConstraint
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

    private func fitHostingSize(
        _ hosting: PointerCursorHostingView<MenuBarPopoverView>,
        maxHeight: CGFloat? = nil
    ) -> NSSize {
        hosting.layoutSubtreeIfNeeded()
        let rawSize = hosting.fittingSize
        let upperBound = maxHeight ?? 960
        let width = menuWidth
        let height = min(upperBound, max(140, ceil(rawSize.height)))
        return NSSize(width: width, height: height)
    }

    private static func targetVisibleFrame(
        cursorPoint: NSPoint,
        screenFrames: [(frame: NSRect, visibleFrame: NSRect)],
        fallbackVisibleFrame: NSRect?
    ) -> NSRect? {
        let cursorScreen = screenFrames.first(where: { NSMouseInRect(cursorPoint, $0.frame, false) })
        return cursorScreen?.visibleFrame ?? fallbackVisibleFrame ?? screenFrames.first?.visibleFrame
    }

    private static func validButtonOnCursorScreen(
        buttonScreenRect: NSRect?,
        cursorPoint: NSPoint,
        screenFrames: [(frame: NSRect, visibleFrame: NSRect)]
    ) -> NSRect? {
        guard let rect = buttonScreenRect,
              rect.width > 1,
              rect.height > 1 else { return nil }
        let targetScreen = screenFrames.first(where: { NSMouseInRect(cursorPoint, $0.frame, false) })
            ?? screenFrames.first(where: { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) })
        if let screen = targetScreen {
            let center = NSPoint(x: rect.midX, y: rect.midY)
            guard screen.frame.contains(center) else { return nil }
            // Reject unpositioned NSStatusItem windows at origin (0, 0) (e.g. before WindowServer
            // lays out the menu bar in --self-test); real status buttons sit in the top menu bar.
            guard rect.minY >= screen.visibleFrame.maxY - 80 else { return nil }
        }
        return rect
    }

    private static func estimatedPopoverTopY(
        cursorPoint: NSPoint,
        buttonScreenRect: NSRect?,
        screenFrames: [(frame: NSRect, visibleFrame: NSRect)],
        fallbackVisibleFrame: NSRect?
    ) -> CGFloat? {
        let targetVisible = targetVisibleFrame(
            cursorPoint: cursorPoint,
            screenFrames: screenFrames,
            fallbackVisibleFrame: fallbackVisibleFrame
        )
        if let rect = validButtonOnCursorScreen(
            buttonScreenRect: buttonScreenRect,
            cursorPoint: cursorPoint,
            screenFrames: screenFrames
        ) {
            if let targetVisible {
                return min(rect.minY - 6, targetVisible.maxY - 8)
            }
            return rect.minY - 6
        }
        if let targetVisible {
            return targetVisible.maxY - 6
        }
        return nil
    }

    internal static func maxAllowedPanelHeight(forTopY topY: CGFloat?, visibleFrame: NSRect?) -> CGFloat {
        guard let topY, let visibleFrame else { return 960 }
        return max(140, floor(topY - (visibleFrame.minY + 8)))
    }

    internal static func popoverOrigin(
        size: NSSize,
        cursorPoint: NSPoint,
        buttonScreenRect: NSRect?,
        screenFrames: [(frame: NSRect, visibleFrame: NSRect)],
        fallbackVisibleFrame: NSRect? = nil
    ) -> NSPoint {
        let targetVisible = targetVisibleFrame(
            cursorPoint: cursorPoint,
            screenFrames: screenFrames,
            fallbackVisibleFrame: fallbackVisibleFrame
        )
        let validButton = validButtonOnCursorScreen(
            buttonScreenRect: buttonScreenRect,
            cursorPoint: cursorPoint,
            screenFrames: screenFrames
        )

        if let rect = validButton {
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

    private func startObservingConfigChanges() {
        stopObservingConfigChanges()
        configCancellable = ConfigManager.shared.$config
            .dropFirst()
            .sink { [weak self] newConfig in
                self?.handleConfigUpdateWhileVisible(newConfig)
            }
    }

    private func stopObservingConfigChanges() {
        configCancellable?.cancel()
        configCancellable = nil
    }

    private func handleConfigUpdateWhileVisible(_ newConfig: ToolboxConfig) {
        guard let panel, panel.isVisible else { return }
        if layoutAnimator.updateTargets(for: newConfig, animated: true) {
            startLayoutAnimation(for: panel)
        } else if !layoutAnimator.isAnimating {
            stopLayoutAnimation()
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self, let panel, panel.isVisible, !self.layoutAnimator.isAnimating else { return }
                if let hostingView = self.hostingView {
                    self.syncHostingRootViewProgress(hostingView)
                }
                self.syncPanelSizeToContent()
            }
        }
    }

    private func startLayoutAnimation(for panel: MenuBarPopoverNSPanel) {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy()
        proxy.onTick = { [weak self] link in
            self?.handleLayoutDisplayLinkTick(link)
        }
        let link = panel.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.handleTick(_:)))
        link.add(to: .main, forMode: .common)
        self.displayLinkProxy = proxy
        self.displayLink = link
    }

    private func stopLayoutAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy?.onTick = nil
        displayLinkProxy = nil
    }

    private func handleLayoutDisplayLinkTick(_ link: CADisplayLink) {
        guard let panel, panel.isVisible, let hostingView else {
            stopLayoutAnimation()
            return
        }
        let frameDuration = link.duration > 0 ? link.duration : max(1.0 / 240.0, link.targetTimestamp - link.timestamp)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let stillRunning = layoutAnimator.step(timestamp: link.timestamp, frameDuration: frameDuration)
        syncHostingRootViewProgress(hostingView)
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        syncPanelSizeToContent()
        hostingView.layoutSubtreeIfNeeded()
        CATransaction.commit()

        if !stillRunning {
            stopLayoutAnimation()
            PointerCursorNSView.syncCursor(in: panel)
        }
    }

    private func startSizeSyncTimer() {
        stopSizeSyncTimer()
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.layoutAnimator.isAnimating else { return }
                self.syncPanelSizeToContent()
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
        let currentTopY = anchoredTopY ?? round(panel.frame.maxY)
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
        let maxHeight = Self.maxAllowedPanelHeight(forTopY: currentTopY, visibleFrame: visible)
        let targetSize = fitHostingSize(hostingView, maxHeight: maxHeight)
        if abs(panel.frame.width - targetSize.width) > 0.25 ||
           abs(panel.frame.height - targetSize.height) > 0.25 {
            var originX = panel.frame.origin.x
            if let visible {
                originX = min(max(originX, visible.minX + 8), max(visible.minX + 8, visible.maxX - targetSize.width - 8))
            }
            let newFrame = NSRect(
                x: round(originX),
                y: round(currentTopY - targetSize.height),
                width: targetSize.width,
                height: targetSize.height
            )
            panel.setFrame(newFrame, display: true)
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
        stopLayoutAnimation()
        layoutAnimator.snapToTargets(for: ConfigManager.shared.config)
        let (panel, hosting) = ensurePanelAndHostingView()
        syncHostingRootViewProgress(hosting)
        if panel.isVisible {
            if anchoredTopY == nil {
                anchoredTopY = round(panel.frame.maxY)
            }
            syncPanelSizeToContent()
        } else {
            let size = fitHostingSize(hosting)
            panel.setContentSize(size)
            anchoredTopY = round(panel.frame.maxY)
        }
        hosting.layoutSubtreeIfNeeded()
    }

    internal func stepLayoutAnimationForTesting(fraction: CGFloat) {
        stopLayoutAnimation()
        layoutAnimator.advanceForTesting(fraction: fraction)
        let (panel, hosting) = ensurePanelAndHostingView()
        syncHostingRootViewProgress(hosting)
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        if panel.isVisible {
            syncPanelSizeToContent()
            hosting.layoutSubtreeIfNeeded()
            if !layoutAnimator.isAnimating {
                PointerCursorNSView.syncCursor(in: panel)
            }
        }
    }

    private func closeMenu() {
        stopLayoutAnimation()
        stopObservingConfigChanges()
        stopSizeSyncTimer()
        removePopoverMonitors()
        anchoredTopY = nil
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
    @Published var isQuitHovered = false
}

struct MenuBarPopoverView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var registry = ModuleRegistry.shared
    @ObservedObject private var keepAwake = ModuleRegistry.shared.keepAwake
    @ObservedObject private var clipboard = ModuleRegistry.shared.clipboard
    @ObservedObject private var portKiller = ModuleRegistry.shared.portKiller
    @ObservedObject private var callControls = ModuleRegistry.shared.callControls
    @ObservedObject private var windowSnapper = ModuleRegistry.shared.windowSnapper
    @ObservedObject private var overlayController = ZoneOverlayController.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject var layoutAnimator: MenuBarPopoverLayoutAnimator
    var layoutRevision: Int
    @StateObject private var headerHover = MenuBarHeaderHoverState()

    let onOpenDashboard: (SidebarDestination) -> Void
    let onClosePopover: (Bool) -> Void

    init(
        layoutAnimator: MenuBarPopoverLayoutAnimator,
        layoutRevision: Int = 0,
        onOpenDashboard: @escaping (SidebarDestination) -> Void,
        onClosePopover: @escaping (Bool) -> Void
    ) {
        self.layoutAnimator = layoutAnimator
        self.layoutRevision = layoutRevision
        self.onOpenDashboard = onOpenDashboard
        self.onClosePopover = onClosePopover
    }

    init(
        onOpenDashboard: @escaping (SidebarDestination) -> Void,
        onClosePopover: @escaping (Bool) -> Void
    ) {
        self.init(
            layoutAnimator: MenuBarPopoverLayoutAnimator(config: ConfigManager.shared.config),
            layoutRevision: 0,
            onOpenDashboard: onOpenDashboard,
            onClosePopover: onClosePopover
        )
    }

    private var versionText: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(short)"
    }

    var body: some View {
        let p = layoutAnimator.progress
        let isAppEnabled = configManager.config.general.appEnabled
        let visibleModules = registry.visibleMenuBarModules(for: configManager.config)
        let activeCommands = configManager.config.customCommands.commands.filter {
            $0.enabled &&
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let activeProfiles = configManager.config.windowSnapper.profiles

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    ToolboxBentoMark(size: 16, primaryColor: .primary, accentColor: .accentColor)
                    Text("Toolbox")
                        .toolboxFont(.headline)
                    Text(versionText)
                        .toolboxFont(.caption2.monospaced())
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
                                .toolboxFont(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.blue)
                            Text("Dashboard")
                                .toolboxFont(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(minHeight: 26)
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
                            .toolboxFont(.system(size: 12.5, weight: .medium))
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
                    .toolboxFont(.body)
                    .foregroundStyle(configManager.config.general.appEnabled ? Color.green : Color.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(configManager.config.general.appEnabled ? "Toolbox Active" : "Toolbox Paused")
                        .toolboxFont(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(configManager.config.general.appEnabled ? "Enabled features are running" : "All modules temporarily suspended")
                        .toolboxFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
            .padding(.top, 12)

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
                                .toolboxFont(.caption.weight(.semibold))
                            Text("Needed for Dock Minimize, Auto-Paste & Scroll")
                                .toolboxFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .toolboxFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(9)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerCursor()
                .menuRowHover(cornerRadius: 8, borderOpacity: 0)
                .padding(.top, 12)
            }

            if !visibleModules.isEmpty {
                Divider()
                    .padding(.vertical, 12)

                VStack(spacing: 8) {
                    ForEach(visibleModules, id: \.id) { module in
                        moduleRow(module, pillProgress: p.callControlsPill)
                    }
                }
                .opacity(isAppEnabled ? 1.0 : 0.55)
                .disabled(!isAppEnabled)
            }

            CollapsibleBlock(progress: p.actionsDivider, isInteractive: false) {
                Divider()
                    .padding(.vertical, 12)
            }

            VStack(alignment: .leading, spacing: 0) {
                CollapsibleBlock(progress: p.quickActions, isInteractive: isAppEnabled) {
                    HStack(spacing: 6) {
                        Button {
                            onClosePopover(false)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                clipboard.showPopover()
                            }
                        } label: {
                            HStack(spacing: 4.5) {
                                Image(systemName: "doc.on.clipboard")
                                    .toolboxFont(.caption.weight(.semibold))
                                    .foregroundStyle(.cyan)
                                Text("Clipboard")
                                    .toolboxFont(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.80)
                                Text("\(clipboard.entries.count)")
                                    .toolboxFont(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4.5)
                                    .padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.08), in: Capsule())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 4)
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
                        .pointerCursor(isAppEnabled && p.quickActions > 0.99)
                        .menuRowHover(cornerRadius: 8)

                        Button {
                            onClosePopover(false)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                portKiller.showPopover()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "network")
                                    .toolboxFont(.caption.weight(.semibold))
                                    .foregroundStyle(.indigo)
                                Text("Ports")
                                    .toolboxFont(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
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
                        .pointerCursor(isAppEnabled && p.quickActions > 0.99)
                        .menuRowHover(cornerRadius: 8)

                        Button {
                            keepAwake.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: keepAwake.isAwakeActive ? "bolt.fill" : "bolt")
                                    .toolboxFont(.caption.weight(.semibold))
                                    .foregroundStyle(keepAwake.isAwakeActive ? .orange : .secondary)
                                Text("Keep Awake")
                                    .toolboxFont(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                if keepAwake.isAwakeActive {
                                    Text("ON")
                                        .toolboxFont(.system(size: 10.5, weight: .bold, design: .rounded))
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
                        .pointerCursor(isAppEnabled && p.quickActions > 0.99)
                        .menuRowHover(cornerRadius: 8)
                    }
                }

                CollapsibleBlock(progress: p.callControlsActions, isInteractive: isAppEnabled) {
                    HStack(spacing: 8) {
                        Button {
                            callControls.toggleSmartMicMute()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: callControls.isInputMuted ? "mic.slash.fill" : "mic.fill")
                                    .toolboxFont(.caption.weight(.semibold))
                                    .foregroundStyle(callControls.isInputMuted ? .red : .green)
                                Text(callControls.isInputMuted ? "Mic Muted" : "Mic Live")
                                    .toolboxFont(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
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
                        .pointerCursor(isAppEnabled && p.callControlsActions > 0.99)
                        .menuRowHover(cornerRadius: 8)

                        Button {
                            callControls.cycleOutputDevice()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: callControls.defaultOutputDevice?.transport.symbolName(isInput: false) ?? "speaker.wave.2")
                                    .toolboxFont(.caption.weight(.semibold))
                                    .foregroundStyle(.blue)
                                Text(callControls.defaultOutputDevice?.name ?? "Cycle Output")
                                    .toolboxFont(.caption.weight(.medium))
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
                        .pointerCursor(isAppEnabled && p.callControlsActions > 0.99)
                        .menuRowHover(cornerRadius: 8)
                    }
                    .padding(.top, 12)
                }

                CollapsibleBlock(progress: p.gapAfterQuickActions, isInteractive: false) {
                    Color.clear.frame(height: 12)
                }

                CollapsibleBlock(progress: p.quickCommands, isInteractive: isAppEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quick Commands")
                            .toolboxFont(.caption2.weight(.semibold))
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
                                        .toolboxFont(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
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
                            .pointerCursor(isAppEnabled && p.quickCommands > 0.99)
                            .menuRowHover(cornerRadius: 6)
                        }
                    }
                }

                CollapsibleBlock(progress: p.gapAfterQuickCommands, isInteractive: false) {
                    Color.clear.frame(height: 12)
                }

                CollapsibleBlock(progress: p.windowProfiles, isInteractive: isAppEnabled) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Workspace Profiles")
                            .toolboxFont(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(activeProfiles.prefix(4)) { profile in
                            let isActiveProfile = configManager.config.windowSnapper.activeProfileID == profile.id
                            let isDryRun = overlayController.isDryRunPreviewActive && overlayController.activeDryRunProfileID == profile.id

                            HStack(spacing: 6) {
                                Button {
                                    onClosePopover(false)
                                    windowSnapper.applyProfile(profile)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: profile.symbolName)
                                            .toolboxFont(.caption)
                                            .foregroundStyle(ToolboxTheme.readableAccentText(for: .indigo))
                                        Text(profile.name)
                                            .toolboxFont(.caption.weight(isActiveProfile ? .semibold : .regular))
                                            .lineLimit(1)
                                        if isActiveProfile {
                                            Circle()
                                                .fill(Color.green)
                                                .frame(width: 5, height: 5)
                                        }
                                        Spacer()
                                        if !profile.shortcut.isEmpty {
                                            ShortcutPill(text: profile.shortcut.displayString)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled()
                                .pointerCursor(isAppEnabled && p.windowProfiles > 0.99)
                                .menuRowHover(cornerRadius: 6)

                                Button {
                                    windowSnapper.previewProfile(profile)
                                } label: {
                                    Image(systemName: "eye")
                                        .toolboxFont(.caption.weight(.medium))
                                        .foregroundStyle(isDryRun ? ToolboxTheme.readableAccentText(for: .indigo) : .secondary)
                                        .frame(width: 26, height: 24)
                                        .background(Color.primary.opacity(isDryRun ? 0.16 : 0.05), in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled()
                                .help("Preview profile for 3s")
                                .pointerCursor(isAppEnabled && p.windowProfiles > 0.99)
                                .menuRowHover(cornerRadius: 6)
                            }
                        }
                    }
                }
            }
            .opacity(isAppEnabled ? 1.0 : 0.55)
            .disabled(!isAppEnabled)

            if visibleModules.isEmpty && !p.hasAnyVisibleActionSection {
                Divider()
                    .padding(.vertical, 12)

                Button {
                    onOpenDashboard(.settings)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .toolboxFont(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("All menu sections hidden · Customize in Settings")
                            .toolboxFont(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .toolboxFont(.caption2)
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
                .padding(.vertical, 12)

            HStack(spacing: 8) {
                let hasPending = updateManager.pendingUpdateVersion != nil
                if let pendingVer = updateManager.pendingUpdateVersion {
                    let sizeNote = updateManager.formattedPendingSize.map { " · \($0)" } ?? ""
                    Button {
                        onClosePopover(true)
                        updateManager.openPendingUpdateOrCheck()
                    } label: {
                        Label("Update to v\(pendingVer)\(sizeNote)…", systemImage: "arrow.down.circle.fill")
                            .toolboxFont(.caption.weight(.semibold))
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

                let isQuitHovered = headerHover.isQuitHovered
                Button {
                    AppDelegate.terminateNow()
                } label: {
                    Label("Quit", systemImage: "power")
                        .toolboxFont(.caption.weight(.medium))
                        .foregroundStyle(isQuitHovered ? Color.red : .secondary)
                        .frame(maxWidth: hasPending ? nil : .infinity)
                        .padding(.horizontal, hasPending ? 14 : 0)
                        .padding(.vertical, 6)
                        .background(
                            isQuitHovered ? Color.red.opacity(0.14) : Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(
                                    isQuitHovered ? Color.red.opacity(0.32) : Color.primary.opacity(0.09),
                                    lineWidth: 0.75
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { headerHover.isQuitHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isQuitHovered)
                .pointerCursor()
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.76))
        .onReceive(NotificationCenter.default.publisher(for: .toolboxMenuBarPopoverDidClose)) { _ in
            headerHover.isDashboardHovered = false
            headerHover.isSettingsHovered = false
            headerHover.isQuitHovered = false
        }
        .toolboxDarkAppearance()
    }

    private func moduleRow(_ module: any ToolboxModule, pillProgress: CGFloat) -> some View {
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
                            .toolboxFont(.callout.weight(.medium))
                            .foregroundStyle(isEnabled ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(
                                    !isEnabled ? Color.secondary.opacity(0.45) :
                                    needsAccessibility ? Color.orange :
                                    isAppEnabled ? Color.green : Color.secondary.opacity(0.6)
                                )
                                .frame(width: 5, height: 5)
                            Text(status)
                                .toolboxFont(.caption2)
                                .foregroundStyle(
                                    needsAccessibility ? Color.orange :
                                    (isEnabled && isAppEnabled) ? Color.secondary : Color.secondary.opacity(0.75)
                                )
                                .lineLimit(1)
                                .truncationMode(.tail)
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
                let clampedPill = min(1, max(0, pillProgress))
                if clampedPill > 0.001 {
                    let pillOn = configManager.config.callControls.showFloatingMicIndicator
                    Button {
                        callControls.toggleFloatingPillVisibility()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: pillOn ? "capsule.inset.filled" : "capsule")
                                .toolboxFont(.system(size: 10, weight: .semibold))
                                .foregroundStyle(pillOn ? .green : .secondary)
                            Text("Pill")
                                .toolboxFont(.caption2.weight(.semibold))
                                .foregroundStyle(pillOn ? .primary : .secondary)
                                .lineLimit(1)
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
                    .opacity(Double(clampedPill))
                    .scaleEffect(0.88 + 0.12 * clampedPill, anchor: .trailing)
                    .allowsHitTesting(isAppEnabled && isEnabled && clampedPill > 0.99)
                    .pointerCursor(isAppEnabled && isEnabled && clampedPill > 0.99)
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
