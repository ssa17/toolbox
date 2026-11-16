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
    @Published var openSequence = 0

    func resetForOpen(entries: [ClipboardEntry]) {
        query = ""
        previewEntryID = nil
        renamingEntryID = nil
        renameDraft = ""
        pendingDeleteEntry = nil
        pendingClearAll = false
        selectedEntryID = entries.first?.id
        openSequence &+= 1
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
                if hasUnpinnedEntries {
                    Button("Clear All") {
                        uiState.pendingClearAll = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Clear all unpinned clipboard items")
                    .focusEffectDisabled()
                    .pointerCursor()
                }
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 16))
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
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text(module.entries.isEmpty ? "Copy something to start building history" : "No matching items")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    } else {
                        ScrollView {
                            VStack(spacing: 5) {
                                ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                                    clipboardRow(entry, index: index)
                                }
                            }
                            .padding(8)
                        }
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
                Text("\(module.entries.count) saved")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(footerShortcutsText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
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
    }

    private var footerShortcutsText: String {
        if uiState.pendingDeleteEntry != nil || uiState.pendingClearAll {
            return "⏎ Confirm · Esc Cancel"
        }
        if previewEntry != nil {
            return "← / Esc Back · ⏎ Paste · ⌘P Pin · ⌘R Rename · ⌫ Delete"
        }
        return "↑↓ Select · ⏎ / ⌘1–9 Paste · → Preview · ⌘P Pin · ⌘R Name · ⌫ Delete"
    }

    private func clipboardRow(_ entry: ClipboardEntry, index: Int) -> some View {
        let isSelected = uiState.selectedEntryID == entry.id || (uiState.selectedEntryID == nil && filteredEntries.first?.id == entry.id)
        let isRenaming = uiState.renamingEntryID == entry.id

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    onSelect(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        if let title = entry.customTitle, !title.isEmpty {
                            HStack(spacing: 5) {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.teal)
                                Text(title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.teal)
                            }
                        }
                        Text(entry.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .font(.system(.callout, design: .monospaced))
                        HStack(spacing: 6) {
                            if entry.isPinned && (entry.customTitle?.isEmpty ?? true) {
                                Label("Pinned", systemImage: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.teal)
                            }
                            Text("\(entry.text.count) chars")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerCursor()

                HStack(spacing: 6) {
                    Button {
                        uiState.selectedEntryID = entry.id
                        uiState.previewEntryID = entry.id
                    } label: {
                        Image(systemName: "eye")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("View full text")
                    .pointerCursor()

                    if entry.isPinned {
                        Button {
                            uiState.selectedEntryID = entry.id
                            uiState.renameDraft = entry.customTitle ?? ""
                            uiState.renamingEntryID = isRenaming ? nil : entry.id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help("Rename pinned item (⌘R)")
                        .pointerCursor()
                    }

                    Button {
                        uiState.selectedEntryID = entry.id
                        module.togglePin(entry)
                    } label: {
                        Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                            .font(.caption)
                            .foregroundStyle(entry.isPinned ? .teal : .secondary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(entry.isPinned ? "Unpin (⌘P)" : "Pin item (⌘P)")
                    .pointerCursor()

                    Button {
                        uiState.selectedEntryID = entry.id
                        uiState.pendingDeleteEntry = entry
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Delete item (⌫)")
                    .pointerCursor()

                    if index < 9 {
                        ShortcutPill(text: "⌘ \(index + 1)")
                            .padding(.leading, 2)
                    }
                }
            }

            if isRenaming {
                HStack(spacing: 6) {
                    TextField("Label for item…", text: $uiState.renameDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
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
                            .font(.caption.weight(.semibold))
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
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .overlay(
            ClipboardRowVisibilityScrollView(
                isSelected: isSelected,
                openSequence: uiState.openSequence,
                isPreviewOpen: previewEntry != nil
            )
            .allowsHitTesting(false)
        )
        .contextMenu {
            entryContextMenu(for: entry, inPreview: false)
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
                        .font(.caption.weight(.semibold))
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
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.teal)
                }

                Spacer()

                Text("\(entry.text.count) chars · \(entry.text.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(entry.text)
                    .font(.system(.callout, design: .monospaced))
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
                        .font(.caption.weight(.medium))
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
                        .font(.caption.weight(.medium))
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
                        .font(.caption.weight(.semibold))
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
                        .font(.caption.weight(.semibold))
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
                        .font(.callout.weight(.semibold))
                }

                Text(entry.customTitle ?? entry.text)
                    .font(.caption.monospaced())
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
                            .font(.callout.weight(.medium))
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
                            .font(.callout.weight(.semibold))
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
                        .font(.callout.weight(.semibold))
                }

                Text(
                    unpinnedCount > 0
                        ? "This will remove \(unpinnedCount) unpinned clipboard \(unpinnedCount == 1 ? "item" : "items"). Pinned items are kept."
                        : "All items are currently pinned and will be kept."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        uiState.pendingClearAll = false
                    } label: {
                        Text("Cancel")
                            .font(.callout.weight(.medium))
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
                            .font(.callout.weight(.semibold))
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

        if !isPreviewOpen && (selectionActivated || reopenedSelected || previewDismissed) {
            nsView.scheduleScrollToVisible()
        }
    }
}

final class ClipboardRowVisibilityNSView: NSView {
    var wasSelected = false
    var lastOpenSequence = -1
    var wasPreviewOpen = false
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
        let rowRectInDoc = documentView.convert(bounds, from: self).insetBy(dx: 0, dy: -8)
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
