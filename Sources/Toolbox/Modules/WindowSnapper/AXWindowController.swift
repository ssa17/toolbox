import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore

final class AXElementBox: @unchecked Sendable {
    let element: AXUIElement
    let selfWindowNumber: Int?

    init(_ element: AXUIElement, selfWindowNumber: Int? = nil) {
        self.element = element
        self.selfWindowNumber = selfWindowNumber
    }

    var isSelfProcess: Bool {
        if selfWindowNumber != nil {
            return true
        }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success
            && pid == ProcessInfo.processInfo.processIdentifier
    }
}

struct WindowSnapUndoItem: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    let pid: Int32
    let windowNumber: Int?
    let bundleIdentifier: String
    let appName: String
    let windowTitle: String
    let initialFrameAX: CGRect
    let afterFrameAX: CGRect
    let displaySignature: DisplaySignature?
    let zoneName: String
    let timestamp: Date

    init(
        id: String = UUID().uuidString,
        pid: Int32,
        windowNumber: Int? = nil,
        bundleIdentifier: String,
        appName: String,
        windowTitle: String,
        initialFrameAX: CGRect,
        afterFrameAX: CGRect,
        displaySignature: DisplaySignature? = nil,
        zoneName: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.pid = pid
        self.windowNumber = windowNumber
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.initialFrameAX = initialFrameAX
        self.afterFrameAX = afterFrameAX
        self.displaySignature = displaySignature
        self.zoneName = zoneName
        self.timestamp = timestamp
    }
}

struct WindowSnapUndoBatch: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    let title: String
    let isProfileBatch: Bool
    let items: [WindowSnapUndoItem]
    let timestamp: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        isProfileBatch: Bool,
        items: [WindowSnapUndoItem],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.isProfileBatch = isProfileBatch
        self.items = items
        self.timestamp = timestamp
    }
}

struct WindowSnapUndoStack: Sendable {
    var maxDepth: Int {
        didSet {
            maxDepth = WindowSnapperConfig.clampedUndoDepth(maxDepth)
            trimToDepth()
        }
    }

    private(set) var batches: [WindowSnapUndoBatch] = []

    init(maxDepth: Int = 25) {
        self.maxDepth = WindowSnapperConfig.clampedUndoDepth(maxDepth)
    }

    mutating func pushSingle(_ item: WindowSnapUndoItem) {
        let title = item.appName.isEmpty ? item.zoneName : "\(item.appName) -> \(item.zoneName)"
        pushBatch(title: title, isProfileBatch: false, items: [item])
    }

    mutating func pushBatch(title: String, isProfileBatch: Bool, items: [WindowSnapUndoItem]) {
        guard !items.isEmpty else { return }
        let batch = WindowSnapUndoBatch(
            title: title,
            isProfileBatch: isProfileBatch,
            items: items,
            timestamp: Date()
        )
        batches.insert(batch, at: 0)
        trimToDepth()
    }

    mutating func popUndo() -> WindowSnapUndoBatch? {
        guard !batches.isEmpty else { return nil }
        return batches.removeFirst()
    }

    mutating func removeBatch(id: String) -> WindowSnapUndoBatch? {
        guard let idx = batches.firstIndex(where: { $0.id == id }) else { return nil }
        return batches.remove(at: idx)
    }

    mutating func clear() {
        batches.removeAll()
    }

    /// Finds the most recent snap entry whose `afterFrameAX` matches `currentFrameAX`
    /// for the specified window, so drag-away or Restore Window Size can return to `initialFrameAX`.
    func latestPreSnapItem(
        forPID pid: Int32,
        windowTitle: String,
        currentFrameAX: CGRect,
        tolerance: CGFloat = 16
    ) -> WindowSnapUndoItem? {
        for batch in batches {
            for item in batch.items where item.pid == pid {
                let sizeMatches = abs(item.afterFrameAX.width - currentFrameAX.width) <= tolerance
                    && abs(item.afterFrameAX.height - currentFrameAX.height) <= tolerance
                let originMatches = abs(item.afterFrameAX.minX - currentFrameAX.minX) <= tolerance
                    && abs(item.afterFrameAX.minY - currentFrameAX.minY) <= tolerance
                if sizeMatches && originMatches {
                    return item
                }
            }
        }
        // Fallback: match same PID & title if size still matches afterFrameAX
        if !windowTitle.isEmpty {
            for batch in batches {
                for item in batch.items where item.pid == pid && item.windowTitle == windowTitle {
                    let sizeMatches = abs(item.afterFrameAX.width - currentFrameAX.width) <= tolerance
                        && abs(item.afterFrameAX.height - currentFrameAX.height) <= tolerance
                    if sizeMatches {
                        return item
                    }
                }
            }
        }
        return nil
    }

    private mutating func trimToDepth() {
        if batches.count > maxDepth {
            batches.removeLast(batches.count - maxDepth)
        }
    }
}

struct PreSnapFrameRecord: Codable, Equatable, Sendable {
    var windowNumber: Int?
    let pid: pid_t
    let bundleIdentifier: String
    var originalFrameAX: CGRect
    var lastSnappedFrameAX: CGRect
    var updatedAt: Date
}

struct PreSnapFrameStore: Sendable {
    private(set) var records: [PreSnapFrameRecord] = []

    private static func sizesMatch(_ lhs: CGSize, _ rhs: CGSize, tolerance: CGFloat) -> Bool {
        abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    private func matchingRecordIndex(
        pid: pid_t,
        windowNumber: Int?,
        size: CGSize,
        sizeTolerance: CGFloat
    ) -> Int? {
        if let windowNumber,
           let exactIdx = records.firstIndex(where: {
               $0.windowNumber == windowNumber && Self.sizesMatch($0.lastSnappedFrameAX.size, size, tolerance: sizeTolerance)
           }) {
            return exactIdx
        }
        return records.indices
            .filter { idx in
                let r = records[idx]
                guard r.pid == pid else { return false }
                let compatNumber = (windowNumber == nil || r.windowNumber == nil || r.windowNumber == windowNumber)
                return compatNumber && Self.sizesMatch(r.lastSnappedFrameAX.size, size, tolerance: sizeTolerance)
            }
            .max(by: { records[$0].updatedAt < records[$1].updatedAt })
    }

    mutating func recordSnap(
        window: DiscoveredAXWindow,
        preSnapFrameAX: CGRect,
        appliedFrameAX: CGRect,
        sizeTolerance: CGFloat = 36
    ) {
        recordSnap(
            pid: window.pid,
            windowNumber: window.windowNumber,
            bundleIdentifier: window.bundleIdentifier,
            preSnapFrameAX: preSnapFrameAX,
            appliedFrameAX: appliedFrameAX,
            sizeTolerance: sizeTolerance
        )
    }

    mutating func recordSnap(
        pid: pid_t,
        windowNumber: Int?,
        bundleIdentifier: String,
        preSnapFrameAX: CGRect,
        appliedFrameAX: CGRect,
        sizeTolerance: CGFloat = 36
    ) {
        let now = Date()
        if let existingIdx = matchingRecordIndex(
            pid: pid,
            windowNumber: windowNumber,
            size: preSnapFrameAX.size,
            sizeTolerance: sizeTolerance
        ) {
            records[existingIdx].windowNumber = windowNumber ?? records[existingIdx].windowNumber
            records[existingIdx].lastSnappedFrameAX = appliedFrameAX
            records[existingIdx].updatedAt = now
            return
        }

        if let windowNumber {
            records.removeAll { $0.windowNumber == windowNumber }
        }
        let record = PreSnapFrameRecord(
            windowNumber: windowNumber,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            originalFrameAX: preSnapFrameAX,
            lastSnappedFrameAX: appliedFrameAX,
            updatedAt: now
        )
        records.append(record)
        if records.count > 100 {
            records.removeFirst(records.count - 100)
        }
    }

    func lookupOriginalFrameIfSnapped(
        for window: DiscoveredAXWindow,
        currentSizeAX: CGSize? = nil,
        sizeTolerance: CGFloat = 36
    ) -> CGRect? {
        let sizeToCheck = currentSizeAX ?? window.frameAX.size
        guard let idx = matchingRecordIndex(
            pid: window.pid,
            windowNumber: window.windowNumber,
            size: sizeToCheck,
            sizeTolerance: sizeTolerance
        ) else {
            return nil
        }
        let record = records[idx]
        let differsFromOriginal = abs(record.originalFrameAX.width - sizeToCheck.width) > 8
            || abs(record.originalFrameAX.height - sizeToCheck.height) > 8
        return differsFromOriginal ? record.originalFrameAX : nil
    }

    mutating func clearRecord(for window: DiscoveredAXWindow) {
        clearRecord(pid: window.pid, windowNumber: window.windowNumber, sizeAX: window.frameAX.size)
    }

    mutating func clearRecord(pid: pid_t, windowNumber: Int?, sizeAX: CGSize? = nil) {
        if let windowNumber {
            records.removeAll { $0.windowNumber == windowNumber }
        }
        if let sizeAX {
            records.removeAll {
                $0.pid == pid
                    && ($0.windowNumber == nil || windowNumber == nil)
                    && Self.sizesMatch($0.lastSnappedFrameAX.size, sizeAX, tolerance: 36)
            }
        } else if windowNumber == nil {
            records.removeAll { $0.pid == pid }
        }
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
    }

    static func load(from url: URL, livePIDs: Set<pid_t>? = nil) -> PreSnapFrameStore {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([PreSnapFrameRecord].self, from: data) else {
            return PreSnapFrameStore()
        }
        var store = PreSnapFrameStore()
        if let livePIDs {
            store.records = decoded.filter { livePIDs.contains($0.pid) }
        } else {
            store.records = decoded
        }
        if store.records.count > 100 {
            store.records.removeFirst(store.records.count - 100)
        }
        return store
    }
}

struct DiscoveredAXWindow: @unchecked Sendable {
    let pid: pid_t
    let windowNumber: Int?
    let bundleIdentifier: String
    let appName: String
    let title: String
    let frameAX: CGRect
    let isFullscreen: Bool
    let isMinimized: Bool
    let elementBox: AXElementBox
    let minSize: CGSize?

