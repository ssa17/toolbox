import AppKit
import SwiftUI

/// Pure geometry model for drag-reordering a vertical list of variable-height rows.
/// Keeps slot math, nearest-slot target selection, neighbor displacement, and
/// release settle offsets exact across any `Hashable` item identifier.
struct VerticalDragReorderLayout<ID: Hashable>: Equatable {
    struct Item: Equatable {
        let id: ID
        let height: CGFloat
        let restingTop: CGFloat
        var restingCenter: CGFloat { restingTop + height / 2 }
    }

    let items: [Item]
    let sourceIndex: Int
    let spacing: CGFloat
    let topInset: CGFloat

    var draggedItem: Item { items[sourceIndex] }

    /// Distance from the dragged row's center up to the top of the list block.
    var distanceAboveDraggedCenter: CGFloat {
        draggedItem.restingCenter - topInset
    }

    /// Distance from the dragged row's center down to the bottom of the last row.
    var distanceBelowDraggedCenter: CGFloat {
        (items.last.map { $0.restingTop + $0.height } ?? draggedItem.restingCenter) - draggedItem.restingCenter
    }

    /// Bottom edge of the reorderable block in block-local top-down coordinates.
    var blockBottomY: CGFloat {
        (items.last.map { $0.restingTop + $0.height } ?? topInset) + topInset
    }

    init?(
        itemIDs: [ID],
        heights: [ID: CGFloat],
        draggedID: ID,
        spacing: CGFloat = 5,
        topInset: CGFloat = 8,
        fallbackHeight: CGFloat = 54
    ) {
        guard itemIDs.count > 1,
              let sourceIdx = itemIDs.firstIndex(of: draggedID) else {
            return nil
        }
        var built: [Item] = []
        built.reserveCapacity(itemIDs.count)
        var y = topInset
        for id in itemIDs {
            let h = max(24, heights[id] ?? fallbackHeight)
            built.append(Item(id: id, height: h, restingTop: y))
            y += h + spacing
        }
        self.items = built
        self.sourceIndex = sourceIdx
        self.spacing = spacing
        self.topInset = topInset
    }

    /// Top Y of the dragged item when committed at `slot` (`0 ..< items.count`)
    /// among the remaining items.
    func slotTop(for slot: Int) -> CGFloat {
        let clamped = min(max(0, slot), items.count - 1)
        var y = topInset
        var remainingPlaced = 0
        for item in items where item.id != draggedItem.id {
            if remainingPlaced == clamped {
                return y
            }
            y += item.height + spacing
            remainingPlaced += 1
        }
        return y
    }

    func clampedOffset(for rawDeltaY: CGFloat, overshoot: CGFloat = 10) -> CGFloat {
        let minOffset = slotTop(for: 0) - draggedItem.restingTop - overshoot
        let maxOffset = slotTop(for: items.count - 1) - draggedItem.restingTop + overshoot
        return min(max(rawDeltaY, minOffset), maxOffset)
    }

    func targetIndex(for rawDeltaY: CGFloat) -> Int {
        let draggedCenter = draggedItem.restingCenter + rawDeltaY
        let halfHeight = draggedItem.height / 2
        var bestSlot = sourceIndex
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for slot in items.indices {
            let candidateCenter = slotTop(for: slot) + halfHeight
            let distance = abs(draggedCenter - candidateCenter)
            if distance < bestDistance {
                bestDistance = distance
                bestSlot = slot
            }
        }
        return bestSlot
    }

    func restingShift(forRowAt index: Int, targetIndex: Int) -> CGFloat {
        guard index != sourceIndex else { return 0 }
        let stride = draggedItem.height + spacing
        if targetIndex > sourceIndex, index > sourceIndex, index <= targetIndex {
            return -stride
        }
        if targetIndex < sourceIndex, index < sourceIndex, index >= targetIndex {
            return stride
        }
        return 0
    }

    func moveInstruction(for targetIndex: Int) -> (targetID: ID, insertAfter: Bool)? {
        let clamped = min(max(0, targetIndex), items.count - 1)
        guard clamped != sourceIndex else { return nil }
        return (items[clamped].id, clamped > sourceIndex)
    }

