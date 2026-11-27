import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

/// Activating, key-capable window for the Quick Screenshot editor (unlike `.nonactivatingPanel` popovers)
/// so single-key tool shortcuts (`S/A/R/E/H/T/N/X/C`), `⌘Z`, `⌘C`, `⌘S`, and inline text callouts work naturally.
final class QuickScreenshotEditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cursorUpdate(with event: NSEvent) {
        if PointerCursorNSView.handleCursorUpdate(in: self) {
            return
        }
        super.cursorUpdate(with: event)
    }
}

@MainActor
final class QuickScreenshotEditorWindowController: NSObject, NSWindowDelegate {
    let session: ScreenshotEditorSession
    let previousFrontmostApp: NSRunningApplication?
    private var config: QuickScreenshotConfig
    private let onClosed: (QuickScreenshotEditorWindowController) -> Void

    private var editorWindow: QuickScreenshotEditorWindow?
    nonisolated(unsafe) private var keyMonitor: Any?
    private var isClosingBypassConfirm = false
    private weak var shareAnchorView: NSView?

    init(
        image: CGImage,
        config: QuickScreenshotConfig,
        previousFrontmostApp: NSRunningApplication? = nil,
        onClosed: @escaping (QuickScreenshotEditorWindowController) -> Void
    ) {
        self.session = ScreenshotEditorSession(
            image: image,
            defaultRedactStyle: config.defaultRedactMode
        )
        self.previousFrontmostApp = previousFrontmostApp
        self.config = config
        self.onClosed = onClosed
        super.init()
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    var window: NSWindow? { editorWindow }

    func presentEditor() {
        let win = ensureWindow()
        win.makeKeyAndOrderFront(nil)
        if previousFrontmostApp != nil {
            // Activate without `.activateAllWindows` and push background Dashboard behind
            // so capturing from another app opens ONLY the floating Screenshot Editor.
            NSApp.activate()
            if let mainWin = MainWindowController.shared.currentWindow, mainWin.isVisible, mainWin !== win {
                mainWin.orderBack(nil)
            }
            win.makeKeyAndOrderFront(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        installKeyMonitor(for: win)
        DispatchQueue.main.async { [weak win] in
            if let win, win.isVisible {
                PointerCursorNSView.syncCursor(in: win)
            }
        }
    }

    func showWindow(_ sender: Any?) {
        presentEditor()
    }

    func forceClose() {
        isClosingBypassConfirm = true
        if let win = editorWindow {
            win.close()
        } else {
            session.releaseImageMemory()
            onClosed(self)
        }
    }

    private func ensureWindow() -> QuickScreenshotEditorWindow {
        if let editorWindow {
            return editorWindow
        }

        let initialSize = Self.recommendedWindowSize(for: session.imagePixelSize)
        let win = QuickScreenshotEditorWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Quick Screenshot — \(Int(session.imagePixelSize.width)) × \(Int(session.imagePixelSize.height)) px"
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = false
        win.minSize = NSSize(width: 760, height: 480)
        win.isReleasedWhenClosed = false
        win.delegate = self
        ToolboxTheme.applyDarkAppearance(to: win)

        let rootView = QuickScreenshotEditorView(
            session: session,
            onCopy: { [weak self] in self?.copyFlattenedToClipboard() },
            onSave: { [weak self] in self?.quickSave() },
            onSaveAs: { [weak self] in self?.saveAsWithPanel() },
            onShare: { [weak self] anchor in self?.shareFlattened(from: anchor) },
            onAutoRedact: { [weak self] in self?.runAutoRedact() },
            onCopyOCR: { [weak self] in self?.runOCRCopy() },
            onRequestClose: { [weak self] in self?.requestClose() }
        )
        let hosting = PointerCursorHostingView(rootView: rootView)
        win.contentView = hosting
        win.center()
        self.editorWindow = win
        return win
    }

    static func recommendedWindowSize(for pixelSize: CGSize) -> NSSize {
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = max(840, screenFrame.width * 0.84)
        let maxH = max(560, screenFrame.height * 0.84)
        let aspect = pixelSize.height > 0 ? (pixelSize.width / pixelSize.height) : 1.5
        let targetW = min(maxW, max(940, pixelSize.width * 0.55 + 140))
        let targetH = min(maxH, max(620, targetW / max(0.5, aspect) + 150))
        return NSSize(width: round(targetW), height: round(targetH))
    }

    // MARK: - Window Close & Unsaved Protection

    func requestClose() {
        guard let win = editorWindow else { return }
        if !session.hasUnexportedChanges {
            win.close()
            return
        }
        presentUnsavedChangesAlert(for: win)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosingBypassConfirm || !session.hasUnexportedChanges {
            return true
        }
        presentUnsavedChangesAlert(for: sender)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        PointerCursorNSView.activeDragCursor = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        session.releaseImageMemory()
        editorWindow?.contentView = nil
        editorWindow = nil
        onClosed(self)

        if !PermissionsManager.isRunningInDiagnosticMode,
           ModuleRegistry.shared.quickScreenshot.openEditorCount == 0,
           let returnApp = previousFrontmostApp,
           !returnApp.isTerminated {
            if let mainWin = MainWindowController.shared.currentWindow, mainWin.isVisible {
                mainWin.orderBack(nil)
            }
            NSApp.yieldActivation(to: returnApp)
            returnApp.activate()
        }
    }

    private func presentUnsavedChangesAlert(for win: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Close without copying or saving?"
        alert.informativeText = "You have unexported annotations or redactions on this screenshot."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Copy & Close")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        ToolboxTheme.applyDarkAppearance(to: alert.window)

        alert.beginSheetModal(for: win) { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    if self.copyFlattenedToClipboard(forceCloseIgnorePreference: true) {
                        self.forceClose()
                    }
                case .alertSecondButtonReturn:
                    self.forceClose()
                default:
                    break
                }
            }
        }
    }

    // MARK: - Actions

    @discardableResult
    func copyFlattenedToClipboard(forceCloseIgnorePreference: Bool = false) -> Bool {
        session.finishTextEditing()
        guard let base = session.baseImage,
              let flattened = ScreenshotRenderer.render(
                baseImage: base,
                annotations: session.annotations,
                cropRect: session.cropRect
              ) else {
            return false
        }
        let ok = ScreenshotRenderer.copyToPasteboard(flattened)
        if ok {
            let redactCount = session.annotations.filter { $0.kind == .redact }.count
            DeveloperEventLog.shared.record(
                .quickScreenshot,
                "Copied screenshot to clipboard",
                detail: "\(flattened.width)x\(flattened.height) px, \(session.annotations.count) annotations (\(redactCount) redactions)"
            )
            session.markExported()
            if ConfigManager.shared.config.quickScreenshot.showToast {
                HUDToast.shared.show(
                    title: "Copied screenshot to clipboard",
                    symbol: "doc.on.clipboard.fill",
                    tint: .red
                )
            }
            if !forceCloseIgnorePreference && ConfigManager.shared.config.quickScreenshot.closeEditorAfterCopy {
                forceClose()
            }
        }
        return ok
    }

    func quickSave() {
        session.finishTextEditing()
        guard let base = session.baseImage,
              let flattened = ScreenshotRenderer.render(
                baseImage: base,
                annotations: session.annotations,
                cropRect: session.cropRect
              ) else {
            return
        }
        let liveConfig = ConfigManager.shared.config.quickScreenshot
        switch ScreenshotRenderer.saveToDirectory(
            flattened,
            format: liveConfig.saveFormat,
            jpegQuality: liveConfig.jpegQuality,
            directoryPath: liveConfig.defaultSaveDirectory
        ) {
        case .success(let savedURL):
            session.markExported()
            if liveConfig.showToast {
                HUDToast.shared.show(
                    title: "Saved \(savedURL.lastPathComponent)",
                    symbol: "checkmark.circle.fill",
                    tint: .green
                )
            }
        case .failure(let err):
            HUDToast.shared.show(
                title: "Save failed: \(err.localizedDescription)",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
    }

    func saveAsWithPanel() {
        session.finishTextEditing()
        guard let base = session.baseImage,
              let flattened = ScreenshotRenderer.render(
                baseImage: base,
                annotations: session.annotations,
                cropRect: session.cropRect
              ) else {
            return
        }
        let liveConfig = ConfigManager.shared.config.quickScreenshot
        let panel = NSSavePanel()
        panel.allowedContentTypes = liveConfig.saveFormat == .png ? [.png] : [.jpeg]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ScreenshotRenderer.defaultFilename(format: liveConfig.saveFormat)
        let expandedDir = (liveConfig.defaultSaveDirectory as NSString).expandingTildeInPath
        panel.directoryURL = URL(fileURLWithPath: expandedDir, isDirectory: true)

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let targetURL = panel.url else { return }
            do {
                try ScreenshotRenderer.writeImage(
                    flattened,
                    to: targetURL,
                    format: liveConfig.saveFormat,
                    jpegQuality: liveConfig.jpegQuality
                )
                self?.session.markExported()
                if liveConfig.showToast {
                    HUDToast.shared.show(
                        title: "Saved \(targetURL.lastPathComponent)",
                        symbol: "checkmark.circle.fill",
                        tint: .green
                    )
                }
            } catch {
                HUDToast.shared.show(
                    title: "Save failed: \(error.localizedDescription)",
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
        }

        if let win = editorWindow {
            panel.beginSheetModal(for: win, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    func shareFlattened(from anchorView: NSView?) {
        session.finishTextEditing()
        guard let base = session.baseImage,
              let flattened = ScreenshotRenderer.render(
                baseImage: base,
                annotations: session.annotations,
                cropRect: session.cropRect
              ) else {
            return
        }
        let nsImage = NSImage(
            cgImage: flattened,
            size: NSSize(width: flattened.width, height: flattened.height)
        )
        let picker = NSSharingServicePicker(items: [nsImage])
        if let anchorView {
            picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        } else if let contentView = editorWindow?.contentView {
            let rect = NSRect(x: contentView.bounds.midX - 40, y: 12, width: 80, height: 32)
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }

    func runAutoRedact() {
        guard !session.isRunningAutoRedact, let base = session.baseImage else { return }
        session.isRunningAutoRedact = true
        let imageBox = ImageBox(image: base)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let matches = ScreenshotAutoRedactor.scanImage(imageBox.image)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.session.isRunningAutoRedact = false
                if matches.isEmpty {
                    HUDToast.shared.show(
                        title: "No secrets or PII detected",
                        symbol: "checkmark.shield",
                        tint: .green
                    )
                } else {
                    self.session.applyAutoRedactSuggestions(matches)
                    HUDToast.shared.show(
                        title: "Found \(matches.count) sensitive item\(matches.count == 1 ? "" : "s") to review",
                        symbol: "eye.slash.fill",
                        tint: .orange
                    )
                }
            }
        }
    }

    func runOCRCopy() {
        guard !session.isRunningOCR, let base = session.baseImage else { return }
        session.isRunningOCR = true
        let cropRect = session.cropRect
        let box = ImageBox(image: base)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cropped: CGImage
            if let cropRect {
                let bounds = CGRect(x: 0, y: 0, width: box.image.width, height: box.image.height)
                let clamped = cropRect.standardized.integral.intersection(bounds)
                cropped = (!clamped.isNull ? box.image.cropping(to: clamped) : nil) ?? box.image
            } else {
                cropped = box.image
            }
            let prepared = ScreenOCREngine.prepareImage(cropped)
            let result = ScreenOCREngine.recognize(
                in: prepared,
                preserveLineBreaks: true,
                detectBarcodes: true
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.session.isRunningOCR = false
                guard !result.isEmpty else {
                    HUDToast.shared.show(
                        title: "No text found in screenshot",
                        symbol: "text.viewfinder",
                        tint: .orange
                    )
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.clipboardString, forType: .string)
                HUDToast.shared.show(
                    title: result.toastSummary,
                    symbol: result.qrPayloads.isEmpty ? "text.viewfinder" : "qrcode",
                    tint: .mint
                )
            }
        }
    }

    // MARK: - Keyboard Shortcuts

    private func installKeyMonitor(for window: QuickScreenshotEditorWindow) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            return self.handleKeyDown(event)
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let isEditingText = (editorWindow?.firstResponder is NSTextView) || session.editingTextAnnotationID != nil

        // Escape always commits inline text editing first.
        if event.keyCode == UInt16(kVK_Escape) {
            if session.editingTextAnnotationID != nil {
                session.finishTextEditing()
                editorWindow?.makeFirstResponder(nil)
                return nil
            }
            if session.activeTool == .crop && session.cropRect != nil {
                session.selectTool(.select)
                return nil
            }
            if session.selectedAnnotationID != nil {
                session.selectedAnnotationID = nil
                return nil
            }
            requestClose()
            return nil
        }

        // Let the inline text field receive normal typing, Return, and Delete.
        if isEditingText {
            return event
        }

        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()

        if mods == [.command] {
            switch chars {
            case "z":
                session.undo()
                return nil
            case "c":
                copyFlattenedToClipboard()
                return nil
            case "s":
                quickSave()
                return nil
            case "=", "+":
                let fit = CanvasCoordinateMapper.fitScale(
                    imageSize: session.imagePixelSize,
                    viewportSize: editorWindow?.contentView?.bounds.size ?? NSSize(width: 900, height: 600)
                )
                session.adjustZoom(by: 0.25, fitScale: fit)
                return nil
            case "-":
                let fit = CanvasCoordinateMapper.fitScale(
                    imageSize: session.imagePixelSize,
                    viewportSize: editorWindow?.contentView?.bounds.size ?? NSSize(width: 900, height: 600)
                )
                session.adjustZoom(by: -0.25, fitScale: fit)
                return nil
            case "0":
                session.resetZoom()
                return nil
            default:
                break
            }
        }

        if mods == [.command, .shift] {
            switch chars {
            case "z":
                session.redo()
                return nil
            case "s":
                saveAsWithPanel()
                return nil
            default:
                break
            }
        }

        if mods.isEmpty {
            if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                if session.activeTool == .crop && session.cropRect != nil {
                    session.selectTool(.select)
                    return nil
                }
                copyFlattenedToClipboard()
                return nil
            }
            if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
                session.deleteSelected()
                return nil
            }
            if let tool = ScreenshotTool.tool(forKeyCharacter: chars) {
                session.selectTool(tool)
                return nil
            }
        }

        return event
    }
}

// MARK: - SwiftUI Editor View

@MainActor
private final class QuickScreenshotEditorUIState: ObservableObject {
    enum ActiveDragMode {
        case none
        case placeTap
        case drawNew
        case moveSelected(initialItem: AnnotationItem)
        case resizeRectHandle(initialItem: AnnotationItem, corner: RectCorner)
        case moveArrowEndpoint(initialItem: AnnotationItem, isStart: Bool)
        case drawCrop
        case resizeCropHandle(initialCrop: CGRect, handle: CropHandle)
        case moveCrop(initialCrop: CGRect)
        case panCanvas
    }

    enum RectCorner {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    enum CropHandle {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
    }

    enum SelectionHandleHit {
        case arrowEndpoint(item: AnnotationItem, isStart: Bool)
        case rectCorner(item: AnnotationItem, corner: RectCorner)
    }

    @Published var draftAnnotation: AnnotationItem? = nil
    @Published var draftCropRect: CGRect? = nil
    @Published var cachedPixelatedImage: CGImage? = nil
    @Published var hoveredAnnotationID: UUID? = nil
    @Published var currentCanvasCursor: NSCursor = .arrow

    struct FilteredRedactCacheKey: Equatable {
        let rect: CGRect
        let style: RedactStyle
    }

    var dragStartPixel: CGPoint? = nil
    var dragMode: ActiveDragMode = .none
    var dragInitialAnnotations: [AnnotationItem]? = nil
    var dragInitialPan: CGSize = .zero
    var dragStartViewPoint: CGPoint? = nil
    var lastHoverViewPoint: CGPoint? = nil
    var cachedPixelateKey: [FilteredRedactCacheKey] = []
    var lastTapAnnotationID: UUID? = nil
    var lastTapTimestamp: TimeInterval = 0
    weak var shareAnchorView: NSView?
}

struct QuickScreenshotEditorView: View {
    @ObservedObject var session: ScreenshotEditorSession
    let onCopy: () -> Void
    let onSave: () -> Void
    let onSaveAs: () -> Void
    let onShare: (NSView?) -> Void
    let onAutoRedact: () -> Void
    let onCopyOCR: () -> Void
    let onRequestClose: () -> Void

    @ObservedObject private var configManager = ConfigManager.shared
    @StateObject private var uiState = QuickScreenshotEditorUIState()

    var body: some View {
        VStack(spacing: 0) {
            topToolbar
            Divider().opacity(0.6)
            canvasArea
            if !session.reviewItems.isEmpty {
                Divider().opacity(0.6)
                autoRedactReviewTray
            }
            Divider().opacity(0.6)
            bottomActionBar
        }
        .background(Color(red: 0.08, green: 0.09, blue: 0.11))
        .toolboxDarkAppearance()
        .onAppear {
            refreshPixelatedCacheIfNeeded()
        }
        .onChange(of: session.annotations) { _, _ in
            refreshPixelatedCacheIfNeeded()
        }
        .onDisappear {
            PointerCursorNSView.activeDragCursor = nil
        }
    }

    // MARK: - Top Toolbar

    private var topToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(ScreenshotTool.allCases) { tool in
                        let selected = session.activeTool == tool
                        Button {
                            session.selectTool(tool)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: tool.symbolName)
                                    .toolboxFont(.system(size: 11.5, weight: .semibold))
                                Text(tool.label)
                                    .toolboxFont(.caption.weight(.medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.86))
                            .background(
                                selected ? Color.red.opacity(0.85) : Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(
                                        selected ? Color.red : Color.white.opacity(0.10),
                                        lineWidth: 0.8
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                        .focusEffectDisabled()
                        .help("\(tool.label) (\(tool.shortcutKey))")
                        .pointerCursor()
                    }
                }

                Spacer(minLength: 8)

                // Undo / Redo / Delete
                HStack(spacing: 4) {
                    Button {
                        session.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 26, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!session.canUndo)
                    .help("Undo (⌘ Z)")
                    .pointerCursor(session.canUndo)

                    Button {
                        session.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .frame(width: 26, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!session.canRedo)
                    .help("Redo (⇧ ⌘ Z)")
                    .pointerCursor(session.canRedo)

                    Button {
                        session.deleteSelected()
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 26, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .disabled(session.selectedAnnotationID == nil)
                    .help("Delete Selected (⌫)")
                    .pointerCursor(session.selectedAnnotationID != nil)
                }

                Divider().frame(height: 18)

                // Zoom
                HStack(spacing: 3) {
                    ForEach([CanvasZoomMode.fit, .percent100, .percent200], id: \.label) { mode in
                        let isSelected = session.zoomMode == mode
                        Button {
                            session.zoomMode = mode
                            if mode == .fit {
                                session.panOffset = .zero
                            }
                        } label: {
                            Text(mode.label)
                                .toolboxFont(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(
                                    isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                        .focusEffectDisabled()
                        .pointerCursor()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Divider().opacity(0.35)

            let selectedAnnotation = session.selectedAnnotationID.flatMap { id in
                session.annotations.first(where: { $0.id == id })
            }
            let showRedactOptions: Bool = {
                if let selected = selectedAnnotation {
                    return selected.kind == .redact
                }
                return session.activeTool == .redact
            }()
            let showColorAndStroke: Bool = {
                if let selected = selectedAnnotation {
                    return selected.kind != .redact
                }
                return session.activeTool != .redact
                    && session.activeTool != .crop
                    && session.activeTool != .select
            }()

            HStack(spacing: 12) {
                if showRedactOptions {
                    let activeRedactStyle = (selectedAnnotation?.kind == .redact)
                        ? selectedAnnotation!.redactStyle
                        : session.redactStyle
                    HStack(spacing: 6) {
                        Text("Redact")
                            .toolboxFont(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Picker("Redact", selection: Binding(
                            get: { activeRedactStyle },
                            set: { session.updateRedactStyleForExistingSelectionOrTool($0) }
                        )) {
                            ForEach(RedactStyle.allCases) { style in
                                Text(style.shortLabel).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 204)
                        .labelsHidden()
                        .help("Redaction style (Solid Opaque Box, Smooth Blur, or Pixelate)")
                        .pointerCursor()
                    }
                } else if showColorAndStroke {
                    let activeColor = (selectedAnnotation != nil && selectedAnnotation?.kind != .redact)
                        ? selectedAnnotation!.color
                        : session.selectedColor
                    let activeStroke = (selectedAnnotation != nil && selectedAnnotation?.kind != .redact)
                        ? selectedAnnotation!.strokeWidth
                        : session.strokeWidth

                    HStack(spacing: 5) {
                        Text("Color")
                            .toolboxFont(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        ForEach(AnnotationColor.allCases) { color in
                            let isSelected = activeColor == color
                            Button {
                                session.updateColorForExistingSelectionOrTool(color)
                            } label: {
                                Circle()
                                    .fill(color.swiftUIColor)
                                    .frame(width: 14, height: 14)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(
                                                isSelected ? Color.white : Color.white.opacity(0.28),
                                                lineWidth: isSelected ? 2.2 : 1
                                            )
                                    )
                                    .padding(2)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .help(color.label)
                            .pointerCursor()
                        }
                    }

                    Divider().frame(height: 16)

                    HStack(spacing: 4) {
                        Text("Stroke")
                            .toolboxFont(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        ForEach([2.0, 4.0, 7.0, 11.0], id: \.self) { width in
                            let isSelected = abs(activeStroke - CGFloat(width)) < 0.5
                            Button {
                                session.updateStrokeWidthForExistingSelectionOrTool(CGFloat(width))
                            } label: {
                                Circle()
                                    .fill(isSelected ? Color.white : Color.white.opacity(0.55))
                                    .frame(width: max(5, CGFloat(width) * 1.1), height: max(5, CGFloat(width) * 1.1))
                                    .frame(width: 20, height: 20)
                                    .background(
                                        isSelected ? Color.white.opacity(0.16) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 5)
                                    )
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .help("Stroke \(Int(width)) px")
                            .pointerCursor()
                        }
                    }
                } else {
                    Text(session.activeTool == .crop
                         ? "Drag to crop · Drag corners/edges to adjust · Return to apply"
                         : "Click or drag any item to adjust · Double-click text to edit")
                        .toolboxFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("S Select · A Arrow · R Rect · E Ellipse · H Highlight · T Text · N Number · X Redact · C Crop")
                    .toolboxFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minHeight: 24)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(red: 0.11, green: 0.12, blue: 0.15))
    }

    // MARK: - Interactive Canvas

    private var canvasArea: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size
            let fitScale = CanvasCoordinateMapper.fitScale(
                imageSize: session.imagePixelSize,
                viewportSize: viewportSize
            )
            let zoomScale = session.zoomMode.scaleFactor(fitScale: fitScale)
            let imageRect = CanvasCoordinateMapper.computeRenderedImageRect(
                imageSize: session.imagePixelSize,
                viewportSize: viewportSize,
                zoomScale: zoomScale,
                panOffset: session.panOffset
            )
            let mapper = CanvasCoordinateMapper(
                imageSize: session.imagePixelSize,
                renderedImageRect: imageRect
            )
            let activeCrop = uiState.draftCropRect ?? session.cropRect
            let isEditingCrop = (session.activeTool == .crop) || (uiState.draftCropRect != nil)
            let isAppliedCropPreview = (session.cropRect != nil) && !isEditingCrop
            let activeViewCrop = activeCrop.map { mapper.imagePixelToViewRect($0) }

            ZStack(alignment: .topLeading) {
                checkerboardBackdrop

                if let displayCG = uiState.cachedPixelatedImage ?? session.baseImage {
                    if isEditingCrop, let viewCrop = activeViewCrop {
                        Image(decorative: displayCG, scale: 1.0, orientation: .up)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: imageRect.width, height: imageRect.height)
                            .blur(radius: 8)
                            .clipped()
                            .position(x: imageRect.midX, y: imageRect.midY)

                        Color.black.opacity(0.65)
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: imageRect.midX, y: imageRect.midY)
                            .allowsHitTesting(false)

                        Image(decorative: displayCG, scale: 1.0, orientation: .up)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: imageRect.midX, y: imageRect.midY)
                            .clipShape(CropClipShape(rect: viewCrop))
                    } else if isAppliedCropPreview, let viewCrop = activeViewCrop {
                        Color(red: 0.06, green: 0.07, blue: 0.09)
                            .frame(width: viewCrop.width, height: viewCrop.height)
                            .position(x: viewCrop.midX, y: viewCrop.midY)
                            .shadow(color: .black.opacity(0.55), radius: 14, y: 6)
                            .allowsHitTesting(false)

                        Image(decorative: displayCG, scale: 1.0, orientation: .up)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: imageRect.midX, y: imageRect.midY)
                            .clipShape(CropClipShape(rect: viewCrop))
                    } else {
                        Image(decorative: displayCG, scale: 1.0, orientation: .up)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: imageRect.midX, y: imageRect.midY)
                            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                    }
                }

                // Vector annotations + hover/selection handles + crop overlay
                Canvas { context, _ in
                    let drawAnnotations: (inout GraphicsContext) -> Void = { targetCtx in
                        for item in session.annotations where item.kind == .redact {
                            drawCanvasAnnotation(item, isDraft: false, in: &targetCtx, mapper: mapper, scale: zoomScale)
                        }
                        for item in session.annotations where item.kind != .redact {
                            drawCanvasAnnotation(item, isDraft: false, in: &targetCtx, mapper: mapper, scale: zoomScale)
                        }
                        if let draft = uiState.draftAnnotation {
                            drawCanvasAnnotation(draft, isDraft: true, in: &targetCtx, mapper: mapper, scale: zoomScale)
                        }
                    }

                    if isAppliedCropPreview, let viewCrop = activeViewCrop {
                        context.drawLayer { layerCtx in
                            layerCtx.clip(to: Path(viewCrop))
                            drawAnnotations(&layerCtx)
                        }
                        context.stroke(Path(viewCrop), with: .color(.white.opacity(0.18)), lineWidth: 1)
                    } else {
                        drawAnnotations(&context)
                    }

                    if let hoveredID = uiState.hoveredAnnotationID,
                       hoveredID != session.selectedAnnotationID,
                       let hovered = session.annotations.first(where: { $0.id == hoveredID }) {
                        drawHoverChrome(for: hovered, in: &context, mapper: mapper)
                    }

                    if let selectedID = session.selectedAnnotationID,
                       let selected = session.annotations.first(where: { $0.id == selectedID }) {
                        drawSelectionChrome(for: selected, in: &context, mapper: mapper)
                    }

                    if isEditingCrop, let activeCrop {
                        drawCropOverlay(
                            cropPixelRect: activeCrop,
                            in: &context,
                            mapper: mapper
                        )
                    }
                }
                .allowsHitTesting(false)

                // Inline text editor overlay when creating/editing a text callout
                if let editingID = session.editingTextAnnotationID,
                   let textItem = session.annotations.first(where: { $0.id == editingID && $0.kind == .text }) {
                    inlineTextCalloutEditor(for: textItem, mapper: mapper, scale: zoomScale)
                }

                // Crop action pill
                if let crop = session.cropRect {
                    HStack(spacing: 8) {
                        Text("\(isEditingCrop ? "Crop" : "Cropped"): \(Int(crop.width)) × \(Int(crop.height)) px")
                            .toolboxFont(.caption.weight(.medium))
                            .foregroundStyle(.white)
                        if isEditingCrop {
                            Button("Done") {
                                session.selectTool(.select)
                            }
                            .buttonStyle(.toolboxProminent(.red))
                            .controlSize(.small)
                            .pointerCursor()
                        } else {
                            Button("Adjust") {
                                session.selectTool(.crop)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointerCursor()
                        }
                        Button("Reset") {
                            session.clearCrop()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThickMaterial, in: Capsule())
                    .padding(12)
                }

                CanvasCursorOverlay(
                    cursor: uiState.currentCanvasCursor,
                    onExit: {
                        uiState.hoveredAnnotationID = nil
                        uiState.lastHoverViewPoint = nil
                    }
                )
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let viewPoint):
                    uiState.lastHoverViewPoint = viewPoint
                    updateHoverAndCursor(
                        at: viewPoint,
                        mapper: mapper,
                        zoomScale: zoomScale,
                        isEditingCrop: isEditingCrop
                    )
                case .ended:
                    uiState.hoveredAnnotationID = nil
                    uiState.lastHoverViewPoint = nil
                }
            }
            .onChange(of: session.activeTool) { _, _ in
                cancelInFlightDrag()
                if let hoverPt = uiState.lastHoverViewPoint {
                    let editingCropNow = (session.activeTool == .crop) || (uiState.draftCropRect != nil)
                    updateHoverAndCursor(at: hoverPt, mapper: mapper, zoomScale: zoomScale, isEditingCrop: editingCropNow)
                } else {
                    uiState.currentCanvasCursor = defaultCursor(for: session.activeTool)
                }
            }
            .onChange(of: session.selectedAnnotationID) { _, _ in
                if let hoverPt = uiState.lastHoverViewPoint {
                    updateHoverAndCursor(at: hoverPt, mapper: mapper, zoomScale: zoomScale, isEditingCrop: isEditingCrop)
                }
            }
            .onChange(of: session.cropRect) { _, _ in
                if let hoverPt = uiState.lastHoverViewPoint {
                    updateHoverAndCursor(at: hoverPt, mapper: mapper, zoomScale: zoomScale, isEditingCrop: isEditingCrop)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleCanvasDragChanged(value: value, mapper: mapper, zoomScale: zoomScale)
                    }
                    .onEnded { value in
                        handleCanvasDragEnded(
                            value: value,
                            mapper: mapper,
                            zoomScale: zoomScale,
                            isEditingCrop: isEditingCrop
                        )
                    }
            )
        }
        .clipped()
    }

    private var checkerboardBackdrop: some View {
        Color(red: 0.06, green: 0.07, blue: 0.09)
            .overlay(
                Canvas { context, size in
                    let step: CGFloat = 24
                    let dotColor = Color.white.opacity(0.05)
                    var y: CGFloat = step / 2
                    while y < size.height {
                        var x: CGFloat = step / 2
                        while x < size.width {
                            context.fill(
                                Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                                with: .color(dotColor)
                            )
                            x += step
                        }
                        y += step
                    }
                }
                .allowsHitTesting(false)
            )
    }

    @ViewBuilder
    private func inlineTextCalloutEditor(
        for item: AnnotationItem,
        mapper: CanvasCoordinateMapper,
        scale: CGFloat
    ) -> some View {
        let origin = mapper.imagePixelToViewPoint(item.startPoint)
        let fontSize = max(12, AnnotationItem.textFontSize(for: item.strokeWidth) * scale)
        TextField("Type note…", text: Binding(
            get: {
                session.annotations.first(where: { $0.id == item.id })?.text ?? item.text
            },
            set: { newValue in
                session.updateTextAnnotation(id: item.id, text: newValue)
            }
        ))
        .textFieldStyle(.plain)
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundStyle(item.color.swiftUIColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minWidth: 140, maxWidth: 360)
        .background(
            Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.92),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(item.color.swiftUIColor, lineWidth: 1.5)
        )
        .onSubmit {
            session.finishTextEditing()
        }
        .offset(x: origin.x, y: origin.y)
    }

    // MARK: - Auto-Redact Review Tray

    private var autoRedactReviewTray: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash.fill")
                    .foregroundStyle(.orange)
                    .toolboxFont(.caption.weight(.semibold))
                Text("Auto-Redact Review (\(session.reviewItems.count) match\(session.reviewItems.count == 1 ? "" : "es"))")
                    .toolboxFont(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button("Keep All") {
                    session.keepAllReviewItems()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointerCursor()

                Button("Undo All", role: .destructive) {
                    session.undoAllReviewItems()
                }
                .buttonStyle(.toolboxDestructive)
                .controlSize(.small)
                .pointerCursor()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(session.reviewItems) { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.category.symbolName)
                                .toolboxFont(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.category.label)
                                    .toolboxFont(.caption2.weight(.semibold))
                                Text("\(item.maskedSnippet) · \(Int((item.confidence * 100).rounded()))%")
                                    .toolboxFont(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                session.selectedAnnotationID = item.annotationID
                                session.keepReviewItem(item)
                            } label: {
                                Image(systemName: "checkmark")
                                    .toolboxFont(.caption2.weight(.bold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Keep redaction")
                            .pointerCursor()

                            Button {
                                session.removeReviewItem(item)
                            } label: {
                                Image(systemName: "xmark")
                                    .toolboxFont(.caption2.weight(.bold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Remove false positive")
                            .pointerCursor()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.orange.opacity(0.32), lineWidth: 0.75)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        HStack(spacing: 10) {
            Button {
                onAutoRedact()
            } label: {
                HStack(spacing: 6) {
                    if session.isRunningAutoRedact {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "eye.slash.fill")
                    }
                    Text(session.isRunningAutoRedact ? "Scanning…" : "Auto-Redact")
                }
            }
            .buttonStyle(.bordered)
            .disabled(session.isRunningAutoRedact || session.baseImage == nil)
            .help("Detect and redact emails, API keys, tokens, JWTs, and cards locally")
            .pointerCursor(!session.isRunningAutoRedact)

            Button {
                onCopyOCR()
            } label: {
                HStack(spacing: 6) {
                    if session.isRunningOCR {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "text.viewfinder")
                    }
                    Text(session.isRunningOCR ? "Reading…" : "Copy Text (OCR)")
                }
            }
            .buttonStyle(.bordered)
            .disabled(session.isRunningOCR || session.baseImage == nil)
            .help("Extract text or QR payloads with Apple Vision")
            .pointerCursor(!session.isRunningOCR)

            Spacer()

            Text("\(Int(session.imagePixelSize.width)) × \(Int(session.imagePixelSize.height)) px")
                .toolboxFont(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                onShare(uiState.shareAnchorView)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .background(ShareAnchorReader { view in
                uiState.shareAnchorView = view
            })
            .pointerCursor()

            Button {
                onSaveAs()
            } label: {
                Text("Save As…")
            }
            .buttonStyle(.bordered)
            .help("Save to a chosen folder (⇧ ⌘ S)")
            .pointerCursor()

            Button {
                onSave()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .help("Save directly to your configured folder (⌘ S)")
            .pointerCursor()

            let closeAfterCopy = configManager.config.quickScreenshot.closeEditorAfterCopy
            Button {
                onCopy()
            } label: {
                Label(closeAfterCopy ? "Copy & Close" : "Copy", systemImage: "doc.on.clipboard.fill")
            }
            .buttonStyle(.toolboxProminent(.red))
            .fixedSize(horizontal: true, vertical: false)
            .help(closeAfterCopy
                  ? "Copy flattened screenshot to clipboard and close editor (⌘ C / Return)"
                  : "Copy flattened screenshot to clipboard (⌘ C / Return)")
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.11, green: 0.12, blue: 0.15))
    }

    // MARK: - Canvas Drawing

    private func drawCanvasAnnotation(
        _ item: AnnotationItem,
        isDraft: Bool,
        in context: inout GraphicsContext,
        mapper: CanvasCoordinateMapper,
        scale: CGFloat
    ) {
        let viewStroke = max(1.5, item.strokeWidth * scale)
        switch item.kind {
        case .redact:
            let viewRect = mapper.imagePixelToViewRect(item.rect)
            switch item.redactStyle {
            case .solidBlack:
                context.fill(Path(viewRect), with: .color(.black))
            case .blur, .pixelate:
                // Blur/Pixelate is baked into cachedPixelatedImage cleanly without any permanent
                // border; show a live preview box only while actively dragging a new redaction.
                if isDraft {
                    context.fill(Path(viewRect), with: .color(.white.opacity(0.10)))
                    context.stroke(
                        Path(viewRect),
                        with: .color(.white.opacity(0.70)),
                        style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                    )
                }
            }

        case .rectangle:
            let viewRect = mapper.imagePixelToViewRect(item.rect)
            let path = Path(roundedRect: viewRect, cornerRadius: max(2, 4 * scale))
            context.stroke(path, with: .color(item.color.swiftUIColor), lineWidth: viewStroke)

        case .ellipse:
            let viewRect = mapper.imagePixelToViewRect(item.rect)
            context.stroke(Path(ellipseIn: viewRect), with: .color(item.color.swiftUIColor), lineWidth: viewStroke)

        case .highlighter:
            guard !item.points.isEmpty else { return }
            var path = Path()
            let first = mapper.imagePixelToViewPoint(item.points[0])
            path.move(to: first)
            for pt in item.points.dropFirst() {
                path.addLine(to: mapper.imagePixelToViewPoint(pt))
            }
            var hlContext = context
            hlContext.blendMode = .multiply
            hlContext.stroke(
                path,
                with: .color(item.color.swiftUIColor.opacity(0.45)),
                style: StrokeStyle(lineWidth: max(8, item.strokeWidth * 4.2 * scale), lineCap: .round, lineJoin: .round)
            )

        case .arrow:
            let start = mapper.imagePixelToViewPoint(item.startPoint)
            let end = mapper.imagePixelToViewPoint(item.endPoint)
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length >= 2 else { return }
            let headLen = max(10, item.strokeWidth * 4.0 * scale)
            let angle = atan2(dy, dx)
            let headAngle: CGFloat = .pi / 6.5
            let shaftEnd = CGPoint(
                x: end.x - cos(angle) * headLen * 0.65,
                y: end.y - sin(angle) * headLen * 0.65
            )
            var shaft = Path()
            shaft.move(to: start)
            shaft.addLine(to: shaftEnd)
            context.stroke(
                shaft,
                with: .color(item.color.swiftUIColor),
                style: StrokeStyle(lineWidth: viewStroke, lineCap: .round)
            )
            var head = Path()
            head.move(to: end)
            head.addLine(to: CGPoint(x: end.x - cos(angle - headAngle) * headLen, y: end.y - sin(angle - headAngle) * headLen))
            head.addLine(to: CGPoint(x: end.x - cos(angle + headAngle) * headLen, y: end.y - sin(angle + headAngle) * headLen))
            head.closeSubpath()
            context.fill(head, with: .color(item.color.swiftUIColor))

        case .step:
            let center = mapper.imagePixelToViewPoint(item.startPoint)
            let radius = max(10, AnnotationItem.stepRadius(for: item.strokeWidth) * scale)
            let circleRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: circleRect), with: .color(item.color.swiftUIColor))
            context.stroke(Path(ellipseIn: circleRect), with: .color(.white.opacity(0.9)), lineWidth: max(1.5, 2 * scale))
            let textColor: Color = (item.color == .white || item.color == .yellow) ? .black : .white
            let resolved = context.resolve(
                Text("\(item.stepNumber)")
                    .font(.system(size: radius * 1.05, weight: .bold))
                    .foregroundStyle(textColor)
            )
            context.draw(resolved, at: center, anchor: .center)

        case .text:
            guard session.editingTextAnnotationID != item.id else { return }
            let origin = mapper.imagePixelToViewPoint(item.startPoint)
            let fontSize = max(11, AnnotationItem.textFontSize(for: item.strokeWidth) * scale)
            let textContent = item.text.isEmpty ? "Note" : item.text
            let resolved = context.resolve(
                Text(textContent)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(item.color.swiftUIColor)
            )
            let textSize = resolved.measure(in: CGSize(width: 1200, height: 1200))
            let padX = 10 * scale
            let padY = 6 * scale
            let pill = CGRect(x: origin.x, y: origin.y, width: textSize.width + padX * 2, height: textSize.height + padY * 2)
            let backdrop: Color = item.color == .black ? .white.opacity(0.92) : Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.86)
            context.fill(Path(roundedRect: pill, cornerRadius: 8 * scale), with: .color(backdrop))
            context.stroke(Path(roundedRect: pill, cornerRadius: 8 * scale), with: .color(item.color.swiftUIColor.opacity(0.55)), lineWidth: 1.5)
            context.draw(resolved, at: CGPoint(x: pill.minX + padX, y: pill.minY + padY), anchor: .topLeading)
        }
    }

    private func drawHoverChrome(
        for item: AnnotationItem,
        in context: inout GraphicsContext,
        mapper: CanvasCoordinateMapper
    ) {
        if item.kind == .arrow {
            var line = Path()
            line.move(to: mapper.imagePixelToViewPoint(item.startPoint))
            line.addLine(to: mapper.imagePixelToViewPoint(item.endPoint))
            context.stroke(
                line,
                with: .color(.blue.opacity(0.45)),
                style: StrokeStyle(lineWidth: 2, dash: [4, 3])
            )
            return
        }
        let bounds = mapper.imagePixelToViewRect(item.boundingRect)
        context.stroke(
            Path(bounds),
            with: .color(.blue.opacity(0.45)),
            style: StrokeStyle(lineWidth: 1)
        )
    }

    private func drawSelectionChrome(
        for item: AnnotationItem,
        in context: inout GraphicsContext,
        mapper: CanvasCoordinateMapper
    ) {
        if item.kind == .arrow {
            for pt in [item.startPoint, item.endPoint] {
                let vp = mapper.imagePixelToViewPoint(pt)
                let handle = CGRect(x: vp.x - 5, y: vp.y - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: handle), with: .color(.white))
                context.stroke(Path(ellipseIn: handle), with: .color(.blue), lineWidth: 1.8)
            }
            return
        }

        let bounds = mapper.imagePixelToViewRect(item.boundingRect)
        context.stroke(
            Path(bounds),
            with: .color(.blue.opacity(0.9)),
            style: StrokeStyle(lineWidth: 1.4, dash: [5, 3])
        )

        if item.kind == .rectangle || item.kind == .ellipse || item.kind == .redact {
            let corners = [
                CGPoint(x: bounds.minX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.minY),
                CGPoint(x: bounds.minX, y: bounds.maxY),
                CGPoint(x: bounds.maxX, y: bounds.maxY)
            ]
            for corner in corners {
                let handle = CGRect(x: corner.x - 4.5, y: corner.y - 4.5, width: 9, height: 9)
                context.fill(Path(roundedRect: handle, cornerRadius: 2), with: .color(.white))
                context.stroke(Path(roundedRect: handle, cornerRadius: 2), with: .color(.blue), lineWidth: 1.5)
            }
        }
    }

    private func drawCropOverlay(
        cropPixelRect: CGRect,
        in context: inout GraphicsContext,
        mapper: CanvasCoordinateMapper
    ) {
        let viewCrop = mapper.imagePixelToViewRect(cropPixelRect)
        context.stroke(Path(viewCrop), with: .color(.white), lineWidth: 1.5)

        // Subtle rule-of-thirds interior guides
        if viewCrop.width >= 36, viewCrop.height >= 36 {
            var guides = Path()
            for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                let x = viewCrop.minX + viewCrop.width * fraction
                guides.move(to: CGPoint(x: x, y: viewCrop.minY))
                guides.addLine(to: CGPoint(x: x, y: viewCrop.maxY))
                let y = viewCrop.minY + viewCrop.height * fraction
                guides.move(to: CGPoint(x: viewCrop.minX, y: y))
                guides.addLine(to: CGPoint(x: viewCrop.maxX, y: y))
            }
            context.stroke(guides, with: .color(.white.opacity(0.28)), lineWidth: 0.75)
        }

        // 4 corner handles + 4 edge midpoint bars
        let corners = [
            CGPoint(x: viewCrop.minX, y: viewCrop.minY),
            CGPoint(x: viewCrop.maxX, y: viewCrop.minY),
            CGPoint(x: viewCrop.minX, y: viewCrop.maxY),
            CGPoint(x: viewCrop.maxX, y: viewCrop.maxY)
        ]
        for corner in corners {
            let handle = CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)
            context.fill(Path(roundedRect: handle, cornerRadius: 2), with: .color(.white))
            context.stroke(Path(roundedRect: handle, cornerRadius: 2), with: .color(.black.opacity(0.65)), lineWidth: 1)
        }

        if viewCrop.width >= 40 {
            for edgeY in [viewCrop.minY, viewCrop.maxY] {
                let bar = CGRect(x: viewCrop.midX - 10, y: edgeY - 2, width: 20, height: 4)
                context.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(.white))
                context.stroke(Path(roundedRect: bar, cornerRadius: 2), with: .color(.black.opacity(0.55)), lineWidth: 0.75)
            }
        }
        if viewCrop.height >= 40 {
            for edgeX in [viewCrop.minX, viewCrop.maxX] {
                let bar = CGRect(x: edgeX - 2, y: viewCrop.midY - 10, width: 4, height: 20)
                context.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(.white))
                context.stroke(Path(roundedRect: bar, cornerRadius: 2), with: .color(.black.opacity(0.55)), lineWidth: 0.75)
            }
        }
    }

    // MARK: - Cursor & Hit Helpers

    private func defaultCursor(for tool: ScreenshotTool) -> NSCursor {
        switch tool {
        case .select: return .arrow
        case .text: return .iBeam
        case .arrow, .rectangle, .ellipse, .highlighter, .step, .redact, .crop:
            return .crosshair
        }
    }

    private func cursorForRectCorner(_ corner: QuickScreenshotEditorUIState.RectCorner) -> NSCursor {
        if #available(macOS 15.0, *) {
            switch corner {
            case .topLeft: return .frameResize(position: .topLeft, directions: .all)
            case .topRight: return .frameResize(position: .topRight, directions: .all)
            case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
            }
        }
        return .crosshair
    }

    private func cursorForCropHandle(_ handle: QuickScreenshotEditorUIState.CropHandle) -> NSCursor {
        switch handle {
        case .topLeft:
            return cursorForRectCorner(.topLeft)
        case .topRight:
            return cursorForRectCorner(.topRight)
        case .bottomLeft:
            return cursorForRectCorner(.bottomLeft)
        case .bottomRight:
            return cursorForRectCorner(.bottomRight)
        case .top, .bottom:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        }
    }

    private func hitTestSelectionHandle(
        at viewPoint: CGPoint,
        mapper: CanvasCoordinateMapper
    ) -> QuickScreenshotEditorUIState.SelectionHandleHit? {
        guard let selectedID = session.selectedAnnotationID,
              let selected = session.annotations.first(where: { $0.id == selectedID }) else {
            return nil
        }
        if selected.kind == .arrow {
            let startView = mapper.imagePixelToViewPoint(selected.startPoint)
            let endView = mapper.imagePixelToViewPoint(selected.endPoint)
            if hypot(viewPoint.x - startView.x, viewPoint.y - startView.y) <= 12 {
                return .arrowEndpoint(item: selected, isStart: true)
            }
            if hypot(viewPoint.x - endView.x, viewPoint.y - endView.y) <= 12 {
                return .arrowEndpoint(item: selected, isStart: false)
            }
            return nil
        }
        if selected.kind == .rectangle || selected.kind == .ellipse || selected.kind == .redact {
            let viewBounds = mapper.imagePixelToViewRect(selected.rect)
            let handleTargets: [(QuickScreenshotEditorUIState.RectCorner, CGPoint)] = [
                (.topLeft, CGPoint(x: viewBounds.minX, y: viewBounds.minY)),
                (.topRight, CGPoint(x: viewBounds.maxX, y: viewBounds.minY)),
                (.bottomLeft, CGPoint(x: viewBounds.minX, y: viewBounds.maxY)),
                (.bottomRight, CGPoint(x: viewBounds.maxX, y: viewBounds.maxY))
            ]
            if let hit = handleTargets.first(where: { hypot(viewPoint.x - $0.1.x, viewPoint.y - $0.1.y) <= 12 }) {
                return .rectCorner(item: selected, corner: hit.0)
            }
        }
        return nil
    }

    private func hitTestCropHandle(
        at viewPoint: CGPoint,
        cropPixelRect: CGRect,
        mapper: CanvasCoordinateMapper
    ) -> QuickScreenshotEditorUIState.CropHandle? {
        let viewCrop = mapper.imagePixelToViewRect(cropPixelRect)
        let cornerTargets: [(QuickScreenshotEditorUIState.CropHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: viewCrop.minX, y: viewCrop.minY)),
            (.topRight, CGPoint(x: viewCrop.maxX, y: viewCrop.minY)),
            (.bottomLeft, CGPoint(x: viewCrop.minX, y: viewCrop.maxY)),
            (.bottomRight, CGPoint(x: viewCrop.maxX, y: viewCrop.maxY))
        ]
        if let hit = cornerTargets.first(where: { hypot(viewPoint.x - $0.1.x, viewPoint.y - $0.1.y) <= 12 }) {
            return hit.0
        }
        let edgeTargets: [(QuickScreenshotEditorUIState.CropHandle, CGPoint)] = [
            (.top, CGPoint(x: viewCrop.midX, y: viewCrop.minY)),
            (.bottom, CGPoint(x: viewCrop.midX, y: viewCrop.maxY)),
            (.left, CGPoint(x: viewCrop.minX, y: viewCrop.midY)),
            (.right, CGPoint(x: viewCrop.maxX, y: viewCrop.midY))
        ]
        if let hit = edgeTargets.first(where: { hypot(viewPoint.x - $0.1.x, viewPoint.y - $0.1.y) <= 12 }) {
            return hit.0
        }
        return nil
    }

    private func resolveCanvasCursor(
        at viewPoint: CGPoint,
        mapper: CanvasCoordinateMapper,
        zoomScale: CGFloat,
        isEditingCrop: Bool
    ) -> (NSCursor, UUID?) {
        if isEditingCrop {
            if let crop = uiState.draftCropRect ?? session.cropRect {
                if let handle = hitTestCropHandle(at: viewPoint, cropPixelRect: crop, mapper: mapper) {
                    return (cursorForCropHandle(handle), nil)
                }
                if mapper.imagePixelToViewRect(crop).contains(viewPoint) {
                    return (.openHand, nil)
                }
            }
            return (.crosshair, nil)
        }

        if let handleHit = hitTestSelectionHandle(at: viewPoint, mapper: mapper) {
            switch handleHit {
            case .arrowEndpoint:
                return (.pointingHand, session.selectedAnnotationID)
            case .rectCorner(_, let corner):
                return (cursorForRectCorner(corner), session.selectedAnnotationID)
            }
        }

        let pixelTol = max(6, 10 / max(zoomScale, 0.25))
        let hoverPixel = mapper.viewPointToImagePixel(viewPoint)
        if let hit = session.hitTestAnnotation(
            at: hoverPixel,
            tolerance: pixelTol,
            directEditMode: session.activeTool != .select
        ) {
            return (.openHand, hit.id)
        }

        return (defaultCursor(for: session.activeTool), nil)
    }

    private func updateHoverAndCursor(
        at viewPoint: CGPoint,
        mapper: CanvasCoordinateMapper,
        zoomScale: CGFloat,
        isEditingCrop: Bool
    ) {
        guard uiState.dragStartPixel == nil else { return }
        let (cursor, hoveredID) = resolveCanvasCursor(
            at: viewPoint,
            mapper: mapper,
            zoomScale: zoomScale,
            isEditingCrop: isEditingCrop
        )
        if uiState.hoveredAnnotationID != hoveredID {
            uiState.hoveredAnnotationID = hoveredID
        }
        if uiState.currentCanvasCursor !== cursor {
            uiState.currentCanvasCursor = cursor
        }
    }

    // MARK: - Pointer & Drag Gestures

    private func handleCanvasDragChanged(
        value: DragGesture.Value,
        mapper: CanvasCoordinateMapper,
        zoomScale: CGFloat
    ) {
        let currentPixel = mapper.viewPointToImagePixel(value.location)

        if uiState.dragStartPixel == nil {
            let startPixel = mapper.viewPointToImagePixel(value.startLocation)
            uiState.dragStartPixel = startPixel
            uiState.dragStartViewPoint = value.startLocation
            uiState.dragInitialPan = session.panOffset
            let wasEditingText = (session.editingTextAnnotationID != nil)
            session.finishTextEditing()

            if session.activeTool == .crop {
                if let crop = session.cropRect {
                    if let cropHandle = hitTestCropHandle(at: value.startLocation, cropPixelRect: crop, mapper: mapper) {
                        uiState.dragMode = .resizeCropHandle(initialCrop: crop, handle: cropHandle)
                        uiState.draftCropRect = crop
                        PointerCursorNSView.activeDragCursor = cursorForCropHandle(cropHandle)
                        return
                    }
                    if mapper.imagePixelToViewRect(crop).contains(value.startLocation) {
                        uiState.dragMode = .moveCrop(initialCrop: crop)
                        uiState.draftCropRect = crop
                        PointerCursorNSView.activeDragCursor = .closedHand
                        return
                    }
                }
                uiState.dragMode = .drawCrop
                uiState.draftCropRect = CGRect(origin: startPixel, size: .zero)
                PointerCursorNSView.activeDragCursor = .crosshair
                return
            }

            if let handleHit = hitTestSelectionHandle(at: value.startLocation, mapper: mapper) {
                switch handleHit {
                case .arrowEndpoint(let item, let isStart):
                    uiState.dragInitialAnnotations = session.annotations
                    uiState.dragMode = .moveArrowEndpoint(initialItem: item, isStart: isStart)
                    PointerCursorNSView.activeDragCursor = .closedHand
                case .rectCorner(let item, let corner):
                    uiState.dragInitialAnnotations = session.annotations
                    uiState.dragMode = .resizeRectHandle(initialItem: item, corner: corner)
                    PointerCursorNSView.activeDragCursor = cursorForRectCorner(corner)
                }
                return
            }

            let pixelTol = max(6, 10 / max(zoomScale, 0.25))
            if let hit = session.hitTestAnnotation(
                at: startPixel,
                tolerance: pixelTol,
                directEditMode: session.activeTool != .select
            ) {
                session.selectedAnnotationID = hit.id
                uiState.dragInitialAnnotations = session.annotations
                uiState.dragMode = .moveSelected(initialItem: hit)
                PointerCursorNSView.activeDragCursor = .closedHand
                return
            }

            session.selectedAnnotationID = nil
            switch session.activeTool {
            case .select:
                uiState.dragMode = .panCanvas
                PointerCursorNSView.activeDragCursor = .closedHand
            case .step:
                uiState.dragMode = .placeTap
            case .text:
                uiState.dragMode = wasEditingText ? .none : .placeTap
            default:
                uiState.dragMode = .drawNew
                uiState.draftAnnotation = makeDraftAnnotation(start: startPixel, current: currentPixel, previous: nil)
                PointerCursorNSView.activeDragCursor = .crosshair
            }
            return
        }

        let startPixel = uiState.dragStartPixel ?? currentPixel
        switch uiState.dragMode {
        case .none, .placeTap:
            break
        case .drawNew:
            uiState.draftAnnotation = makeDraftAnnotation(start: startPixel, current: currentPixel, previous: uiState.draftAnnotation)
        case .drawCrop:
            uiState.draftCropRect = CGRect(
                x: min(startPixel.x, currentPixel.x),
                y: min(startPixel.y, currentPixel.y),
                width: abs(currentPixel.x - startPixel.x),
                height: abs(currentPixel.y - startPixel.y)
            )
        case .moveCrop(let initialCrop):
            let maxW = max(1, session.imagePixelSize.width)
            let maxH = max(1, session.imagePixelSize.height)
            let dx = currentPixel.x - startPixel.x
            let dy = currentPixel.y - startPixel.y
            let clampedX = min(max(0, initialCrop.minX + dx), max(0, maxW - initialCrop.width))
            let clampedY = min(max(0, initialCrop.minY + dy), max(0, maxH - initialCrop.height))
            uiState.draftCropRect = CGRect(x: clampedX, y: clampedY, width: initialCrop.width, height: initialCrop.height)
        case .resizeCropHandle(let initialCrop, let handle):
            let maxW = max(12, session.imagePixelSize.width)
            let maxH = max(12, session.imagePixelSize.height)
            let clampedX = min(max(0, currentPixel.x), maxW)
            let clampedY = min(max(0, currentPixel.y), maxH)
            var left = initialCrop.minX
            var right = initialCrop.maxX
            var top = initialCrop.minY
            var bottom = initialCrop.maxY
            switch handle {
            case .topLeft:
                left = min(clampedX, right - 12)
                top = min(clampedY, bottom - 12)
            case .topRight:
                right = max(clampedX, left + 12)
                top = min(clampedY, bottom - 12)
            case .bottomLeft:
                left = min(clampedX, right - 12)
                bottom = max(clampedY, top + 12)
            case .bottomRight:
                right = max(clampedX, left + 12)
                bottom = max(clampedY, top + 12)
            case .top:
                top = min(clampedY, bottom - 12)
            case .bottom:
                bottom = max(clampedY, top + 12)
            case .left:
                left = min(clampedX, right - 12)
            case .right:
                right = max(clampedX, left + 12)
            }
            uiState.draftCropRect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        case .moveSelected(let initialItem):
            let delta = CGSize(width: currentPixel.x - startPixel.x, height: currentPixel.y - startPixel.y)
            session.updateAnnotationInPlace(initialItem.translated(by: delta))
        case .moveArrowEndpoint(let initialItem, let isStart):
            var updated = initialItem
            if isStart {
                updated.startPoint = currentPixel
            } else {
                updated.endPoint = currentPixel
            }
            session.updateAnnotationInPlace(updated)
        case .resizeRectHandle(let initialItem, let corner):
            let r = initialItem.rect
            let anchor: CGPoint
            switch corner {
            case .topLeft: anchor = CGPoint(x: r.maxX, y: r.maxY)
            case .topRight: anchor = CGPoint(x: r.minX, y: r.maxY)
            case .bottomLeft: anchor = CGPoint(x: r.maxX, y: r.minY)
            case .bottomRight: anchor = CGPoint(x: r.minX, y: r.minY)
            }
            var updated = initialItem
            updated.rect = CGRect(
                x: min(anchor.x, currentPixel.x),
                y: min(anchor.y, currentPixel.y),
                width: max(8, abs(currentPixel.x - anchor.x)),
                height: max(8, abs(currentPixel.y - anchor.y))
            )
            session.updateAnnotationInPlace(updated)
        case .panCanvas:
            let startView = uiState.dragStartViewPoint ?? value.startLocation
            session.panOffset = CGSize(
                width: uiState.dragInitialPan.width + (value.location.x - startView.x),
                height: uiState.dragInitialPan.height + (value.location.y - startView.y)
            )
        }
    }

    private func handleCanvasDragEnded(
        value: DragGesture.Value,
        mapper: CanvasCoordinateMapper,
        zoomScale: CGFloat,
        isEditingCrop: Bool
    ) {
        PointerCursorNSView.activeDragCursor = nil
        let endPixel = mapper.viewPointToImagePixel(value.location)
        let dragDistance = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)

        switch uiState.dragMode {
        case .placeTap:
            if session.activeTool == .step {
                session.addStepBadge(at: endPixel)
            } else if session.activeTool == .text {
                session.beginTextCallout(at: endPixel)
            }
        case .drawNew:
            if let draft = uiState.draftAnnotation, isMeaningfulAnnotation(draft) {
                session.addAnnotation(draft)
            }
        case .drawCrop, .moveCrop, .resizeCropHandle:
            if let crop = uiState.draftCropRect, crop.width >= 12, crop.height >= 12 {
                session.setCropRect(crop)
            }
        case .moveSelected(let initialItem):
            if let before = uiState.dragInitialAnnotations {
                let after = session.annotations
                session.commitMutationSnapshot(before: before, after: after)
            }
            if dragDistance < 4 && initialItem.kind == .text {
                let now = ProcessInfo.processInfo.systemUptime
                if uiState.lastTapAnnotationID == initialItem.id && (now - uiState.lastTapTimestamp) <= 0.4 {
                    uiState.lastTapAnnotationID = nil
                    session.beginEditingTextAnnotation(id: initialItem.id)
                } else {
                    uiState.lastTapAnnotationID = initialItem.id
                    uiState.lastTapTimestamp = now
                }
            } else {
                uiState.lastTapAnnotationID = nil
            }
        case .resizeRectHandle, .moveArrowEndpoint:
            uiState.lastTapAnnotationID = nil
            if let before = uiState.dragInitialAnnotations {
                let after = session.annotations
                session.commitMutationSnapshot(before: before, after: after)
            }
        case .none, .panCanvas:
            uiState.lastTapAnnotationID = nil
        }

        uiState.draftAnnotation = nil
        uiState.draftCropRect = nil
        uiState.dragStartPixel = nil
        uiState.dragStartViewPoint = nil
        uiState.dragInitialAnnotations = nil
        uiState.dragMode = .none

        uiState.lastHoverViewPoint = value.location
        updateHoverAndCursor(
            at: value.location,
            mapper: mapper,
            zoomScale: zoomScale,
            isEditingCrop: isEditingCrop
        )
        if let keyWindow = NSApp.keyWindow {
            PointerCursorNSView.syncCursor(in: keyWindow)
        }
    }

