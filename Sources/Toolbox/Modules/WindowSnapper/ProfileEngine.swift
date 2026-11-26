import AppKit
import ApplicationServices
import Foundation

struct ProfileRulePlacementEntry: Equatable, Sendable {
    let rule: ProfileAppRule
    let targetDisplay: ConnectedDisplay
    let zone: ResolvedZone
    var isAppOpen: Bool
    var hasWindow: Bool
    var isPositioned: Bool
    var consecutiveVerifiedHits: Int = 0
    var snapAttempts: Int = 0
    var didTriggerLaunchOrReopen: Bool = false
    var didRetryActivateReopen: Bool = false
    var lastClampedFramesByIndex: [Int: CGRect] = [:]
}

struct WorkspaceProfileRestoreSnapshot: Sendable {
    let profileID: String
    let profileName: String
    let previousActiveProfileID: String?
    let previousDisplayLayouts: [DisplayLayoutConfig]
    var preProfileWindows: [WindowSnapUndoItem]
    var preProfileElementsByUndoID: [String: AXElementBox]
    var unminimizedElements: [AXElementBox]
    var unhiddenBundleIDs: Set<String>
    var appsHiddenByProfile: Set<String>
    var newlyLaunchedBundleIDs: Set<String>
    let wasToolboxMainWindowVisible: Bool
    let previouslyFrontmostBundleID: String?
}

@MainActor
final class ProfileEngine: ObservableObject {
    @Published private(set) var isApplyingProfile: Bool = false
    @Published private(set) var suggestedTopologyProfileID: String? = nil
    @Published private(set) var activeRulePlacements: [String: ProfileRulePlacementEntry] = [:]

    private let axController: AXWindowController
    private let displayRegistry: DisplayRegistry
    private let overlayController: ZoneOverlayController

    private var launchObservers: [pid_t: AXObserver] = [:]
    private var launchTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var activeRuleObservers: [pid_t: AXObserver] = [:]
    private var workspaceLaunchObserver: NSObjectProtocol?
    private var activeWatchedRulesByBundleID: [String: (profile: WorkspaceProfile, rule: ProfileAppRule, config: WindowSnapperConfig)] = [:]
    private(set) var lastAutoTriggeredTopologyKey: String?
    private var placementTrackerTask: Task<Void, Never>?
    private var applyGeneration: UInt64 = 0
    /// Called whenever the restore snapshot is stored, replaced, or cleared.
    /// The module uses this to keep restore-availability UI state in sync.
    var onRestoreSnapshotChanged: (@MainActor () -> Void)? = nil
    private(set) var lastRestoreSnapshot: WorkspaceProfileRestoreSnapshot? {
        didSet { onRestoreSnapshotChanged?() }
    }

    init(
        axController: AXWindowController,
        displayRegistry: DisplayRegistry = .shared,
        overlayController: ZoneOverlayController = .shared
    ) {
        self.axController = axController
        self.displayRegistry = displayRegistry
        self.overlayController = overlayController
    }

    func cancelInFlightApply() {
        applyGeneration &+= 1
        isApplyingProfile = false
        placementTrackerTask?.cancel()
        placementTrackerTask = nil
        activeRulePlacements.removeAll()
    }

    func stopAllWatchers() {
        applyGeneration &+= 1
        isApplyingProfile = false
        placementTrackerTask?.cancel()
        placementTrackerTask = nil
        activeRulePlacements.removeAll()
        lastRestoreSnapshot = nil
        for (_, task) in launchTimeoutTasks {
            task.cancel()
        }
        launchTimeoutTasks.removeAll()
        for (_, obs) in launchObservers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        launchObservers.removeAll()
        stopActiveRuleWatchers()
    }