    func residualSettleOffset(releaseOffsetY: CGFloat, committedTargetIndex: Int) -> CGFloat {
        (draggedItem.restingTop + releaseOffsetY) - slotTop(for: committedTargetIndex)
    }
}

typealias ClipboardPinnedDragLayout = VerticalDragReorderLayout<UUID>

extension VerticalDragReorderLayout where ID == UUID {
    var pinnedBlockBottomY: CGFloat { blockBottomY }

    init?(
        pinnedIDs: [UUID],
        heights: [UUID: CGFloat],
        draggedID: UUID,
        spacing: CGFloat = 5,
        topInset: CGFloat = 8,
        fallbackHeight: CGFloat = 54
    ) {
        self.init(
            itemIDs: pinnedIDs,
            heights: heights,
            draggedID: draggedID,
            spacing: spacing,
            topInset: topInset,
            fallbackHeight: fallbackHeight
        )
    }
}

/// Auto-scroll range relative to the dragged row's initial vertical center,
/// keeping scroll clamping accurate regardless of where the list sits inside its scroll view.
struct ReorderDragAutoScrollBounds: Equatable {
    let distanceAboveCenter: CGFloat
    let distanceBelowCenter: CGFloat

    init(distanceAboveCenter: CGFloat, distanceBelowCenter: CGFloat) {
        self.distanceAboveCenter = distanceAboveCenter
        self.distanceBelowCenter = distanceBelowCenter
    }

    init<ID: Hashable>(layout: VerticalDragReorderLayout<ID>) {
        self.distanceAboveCenter = layout.distanceAboveDraggedCenter
        self.distanceBelowCenter = layout.distanceBelowDraggedCenter
    }
}

/// Shared `@MainActor` controller managing an active in-view drag-to-reorder session,
/// neighbor displacement, haptics, and zero-jump release settle animation.
@MainActor
final class VerticalDragReorderState<ID: Hashable>: ObservableObject {
    @Published var layout: VerticalDragReorderLayout<ID>?
    @Published var dragOffsetY: CGFloat = 0
    @Published var targetIndex: Int?
    @Published var settlingID: ID?
    @Published var settlingOffsetY: CGFloat = 0
    @Published var rowHeights: [ID: CGFloat] = [:]
    /// False briefly around a drag commit so the re-indexed array snaps in place
    /// without double-animating alongside the shifting rows.
    @Published var animatedReorder = true

    private var activeDragCancelHandler: (() -> Void)?
    private var settleCleanupTask: Task<Void, Never>?
    private var reorderAnimRestoreTask: Task<Void, Never>?

    var isDragging: Bool { layout != nil }
    var draggedID: ID? { layout?.draggedItem.id }

    func restingShift(for id: ID) -> CGFloat {
        guard let layout,
              draggedID != id,
              let index = layout.items.firstIndex(where: { $0.id == id }) else {
            return 0
        }
        return layout.restingShift(forRowAt: index, targetIndex: targetIndex ?? layout.sourceIndex)
    }

    @discardableResult
    func beginDrag(
        id: ID,
        itemIDs: [ID],
        spacing: CGFloat,
        topInset: CGFloat,
        fallbackHeight: CGFloat = 54,
        onExternalCancel: (() -> Void)? = nil
    ) -> ReorderDragAutoScrollBounds? {
        if let existingCancel = activeDragCancelHandler {
            activeDragCancelHandler = nil
            existingCancel()
        }
        settleCleanupTask?.cancel()
        settleCleanupTask = nil
        reorderAnimRestoreTask?.cancel()
        reorderAnimRestoreTask = nil
        animatedReorder = true

        guard let newLayout = VerticalDragReorderLayout(
            itemIDs: itemIDs,
            heights: rowHeights,
            draggedID: id,
            spacing: spacing,
            topInset: topInset,
            fallbackHeight: fallbackHeight
        ) else {
            return nil
        }

        settlingID = nil
        settlingOffsetY = 0
        layout = newLayout
        targetIndex = newLayout.sourceIndex
        dragOffsetY = 0
        activeDragCancelHandler = onExternalCancel
        return ReorderDragAutoScrollBounds(layout: newLayout)
    }

