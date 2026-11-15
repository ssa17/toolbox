import AppKit
import SwiftUI

private enum JSONEditorMode: String, CaseIterable, Identifiable {
    case tree = "Tree"
    case raw = "Raw JSON"
    var id: String { rawValue }
}

private enum JSONDepthPalette {
    static let nsColors: [NSColor] = [
        NSColor(calibratedRed: 0.36, green: 0.78, blue: 1.00, alpha: 1.0), // Level 0: Sky Cyan
        NSColor(calibratedRed: 0.52, green: 0.62, blue: 1.00, alpha: 1.0), // Level 1: Periwinkle Blue
        NSColor(calibratedRed: 0.78, green: 0.56, blue: 1.00, alpha: 1.0), // Level 2: Soft Lavender
        NSColor(calibratedRed: 0.27, green: 0.84, blue: 0.78, alpha: 1.0), // Level 3: Aqua Teal
        NSColor(calibratedRed: 1.00, green: 0.64, blue: 0.45, alpha: 1.0)  // Level 4: Soft Peach
    ]
    static let swiftUIColors: [Color] = nsColors.map { Color(nsColor: $0) }

    static let nsStringColor = NSColor(calibratedRed: 0.44, green: 0.86, blue: 0.58, alpha: 1.0)
    static let nsNumberColor = NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.34, alpha: 1.0)
    static let nsBoolColor = NSColor(calibratedRed: 0.96, green: 0.48, blue: 0.60, alpha: 1.0)

    static let stringColor = Color(nsColor: nsStringColor)
    static let numberColor = Color(nsColor: nsNumberColor)
    static let boolColor = Color(nsColor: nsBoolColor)

    static func color(for depth: Int) -> Color {
        swiftUIColors[max(0, depth) % swiftUIColors.count]
    }

    static func nsColor(for depth: Int) -> NSColor {
        nsColors[max(0, depth) % nsColors.count]
    }
}

@MainActor
private final class ConfigEditorState: ObservableObject {
    @Published var text: String = ""
    @Published var savedText: String = ""
    @Published var statusMessage: String?
    @Published var formatError: String?
    @Published var showResetConfirmation = false
    @Published var mode: JSONEditorMode = .raw
    @Published var collapsedPaths: Set<String> = []
    @Published var editingPath: String?
    @Published var editDraft: String = ""

    var hasUnsavedChanges: Bool {
        text != savedText
    }

    func syncFromManager() {
        let formatted = ConfigManager.shared.formattedJSON()
        text = formatted
        savedText = formatted
        formatError = nil
        editingPath = nil
    }

    func markSaved() {
        savedText = text
        editingPath = nil
    }
}

