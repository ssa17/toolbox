import AppKit
import SwiftUI

@MainActor
final class ClipboardPopoverUIState: ObservableObject {
    @Published var query = ""
    @Published var selectedEntryID: UUID?
    @Published var previewEntryID: UUID?
    @Published var renamingEntryID: UUID?
    @Published var renameDraft = ""
    @Published var pendingDeleteEntry: ClipboardEntry?
    @Published var pendingClearAll = false
    @Published var hoveredEntryID: UUID?
    @Published var openedAt = Date()
    @Published var dragLayout: ClipboardPinnedDragLayout?
    @Published var dragOffsetY: CGFloat = 0
    @Published var dragTargetIndex: Int?
    @Published var settlingEntryID: UUID?
    @Published var settlingOffsetY: CGFloat = 0
    /// Measured row heights, keyed by entry id.
    @Published var rowHeights: [UUID: CGFloat] = [:]
    /// False briefly around a drag commit so the re-indexed array snaps in place
    /// without double-animating alongside the shifting rows.
    @Published var animatedReorder = true
    @Published var openSequence = 0

    private var activeDragCancelHandler: (() -> Void)?
    private var settleCleanupTask: Task<Void, Never>?
    private var reorderAnimRestoreTask: Task<Void, Never>?

    var isDragging: Bool { dragLayout != nil }
    var draggedEntryID: UUID? { dragLayout?.draggedItem.id }

    func resetForOpen(entries: [ClipboardEntry]) {
        query = ""
        previewEntryID = nil
        renamingEntryID = nil
        renameDraft = ""
        pendingDeleteEntry = nil
        pendingClearAll = false
        hoveredEntryID = nil
        openedAt = Date()
        clearDragState()
        selectedEntryID = entries.first?.id
        openSequence &+= 1
    }

    @discardableResult
    func beginDrag(
        entryID: UUID,
        pinnedIDs: [UUID],
        onExternalCancel: (() -> Void)? = nil
    ) -> Bool {
        if let existingCancel = activeDragCancelHandler {
            activeDragCancelHandler = nil
            existingCancel()
        }
        settleCleanupTask?.cancel()
        settleCleanupTask = nil
        reorderAnimRestoreTask?.cancel()
        reorderAnimRestoreTask = nil
        animatedReorder = true
        hoveredEntryID = nil

        guard let layout = ClipboardPinnedDragLayout(
            pinnedIDs: pinnedIDs,
            heights: rowHeights,
            draggedID: entryID,
            spacing: 5,
            topInset: 0
        ) else {
            return false
        }
        settlingEntryID = nil
        settlingOffsetY = 0
        dragLayout = layout
        dragTargetIndex = layout.sourceIndex
        dragOffsetY = 0
        activeDragCancelHandler = onExternalCancel
        return true
    }

    func updateDrag(rawDeltaY: CGFloat) {
        guard let layout = dragLayout else { return }
        dragOffsetY = layout.clampedOffset(for: rawDeltaY)
        let nextTarget = layout.targetIndex(for: rawDeltaY)
        if nextTarget != dragTargetIndex {
            dragTargetIndex = nextTarget
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func finishDrag(onMove: (UUID, UUID, Bool) -> Void) {
        guard let layout = dragLayout else { return }
        let draggedID = layout.draggedItem.id
        let targetIndex = dragTargetIndex ?? layout.sourceIndex
        let releaseOffset = dragOffsetY
        let residual = layout.residualSettleOffset(
            releaseOffsetY: releaseOffset,
            committedTargetIndex: targetIndex
        )

        activeDragCancelHandler = nil
        dragLayout = nil
        dragTargetIndex = nil
        dragOffsetY = 0

        if let move = layout.moveInstruction(for: targetIndex) {
            animatedReorder = false
            onMove(draggedID, move.targetID, move.insertAfter)
            selectedEntryID = draggedID
            reorderAnimRestoreTask?.cancel()
            reorderAnimRestoreTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                self?.animatedReorder = true
            }
        }

        if abs(residual) > 0.5 {
            animateSettle(entryID: draggedID, fromOffset: residual)
        }
    }

    func cancelActiveDrag() {
        let handler = activeDragCancelHandler
        activeDragCancelHandler = nil
        handler?()

        guard let layout = dragLayout else { return }
        let draggedID = layout.draggedItem.id
        let releaseOffset = dragOffsetY
        dragLayout = nil
        dragTargetIndex = nil
        dragOffsetY = 0

        if abs(releaseOffset) > 0.5 {
            animateSettle(entryID: draggedID, fromOffset: releaseOffset)
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
        dragLayout = nil
        dragTargetIndex = nil
        dragOffsetY = 0
        settlingEntryID = nil
        settlingOffsetY = 0
        animatedReorder = true
    }

    private func animateSettle(entryID: UUID, fromOffset: CGFloat) {
        settleCleanupTask?.cancel()
        settlingEntryID = entryID
        settlingOffsetY = fromOffset

        DispatchQueue.main.async { [weak self] in
            guard let self, self.settlingEntryID == entryID, self.dragLayout == nil else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                self.settlingOffsetY = 0
            }
        }

        settleCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, let self, self.settlingEntryID == entryID else { return }
            self.settlingEntryID = nil
            self.settlingOffsetY = 0
        }
    }