    func updateDrag(rawDeltaY: CGFloat) {
        guard let layout else { return }
        dragOffsetY = layout.clampedOffset(for: rawDeltaY)
        let nextTarget = layout.targetIndex(for: rawDeltaY)
        if nextTarget != targetIndex {
            targetIndex = nextTarget
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func finishDrag(onMove: (_ draggedID: ID, _ targetID: ID, _ insertAfter: Bool) -> Void) {
        guard let layout else { return }
        let draggedItemID = layout.draggedItem.id
        let committedTarget = targetIndex ?? layout.sourceIndex
        let releaseOffset = dragOffsetY
        let residual = layout.residualSettleOffset(
            releaseOffsetY: releaseOffset,
            committedTargetIndex: committedTarget
        )

        activeDragCancelHandler = nil
        self.layout = nil
        targetIndex = nil
        dragOffsetY = 0

        if let move = layout.moveInstruction(for: committedTarget) {
            animatedReorder = false
            onMove(draggedItemID, move.targetID, move.insertAfter)
            reorderAnimRestoreTask?.cancel()
            reorderAnimRestoreTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                self?.animatedReorder = true
            }
        }

        if abs(residual) > 0.5 {
            animateSettle(id: draggedItemID, fromOffset: residual)
        }
    }

    func cancelActiveDrag() {
        let handler = activeDragCancelHandler
        activeDragCancelHandler = nil
        handler?()

        guard let layout else { return }
        let draggedItemID = layout.draggedItem.id
        let releaseOffset = dragOffsetY
        self.layout = nil
        targetIndex = nil
        dragOffsetY = 0

        if abs(releaseOffset) > 0.5 {
            animateSettle(id: draggedItemID, fromOffset: releaseOffset)
        }
    }

    func clearDragState() {
        let handler = activeDragCancelHandler
        activeDragCancelHandler = nil
        handler?()

        settleCleanupTask?.cancel()
        settleCleanupTask = nil
        reorderAnimRestoreTask?.cancel()
        reorderAnimRestoreTask = nil
        layout = nil
        targetIndex = nil
        dragOffsetY = 0
        settlingID = nil
        settlingOffsetY = 0
        animatedReorder = true
    }

    private func animateSettle(id: ID, fromOffset: CGFloat) {
        settleCleanupTask?.cancel()
        settlingID = id
        settlingOffsetY = fromOffset

        DispatchQueue.main.async { [weak self] in
            guard let self, self.settlingID == id, self.layout == nil else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                self.settlingOffsetY = 0
            }
        }

        settleCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, let self, self.settlingID == id else { return }
            self.settlingID = nil
            self.settlingOffsetY = 0
        }
    }
}

/// AppKit mouse-tracking surface for dragging rows cleanly inside both
/// `.nonactivatingPanel` popovers and standard windows without triggering an OS
/// `NSDraggingSession`, moving the window, or breaking clicks / context menus.
struct ReorderRowDragSurface: NSViewRepresentable {
    let canDrag: Bool
    let dragThreshold: CGFloat
    let hoverCursor: NSCursor
    let toolTip: String?
    let onClick: (() -> Void)?
    let onDragStart: (_ startDocY: CGFloat, _ cancelHook: @escaping () -> Void) -> ReorderDragAutoScrollBounds?
    let onDragMove: (_ startDocY: CGFloat, _ currentDocY: CGFloat) -> Void
    let onDragEnd: () -> Void
    let onEscapeCancel: (() -> Void)?

    func makeNSView(context: Context) -> ReorderRowDragNSView {
        let view = ReorderRowDragNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: ReorderRowDragNSView, context: Context) {
        apply(to: nsView)
        if nsView.isActivelyDragging {
            NSCursor.closedHand.set()
            RunLoop.main.perform(inModes: [.eventTracking, .common]) { [weak nsView] in
                MainActor.assumeIsolated {
                    if nsView?.isActivelyDragging == true {
                        NSCursor.closedHand.set()
                    }
                }
            }
        } else {
            nsView.reapplyCursorIfHovered()
        }
    }