    private func cancelInFlightDrag() {
        PointerCursorNSView.activeDragCursor = nil
        uiState.draftAnnotation = nil
        uiState.draftCropRect = nil
        uiState.dragStartPixel = nil
        uiState.dragStartViewPoint = nil
        uiState.dragInitialAnnotations = nil
        uiState.dragMode = .none
    }

    private func makeDraftAnnotation(
        start: CGPoint,
        current: CGPoint,
        previous: AnnotationItem?
    ) -> AnnotationItem {
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        switch session.activeTool {
        case .arrow:
            return AnnotationItem(
                kind: .arrow,
                startPoint: start,
                endPoint: current,
                color: session.selectedColor,
                strokeWidth: session.strokeWidth
            )
        case .rectangle:
            return AnnotationItem(
                kind: .rectangle,
                rect: rect,
                color: session.selectedColor,
                strokeWidth: session.strokeWidth
            )
        case .ellipse:
            return AnnotationItem(
                kind: .ellipse,
                rect: rect,
                color: session.selectedColor,
                strokeWidth: session.strokeWidth
            )
        case .highlighter:
            var pts = previous?.points ?? [start]
            if let last = pts.last, hypot(current.x - last.x, current.y - last.y) >= 3 {
                pts.append(current)
            }
            return AnnotationItem(
                kind: .highlighter,
                points: pts,
                color: session.selectedColor,
                strokeWidth: session.strokeWidth
            )
        case .redact:
            return AnnotationItem(
                kind: .redact,
                rect: rect,
                color: .black,
                strokeWidth: session.strokeWidth,
                redactStyle: session.redactStyle
            )
        default:
            return AnnotationItem(kind: .rectangle, rect: rect)
        }
    }

