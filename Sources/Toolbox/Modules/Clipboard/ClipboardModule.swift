import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

enum ClipboardEntryKind: String, Codable, Equatable, Sendable {
    case text, image
}

struct ClipboardImageMetadata: Codable, Equatable, Sendable {
    var filename: String
    var thumbnailFilename: String
    var sha256: String
    var pixelWidth: Int
    var pixelHeight: Int
    var byteSize: Int
}

enum ClipboardHistoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all, text, images, pinned

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .images: "Images"
        case .pinned: "Pinned"
        }
    }
}

struct ClipboardEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let copiedAt: Date
    var isPinned: Bool
    var customTitle: String?
    /// Position within the pinned group (0 = topmost). Only meaningful for pinned
    /// entries — unpinned entries are always ordered by `copiedAt` (newest first).
    var sortIndex: Int
    var kind: ClipboardEntryKind
    var image: ClipboardImageMetadata?

    init(
        id: UUID = UUID(),
        text: String,
        copiedAt: Date = Date(),
        isPinned: Bool = false,
        customTitle: String? = nil,
        sortIndex: Int = 0,
        kind: ClipboardEntryKind = .text,
        image: ClipboardImageMetadata? = nil
    ) {
        self.id = id
        self.text = text
        self.copiedAt = copiedAt
        self.isPinned = isPinned
        self.customTitle = customTitle
        self.sortIndex = sortIndex
        self.kind = kind
        self.image = image
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        copiedAt = try c.decode(Date.self, forKey: .copiedAt)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        // Older pinned_clipboard.json files predate manual ordering; default to 0 so
        // pre-existing pinned items keep their most-recently-copied order.
        sortIndex = try c.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        kind = try c.decodeIfPresent(ClipboardEntryKind.self, forKey: .kind) ?? .text
        image = try c.decodeIfPresent(ClipboardImageMetadata.self, forKey: .image)
    }

    var imageDimensionsText: String? {
        guard let image else { return nil }
        return "\(image.pixelWidth) × \(image.pixelHeight)"
    }

    var imageByteSizeText: String? {
        guard let image else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(image.byteSize), countStyle: .file)
    }

    func matches(query: String, filter: ClipboardHistoryFilter) -> Bool {
        switch filter {
        case .all:
            break
        case .text:
            guard kind == .text else { return false }
        case .images:
            guard kind == .image else { return false }
        case .pinned:
            guard isPinned else { return false }
        }
        guard !query.isEmpty else { return true }
        if text.localizedCaseInsensitiveContains(query) ||
            (customTitle?.localizedCaseInsensitiveContains(query) ?? false) {
            return true
        }
        if kind == .image {
            let imageLabels = ["image", "img", "png", imageDimensionsText, imageByteSizeText]
                .compactMap { $0 }
                .joined(separator: " ")
            return imageLabels.localizedCaseInsensitiveContains(query)
        }
        return false
    }
}

enum ClipboardPasteboardClassification: Equatable {
    case ignored
    case text
    case image(NSPasteboard.PasteboardType)
}

@MainActor
final class ClipboardModule: NSObject, ToolboxModule, ObservableObject {
    let id = "clipboard"
    let name = "Clipboard History"
    let tagline = "Press your hotkey (default ⌘ ⌥ V) for a searchable floating clipboard dropdown."
    let aboutSummary = "Keeps a lightweight rolling history of copied text and images so you never lose a snippet or screenshot when copying something else. Press your shortcut anywhere to search, preview, pin, label, reorder favorites, and paste straight into your active app."
    let featureTips = [
        "Use ↑ / ↓ and Return to paste without touching your mouse, or Esc to dismiss.",
        "Press →, Space, or ⌘ I (or click the eye icon) to inspect full text or an image; ← or Esc returns to the list.",
        "Use the All, Text, Images, and Pinned filters to narrow history; image search also matches dimensions and file size.",
        "Press ⌘ P to pin/unpin, ⌘ R to name or rename an item, and ⌫ (with confirmation) to delete.",
        "Drag pinned items (or press ⌘ ↑ / ⌘ ↓) to reorder them; the saved order drives ⌘ 1–9 quick paste.",
        "Right-click any item in the dropdown to view all actions and their keyboard shortcuts.",
        "Images are stored locally as PNGs with compact thumbnails; use Save As in the image inspector to export a copy.",
        "Pinned items, their custom names, and their order are saved across restarts in ~/.config/toolbox/pinned_clipboard.json."
    ]
    let symbolName = "doc.on.clipboard"
    let accentColor = Color.teal
    let category: ModuleCategory = .productivity
    let requiresAccessibility = false
    let accessibilityReason = "Optional: required only if you enable auto-pasting (⌘ V) after picking an item."

