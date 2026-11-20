import AppKit
import Darwin
import SwiftUI

enum PortFilterMode: String, CaseIterable, Identifiable {
    case all = "All"
    case devPorts = "Dev Ports"
    case elevated = "Elevated"

    var id: String { rawValue }
}

struct HoverTooltipTarget: Equatable, Sendable {
    let id: String
    let text: String
    let screenRect: CGRect
}

@MainActor
final class PortKillerTooltipState {
    private(set) var target: HoverTooltipTarget?
    var onPresent: ((HoverTooltipTarget?) -> Void)?

    private var workItem: DispatchWorkItem?
    private var pendingID: String?

    func setTooltip(_ newTarget: HoverTooltipTarget?, clearingID: String? = nil) {
        if let newTarget {
            workItem?.cancel()
            pendingID = newTarget.id
            if target?.id == newTarget.id {
                if target != newTarget {
                    target = newTarget
                    onPresent?(newTarget)
                }
                return
            }
            if target != nil {
                target = nil
                onPresent?(nil)
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pendingID == newTarget.id else { return }
                self.target = newTarget
                self.onPresent?(newTarget)
            }
            workItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } else if let clearingID {
            if pendingID == clearingID {
                workItem?.cancel()
                workItem = nil
                pendingID = nil
            }
            if target?.id == clearingID {
                target = nil
                onPresent?(nil)
            }
        } else {
            workItem?.cancel()
            workItem = nil
            pendingID = nil
            if target != nil {
                target = nil
                onPresent?(nil)
            }
        }
    }
}

/// Borderless, click-through floating tooltip bubble rendered outside the popover's
/// `NSHostingView` so tooltip appearance never invalidates cursor rects or triggers flashes.
struct PortKillerTooltipBubbleView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 240)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.24), radius: 5, y: 2)
            .padding(6)
    }
}

@MainActor
final class PortKillerPopoverUIState: ObservableObject {
    @Published var query: String = ""
    @Published var filterMode: PortFilterMode = .all
    @Published var selectedKey: String?
    @Published var openSequence: Int = 0

    func resetForOpen(ports: [ListeningPort]) {
        query = ""
        selectedKey = ports.first?.id
        openSequence &+= 1
    }

    func selectedPort(in list: [ListeningPort]) -> ListeningPort? {
        if let key = selectedKey, let found = list.first(where: { $0.id == key }) {
            return found
        }
        return list.first
    }

    func moveSelection(delta: Int, in list: [ListeningPort]) {
        guard !list.isEmpty else {
            selectedKey = nil
            return
        }
        guard let currentKey = selectedKey,
              let idx = list.firstIndex(where: { $0.id == currentKey }) else {
            selectedKey = delta >= 0 ? list.first?.id : list.last?.id
            return
        }
        let next = min(max(0, idx + delta), list.count - 1)
        selectedKey = list[next].id
    }
}

@MainActor
final class PortKillerModule: NSObject, ToolboxModule, ObservableObject {
    let id = "port_killer"
    let name = "Port Killer"
    let tagline = "Inspect active listening TCP ports and kill stuck dev servers in one click."
    let aboutSummary = "Surfaces all active listening TCP ports, including root and other-user services that plain lsof hides, in a searchable floating popover and live table. Stop or force-kill stuck servers in one click, with native macOS administrator authorization when targeting elevated processes."
    let featureTips = [
        "Press your shortcut (default ⌃ ⌥ ⌘ P) anywhere to open the Port Killer popover near your cursor.",
        "Use ↑ / ↓ and Return to stop the selected port, ⌥ Return to force kill (SIGKILL), or Esc to dismiss.",
        "Root and other-user listeners are shown with an Elevated badge and prompt via macOS Touch ID / password when stopped.",
        "Pin favorite dev ports (like 3000, 5173, 8000, 8080) so they always float to the top of the list."
    ]
    let symbolName = "network"
    let accentColor = Color.indigo
    let category: ModuleCategory = .developer
    let requiresAccessibility = false

    private(set) var isRunning = false
    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var portsByPID: [pid_t: [Int]] = [:]
    @Published private(set) var isScanning = false
    private(set) var lastScannedAt: Date?
    @Published private(set) var stuckPortKeys: Set<String> = []
    @Published private(set) var killingPortKeys: Set<String> = []
    @Published var config: PortKillerConfig = PortKillerConfig()