    private func apply(to view: ReorderRowDragNSView) {
        view.canDrag = canDrag
        view.dragThreshold = dragThreshold
        view.hoverCursor = hoverCursor
        if view.toolTip != toolTip {
            view.toolTip = toolTip
        }
        view.onClick = onClick
        view.onDragStart = onDragStart
        view.onDragMove = onDragMove
        view.onDragEnd = onDragEnd
        view.onEscapeCancel = onEscapeCancel
    }
}

final class ReorderRowDragNSView: NSView, HoverCursorProviderView {
    var canDrag = false
    var dragThreshold: CGFloat = 4
    var hoverCursor: NSCursor = .openHand {
        didSet {
            if oldValue !== hoverCursor {
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    var onClick: (() -> Void)?
    var onDragStart: ((_ startDocY: CGFloat, _ cancelHook: @escaping () -> Void) -> ReorderDragAutoScrollBounds?)?
    var onDragMove: ((_ startDocY: CGFloat, _ currentDocY: CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onEscapeCancel: (() -> Void)?

    private(set) var isActivelyDragging = false
    private var hoverTrackingArea: NSTrackingArea?
    private var cursorTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var mouseDownScreenPoint: NSPoint?
    private var dragStartDocY: CGFloat = 0
    private var dragStartAttempted = false
    private var dragCancelledExternally = false
    private var didPushClosedHand = false
    private var minAutoScrollDocY: CGFloat?
    private var maxAutoScrollDocY: CGFloat?
    private var autoScrollTimer: Timer?
    private var localEscapeMonitor: Any?

    var customHoverCursor: NSCursor {
        isActivelyDragging ? .closedHand : hoverCursor
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let own = super.menu(for: event) {
            return own
        }
        var candidate = superview
        while let view = candidate {
            if let menu = view.menu(for: event) {
                return menu
            }
            candidate = view.superview
        }
        return nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Never capture `self.window` when `newWindow == nil` — SwiftUI window/panel
        // teardown clears subviews after deallocation starts.
        if newWindow == nil {
            stopAutoScrollTimer()
            removeEscapeMonitor()
            if didPushClosedHand {
                if PointerCursorNSView.activeDragCursor === NSCursor.closedHand {
                    PointerCursorNSView.activeDragCursor = nil
                }
                didPushClosedHand = false
                NSCursor.pop()
            }
            isActivelyDragging = false
            dragStartAttempted = false
            dragCancelledExternally = false
            minAutoScrollDocY = nil
            maxAutoScrollDocY = nil
            mouseDownScreenPoint = nil
            isHovered = false
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            window.acceptsMouseMovedEvents = true
            window.invalidateCursorRects(for: self)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = bounds.size != newSize
        super.setFrameSize(newSize)
        if changed {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isHidden, alphaValue > 0.01, !bounds.isEmpty else { return }
        addCursorRect(bounds, cursor: customHoverCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let hoverArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        let cursorArea = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(hoverArea)
        addTrackingArea(cursorArea)
        self.hoverTrackingArea = hoverArea
        self.cursorTrackingArea = cursorArea
        reapplyCursorIfHovered()
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isActivelyDragging else {
            NSCursor.closedHand.set()
            return
        }
        reapplyCursorIfHovered()
    }

    override func mouseMoved(with event: NSEvent) {
        if isActivelyDragging {
            NSCursor.closedHand.set()
        } else {
            reapplyCursorIfHovered()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isActivelyDragging {
            NSCursor.closedHand.set()
            return
        }
        if isPointInsideSelf() {
            isHovered = true
            hoverCursor.set()
        } else {
            isHovered = false
            super.cursorUpdate(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard !isActivelyDragging else { return }
        guard !isPointInsideSelf() else { return }
        isHovered = false
        refreshHoverCursorAfterExit()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        mouseDownScreenPoint = NSEvent.mouseLocation
        dragStartDocY = currentDocumentTopDownY()
        isActivelyDragging = false
        dragStartAttempted = false
        dragCancelledExternally = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragCancelledExternally,
              let startScreen = mouseDownScreenPoint else {
            return
        }

        if !isActivelyDragging {
            guard canDrag, !dragStartAttempted else { return }
            let currentScreen = NSEvent.mouseLocation
            let distance = hypot(currentScreen.x - startScreen.x, currentScreen.y - startScreen.y)
            guard distance >= dragThreshold else { return }

            dragStartAttempted = true
            let startY = dragStartDocY
            guard let scrollBounds = onDragStart?(startY, { [weak self] in
                self?.handleExternalDragCancel()
            }) else {
                return
            }

            if let documentView = enclosingScrollView?.documentView {
                let rowCenterY = currentRowCenterTopDownDocY(in: documentView)
                minAutoScrollDocY = max(0, rowCenterY - scrollBounds.distanceAboveCenter - 16)
                maxAutoScrollDocY = rowCenterY + scrollBounds.distanceBelowCenter + 16
            } else {
                minAutoScrollDocY = nil
                maxAutoScrollDocY = nil
            }

            isActivelyDragging = true
            PointerCursorNSView.activeDragCursor = .closedHand
            if !didPushClosedHand {
                NSCursor.closedHand.push()
                didPushClosedHand = true
            }
            NSCursor.closedHand.set()
            installEscapeMonitor()
            startAutoScrollTimer()
        }

        NSCursor.closedHand.set()
        onDragMove?(dragStartDocY, currentDocumentTopDownY())
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoScrollTimer()
        removeEscapeMonitor()
        let wasDragging = isActivelyDragging
        let cancelled = dragCancelledExternally
        isActivelyDragging = false
        dragStartAttempted = false
        dragCancelledExternally = false
        minAutoScrollDocY = nil
        maxAutoScrollDocY = nil
        mouseDownScreenPoint = nil
        endDragCursor()

        if wasDragging {
            if !cancelled {
                onDragEnd?()
            }
            refreshHoverCursorAfterExit()
            return
        }

        if !cancelled,
           let onClick,
           let window {
            let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let ptInSelf = convert(ptInWindow, from: nil)
            if bounds.insetBy(dx: -4, dy: -4).contains(ptInSelf) {
                onClick()
            }
        }
    }

    func reapplyCursorIfHovered() {
        guard !isActivelyDragging else { return }
        if let dragCursor = PointerCursorNSView.activeDragCursor {
            dragCursor.set()
            return
        }
        let hoveredNow = isPointInsideSelf()
        let wasHovered = isHovered
        isHovered = hoveredNow
        if hoveredNow {
            hoverCursor.set()
        } else if wasHovered {
            refreshHoverCursorAfterExit()
        }
    }

    private func isPointInsideSelf() -> Bool {
        guard let window, window.isVisible, !isHidden, alphaValue > 0.01 else { return false }
        let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return PointerCursorNSView.isPoint(ptInWindow, inside: self)
    }

    private func handleExternalDragCancel() {
        stopAutoScrollTimer()
        removeEscapeMonitor()
        isActivelyDragging = false
        dragCancelledExternally = true
        minAutoScrollDocY = nil
        maxAutoScrollDocY = nil
        endDragCursor()
        refreshHoverCursorAfterExit()
    }

    private func endDragCursor() {
        if didPushClosedHand {
            if PointerCursorNSView.activeDragCursor === NSCursor.closedHand {
                PointerCursorNSView.activeDragCursor = nil
            }
            didPushClosedHand = false
            NSCursor.pop()
        }
    }

    private func refreshHoverCursorAfterExit() {
        if let dragCursor = PointerCursorNSView.activeDragCursor {
            dragCursor.set()
            return
        }
        guard let window, window.isVisible else {
            NSCursor.arrow.set()
            return
        }
        let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard let rootView = window.contentView?.superview ?? window.contentView,
              rootView.bounds.contains(ptInWindow) else {
            NSCursor.arrow.set()
            return
        }
        if PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: ptInWindow) {
            PointerCursorNSView.forcePointingHandCursor()
        } else if let custom = PointerCursorNSView.customHoverCursor(in: rootView, atWindowPoint: ptInWindow) {
            custom.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func currentDocumentTopDownY() -> CGFloat {
        guard let window,
              let documentView = enclosingScrollView?.documentView else {
            return -NSEvent.mouseLocation.y
        }
        let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let ptInDoc = documentView.convert(ptInWindow, from: nil)
        return documentView.isFlipped ? ptInDoc.y : (documentView.bounds.maxY - ptInDoc.y)
    }

    private func currentRowCenterTopDownDocY(in documentView: NSView) -> CGFloat {
        let midLocal = NSPoint(x: bounds.midX, y: bounds.midY)
        let ptInDoc = documentView.convert(midLocal, from: self)
        return documentView.isFlipped ? ptInDoc.y : (documentView.bounds.maxY - ptInDoc.y)
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isActivelyDragging, !self.dragCancelledExternally else {
                    return false
                }
                if let onEscapeCancel = self.onEscapeCancel {
                    onEscapeCancel()
                } else {
                    self.handleExternalDragCancel()
                }
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeEscapeMonitor() {
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
            self.localEscapeMonitor = nil
        }
    }

    private func startAutoScrollTimer() {
        guard autoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stepAutoScroll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    private func stopAutoScrollTimer() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    private func stepAutoScroll() {
        guard isActivelyDragging,
              !dragCancelledExternally,
              let window,
              window.isVisible,
              let scrollView = enclosingScrollView,
              let documentView = scrollView.documentView else {
            return
        }
        let clipView = scrollView.contentView
        let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let ptInClip = clipView.convert(ptInWindow, from: nil)
        let vis = clipView.bounds
        let edgeZone: CGFloat = 28
        guard vis.height > edgeZone * 2 else { return }

        let topDistance: CGFloat
        let bottomDistance: CGFloat
        if clipView.isFlipped {
            topDistance = ptInClip.y - vis.minY
            bottomDistance = vis.maxY - ptInClip.y
        } else {
            topDistance = vis.maxY - ptInClip.y
            bottomDistance = ptInClip.y - vis.minY
        }

        let scrollDirection: CGFloat
        let intensity: CGFloat
        if topDistance < edgeZone {
            scrollDirection = -1
            intensity = min(1.5, max(0, (edgeZone - topDistance) / edgeZone))
        } else if bottomDistance < edgeZone {
            scrollDirection = 1
            intensity = min(1.5, max(0, (edgeZone - bottomDistance) / edgeZone))
        } else {
            return
        }

        let step = max(1.5, 10.0 * intensity)
        let docBounds = documentView.bounds
        let minOriginY = docBounds.minY
        let maxOriginY = max(minOriginY, docBounds.maxY - vis.height)
        var targetY = vis.origin.y

        if documentView.isFlipped {
            let blockMin = minAutoScrollDocY.map {
                min(vis.origin.y, max(minOriginY, $0))
            } ?? minOriginY
            let blockMax = maxAutoScrollDocY.map {
                max(vis.origin.y, min(maxOriginY, max(minOriginY, $0 - vis.height)))
            } ?? maxOriginY
            if scrollDirection < 0 {
                targetY = max(blockMin, vis.origin.y - step)
            } else {
                targetY = min(blockMax, vis.origin.y + step)
            }
        } else {
            let blockMax = minAutoScrollDocY.map {
                max(vis.origin.y, min(maxOriginY, max(minOriginY, (docBounds.maxY - $0) - vis.height)))
            } ?? maxOriginY
            let blockMin = maxAutoScrollDocY.map {
                min(vis.origin.y, max(minOriginY, min(maxOriginY, docBounds.maxY - $0)))
            } ?? minOriginY
            if scrollDirection < 0 {
                targetY = min(blockMax, vis.origin.y + step)
            } else {
                targetY = max(blockMin, vis.origin.y - step)
            }
        }

        guard abs(targetY - vis.origin.y) > 0.25 else { return }
        clipView.scroll(to: NSPoint(x: vis.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        onDragMove?(dragStartDocY, currentDocumentTopDownY())
        NSCursor.closedHand.set()
    }
}