struct ConfigEditorView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @StateObject private var editorState = ConfigEditorState()

    private var parsedRoot: Any? {
        guard let data = editorState.text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("JSON Configuration")
                            .font(.title3.bold())
                            .lineLimit(1)
                        if editorState.hasUnsavedChanges {
                            StatusBadge(text: "Unsaved changes", color: .orange)
                        } else {
                            StatusBadge(text: "Synced", color: .green)
                        }
                        Spacer()
                        Picker("", selection: $editorState.mode) {
                            ForEach(JSONEditorMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 170)
                        .pointerCursor()
                    }

                    HStack(spacing: 10) {
                        Text("Live-synced with \(configManager.configURL.path).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Open in Editor") {
                            NSWorkspace.shared.open(configManager.configURL)
                        }
                        .controlSize(.small)
                        .pointerCursor()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([configManager.configURL])
                        }
                        .controlSize(.small)
                        .pointerCursor()
                    }
                }
            }

            if let err = editorState.formatError ?? configManager.lastConfigError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(10)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else if let status = editorState.statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(status)
                        .font(.caption)
                    Spacer()
                }
                .padding(10)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            Group {
                if editorState.mode == .tree {
                    if let root = parsedRoot {
                        JSONTreeEditorView(root: root, editorState: editorState)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            Text("JSON has syntax errors. Switch to Raw JSON to fix them.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Switch to Raw JSON") {
                                editorState.mode = .raw
                            }
                            .buttonStyle(.borderedProminent)
                            .pointerCursor()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    SyntaxHighlightedJSONView(text: $editorState.text)
                }
            }
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )

            HStack(spacing: 8) {
                Button("Apply & Save") {
                    editorState.formatError = nil
                    if configManager.applyRawJSON(editorState.text) {
                        editorState.syncFromManager()
                        editorState.statusMessage = "Saved and reloaded config.json"
                    } else {
                        editorState.statusMessage = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!editorState.hasUnsavedChanges)
                .help(editorState.hasUnsavedChanges ? "Apply & Save JSON (⌘S)" : "No unsaved changes")
                .pointerCursor(editorState.hasUnsavedChanges)

                if editorState.mode == .tree {
                    Button("Expand All") {
                        editorState.collapsedPaths.removeAll()
                    }
                    .buttonStyle(.bordered)
                    .pointerCursor()

                    Button("Collapse All") {
                        if let root = parsedRoot {
                            editorState.collapsedPaths = collectAllContainerPaths(node: root, path: "root")
                        }
                    }
                    .buttonStyle(.bordered)
                    .pointerCursor()
                } else {
                    Button("Format") {
                        do {
                            guard let data = editorState.text.data(using: .utf8) else {
                                editorState.formatError = "Invalid UTF-8 text"
                                editorState.statusMessage = nil
                                return
                            }
                            let obj = try JSONSerialization.jsonObject(with: data)
                            let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                            if let formatted = String(data: pretty, encoding: .utf8) {
                                editorState.formatError = nil
                                editorState.text = formatted
                                editorState.statusMessage = formatted == editorState.savedText ? nil : "Formatted JSON (not yet saved)"
                            }
                        } catch {
                            editorState.formatError = "Invalid JSON: \(error.localizedDescription)"
                            editorState.statusMessage = nil
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Pretty-print JSON in editor")
                    .pointerCursor()
                }

                Button("Reload") {
                    configManager.loadFromDisk()
                    editorState.syncFromManager()
                    editorState.statusMessage = "Reloaded from disk"
                }
                .buttonStyle(.bordered)
                .help("Reload from disk")
                .pointerCursor()

                Spacer()

                Button("Reset to Defaults", role: .destructive) {
                    editorState.showResetConfirmation = true
                }
                .buttonStyle(.bordered)
                .pointerCursor()
                .confirmationDialog(
                    "Reset all Toolbox settings to defaults?",
                    isPresented: $editorState.showResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset to Defaults", role: .destructive) {
                        configManager.resetToDefaults()
                        editorState.syncFromManager()
                        editorState.statusMessage = "Restored default settings"
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will overwrite custom commands, exclusions, shortcuts, and preferences.")
                }
            }
        }
        .padding(22)
        .onAppear {
            editorState.syncFromManager()
        }
        .onChange(of: configManager.lastReloadedAt, initial: false) { _, _ in
            if !editorState.hasUnsavedChanges {
                editorState.syncFromManager()
            }
        }
    }

    private func collectAllContainerPaths(node: Any, path: String) -> Set<String> {
        var result: Set<String> = []
        if let dict = node as? [String: Any] {
            if path != "root" { result.insert(path) }
            for (k, v) in dict {
                result.formUnion(collectAllContainerPaths(node: v, path: "\(path).\(k)"))
            }
        } else if let arr = node as? [Any] {
            if path != "root" { result.insert(path) }
            for (i, v) in arr.enumerated() {
                result.formUnion(collectAllContainerPaths(node: v, path: "\(path)[\(i)]"))
            }
        }
        return result
    }
}

// MARK: - Interactive Collapsible Tree View

