import AppKit
import CoreGraphics
import Foundation

enum DragMoveConfirmation: Equatable, Sendable {
    case pending
    case confirmedMove
    case rejectedResizeOrSelection
}

private final class DragTapStartState: @unchecked Sendable {
    var succeeded = false
}

private final class DragEventCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingDrag: (CGPoint, CGEventFlags, TimeInterval)?
    private var dragScheduled = false
    private var epoch: UInt64 = 0

    func enqueueDrag(
        point: CGPoint,
        flags: CGEventFlags,
        timestamp: TimeInterval,
        handler: @escaping @MainActor @Sendable (CGPoint, CGEventFlags, TimeInterval) -> Void
    ) {
        lock.lock()
        pendingDrag = (point, flags, timestamp)
        let shouldSchedule = !dragScheduled
        let scheduledEpoch = epoch
        if shouldSchedule {
            dragScheduled = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let next: (CGPoint, CGEventFlags, TimeInterval)?
            if self.epoch == scheduledEpoch {
                next = self.pendingDrag
                self.pendingDrag = nil
                self.dragScheduled = false
            } else {
                next = nil
            }
            self.lock.unlock()

            guard let (pt, f, ts) = next else { return }
            MainActor.assumeIsolated {
                handler(pt, f, ts)
            }
        }
    }

    func clearPendingDrag() {
        lock.lock()
        pendingDrag = nil
        dragScheduled = false
        epoch &+= 1
        lock.unlock()
    }
}

/// Passive background `.listenOnly` CGEventTap monitoring mouse drags and modifier changes
/// for Window Snapper without ever running AX IPC inside the event tap callback.
final class WindowDragTap: @unchecked Sendable {
    private let lifecycleLock = NSLock()
    private let stateLock = NSLock()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var backgroundRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var tapExitSemaphore: DispatchSemaphore?

    var onMouseDown: (@Sendable (CGPoint, CGEventFlags, TimeInterval, CGWindowLayerZeroEntry?, Int) -> Void)?
    var onMouseDragged: (@Sendable (CGPoint, CGEventFlags, TimeInterval) -> Void)?
    var onMouseUp: (@Sendable (CGPoint, CGEventFlags, TimeInterval, Int) -> Void)?
    var onFlagsChanged: (@Sendable (CGEventFlags) -> Void)?

    deinit {
        uninstall()
    }

    @discardableResult
    func install() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        uninstallLocked()

        let readySem = DispatchSemaphore(value: 0)
        let exitSem = DispatchSemaphore(value: 0)
        let startState = DragTapStartState()

        let thread = Thread { [weak self] in
            guard let self else {
                readySem.signal()
                exitSem.signal()
                return
            }

            let mask = CGEventMask(
                (1 << CGEventType.leftMouseDown.rawValue) |
                (1 << CGEventType.leftMouseDragged.rawValue) |
                (1 << CGEventType.leftMouseUp.rawValue) |
                (1 << CGEventType.flagsChanged.rawValue)
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            guard let newTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let owner = Unmanaged<WindowDragTap>.fromOpaque(userInfo).takeUnretainedValue()
                    owner.handle(type: type, event: event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: selfPtr
            ) else {
                readySem.signal()
                exitSem.signal()
                return
            }

            let rl = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: newTap, enable: true)

            self.withLock {
                self.tap = newTap
                self.runLoopSource = source
                self.backgroundRunLoop = rl
            }

            startState.succeeded = true
            readySem.signal()
            CFRunLoopRun()
            exitSem.signal()
        }
        thread.name = "app.toolbox.window-snapping-drag-tap"
        thread.qualityOfService = .userInteractive

        withLock {
            self.tapThread = thread
            self.tapExitSemaphore = exitSem
        }
        thread.start()
        readySem.wait()

        if !startState.succeeded {
            _ = exitSem.wait(timeout: .now() + 0.5)
            withLock {
                self.tapThread = nil
                self.tapExitSemaphore = nil
            }
        }
        return startState.succeeded
    }

    func uninstall() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        uninstallLocked()
    }

    private func uninstallLocked() {
        let (currentTap, currentSource, currentRL, currentThread, exitSem) = withLock {
            let values = (tap, runLoopSource, backgroundRunLoop, tapThread, tapExitSemaphore)
            tap = nil
            runLoopSource = nil
            backgroundRunLoop = nil
            tapThread = nil
            tapExitSemaphore = nil
            return values
        }

        if let currentTap {
            CGEvent.tapEnable(tap: currentTap, enable: false)
            if let currentRL, let currentSource {
                CFRunLoopRemoveSource(currentRL, currentSource, .commonModes)
            }
            CFMachPortInvalidate(currentTap)
        }
        if let currentRL {
            CFRunLoopStop(currentRL)
        }
        if let exitSem, Thread.current !== currentThread {
            _ = exitSem.wait(timeout: .now() + 1.0)
        }
    }

    var isInstalled: Bool {
        withLock { tap != nil }
    }

    internal var runsOnDedicatedBackgroundRunLoopForTesting: Bool {
        withLock {
            guard let rl = backgroundRunLoop, let thread = tapThread else { return false }
            return !thread.isMainThread && rl !== CFRunLoopGetMain()
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if PermissionsManager.shouldRearmEventTap(for: type), let current = withLock({ tap }) {
                CGEvent.tapEnable(tap: current, enable: true)
            } else {
                Task { @MainActor in
                    PermissionsManager.shared.refresh()
                }
            }
            return
        }

        let location = event.location
        let flags = event.flags
        let now = ProcessInfo.processInfo.systemUptime
        let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))

        switch type {
        case .leftMouseDown:
            let initialEntry = AXWindowController.topmostLayerZeroEntry(atAXPoint: location)
            onMouseDown?(location, flags, now, initialEntry, clickCount)
        case .leftMouseDragged:
            onMouseDragged?(location, flags, now)
        case .leftMouseUp:
            onMouseUp?(location, flags, now, clickCount)
        case .flagsChanged:
            onFlagsChanged?(flags)
        default:
            break
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}

