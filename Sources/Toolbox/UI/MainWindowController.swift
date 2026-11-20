import AppKit
import SwiftUI

enum SidebarDestination: Hashable {
    case dashboard
    case module(String)
    case jsonConfig
    case settings
    case support
    case developer(DeveloperSection)

    var isDeveloper: Bool {
        if case .developer = self { return true }
        return false
    }

    @MainActor
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .module(let id):
            return ModuleRegistry.shared.module(withID: id)?.name ?? "Module"
        case .jsonConfig: return "JSON Config"
        case .settings: return "Settings & About"
        case .support: return "Support Toolbox"
        case .developer(let section): return section.title
        }
    }
}

enum WindowNavigationDirection: Equatable {
    case back
    case forward
}

@MainActor
final class NavigationState: ObservableObject {
    private static let maxHistoryCount = 50

    @Published var selection: SidebarDestination = .dashboard
    @Published var isSidebarVisible: Bool = true
    @Published private(set) var history: [SidebarDestination] = []
    @Published private(set) var forwardHistory: [SidebarDestination] = []

    var previousDestination: SidebarDestination? {
        history.last ?? (selection != .dashboard ? .dashboard : nil)
    }

    var nextDestination: SidebarDestination? {
        forwardHistory.last
    }

    var canGoBack: Bool {
        previousDestination != nil
    }

    var canGoForward: Bool {
        nextDestination != nil
    }

    @MainActor
    var backHelpText: String {
        previousDestination.map { "Back to \($0.title) (⌘[)" } ?? "Back (⌘[)"
    }

    @MainActor
    var forwardHelpText: String {
        nextDestination.map { "Forward to \($0.title) (⌘])" } ?? "Forward (⌘])"
    }

    func navigate(to destination: SidebarDestination) {
        guard destination != selection else { return }
        pushHistory(selection)
        forwardHistory.removeAll()
        selection = destination
    }

    @discardableResult
    func goBack() -> Bool {
        if let previous = history.popLast() {
            pushForward(selection)
            selection = previous
            return true
        } else if selection != .dashboard {
            pushForward(selection)
            selection = .dashboard
            return true
        }
        return false
    }

    @discardableResult
    func goForward() -> Bool {
        guard let next = forwardHistory.popLast() else { return false }
        pushHistory(selection)
        selection = next
        return true
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func pruneDeveloperDestinations(fallback: SidebarDestination = .settings) {
        history.removeAll(where: \.isDeveloper)
        forwardHistory.removeAll(where: \.isDeveloper)
        if selection.isDeveloper {
            selection = fallback
        }
        history = Self.deduplicatedStack(history, excludingTopMatching: selection)
        forwardHistory = Self.deduplicatedStack(forwardHistory, excludingTopMatching: selection)
    }

    internal func resetHistoryForTesting(selection: SidebarDestination = .dashboard) {
        history.removeAll()
        forwardHistory.removeAll()
        self.selection = selection
    }

    private func pushHistory(_ destination: SidebarDestination) {
        history.append(destination)
        if history.count > Self.maxHistoryCount {
            history.removeFirst(history.count - Self.maxHistoryCount)
        }
    }

    private func pushForward(_ destination: SidebarDestination) {
        forwardHistory.append(destination)
        if forwardHistory.count > Self.maxHistoryCount {
            forwardHistory.removeFirst(forwardHistory.count - Self.maxHistoryCount)
        }
    }

    private static func deduplicatedStack(
        _ stack: [SidebarDestination],
        excludingTopMatching current: SidebarDestination
    ) -> [SidebarDestination] {
        var result: [SidebarDestination] = []
        result.reserveCapacity(stack.count)
        for item in stack where result.last != item {
            result.append(item)
        }
        while result.last == current {
            result.removeLast()
        }
        return result
    }
}

@MainActor
internal final class ToolboxWindow: NSWindow {
    weak var navigationState: NavigationState?

    static func navigationDirection(forOtherMouseButton buttonNumber: Int) -> WindowNavigationDirection? {
        switch buttonNumber {
        case 3: return .back
        case 4: return .forward
        default: return nil
        }
    }