    private(set) var isRunning = false
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var imageDiskUsage: Int64 = 0

    let hotKeyName = "clipboard.toggle"
    private var config = ClipboardConfig()
    private var pollTimer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var latestCapturedChangeCount: Int = -1
    private lazy var imageStore = ClipboardImageStore(
        directoryURL: ConfigManager.shared.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("clipboard-images", isDirectory: true)
    )
    private(set) var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private weak var previousApp: NSRunningApplication?
    let popoverState = ClipboardPopoverUIState()

    private var pinnedStorageURL: URL {
        ConfigManager.shared.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("pinned_clipboard.json")
    }

    private var historyStorageURL: URL {
        ConfigManager.shared.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("clipboard_history.json")
    }

    var isPopoverVisible: Bool {
        panel?.isVisible ?? false
    }

    private static let concealedTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    ]

    override init() {
        super.init()
        let clipboardConfig = ConfigManager.shared.config.clipboard
        self.config = clipboardConfig
        loadPinnedEntries()
        if clipboardConfig.persistHistory {
            loadUnpinnedHistory()
        } else {
            removeUnpinnedHistoryFile()
        }
        pruneMissingImageEntries()
        sweepOrphanedImageFiles()
        refreshImageDiskUsage()
    }

    func isEnabled(in config: ToolboxConfig) -> Bool {
        config.clipboard.enabled
    }

    func setEnabled(_ enabled: Bool, in config: inout ToolboxConfig) {
        config.clipboard.enabled = enabled
    }

    func shortcutText(in config: ToolboxConfig) -> String? {
        config.clipboard.shortcut.isEmpty ? nil : config.clipboard.shortcut.displayString
    }

    func reload(with fullConfig: ToolboxConfig) {
        let previousPersist = config.persistHistory
        let previousMaxItems = config.maxItems
        self.config = fullConfig.clipboard
        trimHistoryIfNeeded()

        if !config.persistHistory {
            purgeUnpinnedImages()
            removeUnpinnedHistoryFile()
        } else if !previousPersist || config.maxItems != previousMaxItems {
            saveUnpinnedHistory()
        }
        refreshImageDiskUsage()

        if config.enabled {
            if !isRunning {
                start()
            } else {
                restartPollTimer()
                registerHotKey()
            }
        } else {
            if isRunning { stop() }
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastChangeCount = NSPasteboard.general.changeCount
        captureCurrentPasteboardIfNeeded()
        restartPollTimer()
        registerHotKey()
    }

    func stop() {
        latestCapturedChangeCount = -1
        pollTimer?.invalidate()
        pollTimer = nil
        HotKeyManager.shared.unregister(name: hotKeyName)
        hidePopover()
        isRunning = false
        if !config.persistHistory {
            purgeUnpinnedImages()
        }
    }

    func togglePin(_ entry: ClipboardEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        if entries[idx].isPinned {
            entries[idx].isPinned = false
            entries[idx].customTitle = nil
        } else {
            // Newly pinned items land at the top of the pinned group; the rest shift down.
            entries[idx].isPinned = true
            entries[idx].sortIndex = 0
            for i in entries.indices where entries[i].isPinned && entries[i].id != entry.id {
                entries[i].sortIndex += 1
            }
        }
        trimHistoryIfNeeded()
        renumberPinnedEntries()
        saveAllStoredEntries()
    }

    /// Moves a pinned item one slot up (-1) or down (+1) within the pinned group
    /// (backing the ⌘ ↑ / ⌘ ↓ dropdown shortcuts and context menu). No-op for unpinned items.
    func movePinnedEntry(_ entry: ClipboardEntry, by delta: Int, within visible: [ClipboardEntry]? = nil) {
        let pinned = (visible ?? entries).filter(\.isPinned)
        guard delta != 0,
              let pos = pinned.firstIndex(where: { $0.id == entry.id }) else { return }
        let targetPos = pos + delta
        guard targetPos >= 0, targetPos < pinned.count else { return }
        movePinnedEntry(entry.id, relativeTo: pinned[targetPos].id, insertAfter: delta > 0)
    }

    /// Moves a pinned item relative to a target row (backing drag-to-reorder and
    /// keyboard/menu moves): `insertAfter` places it directly after the target,
    /// otherwise directly before. No-op if the item is already at that exact slot.
    func movePinnedEntry(_ draggedID: UUID, relativeTo targetID: UUID, insertAfter: Bool) {
        guard draggedID != targetID,
              let dIdx = entries.firstIndex(where: { $0.id == draggedID }),
              let tIdx = entries.firstIndex(where: { $0.id == targetID }),
              entries[dIdx].isPinned,
              entries[tIdx].isPinned else { return }
        let targetAfterRemoval = tIdx > dIdx ? tIdx - 1 : tIdx
        let destination = insertAfter ? targetAfterRemoval + 1 : targetAfterRemoval
        guard destination != dIdx else { return }
        let moved = entries.remove(at: dIdx)
        entries.insert(moved, at: destination)
        renumberPinnedEntries()
        trimHistoryIfNeeded()
        saveAllStoredEntries()
    }

    /// Keeps pinned `sortIndex` values dense (0, 1, 2, …) in current display order.
    private func renumberPinnedEntries() {
        var order = 0
        for i in entries.indices where entries[i].isPinned {
            entries[i].sortIndex = order
            order += 1
        }
    }

    func renameEntry(_ entry: ClipboardEntry, title: String) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[idx].customTitle = cleaned.isEmpty ? nil : cleaned
        if !entries[idx].isPinned {
            entries[idx].isPinned = true
            entries[idx].sortIndex = 0
            for i in entries.indices where entries[i].isPinned && entries[i].id != entry.id {
                entries[i].sortIndex += 1
            }
        }
        trimHistoryIfNeeded()
        renumberPinnedEntries()
        saveAllStoredEntries()
    }

    func deleteEntry(_ entry: ClipboardEntry) {
        let removed = entries.filter { $0.id == entry.id }
        entries.removeAll { $0.id == entry.id }
        renumberPinnedEntries()
        deleteUnreferencedImages(from: removed)
        saveAllStoredEntries()
        refreshImageDiskUsage()
    }

    func clearHistory(keepPinned: Bool = true) {
        let removed = entries.filter { keepPinned ? !$0.isPinned : true }
        if keepPinned {
            entries.removeAll { !$0.isPinned }
        } else {
            entries.removeAll()
        }
        renumberPinnedEntries()
        deleteUnreferencedImages(from: removed)
        saveAllStoredEntries()
        refreshImageDiskUsage()
    }

    func clearImageCache(keepPinned: Bool) {
        let removed = entries.filter { $0.kind == .image && (keepPinned ? !$0.isPinned : true) }
        if !removed.isEmpty {
            entries.removeAll { $0.kind == .image && (keepPinned ? !$0.isPinned : true) }
            renumberPinnedEntries()
            deleteUnreferencedImages(from: removed)
            saveAllStoredEntries()
        }
        sweepOrphanedImageFiles()
        refreshImageDiskUsage()
    }

    private func purgeUnpinnedImages() {
        let removed = entries.filter { $0.kind == .image && !$0.isPinned }
        if !removed.isEmpty {
            entries.removeAll { $0.kind == .image && !$0.isPinned }
            deleteUnreferencedImages(from: removed)
        }
        sweepOrphanedImageFiles()
        refreshImageDiskUsage()
    }

    func togglePopover() {
        if let panel, panel.isVisible {
            hidePopover()
            return
        }
        showPopover()
    }

    func hidePopover() {
        popoverState.cancelActiveDrag()
        popoverState.releaseInspectorImage()
        popoverState.hoveredEntryID = nil
        panel?.orderOut(nil)
        removePopoverMonitors()
    }

    func makeSettingsView() -> AnyView {
        AnyView(ClipboardSettingsView(module: self))
    }

    /// Exposed internally for unit testing capture/dedup/trim rules without requiring the system pasteboard.
    func recordText(_ rawText: String, pasteboardTypes: [NSPasteboard.PasteboardType] = []) {
        if config.ignoreConcealedTypes {
            if pasteboardTypes.contains(where: { Self.concealedTypes.contains($0) }) {
                return
            }
        }

        let text = rawText.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }

        var preservedPin = false
        var preservedTitle: String?
        var preservedSortIndex = 0
        if config.deduplicate {
            if let existing = entries.first(where: { $0.kind == .text && $0.text == text }) {
                preservedPin = existing.isPinned
                preservedTitle = existing.customTitle
                // Keep the user's explicit pinned slot — re-copying a pinned item
                // must not shuffle the pinned group it was ordered into.
                preservedSortIndex = existing.sortIndex
            }
            entries.removeAll { $0.kind == .text && $0.text == text }
        }

        entries.insert(
            ClipboardEntry(text: text, copiedAt: Date(), isPinned: preservedPin, customTitle: preservedTitle, sortIndex: preservedSortIndex),
            at: 0
        )
        trimHistoryIfNeeded()
        if preservedPin {
            savePinnedEntries()
        }
        saveUnpinnedHistory()
    }

    /// Called on the main actor after image normalization and hashing finish off-thread.
    func recordImage(_ metadata: ClipboardImageMetadata) {
        var storedMetadata = metadata
        var preservedPin = false
        var preservedTitle: String?
        var preservedSortIndex = 0

        if config.deduplicate,
           let existing = entries.first(where: { $0.image?.sha256 == metadata.sha256 }),
           let existingMetadata = existing.image {
            preservedPin = existing.isPinned
            preservedTitle = existing.customTitle
            preservedSortIndex = existing.sortIndex
            storedMetadata = existingMetadata
            entries.removeAll { $0.id == existing.id }
            if existingMetadata.filename != metadata.filename {
                imageStore.deleteImage(metadata)
            }
        }

        let label = "Image \(storedMetadata.pixelWidth) × \(storedMetadata.pixelHeight)"
        entries.insert(
            ClipboardEntry(
                text: label,
                copiedAt: Date(),
                isPinned: preservedPin,
                customTitle: preservedTitle,
                sortIndex: preservedSortIndex,
                kind: .image,
                image: storedMetadata
            ),
            at: 0
        )
        trimHistoryIfNeeded()
        if preservedPin {
            savePinnedEntries()
        }
        saveUnpinnedHistory()
        refreshImageDiskUsage()
    }

    private func containsSameContent(as item: ClipboardEntry) -> Bool {
        entries.contains { existing in
            if item.kind == .image {
                return existing.kind == .image && existing.image?.sha256 == item.image?.sha256
            }
            return existing.kind == .text && existing.text == item.text
        }
    }

    private func loadPinnedEntries() {
        guard FileManager.default.fileExists(atPath: pinnedStorageURL.path),
              let data = try? Data(contentsOf: pinnedStorageURL),
              let saved = try? JSONDecoder().decode([ClipboardEntry].self, from: data) else {
            return
        }
        for item in saved where !containsSameContent(as: item) {
            var pinnedItem = item
            pinnedItem.isPinned = true
            entries.append(pinnedItem)
        }
        trimHistoryIfNeeded()
        renumberPinnedEntries()
    }

    private func loadUnpinnedHistory() {
        guard FileManager.default.fileExists(atPath: historyStorageURL.path),
              let data = try? Data(contentsOf: historyStorageURL),
              let saved = try? JSONDecoder().decode([ClipboardEntry].self, from: data) else {
            return
        }
        for item in saved where !containsSameContent(as: item) {
            var historyItem = item
            historyItem.isPinned = false
            historyItem.customTitle = nil
            entries.append(historyItem)
        }
        trimHistoryIfNeeded()
    }

    private func saveAllStoredEntries() {
        savePinnedEntries()
        saveUnpinnedHistory()
    }

    private func savePinnedEntries() {
        let pinned = entries.filter(\.isPinned)
        guard let data = try? JSONEncoder().encode(pinned) else { return }
        try? data.write(to: pinnedStorageURL, options: .atomic)
    }

    private func saveUnpinnedHistory() {
        guard config.persistHistory else {
            removeUnpinnedHistoryFile()
            return
        }
        let unpinned = entries.filter { !$0.isPinned }
        if unpinned.isEmpty {
            removeUnpinnedHistoryFile()
            return
        }
        guard let data = try? JSONEncoder().encode(unpinned) else { return }
        try? data.write(to: historyStorageURL, options: .atomic)
    }

    private func removeUnpinnedHistoryFile() {
        if FileManager.default.fileExists(atPath: historyStorageURL.path) {
            try? FileManager.default.removeItem(at: historyStorageURL)
        }
    }

    private func registerHotKey() {
        HotKeyManager.shared.register(name: hotKeyName, shortcut: config.shortcut) { [weak self] in
            self?.togglePopover()
        }
    }

    private func restartPollTimer() {
        pollTimer?.invalidate()
        let interval = max(0.1, Double(config.pollIntervalMs) / 1000.0)
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboard()
            }
        }
    }

    private func checkPasteboard() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount
        captureCurrentPasteboardIfNeeded()
    }

    static func classifyPasteboard(
        types: [NSPasteboard.PasteboardType],
        text: String?,
        captureImages: Bool = true,
        ignoreConcealedTypes: Bool = true
    ) -> ClipboardPasteboardClassification {
        if ignoreConcealedTypes && types.contains(where: { concealedTypes.contains($0) }) {
            return .ignored
        }
        // Finder places a file icon TIFF beside file URLs; that icon is not an image clip.
        // Preserve a real string representation if the source app provides one.
        if types.contains(.fileURL) {
            if let text, !text.isEmpty {
                return .text
            }
            return .ignored
        }
        // Rich text often includes a rendered TIFF preview. Prefer the actual text.
        if let text, !text.isEmpty {
            return .text
        }
        guard captureImages else { return .ignored }
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            .tiff
        ]
        for type in imageTypes where types.contains(type) {
            return .image(type)
        }
        return .ignored
    }

    static func isImagePayloadAllowed(byteCount: Int, maxImageSizeMB: Int) -> Bool {
        let limitMB = max(1, maxImageSizeMB)
        guard limitMB <= Int.max / (1024 * 1024) else { return true }
        return byteCount <= limitMB * 1024 * 1024
    }

    private func captureCurrentPasteboardIfNeeded() {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        let text = pb.string(forType: .string)
        let changeCount = lastChangeCount
        latestCapturedChangeCount = changeCount

        switch Self.classifyPasteboard(
            types: types,
            text: text,
            captureImages: config.captureImages,
            ignoreConcealedTypes: config.ignoreConcealedTypes
        ) {
        case .ignored:
            return
        case .text:
            if let text {
                recordText(text, pasteboardTypes: types)
            }
        case .image(let type):
            guard let data = pb.data(forType: type),
                  Self.isImagePayloadAllowed(byteCount: data.count, maxImageSizeMB: config.maxImageSizeMB) else {
                return
            }
            let store = imageStore
            Task.detached(priority: .utility) { [weak self] in
                guard let metadata = try? store.saveImage(data: data) else { return }
                await MainActor.run {
                    guard let self else {
                        store.deleteImage(metadata)
                        return
                    }
                    guard self.latestCapturedChangeCount == changeCount,
                          self.config.captureImages else {
                        store.deleteImage(metadata)
                        return
                    }
                    self.recordImage(metadata)
                }
            }
        }
    }

    private func trimHistoryIfNeeded() {
        let previousEntries = entries
        let pinned = entries.filter(\.isPinned)
        let unpinned = entries.filter { !$0.isPinned }
        let allowedUnpinned = max(0, config.maxItems - pinned.count)
        var imageCount = 0
        let keptUnpinned = unpinned.prefix(allowedUnpinned).filter { entry in
            guard entry.kind == .image else { return true }
            imageCount += 1
            return imageCount <= max(1, config.maxImageItems)
        }
        let combined = pinned + keptUnpinned
        entries = combined.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.isPinned {
                // User-ordered pinned group; copiedAt only breaks sortIndex ties
                // (e.g. legacy files that predate manual ordering).
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.copiedAt > rhs.copiedAt
            }
            return lhs.copiedAt > rhs.copiedAt
        }
        let keptIDs = Set(entries.map(\.id))
        let removedEntries = previousEntries.filter { !keptIDs.contains($0.id) }
        deleteUnreferencedImages(from: removedEntries)
        if removedEntries.contains(where: { $0.kind == .image }) {
            refreshImageDiskUsage()
        }
    }

    private func deleteUnreferencedImages(from removedEntries: [ClipboardEntry]) {
        for entry in removedEntries {
            guard let metadata = entry.image else { continue }
            let stillReferenced = entries.contains { $0.image?.filename == metadata.filename }
            if !stillReferenced {
                imageStore.deleteImage(metadata)
            }
        }
    }

    private func pruneMissingImageEntries() {
        entries.removeAll { entry in
            guard entry.kind == .image else { return false }
            guard let metadata = entry.image else { return true }
            return !FileManager.default.fileExists(atPath: imageStore.fullImageURL(for: metadata).path)
        }
    }

    private func sweepOrphanedImageFiles() {
        let referenced = Set(entries.flatMap { entry -> [String] in
            guard let metadata = entry.image else { return [] }
            return [metadata.filename, metadata.thumbnailFilename]
        })
        imageStore.sweepOrphanedFiles(referencedFilenames: referenced)
    }

    func thumbnail(for entry: ClipboardEntry) -> NSImage? {
        guard let metadata = entry.image else { return nil }
        return imageStore.thumbnail(for: metadata)
    }

    func fullImage(for entry: ClipboardEntry) -> NSImage? {
        guard let metadata = entry.image else { return nil }
        return imageStore.fullImage(for: metadata)
    }

    func refreshImageDiskUsage() {
        imageDiskUsage = imageStore.diskUsage()
    }

    func showPopover() {
        previousApp = NSWorkspace.shared.frontmostApplication
        popoverState.resetForOpen(entries: entries)

        let width = CGFloat(max(320, min(680, config.popoverWidth)))
        let height = CGFloat(max(260, min(720, config.popoverHeight)))
        let panel = ensurePanel(width: width, height: height)

        let mouseLocation = NSEvent.mouseLocation
        var origin = NSPoint(x: mouseLocation.x - width / 2, y: mouseLocation.y - height - 14)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - height - 8)
        }

        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.focusFirstEditableTextField()
        installPopoverMonitors(for: panel)
        DispatchQueue.main.async { [weak panel] in
            if let panel, panel.isVisible {
                panel.focusFirstEditableTextField()
                PointerCursorNSView.syncCursor(in: panel)
            }
        }
    }

    @discardableResult
    func ensurePanel(width: CGFloat = 420, height: CGFloat = 460) -> NSPanel {
        if let panel { return panel }

        let newPanel = PointerCursorNSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        newPanel.level = .popUpMenu
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isMovableByWindowBackground = true
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.hidesOnDeactivate = false
        newPanel.acceptsMouseMovedEvents = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        ToolboxTheme.applyDarkAppearance(to: newPanel)

        let contentView = ClipboardPopoverView(
            module: self,
            uiState: popoverState,
            onSelect: { [weak self] entry in
                self?.selectAndPaste(entry)
            },
            onClose: { [weak self] in
                self?.hidePopover()
            }
        )

        newPanel.contentView = PointerCursorHostingView(rootView: contentView)
        self.panel = newPanel
        return newPanel
    }

    private func activeEntryForAction(in visible: [ClipboardEntry]) -> ClipboardEntry? {
        if let previewID = popoverState.previewEntryID,
           let previewed = visible.first(where: { $0.id == previewID }) ?? entries.first(where: { $0.id == previewID }) {
            return previewed
        }
        return popoverState.selectedEntry(in: visible)
    }

    private func filteredEntriesForNavigation() -> [ClipboardEntry] {
        entries.filter { $0.matches(query: popoverState.query, filter: popoverState.filter) }
    }

    private func installPopoverMonitors(for panel: NSPanel) {
        removePopoverMonitors()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] _ in
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel, panel.isVisible else { return }
                let clickLoc = NSEvent.mouseLocation
                if !panel.frame.contains(clickLoc) {
                    self.hidePopover()
                }
            }
        }

        // Also close on clicks inside Toolbox's own windows (global monitors ignore in-app clicks).
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }
            if let window = event.window,
               window !== panel,
               !NSStringFromClass(type(of: window)).contains("Menu"),
               !panel.frame.contains(NSEvent.mouseLocation) {
                self.hidePopover()
            }
            return event
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }

            // Let inline rename TextField receive normal keys except Escape
            if self.popoverState.renamingEntryID != nil {
                if event.keyCode == 53 {
                    self.popoverState.renamingEntryID = nil
                    return nil
                }
                return event
            }

            let visible = self.filteredEntriesForNavigation()

            // Confirmation dialog intercepts Return/Enter and Escape
            if self.popoverState.pendingDeleteEntry != nil || self.popoverState.pendingClearAll {
                switch event.keyCode {
                case 53: // Escape
                    self.popoverState.pendingDeleteEntry = nil
                    self.popoverState.pendingClearAll = false
                    return nil
                case 36, 76: // Return / Keypad Enter
                    if let entry = self.popoverState.pendingDeleteEntry {
                        let targetIndex = visible.firstIndex(where: { $0.id == entry.id })
                        self.deleteEntry(entry)
                        if self.popoverState.previewEntryID == entry.id {
                            self.popoverState.previewEntryID = nil
                        }
                        self.popoverState.pendingDeleteEntry = nil
                        if self.popoverState.selectedEntryID == entry.id {
                            if let targetIndex {
                                if targetIndex + 1 < visible.count {
                                    self.popoverState.selectedEntryID = visible[targetIndex + 1].id
                                } else if targetIndex > 0 {
                                    self.popoverState.selectedEntryID = visible[targetIndex - 1].id
                                } else {
                                    self.popoverState.selectedEntryID = nil
                                }
                            } else {
                                let remaining = self.filteredEntriesForNavigation()
                                self.popoverState.selectedEntryID = remaining.first?.id
                            }
                        }
                    } else if self.popoverState.pendingClearAll {
                        self.clearHistory(keepPinned: true)
                        self.popoverState.previewEntryID = nil
                        self.popoverState.pendingClearAll = false
                        let remaining = self.filteredEntriesForNavigation()
                        self.popoverState.selectedEntryID = remaining.first?.id
                    }
                    return nil
                default:
                    return nil
                }
            }

            let isEditingSearch = panel.firstResponder is NSTextView
            let hasCommand = event.modifierFlags.contains(.command)
            let activeModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

            if activeModifiers == .command {
                let quickPasteKeyCodes: [UInt16] = [
                    UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3),
                    UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6),
                    UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9)
                ]
                if let slotIndex = quickPasteKeyCodes.firstIndex(of: event.keyCode),
                   slotIndex < visible.count {
                    self.selectAndPaste(visible[slotIndex])
                    return nil
                }
            }

            switch event.keyCode {
            case 53: // Escape
                if self.popoverState.isDragging {
                    self.popoverState.cancelActiveDrag()
                    return nil
                }
                if let previewID = self.popoverState.previewEntryID {
                    if visible.contains(where: { $0.id == previewID }) {
                        self.popoverState.selectedEntryID = previewID
                    }
                    self.popoverState.previewEntryID = nil
                } else {
                    self.hidePopover()
                }
                return nil
            case 125 where hasCommand, 126 where hasCommand: // ⌘ ↓ / ⌘ ↑ move the active pinned item
                if let target = self.activeEntryForAction(in: visible), target.isPinned {
                    self.movePinnedEntry(target, by: event.keyCode == 126 ? -1 : 1, within: visible)
                }
                return nil
            case 125: // Down Arrow
                if self.popoverState.previewEntryID == nil {
                    self.popoverState.moveSelection(delta: 1, in: visible)
                }
                return nil
            case 126: // Up Arrow
                if self.popoverState.previewEntryID == nil {
                    self.popoverState.moveSelection(delta: -1, in: visible)
                }
                return nil
            case 124: // Right Arrow -> open detail preview
                if !isEditingSearch || self.popoverState.query.isEmpty {
                    if self.popoverState.previewEntryID == nil,
                       let entry = self.popoverState.selectedEntry(in: visible) {
                        self.popoverState.selectedEntryID = entry.id
                        self.popoverState.previewEntryID = entry.id
                    }
                    return nil
                }
                return event
            case 123: // Left Arrow -> close detail preview
                if let previewID = self.popoverState.previewEntryID {
                    if visible.contains(where: { $0.id == previewID }) {
                        self.popoverState.selectedEntryID = previewID
                    }
                    self.popoverState.previewEntryID = nil
                    return nil
                }
                if !isEditingSearch || self.popoverState.query.isEmpty {
                    return nil
                }
                return event
            case 49: // Space -> toggle detail preview when search query is empty or search is unfocused
                if !isEditingSearch || self.popoverState.query.isEmpty {
                    if let previewID = self.popoverState.previewEntryID {
                        if visible.contains(where: { $0.id == previewID }) {
                            self.popoverState.selectedEntryID = previewID
                        }
                        self.popoverState.previewEntryID = nil
                    } else if let entry = self.popoverState.selectedEntry(in: visible) {
                        self.popoverState.selectedEntryID = entry.id
                        self.popoverState.previewEntryID = entry.id
                    }
                    return nil
                }
                return event
            case 34: // Cmd+I -> toggle detail preview anytime
                if hasCommand {
                    if let previewID = self.popoverState.previewEntryID {
                        if visible.contains(where: { $0.id == previewID }) {
                            self.popoverState.selectedEntryID = previewID
                        }
                        self.popoverState.previewEntryID = nil
                    } else if let entry = self.popoverState.selectedEntry(in: visible) {
                        self.popoverState.selectedEntryID = entry.id
                        self.popoverState.previewEntryID = entry.id
                    }
                    return nil
                }
                return event
            case 35: // Cmd+P -> toggle pin on highlighted/previewed item
                if hasCommand, let target = self.activeEntryForAction(in: visible) {
                    self.togglePin(target)
                    return nil
                }
                return event
            case 15: // Cmd+R -> name or rename highlighted/previewed item
                if hasCommand, let target = self.activeEntryForAction(in: visible) {
                    self.popoverState.previewEntryID = nil
                    self.popoverState.selectedEntryID = target.id
                    self.popoverState.renameDraft = target.customTitle ?? ""
                    self.popoverState.renamingEntryID = target.id
                    return nil
                }
                return event
            case 51, 117: // Backspace / Forward Delete -> prompt delete confirmation
                if hasCommand || !isEditingSearch || self.popoverState.query.isEmpty {
                    if let target = self.activeEntryForAction(in: visible) {
                        self.popoverState.pendingDeleteEntry = target
                        return nil
                    }
                }
                return event
            case 36, 76: // Return / Keypad Enter
                if let entry = self.popoverState.selectedEntry(in: visible) {
                    self.selectAndPaste(entry)
                    return nil
                }
                return event
            default:
                if event.window !== panel {
                    return event
                }
                if !isEditingSearch && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                    return nil
                }
                return event
            }
        }
    }

    private func removePopoverMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    func selectAndPaste(_ entry: ClipboardEntry) {
        hidePopover()
        restoreAndOptionallyPaste(entry, shouldPaste: config.pasteAutomatically, activatePreviousApp: true)
    }

    func copyEntry(_ entry: ClipboardEntry) {
        restoreAndOptionallyPaste(entry, shouldPaste: false, activatePreviousApp: false)
    }

    private func restoreAndOptionallyPaste(
        _ entry: ClipboardEntry,
        shouldPaste: Bool,
        activatePreviousApp: Bool
    ) {
        let pb = NSPasteboard.general
        let imagePNGData: Data?
        if entry.kind == .image, let metadata = entry.image {
            guard let data = try? Data(contentsOf: imageStore.fullImageURL(for: metadata)) else {
                HUDToast.shared.show(title: "Image file is missing", symbol: "exclamationmark.triangle", tint: .orange)
                return
            }
            imagePNGData = data
        } else {
            imagePNGData = nil
        }

        pb.clearContents()
        if let imagePNGData {
            pb.setData(imagePNGData, forType: .png)
            if let image = NSImage(data: imagePNGData), let tiffData = image.tiffRepresentation {
                pb.setData(tiffData, forType: .tiff)
            }
        } else {
            pb.setString(entry.text, forType: .string)
        }

        lastChangeCount = pb.changeCount
        latestCapturedChangeCount = lastChangeCount
        let isImage = entry.kind == .image

        if activatePreviousApp,
           let prev = previousApp,
           prev.bundleIdentifier != Bundle.main.bundleIdentifier {
            prev.activate()
        }

        guard shouldPaste else {
            HUDToast.shared.show(
                title: isImage ? "Copied image to clipboard" : "Copied to clipboard",
                symbol: isImage ? "photo" : "doc.on.clipboard"
            )
            return
        }

        guard PermissionsManager.isProcessTrusted() else {
            HUDToast.shared.show(title: "Copied (grant Accessibility for auto-paste)", symbol: "doc.on.clipboard", tint: .orange)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .hidSystemState)
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            vDown?.flags = .maskCommand
            vUp?.flags = .maskCommand
            vDown?.setIntegerValueField(.eventSourceUserData, value: HyperKeyStateMachine.syntheticEventTag)
            vUp?.setIntegerValueField(.eventSourceUserData, value: HyperKeyStateMachine.syntheticEventTag)
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
        }
    }

    func saveImageAs(_ entry: ClipboardEntry) {
        guard let metadata = entry.image else { return }
        let sourceURL = imageStore.fullImageURL(for: metadata)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            HUDToast.shared.show(title: "Image file is missing", symbol: "exclamationmark.triangle", tint: .orange)
            return
        }

        let savePanel = NSSavePanel()
        hidePopover()
        savePanel.allowedContentTypes = [.png]
        savePanel.canCreateDirectories = true
        let baseName = entry.customTitle?.isEmpty == false
            ? entry.customTitle!
            : "Image \(metadata.pixelWidth) × \(metadata.pixelHeight)"
        let safeName = baseName.replacingOccurrences(of: "/", with: "-")
        savePanel.nameFieldStringValue = "\(safeName).png"
        NSApp.activate()
        savePanel.begin { response in
            guard response == .OK, let destinationURL = savePanel.url else { return }
            do {
                let data = try Data(contentsOf: sourceURL)
                try data.write(to: destinationURL, options: .atomic)
                HUDToast.shared.show(title: "Image saved", symbol: "checkmark.circle")
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
}
