import Foundation

/// Source module / subsystem category for live Developer Console trace events.
enum DeveloperEventCategory: String, CaseIterable, Identifiable, Sendable {
    case dock = "Dock"
    case scroll = "Scroll"
    case hotkeys = "HotKeys"
    case keepAwake = "Keep Awake"
    case cleanLock = "Keyboard Lock"
    case callControls = "Call Controls"
    case windowSnapper = "Window Snapper"
    case finderEnhancer = "Finder Enhancer"
    case windowSwitcher = "Window Switcher"
    case ocr = "Screen OCR"
    case config = "Config"
    case updates = "Updates"

    var id: String { rawValue }
}

/// Single timestamped entry recorded into the in-memory developer trace ring buffer.
struct DeveloperEventEntry: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let category: DeveloperEventCategory
    let message: String
    let detail: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: DeveloperEventCategory,
        message: String,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
        self.detail = detail
    }
}

/// Lightweight main-actor ring buffer capturing non-sensitive internal events for live debugging.
@MainActor
final class DeveloperEventLog: ObservableObject {
    static let shared = DeveloperEventLog()
    static let maxEntries = 150

    @Published private(set) var entries: [DeveloperEventEntry] = []

    private init() {}

    func record(
        _ category: DeveloperEventCategory,
        _ message: String,
        detail: String? = nil
    ) {
        let entry = DeveloperEventEntry(
            category: category,
            message: message,
            detail: detail
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    func filteredEntries(
        category: DeveloperEventCategory?,
        query: String
    ) -> [DeveloperEventEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            if let category, entry.category != category {
                return false
            }
            guard !trimmed.isEmpty else { return true }
            return entry.message.lowercased().contains(trimmed)
                || (entry.detail?.lowercased().contains(trimmed) ?? false)
                || entry.category.rawValue.lowercased().contains(trimmed)
        }
    }

    func formattedExport(
        category: DeveloperEventCategory?,
        query: String
    ) -> String {
        let rows = filteredEntries(category: category, query: query)
        if rows.isEmpty {
            return "Toolbox Event Log (0 matching entries)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        var lines: [String] = ["Toolbox Event Log (\(rows.count) entries, newest first)"]
        for row in rows {
            let ts = formatter.string(from: row.timestamp)
            if let detail = row.detail, !detail.isEmpty {
                lines.append("[\(ts)] [\(row.category.rawValue)] \(row.message) — \(detail)")
            } else {
                lines.append("[\(ts)] [\(row.category.rawValue)] \(row.message)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