    init(
        pid: pid_t,
        windowNumber: Int?,
        bundleIdentifier: String,
        appName: String,
        title: String,
        frameAX: CGRect,
        isFullscreen: Bool,
        isMinimized: Bool,
        elementBox: AXElementBox,
        minSize: CGSize? = nil
    ) {
        self.pid = pid
        self.windowNumber = windowNumber
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.title = title
        self.frameAX = frameAX
        self.isFullscreen = isFullscreen
        self.isMinimized = isMinimized
        self.elementBox = elementBox
        self.minSize = minSize
    }
}

enum FocusedWindowLookupResult: @unchecked Sendable {
    case window(DiscoveredAXWindow)
    case fullscreen(appName: String)
    case ignored
    case none
}

struct CGWindowLayerZeroEntry: Sendable {
    let windowNumber: Int
    let ownerPID: pid_t
    let boundsAX: CGRect
    let title: String
}

struct WindowSnapExecutionResult: Sendable {
    let appliedFrameAX: CGRect
    let clampedForMinSize: Bool
    let minSizeReported: CGSize?
}

final class AXWindowController: @unchecked Sendable {
    static let axTimeoutSeconds: Float = 0.25
    static let snapAnimationDuration: TimeInterval = WindowAnimationSpeed.smooth.snapDuration
    static let unsnapResizeAnimationDuration: TimeInterval = WindowAnimationSpeed.smooth.unsnapResizeDuration

    private let axQueue = DispatchQueue(label: "app.toolbox.window-snapping.ax", qos: .userInteractive)
    private let animationQueue = DispatchQueue(label: "app.toolbox.window-snapping.anim", qos: .userInteractive)
    private let cacheLock = NSLock()
    private var elementCacheByUndoID: [String: AXElementBox] = [:]
    private let animationLock = NSLock()
    private var activeAnimationTokens: [pid_t: UInt64] = [:]

    @discardableResult
    private func bumpAnimationToken(for pid: pid_t) -> UInt64 {
        animationLock.lock()
        let next = (activeAnimationTokens[pid] ?? 0) &+ 1
        activeAnimationTokens[pid] = next
        animationLock.unlock()
        return next
    }

    private func isAnimationTokenActive(_ token: UInt64, for pid: pid_t) -> Bool {
        animationLock.lock()
        let active = activeAnimationTokens[pid] == token
        animationLock.unlock()
        return active
    }

    private func pidForBox(_ box: AXElementBox) -> pid_t {
        if box.isSelfProcess {
            return ProcessInfo.processInfo.processIdentifier
        }
        var pid: pid_t = 0
        if AXUIElementGetPid(box.element, &pid) == .success {
            return pid
        }
        return 0
    }

    func cacheElement(_ box: AXElementBox, forUndoItemID id: String) {
        cacheLock.lock()
        elementCacheByUndoID[id] = box
        if elementCacheByUndoID.count > 200 {
            let keysToKeep = Array(elementCacheByUndoID.keys.prefix(100))
            var trimmed: [String: AXElementBox] = [:]
            for k in keysToKeep {
                trimmed[k] = elementCacheByUndoID[k]
            }
            elementCacheByUndoID = trimmed
        }
        cacheLock.unlock()
    }

    func cachedElement(forUndoItemID id: String) -> AXElementBox? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return elementCacheByUndoID[id]
    }

    func removeCachedElements(for itemIDs: [String]) {
        cacheLock.lock()
        for id in itemIDs {
            elementCacheByUndoID.removeValue(forKey: id)
        }
        cacheLock.unlock()
    }

    // MARK: - In-Process NSWindow Operations (avoids HIServices/AppKit off-main-thread deadlock)