    func selectedEntry(in list: [ClipboardEntry]) -> ClipboardEntry? {
        if let id = selectedEntryID, let found = list.first(where: { $0.id == id }) {
            return found
        }
        return list.first
    }

    func moveSelection(delta: Int, in list: [ClipboardEntry]) {
        guard !list.isEmpty else {
            selectedEntryID = nil
            return
        }
        guard let currentID = selectedEntryID,
              let idx = list.firstIndex(where: { $0.id == currentID }) else {
            selectedEntryID = delta >= 0 ? list.first?.id : list.last?.id
            return
        }
        let next = min(max(0, idx + delta), list.count - 1)
        selectedEntryID = list[next].id
    }
}

struct ClipboardPopoverView: View {
    @ObservedObject var module: ClipboardModule
    @ObservedObject var uiState: ClipboardPopoverUIState
    let onSelect: (ClipboardEntry) -> Void
    let onClose: () -> Void
    @FocusState private var isSearchFocused: Bool
    @FocusState private var focusedRenameID: UUID?

    private var filteredEntries: [ClipboardEntry] {
        guard !uiState.query.isEmpty else { return module.entries }
        return module.entries.filter {
            $0.text.localizedCaseInsensitiveContains(uiState.query) ||
            ($0.customTitle?.localizedCaseInsensitiveContains(uiState.query) ?? false)
        }
    }

    private var previewEntry: ClipboardEntry? {
        guard let id = uiState.previewEntryID else { return nil }
        return module.entries.first(where: { $0.id == id })
    }

    private var hasUnpinnedEntries: Bool {
        module.entries.contains { !$0.isPinned }
    }

    private var pinnedEntries: [ClipboardEntry] {
        filteredEntries.filter(\.isPinned)
    }

    private var recentEntries: [ClipboardEntry] {
        filteredEntries.filter { !$0.isPinned }
    }

    private var pinnedEntryIDs: [UUID] {
        pinnedEntries.map(\.id)
    }