    private func isMeaningfulAnnotation(_ item: AnnotationItem) -> Bool {
        switch item.kind {
        case .arrow:
            return hypot(item.endPoint.x - item.startPoint.x, item.endPoint.y - item.startPoint.y) >= 6
        case .rectangle, .ellipse, .redact:
            return item.rect.width >= 6 && item.rect.height >= 6
        case .highlighter:
            return item.points.count >= 2
        case .step, .text:
            return true
        }
    }

    private func refreshPixelatedCacheIfNeeded() {
        let filteredKeys = session.annotations
            .filter { $0.kind == .redact && $0.redactStyle != .solidBlack }
            .map { QuickScreenshotEditorUIState.FilteredRedactCacheKey(rect: $0.rect, style: $0.redactStyle) }
        guard filteredKeys != uiState.cachedPixelateKey || uiState.cachedPixelatedImage == nil else { return }
        uiState.cachedPixelateKey = filteredKeys
        guard let base = session.baseImage else {
            uiState.cachedPixelatedImage = nil
            return
        }
        if filteredKeys.isEmpty {
            uiState.cachedPixelatedImage = base
        } else {
            uiState.cachedPixelatedImage = ScreenshotRenderer.renderBaseWithFilteredRedactions(
                baseImage: base,
                annotations: session.annotations
            ) ?? base
        }
    }
}

