import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import os

/// Normalized metadata for a single switchable window across open, minimized, and hidden states.
struct SwitcherWindowItem: Identifiable, Equatable, Sendable {
    let id: String
    let pid: pid_t
    let windowNumber: Int?
    let bundleIdentifier: String
    let appName: String
    let title: String
    let frameAX: CGRect
    let isMinimized: Bool
    let isHiddenApp: Bool
    let isOnActiveSpace: Bool
    let zOrderRank: Int

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? appName : title
    }

    static func makeID(pid: pid_t, windowNumber: Int?, axIndex: Int, title: String) -> String {
        if let windowNumber, windowNumber > 0 {
            return "win-\(pid)-\(windowNumber)"
        }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "ax-\(pid)-\(axIndex)-\(cleaned.hashValue)"
    }
}

/// Live window reference used to perform AX/NSWindow focus, close, and minimize actions.
final class WindowAXHandle: @unchecked Sendable {
    let element: AXUIElement?
    let pid: pid_t
    let windowNumber: Int?
    let selfWindowNumber: Int?

    init(
        element: AXUIElement?,
        pid: pid_t,
        windowNumber: Int?,
        selfWindowNumber: Int? = nil
    ) {
        self.element = element
        self.pid = pid
        self.windowNumber = windowNumber
        self.selfWindowNumber = selfWindowNumber
    }

    var isSelfProcess: Bool {
        selfWindowNumber != nil || pid == ProcessInfo.processInfo.processIdentifier
    }
}

struct WindowEnumerationResult: @unchecked Sendable {
    let items: [SwitcherWindowItem]
    let handlesByID: [String: WindowAXHandle]
}

struct CGWindowInfoEntry: Sendable {
    let windowNumber: Int
    let ownerPID: pid_t
    let boundsAX: CGRect
    let title: String
    let zOrderRank: Int
}

/// Tracks MRU activation sequence for both individual windows and applications so off-screen,
/// minimized, and hidden windows retain a predictable recency order alongside WindowServer z-order.
struct WindowMRUTracker: Equatable, Sendable {
    private(set) var windowRanks: [String: UInt64] = [:]
    private(set) var appRanks: [pid_t: UInt64] = [:]
    private(set) var sequence: UInt64 = 0

    mutating func recordWindowActivation(windowID: String, pid: pid_t) {
        sequence &+= 1
        windowRanks[windowID] = sequence
        appRanks[pid] = sequence
    }

    mutating func recordAppActivation(pid: pid_t) {
        sequence &+= 1
        appRanks[pid] = sequence
    }

    mutating func pruneDeadPIDs(_ livePIDs: Set<pid_t>) {
        appRanks = appRanks.filter { livePIDs.contains($0.key) }
        windowRanks = windowRanks.filter { entry in
            guard let pid = Self.pidFromWindowID(entry.key) else { return true }
            return livePIDs.contains(pid)
        }
    }

    func rank(for item: SwitcherWindowItem) -> UInt64? {
        windowRanks[item.id] ?? appRanks[item.pid]
    }

    private static func pidFromWindowID(_ id: String) -> pid_t? {
        let parts = id.split(separator: "-")
        guard parts.count >= 2, let raw = Int32(parts[1]) else { return nil }
        return pid_t(raw)
    }
}