    let hotKeyName = "port_killer.toggle"
    let popoverState = PortKillerPopoverUIState()
    let tooltipState = PortKillerTooltipState()

    private(set) var panel: NSPanel?
    private(set) var tooltipPanel: NSPanel?
    private var tooltipHostingView: NSHostingView<PortKillerTooltipBubbleView>?
    private var outsideClickMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var localScrollMonitor: Any?
    private var scrollBoundsObserver: Any?
    private var refreshTimer: Timer?
    private var isSettingsVisible = false
    private var scanTask: Task<Void, Never>?

    var isPopoverVisible: Bool {
        panel?.isVisible ?? false
    }

    func isEnabled(in config: ToolboxConfig) -> Bool {
        config.portKiller.enabled
    }

    func setEnabled(_ enabled: Bool, in config: inout ToolboxConfig) {
        config.portKiller.enabled = enabled
    }

    func shortcutText(in config: ToolboxConfig) -> String? {
        config.portKiller.shortcut.isEmpty ? nil : config.portKiller.shortcut.displayString
    }

    func reload(with fullConfig: ToolboxConfig) {
        self.config = fullConfig.portKiller

        if config.enabled {
            if !isRunning {
                start()
            } else {
                registerHotKey()
                syncRefreshTimer()
            }
        } else {
            if isRunning {
                stop()
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        registerHotKey()
        isRunning = true
        syncRefreshTimer()
    }

    func stop() {
        hidePopover()
        refreshTimer?.invalidate()
        refreshTimer = nil
        scanTask?.cancel()
        scanTask = nil
        HotKeyManager.shared.unregister(name: hotKeyName)
        isRunning = false
    }

    func makeSettingsView() -> AnyView {
        AnyView(PortKillerSettingsView(module: self))
    }

    // MARK: - Scanning & Refresh Lifecycle

    func setSettingsVisible(_ visible: Bool) {
        guard isSettingsVisible != visible else { return }
        isSettingsVisible = visible
        if visible {
            refreshPorts()
        }
        syncRefreshTimer()
    }

    func refreshPorts(showSpinner: Bool = true) {
        scanTask?.cancel()
        if showSpinner || ports.isEmpty {
            isScanning = true
        }
        scanTask = Task { @MainActor [weak self] in
            let scanned = await PortScanner.scanListeningPorts()
            guard let self, !Task.isCancelled else { return }
            self.applyScannedPorts(scanned)
        }
    }

    private func syncRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        let shouldPoll = isRunning && (isPopoverVisible || isSettingsVisible) && config.refreshIntervalSeconds > 0
        guard shouldPoll else { return }

        let interval = TimeInterval(max(2, config.refreshIntervalSeconds))
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPorts(showSpinner: false)
            }
        }
    }

    // MARK: - Filtering & Sorting

    func filteredPorts(
        query: String,
        filterMode: PortFilterMode = .all,
        hideSystem: Bool? = nil
    ) -> [ListeningPort] {
        let shouldHideSystem = hideSystem ?? config.hideSystemProcesses
        let favSet = Set(config.favoritePorts)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let filtered = ports.filter { entry in
            if shouldHideSystem && entry.isSystemDaemon {
                return false
            }
            switch filterMode {
            case .all:
                break
            case .devPorts:
                if !favSet.contains(entry.port) && !PortScanner.commonDevPorts.contains(entry.port) {
                    return false
                }
            case .elevated:
                if !entry.requiresElevation {
                    return false
                }
            }
            if !trimmedQuery.isEmpty {
                let portMatches = String(entry.port).contains(trimmedQuery)
                let pidMatches = String(entry.pid).contains(trimmedQuery)
                let nameMatches = entry.processName.localizedCaseInsensitiveContains(trimmedQuery)
                let cwdMatches = entry.workingDirectory?.localizedCaseInsensitiveContains(trimmedQuery) ?? false
                let pathMatches = entry.executablePath?.localizedCaseInsensitiveContains(trimmedQuery) ?? false
                let addrMatches = entry.addresses.contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
                if !(portMatches || pidMatches || nameMatches || cwdMatches || pathMatches || addrMatches) {
                    return false
                }
            }
            return true
        }

        return filtered.sorted { lhs, rhs in
            let lhsFav = favSet.contains(lhs.port)
            let rhsFav = favSet.contains(rhs.port)
            if lhsFav != rhsFav { return lhsFav }
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            return lhs.pid < rhs.pid
        }
    }

    private func applyScannedPorts(_ scanned: [ListeningPort]) {
        var grouped: [pid_t: [Int]] = [:]
        for item in scanned {
            grouped[item.pid, default: []].append(item.port)
        }
        for (pid, list) in grouped where list.count > 1 {
            grouped[pid] = list.sorted()
        }
        if self.portsByPID != grouped {
            self.portsByPID = grouped
        }
        if self.ports != scanned {
            self.ports = scanned
        }
        self.lastScannedAt = Date()
        if self.isScanning {
            self.isScanning = false
        }

        let activeIDs = Set(scanned.map(\.id))
        let nextStuck = self.stuckPortKeys.intersection(activeIDs)
        if nextStuck != self.stuckPortKeys {
            self.stuckPortKeys = nextStuck
        }
        let nextKilling = self.killingPortKeys.intersection(activeIDs)
        if nextKilling != self.killingPortKeys {
            self.killingPortKeys = nextKilling
        }
    }

    func otherPorts(for entry: ListeningPort) -> [Int] {
        guard let all = portsByPID[entry.pid], all.count > 1 else { return [] }
        return all.filter { $0 != entry.port }
    }

    // MARK: - Favorites

    func isFavorite(_ port: Int) -> Bool {
        config.favoritePorts.contains(port)
    }

    func toggleFavoritePort(_ port: Int) {
        var next = ConfigManager.shared.config.portKiller.favoritePorts
        if let idx = next.firstIndex(of: port) {
            next.remove(at: idx)
        } else {
            next.append(port)
            next.sort()
        }
        ConfigManager.shared.config.portKiller.favoritePorts = next
    }

    // MARK: - Safety & Process Termination

    nonisolated static func validateKillTarget(pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        guard pid != ProcessInfo.processInfo.processIdentifier else { return false }
        return true
    }

    func killPort(_ entry: ListeningPort, signal: PortKillSignal? = nil) {
        let chosenSignal = signal ?? config.defaultSignal
        guard Self.validateKillTarget(pid: entry.pid) else {
            HUDToast.shared.show(
                title: "Refused to terminate protected system PID \(entry.pid)",
                symbol: "shield.slash.fill",
                tint: .red
            )
            return
        }

        killingPortKeys.insert(entry.id)

        if entry.requiresElevation {
            killWithAdminPrivileges(entry: entry, signal: chosenSignal)
            return
        }

        let result = Darwin.kill(entry.pid, chosenSignal.posixSignal)
        if result == 0 {
            handleSuccessfulSignal(entry: entry, signal: chosenSignal, elevated: false)
            return
        }

        let err = errno
        switch err {
        case ESRCH:
            killingPortKeys.remove(entry.id)
            stuckPortKeys.remove(entry.id)
            refreshPorts()
        case EPERM:
            killWithAdminPrivileges(entry: entry, signal: chosenSignal)
        default:
            killingPortKeys.remove(entry.id)
            let msg = String(cString: strerror(err))
            HUDToast.shared.show(
                title: "Failed to stop :\(entry.port) (\(msg))",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
    }

    private func handleSuccessfulSignal(entry: ListeningPort, signal: PortKillSignal, elevated: Bool) {
        let suffix = elevated ? " (admin)" : ""
        switch signal {
        case .sigkill:
            stuckPortKeys.remove(entry.id)
            HUDToast.shared.show(
                title: "Killed \(entry.processName) on :\(entry.port)\(suffix)",
                symbol: "bolt.slash.fill",
                tint: .red
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self else { return }
                self.killingPortKeys.remove(entry.id)
                self.refreshPorts()
            }
        case .sigterm:
            HUDToast.shared.show(
                title: "Sent stop signal to \(entry.processName) (:\(entry.port))\(suffix)",
                symbol: "stop.circle.fill",
                tint: .indigo
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.killingPortKeys.remove(entry.id)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let scanned = await PortScanner.scanListeningPorts()
                    self.applyScannedPorts(scanned)
                    if scanned.contains(where: { $0.id == entry.id }) {
                        self.stuckPortKeys.insert(entry.id)
                    } else {
                        self.stuckPortKeys.remove(entry.id)
                    }
                }
            }
        }
    }

    private func killWithAdminPrivileges(entry: ListeningPort, signal: PortKillSignal) {
        let pid = entry.pid
        let sigNum = signal.posixNumber

        Task.detached(priority: .userInitiated) {
            let outcome = Self.executeAdminKillScript(pid: pid, signalNumber: sigNum)
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch outcome {
                case .success:
                    self.handleSuccessfulSignal(entry: entry, signal: signal, elevated: true)
                case .cancelled:
                    self.killingPortKeys.remove(entry.id)
                    HUDToast.shared.show(
                        title: "Authorization canceled",
                        symbol: "xmark.shield",
                        tint: .secondary
                    )
                case .failed(let message):
                    self.killingPortKeys.remove(entry.id)
                    HUDToast.shared.show(
                        title: message,
                        symbol: "lock.trianglebadge.exclamationmark",
                        tint: .orange
                    )
                }
            }
        }
    }

    private enum AdminKillOutcome: Sendable {
        case success
        case cancelled
        case failed(String)
    }

    private nonisolated static func executeAdminKillScript(pid: pid_t, signalNumber: Int32) -> AdminKillOutcome {
        let source = "do shell script \"/bin/kill -\(signalNumber) \(pid)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            return .failed("Unable to initialize administrator prompt")
        }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 {
                return .cancelled
            }
            let message = (errorInfo[NSAppleScript.errorBriefMessage] as? String)
                ?? (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? "Permission denied (error \(code))"
            return .failed(message)
        }
        return .success
    }

    // MARK: - Hotkey & Floating NSPanel Popover

    private func registerHotKey() {
        HotKeyManager.shared.register(name: hotKeyName, shortcut: config.shortcut) { [weak self] in
            self?.togglePopover()
        }
    }

    func togglePopover() {
        if isPopoverVisible {
            hidePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        let visible = filteredPorts(query: "", filterMode: popoverState.filterMode)
        popoverState.resetForOpen(ports: visible)
        tooltipState.setTooltip(nil)

        let width = CGFloat(max(360, min(760, config.popoverWidth)))
        let height = CGFloat(max(300, min(780, config.popoverHeight)))
        let panel = ensurePanel(width: width, height: height)

        let mouseLocation = NSEvent.mouseLocation
        var origin = NSPoint(x: mouseLocation.x - width / 2, y: mouseLocation.y - height - 14)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            origin.x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - width - 8)
            origin.y = min(max(origin.y, visibleFrame.minY + 8), visibleFrame.maxY - height - 8)
        }

        tooltipState.onPresent = { [weak self] target in
            self?.updateTooltipPanel(with: target)
        }
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.focusFirstEditableTextField()
        installPopoverMonitors(for: panel)
        DispatchQueue.main.async { [weak panel] in
            if let panel, panel.isVisible {
                panel.focusFirstEditableTextField()
                PointerCursorNSView.syncCursor(in: panel)
            }
        }

        refreshPorts()
        syncRefreshTimer()
    }

    func hidePopover() {
        tooltipState.setTooltip(nil)
        tooltipState.onPresent = nil
        hideTooltipPanel()
        removePopoverMonitors()
        panel?.orderOut(nil)
        syncRefreshTimer()
    }

    @discardableResult
    func ensurePanel(width: CGFloat = 460, height: CGFloat = 480) -> NSPanel {
        if let panel { return panel }

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        newPanel.level = .statusBar
        newPanel.acceptsMouseMovedEvents = true
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isMovableByWindowBackground = true
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        visualEffect.material = .windowBackground
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true

        let contentView = PortKillerPopoverView(
            module: self,
            uiState: popoverState,
            onClose: { [weak self] in
                self?.hidePopover()
            }
        )
        let hostingView = PointerCursorHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor)
        ])

        newPanel.contentView = visualEffect
        self.panel = newPanel
        return newPanel
    }

    func updateTooltipPanel(with target: HoverTooltipTarget?, requireMouseInside: Bool = true) {
        guard let parentPanel = panel, parentPanel.isVisible, let target else {
            hideTooltipPanel()
            return
        }
        if requireMouseInside && !parentPanel.frame.contains(NSEvent.mouseLocation) {
            tooltipState.setTooltip(nil)
            return
        }

        let bubbleView = PortKillerTooltipBubbleView(text: target.text)
        let tipPanel: NSPanel
        let hosting: NSHostingView<PortKillerTooltipBubbleView>
        if let existingPanel = tooltipPanel, let existingHost = tooltipHostingView {
            tipPanel = existingPanel
            hosting = existingHost
            hosting.rootView = bubbleView
        } else {
            let newTip = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 220, height: 38),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newTip.isFloatingPanel = true
            newTip.level = NSWindow.Level(rawValue: parentPanel.level.rawValue + 1)
            newTip.isOpaque = false
            newTip.backgroundColor = .clear
            newTip.hasShadow = false
            newTip.hidesOnDeactivate = false
            newTip.ignoresMouseEvents = true
            newTip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

            let newHost = NSHostingView(rootView: bubbleView)
            newTip.contentView = newHost
            tooltipPanel = newTip
            tooltipHostingView = newHost
            tipPanel = newTip
            hosting = newHost
        }

        hosting.layoutSubtreeIfNeeded()
        let rawSize = hosting.fittingSize
        let size = NSSize(
            width: min(max(rawSize.width, 60), 264),
            height: min(max(rawSize.height, 28), 72)
        )

        let shadowInset: CGFloat = 6
        let parentFrame = parentPanel.frame
        let minX = parentFrame.minX + 8 - shadowInset
        let maxX = max(minX, parentFrame.maxX - 8 + shadowInset - size.width)
        var originX = min(max(target.screenRect.midX - size.width / 2, minX), maxX)

        // Position 4 pt visually below the hovered button; flip above only near the bottom edge.
        let belowOriginY = target.screenRect.minY - 4 + shadowInset - size.height
        let aboveOriginY = target.screenRect.maxY + 4 - shadowInset
        var originY = belowOriginY
        if belowOriginY + shadowInset < parentFrame.minY + 6,
           aboveOriginY + size.height - shadowInset <= parentFrame.maxY - 6 {
            originY = aboveOriginY
        }

        if let visible = parentPanel.screen?.visibleFrame {
            originX = min(max(originX, visible.minX + 4), max(visible.minX + 4, visible.maxX - size.width - 4))
            originY = min(max(originY, visible.minY + 4), max(visible.minY + 4, visible.maxY - size.height - 4))
        }

        tipPanel.setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height), display: true)
        if tipPanel.parent !== parentPanel {
            parentPanel.addChildWindow(tipPanel, ordered: .above)
        }
        tipPanel.orderFrontRegardless()
    }

    private func hideTooltipPanel() {
        guard let tipPanel = tooltipPanel else { return }
        tipPanel.parent?.removeChildWindow(tipPanel)
        tipPanel.orderOut(nil)
    }

    private func installPopoverMonitors(for panel: NSPanel) {
        removePopoverMonitors()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] _ in
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel, panel.isVisible else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    self.hidePopover()
                }
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }
            if event.window === panel && event.type == .leftMouseDown {
                self.tooltipState.setTooltip(nil)
            }
            if let window = event.window,
               window !== panel,
               window !== self.tooltipPanel,
               !NSStringFromClass(type(of: window)).contains("Menu"),
               !panel.frame.contains(NSEvent.mouseLocation) {
                self.hidePopover()
            }
            return event
        }

        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible, event.window === panel else { return event }
            self.tooltipState.setTooltip(nil)
            return event
        }

        scrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak panel] notification in
            let obj = notification.object as? NSClipView
            MainActor.assumeIsolated {
                guard let self, let panel, panel.isVisible,
                      obj?.window === panel else { return }
                self.tooltipState.setTooltip(nil)
                PointerCursorNSView.syncCursor(in: panel)
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }

            let visible = self.filteredPorts(
                query: self.popoverState.query,
                filterMode: self.popoverState.filterMode
            )

            switch event.keyCode {
            case 53: // Escape
                self.hidePopover()
                return nil
            case 125: // Down Arrow
                self.popoverState.moveSelection(delta: 1, in: visible)
                return nil
            case 126: // Up Arrow
                self.popoverState.moveSelection(delta: -1, in: visible)
                return nil
            case 36, 76: // Return / Keypad Enter
                if let entry = self.popoverState.selectedPort(in: visible) {
                    let forceKill = event.modifierFlags.contains(.option)
                    self.killPort(entry, signal: forceKill ? .sigkill : self.config.defaultSignal)
                    return nil
                }
                return event
            default:
                return event
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
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
            self.localScrollMonitor = nil
        }
        if let scrollBoundsObserver {
            NotificationCenter.default.removeObserver(scrollBoundsObserver)
            self.scrollBoundsObserver = nil
        }
    }
}