private struct CropClipShape: Shape {
    let rect: CGRect

    func path(in bounds: CGRect) -> Path {
        Path(rect)
    }
}

private struct CanvasCursorOverlay: NSViewRepresentable {
    let cursor: NSCursor
    let onExit: () -> Void

    func makeNSView(context: Context) -> CanvasCursorNSView {
        let view = CanvasCursorNSView()
        view.customHoverCursor = cursor
        view.onExit = onExit
        return view
    }

    func updateNSView(_ nsView: CanvasCursorNSView, context: Context) {
        nsView.customHoverCursor = cursor
        nsView.onExit = onExit
        if let win = nsView.window, win.isVisible, PointerCursorNSView.isWindowTopmostAtMouse(win) {
            let ptInWindow = win.convertPoint(fromScreen: NSEvent.mouseLocation)
            if PointerCursorNSView.isPoint(ptInWindow, inside: nsView) {
                PointerCursorNSView.syncCursor(in: win)
            }
        }
    }
}

@MainActor
private final class CanvasCursorNSView: NSView, HoverCursorProviderView {
    var customHoverCursor: NSCursor = .arrow
    var onExit: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingArea == nil {
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            self.trackingArea = area
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if let window {
            PointerCursorNSView.syncCursor(in: window)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if let window {
            PointerCursorNSView.syncCursor(in: window)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if let window {
            PointerCursorNSView.syncCursor(in: window)
        } else {
            customHoverCursor.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
        if let window, !PointerCursorNSView.handleCursorUpdate(in: window) {
            NSCursor.arrow.set()
        }
    }
}

private struct ShareAnchorReader: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onResolve(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView)
        }
    }
}