    static func navigationDirection(forSwipeDeltaX deltaX: CGFloat) -> WindowNavigationDirection? {
        if deltaX > 0 { return .back }
        if deltaX < 0 { return .forward }
        return nil
    }

    private var canPerformWindowNavigation: Bool {
        attachedSheet == nil
            && sheets.isEmpty
            && !PermissionsManager.shared.isPresentingOnboardingModal
            && PointerCursorNSView.activeDragCursor == nil
    }

    @discardableResult
    private func performNavigation(_ direction: WindowNavigationDirection) -> Bool {
        guard canPerformWindowNavigation, let navigationState else { return false }
        let canNavigate = (direction == .back) ? navigationState.canGoBack : navigationState.canGoForward
        guard canNavigate else { return false }
        if firstResponder is NSText {
            makeFirstResponder(nil)
        }
        let didNavigate: Bool
        switch direction {
        case .back:
            didNavigate = navigationState.goBack()
        case .forward:
            didNavigate = navigationState.goForward()
        }
        if didNavigate {
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    PointerCursorNSView.syncCursor(in: self)
                }
            }
        }
        return didNavigate
    }

    override var contentMinSize: NSSize {
        get { super.contentMinSize }
        set {
            super.contentMinSize = NSSize(
                width: max(newValue.width, MainWindowController.minimumContentSize.width),
                height: max(newValue.height, MainWindowController.minimumContentSize.height)
            )
        }
    }

    override var minSize: NSSize {
        get { super.minSize }
        set {
            super.minSize = NSSize(
                width: max(newValue.width, MainWindowController.minimumContentSize.width),
                height: max(newValue.height, MainWindowController.minimumContentSize.height + 28)
            )
        }
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .otherMouseDown:
            if let direction = Self.navigationDirection(forOtherMouseButton: event.buttonNumber),
               canPerformWindowNavigation {
                performNavigation(direction)
                return
            }
        case .otherMouseUp:
            if Self.navigationDirection(forOtherMouseButton: event.buttonNumber) != nil,
               canPerformWindowNavigation {
                return
            }
        case .swipe:
            if let direction = Self.navigationDirection(forSwipeDeltaX: event.deltaX),
               canPerformWindowNavigation {
                performNavigation(direction)
                return
            }
        default:
            break
        }
        if event.type == .leftMouseDown,
           let textView = firstResponder as? NSTextView {
            let ptInTextView = textView.convert(event.locationInWindow, from: nil)
            if !textView.bounds.contains(ptInTextView) {
                makeFirstResponder(nil)
            }
        }
        super.sendEvent(event)
        switch event.type {
        case .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate, .leftMouseDown, .leftMouseUp, .scrollWheel:
            PointerCursorNSView.syncCursor(in: self)
            if event.type == .leftMouseDown || event.type == .leftMouseUp {
                RunLoop.main.perform(inModes: [.common]) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        PointerCursorNSView.syncCursor(in: self)
                    }
                }
            }
        default:
            break
        }
    }

    override func swipe(with event: NSEvent) {
        if let direction = Self.navigationDirection(forSwipeDeltaX: event.deltaX),
           canPerformWindowNavigation {
            performNavigation(direction)
            return
        }
        super.swipe(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, canPerformWindowNavigation {
            let relevantMods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if relevantMods == .command {
                switch event.charactersIgnoringModifiers {
                case "[":
                    performNavigation(.back)
                    return true
                case "]":
                    performNavigation(.forward)
                    return true
                default:
                    if !(firstResponder is NSText) {
                        if event.keyCode == 123 { // kVK_LeftArrow
                            performNavigation(.back)
                            return true
                        }
                        if event.keyCode == 124 { // kVK_RightArrow
                            performNavigation(.forward)
                            return true
                        }
                    }
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    static let defaultContentSize = NSSize(width: 1140, height: 760)
    static let minimumContentSize = NSSize(width: 820, height: 560)

    let navState = NavigationState()
    private var window: NSWindow?
    internal var currentWindow: NSWindow? { window }

    private override init() {
        super.init()
    }

    @discardableResult
    internal func ensureWindow() -> NSWindow {
        if let window { return window }

        let rootView = MainSplitView(navState: navState)
        let hosting = NSHostingView(rootView: rootView)
        // Prevent SwiftUI's ScrollView from overriding NSWindow's minimum size constraints.
        hosting.sizingOptions = []

        let win = ToolboxWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Toolbox"
        win.navigationState = navState
        ToolboxTheme.applyDarkAppearance(to: win)
        win.isReleasedWhenClosed = false
        win.titlebarAppearsTransparent = false
        win.acceptsMouseMovedEvents = true
        win.delegate = self
        win.contentView = hosting
        win.layoutIfNeeded()
        win.contentMinSize = Self.minimumContentSize
        win.minSize = NSSize(width: max(win.minSize.width, Self.minimumContentSize.width), height: max(win.minSize.height, Self.minimumContentSize.height + 28))
        win.center()
        self.window = win
        return win
    }

    static func screen(containing point: NSPoint, in screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main ?? screens.first
    }

    static func centeredWindowFrame(
        currentSize: NSSize,
        onScreenVisibleFrame visibleFrame: NSRect
    ) -> NSRect {
        let width = min(max(currentSize.width, minimumContentSize.width), visibleFrame.width)
        let height = min(max(currentSize.height, minimumContentSize.height + 28), visibleFrame.height)
        let minX = visibleFrame.minX
        let maxX = max(minX, visibleFrame.maxX - width)
        let minY = visibleFrame.minY
        let maxY = max(minY, visibleFrame.maxY - height)
        let originX = min(max(round(visibleFrame.midX - width / 2), minX), maxX)
        let originY = min(max(round(visibleFrame.midY - height / 2), minY), maxY)
        return NSRect(x: originX, y: originY, width: width, height: height)
    }

    @discardableResult
    internal func repositionWindowToScreen(
        containing point: NSPoint,
        window win: NSWindow,
        forceIfVisibleOnOtherScreen: Bool = true
    ) -> NSScreen? {
        guard let targetScreen = Self.screen(containing: point) else { return nil }
        let windowCenter = NSPoint(x: win.frame.midX, y: win.frame.midY)
        let isCenterOnTargetScreen = targetScreen.frame.contains(windowCenter)
        let isSameAppKitScreen = (win.screen === targetScreen) && isCenterOnTargetScreen
        let shouldReposition = win.isVisible
            ? (forceIfVisibleOnOtherScreen && !isSameAppKitScreen)
            : !isCenterOnTargetScreen
        if shouldReposition {
            let nextFrame = Self.centeredWindowFrame(
                currentSize: win.frame.size,
                onScreenVisibleFrame: targetScreen.visibleFrame
            )
            win.setFrame(nextFrame, display: win.isVisible)
        }
        return targetScreen
    }

    /// Opens or focuses the main window. Pass `nil` to preserve the user's current page.
    func show(destination: SidebarDestination? = nil) {
        if let destination {
            navState.navigate(to: destination)
        }

        let win = ensureWindow()
        if win.isMiniaturized {
            win.deminiaturize(nil)
        }
        repositionWindowToScreen(containing: NSEvent.mouseLocation, window: win)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(nil)
        win.contentMinSize = Self.minimumContentSize
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, Self.minimumContentSize.width),
            height: max(frameSize.height, Self.minimumContentSize.height + 28)
        )
    }

    static func makeRootView(navState: NavigationState) -> some View {
        MainSplitView(navState: navState)
    }
}

struct MainSplitView: View {
    @ObservedObject var navState: NavigationState
    @ObservedObject private var registry = ModuleRegistry.shared
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var developerMode = DeveloperModeManager.shared
    @ObservedObject private var healthChecks = DeveloperHealthCheckRunner.shared
    @ObservedObject private var hotKeys = HotKeyManager.shared
    @ObservedObject private var callControls = ModuleRegistry.shared.callControls
    @ObservedObject private var screenOCR = ModuleRegistry.shared.screenOCR
    @ObservedObject private var supportState = SupportState.shared

    var body: some View {
        HStack(spacing: 0) {
            if navState.isSidebarVisible {
                sidebarView
                    .frame(width: 228)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Divider()
            }

            VStack(spacing: 0) {
                if let newVer = updateManager.pendingUpdateVersion {
                    updateAvailableBanner(version: newVer)
                }

                if navState.selection != .dashboard {
                    detailTopBar
                }

                Group {
                    switch navState.selection {
                    case .dashboard:
                        DashboardView(
                            onSelectModule: { id in navState.navigate(to: .module(id)) }
                        )
                    case .module(let id):
                        if let module = registry.module(withID: id) {
                            ModuleDetailContainerView(module: module)
                        } else {
                            Text("Module not found")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    case .jsonConfig:
                        ConfigEditorView()
                    case .settings:
                        SettingsView()
                    case .support:
                        SupportView()
                    case .developer(let section):
                        if developerMode.isUnlocked {
                            DeveloperToolsView(section: section)
                        } else {
                            SettingsView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.16), value: navState.isSidebarVisible)
        .onChange(of: developerMode.isUnlocked) { _, unlocked in
            if !unlocked {
                navState.pruneDeveloperDestinations(fallback: .settings)
            }
        }
        .background {
            ZStack {
                Button("") {
                    guard !permissions.isPresentingOnboardingModal else { return }
                    navState.goBack()
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("") {
                    guard !permissions.isPresentingOnboardingModal else { return }
                    navState.goForward()
                }
                .keyboardShortcut("]", modifiers: .command)
            }
            .hidden()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    navState.toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(navState.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                .pointerCursor()
            }

            ToolbarItemGroup(placement: .navigation) {
                Button {
                    navState.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!navState.canGoBack)
                .help(navState.backHelpText)
                .accessibilityLabel("Back")
                .pointerCursor(navState.canGoBack)

                Button {
                    navState.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!navState.canGoForward)
                .help(navState.forwardHelpText)
                .accessibilityLabel("Forward")
                .pointerCursor(navState.canGoForward)
            }

            if supportState.isSupporterUnlocked {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        navState.navigate(to: .support)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.caption2.weight(.bold))
                            Text("Supporter")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.pink)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            Color.pink.opacity(0.14),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    Color.pink.opacity(0.35),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Thank you for supporting Toolbox!")
                    .pointerCursor()
                }
            }
        }
        .overlay {
            if permissions.isPresentingOnboardingModal {
                ZStack {
                    Color.black.opacity(0.45)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            permissions.dismissOnboardingModal(markSeen: true)
                        }

                    AccessibilityOnboardingModalView(permissions: permissions)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(nsColor: .windowBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 10)
                        .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: permissions.isPresentingOnboardingModal)
        .toolboxDarkAppearance()
    }

    private var sidebarView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Overview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)

                        Button {
                            navState.navigate(to: .dashboard)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.grid.2x2")
                                    .foregroundStyle(navState.selection == .dashboard ? Color.white : ToolboxTheme.accentBlue)
                                Text("Dashboard")
                                    .font(.callout.weight(.medium))
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                navState.selection == .dashboard
                                    ? ToolboxTheme.accentBlue
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .foregroundStyle(navState.selection == .dashboard ? .white : .primary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .pointerCursor()
                        .id(SidebarDestination.dashboard)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Modules")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)

                        ForEach(registry.modules, id: \.id) { module in
                            let dest = SidebarDestination.module(module.id)
                            let isSelected = navState.selection == dest
                            Button {
                                navState.navigate(to: dest)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: module.symbolName)
                                        .foregroundStyle(isSelected ? .white : module.accentColor)
                                        .frame(width: 16)
                                    Text(module.name)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Spacer()
                                    Circle()
                                        .fill(
                                            !module.isEnabled(in: configManager.config)
                                                ? Color.secondary.opacity(0.35)
                                                : (!configManager.config.general.appEnabled
                                                    || (module.requiresAccessibility && !permissions.isAccessibilityGranted)
                                                    || (module as? ScreenOCRModule)?.screenRecordingGranted == false
                                                    ? Color.orange
                                                    : (!module.supportsEnableToggle
                                                        ? (module.isRunning ? Color.red : Color.blue)
                                                        : Color.green))
                                        )
                                        .frame(width: 7, height: 7)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    isSelected ? ToolboxTheme.accentBlue : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                                .foregroundStyle(isSelected ? .white : .primary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .pointerCursor()
                            .id(dest)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Configuration")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)

                        sidebarConfigItem(
                            title: "JSON Config",
                            symbol: "curlybraces",
                            destination: .jsonConfig
                        )
                        sidebarConfigItem(
                            title: "Settings & About",
                            symbol: "gearshape",
                            destination: .settings,
                            badge: updateManager.pendingUpdateVersion.map { "v\($0)" }
                        )
                        sidebarConfigItem(
                            title: "Support Toolbox",
                            symbol: "heart.fill",
                            symbolColor: .pink,
                            destination: .support,
                            badge: supportState.isSupporterUnlocked ? "♥" : nil,
                            badgeColor: .pink
                        )
                    }

                    if developerMode.isUnlocked {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Developer")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)

                            ForEach(DeveloperSection.allCases) { section in
                                let badgeInfo = developerBadge(for: section)
                                sidebarConfigItem(
                                    title: section.title,
                                    symbol: section.symbolName,
                                    destination: .developer(section),
                                    badge: badgeInfo?.text,
                                    badgeColor: badgeInfo?.color ?? .blue
                                )
                            }
                        }
                    }

                    Spacer()
                }
                .padding(12)
            }
            .background(Color.primary.opacity(0.03))
            .onChange(of: navState.selection) { _, destination in
                proxy.scrollTo(destination)
            }
        }
    }

    private func sidebarConfigItem(
        title: String,
        symbol: String,
        symbolColor: Color = .secondary,
        destination: SidebarDestination,
        badge: String? = nil,
        badgeColor: Color = .blue
    ) -> some View {
        let isSelected = navState.selection == destination
        return Button {
            navState.navigate(to: destination)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(isSelected ? .white : symbolColor)
                    .frame(width: 16)
                Text(title)
                    .font(.callout)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? ToolboxTheme.accentBlue : .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.white : badgeColor, in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isSelected ? ToolboxTheme.accentBlue : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .foregroundStyle(isSelected ? .white : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerCursor()
        .id(destination)
    }

    private func developerBadge(for section: DeveloperSection) -> (text: String, color: Color)? {
        switch section {
        case .updates:
            return (updateManager.isSimulatingState || updateManager.isUsingCustomScheduleInterval)
                ? ("SIM", .orange)
                : nil
        case .uiAndModules:
            return permissions.simulatedAccessibilityGranted != nil ? ("SIM", .orange) : nil
        case .screenOCR:
            return screenOCR.isRunningPipelineTest || screenOCR.isRunningSelfCheck ? ("TEST", .orange) : nil
        case .callControls:
            return callControls.developerSimulation != nil ? ("SIM", .orange) : nil
        case .eventsAndTaps:
            return nil
        case .hotKeysAndConfig:
            if !hotKeys.registrationErrors.isEmpty {
                return ("\(hotKeys.registrationErrors.count)", .red)
            }
            return nil
        case .checksAndDiagnostics:
            if healthChecks.failCount > 0 {
                return ("\(healthChecks.failCount)", .red)
            }
            return nil
        }
    }

    private func updateAvailableBanner(version: String) -> some View {
        let sizeNote = updateManager.formattedPendingSize.map { " (\($0))" } ?? ""
        return Button {
            updateManager.openPendingUpdateOrCheck()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption.weight(.bold))
                Text("Toolbox v\(version) is available\(sizeNote) - click to review and update")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text("Update…")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.22), in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.16, green: 0.45, blue: 0.94), Color(red: 0.10, green: 0.36, blue: 0.84)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerCursor()
    }

    private var detailTopBar: some View {
        BackToDashboardBar {
            navState.navigate(to: .dashboard)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}
