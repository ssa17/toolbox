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

    func resetForOpen(entries: [ClipboardEntry]) {
        query = ""
        previewEntryID = nil
        renamingEntryID = nil
        renameDraft = ""
        pendingDeleteEntry = nil
        pendingClearAll = false
        selectedEntryID = entries.first?.id
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

            if let entry = previewEntry {
                fullRowPreview(entry)
            } else if filteredEntries.isEmpty {
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                                clipboardRow(entry, index: index)
                                    .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: uiState.selectedEntryID, initial: false) { _, newID in
                        if let newID {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(newID)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("\(module.entries.count) saved")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(footerShortcutsText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
        .onChange(of: uiState.renamingEntryID) { _, newID in
            if let newID {
                DispatchQueue.main.async {
                    focusedRenameID = newID
                }
            } else {
                focusedRenameID = nil
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
                .pointerCursor()

                HStack(spacing: 6) {
                    Button {
                        uiState.previewEntryID = entry.id
                    } label: {
                        Image(systemName: "eye")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("View full text")
                    .pointerCursor()

                    if entry.isPinned {
                        Button {
                            uiState.renameDraft = entry.customTitle ?? ""
                            uiState.renamingEntryID = isRenaming ? nil : entry.id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Rename pinned item (⌘R)")
                        .pointerCursor()
                    }

                    Button {
                        module.togglePin(entry)
                    } label: {
                        Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                            .font(.caption)
                            .foregroundStyle(entry.isPinned ? .teal : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(entry.isPinned ? "Unpin (⌘P)" : "Pin item (⌘P)")
                    .pointerCursor()

                    Button {
                        uiState.pendingDeleteEntry = entry
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
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
                    Button("Save") {
                        module.renameEntry(entry, title: uiState.renameDraft)
                        uiState.renamingEntryID = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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
        .onHover { hovering in
            if hovering {
                uiState.selectedEntryID = entry.id
            }
        }
        .contextMenu {
            entryContextMenu(for: entry, inPreview: false)
        }
    }

    private func fullRowPreview(_ entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    uiState.previewEntryID = nil
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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

            HStack {
                Button {
                    module.togglePin(entry)
                } label: {
                    Label(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.bordered)
                .help(entry.isPinned ? "Unpin (⌘P)" : "Pin item (⌘P)")
                .pointerCursor()

                Button {
                    uiState.previewEntryID = nil
                    uiState.selectedEntryID = entry.id
                    uiState.renameDraft = entry.customTitle ?? ""
                    uiState.renamingEntryID = entry.id
                } label: {
                    Label(entry.customTitle?.isEmpty == false ? "Rename" : "Name", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .help("Name or rename item (⌘R)")
                .pointerCursor()

                Button(role: .destructive) {
                    uiState.pendingDeleteEntry = entry
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .pointerCursor()

                Spacer()

                Button("Paste This Item") {
                    onSelect(entry)
                }
                .buttonStyle(.borderedProminent)
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
                    Button("Cancel") {
                        uiState.pendingDeleteEntry = nil
                    }
                    .buttonStyle(.bordered)
                    .pointerCursor()

                    Button("Delete") {
                        confirmDelete(entry)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
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
                    Button("Cancel") {
                        uiState.pendingClearAll = false
                    }
                    .buttonStyle(.bordered)
                    .pointerCursor()

                    Button("Clear All") {
                        module.clearHistory(keepPinned: true)
                        uiState.pendingClearAll = false
                        uiState.previewEntryID = nil
                        uiState.selectedEntryID = filteredEntries.first?.id
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
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