private struct JSONTreeEditorView: View {
    let root: Any
    @ObservedObject var editorState: ConfigEditorState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if let dict = root as? [String: Any] {
                    let keys = dict.keys.sorted()
                    ForEach(keys, id: \.self) { key in
                        JSONTreeNodeView(
                            label: key,
                            value: dict[key] as Any,
                            path: "root.\(key)",
                            depth: 0,
                            keyPathComponents: [.key(key)],
                            editorState: editorState
                        )
                    }
                } else if let arr = root as? [Any] {
                    ForEach(Array(arr.enumerated()), id: \.offset) { idx, item in
                        JSONTreeNodeView(
                            label: "[\(idx)]",
                            value: item,
                            path: "root[\(idx)]",
                            depth: 0,
                            keyPathComponents: [.index(idx)],
                            editorState: editorState
                        )
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum JSONPathComponent: Hashable {
    case key(String)
    case index(Int)
}

private struct JSONTreeNodeView: View {
    let label: String
    let value: Any
    let path: String
    let depth: Int
    let keyPathComponents: [JSONPathComponent]
    @ObservedObject var editorState: ConfigEditorState

    private var levelColor: Color {
        JSONDepthPalette.color(for: depth)
    }

    private var isCollapsed: Bool {
        editorState.collapsedPaths.contains(path)
    }

    private var isContainer: Bool {
        value is [String: Any] || value is [Any]
    }

    private var formattedLabel: String {
        if case .index = keyPathComponents.last {
            return label
        }
        return "\"\(label)\""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if isContainer {
                    Button {
                        if isCollapsed {
                            editorState.collapsedPaths.remove(path)
                        } else {
                            editorState.collapsedPaths.insert(path)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(levelColor)
                                .frame(width: 12)
                            Text(formattedLabel)
                                .font(.system(.callout, design: .monospaced).weight(.semibold))
                                .foregroundStyle(levelColor)
                            Text(":")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                            containerBadge
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                } else {
                    Color.clear.frame(width: 12, height: 1)
                    Text(formattedLabel)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(levelColor)
                    Text(":")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                    leafValueView
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(
                depth == 0 && isContainer
                    ? levelColor.opacity(0.06)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )

            if !isCollapsed, isContainer {
                VStack(alignment: .leading, spacing: 2) {
                    if let dict = value as? [String: Any] {
                        let sortedKeys = dict.keys.sorted()
                        ForEach(sortedKeys, id: \.self) { childKey in
                            JSONTreeNodeView(
                                label: childKey,
                                value: dict[childKey] as Any,
                                path: "\(path).\(childKey)",
                                depth: depth + 1,
                                keyPathComponents: keyPathComponents + [.key(childKey)],
                                editorState: editorState
                            )
                        }
                    } else if let arr = value as? [Any] {
                        ForEach(Array(arr.enumerated()), id: \.offset) { idx, item in
                            JSONTreeNodeView(
                                label: "[\(idx)]",
                                value: item,
                                path: "\(path)[\(idx)]",
                                depth: depth + 1,
                                keyPathComponents: keyPathComponents + [.index(idx)],
                                editorState: editorState
                            )
                        }
                    }
                }
                .padding(.leading, 18)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(levelColor.opacity(0.32))
                        .frame(width: 1.5)
                        .padding(.leading, 11.25)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var containerBadge: some View {
        if let dict = value as? [String: Any] {
            Text(isCollapsed ? "{ \(dict.count) keys }" : "{ \(dict.count) }")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(levelColor.opacity(0.12), in: Capsule())
        } else if let arr = value as? [Any] {
            Text(isCollapsed ? "[ \(arr.count) items ]" : "[ \(arr.count) ]")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(levelColor.opacity(0.12), in: Capsule())
        }
    }

    @ViewBuilder
    private var leafValueView: some View {
        if let num = value as? NSNumber, CFGetTypeID(num) == CFBooleanGetTypeID() {
            let boolVal = num.boolValue
            Button {
                updateJSONValue(newValue: !boolVal)
            } label: {
                Text(boolVal ? "true" : "false")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(JSONDepthPalette.boolColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(JSONDepthPalette.boolColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Click to toggle boolean")
            .pointerCursor()
        } else if editorState.editingPath == path {
            HStack(spacing: 6) {
                TextField("", text: $editorState.editDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minWidth: 140, maxWidth: 320)
                    .onSubmit {
                        commitLeafEdit()
                    }
                Button("OK") {
                    commitLeafEdit()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .pointerCursor()
                Button("Cancel") {
                    editorState.editingPath = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .pointerCursor()
            }
        } else if let num = value as? NSNumber {
            Button {
                editorState.editDraft = num.stringValue
                editorState.editingPath = path
            } label: {
                Text(num.stringValue)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(JSONDepthPalette.numberColor)
            }
            .buttonStyle(.plain)
            .help("Click to edit number")
            .pointerCursor()
        } else if let str = value as? String {
            Button {
                editorState.editDraft = str
                editorState.editingPath = path
            } label: {
                Text("\"\(str)\"")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(JSONDepthPalette.stringColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Click to edit string")
            .pointerCursor()
        } else if value is NSNull {
            Text("null")
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(JSONDepthPalette.boolColor)
        } else {
            Text(String(describing: value))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func commitLeafEdit() {
        let draft = editorState.editDraft
        if value is NSNumber {
            if let intVal = Int(draft) {
                updateJSONValue(newValue: intVal)
            } else if let dblVal = Double(draft) {
                updateJSONValue(newValue: dblVal)
            }
        } else {
            updateJSONValue(newValue: draft)
        }
        editorState.editingPath = nil
    }

    private func updateJSONValue(newValue: Any) {
        guard let data = editorState.text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) else { return }

        let updated = setValue(in: root, path: keyPathComponents, to: newValue)
        if let outData = try? JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys]),
           let outStr = String(data: outData, encoding: .utf8) {
            editorState.text = outStr
            editorState.statusMessage = nil
        }
    }

    private func setValue(in node: Any, path: [JSONPathComponent], to newValue: Any) -> Any {
        guard let first = path.first else { return newValue }
        let rest = Array(path.dropFirst())
        switch first {
        case .key(let k):
            guard var dict = node as? [String: Any] else { return node }
            if rest.isEmpty {
                dict[k] = newValue
            } else if let child = dict[k] {
                dict[k] = setValue(in: child, path: rest, to: newValue)
            }
            return dict
        case .index(let idx):
            guard var arr = node as? [Any], idx >= 0, idx < arr.count else { return node }
            if rest.isEmpty {
                arr[idx] = newValue
            } else {
                arr[idx] = setValue(in: arr[idx], path: rest, to: newValue)
            }
            return arr
        }
    }
}

// MARK: - Raw JSON Editor with Indent Guides & Depth Colors

private final class JSONCodeTextView: NSTextView {
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let layoutManager, let textContainer else { return }
        let font = self.font ?? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let indentStep = spaceWidth * 2.0
        guard indentStep > 0 else { return }

        let origin = textContainerOrigin
        let source = string as NSString
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        var lineStart = visibleCharRange.location
        while lineStart < NSMaxRange(visibleCharRange) {
            let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
            var spaces = 0
            var idx = lineRange.location
            while idx < NSMaxRange(lineRange) {
                let ch = source.character(at: idx)
                if ch == 32 { // space
                    spaces += 1
                } else if ch == 9 { // tab
                    spaces += 2
                } else {
                    break
                }
                idx += 1
            }

            let levels = spaces / 2
            if levels > 1 {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, _, _ in
                    for level in 1..<levels {
                        let x = floor(origin.x + textContainer.lineFragmentPadding + CGFloat(level) * indentStep) + 0.5
                        JSONDepthPalette.nsColor(for: level - 1).withAlphaComponent(0.32).setStroke()
                        let path = NSBezierPath()
                        path.lineWidth = 1.2
                        path.move(to: NSPoint(x: x, y: lineRect.minY + origin.y))
                        path.line(to: NSPoint(x: x, y: lineRect.maxY + origin.y))
                        path.stroke()
                    }
                }
            }

            lineStart = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
    }
}

private struct SyntaxHighlightedJSONView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        let textView = JSONCodeTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let defaultParagraph = NSMutableParagraphStyle()
        defaultParagraph.lineSpacing = 2.0
        textView.defaultParagraphStyle = defaultParagraph
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.applyHighlightedText(text, force: true)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyHighlightedText(text, force: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyntaxHighlightedJSONView
        weak var textView: NSTextView?
        private var isUpdating = false

        private static let keyRegex = try! NSRegularExpression(pattern: "\"([^\"\\\\]|\\\\.)*\"\\s*(?=:)")
        private static let stringRegex = try! NSRegularExpression(pattern: "\"([^\"\\\\]|\\\\.)*\"")
        private static let numberRegex = try! NSRegularExpression(pattern: "(?<![\\w\"])-?\\b\\d+(\\.\\d+)?([eE][+-]?\\d+)?\\b")
        private static let boolNullRegex = try! NSRegularExpression(pattern: "\\b(true|false|null)\\b")

        init(parent: SyntaxHighlightedJSONView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView else { return }
            let updated = textView.string
            parent.text = updated
            recolor(textView)
            textView.needsDisplay = true
        }

        func applyHighlightedText(_ newText: String, force: Bool) {
            guard let textView else { return }
            if !force && textView.string == newText { return }
            isUpdating = true
            let selected = textView.selectedRanges
            textView.string = newText
            recolor(textView)
            textView.needsDisplay = true
            if selected.allSatisfy({ ($0.rangeValue.location + $0.rangeValue.length) <= (newText as NSString).length }) {
                textView.selectedRanges = selected
            }
            isUpdating = false
        }

        private func recolor(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let source = storage.string
            let nsSource = source as NSString
            let fullRange = NSRange(location: 0, length: nsSource.length)
            let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            let keyFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
            let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
            let baseParagraphStyle = NSMutableParagraphStyle()
            baseParagraphStyle.lineSpacing = 2.0
            baseParagraphStyle.lineBreakMode = .byWordWrapping

            var cachedParagraphStyles: [Int: NSMutableParagraphStyle] = [0: baseParagraphStyle]
            func paragraphStyle(forLeadingSpaces spaces: Int) -> NSMutableParagraphStyle {
                if let cached = cachedParagraphStyles[spaces] { return cached }
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 2.0
                style.lineBreakMode = .byWordWrapping
                style.headIndent = CGFloat(spaces + 2) * spaceWidth
                cachedParagraphStyles[spaces] = style
                return style
            }

            // Compute brace/bracket depth at every UTF-16 offset (ignoring strings)
            var depths = [Int](repeating: 0, count: nsSource.length)
            var braceColors: [(NSRange, Int)] = []
            var depth = 0
            var inString = false
            var escaped = false
            for i in 0..<nsSource.length {
                let ch = nsSource.character(at: i)
                depths[i] = depth
                if inString {
                    if escaped {
                        escaped = false
                    } else if ch == 92 { // '\'
                        escaped = true
                    } else if ch == 34 { // '"'
                        inString = false
                    }
                    continue
                }
                if ch == 34 {
                    inString = true
                } else if ch == 123 || ch == 91 { // '{' or '['
                    braceColors.append((NSRange(location: i, length: 1), depth))
                    depth += 1
                } else if ch == 125 || ch == 93 { // '}' or ']'
                    depth = max(0, depth - 1)
                    braceColors.append((NSRange(location: i, length: 1), depth))
                }
            }

            storage.beginEditing()
            storage.setAttributes([
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: baseParagraphStyle
            ], range: fullRange)

            var linePos = 0
            while linePos < nsSource.length {
                let lineRange = nsSource.lineRange(for: NSRange(location: linePos, length: 0))
                var spaces = 0
                var idx = lineRange.location
                while idx < NSMaxRange(lineRange) {
                    let ch = nsSource.character(at: idx)
                    if ch == 32 {
                        spaces += 1
                    } else if ch == 9 {
                        spaces += 2
                    } else {
                        break
                    }
                    idx += 1
                }
                if spaces > 0 {
                    storage.addAttribute(
                        .paragraphStyle,
                        value: paragraphStyle(forLeadingSpaces: spaces),
                        range: lineRange
                    )
                }
                linePos = NSMaxRange(lineRange)
                if lineRange.length == 0 { break }
            }

            for match in Self.boolNullRegex.matches(in: source, range: fullRange) {
                storage.addAttributes([
                    .font: keyFont,
                    .foregroundColor: JSONDepthPalette.nsBoolColor
                ], range: match.range)
            }

            for match in Self.numberRegex.matches(in: source, range: fullRange) {
                storage.addAttribute(.foregroundColor, value: JSONDepthPalette.nsNumberColor, range: match.range)
            }

            for match in Self.stringRegex.matches(in: source, range: fullRange) {
                storage.addAttribute(.foregroundColor, value: JSONDepthPalette.nsStringColor, range: match.range)
            }

            for match in Self.keyRegex.matches(in: source, range: fullRange) {
                let loc = match.range.location
                let keyDepth = loc < depths.count ? max(0, depths[loc] - 1) : 0
                storage.addAttributes([
                    .font: keyFont,
                    .foregroundColor: JSONDepthPalette.nsColor(for: keyDepth)
                ], range: match.range)
            }

            for (range, braceDepth) in braceColors {
                let braceColor = braceDepth == 0
                    ? NSColor.secondaryLabelColor
                    : JSONDepthPalette.nsColor(for: braceDepth - 1)
                storage.addAttributes([
                    .font: keyFont,
                    .foregroundColor: braceColor
                ], range: range)
            }

            storage.endEditing()
        }
    }
}