    @MainActor
    private static func primaryScreenHeightMainActor() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080
    }

    @MainActor
    private static func findSelfWindow(number: Int?) -> NSWindow? {
        if let number,
           let byNum = NSApp.window(withWindowNumber: number),
           !(byNum is NSPanel),
           byNum.styleMask.contains(.titled) {
            return byNum
        }
        return NSApp.windows.first {
            !($0 is NSPanel) && $0.styleMask.contains(.titled) && $0.isVisible
        }
    }

    @MainActor
    static func standardSelfWindowsMainActor() -> [DiscoveredAXWindow] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let primaryH = primaryScreenHeightMainActor()
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let appName = (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? "Toolbox"

        return NSApp.windows.compactMap { win in
            guard !(win is NSPanel),
                  win.styleMask.contains(.titled),
                  win.isVisible else {
                return nil
            }
            let frameAX = SnapGeometry.appKitToAX(win.frame, primaryScreenHeight: primaryH)
            guard frameAX.width >= 80, frameAX.height >= 60 else { return nil }
            let box = AXElementBox(applicationElement(for: selfPID), selfWindowNumber: win.windowNumber)
            let winMin: CGSize? = (win.minSize.width > 0 || win.minSize.height > 0) ? win.minSize : nil
            return DiscoveredAXWindow(
                pid: selfPID,
                windowNumber: win.windowNumber,
                bundleIdentifier: bundleID,
                appName: appName,
                title: win.title,
                frameAX: frameAX,
                isFullscreen: win.styleMask.contains(.fullScreen),
                isMinimized: win.isMiniaturized,
                elementBox: box,
                minSize: winMin
            )
        }
    }

    @MainActor
    static func inspectSelfWindowMainActor(
        windowNumber: Int?,
        atAXPoint point: CGPoint,
        ignoredBundleIDs: Set<String>
    ) -> DiscoveredAXWindow? {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        if isBundleIgnored(bundleID, ignoredBundleIDs: ignoredBundleIDs) {
            return nil
        }
        let selfWins = standardSelfWindowsMainActor()
        let match = (windowNumber.flatMap { num in selfWins.first(where: { $0.windowNumber == num }) })
            ?? selfWins.first(where: { $0.frameAX.contains(point) })
        if let match, !match.isFullscreen, !match.isMinimized {
            return match
        }
        return nil
    }

    @MainActor
    static func readSelfWindowFrameMainActor(windowNumber: Int?) -> CGRect? {
        guard let win = findSelfWindow(number: windowNumber) else { return nil }
        return SnapGeometry.appKitToAX(win.frame, primaryScreenHeight: primaryScreenHeightMainActor())
    }

    @MainActor
    static func moveSelfWindowOriginMainActor(windowNumber: Int?, toAXOrigin origin: CGPoint) {
        guard let win = findSelfWindow(number: windowNumber) else { return }
        let primaryH = primaryScreenHeightMainActor()
        win.setFrameTopLeftPoint(NSPoint(x: origin.x, y: primaryH - origin.y))
    }

    @MainActor
    private static var activeSelfResizeTimer: Timer?

    @MainActor
    static func cancelSelfResizeAnimationMainActor() {
        activeSelfResizeTimer?.invalidate()
        activeSelfResizeTimer = nil
    }

    @MainActor
    static func resizeSelfWindowSizeMainActor(
        windowNumber: Int?,
        toAXSize size: CGSize,
        animationSpeed: WindowAnimationSpeed = .off
    ) {
        cancelSelfResizeAnimationMainActor()
        guard let win = findSelfWindow(number: windowNumber) else { return }
        let startSize = win.frame.size
        let targetW = max(size.width, win.minSize.width)
        let targetH = max(size.height, win.minSize.height)
        let targetSize = CGSize(width: targetW, height: targetH)

        let delta = max(abs(startSize.width - targetW), abs(startSize.height - targetH))
        let duration = animationSpeed.unsnapResizeDuration
        guard animationSpeed.isAnimated, duration > 0, delta > 3 else {
            let current = win.frame
            let newOrigin = NSPoint(x: current.minX, y: current.maxY - targetH)
            win.setFrame(NSRect(origin: newOrigin, size: targetSize), display: true)
            return
        }

        let startTime = CACurrentMediaTime()
        let targetWinNumber = win.windowNumber
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let liveWin = findSelfWindow(number: targetWinNumber) else {
                    cancelSelfResizeAnimationMainActor()
                    return
                }
                let elapsed = CACurrentMediaTime() - startTime
                let rawProgress = CGFloat(min(1.0, max(0.0, elapsed / duration)))
                let current = liveWin.frame

                if rawProgress >= 1.0 {
                    let finalOrigin = NSPoint(x: current.minX, y: current.maxY - targetH)
                    liveWin.setFrame(NSRect(origin: finalOrigin, size: targetSize), display: true)
                    cancelSelfResizeAnimationMainActor()
                } else {
                    let stepSize = SnapGeometry.interpolatedSize(from: startSize, to: targetSize, progress: rawProgress)
                    let stepW = max(stepSize.width, liveWin.minSize.width)
                    let stepH = max(stepSize.height, liveWin.minSize.height)
                    let stepOrigin = NSPoint(x: current.minX, y: current.maxY - stepH)
                    liveWin.setFrame(NSRect(origin: stepOrigin, size: NSSize(width: stepW, height: stepH)), display: true)
                }
            }
        }
        activeSelfResizeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    static func applySelfWindowFrameMainActor(
        windowNumber: Int?,
        targetFrameAX: CGRect,
        usableAXRect: CGRect,
        animationSpeed: WindowAnimationSpeed = .off
    ) -> WindowSnapExecutionResult? {
        cancelSelfResizeAnimationMainActor()
        guard let win = findSelfWindow(number: windowNumber) else { return nil }
        let primaryH = primaryScreenHeightMainActor()
        let minSize = (win.minSize.width > 0 || win.minSize.height > 0) ? win.minSize : nil

        let clampedW = max(targetFrameAX.width, win.minSize.width)
        let clampedH = max(targetFrameAX.height, win.minSize.height)
        var finalFrame = targetFrameAX
        var didClamp = false

        if clampedW > targetFrameAX.width + 2.0 || clampedH > targetFrameAX.height + 2.0 {
            finalFrame = SnapGeometry.clampFrameForMinimumSize(
                targetFrame: targetFrameAX,
                actualSize: CGSize(width: clampedW, height: clampedH),
                usableRect: usableAXRect
            )
            didClamp = true
        }

        let currentAX = SnapGeometry.appKitToAX(win.frame, primaryScreenHeight: primaryH)
        let delta = max(
            abs(currentAX.minX - finalFrame.minX),
            abs(currentAX.minY - finalFrame.minY),
            abs(currentAX.width - finalFrame.width),
            abs(currentAX.height - finalFrame.height)
        )
        let finalAppKit = SnapGeometry.axToAppKit(finalFrame, primaryScreenHeight: primaryH)

        let duration = animationSpeed.snapDuration
        if animationSpeed.isAnimated && duration > 0 && delta > 3 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().setFrame(finalAppKit, display: true)
            }
            return WindowSnapExecutionResult(
                appliedFrameAX: finalFrame,
                clampedForMinSize: didClamp,
                minSizeReported: minSize
            )
        }

        let targetAppKit = SnapGeometry.axToAppKit(targetFrameAX, primaryScreenHeight: primaryH)
        win.setFrame(targetAppKit, display: true)

        let actualAX = SnapGeometry.appKitToAX(win.frame, primaryScreenHeight: primaryH)
        finalFrame = actualAX
        didClamp = false

        if actualAX.width > targetFrameAX.width + 2.0 || actualAX.height > targetFrameAX.height + 2.0 {
            let clamped = SnapGeometry.clampFrameForMinimumSize(
                targetFrame: targetFrameAX,
                actualSize: actualAX.size,
                usableRect: usableAXRect
            )
            if abs(clamped.origin.x - actualAX.origin.x) > 1.0 || abs(clamped.origin.y - actualAX.origin.y) > 1.0 {
                let clampedAppKit = SnapGeometry.axToAppKit(clamped, primaryScreenHeight: primaryH)
                win.setFrame(clampedAppKit, display: true)
                finalFrame = SnapGeometry.appKitToAX(win.frame, primaryScreenHeight: primaryH)
            }
            didClamp = true
        }

        return WindowSnapExecutionResult(
            appliedFrameAX: finalFrame,
            clampedForMinSize: didClamp,
            minSizeReported: minSize
        )
    }

    // MARK: - Asynchronous Public Dispatch

    static func topmostLayerZeroEntry(atAXPoint point: CGPoint) -> CGWindowLayerZeroEntry? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        return onScreenLayerZeroWindows().first { entry in
            guard entry.boundsAX.contains(point) else { return false }
            if entry.ownerPID == selfPID { return true }
            guard let app = NSRunningApplication(processIdentifier: entry.ownerPID),
                  !app.isTerminated,
                  app.activationPolicy == .regular else {
                return false
            }
            return true
        }
    }

    static func layerZeroWindowBounds(windowNumber: Int) -> CGRect? {
        guard windowNumber > 0,
              let rawList = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]],
              let dict = rawList.first,
              let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              bounds.width >= 40, bounds.height >= 40 else {
            return nil
        }
        return bounds
    }

    func inspectWindow(
        forCGEntry entry: CGWindowLayerZeroEntry?,
        fallbackAXPoint point: CGPoint,
        ignoredBundleIDs: Set<String>,
        completion: @escaping @MainActor (DiscoveredAXWindow?) -> Void
    ) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if let entry, entry.ownerPID == selfPID {
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    completion(Self.inspectSelfWindowMainActor(
                        windowNumber: entry.windowNumber,
                        atAXPoint: point,
                        ignoredBundleIDs: ignoredBundleIDs
                    ))
                }
            } else {
                Task { @MainActor in
                    completion(Self.inspectSelfWindowMainActor(
                        windowNumber: entry.windowNumber,
                        atAXPoint: point,
                        ignoredBundleIDs: ignoredBundleIDs
                    ))
                }
            }
            return
        }

        axQueue.async { [weak self] in
            guard let self else {
                Task { @MainActor in completion(nil) }
                return
            }

            if let entry,
               let app = NSRunningApplication(processIdentifier: entry.ownerPID),
               !app.isTerminated,
               app.activationPolicy == .regular {
                let bundleID = app.bundleIdentifier ?? ""
                if Self.isBundleIgnored(bundleID, ignoredBundleIDs: ignoredBundleIDs) {
                    Task { @MainActor in completion(nil) }
                    return
                }
                let liveBounds = Self.layerZeroWindowBounds(windowNumber: entry.windowNumber) ?? entry.boundsAX
                let updatedEntry = CGWindowLayerZeroEntry(
                    windowNumber: entry.windowNumber,
                    ownerPID: entry.ownerPID,
                    boundsAX: liveBounds,
                    title: entry.title
                )
                let axWindows = self.windowsForAppSync(pid: entry.ownerPID, app: app)
                if let matched = Self.matchAXWindow(for: updatedEntry, among: axWindows) {
                    if matched.isFullscreen || matched.isMinimized {
                        Task { @MainActor in completion(nil) }
                    } else {
                        Task { @MainActor in completion(matched) }
                    }
                    return
                }
            }

            let found = self.topmostStandardWindowSync(atAXPoint: point, ignoredBundleIDs: ignoredBundleIDs)
            Task { @MainActor in
                completion(found)
            }
        }
    }

    func inspectTopmostWindow(
        atAXPoint point: CGPoint,
        ignoredBundleIDs: Set<String>,
        completion: @escaping @MainActor (DiscoveredAXWindow?) -> Void
    ) {
        axQueue.async { [weak self] in
            guard let self else {
                Task { @MainActor in completion(nil) }
                return
            }
            let selfPID = ProcessInfo.processInfo.processIdentifier
            let cgEntries = Self.onScreenLayerZeroWindows()
            if let topSelfOrRegular = cgEntries.first(where: { entry in
                guard entry.boundsAX.contains(point) else { return false }
                if entry.ownerPID == selfPID { return true }
                return NSRunningApplication(processIdentifier: entry.ownerPID)?.activationPolicy == .regular
            }), topSelfOrRegular.ownerPID == selfPID {
                let bundleID = Bundle.main.bundleIdentifier ?? ""
                if Self.isBundleIgnored(bundleID, ignoredBundleIDs: ignoredBundleIDs) {
                    Task { @MainActor in completion(nil) }
                    return
                }
                let targetWinNum = topSelfOrRegular.windowNumber
                let entryTitle = topSelfOrRegular.title
                Task { @MainActor in
                    let selfWins = Self.standardSelfWindowsMainActor()
                    let match = selfWins.first(where: { $0.windowNumber == targetWinNum })
                        ?? (entryTitle.isEmpty ? nil : selfWins.first(where: { $0.title == entryTitle }))
                        ?? selfWins.first(where: { $0.frameAX.contains(point) })
                    if let match, !match.isFullscreen, !match.isMinimized {
                        completion(match)
                    } else {
                        completion(nil)
                    }
                }
                return
            }

            let found = self.topmostStandardWindowSync(atAXPoint: point, ignoredBundleIDs: ignoredBundleIDs)
            Task { @MainActor in
                completion(found)
            }
        }
    }

    func readWindowFrame(
        _ box: AXElementBox,
        completion: @escaping @MainActor (CGRect?) -> Void
    ) {
        if box.isSelfProcess {
            let winNum = box.selfWindowNumber
            Task { @MainActor in
                completion(Self.readSelfWindowFrameMainActor(windowNumber: winNum))
            }
            return
        }
        axQueue.async {
            let frame = Self.copyFrameAX(of: box.element)
            Task { @MainActor in
                completion(frame)
            }
        }
    }

    func moveWindowPosition(
        _ box: AXElementBox,
        toAXOrigin origin: CGPoint
    ) {
        let pid = pidForBox(box)
        if pid != 0 {
            bumpAnimationToken(for: pid)
        }
        if box.isSelfProcess {
            let winNum = box.selfWindowNumber
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    Self.cancelSelfResizeAnimationMainActor()
                    Self.moveSelfWindowOriginMainActor(windowNumber: winNum, toAXOrigin: origin)
                }
            } else {
                Task { @MainActor in
                    Self.cancelSelfResizeAnimationMainActor()
                    Self.moveSelfWindowOriginMainActor(windowNumber: winNum, toAXOrigin: origin)
                }
            }
            return
        }
        axQueue.async {
            Self.applyTimeout(to: box.element)
            Self.setPositionAX(origin, on: box.element)
        }
    }

    func resizeWindowSize(
        _ box: AXElementBox,
        toAXSize size: CGSize,
        animationSpeed: WindowAnimationSpeed = .off
    ) {
        let pid = pidForBox(box)
        let token = pid != 0 ? bumpAnimationToken(for: pid) : 0
        if box.isSelfProcess {
            let winNum = box.selfWindowNumber
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    Self.resizeSelfWindowSizeMainActor(windowNumber: winNum, toAXSize: size, animationSpeed: animationSpeed)
                }
            } else {
                Task { @MainActor in
                    Self.resizeSelfWindowSizeMainActor(windowNumber: winNum, toAXSize: size, animationSpeed: animationSpeed)
                }
            }
            return
        }
        let duration = animationSpeed.unsnapResizeDuration
        guard animationSpeed.isAnimated, duration > 0 else {
            axQueue.async {
                Self.applyTimeout(to: box.element)
                _ = Self.setSizeAX(size, on: box.element)
            }
            return
        }

        animationQueue.async { [weak self] in
            guard let self, self.isAnimationTokenActive(token, for: pid) else { return }
            let element = box.element
            Self.applyTimeout(to: element)

            guard let startFrame = Self.copyFrameAX(of: element) else {
                if self.isAnimationTokenActive(token, for: pid) {
                    _ = Self.setSizeAX(size, on: element)
                }
                return
            }

            let startSize = startFrame.size
            let delta = max(abs(startSize.width - size.width), abs(startSize.height - size.height))
            guard delta > 3 else { return }

            let startTime = CACurrentMediaTime()
            let frameBudget: TimeInterval = 1.0 / 60.0
            var lastAppliedSize = CGSize(width: round(startSize.width), height: round(startSize.height))

            while true {
                guard self.isAnimationTokenActive(token, for: pid) else { return }
                let now = CACurrentMediaTime()
                let progress = CGFloat(min(1.0, max(0.0, (now - startTime) / duration)))
                if progress >= 1.0 {
                    break
                }

                let stepSize = SnapGeometry.interpolatedSize(from: startSize, to: size, progress: progress)
                if stepSize != lastAppliedSize {
                    let ipcStart = CACurrentMediaTime()
                    _ = Self.setSizeAX(stepSize, on: element)
                    let ipcElapsed = CACurrentMediaTime() - ipcStart
                    lastAppliedSize = stepSize
                    if ipcElapsed >= 0.085 {
                        break
                    }
                }

                let stepDuration = CACurrentMediaTime() - now
                let sleepTime = frameBudget - stepDuration
                if sleepTime > 0.002 {
                    Thread.sleep(forTimeInterval: min(sleepTime, 0.016))
                }
            }

            guard self.isAnimationTokenActive(token, for: pid) else { return }
            _ = Self.setSizeAX(size, on: element)
        }
    }

    func inspectFocusedStandardWindow(
        ignoredBundleIDs: Set<String>,
        completion: @escaping @MainActor (FocusedWindowLookupResult) -> Void
    ) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == selfPID {
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            if Self.isBundleIgnored(bundleID, ignoredBundleIDs: ignoredBundleIDs) {
                Task { @MainActor in completion(.ignored) }
                return
            }
            Task { @MainActor in
                let selfWins = Self.standardSelfWindowsMainActor()
                let keyNum = NSApp.keyWindow?.windowNumber ?? NSApp.mainWindow?.windowNumber
                if let win = (keyNum.flatMap { num in selfWins.first(where: { $0.windowNumber == num }) }) ?? selfWins.first(where: { !$0.isFullscreen && !$0.isMinimized }) {
                    if win.isFullscreen {
                        completion(.fullscreen(appName: win.appName))
                    } else {
                        completion(.window(win))
                    }
                } else if selfWins.contains(where: \.isFullscreen) {
                    completion(.fullscreen(appName: "Toolbox"))
                } else {
                    completion(.none)
                }
            }
            return
        }

        axQueue.async { [weak self] in
            let result = self?.focusedStandardWindowSync(ignoredBundleIDs: ignoredBundleIDs) ?? .none
            Task { @MainActor in
                completion(result)
            }
        }
    }

    func inspectAllVisibleStandardWindows(
        ignoredBundleIDs: Set<String>,
        completion: @escaping @MainActor ([DiscoveredAXWindow]) -> Void
    ) {
        axQueue.async { [weak self] in
            let windows = self?.allVisibleStandardWindowsSync(ignoredBundleIDs: ignoredBundleIDs) ?? []
            Task { @MainActor in
                completion(windows)
            }
        }
    }

    func windowsForApps(
        pids: [pid_t],
        completion: @escaping @MainActor ([pid_t: [DiscoveredAXWindow]]) -> Void
    ) {
        let uniquePIDs = Array(Set(pids))
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let includeSelf = uniquePIDs.contains(selfPID)
        let foreignPIDs = uniquePIDs.filter { $0 != selfPID }

        if foreignPIDs.isEmpty {
            Task { @MainActor in
                var result: [pid_t: [DiscoveredAXWindow]] = [:]
                if includeSelf {
                    result[selfPID] = Self.standardSelfWindowsMainActor()
                }
                completion(result)
            }
            return
        }

        axQueue.async { [weak self] in
            guard let self else {
                Task { @MainActor in completion([:]) }
                return
            }
            let cgEntries = Self.onScreenLayerZeroWindows()
            var cgByPID: [pid_t: [CGWindowLayerZeroEntry]] = [:]
            for entry in cgEntries {
                cgByPID[entry.ownerPID, default: []].append(entry)
            }

            var remoteResult: [pid_t: [DiscoveredAXWindow]] = [:]
            for pid in foreignPIDs {
                let axWindows = self.windowsForAppSync(pid: pid)
                remoteResult[pid] = Self.enrichWindows(axWindows, withCGEntries: cgByPID[pid] ?? [])
            }

            Task { @MainActor in
                var combined = remoteResult
                if includeSelf {
                    combined[selfPID] = Self.standardSelfWindowsMainActor()
                }
                completion(combined)
            }
        }
    }

    func unminimizeAndFetchWindowsForApps(
        pids: [pid_t],
        unminimize: Bool,
        completion: @escaping @MainActor (_ unminimizedElements: [AXElementBox], _ windowsByPID: [pid_t: [DiscoveredAXWindow]]) -> Void
    ) {
        let uniquePIDs = Array(Set(pids))
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let includeSelf = uniquePIDs.contains(selfPID)
        let foreignPIDs = uniquePIDs.filter { $0 != selfPID }

        axQueue.async { [weak self] in
            guard let self else {
                Task { @MainActor in completion([], [:]) }
                return
            }
            var unminimized: [AXElementBox] = []
            var remoteResult: [pid_t: [DiscoveredAXWindow]] = [:]

            for pid in foreignPIDs {
                var windows = self.windowsForAppSync(pid: pid)
                if unminimize {
                    var didUnminimize = false
                    for win in windows where win.isMinimized {
                        Self.applyTimeout(to: win.elementBox.element)
                        if AXUIElementSetAttributeValue(
                            win.elementBox.element,
                            kAXMinimizedAttribute as CFString,
                            kCFBooleanFalse
                        ) == .success {
                            unminimized.append(win.elementBox)
                            didUnminimize = true
                        }
                    }
                    if didUnminimize {
                        windows = self.windowsForAppSync(pid: pid)
                    }
                }
                remoteResult[pid] = windows
            }

            let cgEntries = Self.onScreenLayerZeroWindows()
            var cgByPID: [pid_t: [CGWindowLayerZeroEntry]] = [:]
            for entry in cgEntries {
                cgByPID[entry.ownerPID, default: []].append(entry)
            }
            for pid in foreignPIDs {
                if let wins = remoteResult[pid] {
                    remoteResult[pid] = Self.enrichWindows(wins, withCGEntries: cgByPID[pid] ?? [])
                }
            }

            Task { @MainActor in
                var combined = remoteResult
                if includeSelf {
                    combined[selfPID] = Self.standardSelfWindowsMainActor()
                }
                completion(unminimized, combined)
            }
        }
    }

    func minimizeElements(
        _ boxes: [AXElementBox],
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard !boxes.isEmpty else {
            if let completion {
                Task { @MainActor in completion() }
            }
            return
        }
        let remoteBoxes = boxes.filter { !$0.isSelfProcess }
        let selfWinNumbers = boxes.filter(\.isSelfProcess).compactMap(\.selfWindowNumber)

        axQueue.async {
            for box in remoteBoxes {
                Self.applyTimeout(to: box.element)
                _ = AXUIElementSetAttributeValue(box.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
            Task { @MainActor in
                for num in selfWinNumbers {
                    if let win = NSApp.window(withWindowNumber: num), !(win is NSPanel) {
                        win.miniaturize(nil)
                    }
                }
                completion?()
            }
        }
    }

    private static func enrichWindows(
        _ axWindows: [DiscoveredAXWindow],
        withCGEntries cgEntries: [CGWindowLayerZeroEntry]
    ) -> [DiscoveredAXWindow] {
        guard !cgEntries.isEmpty else { return axWindows }
        var usedWinNums: Set<Int> = []
        return axWindows.map { win in
            let available = cgEntries.filter { !usedWinNums.contains($0.windowNumber) }
            guard let matchedCG = bestMatchingCGEntry(for: win, among: available) else {
                return win
            }
            usedWinNums.insert(matchedCG.windowNumber)
            return DiscoveredAXWindow(
                pid: win.pid,
                windowNumber: win.windowNumber ?? matchedCG.windowNumber,
                bundleIdentifier: win.bundleIdentifier,
                appName: win.appName,
                title: win.title.isEmpty ? matchedCG.title : win.title,
                frameAX: win.frameAX,
                isFullscreen: win.isFullscreen,
                isMinimized: win.isMinimized,
                elementBox: win.elementBox,
                minSize: win.minSize
            )
        }
    }

    func inspectRunningAppWindows(
        excludingPIDs: Set<pid_t>,
        excludingWindowNumbers: Set<Int>,
        ignoredBundleIDs: Set<String>,
        completion: @escaping @MainActor ([AppCardCandidate], [String: DiscoveredAXWindow]) -> Void
    ) {
        axQueue.async { [weak self] in
            guard let self else {
                Task { @MainActor in completion([], [:]) }
                return
            }
            let (candidates, windowsByID) = self.runningAppWindowsSync(
                excludingPIDs: excludingPIDs,
                excludingWindowNumbers: excludingWindowNumbers,
                ignoredBundleIDs: ignoredBundleIDs
            )
            Task { @MainActor in
                completion(candidates, windowsByID)
            }
        }
    }

    func resolveAndActivateWindow(
        forCandidate candidate: AppCardCandidate,
        preResolvedWindow: DiscoveredAXWindow?,
        completion: @escaping @MainActor (DiscoveredAXWindow?) -> Void
    ) {
        axQueue.async { [weak self] in
            guard let self else {
                Task { @MainActor in completion(nil) }
                return
            }
            let resolved = self.resolveAndActivateWindowSync(
                forCandidate: candidate,
                preResolvedWindow: preResolvedWindow
            )
            Task { @MainActor in
                if let app = NSRunningApplication(processIdentifier: candidate.pid), !app.isTerminated {
                    if NSApp.isActive {
                        NSApp.yieldActivation(to: app)
                    }
                    _ = app.activate()
                }
                completion(resolved)
            }
        }
    }

    func snapWindow(
        _ window: DiscoveredAXWindow,
        toAXFrame targetFrame: CGRect,
        usableAXRect: CGRect,
        sourceDisplayFrameAX: CGRect?,
        targetDisplayFrameAX: CGRect?,
        animationSpeed: WindowAnimationSpeed = .off,
        completion: @escaping @MainActor (WindowSnapExecutionResult?) -> Void
    ) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if window.pid == selfPID || window.elementBox.isSelfProcess {
            let winNum = window.windowNumber ?? window.elementBox.selfWindowNumber
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    let res = Self.applySelfWindowFrameMainActor(
                        windowNumber: winNum,
                        targetFrameAX: targetFrame,
                        usableAXRect: usableAXRect,
                        animationSpeed: animationSpeed
                    )
                    completion(res)
                }
            } else {
                Task { @MainActor in
                    let res = Self.applySelfWindowFrameMainActor(
                        windowNumber: winNum,
                        targetFrameAX: targetFrame,
                        usableAXRect: usableAXRect,
                        animationSpeed: animationSpeed
                    )
                    completion(res)
                }
            }
            return
        }

        let pid = window.pid != 0 ? window.pid : pidForBox(window.elementBox)
        let token = bumpAnimationToken(for: pid)

        let duration = animationSpeed.snapDuration
        guard animationSpeed.isAnimated, duration > 0 else {
            axQueue.async { [weak self] in
                guard let self, self.isAnimationTokenActive(token, for: pid) else {
                    Task { @MainActor in completion(nil) }
                    return
                }
                let result = Self.applyFrameSequenceSync(
                    to: window.elementBox.element,
                    currentFrameAX: Self.copyFrameAX(of: window.elementBox.element) ?? window.frameAX,
                    targetFrameAX: targetFrame,
                    usableAXRect: usableAXRect,
                    sourceDisplayFrameAX: sourceDisplayFrameAX,
                    targetDisplayFrameAX: targetDisplayFrameAX
                )
                Task { @MainActor in
                    completion(result)
                }
            }
            return
        }

        animationQueue.async { [weak self] in
            guard let self, self.isAnimationTokenActive(token, for: pid) else {
                Task { @MainActor in completion(nil) }
                return
            }
            let element = window.elementBox.element
            Self.applyTimeout(to: element)
            let startFrame = Self.copyFrameAX(of: element) ?? window.frameAX

            let delta = max(
                abs(startFrame.minX - targetFrame.minX),
                abs(startFrame.minY - targetFrame.minY),
                abs(startFrame.width - targetFrame.width),
                abs(startFrame.height - targetFrame.height)
            )
            let isShrinking = targetFrame.width < startFrame.width - 1.0
                || targetFrame.height < startFrame.height - 1.0

            if delta > 3 {
                let startTime = CACurrentMediaTime()
                let frameBudget: TimeInterval = 1.0 / 60.0
                var lastAppliedRect = CGRect(
                    x: round(startFrame.minX),
                    y: round(startFrame.minY),
                    width: round(startFrame.width),
                    height: round(startFrame.height)
                )

                while true {
                    guard self.isAnimationTokenActive(token, for: pid) else {
                        Task { @MainActor in completion(nil) }
                        return
                    }
                    let now = CACurrentMediaTime()
                    let progress = CGFloat(min(1.0, max(0.0, (now - startTime) / duration)))
                    if progress >= 1.0 {
                        break
                    }

                    let stepRect = SnapGeometry.interpolatedRect(from: startFrame, to: targetFrame, progress: progress)
                    if stepRect != lastAppliedRect {
                        let ipcStart = CACurrentMediaTime()
                        if isShrinking {
                            _ = Self.setSizeAX(stepRect.size, on: element)
                            _ = Self.setPositionAX(stepRect.origin, on: element)
                        } else {
                            _ = Self.setPositionAX(stepRect.origin, on: element)
                            _ = Self.setSizeAX(stepRect.size, on: element)
                        }
                        let ipcElapsed = CACurrentMediaTime() - ipcStart
                        lastAppliedRect = stepRect
                        if ipcElapsed >= 0.085 {
                            break
                        }
                    }

                    let stepDuration = CACurrentMediaTime() - now
                    let sleepTime = frameBudget - stepDuration
                    if sleepTime > 0.002 {
                        Thread.sleep(forTimeInterval: min(sleepTime, 0.016))
                    }
                }
            }

            guard self.isAnimationTokenActive(token, for: pid) else {
                Task { @MainActor in completion(nil) }
                return
            }
            let currentAfterAnim = Self.copyFrameAX(of: element) ?? startFrame
            let result = Self.applyFrameSequenceSync(
                to: element,
                currentFrameAX: currentAfterAnim,
                targetFrameAX: targetFrame,
                usableAXRect: usableAXRect,
                sourceDisplayFrameAX: sourceDisplayFrameAX,
                targetDisplayFrameAX: targetDisplayFrameAX
            )
            Task { @MainActor in
                completion(result)
            }
        }
    }

    func restoreUndoBatch(
        _ batch: WindowSnapUndoBatch,
        displays: [ConnectedDisplay],
        overrideElements: [String: AXElementBox] = [:],
        completion: @escaping @MainActor (Int) -> Void
    ) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfItems = batch.items.filter { $0.pid == selfPID }
        let remoteItems = batch.items.filter { $0.pid != selfPID }

        axQueue.async { [weak self] in
            var remoteRestored = 0
            if let self {
                for item in remoteItems {
                    guard let targetElement = self.resolveElement(for: item, overrideElements: overrideElements) else {
                        continue
                    }
                    let targetCenter = CGPoint(x: item.initialFrameAX.midX, y: item.initialFrameAX.midY)
                    let targetDisplay = displays.first { $0.frameAX.contains(targetCenter) }
                        ?? displays.first(where: \.isMain)
                        ?? displays.first
                    let usableAX = targetDisplay?.usableAX ?? item.initialFrameAX
                    let currentFrame = Self.copyFrameAX(of: targetElement) ?? item.afterFrameAX
                    let sourceDisplay = displays.first {
                        $0.frameAX.contains(CGPoint(x: currentFrame.midX, y: currentFrame.midY))
                    }
                    if Self.applyFrameSequenceSync(
                        to: targetElement,
                        currentFrameAX: currentFrame,
                        targetFrameAX: item.initialFrameAX,
                        usableAXRect: usableAX,
                        sourceDisplayFrameAX: sourceDisplay?.frameAX,
                        targetDisplayFrameAX: targetDisplay?.frameAX
                    ) != nil {
                        remoteRestored += 1
                    }
                }
                self.removeCachedElements(for: batch.items.map(\.id))
            }

            let countFromRemote = remoteRestored
            Task { @MainActor in
                var selfRestored = 0
                for item in selfItems {
                    let targetCenter = CGPoint(x: item.initialFrameAX.midX, y: item.initialFrameAX.midY)
                    let targetDisplay = displays.first { $0.frameAX.contains(targetCenter) }
                        ?? displays.first(where: \.isMain)
                        ?? displays.first
                    let usableAX = targetDisplay?.usableAX ?? item.initialFrameAX
                    if Self.applySelfWindowFrameMainActor(
                        windowNumber: item.windowNumber,
                        targetFrameAX: item.initialFrameAX,
                        usableAXRect: usableAX
                    ) != nil {
                        selfRestored += 1
                    }
                }
                completion(countFromRemote + selfRestored)
            }
        }
    }

    // MARK: - Synchronous Serial Queue Implementation

    private func resolveElement(for item: WindowSnapUndoItem, overrideElements: [String: AXElementBox] = [:]) -> AXUIElement? {
        if item.pid == ProcessInfo.processInfo.processIdentifier {
            return nil
        }
        if let overrideBox = overrideElements[item.id], !overrideBox.isSelfProcess {
            if Self.copyFrameAX(of: overrideBox.element) != nil {
                return overrideBox.element
            }
        }
        if let cached = cachedElement(forUndoItemID: item.id), !cached.isSelfProcess {
            if Self.copyFrameAX(of: cached.element) != nil {
                return cached.element
            }
        }
        let windows = windowsForAppSync(pid: item.pid)
        if let byFrame = windows.first(where: { win in
            abs(win.frameAX.minX - item.afterFrameAX.minX) <= 24
                && abs(win.frameAX.minY - item.afterFrameAX.minY) <= 24
                && abs(win.frameAX.width - item.afterFrameAX.width) <= 24
                && abs(win.frameAX.height - item.afterFrameAX.height) <= 24
        }) {
            return byFrame.elementBox.element
        }
        if !item.windowTitle.isEmpty,
           let byTitle = windows.first(where: { $0.title == item.windowTitle }) {
            return byTitle.elementBox.element
        }
        return windows.first?.elementBox.element
    }

    static func onScreenLayerZeroWindows() -> [CGWindowLayerZeroEntry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var entries: [CGWindowLayerZeroEntry] = []
        for dict in rawList {
            guard ((dict[kCGWindowLayer as String] as? Int) ?? -1) == 0,
                  ((dict[kCGWindowAlpha as String] as? Double) ?? 0) > 0,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 80, bounds.height >= 60,
                  let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t,
                  let windowNum = dict[kCGWindowNumber as String] as? Int else {
                continue
            }
            let title = (dict[kCGWindowName as String] as? String) ?? ""
            entries.append(CGWindowLayerZeroEntry(
                windowNumber: windowNum,
                ownerPID: ownerPID,
                boundsAX: bounds,
                title: title
            ))
        }
        return entries
    }

    func topmostStandardWindowSync(
        atAXPoint point: CGPoint,
        ignoredBundleIDs: Set<String>
    ) -> DiscoveredAXWindow? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let cgEntries = Self.onScreenLayerZeroWindows()

        for entry in cgEntries where entry.boundsAX.contains(point) {
            if entry.ownerPID == selfPID {
                // Self-process windows must be inspected via NSApp on @MainActor, never AXUIElement off main thread
                continue
            }
            guard let app = NSRunningApplication(processIdentifier: entry.ownerPID),
                  !app.isTerminated,
                  app.activationPolicy == .regular else {
                continue
            }
            let bundleID = app.bundleIdentifier ?? ""
            if Self.isBundleIgnored(bundleID, ignoredBundleIDs: ignoredBundleIDs) {
                return nil
            }

            let axWindows = windowsForAppSync(pid: entry.ownerPID, app: app)
            if let matched = Self.matchAXWindow(for: entry, among: axWindows) {
                if matched.isFullscreen || matched.isMinimized {
                    return nil
                }
                return matched
            }
        }
        return nil
    }

    func focusedStandardWindowSync(ignoredBundleIDs: Set<String>) -> FocusedWindowLookupResult {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              !frontApp.isTerminated else {
            return .none
        }
        if frontApp.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return .none
        }
        let bundleID = frontApp.bundleIdentifier ?? ""
        if Self.isBundleIgnored(bundleID, ignoredBundleIDs: ignoredBundleIDs) {
            return .ignored
        }

        let appName = frontApp.localizedName ?? bundleID
        let appAX = Self.applicationElement(for: frontApp.processIdentifier)

        var targetElement: AXUIElement?
        if let main = Self.copyElementAttribute(kAXMainWindowAttribute as CFString, from: appAX) {
            targetElement = main
        } else if let focused = Self.copyElementAttribute(kAXFocusedWindowAttribute as CFString, from: appAX) {
            targetElement = focused
        }

        if let element = targetElement {
            Self.applyTimeout(to: element)
            if Self.isFullscreenAX(element) {
                return .fullscreen(appName: appName)
            }
            if let discovered = Self.buildDiscoveredWindow(
                element: element,
                pid: frontApp.processIdentifier,
                bundleIdentifier: bundleID,
                appName: appName,
                windowNumber: nil
            ), !discovered.isMinimized {
                return .window(discovered)
            }
        }

        let windows = windowsForAppSync(pid: frontApp.processIdentifier, app: frontApp)
        if let first = windows.first(where: { !$0.isFullscreen && !$0.isMinimized }) {
            return .window(first)
        }
        if windows.contains(where: \.isFullscreen) {
            return .fullscreen(appName: appName)
        }
        return .none
    }

    func allVisibleStandardWindowsSync(ignoredBundleIDs: Set<String>) -> [DiscoveredAXWindow] {
        let cgEntries = Self.onScreenLayerZeroWindows()
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var byPID: [pid_t: [CGWindowLayerZeroEntry]] = [:]
        var pidOrder: [pid_t] = []

        for entry in cgEntries where entry.ownerPID != selfPID {
            if byPID[entry.ownerPID] == nil {
                pidOrder.append(entry.ownerPID)
            }
            byPID[entry.ownerPID, default: []].append(entry)
        }

        var result: [DiscoveredAXWindow] = []
        var seenElements: [AXUIElement] = []

        for pid in pidOrder {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated,
                  app.activationPolicy == .regular,
                  !app.isHidden else {
                continue
            }
            let bundleID = app.bundleIdentifier ?? ""
            if Self.isBundleIgnored(bundleID, ignoredBundleIDs: ignoredBundleIDs) {
                continue
            }
            let axWindows = windowsForAppSync(pid: pid, app: app)
            for cgEntry in byPID[pid] ?? [] {
                if let matched = Self.matchAXWindow(for: cgEntry, among: axWindows),
                   !matched.isFullscreen,
                   !matched.isMinimized,
                   !seenElements.contains(where: { CFEqual($0, matched.elementBox.element) }) {
                    seenElements.append(matched.elementBox.element)
                    result.append(matched)
                }
            }
        }
        return result
    }

    func runningAppWindowsSync(
        excludingPIDs: Set<pid_t>,
        excludingWindowNumbers: Set<Int>,
        ignoredBundleIDs: Set<String>
    ) -> ([AppCardCandidate], [String: DiscoveredAXWindow]) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let cgEntries = Self.onScreenLayerZeroWindows()

        var cgByPID: [pid_t: [CGWindowLayerZeroEntry]] = [:]
        var zOrderByWindowNumber: [Int: Int] = [:]
        var firstZOrderByPID: [pid_t: Int] = [:]
        for (idx, entry) in cgEntries.enumerated() {
            cgByPID[entry.ownerPID, default: []].append(entry)
            zOrderByWindowNumber[entry.windowNumber] = idx
            if firstZOrderByPID[entry.ownerPID] == nil {
                firstZOrderByPID[entry.ownerPID] = idx
            }
        }

        var rawCandidates: [AppCardCandidate] = []
        var windowsByCandidateID: [String: DiscoveredAXWindow] = [:]

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid != selfPID,
                  !excludingPIDs.contains(pid),
                  !app.isTerminated,
                  app.activationPolicy == .regular else {
                continue
            }

            let bundleID = app.bundleIdentifier ?? ""
            if Self.isBundleIgnored(bundleID, ignoredBundleIDs: ignoredBundleIDs) {
                continue
            }

            let appName = app.localizedName ?? (bundleID.isEmpty ? "PID \(pid)" : bundleID)
            let appCG = cgByPID[pid] ?? []
            var axWindows = windowsForAppSync(pid: pid, app: app).filter { !$0.isFullscreen }

            // Fallback to main/focused window if AXWindows omitted it (e.g. minimized/hidden quirks)
            if axWindows.isEmpty {
                let appAX = Self.applicationElement(for: pid)
                if let mainEl = Self.copyElementAttribute(kAXMainWindowAttribute as CFString, from: appAX)
                    ?? Self.copyElementAttribute(kAXFocusedWindowAttribute as CFString, from: appAX),
                   let discovered = Self.buildDiscoveredWindow(
                       element: mainEl,
                       pid: pid,
                       bundleIdentifier: bundleID,
                       appName: appName,
                       windowNumber: nil
                   ),
                   !discovered.isFullscreen {
                    axWindows = [discovered]
                }
            }

            var usedCGWindowNumbers: Set<Int> = []
            for win in axWindows {
                let availableCG = appCG.filter { !usedCGWindowNumbers.contains($0.windowNumber) }
                let matchedCG = Self.bestMatchingCGEntry(for: win, among: availableCG)
                if let matchedCG {
                    usedCGWindowNumbers.insert(matchedCG.windowNumber)
                }

                let resolvedWinNum = win.windowNumber ?? matchedCG?.windowNumber
                if let resolvedWinNum, excludingWindowNumbers.contains(resolvedWinNum) {
                    continue
                }

                let resolvedTitle = win.title.isEmpty ? (matchedCG?.title ?? "") : win.title
                let candidateID = AppCardCandidate.makeID(
                    pid: pid,
                    windowNumber: resolvedWinNum,
                    title: resolvedTitle,
                    frameAX: win.frameAX
                )

                let finalWin = DiscoveredAXWindow(
                    pid: win.pid,
                    windowNumber: resolvedWinNum,
                    bundleIdentifier: win.bundleIdentifier,
                    appName: win.appName,
                    title: resolvedTitle,
                    frameAX: win.frameAX,
                    isFullscreen: false,
                    isMinimized: win.isMinimized,
                    elementBox: win.elementBox,
                    minSize: win.minSize
                )
                windowsByCandidateID[candidateID] = finalWin

                let rank = resolvedWinNum.flatMap { zOrderByWindowNumber[$0] }
                    ?? firstZOrderByPID[pid]
                    ?? (appCG.isEmpty ? 10000 : 5000)

                rawCandidates.append(AppCardCandidate(
                    id: candidateID,
                    pid: pid,
                    bundleIdentifier: bundleID,
                    appName: appName,
                    windowTitle: resolvedTitle,
                    windowNumber: resolvedWinNum,
                    windowFrameAX: finalWin.frameAX,
                    isMinimized: finalWin.isMinimized,
                    zOrderRank: rank
                ))
            }

            // Include any remaining unmatched visible layer-0 windows (e.g. if AX timing skipped them)
            for cgEntry in appCG where !usedCGWindowNumbers.contains(cgEntry.windowNumber) {
                guard !excludingWindowNumbers.contains(cgEntry.windowNumber) else { continue }
                let rank = zOrderByWindowNumber[cgEntry.windowNumber] ?? 5000
                rawCandidates.append(AppCardCandidate(
                    pid: pid,
                    bundleIdentifier: bundleID,
                    appName: appName,
                    windowTitle: cgEntry.title,
                    windowNumber: cgEntry.windowNumber,
                    windowFrameAX: cgEntry.boundsAX,
                    isMinimized: false,
                    zOrderRank: rank
                ))
            }
        }

        let deduped = AppCardLayoutEngine.dedupeAndFilterCandidates(
            rawCandidates,
            excludingPIDs: excludingPIDs.union([selfPID]),
            excludingWindowNumbers: excludingWindowNumbers,
            ignoredBundleIDs: ignoredBundleIDs
        )
        return (deduped, windowsByCandidateID)
    }

    private static func bestMatchingCGEntry(
        for axWin: DiscoveredAXWindow,
        among cgEntries: [CGWindowLayerZeroEntry]
    ) -> CGWindowLayerZeroEntry? {
        if let exactBoundsAndTitle = cgEntries.first(where: { cg in
            abs(cg.boundsAX.minX - axWin.frameAX.minX) <= 10
                && abs(cg.boundsAX.minY - axWin.frameAX.minY) <= 10
                && abs(cg.boundsAX.width - axWin.frameAX.width) <= 10
                && abs(cg.boundsAX.height - axWin.frameAX.height) <= 10
                && !axWin.title.isEmpty
                && cg.title == axWin.title
        }) {
            return exactBoundsAndTitle
        }

        if let exactBounds = cgEntries.first(where: { cg in
            abs(cg.boundsAX.minX - axWin.frameAX.minX) <= 10
                && abs(cg.boundsAX.minY - axWin.frameAX.minY) <= 10
                && abs(cg.boundsAX.width - axWin.frameAX.width) <= 10
                && abs(cg.boundsAX.height - axWin.frameAX.height) <= 10
        }) {
            return exactBounds
        }

        if !axWin.title.isEmpty {
            let titleMatches = cgEntries.filter { $0.title == axWin.title }
            if let closestTitle = titleMatches.min(by: { a, b in
                let dA = hypot(a.boundsAX.midX - axWin.frameAX.midX, a.boundsAX.midY - axWin.frameAX.midY)
                let dB = hypot(b.boundsAX.midX - axWin.frameAX.midX, b.boundsAX.midY - axWin.frameAX.midY)
                return dA < dB
            }) {
                return closestTitle
            }
        }

        let sizeMatches = cgEntries.filter { cg in
            abs(cg.boundsAX.width - axWin.frameAX.width) <= 10
                && abs(cg.boundsAX.height - axWin.frameAX.height) <= 10
        }
        return sizeMatches.min { a, b in
            let dA = hypot(a.boundsAX.midX - axWin.frameAX.midX, a.boundsAX.midY - axWin.frameAX.midY)
            let dB = hypot(b.boundsAX.midX - axWin.frameAX.midX, b.boundsAX.midY - axWin.frameAX.midY)
            return dA < dB
        }
    }

    func resolveAndActivateWindowSync(
        forCandidate candidate: AppCardCandidate,
        preResolvedWindow: DiscoveredAXWindow?
    ) -> DiscoveredAXWindow? {
        let pid = candidate.pid
        guard let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated,
              app.activationPolicy == .regular else {
            return nil
        }

        if app.isHidden {
            _ = app.unhide()
            Thread.sleep(forTimeInterval: 0.06)
        }

        let appAX = Self.applicationElement(for: pid)
        var chosen: DiscoveredAXWindow?

        // 1. Reuse the exact cached AXUIElement for that card if still valid
        if let pre = preResolvedWindow,
           Self.copyFrameAX(of: pre.elementBox.element) != nil,
           !Self.isFullscreenAX(pre.elementBox.element) {
            chosen = pre
        }

        if chosen == nil {
            var windows = windowsForAppSync(pid: pid, app: app).filter { !$0.isFullscreen }
            if let winNum = candidate.windowNumber,
               let bounds = Self.layerZeroWindowBounds(windowNumber: winNum) {
                let entry = CGWindowLayerZeroEntry(
                    windowNumber: winNum,
                    ownerPID: pid,
                    boundsAX: bounds,
                    title: candidate.windowTitle
                )
                chosen = Self.matchAXWindow(for: entry, among: windows)
            }

            if chosen == nil && !candidate.windowTitle.isEmpty {
                let titleMatches = windows.filter { $0.title == candidate.windowTitle }
                chosen = titleMatches.min { a, b in
                    let dA = hypot(a.frameAX.midX - candidate.windowFrameAX.midX, a.frameAX.midY - candidate.windowFrameAX.midY)
                    let dB = hypot(b.frameAX.midX - candidate.windowFrameAX.midX, b.frameAX.midY - candidate.windowFrameAX.midY)
                    return dA < dB
                }
            }

            if chosen == nil {
                if let mainEl = Self.copyElementAttribute(kAXMainWindowAttribute as CFString, from: appAX),
                   let mainWin = Self.buildDiscoveredWindow(
                       element: mainEl,
                       pid: pid,
                       bundleIdentifier: app.bundleIdentifier ?? "",
                       appName: app.localizedName ?? "",
                       windowNumber: candidate.windowNumber
                   ),
                   !mainWin.isFullscreen {
                    chosen = mainWin
                } else {
                    chosen = windows.first(where: { !$0.isMinimized }) ?? windows.first
                }
            }

            if chosen == nil {
                Thread.sleep(forTimeInterval: 0.08)
                windows = windowsForAppSync(pid: pid, app: app).filter { !$0.isFullscreen }
                chosen = windows.first
            }
        }

        guard let win = chosen else { return nil }

        Self.applyTimeout(to: win.elementBox.element)
        if win.isMinimized {
            _ = AXUIElementSetAttributeValue(win.elementBox.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        _ = AXUIElementSetAttributeValue(win.elementBox.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(win.elementBox.element, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(appAX, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        return DiscoveredAXWindow(
            pid: win.pid,
            windowNumber: win.windowNumber ?? candidate.windowNumber,
            bundleIdentifier: win.bundleIdentifier,
            appName: win.appName,
            title: win.title.isEmpty ? candidate.windowTitle : win.title,
            frameAX: Self.copyFrameAX(of: win.elementBox.element) ?? win.frameAX,
            isFullscreen: win.isFullscreen,
            isMinimized: false,
            elementBox: win.elementBox,
            minSize: win.minSize
        )
    }

    func windowsForAppSync(pid: pid_t, app: NSRunningApplication? = nil) -> [DiscoveredAXWindow] {
        if pid == ProcessInfo.processInfo.processIdentifier && !Thread.isMainThread {
            return []
        }
        let resolvedApp = app ?? NSRunningApplication(processIdentifier: pid)
        let bundleID = resolvedApp?.bundleIdentifier ?? ""
        let appName = resolvedApp?.localizedName ?? (bundleID.isEmpty ? "PID \(pid)" : bundleID)
        let appAX = Self.applicationElement(for: pid)

        var result: [DiscoveredAXWindow] = []
        var windowsValue: AnyObject?
        if AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let axWindows = windowsValue as? [AXUIElement] {
            for element in axWindows {
                if let win = Self.buildDiscoveredWindow(
                    element: element,
                    pid: pid,
                    bundleIdentifier: bundleID,
                    appName: appName,
                    windowNumber: nil
                ) {
                    result.append(win)
                }
            }
        }

        if result.isEmpty {
            if let fallbackEl = Self.copyElementAttribute(kAXMainWindowAttribute as CFString, from: appAX)
                ?? Self.copyElementAttribute(kAXFocusedWindowAttribute as CFString, from: appAX),
               let discovered = Self.buildDiscoveredWindow(
                   element: fallbackEl,
                   pid: pid,
                   bundleIdentifier: bundleID,
                   appName: appName,
                   windowNumber: nil
               ) {
                result.append(discovered)
            }
        }
        return result
    }

    // MARK: - Clamping-Safe Frame Mutation

    @discardableResult
    static func applyFrameSequenceSync(
        to element: AXUIElement,
        currentFrameAX: CGRect,
        targetFrameAX: CGRect,
        usableAXRect: CGRect,
        sourceDisplayFrameAX: CGRect? = nil,
        targetDisplayFrameAX: CGRect? = nil
    ) -> WindowSnapExecutionResult? {
        if isUnsafeOffMainSelfElement(element) {
            return nil
        }
        applyTimeout(to: element)

        let minSize = copyMinSizeAX(of: element)
        let targetOrigin = targetFrameAX.origin
        let targetSize = targetFrameAX.size

        let isShrinking = targetSize.width < currentFrameAX.width - 1.0
            || targetSize.height < currentFrameAX.height - 1.0
        let isCrossDisplay: Bool = {
            if let src = sourceDisplayFrameAX, let dst = targetDisplayFrameAX {
                return src != dst
            }
            return abs(currentFrameAX.midX - targetFrameAX.midX) > usableAXRect.width * 0.75
        }()

        // Conservative Electron / Chromium note: do not toggle AXEnhancedUserInterface
        // from main thread or per-drag-frame; perform clean one-shot Size/Position batching.
        if isShrinking || isCrossDisplay {
            _ = setSizeAX(targetSize, on: element)
            _ = setPositionAX(targetOrigin, on: element)
            _ = setSizeAX(targetSize, on: element)
        } else {
            _ = setPositionAX(targetOrigin, on: element)
            _ = setSizeAX(targetSize, on: element)
            _ = setPositionAX(targetOrigin, on: element)
        }

        let actualAfter = copyFrameAX(of: element) ?? targetFrameAX
        var finalFrame = actualAfter
        var didClampForMinSize = false

        if actualAfter.width > targetFrameAX.width + 2.0 || actualAfter.height > targetFrameAX.height + 2.0 {
            let clamped = SnapGeometry.clampFrameForMinimumSize(
                targetFrame: targetFrameAX,
                actualSize: actualAfter.size,
                usableRect: usableAXRect
            )
            if abs(clamped.origin.x - actualAfter.origin.x) > 1.0 || abs(clamped.origin.y - actualAfter.origin.y) > 1.0 {
                _ = setPositionAX(clamped.origin, on: element)
                finalFrame = copyFrameAX(of: element) ?? clamped
                didClampForMinSize = true
            } else {
                didClampForMinSize = true
            }
        }

        return WindowSnapExecutionResult(
            appliedFrameAX: finalFrame,
            clampedForMinSize: didClampForMinSize,
            minSizeReported: minSize
        )
    }

    // MARK: - Low-Level AX Helpers

    private static func isUnsafeOffMainSelfElement(_ element: AXUIElement) -> Bool {
        guard !Thread.isMainThread else { return false }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success
            && pid == ProcessInfo.processInfo.processIdentifier
    }

    private static func isBundleIgnored(_ bundleID: String, ignoredBundleIDs: Set<String>) -> Bool {
        guard !bundleID.isEmpty else { return false }
        let lower = bundleID.lowercased()
        return ignoredBundleIDs.contains { $0.lowercased() == lower }
    }

    private static func matchAXWindow(
        for entry: CGWindowLayerZeroEntry,
        among windows: [DiscoveredAXWindow]
    ) -> DiscoveredAXWindow? {
        let wrap: (DiscoveredAXWindow) -> DiscoveredAXWindow = { win in
            DiscoveredAXWindow(
                pid: win.pid,
                windowNumber: entry.windowNumber,
                bundleIdentifier: win.bundleIdentifier,
                appName: win.appName,
                title: win.title.isEmpty ? entry.title : win.title,
                frameAX: win.frameAX,
                isFullscreen: win.isFullscreen,
                isMinimized: win.isMinimized,
                elementBox: win.elementBox,
                minSize: win.minSize
            )
        }

        if let exactBounds = windows.first(where: { win in
            abs(win.frameAX.minX - entry.boundsAX.minX) <= 10
                && abs(win.frameAX.minY - entry.boundsAX.minY) <= 10
                && abs(win.frameAX.width - entry.boundsAX.width) <= 10
                && abs(win.frameAX.height - entry.boundsAX.height) <= 10
        }) {
            return wrap(exactBounds)
        }

        let sizeMatches = windows.filter { win in
            abs(win.frameAX.width - entry.boundsAX.width) <= 10
                && abs(win.frameAX.height - entry.boundsAX.height) <= 10
        }
        if let closestByCenter = sizeMatches.min(by: { a, b in
            let distA = hypot(a.frameAX.midX - entry.boundsAX.midX, a.frameAX.midY - entry.boundsAX.midY)
            let distB = hypot(b.frameAX.midX - entry.boundsAX.midX, b.frameAX.midY - entry.boundsAX.midY)
            return distA < distB
        }) {
            return wrap(closestByCenter)
        }

        if !entry.title.isEmpty,
           let byTitle = windows.first(where: { $0.title == entry.title }) {
            return wrap(byTitle)
        }
        return windows.first.map(wrap)
    }

    static func applicationElement(for pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        applyTimeout(to: el)
        return el
    }

    private static func applyTimeout(to element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, axTimeoutSeconds)
    }

    private static func buildDiscoveredWindow(
        element: AXUIElement,
        pid: pid_t,
        bundleIdentifier: String,
        appName: String,
        windowNumber: Int?
    ) -> DiscoveredAXWindow? {
        if isUnsafeOffMainSelfElement(element) {
            return nil
        }
        applyTimeout(to: element)

        var subroleVal: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleVal)
        let subrole = subroleVal as? String
        guard subrole == (kAXStandardWindowSubrole as String)
            || subrole == (kAXDialogSubrole as String) else {
            return nil
        }

        guard let frameAX = copyFrameAX(of: element),
              frameAX.width >= 80,
              frameAX.height >= 60 else {
            return nil
        }

        var minVal: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minVal)
        let isMinimized = (minVal as? Bool) ?? false

        var titleVal: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleVal)
        let title = (titleVal as? String) ?? ""

        let rawMin = copyMinSizeAX(of: element)
        let reportedMinSize: CGSize? = (rawMin.map { $0.width > 1 || $0.height > 1 } == true) ? rawMin : nil

        return DiscoveredAXWindow(
            pid: pid,
            windowNumber: windowNumber,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            title: title,
            frameAX: frameAX,
            isFullscreen: isFullscreenAX(element),
            isMinimized: isMinimized,
            elementBox: AXElementBox(element),
            minSize: reportedMinSize
        )
    }

    static func isFullscreenAX(_ element: AXUIElement) -> Bool {
        if isUnsafeOffMainSelfElement(element) {
            return false
        }
        applyTimeout(to: element)
        var fullscreenVal: AnyObject?
        if AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &fullscreenVal) == .success,
           let flag = fullscreenVal as? Bool {
            return flag
        }
        return false
    }

    private static func copyElementAttribute(_ attr: CFString, from element: AXUIElement) -> AXUIElement? {
        if isUnsafeOffMainSelfElement(element) {
            return nil
        }
        var val: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr, &val) == .success,
              let raw = val,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return (raw as! AXUIElement)
    }

    static func copyFrameAX(of element: AXUIElement) -> CGRect? {
        if isUnsafeOffMainSelfElement(element) {
            return nil
        }
        applyTimeout(to: element)
        var posVal: AnyObject?
        var sizeVal: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeVal) == .success,
              let posRaw = posVal,
              let sizeRaw = sizeVal,
              CFGetTypeID(posRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRaw as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    static func copyMinSizeAX(of element: AXUIElement) -> CGSize? {
        if isUnsafeOffMainSelfElement(element) {
            return nil
        }
        var minVal: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXMinSize" as CFString, &minVal) == .success,
              let raw = minVal,
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        var minSize = CGSize.zero
        if AXValueGetValue(raw as! AXValue, .cgSize, &minSize) {
            return minSize
        }
        return nil
    }

    @discardableResult
    static func setPositionAX(_ point: CGPoint, on element: AXUIElement) -> Bool {
        if isUnsafeOffMainSelfElement(element) {
            return false
        }
        var p = point
        guard let axVal = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axVal) == .success
    }

    @discardableResult
    static func setSizeAX(_ size: CGSize, on element: AXUIElement) -> Bool {
        if isUnsafeOffMainSelfElement(element) {
            return false
        }
        var s = size
        guard let axVal = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axVal) == .success
    }
}