/// Discovers, filters, sorts, and acts upon open, minimized, and hidden application windows.
enum WindowEnumerator {
    private static let axTimeoutSeconds: Float = 0.15
    private static let minimumWindowDimension: CGFloat = 50
    private static let protectedQuitBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock"
    ]

    private typealias AXUIElementGetWindowFunc = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    nonisolated private static let axGetWindowSymbol: AXUIElementGetWindowFunc? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(sym, to: AXUIElementGetWindowFunc.self)
    }()

    nonisolated static func windowNumber(for element: AXUIElement) -> Int? {
        guard let fn = axGetWindowSymbol else { return nil }
        var winID: CGWindowID = 0
        guard fn(element, &winID) == .success, winID != 0 else {
            return nil
        }
        return Int(winID)
    }

    // MARK: - Live CGWindow & AX Enumeration

    nonisolated static func onScreenLayerZeroEntries(
        excludingPanelWindowNumber: Int? = nil
    ) -> [CGWindowInfoEntry] {
        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var entries: [CGWindowInfoEntry] = []
        entries.reserveCapacity(rawList.count)
        var rank = 0

        for dict in rawList {
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer == 0 else { continue }

            guard let windowNumber = (dict[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  windowNumber > 0 else {
                continue
            }
            if let excluded = excludingPanelWindowNumber, windowNumber == excluded {
                continue
            }

            guard let ownerPID = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID > 0 else {
                continue
            }

            guard let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= minimumWindowDimension,
                  bounds.height >= minimumWindowDimension else {
                continue
            }

            let alpha = (dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            guard alpha > 0.01 else { continue }

            let title = (dict[kCGWindowName as String] as? String) ?? ""
            entries.append(
                CGWindowInfoEntry(
                    windowNumber: windowNumber,
                    ownerPID: pid_t(ownerPID),
                    boundsAX: bounds,
                    title: title,
                    zOrderRank: rank
                )
            )
            rank += 1
        }
        return entries
    }

    @MainActor
    static func enumerateSelfWindows(
        excludingPanelWindowNumber: Int?,
        zOrderByWindowNumber: [Int: Int]
    ) -> ([SwitcherWindowItem], [String: WindowAXHandle]) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.toolbox.app"
        let appName = (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleName"] as? String)
            ?? "Toolbox"
        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080
        let isAppHidden = NSApp.isHidden

        var items: [SwitcherWindowItem] = []
        var handles: [String: WindowAXHandle] = [:]

        for (index, win) in NSApp.windows.enumerated() {
            if win is NSPanel { continue }
            if let excludingPanelWindowNumber, win.windowNumber == excludingPanelWindowNumber { continue }
            guard win.styleMask.contains(.titled) else { continue }
            guard win.isVisible || win.isMiniaturized else { continue }

            let frameAX = SnapGeometry.appKitToAX(win.frame, primaryScreenHeight: primaryHeight)
            guard win.isMiniaturized
                    || (frameAX.width >= minimumWindowDimension && frameAX.height >= minimumWindowDimension) else {
                continue
            }

            let winNum = win.windowNumber > 0 ? win.windowNumber : nil
            let zRank = winNum.flatMap { zOrderByWindowNumber[$0] } ?? Int.max
            let title = win.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = SwitcherWindowItem.makeID(pid: selfPID, windowNumber: winNum, axIndex: index, title: title)

            let item = SwitcherWindowItem(
                id: id,
                pid: selfPID,
                windowNumber: winNum,
                bundleIdentifier: bundleID,
                appName: appName,
                title: title,
                frameAX: frameAX,
                isMinimized: win.isMiniaturized,
                isHiddenApp: isAppHidden,
                isOnActiveSpace: winNum.flatMap { zOrderByWindowNumber[$0] } != nil,
                zOrderRank: zRank
            )
            items.append(item)
            handles[id] = WindowAXHandle(
                element: nil,
                pid: selfPID,
                windowNumber: winNum,
                selfWindowNumber: win.windowNumber
            )
        }
        return (items, handles)
    }

    /// Instant zero-AX snapshot from on-screen `CGWindowList` entries so the HUD renders immediately.
    nonisolated static func fastOnScreenItems(
        from onScreenEntries: [CGWindowInfoEntry],
        excludingPID: pid_t
    ) -> ([SwitcherWindowItem], [String: WindowAXHandle]) {
        var appsByPID: [pid_t: (bundleID: String, appName: String, isHidden: Bool)] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard !app.isTerminated,
                  app.processIdentifier > 0,
                  app.processIdentifier != excludingPID,
                  app.activationPolicy == .regular else {
                continue
            }
            let bundleID = app.bundleIdentifier ?? ""
            let appName = app.localizedName ?? bundleID
            appsByPID[app.processIdentifier] = (bundleID, appName, app.isHidden)
        }

        var items: [SwitcherWindowItem] = []
        var handles: [String: WindowAXHandle] = [:]
        items.reserveCapacity(onScreenEntries.count)

        for entry in onScreenEntries {
            guard let appInfo = appsByPID[entry.ownerPID] else { continue }
            let id = SwitcherWindowItem.makeID(
                pid: entry.ownerPID,
                windowNumber: entry.windowNumber,
                axIndex: 0,
                title: entry.title
            )
            let item = SwitcherWindowItem(
                id: id,
                pid: entry.ownerPID,
                windowNumber: entry.windowNumber,
                bundleIdentifier: appInfo.bundleID,
                appName: appInfo.appName,
                title: entry.title,
                frameAX: entry.boundsAX,
                isMinimized: false,
                isHiddenApp: appInfo.isHidden,
                isOnActiveSpace: true,
                zOrderRank: entry.zOrderRank
            )
            items.append(item)
            handles[id] = WindowAXHandle(
                element: nil,
                pid: entry.ownerPID,
                windowNumber: entry.windowNumber
            )
        }
        return (items, handles)
    }

    nonisolated static func enumerateExternalWindows(
        excludingPID: pid_t,
        onScreenEntries: [CGWindowInfoEntry]
    ) -> ([SwitcherWindowItem], [String: WindowAXHandle]) {
        var cgByPID: [pid_t: [CGWindowInfoEntry]] = [:]
        var zOrderByWindowNumber: [Int: Int] = [:]
        for entry in onScreenEntries {
            cgByPID[entry.ownerPID, default: []].append(entry)
            zOrderByWindowNumber[entry.windowNumber] = entry.zOrderRank
        }

        struct AppSnapshot: Sendable {
            let pid: pid_t
            let bundleID: String
            let appName: String
            let isHidden: Bool
        }

        let appSnapshots: [AppSnapshot] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated,
                  app.processIdentifier > 0,
                  app.processIdentifier != excludingPID,
                  app.activationPolicy == .regular else {
                return nil
            }
            let bundleID = app.bundleIdentifier ?? ""
            return AppSnapshot(
                pid: app.processIdentifier,
                bundleID: bundleID,
                appName: app.localizedName ?? bundleID,
                isHidden: app.isHidden
            )
        }

        let collectedLock = OSAllocatedUnfairLock<(items: [SwitcherWindowItem], handles: [String: WindowAXHandle])>(
            initialState: ([], [:])
        )
        let cgMap = cgByPID
        let zMap = zOrderByWindowNumber

        DispatchQueue.concurrentPerform(iterations: appSnapshots.count) { index in
            let app = appSnapshots[index]
            let pid = app.pid
            let bundleID = app.bundleID
            let appName = app.appName
            let isHidden = app.isHidden
            let cgEntriesForApp = cgMap[pid] ?? []
            var matchedCGWindowNumbers: Set<Int> = []
            var localItems: [SwitcherWindowItem] = []
            var localHandles: [String: WindowAXHandle] = [:]

            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, axTimeoutSeconds)

            var windowsVal: AnyObject?
            let axStatus = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsVal)
            let axWindows = (axStatus == .success ? (windowsVal as? [AXUIElement]) : nil) ?? []

            for (axIndex, windowElement) in axWindows.enumerated() {
                AXUIElementSetMessagingTimeout(windowElement, axTimeoutSeconds)

                let role = copyStringAttribute(windowElement, kAXRoleAttribute as CFString)
                if let role, role != "AXWindow" { continue }

                let subrole = copyStringAttribute(windowElement, kAXSubroleAttribute as CFString)
                let isMinimized = copyBoolAttribute(windowElement, kAXMinimizedAttribute as CFString) ?? false
                let acceptedSubrole = subrole == nil
                    || subrole == "AXStandardWindow"
                    || subrole == "AXDialog"
                guard acceptedSubrole || isMinimized else { continue }

                let title = (copyStringAttribute(windowElement, kAXTitleAttribute as CFString) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let frameAX = copyRectAttribute(windowElement) ?? .zero

                if !isMinimized {
                    guard frameAX.width >= minimumWindowDimension,
                          frameAX.height >= minimumWindowDimension else {
                        continue
                    }
                }

                var winNum = windowNumber(for: windowElement)
                var matchedCG: CGWindowInfoEntry?
                if let winNum {
                    matchedCG = cgEntriesForApp.first { $0.windowNumber == winNum }
                }
                if matchedCG == nil {
                    let available = cgEntriesForApp.filter { !matchedCGWindowNumbers.contains($0.windowNumber) }
                    matchedCG = matchCGEntry(title: title, frameAX: frameAX, among: available)
                    if winNum == nil {
                        winNum = matchedCG?.windowNumber
                    }
                }

                if let matchedCG {
                    matchedCGWindowNumbers.insert(matchedCG.windowNumber)
                }

                let resolvedTitle = title.isEmpty ? (matchedCG?.title ?? "") : title
                let resolvedFrame = frameAX.isEmpty ? (matchedCG?.boundsAX ?? .zero) : frameAX
                let isOnActiveSpace = matchedCG != nil
                let zRank = matchedCG?.zOrderRank ?? (winNum.flatMap { zMap[$0] } ?? Int.max)

                let id = SwitcherWindowItem.makeID(
                    pid: pid,
                    windowNumber: winNum,
                    axIndex: axIndex,
                    title: resolvedTitle
                )
                let item = SwitcherWindowItem(
                    id: id,
                    pid: pid,
                    windowNumber: winNum,
                    bundleIdentifier: bundleID,
                    appName: appName,
                    title: resolvedTitle,
                    frameAX: resolvedFrame,
                    isMinimized: isMinimized,
                    isHiddenApp: isHidden,
                    isOnActiveSpace: isOnActiveSpace,
                    zOrderRank: zRank
                )
                localItems.append(item)
                localHandles[id] = WindowAXHandle(
                    element: windowElement,
                    pid: pid,
                    windowNumber: winNum
                )
            }

            // Fallback: if AX returned nothing (e.g. app momentarily unresponsive) but WindowServer
            // shows layer-0 windows for this regular app, expose them so switching still works.
            for cgEntry in cgEntriesForApp where !matchedCGWindowNumbers.contains(cgEntry.windowNumber) {
                let id = SwitcherWindowItem.makeID(
                    pid: pid,
                    windowNumber: cgEntry.windowNumber,
                    axIndex: 0,
                    title: cgEntry.title
                )
                let item = SwitcherWindowItem(
                    id: id,
                    pid: pid,
                    windowNumber: cgEntry.windowNumber,
                    bundleIdentifier: bundleID,
                    appName: appName,
                    title: cgEntry.title,
                    frameAX: cgEntry.boundsAX,
                    isMinimized: false,
                    isHiddenApp: isHidden,
                    isOnActiveSpace: true,
                    zOrderRank: cgEntry.zOrderRank
                )
                localItems.append(item)
                localHandles[id] = WindowAXHandle(
                    element: nil,
                    pid: pid,
                    windowNumber: cgEntry.windowNumber
                )
            }

            let finalItems = localItems
            let finalHandles = localHandles
            collectedLock.withLock { state in
                state.items.append(contentsOf: finalItems)
                for (k, v) in finalHandles {
                    state.handles[k] = v
                }
            }
        }

        return collectedLock.withLock { ($0.items, $0.handles) }
    }

    // MARK: - Pure Filtering & MRU Ordering

    nonisolated static func filterAndSort(
        items: [SwitcherWindowItem],
        config: WindowSwitcherConfig,
        mruTracker: WindowMRUTracker,
        activeDisplayBoundsAX: CGRect?,
        currentAppOnlyPID: pid_t?,
        query: String
    ) -> [SwitcherWindowItem] {
        let excludedSet = Set(config.excludedBundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }

        let filtered = items.filter { item in
            if !config.includeMinimized && item.isMinimized {
                return false
            }
            if !config.includeHiddenApps && item.isHiddenApp {
                return false
            }
            if config.activeSpaceOnly && !item.isOnActiveSpace {
                return false
            }
            if config.activeDisplayOnly, let displayBounds = activeDisplayBoundsAX {
                guard !item.frameAX.isEmpty else { return false }
                let center = CGPoint(x: item.frameAX.midX, y: item.frameAX.midY)
                if !displayBounds.contains(center) && !displayBounds.intersects(item.frameAX) {
                    return false
                }
            }
            if !item.bundleIdentifier.isEmpty,
               excludedSet.contains(item.bundleIdentifier.lowercased()) {
                return false
            }
            if let currentAppOnlyPID, item.pid != currentAppOnlyPID {
                return false
            }
            if !tokens.isEmpty && !matchesQuery(tokens: tokens, item: item) {
                return false
            }
            return true
        }

        return filtered.sorted { lhs, rhs in
            let lhsOnScreen = lhs.zOrderRank < Int.max
            let rhsOnScreen = rhs.zOrderRank < Int.max
            if lhsOnScreen != rhsOnScreen {
                return lhsOnScreen
            }
            if lhs.zOrderRank != rhs.zOrderRank {
                return lhs.zOrderRank < rhs.zOrderRank
            }

            let lhsWinRank = mruTracker.windowRanks[lhs.id] ?? 0
            let rhsWinRank = mruTracker.windowRanks[rhs.id] ?? 0
            if lhsWinRank != rhsWinRank {
                return lhsWinRank > rhsWinRank
            }

            let lhsAppRank = mruTracker.appRanks[lhs.pid] ?? 0
            let rhsAppRank = mruTracker.appRanks[rhs.pid] ?? 0
            if lhsAppRank != rhsAppRank {
                return lhsAppRank > rhsAppRank
            }

            if lhs.isMinimized != rhs.isMinimized {
                return !lhs.isMinimized
            }
            if lhs.isHiddenApp != rhs.isHiddenApp {
                return !lhs.isHiddenApp
            }

            let appOrder = lhs.appName.localizedCaseInsensitiveCompare(rhs.appName)
            if appOrder != .orderedSame {
                return appOrder == .orderedAscending
            }
            let titleOrder = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    nonisolated static func matchesQuery(_ query: String, item: SwitcherWindowItem) -> Bool {
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
        guard !tokens.isEmpty else { return true }
        return matchesQuery(tokens: tokens, item: item)
    }

    nonisolated private static func matchesQuery(tokens: [String], item: SwitcherWindowItem) -> Bool {
        for token in tokens {
            let matched = item.title.localizedCaseInsensitiveContains(token)
                || item.appName.localizedCaseInsensitiveContains(token)
                || item.bundleIdentifier.localizedCaseInsensitiveContains(token)
            if !matched {
                return false
            }
        }
        return true
    }

    // MARK: - Window Actions (Focus, Close, Minimize, Hide, Quit)

    @MainActor
    static func focusWindow(_ item: SwitcherWindowItem, handle: WindowAXHandle?) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if item.pid == selfPID || handle?.isSelfProcess == true {
            if NSApp.isHidden {
                NSApp.unhide(nil)
            }
            let winNum = handle?.selfWindowNumber ?? item.windowNumber
            if let win = winNum.flatMap({ NSApp.window(withWindowNumber: $0) }) {
                if win.isMiniaturized {
                    win.deminiaturize(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
                win.makeKeyAndOrderFront(nil)
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        guard let targetApp = NSRunningApplication(processIdentifier: item.pid),
              !targetApp.isTerminated else {
            return
        }

        let appAX = AXUIElementCreateApplication(item.pid)
        AXUIElementSetMessagingTimeout(appAX, axTimeoutSeconds)

        if targetApp.isHidden || item.isHiddenApp {
            _ = AXUIElementSetAttributeValue(appAX, kAXHiddenAttribute as CFString, kCFBooleanFalse)
            _ = targetApp.unhide()
        }

        let resolvedElement = resolveAXWindow(for: item, handle: handle, appElement: appAX)
        var wasMinimized = item.isMinimized
        if let winAX = resolvedElement {
            AXUIElementSetMessagingTimeout(winAX, axTimeoutSeconds)
            if copyBoolAttribute(winAX, kAXMinimizedAttribute as CFString) == true {
                wasMinimized = true
                _ = AXUIElementSetAttributeValue(winAX, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            _ = AXUIElementSetAttributeValue(winAX, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementPerformAction(winAX, kAXRaiseAction as CFString)
        }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier == selfPID {
            NSApp.yieldActivation(to: targetApp)
        }
        _ = AXUIElementSetAttributeValue(appAX, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = targetApp.activate()

        if wasMinimized, let winAX = resolvedElement {
            let winBox = WindowAXHandle(element: winAX, pid: item.pid, windowNumber: item.windowNumber)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let el = winBox.element else { return }
                AXUIElementSetMessagingTimeout(el, axTimeoutSeconds)
                _ = AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            }
        }
    }

    @MainActor
    @discardableResult
    static func closeWindow(_ item: SwitcherWindowItem, handle: WindowAXHandle?) -> Bool {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if item.pid == selfPID || handle?.isSelfProcess == true {
            let winNum = handle?.selfWindowNumber ?? item.windowNumber
            guard let win = winNum.flatMap({ NSApp.window(withWindowNumber: $0) }) else {
                return false
            }
            win.performClose(nil)
            return true
        }

        let appAX = AXUIElementCreateApplication(item.pid)
        guard let winAX = resolveAXWindow(for: item, handle: handle, appElement: appAX) else {
            return false
        }
        AXUIElementSetMessagingTimeout(winAX, axTimeoutSeconds)
        var closeBtnVal: AnyObject?
        guard AXUIElementCopyAttributeValue(winAX, kAXCloseButtonAttribute as CFString, &closeBtnVal) == .success,
              let closeBtn = closeBtnVal else {
            return false
        }
        let closeElement = closeBtn as! AXUIElement
        AXUIElementSetMessagingTimeout(closeElement, axTimeoutSeconds)
        return AXUIElementPerformAction(closeElement, kAXPressAction as CFString) == .success
    }

    @MainActor
    @discardableResult
    static func toggleMinimize(_ item: SwitcherWindowItem, handle: WindowAXHandle?) -> Bool {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if item.pid == selfPID || handle?.isSelfProcess == true {
            let winNum = handle?.selfWindowNumber ?? item.windowNumber
            guard let win = winNum.flatMap({ NSApp.window(withWindowNumber: $0) }) else {
                return item.isMinimized
            }
            if win.isMiniaturized {
                win.deminiaturize(nil)
                return false
            } else {
                win.miniaturize(nil)
                return true
            }
        }

        let appAX = AXUIElementCreateApplication(item.pid)
        guard let winAX = resolveAXWindow(for: item, handle: handle, appElement: appAX) else {
            return item.isMinimized
        }
        AXUIElementSetMessagingTimeout(winAX, axTimeoutSeconds)
        let currentlyMinimized = copyBoolAttribute(winAX, kAXMinimizedAttribute as CFString) ?? item.isMinimized
        let nextMinimized = !currentlyMinimized
        let result = AXUIElementSetAttributeValue(
            winAX,
            kAXMinimizedAttribute as CFString,
            nextMinimized ? kCFBooleanTrue : kCFBooleanFalse
        )
        return result == .success ? nextMinimized : currentlyMinimized
    }

    @MainActor
    @discardableResult
    static func hideApp(pid: pid_t) -> Bool {
        if pid == ProcessInfo.processInfo.processIdentifier {
            NSApp.hide(nil)
            return true
        }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return false
        }
        let appAX = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appAX, axTimeoutSeconds)
        _ = AXUIElementSetAttributeValue(appAX, kAXHiddenAttribute as CFString, kCFBooleanTrue)
        return app.hide()
    }

    @MainActor
    @discardableResult
    static func quitApp(pid: pid_t, bundleID: String) -> Bool {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard pid != selfPID else { return false }
        if protectedQuitBundleIDs.contains(bundleID.lowercased()) {
            return false
        }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return false
        }
        return app.terminate()
    }

    static func isProtectedFromQuit(bundleID: String, selfBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        let lowered = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let selfBundleID, lowered == selfBundleID.lowercased() {
            return true
        }
        return protectedQuitBundleIDs.contains(lowered)
    }

    // MARK: - AX Helpers

    nonisolated private static func resolveAXWindow(
        for item: SwitcherWindowItem,
        handle: WindowAXHandle?,
        appElement: AXUIElement
    ) -> AXUIElement? {
        if let element = handle?.element {
            return element
        }
        AXUIElementSetMessagingTimeout(appElement, axTimeoutSeconds)
        var windowsVal: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsVal) == .success,
              let windows = windowsVal as? [AXUIElement] else {
            return nil
        }
        if let targetNum = item.windowNumber {
            for win in windows {
                if windowNumber(for: win) == targetNum {
                    return win
                }
            }
        }
        if !item.title.isEmpty {
            for win in windows where copyStringAttribute(win, kAXTitleAttribute as CFString) == item.title {
                return win
            }
        }
        return windows.first
    }

    nonisolated private static func matchCGEntry(
        title: String,
        frameAX: CGRect,
        among candidates: [CGWindowInfoEntry]
    ) -> CGWindowInfoEntry? {
        var bestEntry: CGWindowInfoEntry?
        var bestScore = Double.greatestFiniteMagnitude

        for candidate in candidates {
            var score = 0.0
            if !frameAX.isEmpty && !candidate.boundsAX.isEmpty {
                let delta = abs(frameAX.minX - candidate.boundsAX.minX)
                    + abs(frameAX.minY - candidate.boundsAX.minY)
                    + abs(frameAX.width - candidate.boundsAX.width)
                    + abs(frameAX.height - candidate.boundsAX.height)
                if delta > 80 {
                    continue
                }
                score += Double(delta)
            } else if !title.isEmpty && candidate.title != title {
                continue
            }

            if !title.isEmpty && candidate.title == title {
                score -= 25.0
            }
            if score < bestScore {
                bestScore = score
                bestEntry = candidate
            }
        }
        return bestEntry
    }

    nonisolated private static func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    nonisolated private static func copyBoolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        if let boolVal = value as? Bool { return boolVal }
        if let numVal = value as? NSNumber { return numVal.boolValue }
        return nil
    }

    nonisolated private static func copyRectAttribute(_ element: AXUIElement) -> CGRect? {
        var posVal: AnyObject?
        var sizeVal: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeVal) == .success,
              let posVal,
              let sizeVal else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }
}