    private func stopActiveRuleWatchers() {
        for (_, obs) in activeRuleObservers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        activeRuleObservers.removeAll()
        activeWatchedRulesByBundleID.removeAll()
        if let workspaceLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceLaunchObserver)
            self.workspaceLaunchObserver = nil
        }
    }

    // MARK: - Pure Resolution, Verification & Dry-Run Preview

    static func framesMatchWithinTolerance(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 14) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    static func isWindowFramePositionedCorrectly(
        actualFrameAX: CGRect,
        targetFrameAX: CGRect,
        minSize: CGSize? = nil,
        lastClampedFrameAX: CGRect? = nil,
        usableAXRect: CGRect,
        tolerance: CGFloat = 14
    ) -> Bool {
        if framesMatchWithinTolerance(actualFrameAX, targetFrameAX, tolerance: tolerance) {
            return true
        }
        if let lastClampedFrameAX,
           framesMatchWithinTolerance(actualFrameAX, lastClampedFrameAX, tolerance: tolerance) {
            return true
        }
        if let warning = SnapGeometry.evaluateMinSizeFit(
            targetFrameAX: targetFrameAX,
            minSize: minSize,
            usableAXRect: usableAXRect
        ), framesMatchWithinTolerance(actualFrameAX, warning.clampedFrameAX, tolerance: tolerance) {
            return true
        }
        return false
    }

    static func resolveTargetDisplay(
        for target: ProfileTargetDisplay,
        fallback: ProfileDisconnectedFallback,
        displays: [ConnectedDisplay],
        swapExternalDisplays: Bool = false
    ) -> (display: ConnectedDisplay, usedFallback: Bool)? {
        guard !displays.isEmpty else { return nil }
        let roles = DisplayRegistry.assignLogicalRoles(for: displays, swapExternalDisplays: swapExternalDisplays)
        let main = roles[.main] ?? displays.first(where: \.isMain) ?? displays[0]

        switch target {
        case .main:
            return (main, false)
        case .anyExternal:
            if let external = roles[.external1] {
                return (external, false)
            }
            switch fallback {
            case .moveToMainDisplay, .moveToNextAvailableDisplay:
                return (main, true)
            case .skipRule:
                return nil
            }
        case .externalSlot(let idx):
            let role: ProfileDisplayRole = idx <= 0 ? .external1 : .external2
            if let matched = roles[role] {
                return (matched, false)
            }
            switch fallback {
            case .moveToMainDisplay:
                return (main, true)
            case .moveToNextAvailableDisplay:
                if let anyExt = roles[.external1] ?? roles[.external2] {
                    return (anyExt, true)
                }
                return (main, true)
            case .skipRule:
                return nil
            }
        case .specific(let sig):
            if let matchedSig = DisplayRegistry.matchDisplay(for: sig, among: displays.map(\.signature)),
               let matchedDisplay = displays.first(where: { $0.signature == matchedSig }) {
                return (matchedDisplay, false)
            }
            switch fallback {
            case .moveToMainDisplay:
                return (main, true)
            case .moveToNextAvailableDisplay:
                return (displays[0], true)
            case .skipRule:
                return nil
            }
        }
    }

    static func resolveRuleZone(
        rule: ProfileAppRule,
        profile: WorkspaceProfile,
        on display: ConnectedDisplay,
        displays: [ConnectedDisplay] = [],
        config: WindowSnapperConfig
    ) -> ResolvedZone? {
        let effectiveDisplays = displays.isEmpty ? [display] : displays
        let effectiveOverrides = profile.effectiveDisplayLayoutOverrides(
            for: effectiveDisplays,
            swapExternalDisplays: config.swapExternalDisplays
        )
        let layout = DisplayRegistry.layout(
            for: display.signature,
            in: config.displayLayouts,
            overrides: effectiveOverrides
        )
        if let resolved = SnapGeometry.resolveUniversalOrBuiltInZone(
            id: rule.targetZoneID,
            usableAXRect: display.usableAX,
            primaryScreenHeight: display.primaryScreenHeight,
            gaps: config.gaps,
            layoutOverride: layout,
            centerWidthFraction: config.centerWidthFraction,
            centerHeightFraction: config.centerHeightFraction
        ) {
            return resolved
        }
        if let fallbackNorm = rule.fallbackRect {
            let outer = CGFloat(layout?.outerMarginPoints ?? config.gaps.outerMarginPoints)
            let inner = CGFloat(layout?.innerGapPoints ?? config.gaps.innerGapPoints)
            let ax = SnapGeometry.applyGaps(
                to: fallbackNorm,
                in: display.usableAX,
                outerMargin: outer,
                innerGap: inner
            )
            return ResolvedZone(
                id: rule.targetZoneID,
                name: "Custom Area",
                badgeNumber: 0,
                normalizedRect: fallbackNorm,
                frameInAX: ax,
                frameInAppKit: SnapGeometry.axToAppKit(ax, primaryScreenHeight: display.primaryScreenHeight),
                gridCoord: nil,
                shortcut: .none
            )
        }
        return nil
    }

    static func tiledFrames(
        count: Int,
        inside zoneFrameAX: CGRect,
        innerGap: CGFloat
    ) -> [CGRect] {
        guard count > 1 else { return [zoneFrameAX] }
        let horizontal = zoneFrameAX.width >= zoneFrameAX.height * 0.9
        if horizontal {
            let cells = SnapGeometry.divideAxis(
                origin: zoneFrameAX.minX,
                totalSpan: zoneFrameAX.width,
                weights: Array(repeating: 1.0, count: count),
                outerMargin: 0,
                innerGap: innerGap
            )
            return cells.map {
                CGRect(x: $0.offset, y: zoneFrameAX.minY, width: $0.span, height: zoneFrameAX.height)
            }
        } else {
            let cells = SnapGeometry.divideAxis(
                origin: zoneFrameAX.minY,
                totalSpan: zoneFrameAX.height,
                weights: Array(repeating: 1.0, count: count),
                outerMargin: 0,
                innerGap: innerGap
            )
            return cells.map {
                CGRect(x: zoneFrameAX.minX, y: $0.offset, width: zoneFrameAX.width, height: $0.span)
            }
        }
    }

    static func selectWindows(
        for rule: ProfileAppRule,
        from visibleWindows: [DiscoveredAXWindow]
    ) -> [DiscoveredAXWindow] {
        let matching = visibleWindows.filter {
            $0.bundleIdentifier.caseInsensitiveCompare(rule.bundleIdentifier) == .orderedSame
        }
        guard !matching.isEmpty else { return [] }

        switch rule.windowPolicy {
        case .frontmost:
            return [matching[0]]
        case .largest:
            if let biggest = matching.max(by: { ($0.frameAX.width * $0.frameAX.height) < ($1.frameAX.width * $1.frameAX.height) }) {
                return [biggest]
            }
            return [matching[0]]
        case .titleContains(let query):
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return [matching[0]] }
            let filtered = matching.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
            return filtered.isEmpty ? [] : [filtered[0]]
        case .allTiledInZone:
            return matching
        }
    }

    static func buildDryRunPreview(
        profile: WorkspaceProfile,
        displays: [ConnectedDisplay],
        visibleWindows: [DiscoveredAXWindow],
        runningBundleIDs: Set<String>,
        config: WindowSnapperConfig
    ) -> [CGDirectDisplayID: [ProfilePreviewOverlayItem]] {
        var result: [CGDirectDisplayID: [ProfilePreviewOverlayItem]] = [:]

        let effectiveRules = profile.effectiveAppRules(forDisplayCount: displays.count)
        for rule in effectiveRules where rule.enabled {
            guard let resolvedTarget = resolveTargetDisplay(
                for: rule.targetDisplay,
                fallback: profile.disconnectedFallback,
                displays: displays,
                swapExternalDisplays: config.swapExternalDisplays
            ) else {
                continue
            }
            guard let zone = resolveRuleZone(
                rule: rule,
                profile: profile,
                on: resolvedTarget.display,
                displays: displays,
                config: config
            ) else {
                continue
            }

            let matchingWindows = selectWindows(for: rule, from: visibleWindows)
            let isRunning = runningBundleIDs.contains { $0.caseInsensitiveCompare(rule.bundleIdentifier) == .orderedSame }

            let status: ProfileRulePreviewStatus
            if resolvedTarget.usedFallback {
                status = .mainDisplayFallback
            } else if let firstWin = matchingWindows.first {
                let alreadyFits = isWindowFramePositionedCorrectly(
                    actualFrameAX: firstWin.frameAX,
                    targetFrameAX: zone.frameInAX,
                    minSize: firstWin.minSize,
                    usableAXRect: resolvedTarget.display.usableAX
                )
                status = alreadyFits ? .alreadyPlaced : .ready
            } else if isRunning {
                status = .ready
            } else if rule.launchIfNotRunning {
                status = .willLaunch
            } else {
                status = .notRunningSkipped
            }

            let item = ProfilePreviewOverlayItem(
                id: rule.id,
                appName: rule.appName,
                bundleIdentifier: rule.bundleIdentifier,
                zone: zone,
                status: status
            )
            result[resolvedTarget.display.displayID, default: []].append(item)
        }

        return result
    }

    // MARK: - Shortcut Toggle & Previous Workspace Restore

    func seedRestoreSnapshotForTesting(_ snapshot: WorkspaceProfileRestoreSnapshot?) {
        lastRestoreSnapshot = snapshot
    }

    func canRestorePreviousWorkspace(forProfileID profileID: String, config: WindowSnapperConfig) -> Bool {
        config.restorePreviousWorkspaceOnShortcutToggle
            && config.activeProfileID == profileID
            && lastRestoreSnapshot?.profileID == profileID
    }

    func toggleOrApplyProfile(
        _ profile: WorkspaceProfile,
        onPushUndoBatch: @escaping (WindowSnapUndoBatch) -> Void
    ) {
        let cfg = ConfigManager.shared.config.windowSnapper
        if canRestorePreviousWorkspace(forProfileID: profile.id, config: cfg) {
            restorePreviousWorkspace()
        } else {
            applyProfile(profile, onPushUndoBatch: onPushUndoBatch)
        }
    }

    func restorePreviousWorkspace(completion: (@MainActor () -> Void)? = nil) {
        guard let snapshot = lastRestoreSnapshot else {
            completion?()
            return
        }
        lastRestoreSnapshot = nil
        applyGeneration &+= 1
        isApplyingProfile = false
        placementTrackerTask?.cancel()
        placementTrackerTask = nil
        activeRulePlacements.removeAll()
        stopActiveRuleWatchers()
        overlayController.hideAllPreviews()

        var cfg = ConfigManager.shared.config.windowSnapper
        cfg.activeProfileID = snapshot.previousActiveProfileID
        cfg.displayLayouts = snapshot.previousDisplayLayouts
        ConfigManager.shared.config.windowSnapper = cfg

        displayRegistry.refresh(gaps: cfg.gaps)
        let displays = displayRegistry.connectedDisplays

        for bid in snapshot.appsHiddenByProfile {
            for app in NSWorkspace.shared.runningApplications where !app.isTerminated
                && (app.bundleIdentifier?.caseInsensitiveCompare(bid) == .orderedSame) {
                if app.isHidden {
                    _ = app.unhide()
                }
            }
        }

        let restoreBatch = WindowSnapUndoBatch(
            title: "Restore pre-\(snapshot.profileName)",
            isProfileBatch: true,
            items: snapshot.preProfileWindows
        )

        axController.restoreUndoBatch(
            restoreBatch,
            displays: displays,
            overrideElements: snapshot.preProfileElementsByUndoID
        ) { [weak self] restoredCount in
            guard let self else {
                completion?()
                return
            }

            let finalizeVisibilityAndFocus: @MainActor () -> Void = {
                for bid in snapshot.unhiddenBundleIDs.union(snapshot.newlyLaunchedBundleIDs) {
                    for app in NSWorkspace.shared.runningApplications where !app.isTerminated
                        && (app.bundleIdentifier?.caseInsensitiveCompare(bid) == .orderedSame) {
                        _ = app.hide()
                    }
                }

                if snapshot.wasToolboxMainWindowVisible,
                   !PermissionsManager.isRunningInDiagnosticMode,
                   let mainWin = MainWindowController.shared.currentWindow {
                    if mainWin.isMiniaturized {
                        mainWin.deminiaturize(nil)
                    }
                    mainWin.makeKeyAndOrderFront(nil)
                }

                if !PermissionsManager.isRunningInDiagnosticMode,
                   let prevFrontBID = snapshot.previouslyFrontmostBundleID {
                    let selfID = Bundle.main.bundleIdentifier?.lowercased() ?? ""
                    if prevFrontBID.lowercased() == selfID {
                        if snapshot.wasToolboxMainWindowVisible {
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    } else if let prevApp = NSWorkspace.shared.runningApplications.first(where: {
                        !$0.isTerminated && ($0.bundleIdentifier?.caseInsensitiveCompare(prevFrontBID) == .orderedSame)
                    }) {
                        if NSApp.isActive {
                            NSApp.yieldActivation(to: prevApp)
                        }
                        _ = prevApp.activate()
                    }
                }

                DeveloperEventLog.shared.record(
                    .windowSnapper,
                    "Restored workspace before '\(snapshot.profileName)'",
                    detail: "windows restored: \(restoredCount)"
                )

                if cfg.showSnapHUDToasts {
                    HUDToast.shared.show(
                        title: "Restored previous layout",
                        symbol: "arrow.uturn.backward.circle",
                        tint: .indigo
                    )
                }

                self.syncActiveProfileWatchers(config: ConfigManager.shared.config)
                completion?()
            }

            if !snapshot.unminimizedElements.isEmpty {
                self.axController.minimizeElements(snapshot.unminimizedElements) {
                    finalizeVisibilityAndFocus()
                }
            } else {
                finalizeVisibilityAndFocus()
            }
        }
    }

    // MARK: - Live Preview & Apply

    func previewProfile(
        _ profile: WorkspaceProfile,
        config: WindowSnapperConfig,
        autoHideAfter: TimeInterval? = 3.0
    ) {
        displayRegistry.refresh(gaps: config.gaps)
        let displays = displayRegistry.connectedDisplays
        let effectiveRules = profile.effectiveAppRules(forDisplayCount: displays.count)
        if effectiveRules.filter(\.enabled).isEmpty {
            overlayController.showLayoutProfilePreview(
                profile: profile,
                displays: displays,
                config: config,
                autoHideAfter: autoHideAfter
            )
            return
        }
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let ignored = Set(config.ignoredBundleIDs)

        axController.inspectAllVisibleStandardWindows(ignoredBundleIDs: ignored) { [weak self] visibleWindows in
            guard let self else { return }
            let previewItems = Self.buildDryRunPreview(
                profile: profile,
                displays: displays,
                visibleWindows: visibleWindows,
                runningBundleIDs: runningIDs,
                config: config
            )
            self.overlayController.showProfileDryRunPreview(
                profile: profile,
                itemsByDisplay: previewItems,
                displays: displays,
                style: config.overlayStyle,
                autoHideAfter: autoHideAfter
            )
        }
    }

    func applyProfile(
        _ profile: WorkspaceProfile,
        onPushUndoBatch: @escaping (WindowSnapUndoBatch) -> Void
    ) {
        guard !isApplyingProfile else { return }
        overlayController.hideAllPreviews()
        suggestedTopologyProfileID = nil
        isApplyingProfile = true

        placementTrackerTask?.cancel()
        placementTrackerTask = nil
        activeRulePlacements.removeAll()
        applyGeneration &+= 1
        let gen = applyGeneration

        let initialCfg = ConfigManager.shared.config.windowSnapper
        displayRegistry.refresh(gaps: initialCfg.gaps)
        let displays = displayRegistry.connectedDisplays
        let ignored = Set(initialCfg.ignoredBundleIDs)

        if initialCfg.showSnapHUDToasts && !PermissionsManager.isRunningInDiagnosticMode {
            let matchedCount = min(max(displays.count, 1), profile.maxDisplayCount)
            let subtitle = profile.maxDisplayCount > 1
                ? "\(matchedCount) \(matchedCount == 1 ? "Display" : "Displays") · Arranging windows…"
                : "Arranging windows…"
            HUDToast.shared.showLoading(
                title: "Applying \(profile.name)",
                subtitle: subtitle,
                tint: .indigo
            )
        }

        let previousActiveProfileID = initialCfg.activeProfileID
        let previousDisplayLayouts = initialCfg.displayLayouts
        let previouslyFrontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let selfID = Bundle.main.bundleIdentifier?.lowercased() ?? ""
        let wasToolboxMainWindowVisible = !PermissionsManager.isRunningInDiagnosticMode
            && (MainWindowController.shared.currentWindow?.isVisible == true)
        let selfVisibleWindows = AXWindowController.standardSelfWindowsMainActor()

        let effectiveRules = profile.effectiveAppRules(forDisplayCount: displays.count)
        let enabledRules = effectiveRules.filter(\.enabled)
        let effectiveOverrides = profile.effectiveDisplayLayoutOverrides(
            for: displays,
            swapExternalDisplays: initialCfg.swapExternalDisplays
        )
        let targetBundleIDs = Set(enabledRules.map { $0.bundleIdentifier.lowercased() })
        let targetPIDs = NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && targetBundleIDs.contains(($0.bundleIdentifier ?? "").lowercased()) }
            .map(\.processIdentifier)

        // Phase A: Capture pre-profile window frames before hiding/unhiding or moving anything
        axController.inspectAllVisibleStandardWindows(ignoredBundleIDs: ignored) { [weak self] preVisibleWindows in
            guard let self, self.applyGeneration == gen else { return }

            self.axController.windowsForApps(pids: targetPIDs) { [weak self] preTargetByPID in
                guard let self, self.applyGeneration == gen else { return }

                var snapshotWindows: [DiscoveredAXWindow] = preVisibleWindows
                for (_, wins) in preTargetByPID {
                    for win in wins {
                        let alreadySeen = snapshotWindows.contains { existing in
                            if let w1 = existing.windowNumber, let w2 = win.windowNumber, w1 == w2 {
                                return true
                            }
                            return existing.pid == win.pid && CFEqual(existing.elementBox.element, win.elementBox.element)
                        }
                        if !alreadySeen {
                            snapshotWindows.append(win)
                        }
                    }
                }
                if targetBundleIDs.contains(selfID) {
                    for win in selfVisibleWindows {
                        let alreadySeen = snapshotWindows.contains { $0.pid == win.pid && $0.windowNumber == win.windowNumber }
                        if !alreadySeen {
                            snapshotWindows.append(win)
                        }
                    }
                }

                var preItems: [WindowSnapUndoItem] = []
                var preElements: [String: AXElementBox] = [:]
                for win in snapshotWindows {
                    let item = WindowSnapUndoItem(
                        pid: win.pid,
                        windowNumber: win.windowNumber,
                        bundleIdentifier: win.bundleIdentifier,
                        appName: win.appName,
                        windowTitle: win.title,
                        initialFrameAX: win.frameAX,
                        afterFrameAX: win.frameAX,
                        displaySignature: self.displayRegistry.display(containingAXRect: win.frameAX)?.signature,
                        zoneName: "Pre-Profile"
                    )
                    preItems.append(item)
                    preElements[item.id] = win.elementBox
                }

                var snapshot = WorkspaceProfileRestoreSnapshot(
                    profileID: profile.id,
                    profileName: profile.name,
                    previousActiveProfileID: previousActiveProfileID,
                    previousDisplayLayouts: previousDisplayLayouts,
                    preProfileWindows: preItems,
                    preProfileElementsByUndoID: preElements,
                    unminimizedElements: [],
                    unhiddenBundleIDs: [],
                    appsHiddenByProfile: [],
                    newlyLaunchedBundleIDs: [],
                    wasToolboxMainWindowVisible: wasToolboxMainWindowVisible,
                    previouslyFrontmostBundleID: previouslyFrontmostBundleID
                )

                // Phase B: Update config, unhide/unminimize target apps, and hide unlisted apps (including Toolbox)
                var cfg = ConfigManager.shared.config.windowSnapper
                cfg.activeProfileID = profile.id
                for overrideLayout in effectiveOverrides {
                    if let existingIdx = cfg.displayLayouts.firstIndex(where: {
                        DisplayRegistry.matchDisplay(for: overrideLayout.display, among: [$0.display]) != nil
                    }) {
                        cfg.displayLayouts[existingIdx].presetID = overrideLayout.presetID
                        cfg.displayLayouts[existingIdx].division = overrideLayout.division
                        cfg.displayLayouts[existingIdx].customZones = overrideLayout.customZones
                        cfg.displayLayouts[existingIdx].outerMarginPoints = overrideLayout.outerMarginPoints
                        cfg.displayLayouts[existingIdx].innerGapPoints = overrideLayout.innerGapPoints
                    } else {
                        cfg.displayLayouts.append(overrideLayout)
                    }
                }
                ConfigManager.shared.config.windowSnapper = cfg

                var restoredAnyAppOrWindow = false
                let alreadyVisibleTargetBIDs = Set(preVisibleWindows.map { $0.bundleIdentifier.lowercased() })
                var enteringBundleIDs = targetBundleIDs.subtracting(alreadyVisibleTargetBIDs)

                if profile.unminimizeAndUnhideApps {
                    for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
                        let bid = (app.bundleIdentifier ?? "").lowercased()
                        if targetBundleIDs.contains(bid), app.isHidden {
                            _ = app.unhide()
                            snapshot.unhiddenBundleIDs.insert(bid)
                            enteringBundleIDs.insert(bid)
                            restoredAnyAppOrWindow = true
                        }
                    }
                }

                var appsToHide: [NSRunningApplication] = []
                var exitingPairs: [(window: DiscoveredAXWindow, exitFrameAX: CGRect)] = []
                if profile.hideUnlistedApps {
                    var hideBIDs = Set<String>()
                    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
                        let bid = app.bundleIdentifier?.lowercased() ?? ""
                        if bid.isEmpty || bid == "com.apple.finder" || bid == selfID {
                            continue
                        }
                        if !targetBundleIDs.contains(bid) && !app.isHidden {
                            snapshot.appsHiddenByProfile.insert(bid)
                            hideBIDs.insert(bid)
                            appsToHide.append(app)
                        }
                    }
                    if cfg.windowAnimationSpeed.isAnimated {
                        for win in preVisibleWindows where hideBIDs.contains(win.bundleIdentifier.lowercased()) {
                            let disp = self.displayRegistry.display(containingAXRect: win.frameAX)
                                ?? displays.first(where: \.isMain)
                                ?? displays.first
                            if let disp {
                                let exitRect = SnapGeometry.slideOutTargetFrame(for: win.frameAX, inside: disp.usableAX)
                                exitingPairs.append((window: win, exitFrameAX: exitRect))
                            }
                        }
                    }
                }

                let continueAfterExit: @MainActor () -> Void = { [weak self] in
                    guard let self, self.applyGeneration == gen else { return }
                    for app in appsToHide {
                        _ = app.hide()
                    }
                    if profile.hideUnlistedApps && !targetBundleIDs.contains(selfID) && !PermissionsManager.isRunningInDiagnosticMode {
                        for win in NSApp.windows where !(win is NSPanel) && win.styleMask.contains(.titled) && win.isVisible {
                            win.orderOut(nil)
                        }
                    }

                    self.axController.unminimizeAndFetchWindowsForApps(
                        pids: targetPIDs,
                        unminimize: profile.unminimizeAndUnhideApps
                    ) { [weak self] unminimizedElements, _ in
                        guard let self, self.applyGeneration == gen else { return }
                        if !unminimizedElements.isEmpty {
                            snapshot.unminimizedElements = unminimizedElements
                            restoredAnyAppOrWindow = true
                        }
                        self.lastRestoreSnapshot = snapshot

                        let runPlacementPass: @MainActor () -> Void = { [weak self] in
                            self?.performInitialPlacementAndStartTracker(
                                generation: gen,
                                profile: profile,
                                displays: displays,
                                config: cfg,
                                ignoredBundleIDs: ignored,
                                enteringBundleIDs: enteringBundleIDs,
                                onPushUndoBatch: onPushUndoBatch
                            )
                        }

                        if restoredAnyAppOrWindow {
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 140_000_000)
                                guard self.applyGeneration == gen else { return }
                                runPlacementPass()
                            }
                        } else {
                            runPlacementPass()
                        }
                    }
                }

                if !exitingPairs.isEmpty {
                    self.axController.animateWindowsExit(
                        exitingPairs,
                        animationSpeed: cfg.windowAnimationSpeed
                    ) {
                        continueAfterExit()
                    }
                } else {
                    continueAfterExit()
                }
            }
        }
    }

    private func performInitialPlacementAndStartTracker(
        generation gen: UInt64,
        profile: WorkspaceProfile,
        displays: [ConnectedDisplay],
        config cfg: WindowSnapperConfig,
        ignoredBundleIDs ignored: Set<String>,
        enteringBundleIDs: Set<String>,
        onPushUndoBatch: @escaping (WindowSnapUndoBatch) -> Void
    ) {
        guard applyGeneration == gen else { return }

        let effectiveRules = profile.effectiveAppRules(forDisplayCount: displays.count)
        let enabledRules = effectiveRules.filter(\.enabled)
        let targetBundleIDs = Set(enabledRules.map { $0.bundleIdentifier.lowercased() })
        let targetPIDs = NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && targetBundleIDs.contains(($0.bundleIdentifier ?? "").lowercased()) }
            .map(\.processIdentifier)

        axController.inspectAllVisibleStandardWindows(ignoredBundleIDs: ignored) { [weak self] visibleWindows in
            guard let self, self.applyGeneration == gen else { return }

            self.axController.windowsForApps(pids: targetPIDs) { [weak self] axWindowsByPID in
                guard let self, self.applyGeneration == gen else { return }

                var undoItems: [WindowSnapUndoItem] = []
                var placedCount = 0
                var launchingNames: [String] = []
                let group = DispatchGroup()
                var firstPlacedApp: NSRunningApplication?

                for rule in enabledRules {
                    guard let resolvedTarget = Self.resolveTargetDisplay(
                        for: rule.targetDisplay,
                        fallback: profile.disconnectedFallback,
                        displays: displays,
                        swapExternalDisplays: cfg.swapExternalDisplays
                    ),
                    let zone = Self.resolveRuleZone(
                        rule: rule,
                        profile: profile,
                        on: resolvedTarget.display,
                        displays: displays,
                        config: cfg
                    ) else {
                        continue
                    }

                    let runningMatches = NSWorkspace.shared.runningApplications.filter {
                        !$0.isTerminated && ($0.bundleIdentifier?.caseInsensitiveCompare(rule.bundleIdentifier) == .orderedSame)
                    }
                    let isAppRunning = !runningMatches.isEmpty

                    var candidateWindows = visibleWindows.filter {
                        $0.bundleIdentifier.caseInsensitiveCompare(rule.bundleIdentifier) == .orderedSame
                    }
                    if candidateWindows.isEmpty {
                        for app in runningMatches {
                            let fallbackWins = (axWindowsByPID[app.processIdentifier] ?? []).filter {
                                !$0.isFullscreen && !$0.isMinimized && $0.frameAX.width >= 100 && $0.frameAX.height >= 80
                            }
                            candidateWindows.append(contentsOf: fallbackWins)
                        }
                    }

                    let selected = Self.selectWindows(for: rule, from: candidateWindows)
                    if !selected.isEmpty {
                        if firstPlacedApp == nil, let app = runningMatches.first {
                            firstPlacedApp = app
                        }
                        let frames = Self.tiledFrames(
                            count: selected.count,
                            inside: zone.frameInAX,
                            innerGap: CGFloat(cfg.gaps.innerGapPoints)
                        )
                        self.activeRulePlacements[rule.id] = ProfileRulePlacementEntry(
                            rule: rule,
                            targetDisplay: resolvedTarget.display,
                            zone: zone,
                            isAppOpen: true,
                            hasWindow: true,
                            isPositioned: false,
                            consecutiveVerifiedHits: 0,
                            snapAttempts: 1
                        )

                        for (idx, win) in selected.enumerated() {
                            let targetFrame = frames[idx]
                            let sourceDisp = self.displayRegistry.display(containingAXRect: win.frameAX)
                            let isEntering = enteringBundleIDs.contains(win.bundleIdentifier.lowercased())
                            let entryStart = (isEntering && cfg.windowAnimationSpeed.isAnimated)
                                ? SnapGeometry.slideInStartFrame(for: targetFrame, inside: resolvedTarget.display.usableAX)
                                : nil
                            group.enter()
                            self.axController.snapWindow(
                                win,
                                toAXFrame: targetFrame,
                                usableAXRect: resolvedTarget.display.usableAX,
                                sourceDisplayFrameAX: sourceDisp?.frameAX,
                                targetDisplayFrameAX: resolvedTarget.display.frameAX,
                                animationSpeed: cfg.windowAnimationSpeed,
                                entryStartFrameAX: entryStart
                            ) { [weak self] execResult in
                                if let self, let execResult {
                                    let undoItem = WindowSnapUndoItem(
                                        pid: win.pid,
                                        windowNumber: win.windowNumber,
                                        bundleIdentifier: win.bundleIdentifier,
                                        appName: win.appName,
                                        windowTitle: win.title,
                                        initialFrameAX: win.frameAX,
                                        afterFrameAX: execResult.appliedFrameAX,
                                        displaySignature: resolvedTarget.display.signature,
                                        zoneName: zone.name
                                    )
                                    self.axController.cacheElement(win.elementBox, forUndoItemID: undoItem.id)
                                    undoItems.append(undoItem)
                                    placedCount += 1

                                    if self.applyGeneration == gen, execResult.clampedForMinSize {
                                        self.activeRulePlacements[rule.id]?.lastClampedFramesByIndex[idx] = execResult.appliedFrameAX
                                    }
                                    if self.applyGeneration == gen,
                                       Self.isWindowFramePositionedCorrectly(
                                           actualFrameAX: execResult.appliedFrameAX,
                                           targetFrameAX: targetFrame,
                                           minSize: win.minSize,
                                           lastClampedFrameAX: execResult.clampedForMinSize ? execResult.appliedFrameAX : nil,
                                           usableAXRect: resolvedTarget.display.usableAX
                                       ) {
                                        self.activeRulePlacements[rule.id]?.isPositioned = true
                                    }
                                }
                                group.leave()
                            }
                        }
                    } else if candidateWindows.isEmpty && rule.launchIfNotRunning {
                        let lowerBID = rule.bundleIdentifier.lowercased()
                        if !isAppRunning {
                            self.lastRestoreSnapshot?.newlyLaunchedBundleIDs.insert(lowerBID)
                        }
                        launchingNames.append(rule.appName)
                        self.activeRulePlacements[rule.id] = ProfileRulePlacementEntry(
                            rule: rule,
                            targetDisplay: resolvedTarget.display,
                            zone: zone,
                            isAppOpen: isAppRunning,
                            hasWindow: false,
                            isPositioned: false,
                            consecutiveVerifiedHits: 0,
                            snapAttempts: 0,
                            didTriggerLaunchOrReopen: true
                        )
                        self.launchOrReopenApp(bundleIdentifier: rule.bundleIdentifier)
                    } else {
                        self.activeRulePlacements[rule.id] = ProfileRulePlacementEntry(
                            rule: rule,
                            targetDisplay: resolvedTarget.display,
                            zone: zone,
                            isAppOpen: isAppRunning,
                            hasWindow: !candidateWindows.isEmpty,
                            isPositioned: false,
                            consecutiveVerifiedHits: 2
                        )
                    }
                }

                group.notify(queue: .main) { [weak self] in
                    guard let self, self.applyGeneration == gen else { return }
                    self.isApplyingProfile = false

                    if !undoItems.isEmpty {
                        let batch = WindowSnapUndoBatch(
                            title: "Profile '\(profile.name)'",
                            isProfileBatch: true,
                            items: undoItems
                        )
                        onPushUndoBatch(batch)
                    }

                    if !PermissionsManager.isRunningInDiagnosticMode,
                       (profile.hideUnlistedApps || NSApp.isActive) {
                        if let app = firstPlacedApp {
                            if NSApp.isActive {
                                NSApp.yieldActivation(to: app)
                            }
                            _ = app.activate()
                        }
                    }

                    DeveloperEventLog.shared.record(
                        .windowSnapper,
                        "Applied profile '\(profile.name)'",
                        detail: "placed: \(placedCount), launching: \(launchingNames.count)"
                    )

                    if cfg.showSnapHUDToasts {
                        let matchedCount = min(max(displays.count, 1), profile.maxDisplayCount)
                        let displayPrefix = profile.maxDisplayCount > 1
                            ? "\(matchedCount) \(matchedCount == 1 ? "Display" : "Displays") · "
                            : ""
                        if enabledRules.isEmpty {
                            HUDToast.shared.show(
                                title: profile.name,
                                subtitle: "\(displayPrefix)Layout applied",
                                symbol: "checkmark.circle.fill",
                                tint: .green
                            )
                        } else {
                            let placedWord = placedCount == 1 ? "window" : "windows"
                            let launchSuffix = launchingNames.isEmpty
                                ? ""
                                : ", opening \(launchingNames.joined(separator: ", "))"
                            HUDToast.shared.show(
                                title: profile.name,
                                subtitle: "\(displayPrefix)\(placedCount) \(placedWord) placed\(launchSuffix)",
                                symbol: "checkmark.circle.fill",
                                tint: .green
                            )
                        }
                    }

                    self.syncActiveProfileWatchers(config: ConfigManager.shared.config)
                    self.startPlacementReconciliationLoop(generation: gen, config: cfg)
                }
            }
        }
    }

    // MARK: - App Launch / Reopen + Placement Verification Tracker

    private func launchOrReopenApp(bundleIdentifier: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return
        }
        let openConfig = NSWorkspace.OpenConfiguration()
        openConfig.activates = true
        openConfig.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: openConfig) { _, _ in }
    }

    private func startPlacementReconciliationLoop(
        generation gen: UInt64,
        config cfg: WindowSnapperConfig
    ) {
        placementTrackerTask?.cancel()
        guard PermissionsManager.isProcessTrusted() else { return }

        placementTrackerTask = Task { @MainActor [weak self] in
            let maxTicks = 22
            let intervalSeconds = max(0.38, cfg.windowAnimationSpeed.snapDuration + 0.16)
            let intervalNs = UInt64(intervalSeconds * 1_000_000_000)

            for tick in 0..<maxTicks {
                try? await Task.sleep(nanoseconds: intervalNs)
                guard !Task.isCancelled, let self, self.applyGeneration == gen else { return }

                let pendingRuleIDs = self.activeRulePlacements.compactMap { ruleID, entry -> String? in
                    if entry.consecutiveVerifiedHits >= 2 { return nil }
                    if !entry.isAppOpen && !entry.rule.launchIfNotRunning { return nil }
                    return ruleID
                }
                if pendingRuleIDs.isEmpty {
                    return
                }

                var targetPIDs: [pid_t] = []
                var runningByRuleID: [String: [NSRunningApplication]] = [:]
                for ruleID in pendingRuleIDs {
                    guard let entry = self.activeRulePlacements[ruleID] else { continue }
                    let matches = NSWorkspace.shared.runningApplications.filter {
                        !$0.isTerminated && ($0.bundleIdentifier?.caseInsensitiveCompare(entry.rule.bundleIdentifier) == .orderedSame)
                    }
                    runningByRuleID[ruleID] = matches
                    for app in matches {
                        targetPIDs.append(app.processIdentifier)
                    }
                }

                let axWindowsByPID: [pid_t: [DiscoveredAXWindow]] = await withCheckedContinuation { continuation in
                    self.axController.windowsForApps(pids: targetPIDs) { result in
                        continuation.resume(returning: result)
                    }
                }
                guard !Task.isCancelled, self.applyGeneration == gen else { return }

                for ruleID in pendingRuleIDs {
                    guard var entry = self.activeRulePlacements[ruleID] else { continue }
                    let runningApps = runningByRuleID[ruleID] ?? []
                    entry.isAppOpen = !runningApps.isEmpty

                    guard !runningApps.isEmpty else {
                        self.activeRulePlacements[ruleID] = entry
                        continue
                    }

                    var candidateWindows: [DiscoveredAXWindow] = []
                    for app in runningApps {
                        let wins = (axWindowsByPID[app.processIdentifier] ?? []).filter {
                            !$0.isFullscreen && !$0.isMinimized && $0.frameAX.width >= 100 && $0.frameAX.height >= 80
                        }
                        candidateWindows.append(contentsOf: wins)
                    }

                    let selected = Self.selectWindows(for: entry.rule, from: candidateWindows)
                    if selected.isEmpty {
                        entry.hasWindow = !candidateWindows.isEmpty
                        entry.isPositioned = false
                        entry.consecutiveVerifiedHits = 0
                        if candidateWindows.isEmpty,
                           entry.didTriggerLaunchOrReopen,
                           !entry.didRetryActivateReopen,
                           tick >= 5,
                           let firstApp = runningApps.first,
                           firstApp.isFinishedLaunching {
                            entry.didRetryActivateReopen = true
                            _ = firstApp.activate()
                            self.launchOrReopenApp(bundleIdentifier: entry.rule.bundleIdentifier)
                        }
                        self.activeRulePlacements[ruleID] = entry
                        continue
                    }

                    entry.hasWindow = true
                    let frames = Self.tiledFrames(
                        count: selected.count,
                        inside: entry.zone.frameInAX,
                        innerGap: CGFloat(cfg.gaps.innerGapPoints)
                    )

                    var allPositioned = true
                    for (idx, win) in selected.enumerated() {
                        let targetFrame = frames[idx]
                        let ok = Self.isWindowFramePositionedCorrectly(
                            actualFrameAX: win.frameAX,
                            targetFrameAX: targetFrame,
                            minSize: win.minSize,
                            lastClampedFrameAX: entry.lastClampedFramesByIndex[idx],
                            usableAXRect: entry.targetDisplay.usableAX
                        )
                        if !ok {
                            allPositioned = false
                        }
                    }

                    if allPositioned {
                        entry.isPositioned = true
                        entry.consecutiveVerifiedHits += 1
                        self.activeRulePlacements[ruleID] = entry
                    } else {
                        entry.isPositioned = false
                        entry.consecutiveVerifiedHits = 0
                        guard entry.snapAttempts < 8 else {
                            entry.consecutiveVerifiedHits = 2
                            self.activeRulePlacements[ruleID] = entry
                            continue
                        }
                        entry.snapAttempts += 1
                        self.activeRulePlacements[ruleID] = entry

                        for (idx, win) in selected.enumerated() {
                            let targetFrame = frames[idx]
                            let alreadyPositioned = Self.isWindowFramePositionedCorrectly(
                                actualFrameAX: win.frameAX,
                                targetFrameAX: targetFrame,
                                minSize: win.minSize,
                                lastClampedFrameAX: entry.lastClampedFramesByIndex[idx],
                                usableAXRect: entry.targetDisplay.usableAX
                            )
                            guard !alreadyPositioned else { continue }

                            self.recordPreSnapWindowIfUnseen(win)
                            let sourceDisp = self.displayRegistry.display(containingAXRect: win.frameAX)
                            let entryStart = (entry.didTriggerLaunchOrReopen && entry.snapAttempts == 1 && cfg.windowAnimationSpeed.isAnimated)
                                ? SnapGeometry.slideInStartFrame(for: targetFrame, inside: entry.targetDisplay.usableAX)
                                : nil
                            self.axController.snapWindow(
                                win,
                                toAXFrame: targetFrame,
                                usableAXRect: entry.targetDisplay.usableAX,
                                sourceDisplayFrameAX: sourceDisp?.frameAX,
                                targetDisplayFrameAX: entry.targetDisplay.frameAX,
                                animationSpeed: cfg.windowAnimationSpeed,
                                entryStartFrameAX: entryStart
                            ) { [weak self] execResult in
                                guard let self, self.applyGeneration == gen, let execResult else { return }
                                if execResult.clampedForMinSize {
                                    self.activeRulePlacements[ruleID]?.lastClampedFramesByIndex[idx] = execResult.appliedFrameAX
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func recordPreSnapWindowIfUnseen(_ win: DiscoveredAXWindow) {
        guard var snapshot = lastRestoreSnapshot else { return }
        let bid = win.bundleIdentifier.lowercased()
        if snapshot.newlyLaunchedBundleIDs.contains(bid) {
            return
        }
        let exists = snapshot.preProfileWindows.contains { existing in
            if let w1 = existing.windowNumber, let w2 = win.windowNumber, w1 == w2 {
                return true
            }
            return existing.pid == win.pid && existing.windowTitle == win.title && !win.title.isEmpty
        }
        guard !exists else { return }

        let item = WindowSnapUndoItem(
            pid: win.pid,
            windowNumber: win.windowNumber,
            bundleIdentifier: win.bundleIdentifier,
            appName: win.appName,
            windowTitle: win.title,
            initialFrameAX: win.frameAX,
            afterFrameAX: win.frameAX,
            displaySignature: displayRegistry.display(containingAXRect: win.frameAX)?.signature,
            zoneName: "Pre-Profile"
        )
        snapshot.preProfileWindows.append(item)
        snapshot.preProfileElementsByUndoID[item.id] = win.elementBox
        lastRestoreSnapshot = snapshot
    }

    // MARK: - Active Profile New-Window Auto-Placement

    func syncActiveProfileWatchers(config fullConfig: ToolboxConfig) {
        stopActiveRuleWatchers()
        let ws = fullConfig.windowSnapper
        guard fullConfig.general.appEnabled,
              ws.enabled,
              PermissionsManager.isProcessTrusted(),
              let activeID = ws.activeProfileID,
              let activeProfile = ws.profiles.first(where: { $0.id == activeID }) else {
            return
        }

        let displays = displayRegistry.connectedDisplays
        let autoRules = activeProfile.effectiveAppRules(forDisplayCount: displays.count)
            .filter { $0.enabled && $0.autoPlaceNewWindowsWhileActive }
        guard !autoRules.isEmpty else { return }

        for rule in autoRules {
            activeWatchedRulesByBundleID[rule.bundleIdentifier.lowercased()] = (activeProfile, rule, ws)
        }

        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            if let bid = app.bundleIdentifier?.lowercased(), activeWatchedRulesByBundleID[bid] != nil {
                attachActiveRuleObserver(for: app, bundleKey: bid)
            }
        }

        workspaceLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier?.lowercased() else { return }
            MainActor.assumeIsolated {
                guard let self, self.activeWatchedRulesByBundleID[bid] != nil else { return }
                self.attachActiveRuleObserver(for: app, bundleKey: bid)
            }
        }
    }

    private func attachActiveRuleObserver(for app: NSRunningApplication, bundleKey: String) {
        let pid = app.processIdentifier
        guard activeRuleObservers[pid] == nil else { return }
        let appAX = AXWindowController.applicationElement(for: pid)
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, _, userInfo in
            guard let userInfo else { return }
            let box = Unmanaged<LaunchObserverBox>.fromOpaque(userInfo).takeUnretainedValue()
            let elBox = AXElementBox(element)
            Task { @MainActor in
                box.onWindowCreated(elBox)
            }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let observer = obs else {
            return
        }
        let box = LaunchObserverBox { [weak self] elBox in
            self?.handleNewWindowCreatedForActiveProfile(elBox, pid: pid, bundleKey: bundleKey)
        }
        objc_setAssociatedObject(observer, &LaunchObserverBox.assocKey, box, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()
        _ = AXObserverAddNotification(observer, appAX, kAXWindowCreatedNotification as CFString, boxPtr)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        activeRuleObservers[pid] = observer
    }

    private func handleNewWindowCreatedForActiveProfile(_ elBox: AXElementBox, pid: pid_t, bundleKey: String) {
        guard let entry = activeWatchedRulesByBundleID[bundleKey] else { return }
        Task { @MainActor [weak self] in
            // Wait briefly for Electron/Chromium renderers to finalize standard subrole and initial frame
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self else { return }
            let displays = self.displayRegistry.connectedDisplays
            guard let resolvedTarget = Self.resolveTargetDisplay(
                for: entry.rule.targetDisplay,
                fallback: entry.profile.disconnectedFallback,
                displays: displays,
                swapExternalDisplays: entry.config.swapExternalDisplays
            ),
            let zone = Self.resolveRuleZone(
                rule: entry.rule,
                profile: entry.profile,
                on: resolvedTarget.display,
                displays: displays,
                config: entry.config
            ) else {
                return
            }
            let windows = self.axController.windowsForAppSync(pid: pid)
            if let win = windows.first(where: {
                CFEqual($0.elementBox.element, elBox.element)
                    && !$0.isFullscreen && !$0.isMinimized
                    && $0.frameAX.width >= 100 && $0.frameAX.height >= 80
            }) {
                self.axController.snapWindow(
                    win,
                    toAXFrame: zone.frameInAX,
                    usableAXRect: resolvedTarget.display.usableAX,
                    sourceDisplayFrameAX: nil,
                    targetDisplayFrameAX: resolvedTarget.display.frameAX
                ) { _ in }
            }
        }
    }

    // MARK: - Capture Current Workspace as Profile

    func captureCurrentWorkspace(
        name: String,
        config: WindowSnapperConfig,
        completion: @escaping @MainActor (WorkspaceProfile) -> Void
    ) {
        displayRegistry.refresh(gaps: config.gaps)
        let displays = displayRegistry.connectedDisplays
        let ignored = Set(config.ignoredBundleIDs)

        axController.inspectAllVisibleStandardWindows(ignoredBundleIDs: ignored) { visibleWindows in
            var capturedRules: [ProfileAppRule] = []
            var seenBundles = Set<String>()

            for win in visibleWindows {
                guard !win.bundleIdentifier.isEmpty,
                      seenBundles.insert(win.bundleIdentifier.lowercased()).inserted else {
                    continue
                }
                let display = displays.first {
                    $0.frameAX.contains(CGPoint(x: win.frameAX.midX, y: win.frameAX.midY))
                } ?? displays.first(where: \.isMain) ?? displays.first

                guard let display else { continue }
                let layout = DisplayRegistry.layout(for: display.signature, in: config.displayLayouts)
                let zones = SnapGeometry.resolveZones(
                    layout: layout,
                    usableAXRect: display.usableAX,
                    primaryScreenHeight: display.primaryScreenHeight,
                    gaps: config.gaps
                )
                let matchedZoneID = SnapGeometry.closestZoneID(forAXFrame: win.frameAX, in: zones)
                let normRect = SnapGeometry.normalizedRect(forAXFrame: win.frameAX, inUsableAXRect: display.usableAX)
                let targetDisplay: ProfileTargetDisplay = display.isMain ? .main : .specific(display.signature)

                capturedRules.append(ProfileAppRule(
                    bundleIdentifier: win.bundleIdentifier,
                    appName: win.appName,
                    targetDisplay: targetDisplay,
                    targetZoneID: matchedZoneID ?? "custom:captured",
                    fallbackRect: normRect,
                    windowPolicy: .frontmost,
                    launchIfNotRunning: true
                ))
            }

            let boundSigs = displays.map(\.signature)
            let layoutOverrides = displays.compactMap { disp -> DisplayLayoutConfig? in
                if let existing = DisplayRegistry.layout(for: disp.signature, in: config.displayLayouts) {
                    return existing
                }
                return DisplayLayoutConfig(display: disp.signature)
            }

            let profile = WorkspaceProfile(
                name: name,
                symbolName: "rectangle.3.group",
                displayLayoutOverrides: layoutOverrides,
                appRules: capturedRules,
                boundDisplaySignatures: boundSigs
            )
            completion(profile)
        }
    }

    func captureCurrentWindowsForVariant(
        displayCount: Int,
        config: WindowSnapperConfig,
        completion: @escaping @MainActor (ProfileDisplayVariant) -> Void
    ) {
        displayRegistry.refresh(gaps: config.gaps)
        let displays = displayRegistry.connectedDisplays
        let roles = DisplayRegistry.assignLogicalRoles(
            for: displays,
            swapExternalDisplays: config.swapExternalDisplays
        )
        let roleByDisplayID = Dictionary(
            uniqueKeysWithValues: roles.map { ($0.value.displayID, $0.key) }
        )
        let ignored = Set(config.ignoredBundleIDs)

        axController.inspectAllVisibleStandardWindows(ignoredBundleIDs: ignored) { visibleWindows in
            let expectedRoles = ProfileDisplayRole.roles(forDisplayCount: displayCount)
            var slotLayouts: [ProfileDisplaySlotLayout] = []
            for role in expectedRoles {
                if let disp = roles[role],
                   let existingLayout = DisplayRegistry.layout(for: disp.signature, in: config.displayLayouts) {
                    slotLayouts.append(
                        ProfileDisplaySlotLayout(
                            role: role,
                            presetID: existingLayout.presetID,
                            division: existingLayout.division,
                            customZones: existingLayout.customZones,
                            outerMarginPoints: existingLayout.outerMarginPoints,
                            innerGapPoints: existingLayout.innerGapPoints
                        )
                    )
                } else {
                    slotLayouts.append(ProfileDisplaySlotLayout(role: role))
                }
            }

            var capturedRules: [ProfileAppRule] = []
            var seenBundles = Set<String>()

            for win in visibleWindows {
                guard !win.bundleIdentifier.isEmpty,
                      seenBundles.insert(win.bundleIdentifier.lowercased()).inserted else {
                    continue
                }
                let display = displays.first {
                    $0.frameAX.contains(CGPoint(x: win.frameAX.midX, y: win.frameAX.midY))
                } ?? displays.first(where: \.isMain) ?? displays.first
                guard let display else { continue }

                let role = roleByDisplayID[display.displayID] ?? .main
                guard expectedRoles.contains(role) else { continue }

                let layout = DisplayRegistry.layout(for: display.signature, in: config.displayLayouts)
                let zones = SnapGeometry.resolveZones(
                    layout: layout,
                    usableAXRect: display.usableAX,
                    primaryScreenHeight: display.primaryScreenHeight,
                    gaps: config.gaps
                )
                let matchedZoneID = SnapGeometry.closestZoneID(forAXFrame: win.frameAX, in: zones)
                let normRect = SnapGeometry.normalizedRect(forAXFrame: win.frameAX, inUsableAXRect: display.usableAX)

                capturedRules.append(ProfileAppRule(
                    bundleIdentifier: win.bundleIdentifier,
                    appName: win.appName,
                    targetDisplay: role.targetDisplay,
                    targetZoneID: matchedZoneID ?? "cell:0:0",
                    fallbackRect: normRect,
                    windowPolicy: .frontmost,
                    launchIfNotRunning: true
                ))
            }

            let variant = ProfileDisplayVariant(
                displayCount: displayCount,
                slotLayouts: slotLayouts,
                appRules: capturedRules
            )
            completion(variant)
        }
    }

    // MARK: - Display Topology Auto-Trigger

    static func topologyKey(
        for connectedDisplays: [ConnectedDisplay],
        swapExternalDisplays: Bool
    ) -> String {
        let connectedSigs = connectedDisplays.map(\.signature)
        return "\(connectedDisplays.count)|\(swapExternalDisplays)|\(connectedSigs.map(\.stableStorageKey).sorted().joined(separator: "|"))"
    }

    func seedCurrentTopology(
        connectedDisplays: [ConnectedDisplay],
        swapExternalDisplays: Bool
    ) {
        guard !connectedDisplays.isEmpty else { return }
        lastAutoTriggeredTopologyKey = Self.topologyKey(
            for: connectedDisplays,
            swapExternalDisplays: swapExternalDisplays
        )
    }

    func handleDisplaysReconfigured(
        connectedDisplays: [ConnectedDisplay],
        config: WindowSnapperConfig,
        onPushUndoBatch: @escaping (WindowSnapUndoBatch) -> Void
    ) {
        guard !connectedDisplays.isEmpty else { return }
        let connectedSigs = connectedDisplays.map(\.signature)
        let topologyKey = Self.topologyKey(
            for: connectedDisplays,
            swapExternalDisplays: config.swapExternalDisplays
        )
        guard topologyKey != lastAutoTriggeredTopologyKey else { return }
        lastAutoTriggeredTopologyKey = topologyKey

        if let autoID = config.autoApplyProfileID,
           let autoProfile = config.profiles.first(where: { $0.id == autoID }) {
            suggestedTopologyProfileID = nil
            cancelInFlightApply()
            applyProfile(autoProfile, onPushUndoBatch: onPushUndoBatch)
            return
        }

        for profile in config.profiles where profile.topologyTriggerMode != .off && !profile.boundDisplaySignatures.isEmpty {
            if DisplayRegistry.topologiesMatch(bound: profile.boundDisplaySignatures, connected: connectedSigs) {
                switch profile.topologyTriggerMode {
                case .off:
                    break
                case .askViaHUD:
                    suggestedTopologyProfileID = profile.id
                    HUDToast.shared.show(
                        title: "Displays matched '\(profile.name)' — Apply from Menu Bar",
                        symbol: "display.2",
                        tint: .indigo,
                        duration: 4.0
                    )
                case .autoApply:
                    cancelInFlightApply()
                    applyProfile(profile, onPushUndoBatch: onPushUndoBatch)
                }
                return
            }
        }
        suggestedTopologyProfileID = nil
    }
}

private final class LaunchObserverBox: NSObject {
    nonisolated(unsafe) static var assocKey: UInt8 = 0
    let onWindowCreated: @MainActor (AXElementBox) -> Void

    init(onWindowCreated: @escaping @MainActor (AXElementBox) -> Void) {
        self.onWindowCreated = onWindowCreated
    }
}