    private var entriesList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !pinnedEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        sectionHeader(title: "PINNED", count: pinnedEntries.count) {
                            if pinnedEntries.count > 1 {
                                Text("Drag to reorder")
                                    .toolboxFont(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        VStack(spacing: 5) {
                            ForEach(Array(pinnedEntries.enumerated()), id: \.element.id) { pinnedIdx, entry in
                                clipboardRow(entry, index: pinnedIdx, isFirstInSection: pinnedIdx == 0)
                            }
                        }
                        .animation(
                            uiState.animatedReorder ? .easeInOut(duration: 0.15) : nil,
                            value: pinnedEntries.map(\.id)
                        )
                    }
                    // Keep lifted/settling pinned cards cleanly above the RECENT header.
                    .zIndex(uiState.isDragging || uiState.settlingEntryID != nil ? 10 : 0)
                }

                if !recentEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        sectionHeader(title: "RECENT", count: recentEntries.count) {
                            if hasUnpinnedEntries {
                                Button("Clear All") {
                                    uiState.pendingClearAll = true
                                }
                                .buttonStyle(.plain)
                                .toolboxFont(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .help("Clear all unpinned clipboard items")
                                .focusEffectDisabled()
                                .pointerCursor()
                            }
                        }
                        VStack(spacing: 5) {
                            ForEach(Array(recentEntries.enumerated()), id: \.element.id) { recentIdx, entry in
                                clipboardRow(
                                    entry,
                                    index: pinnedEntries.count + recentIdx,
                                    isFirstInSection: recentIdx == 0
                                )
                            }
                        }
                        .animation(
                            uiState.animatedReorder ? .easeInOut(duration: 0.15) : nil,
                            value: recentEntries.map(\.id)
                        )
                    }
                }
            }
            .padding(8)
        }
        .onPreferenceChange(ClipboardRowHeightKey.self) { heights in
            MainActor.assumeIsolated {
                uiState.rowHeights = heights
            }
        }
    }

    private func sectionHeader<Trailing: View>(
        title: String,
        count: Int,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .toolboxFont(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .toolboxFont(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.06), in: Capsule())
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search clipboard or pinned labels…", text: $uiState.query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onChange(of: uiState.query) { _, _ in
                        if let first = filteredEntries.first {
                            uiState.selectedEntryID = first.id
                        }
                    }
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .toolboxFont(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                .focusEffectDisabled()
                .pointerCursor()
            }
            .padding(11)

            Divider()

            ZStack {
                Group {
                    if filteredEntries.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "doc.on.clipboard")
                                .toolboxFont(.title2)
                                .foregroundStyle(.secondary)
                            Text(module.entries.isEmpty ? "Copy something to start building history" : "No matching items")
                                .toolboxFont(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    } else {
                        entriesList
                    }
                }
                .opacity(previewEntry == nil ? 1 : 0)
                .allowsHitTesting(previewEntry == nil)

                if let entry = previewEntry {
                    fullRowPreview(entry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThickMaterial)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Text(
                    uiState.query.isEmpty
                        ? "\(module.entries.count) saved"
                        : "\(filteredEntries.count) of \(module.entries.count)"
                )
                .toolboxFont(.caption2)
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(footerShortcutsText)
                    .toolboxFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .overlay {
            if let entry = uiState.pendingDeleteEntry {
                confirmDeleteOverlay(entry)
            } else if uiState.pendingClearAll {
                confirmClearAllOverlay()
            }
        }
        .onAppear {
            isSearchFocused = true
        }
        .onChange(of: uiState.openSequence) { _, _ in
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onChange(of: uiState.previewEntryID) { oldID, newID in
            if oldID != nil && newID == nil && uiState.renamingEntryID == nil {
                DispatchQueue.main.async {
                    isSearchFocused = true
                }
            }
        }
        .onChange(of: uiState.renamingEntryID) { _, newID in
            if let newID {
                DispatchQueue.main.async {
                    focusedRenameID = newID
                }
            } else {
                focusedRenameID = nil
                DispatchQueue.main.async {
                    isSearchFocused = true
                }
            }
        }
        .onChange(of: pinnedEntryIDs) { _, newPinnedIDs in
            if let layout = uiState.dragLayout, layout.items.map(\.id) != newPinnedIDs {
                uiState.cancelActiveDrag()
            }
        }
        .toolboxDarkAppearance()
    }

    private var activeFooterEntry: ClipboardEntry? {
        uiState.selectedEntry(in: filteredEntries)
    }

    private var footerShortcutsText: String {
        if uiState.pendingDeleteEntry != nil || uiState.pendingClearAll {
            return "⏎ Confirm · Esc Cancel"
        }
        if let preview = previewEntry {
            let move = (preview.isPinned && pinnedEntryIDs.count > 1) ? " · ⌘↑↓ Move" : ""
            return "← Back · ⏎ Paste · ⌘P Pin · ⌘R Rename" + move
        }
        if let active = activeFooterEntry, active.isPinned, pinnedEntryIDs.count > 1 {
            return "⏎ Paste · → Preview · ⌘P Pin · ⌘R Name · ⌘↑↓ Move"
        }
        return "⏎ Paste · → Preview · ⌘P Pin · ⌘R Name · ⌫ Delete"
    }

    static func formatRowMetadata(for entry: ClipboardEntry, now: Date = Date()) -> String {
        let lineCount = entry.text.split(separator: "\n", omittingEmptySubsequences: false).count
        let charCount = entry.text.count
        let sizePart = lineCount > 1
            ? "\(lineCount) lines · \(charCount) chars"
            : "\(charCount) \(charCount == 1 ? "char" : "chars")"
        if entry.isPinned {
            return sizePart
        }
        return "\(relativeTimestamp(from: entry.copiedAt, to: now)) · \(sizePart)"
    }

    private static func relativeTimestamp(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 45 {
            return "Just now"
        }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "\(max(1, minutes))m ago"
        }
        let hours = Int(seconds / 3600)
        if hours < 24 {
            return "\(hours)h ago"
        }
        let days = Int(seconds / 86400)
        if days < 7 {
            return "\(days)d ago"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func clipboardRow(_ entry: ClipboardEntry, index: Int, isFirstInSection: Bool) -> some View {
        let isSelected = uiState.selectedEntryID == entry.id || (uiState.selectedEntryID == nil && filteredEntries.first?.id == entry.id)
        let isRenaming = uiState.renamingEntryID == entry.id
        let canDragPinned = entry.isPinned && pinnedEntryIDs.count > 1
        let isDragging = uiState.draggedEntryID == entry.id
        let isSettling = !isDragging && uiState.settlingEntryID == entry.id
        let isHovered = uiState.hoveredEntryID == entry.id
        let showActions = !uiState.isDragging && (isHovered || isSelected || isRenaming)
        let dragShift: CGFloat = {
            guard let layout = uiState.dragLayout,
                  !isDragging,
                  let pinnedIdx = layout.items.firstIndex(where: { $0.id == entry.id }) else {
                return 0
            }
            return layout.restingShift(
                forRowAt: pinnedIdx,
                targetIndex: uiState.dragTargetIndex ?? layout.sourceIndex
            )
        }()
        let rowOffsetY = isDragging ? uiState.dragOffsetY : (isSettling ? uiState.settlingOffsetY : dragShift)

        let dragStartAction: (_ startDocY: CGFloat, _ cancelHook: @escaping () -> Void) -> ReorderDragAutoScrollBounds? = { [weak uiState] _, cancelHook in
            guard let uiState,
                  uiState.beginDrag(
                      entryID: entry.id,
                      pinnedIDs: pinnedEntryIDs,
                      onExternalCancel: cancelHook
                  ),
                  let layout = uiState.dragLayout else {
                return nil
            }
            return ReorderDragAutoScrollBounds(layout: layout)
        }
        let dragMoveAction: (_ startDocY: CGFloat, _ currentDocY: CGFloat) -> Void = { [weak uiState] startDocY, currentDocY in
            uiState?.updateDrag(rawDeltaY: currentDocY - startDocY)
        }
        let dragEndAction: () -> Void = { [weak uiState, weak module] in
            uiState?.finishDrag { draggedID, targetID, insertAfter in
                module?.movePinnedEntry(draggedID, relativeTo: targetID, insertAfter: insertAfter)
            }
        }
        let dragEscapeAction: () -> Void = { [weak uiState] in
            uiState?.cancelActiveDrag()
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                if entry.isPinned {
                    if canDragPinned {
                        Image(systemName: "line.3.horizontal")
                            .toolboxFont(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isDragging ? Color.teal : (isHovered ? Color.secondary : Color.secondary.opacity(0.55)))
                            .frame(width: 16, height: 28)
                            .contentShape(Rectangle())
                            .overlay(
                                ReorderRowDragSurface(
                                    canDrag: true,
                                    dragThreshold: 1,
                                    hoverCursor: .openHand,
                                    toolTip: uiState.isDragging ? nil : "Drag to reorder (⌘ ↑ / ⌘ ↓)",
                                    onClick: nil,
                                    onDragStart: dragStartAction,
                                    onDragMove: dragMoveAction,
                                    onDragEnd: dragEndAction,
                                    onEscapeCancel: dragEscapeAction
                                )
                            )
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "pin.fill")
                            .toolboxFont(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.teal.opacity(0.85))
                            .frame(width: 16, height: 28)
                            .accessibilityHidden(true)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    interactiveRowSurface(
                        canDragPinned: canDragPinned,
                        onSelect: { onSelect(entry) },
                        dragStartAction: dragStartAction,
                        dragMoveAction: dragMoveAction,
                        dragEndAction: dragEndAction,
                        dragEscapeAction: dragEscapeAction
                    ) {
                        HStack(alignment: .top, spacing: 8) {
                            snippetTextBlock(entry)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if index < 9 {
                                ShortcutPill(text: "⌘ \(index + 1)")
                                    .padding(.top, 1)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onSelect(entry) }

                    HStack(spacing: 6) {
                        interactiveRowSurface(
                            canDragPinned: canDragPinned,
                            onSelect: { onSelect(entry) },
                            dragStartAction: dragStartAction,
                            dragMoveAction: dragMoveAction,
                            dragEndAction: dragEndAction,
                            dragEscapeAction: dragEscapeAction
                        ) {
                            HStack(spacing: 0) {
                                Text(Self.formatRowMetadata(for: entry, now: uiState.openedAt))
                                    .toolboxFont(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityHidden(true)

                        HStack(spacing: 4) {
                            ClipboardRowActionButton(
                                systemName: "eye",
                                helpText: "View full text (→)",
                                isVisible: showActions
                            ) {
                                uiState.selectedEntryID = entry.id
                                uiState.previewEntryID = entry.id
                            }

                            if entry.isPinned {
                                ClipboardRowActionButton(
                                    systemName: "pencil",
                                    helpText: "Rename item (⌘R)",
                                    isVisible: showActions
                                ) {
                                    uiState.selectedEntryID = entry.id
                                    uiState.renameDraft = entry.customTitle ?? ""
                                    uiState.renamingEntryID = isRenaming ? nil : entry.id
                                }
                            }

                            ClipboardRowActionButton(
                                systemName: entry.isPinned ? "pin.fill" : "pin",
                                helpText: entry.isPinned ? "Unpin (⌘P)" : "Pin item (⌘P)",
                                tint: .teal,
                                activeColor: entry.isPinned ? .teal : nil,
                                isVisible: showActions
                            ) {
                                uiState.selectedEntryID = entry.id
                                module.togglePin(entry)
                            }

                            ClipboardRowActionButton(
                                systemName: "trash",
                                helpText: "Delete item (⌫)",
                                isDestructive: true,
                                isVisible: showActions
                            ) {
                                uiState.selectedEntryID = entry.id
                                uiState.pendingDeleteEntry = entry
                            }
                        }
                        .opacity(showActions ? 1 : 0)
                        .allowsHitTesting(showActions)
                        .animation(.easeOut(duration: 0.12), value: showActions)
                    }
                    .frame(height: 24)
                }
            }

            if isRenaming {
                HStack(spacing: 6) {
                    TextField("Label for item…", text: $uiState.renameDraft)
                        .textFieldStyle(.roundedBorder)
                        .toolboxFont(.caption)
                        .focused($focusedRenameID, equals: entry.id)
                        .onSubmit {
                            module.renameEntry(entry, title: uiState.renameDraft)
                            uiState.renamingEntryID = nil
                        }
                    Button {
                        module.renameEntry(entry, title: uiState.renameDraft)
                        uiState.renamingEntryID = nil
                    } label: {
                        Text("Save")
                            .toolboxFont(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .pointerCursor()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if isDragging {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.teal.opacity(0.12))
                    )
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.18)
                            : (isHovered
                                ? Color.primary.opacity(0.085)
                                : (entry.isPinned ? Color.teal.opacity(0.055) : Color.primary.opacity(0.045)))
                    )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDragging
                        ? Color.teal.opacity(0.65)
                        : (isSelected
                            ? Color.accentColor.opacity(0.45)
                            : (isHovered
                                ? Color.primary.opacity(0.12)
                                : (entry.isPinned ? Color.teal.opacity(0.14) : Color.clear))),
                    lineWidth: isDragging ? 1.5 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            guard !uiState.isDragging else { return }
            if hovering {
                uiState.hoveredEntryID = entry.id
            } else if uiState.hoveredEntryID == entry.id {
                uiState.hoveredEntryID = nil
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ClipboardRowHeightKey.self, value: [entry.id: proxy.size.height])
            }
        )
        .overlay(
            ClipboardRowVisibilityScrollView(
                isSelected: isSelected,
                openSequence: uiState.openSequence,
                isPreviewOpen: previewEntry != nil,
                isFirstInSection: isFirstInSection
            )
            .allowsHitTesting(false)
        )
        .scaleEffect(isDragging ? 1.015 : 1.0)
        .shadow(color: .black.opacity(isDragging ? 0.24 : 0), radius: isDragging ? 10 : 0, y: isDragging ? 4 : 0)
        .animation(.easeOut(duration: 0.12), value: isDragging)
        .offset(y: rowOffsetY)
        .animation(
            uiState.dragLayout != nil && !isDragging
                ? .interactiveSpring(response: 0.22, dampingFraction: 0.86)
                : nil,
            value: dragShift
        )
        .zIndex(isDragging ? 100 : (isSettling ? 50 : 0))
        .contextMenu {
            entryContextMenu(for: entry, inPreview: false)
        }
    }

    @ViewBuilder
    private func interactiveRowSurface<Content: View>(
        canDragPinned: Bool,
        onSelect: @escaping () -> Void,
        dragStartAction: @escaping (_ startDocY: CGFloat, _ cancelHook: @escaping () -> Void) -> ReorderDragAutoScrollBounds?,
        dragMoveAction: @escaping (_ startDocY: CGFloat, _ currentDocY: CGFloat) -> Void,
        dragEndAction: @escaping () -> Void,
        dragEscapeAction: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if canDragPinned {
            content()
                .contentShape(Rectangle())
                .overlay(
                    ReorderRowDragSurface(
                        canDrag: true,
                        dragThreshold: 4,
                        hoverCursor: .pointingHand,
                        toolTip: nil,
                        onClick: onSelect,
                        onDragStart: dragStartAction,
                        onDragMove: dragMoveAction,
                        onDragEnd: dragEndAction,
                        onEscapeCancel: dragEscapeAction
                    )
                )
        } else {
            Button(action: onSelect) {
                content()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerCursor()
        }
    }

    private func snippetTextBlock(_ entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = entry.customTitle, !title.isEmpty {
                Text(title)
                    .toolboxFont(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
                    .lineLimit(1)
            }
            Text(entry.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .toolboxFont(.system(.callout, design: .monospaced))
        }
    }

    private func fullRowPreview(_ entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    uiState.selectedEntryID = entry.id
                    uiState.previewEntryID = nil
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .toolboxFont(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)
                        )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerCursor()

                if let title = entry.customTitle, !title.isEmpty {
                    Text(title)
                        .toolboxFont(.callout.weight(.semibold))
                        .foregroundStyle(.teal)
                }

                Spacer()

                Text("\(entry.text.count) chars · \(entry.text.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
                    .toolboxFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(entry.text)
                    .toolboxFont(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Button {
                    module.togglePin(entry)
                } label: {
                    Label(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.fill" : "pin")
                        .toolboxFont(.caption.weight(.medium))
                        .foregroundStyle(entry.isPinned ? .teal : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            entry.isPinned ? Color.teal.opacity(0.15) : Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    entry.isPinned ? Color.teal.opacity(0.35) : Color.primary.opacity(0.14),
                                    lineWidth: 0.75
                                )
                        )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(entry.isPinned ? "Unpin (⌘P)" : "Pin item (⌘P)")
                .pointerCursor()

                Button {
                    uiState.previewEntryID = nil
                    uiState.selectedEntryID = entry.id
                    uiState.renameDraft = entry.customTitle ?? ""
                    uiState.renamingEntryID = entry.id
                } label: {
                    Label(entry.customTitle?.isEmpty == false ? "Rename" : "Name", systemImage: "pencil")
                        .toolboxFont(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)
                        )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Name or rename item (⌘R)")
                .pointerCursor()

                Button {
                    uiState.pendingDeleteEntry = entry
                } label: {
                    Label("Delete", systemImage: "trash")
                        .toolboxFont(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.red.opacity(0.32), lineWidth: 0.75)
                        )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerCursor()

                Spacer()

                Button {
                    onSelect(entry)
                } label: {
                    Text("Paste This Item")
                        .toolboxFont(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerCursor()
            }
        }
        .padding(12)
        .contextMenu {
            entryContextMenu(for: entry, inPreview: true)
        }
    }

    @ViewBuilder
    private func entryContextMenu(for entry: ClipboardEntry, inPreview: Bool) -> some View {
        Button {
            onSelect(entry)
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .keyboardShortcut(.return, modifiers: [])

        if inPreview {
            Button {
                uiState.previewEntryID = nil
            } label: {
                Label("Back to List", systemImage: "chevron.left")
            }
            .keyboardShortcut(.escape, modifiers: [])
        } else {
            Button {
                uiState.previewEntryID = entry.id
            } label: {
                Label("View Full Text", systemImage: "eye")
            }
            .keyboardShortcut("i", modifiers: .command)
        }

        Button {
            module.togglePin(entry)
        } label: {
            Label(entry.isPinned ? "Unpin Item" : "Pin Item", systemImage: entry.isPinned ? "pin.slash" : "pin")
        }
        .keyboardShortcut("p", modifiers: .command)

        Button {
            uiState.previewEntryID = nil
            uiState.selectedEntryID = entry.id
            uiState.renameDraft = entry.customTitle ?? ""
            uiState.renamingEntryID = entry.id
        } label: {
            Label(entry.customTitle?.isEmpty == false ? "Rename…" : "Name Item…", systemImage: "pencil")
        }
        .keyboardShortcut("r", modifiers: .command)

        if entry.isPinned {
            Button {
                uiState.selectedEntryID = entry.id
                module.movePinnedEntry(entry, by: -1, within: filteredEntries)
            } label: {
                Label("Move Up (⌘ ↑)", systemImage: "chevron.up")
            }
            .disabled(pinnedEntryIDs.first == entry.id)

            Button {
                uiState.selectedEntryID = entry.id
                module.movePinnedEntry(entry, by: 1, within: filteredEntries)
            } label: {
                Label("Move Down (⌘ ↓)", systemImage: "chevron.down")
            }
            .disabled(pinnedEntryIDs.last == entry.id)
        }

        Divider()

        Button(role: .destructive) {
            uiState.pendingDeleteEntry = entry
        } label: {
            Label("Delete…", systemImage: "trash")
        }
        .keyboardShortcut(.delete, modifiers: [])

        if hasUnpinnedEntries {
            Divider()
            Button(role: .destructive) {
                uiState.pendingClearAll = true
            } label: {
                Label("Clear All Unpinned…", systemImage: "trash.slash")
            }
        }
    }

    private func confirmDeleteOverlay(_ entry: ClipboardEntry) -> some View {
        ZStack {
            Color.black.opacity(0.35)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture {
                    uiState.pendingDeleteEntry = nil
                }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "trash.fill")
                        .foregroundStyle(.red)
                    Text("Delete Clipboard Item?")
                        .toolboxFont(.callout.weight(.semibold))
                }

                Text(entry.customTitle ?? entry.text)
                    .toolboxFont(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        uiState.pendingDeleteEntry = nil
                    } label: {
                        Text("Cancel")
                            .toolboxFont(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)
                            )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .pointerCursor()

                    Button {
                        confirmDelete(entry)
                    } label: {
                        Text("Delete")
                            .toolboxFont(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .pointerCursor()
                }
            }
            .padding(14)
            .frame(width: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        }
    }

    private func confirmClearAllOverlay() -> some View {
        let unpinnedCount = module.entries.filter { !$0.isPinned }.count
        return ZStack {
            Color.black.opacity(0.35)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture {
                    uiState.pendingClearAll = false
                }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "trash.fill")
                        .foregroundStyle(.red)
                    Text("Clear All Unpinned Items?")
                        .toolboxFont(.callout.weight(.semibold))
                }

                Text(
                    unpinnedCount > 0
                        ? "This will remove \(unpinnedCount) unpinned clipboard \(unpinnedCount == 1 ? "item" : "items"). Pinned items are kept."
                        : "All items are currently pinned and will be kept."
                )
                .toolboxFont(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        uiState.pendingClearAll = false
                    } label: {
                        Text("Cancel")
                            .toolboxFont(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)
                            )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .pointerCursor()

                    Button {
                        module.clearHistory(keepPinned: true)
                        uiState.pendingClearAll = false
                        uiState.previewEntryID = nil
                        uiState.selectedEntryID = filteredEntries.first?.id
                    } label: {
                        Text("Clear All")
                            .toolboxFont(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .pointerCursor()
                }
            }
            .padding(14)
            .frame(width: 290)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        }
    }

    private func confirmDelete(_ entry: ClipboardEntry) {
        module.deleteEntry(entry)
        uiState.pendingDeleteEntry = nil
        if uiState.previewEntryID == entry.id {
            uiState.previewEntryID = nil
        }
        if uiState.selectedEntryID == entry.id {
            uiState.selectedEntryID = filteredEntries.first?.id
        }
    }
}

private struct ClipboardRowVisibilityScrollView: NSViewRepresentable {
    let isSelected: Bool
    let openSequence: Int
    let isPreviewOpen: Bool
    let isFirstInSection: Bool

    func makeNSView(context: Context) -> ClipboardRowVisibilityNSView {
        ClipboardRowVisibilityNSView()
    }

    func updateNSView(_ nsView: ClipboardRowVisibilityNSView, context: Context) {
        let selectionActivated = isSelected && !nsView.wasSelected
        let reopenedSelected = isSelected && nsView.lastOpenSequence != openSequence
        let previewDismissed = isSelected && nsView.wasPreviewOpen && !isPreviewOpen
        nsView.wasSelected = isSelected
        nsView.lastOpenSequence = openSequence
        nsView.wasPreviewOpen = isPreviewOpen
        nsView.isFirstInSection = isFirstInSection

        if !isPreviewOpen && (selectionActivated || reopenedSelected || previewDismissed) {
            nsView.scheduleScrollToVisible()
        }
    }
}

final class ClipboardRowVisibilityNSView: NSView {
    var wasSelected = false
    var lastOpenSequence = -1
    var wasPreviewOpen = false
    var isFirstInSection = false
    private var scrollPending = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wasSelected && window != nil && !wasPreviewOpen {
            scheduleScrollToVisible()
        }
    }

    func scheduleScrollToVisible() {
        guard !scrollPending else { return }
        scrollPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollPending = false
            self.scrollIntoViewIfNeeded()
        }
    }

    static func minimalVerticalScrollOriginY(
        rowRect: NSRect,
        visibleRect: NSRect,
        documentBounds: NSRect,
        isFlipped: Bool
    ) -> CGFloat? {
        let clampedRow = rowRect.intersection(documentBounds)
        guard !clampedRow.isNull, !clampedRow.isEmpty else { return nil }
        if visibleRect.contains(clampedRow) {
            return nil
        }

        var targetY = visibleRect.origin.y
        if isFlipped {
            if clampedRow.minY < visibleRect.minY {
                targetY = clampedRow.minY
            } else if clampedRow.maxY > visibleRect.maxY {
                targetY = clampedRow.maxY - visibleRect.height
            }
        } else {
            if clampedRow.maxY > visibleRect.maxY {
                targetY = clampedRow.maxY - visibleRect.height
            } else if clampedRow.minY < visibleRect.minY {
                targetY = clampedRow.minY
            }
        }

        let minOriginY = documentBounds.minY
        let maxOriginY = max(minOriginY, documentBounds.maxY - visibleRect.height)
        targetY = min(max(minOriginY, targetY), maxOriginY)
        return abs(targetY - visibleRect.origin.y) > 0.5 ? targetY : nil
    }

    private func scrollIntoViewIfNeeded() {
        guard wasSelected,
              !wasPreviewOpen,
              window != nil,
              !bounds.isEmpty,
              let scrollView = enclosingScrollView,
              let documentView = scrollView.documentView else {
            return
        }
        scrollView.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        let visibleRect = clipView.documentVisibleRect
        let rawRectInDoc = documentView.convert(bounds, from: self)
        let topPad: CGFloat = isFirstInSection ? 36 : 8
        let bottomPad: CGFloat = 8
        let rowRectInDoc = NSRect(
            x: rawRectInDoc.origin.x,
            y: rawRectInDoc.origin.y - (documentView.isFlipped ? topPad : bottomPad),
            width: rawRectInDoc.width,
            height: rawRectInDoc.height + topPad + bottomPad
        )
        guard let nextY = Self.minimalVerticalScrollOriginY(
            rowRect: rowRectInDoc,
            visibleRect: visibleRect,
            documentBounds: documentView.bounds,
            isFlipped: documentView.isFlipped
        ) else {
            return
        }

        clipView.scroll(to: NSPoint(x: visibleRect.origin.x, y: nextY))
        scrollView.reflectScrolledClipView(clipView)
    }
}

/// Reports each row's measured height for drag layout slot geometry.
private struct ClipboardRowHeightKey: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

@MainActor
private final class ClipboardActionHoverState: ObservableObject {
    @Published var isHovered = false
}

/// Compact rounded action pill rendered in the bottom-right row metadata bar.
private struct ClipboardRowActionButton: View {
    let systemName: String
    let helpText: String
    var tint: Color = .primary
    var activeColor: Color? = nil
    var isDestructive: Bool = false
    let isVisible: Bool
    let action: () -> Void

    @StateObject private var hoverState = ClipboardActionHoverState()

    private var foregroundColor: Color {
        if isDestructive && hoverState.isHovered { return .red }
        if let activeColor { return activeColor }
        if hoverState.isHovered {
            return tint != .primary ? tint : .primary
        }
        return .secondary
    }

    private var pillBackgroundColor: Color {
        if hoverState.isHovered {
            if isDestructive { return Color.red.opacity(0.16) }
            if tint != .primary { return tint.opacity(0.16) }
            return Color.primary.opacity(0.12)
        }
        return Color.primary.opacity(0.055)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .toolboxFont(.system(size: 12.5, weight: .medium))
                .foregroundStyle(foregroundColor)
                .frame(width: 26, height: 24)
                .background(pillBackgroundColor, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(helpText)
        .onHover { hoverState.isHovered = isVisible && $0 }
        .onChange(of: isVisible) { _, visible in
            if !visible {
                hoverState.isHovered = false
            }
        }
        .pointerCursor()
    }
}