@MainActor
final class WindowDragMonitor {
    private struct ActiveDragSession {
        let id = UUID()
        let downPointAX: CGPoint
        var lastPointAX: CGPoint
        var lastTimestamp: TimeInterval
        var velocityX: CGFloat = 0
        var velocityY: CGFloat = 0
        var flags: CGEventFlags
        var window: DiscoveredAXWindow?
        var lookupCompleted: Bool = false
        var confirmation: DragMoveConfirmation = .pending
        var didRestorePreSnapSize: Bool = false
        var startedInTopSnapBand: Bool = false
        var hasExitedInitialTopSnapBand: Bool = false
        var lastFramePollTime: TimeInterval = 0
        var lastPendingConfirmPollTime: TimeInterval = 0
        var isFramePollInFlight: Bool = false
        var initialCGEntryAtMouseDown: CGWindowLayerZeroEntry? = nil
        var initialCGFrameAtMouseDownAX: CGRect? = nil
        var initialAXFrameAtMouseDownAX: CGRect? = nil
        var initialGrabRatioX: CGFloat = 0.5
        var preSnapOriginalFrameAX: CGRect? = nil
        var downClickCount: Int = 1
        var preDoubleClickFrameAX: CGRect? = nil
        var activeTargetZone: ResolvedZone? = nil
        var activeTargetDisplay: ConnectedDisplay? = nil
        var topPanelVisible: Bool = false
        var topPanelDisplayID: CGDirectDisplayID? = nil
        var topPanelActiveSlot: TopEdgePanelSlotKind? = nil
        var topPanelHoveredCellIndex: Int? = nil
        var topPanelPreviewZones: [ResolvedZone] = []
        var cancelledByEscape: Bool = false

        var initialReferenceFrameAX: CGRect? {
            initialCGFrameAtMouseDownAX ?? initialAXFrameAtMouseDownAX
        }
    }

    private let tap = WindowDragTap()
    private let axController: AXWindowController
    private let displayRegistry: DisplayRegistry
    private let overlayController: ZoneOverlayController
    private let dragCoalescer = DragEventCoalescer()

    private var config: WindowSnapperConfig = WindowSnapperConfig()
    private var session: ActiveDragSession?
    private var lastSingleClickSnapshot: (windowNumber: Int, pid: pid_t, frameAX: CGRect, timestamp: TimeInterval)?
    private var escKeyMonitor: Any?

    var preSnapLookup: ((DiscoveredAXWindow) -> CGRect?)?
    var onSnapCommitted: ((DiscoveredAXWindow, ResolvedZone, ConnectedDisplay, TopEdgeTemplateSnapContext?) -> Void)?
    var onUnsnapCommitted: ((DiscoveredAXWindow, CGRect, CGPoint, CGFloat) -> Void)?
    var onExternalMaximizeDetected: ((Int?, pid_t, String, CGRect, CGRect) -> Void)?
    var onExternalUnmaximizeDetected: ((Int?, pid_t, CGSize) -> Void)?
    var onMidDragResizeRequestedForTesting: ((CGSize, WindowAnimationSpeed) -> Void)?
    var onShouldIgnoreMouseDownAtAXPoint: ((CGPoint) -> Bool)?
    var onExternalMouseDownOrDragBegan: (() -> Void)?

