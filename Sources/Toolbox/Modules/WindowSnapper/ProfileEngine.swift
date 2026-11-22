import AppKit
import ApplicationServices
import Foundation

@MainActor
final class ProfileEngine: ObservableObject {
    @Published private(set) var isApplyingProfile: Bool = false
    @Published private(set) var suggestedTopologyProfileID: String? = nil

    private let axController: AXWindowController
    private let displayRegistry: DisplayRegistry
    private let overlayController: ZoneOverlayController

    private var launchObservers: [pid_t: AXObserver] = [:]
    private var launchTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var activeRuleObservers: [pid_t: AXObserver] = [:]
    private var workspaceLaunchObserver: NSObjectProtocol?
    private var activeWatchedRulesByBundleID: [String: (profile: WorkspaceProfile, rule: ProfileAppRule, config: WindowSnapperConfig)] = [:]
    private var lastAutoTriggeredTopologyKey: String?

    init(
        axController: AXWindowController,
        displayRegistry: DisplayRegistry = .shared,
        overlayController: ZoneOverlayController = .shared
    ) {
        self.axController = axController
        self.displayRegistry = displayRegistry
        self.overlayController = overlayController
    }

    func stopAllWatchers() {
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

    // MARK: - Pure Resolution & Dry-Run Preview

    static func resolveTargetDisplay(
        for target: ProfileTargetDisplay,
        fallback: ProfileDisconnectedFallback,
        displays: [ConnectedDisplay]
    ) -> (display: ConnectedDisplay, usedFallback: Bool)? {
        guard !displays.isEmpty else { return nil }
        let main = displays.first(where: \.isMain) ?? displays.first!

        switch target {
        case .main:
            return (main, false)
        case .anyExternal:
            if let external = displays.first(where: { !$0.isMain }) {
                return (external, false)
            }
            switch fallback {
            case .moveToMainDisplay, .moveToNextAvailableDisplay:
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
        config: WindowSnapperConfig
    ) -> ResolvedZone? {
        let layout = DisplayRegistry.layout(
            for: display.signature,
            in: config.displayLayouts,
            overrides: profile.displayLayoutOverrides
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

        for rule in profile.appRules where rule.enabled {
            guard let resolvedTarget = resolveTargetDisplay(
                for: rule.targetDisplay,
                fallback: profile.disconnectedFallback,
                displays: displays
            ) else {
                continue
            }
            guard let zone = resolveRuleZone(
                rule: rule,
                profile: profile,
                on: resolvedTarget.display,
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
                let alreadyFits = abs(firstWin.frameAX.minX - zone.frameInAX.minX) <= 14
                    && abs(firstWin.frameAX.minY - zone.frameInAX.minY) <= 14
                    && abs(firstWin.frameAX.width - zone.frameInAX.width) <= 14
                    && abs(firstWin.frameAX.height - zone.frameInAX.height) <= 14
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

    // MARK: - Live Preview & Apply

    func previewProfile(
        _ profile: WorkspaceProfile,
        config: WindowSnapperConfig,
        autoHideAfter: TimeInterval? = 3.0
    ) {
        displayRegistry.refresh(gaps: config.gaps)
        let displays = displayRegistry.connectedDisplays
        if profile.appRules.filter(\.enabled).isEmpty {
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

        var cfg = ConfigManager.shared.config.windowSnapper
        cfg.activeProfileID = profile.id

        // Merge any display layout overrides from the profile into active displayLayouts
        for overrideLayout in profile.displayLayoutOverrides {
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

        displayRegistry.refresh(gaps: cfg.gaps)
        let displays = displayRegistry.connectedDisplays
        let ignored = Set(cfg.ignoredBundleIDs)

        // Unhide / unminimize target apps before scanning windows so restored windows are placed too
        var restoredAnyWindowOrApp = false
        if profile.unminimizeAndUnhideApps {
            for rule in profile.appRules where rule.enabled {
                for app in NSWorkspace.shared.runningApplications where !app.isTerminated
                    && (app.bundleIdentifier?.caseInsensitiveCompare(rule.bundleIdentifier) == .orderedSame) {
                    if app.isHidden {
                        _ = app.unhide()
                        restoredAnyWindowOrApp = true
                    }
                    let allAppWins = axController.windowsForAppSync(pid: app.processIdentifier, app: app)
                    for win in allAppWins where win.isMinimized {
                        _ = AXUIElementSetAttributeValue(win.elementBox.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                        restoredAnyWindowOrApp = true
                    }
                }
            }
        }

        // Hide unlisted regular apps if configured
        if profile.hideUnlistedApps {
            let listedIDs = Set(profile.appRules.filter(\.enabled).map { $0.bundleIdentifier.lowercased() })
            let selfID = Bundle.main.bundleIdentifier?.lowercased()
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
                let bid = app.bundleIdentifier?.lowercased() ?? ""
                if bid.isEmpty || bid == "com.apple.finder" || bid == selfID {
                    continue
                }
                if !listedIDs.contains(bid) {
                    _ = app.hide()
                }
            }
        }

        let scanAndPlace: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.axController.inspectAllVisibleStandardWindows(ignoredBundleIDs: ignored) { [weak self] visibleWindows in
                guard let self else { return }

                var undoItems: [WindowSnapUndoItem] = []
                var placedCount = 0
                var launchingNames: [String] = []
                let group = DispatchGroup()

                for rule in profile.appRules where rule.enabled {
                    guard let resolvedTarget = Self.resolveTargetDisplay(
                        for: rule.targetDisplay,
                        fallback: profile.disconnectedFallback,
                        displays: displays
                    ),
                    let zone = Self.resolveRuleZone(
                        rule: rule,
                        profile: profile,
                        on: resolvedTarget.display,
                        config: cfg
                    ) else {
                        continue
                    }

                    let runningMatches = NSWorkspace.shared.runningApplications.filter {
                        !$0.isTerminated && ($0.bundleIdentifier?.caseInsensitiveCompare(rule.bundleIdentifier) == .orderedSame)
                    }

                    let selected = Self.selectWindows(for: rule, from: visibleWindows)
                    if !selected.isEmpty {
                        let frames = Self.tiledFrames(
                            count: selected.count,
                            inside: zone.frameInAX,
                            innerGap: CGFloat(cfg.gaps.innerGapPoints)
                        )
                        for (idx, win) in selected.enumerated() {
                            let targetFrame = frames[idx]
                            let sourceDisp = self.displayRegistry.display(containingAXRect: win.frameAX)
                            group.enter()
                            self.axController.snapWindow(
                                win,
                                toAXFrame: targetFrame,
                                usableAXRect: resolvedTarget.display.usableAX,
                                sourceDisplayFrameAX: sourceDisp?.frameAX,
                                targetDisplayFrameAX: resolvedTarget.display.frameAX
                            ) { execResult in
                                if let execResult {
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
                                }
                                group.leave()
                            }
                        }
                    } else if runningMatches.isEmpty && rule.launchIfNotRunning {
                        launchingNames.append(rule.appName)
                        self.launchAndPlaceApp(
                            rule: rule,
                            zone: zone,
                            targetDisplay: resolvedTarget.display,
                            config: cfg
                        )
                    }
                }

                group.notify(queue: .main) {
                    self.isApplyingProfile = false
                    if !undoItems.isEmpty {
                        let batch = WindowSnapUndoBatch(
                            title: "Profile '\(profile.name)'",
                            isProfileBatch: true,
                            items: undoItems
                        )
                        onPushUndoBatch(batch)
                    }

                    DeveloperEventLog.shared.record(
                        .windowSnapper,
                        "Applied profile '\(profile.name)'",
                        detail: "placed: \(placedCount), launching: \(launchingNames.count)"
                    )

                    if cfg.showSnapHUDToasts {
                        if profile.appRules.filter(\.enabled).isEmpty {
                            HUDToast.shared.show(
                                title: "Applied layout '\(profile.name)'",
                                symbol: "rectangle.3.group",
                                tint: .indigo
                            )
                        } else {
                            let launchSuffix = launchingNames.isEmpty
                                ? ""
                                : ", launching \(launchingNames.joined(separator: ", "))"
                            HUDToast.shared.show(
                                title: "Applied '\(profile.name)' · \(placedCount) placed\(launchSuffix)",
                                symbol: "rectangle.3.group",
                                tint: .indigo
                            )
                        }
                    }

                    self.syncActiveProfileWatchers(config: ConfigManager.shared.config)
                }
            }
        }

        if restoredAnyWindowOrApp {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 140_000_000)
                scanAndPlace()
            }
        } else {
            scanAndPlace()
        }
    }

    // MARK: - App Launch + AXObserver Retry Placement (Electron/Chrome safe)

    private func launchAndPlaceApp(
        rule: ProfileAppRule,
        zone: ResolvedZone,
        targetDisplay: ConnectedDisplay,
        config: WindowSnapperConfig
    ) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleIdentifier) else {
            return
        }
        let openConfig = NSWorkspace.OpenConfiguration()
        openConfig.activates = false
        openConfig.addsToRecentItems = false

        NSWorkspace.shared.openApplication(at: appURL, configuration: openConfig) { [weak self] app, error in
            guard error == nil, let app else { return }
            Task { @MainActor [weak self] in
                self?.observeLaunchedAppForPlacement(
                    app: app,
                    rule: rule,
                    zone: zone,
                    targetDisplay: targetDisplay
                )
            }
        }
    }

    private func observeLaunchedAppForPlacement(
        app: NSRunningApplication,
        rule: ProfileAppRule,
        zone: ResolvedZone,
        targetDisplay: ConnectedDisplay
    ) {
        let pid = app.processIdentifier
        let taskKey = "\(rule.id):\(pid)"
        launchTimeoutTasks[taskKey]?.cancel()

        // Install AXObserver for kAXWindowCreatedNotification
        if PermissionsManager.isProcessTrusted() {
            let appAX = AXWindowController.applicationElement(for: pid)
            var obs: AXObserver?
            let callback: AXObserverCallback = { _, element, _, userInfo in
                guard let userInfo else { return }
                let ctx = Unmanaged<LaunchObserverBox>.fromOpaque(userInfo).takeUnretainedValue()
                let elBox = AXElementBox(element)
                Task { @MainActor in
                    ctx.onWindowCreated(elBox)
                }
            }
            if AXObserverCreate(pid, callback, &obs) == .success, let observer = obs {
                let box = LaunchObserverBox { [weak self] elBox in
                    self?.tryPlaceLaunchedElement(elBox, pid: pid, rule: rule, zone: zone, targetDisplay: targetDisplay, taskKey: taskKey)
                }
                objc_setAssociatedObject(observer, &LaunchObserverBox.assocKey, box, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                let boxPtr = Unmanaged.passUnretained(box).toOpaque()
                _ = AXObserverAddNotification(observer, appAX, kAXWindowCreatedNotification as CFString, boxPtr)
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                launchObservers[pid] = observer
            }
        }

        // Exponential backoff poller (50ms, 150ms, 350ms, 750ms, 1.5s, 2.5s up to 8s) handles Electron/Chrome windows
        launchTimeoutTasks[taskKey] = Task { @MainActor [weak self] in
            let delaysMs: [UInt64] = [50, 150, 350, 750, 1500, 2200, 2500]
            for delay in delaysMs {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                guard !Task.isCancelled, let self, !app.isTerminated else { return }
                let windows = self.axController.windowsForAppSync(pid: pid, app: app)
                if let valid = windows.first(where: { !$0.isFullscreen && !$0.isMinimized && $0.frameAX.width >= 100 && $0.frameAX.height >= 80 }) {
                    self.axController.snapWindow(
                        valid,
                        toAXFrame: zone.frameInAX,
                        usableAXRect: targetDisplay.usableAX,
                        sourceDisplayFrameAX: nil,
                        targetDisplayFrameAX: targetDisplay.frameAX
                    ) { _ in }
                    self.cleanupLaunchObserver(pid: pid, taskKey: taskKey)
                    return
                }
            }
            self?.cleanupLaunchObserver(pid: pid, taskKey: taskKey)
        }
    }

    private func tryPlaceLaunchedElement(
        _ elementBox: AXElementBox,
        pid: pid_t,
        rule: ProfileAppRule,
        zone: ResolvedZone,
        targetDisplay: ConnectedDisplay,
        taskKey: String
    ) {
        let windows = axController.windowsForAppSync(pid: pid)
        guard let valid = windows.first(where: {
            CFEqual($0.elementBox.element, elementBox.element)
                && !$0.isFullscreen && !$0.isMinimized
                && $0.frameAX.width >= 100 && $0.frameAX.height >= 80
        }) else {
            return
        }
        axController.snapWindow(
            valid,
            toAXFrame: zone.frameInAX,
            usableAXRect: targetDisplay.usableAX,
            sourceDisplayFrameAX: nil,
            targetDisplayFrameAX: targetDisplay.frameAX
        ) { _ in }
        cleanupLaunchObserver(pid: pid, taskKey: taskKey)
    }

    private func cleanupLaunchObserver(pid: pid_t, taskKey: String) {
        launchTimeoutTasks[taskKey]?.cancel()
        launchTimeoutTasks.removeValue(forKey: taskKey)
        if let obs = launchObservers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
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

        let autoRules = activeProfile.appRules.filter { $0.enabled && $0.autoPlaceNewWindowsWhileActive }
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
                displays: displays
            ),
            let zone = Self.resolveRuleZone(
                rule: entry.rule,
                profile: entry.profile,
                on: resolvedTarget.display,
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

    // MARK: - Display Topology Auto-Trigger

    func handleDisplaysReconfigured(
        connectedDisplays: [ConnectedDisplay],
        config: WindowSnapperConfig,
        onPushUndoBatch: @escaping (WindowSnapUndoBatch) -> Void
    ) {
        let connectedSigs = connectedDisplays.map(\.signature)
        let topologyKey = connectedSigs.map(\.stableStorageKey).sorted().joined(separator: "|")
        guard topologyKey != lastAutoTriggeredTopologyKey else { return }

        for profile in config.profiles where profile.topologyTriggerMode != .off && !profile.boundDisplaySignatures.isEmpty {
            if DisplayRegistry.topologiesMatch(bound: profile.boundDisplaySignatures, connected: connectedSigs) {
                lastAutoTriggeredTopologyKey = topologyKey
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