    init(
        axController: AXWindowController,
        displayRegistry: DisplayRegistry = .shared,
        overlayController: ZoneOverlayController = .shared
    ) {
        self.axController = axController
        self.displayRegistry = displayRegistry
        self.overlayController = overlayController

        let coalescer = self.dragCoalescer
        tap.onMouseDown = { [weak self] pt, flags, ts, entry, clickCount in
            coalescer.clearPendingDrag()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleMouseDown(
                        atAXPoint: pt,
                        flags: flags,
                        timestamp: ts,
                        initialCGEntry: entry,
                        clickCount: clickCount
                    )
                }
            }
        }
        tap.onMouseDragged = { [weak self] pt, flags, ts in
            coalescer.enqueueDrag(point: pt, flags: flags, timestamp: ts) { [weak self] cPt, cFlags, cTs in
                self?.handleMouseDragged(toAXPoint: cPt, flags: cFlags, timestamp: cTs)
            }
        }
        tap.onMouseUp = { [weak self] pt, flags, ts, clickCount in
            coalescer.clearPendingDrag()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleMouseUp(atAXPoint: pt, flags: flags, timestamp: ts, clickCount: clickCount)
                }
            }
        }
        tap.onFlagsChanged = { [weak self] flags in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleFlagsChanged(flags)
                }
            }
        }
    }

    var isTapInstalled: Bool {
        tap.isInstalled
    }

    func updateConfig(_ newConfig: WindowSnapperConfig) {
        self.config = newConfig
    }

    func start() {
        guard PermissionsManager.isProcessTrusted() else {
            stop()
            return
        }
        if !tap.isInstalled {
            _ = tap.install()
        }
    }

    func stop() {
        dragCoalescer.clearPendingDrag()
        removeEscMonitor()
        session = nil
        lastSingleClickSnapshot = nil
        tap.uninstall()
        overlayController.hideDragOverlays()
    }

    // MARK: - Pure Static Evaluation Helpers (Unit Tested)

    static func evaluateConfirmedWindowDrag(
        initialFrameAX: CGRect,
        currentFrameAX: CGRect,
        positionTolerance: CGFloat = 2.5,
        sizeTolerance: CGFloat = 2.0,
        pointerDistance: CGFloat = 0
    ) -> DragMoveConfirmation {
        if abs(currentFrameAX.width - initialFrameAX.width) > sizeTolerance
            || abs(currentFrameAX.height - initialFrameAX.height) > sizeTolerance {
            return .rejectedResizeOrSelection
        }
        let delta = hypot(
            currentFrameAX.minX - initialFrameAX.minX,
            currentFrameAX.minY - initialFrameAX.minY
        )
        if delta >= positionTolerance {
            return .confirmedMove
        }
        return .pending
    }

    static func shouldSuppressSharedEdgeSnap(
        pointerAX: CGPoint,
        velocityX: CGFloat,
        velocityY: CGFloat,
        displayFrameAX: CGRect,
        allDisplayFramesAX: [CGRect],
        edgeThreshold: CGFloat = 36,
        speedThreshold: CGFloat = 650
    ) -> Bool {
        let seamTolerance: CGFloat = 12
        for other in allDisplayFramesAX where other != displayFrameAX {
            let verticalOverlap = pointerAX.y >= other.minY - 24 && pointerAX.y <= other.maxY + 24
            let horizontalOverlap = pointerAX.x >= other.minX - 24 && pointerAX.x <= other.maxX + 24

            // Crossing left into adjacent monitor
            if pointerAX.x - displayFrameAX.minX <= edgeThreshold,
               verticalOverlap,
               abs(other.maxX - displayFrameAX.minX) <= seamTolerance,
               velocityX < -speedThreshold {
                return true
            }
            // Crossing right into adjacent monitor
            if displayFrameAX.maxX - pointerAX.x <= edgeThreshold,
               verticalOverlap,
               abs(other.minX - displayFrameAX.maxX) <= seamTolerance,
               velocityX > speedThreshold {
                return true
            }
            // Crossing top into adjacent monitor
            if pointerAX.y - displayFrameAX.minY <= edgeThreshold,
               horizontalOverlap,
               abs(other.maxY - displayFrameAX.minY) <= seamTolerance,
               velocityY < -speedThreshold {
                return true
            }
            // Crossing bottom into adjacent monitor
            if displayFrameAX.maxY - pointerAX.y <= edgeThreshold,
               horizontalOverlap,
               abs(other.minY - displayFrameAX.maxY) <= seamTolerance,
               velocityY > speedThreshold {
                return true
            }
        }
        return false
    }

    static func shouldTriggerMidDragSizeRestore(
        currentFrameAX: CGRect,
        preSnapFrameAX: CGRect,
        dragDistance: CGFloat,
        tolerance: CGFloat = 4
    ) -> Bool {
        guard dragDistance >= 3 else { return false }
        let alreadyAtPreSnapSize = abs(currentFrameAX.width - preSnapFrameAX.width) <= tolerance
            && abs(currentFrameAX.height - preSnapFrameAX.height) <= tolerance
        return !alreadyAtPreSnapSize
    }

    static func shouldReleaseTopPullAwaySuppression(
        downPointAX: CGPoint,
        pointerAX: CGPoint,
        velocityY: CGFloat,
        usableMinY: CGFloat,
        topTriggerBand: CGFloat
    ) -> Bool {
        if pointerAX.y > usableMinY + topTriggerBand + 8 {
            return true
        }
        let pushedUpward = pointerAX.y < downPointAX.y - 3
            || (downPointAX.y <= usableMinY + 4 && pointerAX.y <= downPointAX.y - 1)
        return velocityY <= 20 && pushedUpward
    }

    static func isFrameMaximizedLike(
        _ frameAX: CGRect,
        in usableAX: CGRect,
        tolerance: CGFloat = 24
    ) -> Bool {
        abs(frameAX.width - usableAX.width) <= tolerance
            && abs(frameAX.height - usableAX.height) <= tolerance
    }

    static func restoredDragOrigin(
        pointerAX: CGPoint,
        initialFrameAX: CGRect,
        preSnapSize: CGSize,
        horizontalGrabRatio: CGFloat,
        downPointAX: CGPoint? = nil
    ) -> CGPoint {
        let clampedRatio = min(max(horizontalGrabRatio, 0.08), 0.92)
        let referenceY = downPointAX?.y ?? pointerAX.y
        let grabOffsetY = min(max(referenceY - initialFrameAX.minY, 8), 28)
        return CGPoint(
            x: round(pointerAX.x - preSnapSize.width * clampedRatio),
            y: round(pointerAX.y - grabOffsetY)
        )
    }

    static func detachedReleaseOriginIfNeeded(
        liveFrameAX: CGRect,
        releasePointAX: CGPoint,
        horizontalGrabRatio: CGFloat,
        usableAXRect: CGRect,
        marginTolerance: CGFloat = 16
    ) -> CGPoint? {
        if releasePointAX.x >= liveFrameAX.minX - marginTolerance
            && releasePointAX.x <= liveFrameAX.maxX + marginTolerance {
            return nil
        }
        let clampedRatio = min(max(horizontalGrabRatio, 0.08), 0.92)
        let desiredX = round(releasePointAX.x - liveFrameAX.width * clampedRatio)
        let maxOriginX = max(usableAXRect.minX, usableAXRect.maxX - liveFrameAX.width)
        let clampedX = min(max(desiredX, usableAXRect.minX), maxOriginX)

        let maxOriginY = max(usableAXRect.minY, usableAXRect.maxY - liveFrameAX.height)
        let clampedY = min(max(round(liveFrameAX.minY), usableAXRect.minY), maxOriginY)
        return CGPoint(x: clampedX, y: clampedY)
    }

    private func liveModifierFlags(fallback: CGEventFlags) -> CGEventFlags {
        let live = CGEventSource.flagsState(.combinedSessionState)
        let modifierMask: UInt64 = CGEventFlags.maskShift.rawValue
            | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskCommand.rawValue
        let mergedRaw = (fallback.rawValue & ~modifierMask) | (live.rawValue & modifierMask)
        return CGEventFlags(rawValue: mergedRaw)
    }

    // MARK: - Event Handling

    private func handleMouseDown(
        atAXPoint point: CGPoint,
        flags: CGEventFlags,
        timestamp: TimeInterval,
        initialCGEntry: CGWindowLayerZeroEntry? = nil,
        clickCount: Int = 1
    ) {
        removeEscMonitor()
        if onShouldIgnoreMouseDownAtAXPoint?(point) == true {
            session = nil
            return
        }
        onExternalMouseDownOrDragBegan?()
        guard config.enabled,
              config.drag.enabled,
              !overlayController.isEditingOnScreen,
              !overlayController.isLivePreviewActive,
              !overlayController.isDryRunPreviewActive else {
            session = nil
            return
        }

        let effectiveFlags = liveModifierFlags(fallback: flags)
        let resolvedInitialEntry = initialCGEntry ?? AXWindowController.topmostLayerZeroEntry(atAXPoint: point)

        var preDoubleClickFrame: CGRect? = nil
        if clickCount <= 1 {
            if let entry = resolvedInitialEntry {
                lastSingleClickSnapshot = (
                    windowNumber: entry.windowNumber,
                    pid: entry.ownerPID,
                    frameAX: entry.boundsAX,
                    timestamp: timestamp
                )
            } else {
                lastSingleClickSnapshot = nil
            }
        } else if let snap = lastSingleClickSnapshot,
                  timestamp - snap.timestamp <= 1.2,
                  (resolvedInitialEntry == nil
                      || resolvedInitialEntry?.windowNumber == snap.windowNumber
                      || resolvedInitialEntry?.ownerPID == snap.pid) {
            preDoubleClickFrame = snap.frameAX
        }

        let grabRatio: CGFloat = {
            guard let bounds = resolvedInitialEntry?.boundsAX, bounds.width > 1 else { return 0.5 }
            return min(max((point.x - bounds.minX) / bounds.width, 0.08), 0.92)
        }()

        var newSession = ActiveDragSession(
            downPointAX: point,
            lastPointAX: point,
            lastTimestamp: timestamp,
            flags: effectiveFlags,
            initialCGEntryAtMouseDown: resolvedInitialEntry,
            initialCGFrameAtMouseDownAX: resolvedInitialEntry?.boundsAX,
            initialGrabRatioX: grabRatio,
            downClickCount: clickCount,
            preDoubleClickFrameAX: preDoubleClickFrame
        )
        let ignored = Set(config.ignoredBundleIDs)
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if resolvedInitialEntry?.ownerPID == selfPID {
            newSession.lookupCompleted = true
            if let found = AXWindowController.inspectSelfWindowMainActor(
                windowNumber: resolvedInitialEntry?.windowNumber,
                atAXPoint: point,
                ignoredBundleIDs: ignored
            ) {
                populateResolvedWindow(&newSession, found: found)
            } else {
                newSession.confirmation = .rejectedResizeOrSelection
            }
            session = newSession
            return
        }

        let sessionID = newSession.id
        session = newSession

        axController.inspectWindow(
            forCGEntry: resolvedInitialEntry,
            fallbackAXPoint: point,
            ignoredBundleIDs: ignored
        ) { [weak self] found in
            guard let self, var current = self.session, current.id == sessionID else { return }
            current.lookupCompleted = true
            guard let found else {
                current.confirmation = .rejectedResizeOrSelection
                self.session = current
                return
            }

            self.populateResolvedWindow(&current, found: found)

            if current.confirmation == .confirmedMove, let lookupWindow = current.window {
                self.installEscMonitor()
                self.attemptMidDragSizeRestoreIfNeeded(
                    &current,
                    window: lookupWindow,
                    pointerAX: current.lastPointAX,
                    timestamp: current.lastTimestamp
                )
                self.evaluateDragTarget(for: &current, window: lookupWindow, pointerAX: current.lastPointAX, flags: current.flags)
            }
            self.session = current
        }
    }

    private func populateResolvedWindow(_ current: inout ActiveDragSession, found: DiscoveredAXWindow) {
        current.initialAXFrameAtMouseDownAX = current.initialCGFrameAtMouseDownAX ?? found.frameAX
        if current.initialCGFrameAtMouseDownAX == nil, let winNum = found.windowNumber {
            current.initialCGFrameAtMouseDownAX = AXWindowController.layerZeroWindowBounds(windowNumber: winNum)
        }

        let refFrame = current.initialReferenceFrameAX ?? found.frameAX
        current.initialGrabRatioX = min(
            max((current.downPointAX.x - refFrame.minX) / max(1, refFrame.width), 0.08),
            0.92
        )

        let lookupWindow = DiscoveredAXWindow(
            pid: found.pid,
            windowNumber: found.windowNumber ?? current.initialCGEntryAtMouseDown?.windowNumber,
            bundleIdentifier: found.bundleIdentifier,
            appName: found.appName,
            title: found.title,
            frameAX: found.frameAX,
            isFullscreen: found.isFullscreen,
            isMinimized: found.isMinimized,
            elementBox: found.elementBox
        )
        current.window = lookupWindow
        current.preSnapOriginalFrameAX = preSnapLookup?(lookupWindow) ?? preSnapLookup?(found)

        if let downDisplay = displayRegistry.display(containingAXPoint: current.downPointAX) {
            let topTriggerBand = max(2, CGFloat(config.topEdgePanel.triggerDistancePoints))
            current.startedInTopSnapBand = current.downPointAX.y
                <= downDisplay.usableAX.minY + topTriggerBand + 4
        }

        if current.confirmation == .pending {
            let pointerDist = hypot(
                current.lastPointAX.x - current.downPointAX.x,
                current.lastPointAX.y - current.downPointAX.y
            )
            if let cgInit = current.initialCGFrameAtMouseDownAX {
                let axCheck = Self.evaluateConfirmedWindowDrag(
                    initialFrameAX: cgInit,
                    currentFrameAX: found.frameAX,
                    positionTolerance: 2.0,
                    pointerDistance: pointerDist
                )
                if axCheck == .confirmedMove || axCheck == .rejectedResizeOrSelection {
                    current.confirmation = axCheck
                } else if let winNum = lookupWindow.windowNumber ?? current.initialCGEntryAtMouseDown?.windowNumber,
                          let cgNow = AXWindowController.layerZeroWindowBounds(windowNumber: winNum) {
                    current.confirmation = Self.evaluateConfirmedWindowDrag(
                        initialFrameAX: cgInit,
                        currentFrameAX: cgNow,
                        positionTolerance: 2.0,
                        pointerDistance: pointerDist
                    )
                }
            }
        }
    }

    @discardableResult
    private func tryConfirmPendingDragSynchronously(
        _ current: inout ActiveDragSession,
        window draggedWindow: DiscoveredAXWindow,
        pointerAX: CGPoint,
        flags: CGEventFlags,
        timestamp: TimeInterval
    ) -> DragMoveConfirmation? {
        let pointerDist = hypot(
            pointerAX.x - current.downPointAX.x,
            pointerAX.y - current.downPointAX.y
        )
        if draggedWindow.elementBox.isSelfProcess {
            guard let liveSelfFrame = AXWindowController.readSelfWindowFrameMainActor(windowNumber: draggedWindow.elementBox.selfWindowNumber) else {
                return nil
            }
            let baseAX = current.initialAXFrameAtMouseDownAX ?? draggedWindow.frameAX
            let check = Self.evaluateConfirmedWindowDrag(
                initialFrameAX: baseAX,
                currentFrameAX: liveSelfFrame,
                positionTolerance: 2.0,
                pointerDistance: pointerDist
            )
            current.confirmation = check
            if check == .confirmedMove {
                installEscMonitor()
                attemptMidDragSizeRestoreIfNeeded(&current, window: draggedWindow, pointerAX: pointerAX, timestamp: timestamp)
                evaluateDragTarget(for: &current, window: draggedWindow, pointerAX: pointerAX, flags: flags)
            } else if check == .rejectedResizeOrSelection {
                overlayController.hideDragOverlays()
            }
            return check
        }

        if let cgInit = current.initialCGFrameAtMouseDownAX,
           let winNum = draggedWindow.windowNumber ?? current.initialCGEntryAtMouseDown?.windowNumber,
           let cgLive = AXWindowController.layerZeroWindowBounds(windowNumber: winNum) {
            let check = Self.evaluateConfirmedWindowDrag(
                initialFrameAX: cgInit,
                currentFrameAX: cgLive,
                positionTolerance: 2.0,
                pointerDistance: pointerDist
            )
            current.confirmation = check
            if check == .confirmedMove {
                installEscMonitor()
                attemptMidDragSizeRestoreIfNeeded(&current, window: draggedWindow, pointerAX: pointerAX, timestamp: timestamp)
                evaluateDragTarget(for: &current, window: draggedWindow, pointerAX: pointerAX, flags: flags)
            } else if check == .rejectedResizeOrSelection {
                overlayController.hideDragOverlays()
            }
            return check
        }

        return nil
    }

    private func handleMouseDragged(toAXPoint point: CGPoint, flags: CGEventFlags, timestamp: TimeInterval) {
        guard var current = session else { return }
        if current.cancelledByEscape || current.confirmation == .rejectedResizeOrSelection {
            return
        }

        let effectiveFlags = liveModifierFlags(fallback: flags)
        let dt = max(0.004, timestamp - current.lastTimestamp)
        let instVX = (point.x - current.lastPointAX.x) / CGFloat(dt)
        let instVY = (point.y - current.lastPointAX.y) / CGFloat(dt)
        current.velocityX = current.velocityX * 0.4 + instVX * 0.6
        current.velocityY = current.velocityY * 0.4 + instVY * 0.6
        current.lastPointAX = point
        current.lastTimestamp = timestamp
        current.flags = effectiveFlags
        session = current

        guard current.lookupCompleted, let draggedWindow = current.window else {
            return
        }

        if current.confirmation == .pending {
            let pointerMoved = hypot(point.x - current.downPointAX.x, point.y - current.downPointAX.y)
            guard pointerMoved >= 2 else { return }

            let pollInterval: TimeInterval = pointerMoved >= 24 ? 0.040 : 0.016
            if current.lastPendingConfirmPollTime == 0 || (timestamp - current.lastPendingConfirmPollTime) >= pollInterval {
                current.lastPendingConfirmPollTime = timestamp
                if tryConfirmPendingDragSynchronously(
                    &current,
                    window: draggedWindow,
                    pointerAX: point,
                    flags: effectiveFlags,
                    timestamp: timestamp
                ) != nil {
                    session = current
                    return
                }
            } else if current.initialCGFrameAtMouseDownAX != nil || draggedWindow.elementBox.isSelfProcess {
                session = current
                return
            }

            let sessionID = current.id
            if !current.isFramePollInFlight && (timestamp - current.lastFramePollTime) >= 0.012 {
                current.isFramePollInFlight = true
                current.lastFramePollTime = timestamp
                session = current

                axController.readWindowFrame(draggedWindow.elementBox) { [weak self] liveFrame in
                    guard let self, var s = self.session, s.id == sessionID else { return }
                    s.isFramePollInFlight = false
                    guard let liveFrame else {
                        s.confirmation = .rejectedResizeOrSelection
                        self.session = s
                        return
                    }
                    let baseInitial = s.initialAXFrameAtMouseDownAX ?? draggedWindow.frameAX
                    let livePointerMoved = hypot(s.lastPointAX.x - s.downPointAX.x, s.lastPointAX.y - s.downPointAX.y)
                    let check = Self.evaluateConfirmedWindowDrag(
                        initialFrameAX: baseInitial,
                        currentFrameAX: liveFrame,
                        positionTolerance: 2.0,
                        pointerDistance: livePointerMoved
                    )
                    s.confirmation = check
                    if check == .confirmedMove {
                        self.installEscMonitor()
                        self.attemptMidDragSizeRestoreIfNeeded(
                            &s,
                            window: draggedWindow,
                            pointerAX: s.lastPointAX,
                            timestamp: s.lastTimestamp
                        )
                        self.evaluateDragTarget(for: &s, window: draggedWindow, pointerAX: s.lastPointAX, flags: s.flags)
                    } else if check == .rejectedResizeOrSelection {
                        self.overlayController.hideDragOverlays()
                    }
                    self.session = s
                }
            }
            return
        }

        attemptMidDragSizeRestoreIfNeeded(&current, window: draggedWindow, pointerAX: point, timestamp: timestamp)
        evaluateDragTarget(for: &current, window: draggedWindow, pointerAX: point, flags: effectiveFlags)
        session = current
    }

    private func attemptMidDragSizeRestoreIfNeeded(
        _ current: inout ActiveDragSession,
        window: DiscoveredAXWindow,
        pointerAX: CGPoint,
        timestamp: TimeInterval
    ) {
        guard !current.didRestorePreSnapSize else {
            return
        }
        let dragDist = hypot(pointerAX.x - current.downPointAX.x, pointerAX.y - current.downPointAX.y)
        guard dragDist >= 3 else { return }

        guard let preSnapRect = current.preSnapOriginalFrameAX ?? preSnapLookup?(window) else {
            return
        }
        current.preSnapOriginalFrameAX = preSnapRect
        current.didRestorePreSnapSize = true

        let refFrame = current.initialReferenceFrameAX ?? window.frameAX
        guard Self.shouldTriggerMidDragSizeRestore(
            currentFrameAX: refFrame,
            preSnapFrameAX: preSnapRect,
            dragDistance: dragDist
        ) else {
            return
        }

        onMidDragResizeRequestedForTesting?(preSnapRect.size, config.windowAnimationSpeed)
        axController.resizeWindowSize(
            window.elementBox,
            toAXSize: preSnapRect.size,
            animationSpeed: config.windowAnimationSpeed
        )
    }

    internal func handleExternalZoomTransition(
        windowNumber: Int?,
        pid: pid_t,
        bundleIdentifier: String,
        preClickFrameAX: CGRect,
        postClickFrameAX: CGRect,
        displayUsableAX: CGRect
    ) {
        let wasMaximized = Self.isFrameMaximizedLike(preClickFrameAX, in: displayUsableAX)
        let isNowMaximized = Self.isFrameMaximizedLike(postClickFrameAX, in: displayUsableAX)
        if !wasMaximized && isNowMaximized {
            onExternalMaximizeDetected?(windowNumber, pid, bundleIdentifier, preClickFrameAX, postClickFrameAX)
        } else if wasMaximized && !isNowMaximized {
            onExternalUnmaximizeDetected?(windowNumber, pid, postClickFrameAX.size)
        }
    }

    private func scheduleExternalZoomDetectionIfNeeded(
        for finished: ActiveDragSession,
        atAXPoint point: CGPoint
    ) {
        guard let winNum = finished.window?.windowNumber ?? finished.initialCGEntryAtMouseDown?.windowNumber,
              let pid = finished.window?.pid ?? finished.initialCGEntryAtMouseDown?.ownerPID,
              let preClickFrame = finished.preDoubleClickFrameAX ?? finished.initialReferenceFrameAX else {
            return
        }
        displayRegistry.refresh(gaps: config.gaps)
        guard let display = displayRegistry.display(containingAXPoint: point)
            ?? displayRegistry.display(containingAXRect: preClickFrame) else {
            return
        }
        let usableAX = display.usableAX
        let bundleID = finished.window?.bundleIdentifier
            ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            ?? ""

        let evaluateNow: () -> Bool = { [weak self] in
            guard let self,
                  let postFrame = AXWindowController.layerZeroWindowBounds(windowNumber: winNum) else {
                return false
            }
            let sizeChanged = abs(postFrame.width - preClickFrame.width) > 12
                || abs(postFrame.height - preClickFrame.height) > 12
            guard sizeChanged else { return false }
            self.handleExternalZoomTransition(
                windowNumber: winNum,
                pid: pid,
                bundleIdentifier: bundleID,
                preClickFrameAX: preClickFrame,
                postClickFrameAX: postFrame,
                displayUsableAX: usableAX
            )
            return true
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard self != nil else { return }
            if evaluateNow() { return }
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard self != nil else { return }
            _ = evaluateNow()
        }
    }

    private func handleFlagsChanged(_ flags: CGEventFlags) {
        guard var current = session,
              !current.cancelledByEscape,
              current.confirmation != .rejectedResizeOrSelection else {
            return
        }
        let effectiveFlags = liveModifierFlags(fallback: flags)
        current.flags = effectiveFlags

        guard current.lookupCompleted, let draggedWindow = current.window else {
            session = current
            return
        }

        if current.confirmation == .pending {
            _ = tryConfirmPendingDragSynchronously(
                &current,
                window: draggedWindow,
                pointerAX: current.lastPointAX,
                flags: effectiveFlags,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
            session = current
            return
        }

        evaluateDragTarget(for: &current, window: draggedWindow, pointerAX: current.lastPointAX, flags: effectiveFlags)
        session = current
    }

    private func handleMouseUp(
        atAXPoint point: CGPoint,
        flags: CGEventFlags,
        timestamp: TimeInterval,
        clickCount: Int = 1
    ) {
        removeEscMonitor()
        guard var finished = session else {
            overlayController.hideDragOverlays()
            return
        }
        session = nil

        if finished.confirmation == .pending,
           finished.lookupCompleted,
           let draggedWindow = finished.window {
            let effectiveFlags = liveModifierFlags(fallback: flags)
            finished.lastPointAX = point
            finished.lastTimestamp = timestamp
            finished.flags = effectiveFlags
            _ = tryConfirmPendingDragSynchronously(
                &finished,
                window: draggedWindow,
                pointerAX: point,
                flags: effectiveFlags,
                timestamp: timestamp
            )
        }

        overlayController.hideDragOverlays()

        if max(clickCount, finished.downClickCount) >= 2,
           !finished.cancelledByEscape,
           finished.confirmation != .confirmedMove {
            scheduleExternalZoomDetectionIfNeeded(for: finished, atAXPoint: point)
        }

        guard !finished.cancelledByEscape,
              finished.confirmation == .confirmedMove,
              let draggedWindow = finished.window else {
            return
        }

        if let targetZone = finished.activeTargetZone,
           let targetDisplay = finished.activeTargetDisplay {
            let committedWindow = DiscoveredAXWindow(
                pid: draggedWindow.pid,
                windowNumber: draggedWindow.windowNumber ?? finished.initialCGEntryAtMouseDown?.windowNumber,
                bundleIdentifier: draggedWindow.bundleIdentifier,
                appName: draggedWindow.appName,
                title: draggedWindow.title,
                frameAX: finished.preSnapOriginalFrameAX ?? finished.initialReferenceFrameAX ?? draggedWindow.frameAX,
                isFullscreen: draggedWindow.isFullscreen,
                isMinimized: draggedWindow.isMinimized,
                elementBox: draggedWindow.elementBox,
                minSize: draggedWindow.minSize
            )
            let templateContext: TopEdgeTemplateSnapContext? = {
                guard case .template(let preset) = finished.topPanelActiveSlot,
                      !finished.topPanelPreviewZones.isEmpty,
                      finished.topPanelPreviewZones.contains(where: { $0.id == targetZone.id }) else {
                    return nil
                }
                return TopEdgeTemplateSnapContext(
                    template: preset,
                    allCells: finished.topPanelPreviewZones,
                    snappedCellID: targetZone.id
                )
            }()
            onSnapCommitted?(committedWindow, targetZone, targetDisplay, templateContext)
            return
        }

        if finished.activeTargetZone == nil,
           let preSnapRect = finished.preSnapOriginalFrameAX ?? preSnapLookup?(draggedWindow) {
            onUnsnapCommitted?(draggedWindow, preSnapRect, point, finished.initialGrabRatioX)
        }
    }

    private func evaluateDragTarget(
        for current: inout ActiveDragSession,
        window: DiscoveredAXWindow,
        pointerAX: CGPoint,
        flags: CGEventFlags
    ) {
        guard let display = displayRegistry.display(containingAXPoint: pointerAX) else {
            current.activeTargetZone = nil
            current.activeTargetDisplay = nil
            current.topPanelVisible = false
            current.topPanelDisplayID = nil
            current.topPanelActiveSlot = nil
            current.topPanelHoveredCellIndex = nil
            current.topPanelPreviewZones = []
            overlayController.hideDragOverlays()
            return
        }

        let layout = DisplayRegistry.layout(for: display.signature, in: config.displayLayouts)

        // 1. Modifier-hold full-grid overlay (default Shift) + automatic seam spanning
        if config.drag.gridModifier.matches(cgFlags: flags) {
            let zones = SnapGeometry.resolveZones(
                layout: layout,
                usableAXRect: display.usableAX,
                primaryScreenHeight: display.primaryScreenHeight,
                gaps: config.gaps
            )
            let hit = SnapGeometry.hitTestGridOrSpan(
                pointerAX: pointerAX,
                usableAXRect: display.usableAX,
                primaryScreenHeight: display.primaryScreenHeight,
                layout: layout,
                gaps: config.gaps
            )
            current.activeTargetZone = hit?.zone
            current.activeTargetDisplay = display
            current.topPanelVisible = false
            current.topPanelDisplayID = nil
            current.topPanelActiveSlot = nil
            current.topPanelHoveredCellIndex = nil
            current.topPanelPreviewZones = []

            let minWarning = hit.flatMap {
                SnapGeometry.evaluateMinSizeFit(
                    targetFrameAX: $0.zone.frameInAX,
                    minSize: window.minSize,
                    usableAXRect: display.usableAX
                )
            }
            overlayController.showFullGridDragOverlay(
                on: display,
                zones: zones,
                highlightedZone: hit?.zone,
                isSpanning: hit?.isSpanning ?? false,
                style: config.overlayStyle,
                minSizeWarning: minWarning
            )
            return
        }

        if current.topPanelDisplayID != display.displayID {
            current.topPanelVisible = false
            current.topPanelDisplayID = nil
            current.topPanelActiveSlot = nil
            current.topPanelHoveredCellIndex = nil
            current.topPanelPreviewZones = []
        }

        let topTriggerBand = max(2, CGFloat(config.topEdgePanel.triggerDistancePoints))
        if current.startedInTopSnapBand && !current.hasExitedInitialTopSnapBand {
            if Self.shouldReleaseTopPullAwaySuppression(
                downPointAX: current.downPointAX,
                pointerAX: pointerAX,
                velocityY: current.velocityY,
                usableMinY: display.usableAX.minY,
                topTriggerBand: topTriggerBand
            ) {
                current.hasExitedInitialTopSnapBand = true
            }
        }
        let suppressTopPullAway = current.startedInTopSnapBand && !current.hasExitedInitialTopSnapBand

        // 2. Top Edge Panel — Direct Mini-Cell Selection
        if !suppressTopPullAway, config.topEdgePanel.enabled {
            let visibleSlots = TopEdgePanelGeometry.visibleSlots(for: config.topEdgePanel)
            let pickerLayout = TopEdgePanelGeometry.pickerLayout(for: display, slots: visibleSlots)

            let resolveZonesForSlot: (TopEdgePanelSlotKind) -> [ResolvedZone] = { slot in
                switch slot {
                case .template(let preset):
                    return SnapGeometry.resolveTemplateZones(
                        preset: preset,
                        usableAXRect: display.usableAX,
                        primaryScreenHeight: display.primaryScreenHeight,
                        gaps: self.config.gaps,
                        layoutOverride: layout
                    )
                case .maximize:
                    if let maxZone = SnapGeometry.resolveUniversalOrBuiltInZone(
                        id: "universal:maximize",
                        usableAXRect: display.usableAX,
                        primaryScreenHeight: display.primaryScreenHeight,
                        gaps: self.config.gaps,
                        layoutOverride: layout
                    ) {
                        return [maxZone]
                    }
                    return []
                }
            }

            let inTrigger = TopEdgePanelGeometry.isPointerInTriggerZone(
                pointerAX: pointerAX,
                display: display,
                layout: pickerLayout,
                triggerDistancePoints: CGFloat(config.topEdgePanel.triggerDistancePoints),
                cornerBandPoints: CGFloat(config.drag.cornerBandPoints),
                triggerWidth: config.topEdgePanel.triggerWidth
            )
            let inKeepAlive = current.topPanelVisible && TopEdgePanelGeometry.isPointerInPickerKeepAliveZone(
                pointerAX: pointerAX,
                display: display,
                layout: pickerLayout
            )
            let movingAwayFromTop = !current.topPanelVisible && current.velocityY > 80
            let shouldOpenFromTrigger = inTrigger && !movingAwayFromTop

            if shouldOpenFromTrigger || inKeepAlive {
                current.topPanelVisible = true
                current.topPanelDisplayID = display.displayID
                current.activeTargetDisplay = display

                if let hit = TopEdgePanelGeometry.hitTestPickerCell(pointerAX: pointerAX, in: pickerLayout) {
                    let zones = (current.topPanelActiveSlot == hit.slotKind && !current.topPanelPreviewZones.isEmpty)
                        ? current.topPanelPreviewZones
                        : resolveZonesForSlot(hit.slotKind)
                    let target = (hit.cellIndex >= 0 && hit.cellIndex < zones.count)
                        ? zones[hit.cellIndex]
                        : zones.first
                    current.topPanelActiveSlot = hit.slotKind
                    current.topPanelHoveredCellIndex = hit.cellIndex
                    current.topPanelPreviewZones = zones
                    current.activeTargetZone = target
                } else {
                    current.topPanelActiveSlot = nil
                    current.topPanelHoveredCellIndex = nil
                    current.topPanelPreviewZones = []
                    current.activeTargetZone = nil
                }

                let minWarning = current.activeTargetZone.flatMap {
                    SnapGeometry.evaluateMinSizeFit(
                        targetFrameAX: $0.frameInAX,
                        minSize: window.minSize,
                        usableAXRect: display.usableAX
                    )
                }
                overlayController.showTopEdgeTemplatePicker(
                    on: display,
                    layout: pickerLayout,
                    activeSlot: current.topPanelActiveSlot,
                    hoveredCellIndex: current.topPanelHoveredCellIndex,
                    previewZones: current.topPanelPreviewZones,
                    highlightedZone: current.activeTargetZone,
                    style: config.overlayStyle,
                    minSizeWarning: minWarning
                )
                return
            }
        }

        current.topPanelVisible = false
        current.topPanelDisplayID = nil
        current.topPanelActiveSlot = nil
        current.topPanelHoveredCellIndex = nil
        current.topPanelPreviewZones = []

        // 3. Edge & Corner magnetic pull (with inter-display pass-through suppression)
        let allFrames = displayRegistry.connectedDisplays.map(\.frameAX)
        let suppressed = Self.shouldSuppressSharedEdgeSnap(
            pointerAX: pointerAX,
            velocityX: current.velocityX,
            velocityY: current.velocityY,
            displayFrameAX: display.frameAX,
            allDisplayFramesAX: allFrames
        )

        if !suppressed,
           let edgeHit = SnapGeometry.hitTestEdgeOrCorner(
               pointerAX: pointerAX,
               screenFrameAX: display.frameAX,
               usableAXRect: display.usableAX,
               primaryScreenHeight: display.primaryScreenHeight,
               dragConfig: config.drag,
               gaps: config.gaps,
               layout: layout
           ),
           !(suppressTopPullAway && edgeHit.id == "universal:maximize") {
            current.activeTargetZone = edgeHit
            current.activeTargetDisplay = display
            let minWarning = SnapGeometry.evaluateMinSizeFit(
                targetFrameAX: edgeHit.frameInAX,
                minSize: window.minSize,
                usableAXRect: display.usableAX
            )
            overlayController.showSingleZoneDragPreview(
                on: display,
                zone: edgeHit,
                style: config.overlayStyle,
                minSizeWarning: minWarning
            )
        } else {
            current.activeTargetZone = nil
            current.activeTargetDisplay = nil
            overlayController.hideDragOverlays()
        }
    }

    private func installEscMonitor() {
        guard escKeyMonitor == nil else { return }
        escKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                guard let self, var current = self.session else { return }
                current.cancelledByEscape = true
                current.activeTargetZone = nil
                current.activeTargetDisplay = nil
                self.session = current
                self.overlayController.hideDragOverlays()
            }
        }
    }

    private func removeEscMonitor() {
        if let escKeyMonitor {
            NSEvent.removeMonitor(escKeyMonitor)
            self.escKeyMonitor = nil
        }
    }

    // MARK: - Testing Support

    internal func beginSimulatedDragSessionForTesting(
        downPointAX: CGPoint,
        window: DiscoveredAXWindow,
        initialFrameAX: CGRect,
        flags: CGEventFlags = [],
        timestamp: TimeInterval = 1.0
    ) {
        var s = ActiveDragSession(
            downPointAX: downPointAX,
            lastPointAX: downPointAX,
            lastTimestamp: timestamp,
            flags: flags,
            initialCGFrameAtMouseDownAX: initialFrameAX,
            initialAXFrameAtMouseDownAX: initialFrameAX
        )
        s.lookupCompleted = true
        populateResolvedWindow(&s, found: window)
        session = s
    }

    @discardableResult
    internal func advanceSimulatedDragForTesting(
        pointerAX: CGPoint,
        liveWindowFrameAX: CGRect,
        flags: CGEventFlags = [],
        timestamp: TimeInterval
    ) -> (confirmation: DragMoveConfirmation, topPanelVisible: Bool) {
        guard var current = session, let draggedWindow = current.window else {
            return (.rejectedResizeOrSelection, false)
        }
        if current.cancelledByEscape || current.confirmation == .rejectedResizeOrSelection {
            return (current.confirmation, current.topPanelVisible)
        }
        let dt = max(0.004, timestamp - current.lastTimestamp)
        let instVX = (pointerAX.x - current.lastPointAX.x) / CGFloat(dt)
        let instVY = (pointerAX.y - current.lastPointAX.y) / CGFloat(dt)
        current.velocityX = current.velocityX * 0.4 + instVX * 0.6
        current.velocityY = current.velocityY * 0.4 + instVY * 0.6
        current.lastPointAX = pointerAX
        current.lastTimestamp = timestamp
        current.flags = flags

        if current.confirmation == .pending {
            let pointerMoved = hypot(pointerAX.x - current.downPointAX.x, pointerAX.y - current.downPointAX.y)
            let baseAX = current.initialReferenceFrameAX ?? draggedWindow.frameAX
            let check = Self.evaluateConfirmedWindowDrag(
                initialFrameAX: baseAX,
                currentFrameAX: liveWindowFrameAX,
                positionTolerance: 2.0,
                pointerDistance: pointerMoved
            )
            current.confirmation = check
            if check == .confirmedMove {
                attemptMidDragSizeRestoreIfNeeded(&current, window: draggedWindow, pointerAX: pointerAX, timestamp: timestamp)
                evaluateDragTarget(for: &current, window: draggedWindow, pointerAX: pointerAX, flags: flags)
            } else if check == .rejectedResizeOrSelection {
                overlayController.hideDragOverlays()
            }
        } else if current.confirmation == .confirmedMove {
            attemptMidDragSizeRestoreIfNeeded(&current, window: draggedWindow, pointerAX: pointerAX, timestamp: timestamp)
            evaluateDragTarget(for: &current, window: draggedWindow, pointerAX: pointerAX, flags: flags)
        }
        session = current
        return (current.confirmation, current.topPanelVisible)
    }

    internal func finishSimulatedDragForTesting(
        releasePointAX: CGPoint,
        flags: CGEventFlags = [],
        timestamp: TimeInterval
    ) {
        handleMouseUp(atAXPoint: releasePointAX, flags: flags, timestamp: timestamp, clickCount: 1)
    }
}
