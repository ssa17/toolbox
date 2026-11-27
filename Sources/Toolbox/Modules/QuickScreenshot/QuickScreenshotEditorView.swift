import AppKit
import Carbon
import CoreText
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
    private let tooltipController = EditorTooltipController()
    nonisolated(unsafe) private var keyMonitor: Any?
    nonisolated(unsafe) private var magnifyMonitor: Any?
    nonisolated(unsafe) private var scrollMonitor: Any?
    private var isClosingBypassConfirm = false
    private weak var shareAnchorView: NSView?
    private weak var canvasAnchorView: NSView?

    init(
        image: CGImage,
        config: QuickScreenshotConfig,
        previousFrontmostApp: NSRunningApplication? = nil,
        onClosed: @escaping (QuickScreenshotEditorWindowController) -> Void
    ) {
        self.session = ScreenshotEditorSession(
            image: image,
            config: config
        )
        self.previousFrontmostApp = previousFrontmostApp
        self.config = config
        self.onClosed = onClosed
        super.init()

        self.session.onPresetsChanged = { presets, activeTool in
            var live = ConfigManager.shared.config.quickScreenshot
            guard live.rememberLastToolSettings else { return }
            var changed = false
            if live.toolPresets != presets {
                live.toolPresets = presets
                changed = true
            }
            if live.lastUsedTool != activeTool {
                live.lastUsedTool = activeTool
                changed = true
            }
            if changed {
                ConfigManager.shared.config.quickScreenshot = live
            }
        }
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let magnifyMonitor {
            NSEvent.removeMonitor(magnifyMonitor)
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
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
        win.minSize = NSSize(width: 820, height: 520)
        win.isReleasedWhenClosed = false
        win.delegate = self
        ToolboxTheme.applyDarkAppearance(to: win)

        let rootView = QuickScreenshotEditorView(
            session: session,
            tooltipController: tooltipController,
            onCanvasAnchor: { [weak self] view in self?.canvasAnchorView = view },
            onCopy: { [weak self] in self?.copyFlattenedToClipboard() },
            onSave: { [weak self] in self?.quickSave() },
            onSaveAs: { [weak self] in self?.saveAsWithPanel() },
            onShare: { [weak self] anchor in self?.shareFlattened(from: anchor) },
            onPin: { [weak self] in self?.pinFlattenedToScreen() },
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
        let maxW = max(960, screenFrame.width * 0.90)
        let maxH = max(640, screenFrame.height * 0.88)
        let aspect = pixelSize.height > 0 ? (pixelSize.width / pixelSize.height) : 1.5
        let targetW = min(maxW, max(1120, pixelSize.width * 0.68 + 180))
        let targetH = min(maxH, max(740, targetW / max(0.5, aspect) + 180))
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
        tooltipController.hide()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let magnifyMonitor {
            NSEvent.removeMonitor(magnifyMonitor)
            self.magnifyMonitor = nil
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
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
                cropRect: session.cropRect,
                beautify: session.beautify
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
                cropRect: session.cropRect,
                beautify: session.beautify
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
                cropRect: session.cropRect,
                beautify: session.beautify
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
                cropRect: session.cropRect,
                beautify: session.beautify
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

    func pinFlattenedToScreen() {
        session.finishTextEditing()
        guard let base = session.baseImage,
              let flattened = ScreenshotRenderer.render(
                baseImage: base,
                annotations: session.annotations,
                cropRect: session.cropRect,
                beautify: session.beautify
              ) else {
            return
        }
        ModuleRegistry.shared.quickScreenshot.pinScreenshot(flattened)
        session.markExported()
        if ConfigManager.shared.config.quickScreenshot.showToast {
            HUDToast.shared.show(
                title: "Pinned screenshot on screen",
                symbol: "pin.fill",
                tint: .red
            )
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
                    let addedCount = self.session.applyAutoRedactSuggestions(matches)
                    if addedCount == 0 {
                        HUDToast.shared.show(
                            title: "All detected secrets are already redacted",
                            symbol: "checkmark.shield",
                            tint: .green
                        )
                    } else {
                        HUDToast.shared.show(
                            title: "Found \(addedCount) sensitive item\(addedCount == 1 ? "" : "s") to review",
                            symbol: "eye.slash.fill",
                            tint: .orange
                        )
                    }
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

    // MARK: - Keyboard Shortcuts & Trackpad Zoom

    private func installKeyMonitor(for window: QuickScreenshotEditorWindow) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let magnifyMonitor {
            NSEvent.removeMonitor(magnifyMonitor)
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            return self.handleKeyDown(event)
        }
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            return self.handleMagnify(event)
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            return self.handleScrollWheel(event)
        }
    }

    private func canvasMetricsForEvent(_ event: NSEvent) -> (anchor: CGPoint, viewportSize: CGSize, fitScale: CGFloat)? {
        guard let canvasView = canvasAnchorView else { return nil }
        let local = canvasView.convert(event.locationInWindow, from: nil)
        guard canvasView.bounds.contains(local) else { return nil }
        let viewportSize = canvasView.bounds.size
        guard viewportSize.width > 10, viewportSize.height > 10 else { return nil }

        let anchor = CGPoint(x: local.x, y: canvasView.bounds.height - local.y)
        let isEditingCrop = (session.activeTool == .crop)
        let beautifyActive = session.beautify.enabled && session.beautify.backdrop != .none && !isEditingCrop
        let beautifyPadPx = beautifyActive ? session.beautify.padding : 0
        let fitTargetSize = CGSize(
            width: session.imagePixelSize.width + beautifyPadPx * 2,
            height: session.imagePixelSize.height + beautifyPadPx * 2
        )
        let fitScale = CanvasCoordinateMapper.fitScale(imageSize: fitTargetSize, viewportSize: viewportSize)
        return (anchor, viewportSize, fitScale)
    }

    private func handleMagnify(_ event: NSEvent) -> NSEvent? {
        guard let (anchor, viewportSize, fitScale) = canvasMetricsForEvent(event) else {
            return event
        }
        let current = session.zoomMode.scaleFactor(fitScale: fitScale)
        let target = current * (1.0 + event.magnification)
        session.setZoomAnchored(to: target, anchorViewPoint: anchor, viewportSize: viewportSize, fitScale: fitScale)
        return nil
    }

    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard let (anchor, viewportSize, fitScale) = canvasMetricsForEvent(event) else {
            return event
        }
        let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if mods.contains(.shift) || mods.contains(.command) || mods.contains(.option) {
            let rawDelta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
                ? event.scrollingDeltaY
                : event.scrollingDeltaX
            guard abs(rawDelta) > 0.001 else { return nil }
            let factorDelta = event.hasPreciseScrollingDeltas ? rawDelta * 0.008 : rawDelta * 0.06
            let current = session.zoomMode.scaleFactor(fitScale: fitScale)
            let target = current * exp(factorDelta)
            session.setZoomAnchored(to: target, anchorViewPoint: anchor, viewportSize: viewportSize, fitScale: fitScale)
            return nil
        }

        if mods.isEmpty && session.zoomMode != .fit {
            session.panOffset = CGSize(
                width: session.panOffset.width + event.scrollingDeltaX,
                height: session.panOffset.height + event.scrollingDeltaY
            )
            return nil
        }
        return event
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
            case "d":
                session.duplicateSelected()
                return nil
            case "p":
                pinFlattenedToScreen()
                return nil
            case "]":
                session.bringSelectedToFront()
                return nil
            case "[":
                session.sendSelectedToBack()
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

        if session.selectedAnnotationID != nil,
           mods.isEmpty || mods == [.shift] {
            let step: CGFloat = mods == [.shift] ? 10 : 1
            switch Int(event.keyCode) {
            case kVK_LeftArrow:
                session.nudgeSelected(dx: -step, dy: 0)
                return nil
            case kVK_RightArrow:
                session.nudgeSelected(dx: step, dy: 0)
                return nil
            case kVK_UpArrow:
                session.nudgeSelected(dx: 0, dy: -step)
                return nil
            case kVK_DownArrow:
                session.nudgeSelected(dx: 0, dy: step)
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
            if chars == "b" {
                session.updateBeautify { $0.enabled.toggle() }
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
        case resizeTextHandle(initialItem: AnnotationItem, initialBounds: CGRect, corner: RectCorner)
        case resizeTextEdge(initialItem: AnnotationItem, initialBounds: CGRect, edge: BoxEdge)
        case moveArrowEndpoint(initialItem: AnnotationItem, isStart: Bool)
        case drawCrop
        case resizeCropHandle(initialCrop: CGRect, handle: CropHandle)
        case moveCrop(initialCrop: CGRect)
        case panCanvas
    }

    enum RectCorner {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    enum BoxEdge {
        case top, bottom, left, right
    }

    enum CropHandle {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
    }

    enum SelectionHandleHit {
        case arrowEndpoint(item: AnnotationItem, isStart: Bool)
        case rectCorner(item: AnnotationItem, corner: RectCorner)
        case textCorner(item: AnnotationItem, bounds: CGRect, corner: RectCorner)
        case textEdge(item: AnnotationItem, bounds: CGRect, edge: BoxEdge)
    }

    @Published var draftAnnotation: AnnotationItem? = nil
    @Published var draftCropRect: CGRect? = nil
    @Published var cachedPixelatedImage: CGImage? = nil
    @Published var hoveredAnnotationID: UUID? = nil
    @Published var currentCanvasCursor: NSCursor = .arrow
    @Published var isInspectingBeautify: Bool = false
    @Published var showShortcutsPopover: Bool = false
    @Published var savedDefaultBadge: Bool = false

    struct FilteredRedactCacheKey: Equatable {
        let rect: CGRect
        let style: RedactStyle
        let strength: RedactStrength
        let solidColor: RedactSolidColor
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
    var tooltipController: EditorTooltipController? = nil
    var onCanvasAnchor: ((NSView) -> Void)? = nil
    let onCopy: () -> Void
    let onSave: () -> Void
    let onSaveAs: () -> Void
    let onShare: (NSView?) -> Void
    var onPin: () -> Void = {}
    let onAutoRedact: () -> Void
    let onCopyOCR: () -> Void
    let onRequestClose: () -> Void

    @ObservedObject private var configManager = ConfigManager.shared
    @StateObject private var uiState = QuickScreenshotEditorUIState()

    private static let toolGroups: [[ScreenshotTool]] = [
        [.select],
        [.arrow, .rectangle, .ellipse, .highlighter],
        [.text, .step],
        [.redact, .crop]
    ]

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
        .environment(\.editorTooltipController, tooltipController)
        .toolboxDarkAppearance()
        .onAppear {
            refreshPixelatedCacheIfNeeded()
        }
        .onChange(of: session.annotations) { _, _ in
            refreshPixelatedCacheIfNeeded()
        }
        .onChange(of: session.selectedAnnotationID) { _, newValue in
            if newValue != nil {
                uiState.isInspectingBeautify = false
            }
        }
        .onDisappear {
            PointerCursorNSView.activeDragCursor = nil
            tooltipController?.hide()
        }
    }

    // MARK: - Top Toolbar

    private var topToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                toolButtonsCluster

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Button {
                        session.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 28, height: 26)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!session.canUndo)
                    .editorTooltip("Undo (⌘ Z)")
                    .pointerCursor(session.canUndo)

                    Button {
                        session.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .frame(width: 28, height: 26)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!session.canRedo)
                    .editorTooltip("Redo (⇧ ⌘ Z)")
                    .pointerCursor(session.canRedo)
                }

                Divider().frame(height: 18).opacity(0.45)

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
                                .padding(.horizontal, 9)
                                .frame(height: 28)
                                .background(
                                    isSelected ? Color.white.opacity(0.20) : Color.white.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                        .focusEffectDisabled()
                        .editorTooltip(mode == .fit ? "Zoom to Fit (⌘ 0 · Pinch or ⇧-Scroll to zoom)" : "Zoom to \(mode.label)")
                        .pointerCursor()
                    }

                    if case .custom = session.zoomMode {
                        Text(session.zoomMode.label)
                            .toolboxFont(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(Color.white.opacity(0.20), in: RoundedRectangle(cornerRadius: 6))
                            .fixedSize(horizontal: true, vertical: false)
                            .help("Current custom zoom (Pinch or ⇧-Scroll to adjust)")
                    }
                }

                Button {
                    uiState.showShortcutsPopover.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .toolboxFont(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 28)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .editorTooltip("Keyboard Shortcuts & Zoom Controls")
                .pointerCursor()
                .popover(isPresented: $uiState.showShortcutsPopover, arrowEdge: .bottom) {
                    shortcutsPopoverContent
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().opacity(0.35)

            contextualInspectorBar
                .frame(minHeight: 36)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .background(Color(red: 0.11, green: 0.12, blue: 0.15))
    }

    private var toolButtonsCluster: some View {
        HStack(spacing: 5) {
            ForEach(Array(Self.toolGroups.enumerated()), id: \.offset) { groupIdx, group in
                if groupIdx > 0 {
                    Divider().frame(height: 20).opacity(0.45)
                }
                HStack(spacing: 3) {
                    ForEach(group) { tool in
                        toolIconButton(for: tool)
                    }
                }
            }

            Divider().frame(height: 20).opacity(0.45)
            beautifyToolbarButton
        }
    }

    private func toolIconButton(for tool: ScreenshotTool) -> some View {
        let selected = !uiState.isInspectingBeautify && session.activeTool == tool
        let fg: Color = selected ? .white : .primary.opacity(0.86)
        let bg: Color = selected ? .white.opacity(0.20) : .white.opacity(0.04)
        let border: Color = selected ? .white.opacity(0.32) : .clear

        return Button {
            uiState.isInspectingBeautify = false
            session.selectTool(tool)
        } label: {
            Image(systemName: tool.symbolName)
                .toolboxFont(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 32)
                .foregroundStyle(fg)
                .background(bg, in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(border, lineWidth: 0.9)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .editorTooltip("\(tool.label) (\(tool.shortcutKey))")
        .pointerCursor()
    }

    private var beautifyToolbarButton: some View {
        let inspecting = uiState.isInspectingBeautify
        let enabled = session.beautify.enabled
        let fg: Color = (inspecting || enabled) ? .white : .primary.opacity(0.86)
        let bg: Color = inspecting ? .white.opacity(0.20) : (enabled ? .blue.opacity(0.26) : .white.opacity(0.05))
        let border: Color = inspecting ? .white.opacity(0.32) : (enabled ? .blue.opacity(0.45) : .white.opacity(0.08))

        return Button {
            if uiState.isInspectingBeautify {
                uiState.isInspectingBeautify = false
            } else {
                uiState.isInspectingBeautify = true
                if !session.beautify.enabled {
                    session.updateBeautify { $0.enabled = true }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles.rectangle.stack")
                    .toolboxFont(.system(size: 13, weight: .semibold))
                Text("Beautify")
                    .toolboxFont(.caption.weight(.medium))
                    .lineLimit(1)
                if enabled {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .foregroundStyle(fg)
            .background(bg, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(border, lineWidth: 0.9)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .focusEffectDisabled()
        .editorTooltip("Beautify backdrop & rounded frame (B)")
        .pointerCursor()
    }

    private var shortcutsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Editor Shortcuts")
                .toolboxFont(.caption.weight(.bold))
                .foregroundStyle(.primary)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    shortcutRow("S", "Select / Pan")
                    shortcutRow("A", "Arrow / Line")
                    shortcutRow("R", "Rectangle / Spotlight")
                    shortcutRow("E", "Ellipse / Spotlight")
                    shortcutRow("H", "Highlight")
                    shortcutRow("T", "Text Callout")
                    shortcutRow("N", "Number Badge")
                    shortcutRow("X", "Redact / Erase")
                    shortcutRow("C", "Crop")
                }
                VStack(alignment: .leading, spacing: 4) {
                    shortcutRow("B", "Toggle Beautify")
                    shortcutRow("Pinch / ⇧ Scroll", "Zoom Canvas")
                    shortcutRow("⇧ Drag", "Snap 45° / Square")
                    shortcutRow("⌘ D", "Duplicate Selected")
                    shortcutRow("⌘ P", "Pin on Screen")
                    shortcutRow("⌘ [ / ]", "Back / Front")
                    shortcutRow("Arrows", "Nudge 1px (⇧ 10px)")
                    shortcutRow("⌘ Z / ⇧⌘Z", "Undo / Redo")
                    shortcutRow("⌘ C / ⏎", "Copy Screenshot")
                    shortcutRow("⌘ S", "Quick Save")
                }
            }
        }
        .padding(14)
        .frame(width: 380)
        .toolboxDarkAppearance()
    }

    private func shortcutRow(_ keys: String, _ desc: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .toolboxFont(.caption2.monospaced().weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                .frame(minWidth: 56, alignment: .center)
            Text(desc)
                .toolboxFont(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Contextual Inspector Bar

    private var contextualInspectorBar: some View {
        let selectedAnnotation = session.selectedAnnotationID.flatMap { id in
            session.annotations.first(where: { $0.id == id })
        }

        return HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if uiState.isInspectingBeautify {
                        beautifyInspectorContent
                    } else if let selected = selectedAnnotation {
                        inspectorContent(forKind: selected.kind, selectedItem: selected)
                    } else {
                        inspectorContent(forTool: session.activeTool)
                    }
                }
            }

            Spacer(minLength: 4)

            if !uiState.isInspectingBeautify, selectedAnnotation != nil {
                selectionActionsCluster
            }

            if !configManager.config.quickScreenshot.rememberLastToolSettings,
               selectedAnnotation == nil,
               session.activeTool != .select {
                Button {
                    saveCurrentToolAsDefault()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: uiState.savedDefaultBadge ? "checkmark" : "pin")
                            .toolboxFont(.caption2.weight(.semibold))
                        Text(uiState.savedDefaultBadge ? "Saved" : "Set Default")
                            .toolboxFont(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Save this tool's current style as your default")
                .pointerCursor()
            }
        }
    }

    @ViewBuilder
    private func inspectorContent(forTool tool: ScreenshotTool) -> some View {
        switch tool {
        case .select:
            HStack(spacing: 10) {
                Text("Click an item to edit · Drag canvas to pan · ⌘D duplicate · Arrows nudge")
                    .toolboxFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !session.annotations.isEmpty {
                    Button("Clear All") {
                        session.clearAllAnnotations()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .pointerCursor()
                }
            }
        case .arrow:
            arrowInspector(
                color: session.toolPresets.arrow.color,
                strokeWidth: session.toolPresets.arrow.strokeWidth,
                arrowStyle: session.toolPresets.arrow.style,
                dashStyle: session.toolPresets.arrow.dashStyle
            )
        case .rectangle:
            shapeInspector(
                isRectangle: true,
                color: session.toolPresets.rectangle.color,
                strokeWidth: session.toolPresets.rectangle.strokeWidth,
                fillStyle: session.toolPresets.rectangle.fillStyle,
                cornerRadius: session.toolPresets.rectangle.cornerRadius,
                dashStyle: session.toolPresets.rectangle.dashStyle
            )
        case .ellipse:
            shapeInspector(
                isRectangle: false,
                color: session.toolPresets.ellipse.color,
                strokeWidth: session.toolPresets.ellipse.strokeWidth,
                fillStyle: session.toolPresets.ellipse.fillStyle,
                cornerRadius: .rounded,
                dashStyle: session.toolPresets.ellipse.dashStyle
            )
        case .highlighter:
            highlighterInspector(
                color: session.toolPresets.highlighter.color,
                strokeWidth: session.toolPresets.highlighter.strokeWidth,
                mode: session.toolPresets.highlighter.mode,
                opacity: session.toolPresets.highlighter.opacity,
                showModePicker: true
            )
            case .text:
            textInspector(
                color: session.toolPresets.text.color,
                fontSize: session.toolPresets.text.fontSize,
                backgroundStyle: session.toolPresets.text.backgroundStyle,
                weightStyle: session.toolPresets.text.weightStyle,
                cornerRadius: session.toolPresets.text.cornerRadius
            )
        case .step:
            stepInspector(
                color: session.toolPresets.step.color,
                size: session.toolPresets.step.size,
                style: session.toolPresets.step.style,
                showNextCounter: true
            )
        case .redact:
            redactInspector(
                style: session.toolPresets.redact.style,
                strength: session.toolPresets.redact.strength,
                solidColor: session.toolPresets.redact.solidColor
            )
        case .crop:
            cropInspector
        }
    }

    @ViewBuilder
    private func inspectorContent(forKind kind: AnnotationKind, selectedItem: AnnotationItem) -> some View {
        switch kind {
        case .arrow:
            arrowInspector(
                color: selectedItem.color,
                strokeWidth: selectedItem.strokeWidth,
                arrowStyle: selectedItem.arrowStyle,
                dashStyle: selectedItem.dashStyle
            )
        case .rectangle:
            shapeInspector(
                isRectangle: true,
                color: selectedItem.color,
                strokeWidth: selectedItem.strokeWidth,
                fillStyle: selectedItem.fillStyle,
                cornerRadius: selectedItem.cornerRadius,
                dashStyle: selectedItem.dashStyle
            )
        case .ellipse:
            shapeInspector(
                isRectangle: false,
                color: selectedItem.color,
                strokeWidth: selectedItem.strokeWidth,
                fillStyle: selectedItem.fillStyle,
                cornerRadius: .rounded,
                dashStyle: selectedItem.dashStyle
            )
        case .highlighter:
            highlighterInspector(
                color: selectedItem.color,
                strokeWidth: selectedItem.strokeWidth,
                mode: selectedItem.highlighterMode,
                opacity: selectedItem.highlighterOpacity,
                showModePicker: false
            )
        case .text:
            textInspector(
                color: selectedItem.color,
                fontSize: selectedItem.effectiveTextFontSize,
                backgroundStyle: selectedItem.textBackgroundStyle,
                weightStyle: selectedItem.textWeightStyle,
                cornerRadius: selectedItem.textCornerRadius
            )
        case .step:
            stepInspector(
                color: selectedItem.color,
                size: selectedItem.effectiveStepRadius,
                style: selectedItem.stepStyle,
                showNextCounter: false
            )
        case .redact:
            redactInspector(
                style: selectedItem.redactStyle,
                strength: selectedItem.redactStrength,
                solidColor: selectedItem.redactSolidColor
            )
        }
    }

    private func arrowInspector(
        color: AnnotationColor,
        strokeWidth: CGFloat,
        arrowStyle: ArrowStyle,
        dashStyle: StrokeDashStyle
    ) -> some View {
        HStack(spacing: 10) {
            colorSwatchStrip(activeColor: color)
            Divider().frame(height: 16).opacity(0.45)
            strokeWeightStrip(activeWidth: strokeWidth)
            Divider().frame(height: 16).opacity(0.45)
            HStack(spacing: 3) {
                ForEach(ArrowStyle.allCases) { style in
                    let active = arrowStyle == style
                    Button {
                        session.updateArrowStyle(style)
                    } label: {
                        Image(systemName: style.symbolName)
                            .toolboxFont(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 28)
                            .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .editorTooltip("Arrow Style: \(style.label)")
                    .pointerCursor()
                }
            }
            if arrowStyle != .tapered {
                Divider().frame(height: 18).opacity(0.45)
                dashToggleStrip(activeDash: dashStyle)
            }
        }
    }

    private func shapeInspector(
        isRectangle: Bool,
        color: AnnotationColor,
        strokeWidth: CGFloat,
        fillStyle: ShapeFillStyle,
        cornerRadius: CornerRadiusPreset,
        dashStyle: StrokeDashStyle
    ) -> some View {
        HStack(spacing: 10) {
            colorSwatchStrip(activeColor: color)
            Divider().frame(height: 18).opacity(0.45)
            HStack(spacing: 3) {
                ForEach(ShapeFillStyle.allCases) { fill in
                    let active = fillStyle == fill
                    Button {
                        session.updateFillStyle(fill)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: fill.symbolName)
                                .toolboxFont(.system(size: 11, weight: .semibold))
                            Text(fill.label)
                                .toolboxFont(.caption2.weight(.medium))
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .focusEffectDisabled()
                    .editorTooltip(fill == .spotlight ? "Spotlight: Dim everything outside this shape" : "Fill: \(fill.label)")
                    .pointerCursor()
                }
            }
            if fillStyle != .solid {
                Divider().frame(height: 18).opacity(0.45)
                strokeWeightStrip(activeWidth: strokeWidth)
            }
            if isRectangle {
                Divider().frame(height: 18).opacity(0.45)
                HStack(spacing: 3) {
                    ForEach(CornerRadiusPreset.allCases) { preset in
                        let active = cornerRadius == preset
                        Button {
                            session.updateCornerRadius(preset)
                        } label: {
                            Text(preset.label)
                                .toolboxFont(.caption2.weight(.medium))
                                .padding(.horizontal, 9)
                                .frame(height: 28)
                                .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                        .focusEffectDisabled()
                        .editorTooltip("Corner Radius: \(preset.label)")
                        .pointerCursor()
                    }
                }
            }
            if fillStyle != .solid {
                Divider().frame(height: 18).opacity(0.45)
                dashToggleStrip(activeDash: dashStyle)
            }
        }
    }

    private func highlighterInspector(
        color: AnnotationColor,
        strokeWidth: CGFloat,
        mode: HighlighterMode,
        opacity: HighlighterOpacity,
        showModePicker: Bool
    ) -> some View {
        HStack(spacing: 10) {
            colorSwatchStrip(activeColor: color)
            if showModePicker {
                Divider().frame(height: 18).opacity(0.45)
                HStack(spacing: 3) {
                    ForEach(HighlighterMode.allCases) { m in
                        let active = mode == m
                        Button {
                            session.updateHighlighterMode(m)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: m.symbolName)
                                    .toolboxFont(.system(size: 11, weight: .semibold))
                                Text(m.label)
                                    .toolboxFont(.caption2.weight(.medium))
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                        .focusEffectDisabled()
                        .editorTooltip(m == .box ? "Box Highlight: Drag a straight rectangular band" : "Freehand Marker")
                        .pointerCursor()
                    }
                }
            }
            if mode == .freehand {
                Divider().frame(height: 18).opacity(0.45)
                strokeWeightStrip(activeWidth: strokeWidth, widths: [3.0, 5.0, 8.0, 12.0])
            }
            Divider().frame(height: 18).opacity(0.45)
            HStack(spacing: 3) {
                ForEach(HighlighterOpacity.allCases) { op in
                    let active = opacity == op
                    Button {
                        session.updateHighlighterOpacity(op)
                    } label: {
                        Text(op.label)
                            .toolboxFont(.caption2.weight(.medium))
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .focusEffectDisabled()
                    .editorTooltip("Highlight Opacity: \(op.label)")
                    .pointerCursor()
                }
            }
        }
    }

    private func textInspector(
        color: AnnotationColor,
        fontSize: CGFloat,
        backgroundStyle: TextBackgroundStyle,
        weightStyle: TextWeightStyle,
        cornerRadius: CornerRadiusPreset
    ) -> some View {
        HStack(spacing: 10) {
            colorSwatchStrip(activeColor: color)
            Divider().frame(height: 18).opacity(0.45)
            HStack(spacing: 3) {
                ForEach(TextBackgroundStyle.allCases) { bg in
                    let active = backgroundStyle == bg
                    Button {
                        session.updateTextBackgroundStyle(bg)
                    } label: {
                        Text(bg.label)
                            .toolboxFont(.caption2.weight(.medium))
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .focusEffectDisabled()
                    .editorTooltip(
                        bg == .filled ? "Filled Color Pill"
                        : (bg == .pill ? "Dark Backdrop Pill" : "Plain Shadowed Text")
                    )
                    .pointerCursor()
                }
            }
            if backgroundStyle != .plain {
                Divider().frame(height: 18).opacity(0.45)
                HStack(spacing: 3) {
                    ForEach(CornerRadiusPreset.allCases) { preset in
                        let active = cornerRadius == preset
                        Button {
                            session.updateTextCornerRadius(preset)
                        } label: {
                            Text(preset.label)
                                .toolboxFont(.caption2.weight(.medium))
                                .padding(.horizontal, 9)
                                .frame(height: 28)
                                .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                        .focusEffectDisabled()
                        .editorTooltip("Pill Rounding: \(preset.label)")
                        .pointerCursor()
                    }
                }
            }
            Divider().frame(height: 18).opacity(0.45)
            HStack(spacing: 3) {
                ForEach(TextWeightStyle.allCases) { w in
                    let active = weightStyle == w
                    Button {
                        session.updateTextWeightStyle(w)
                    } label: {
                        Text(w.shortLabel)
                            .toolboxFont(.caption2.weight(.medium))
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .focusEffectDisabled()
                    .editorTooltip("Font Style: \(w.label)")
                    .pointerCursor()
                }
            }
            Divider().frame(height: 18).opacity(0.45)
            Text("\(Int(fontSize.rounded())) pt · Drag corners / edges")
                .toolboxFont(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .editorTooltip("Drag corners to resize text · Drag edges for pill size")
        }
    }

    private func stepInspector(
        color: AnnotationColor,
        size: CGFloat,
        style: StepBadgeStyle,
        showNextCounter: Bool
    ) -> some View {
        HStack(spacing: 10) {
            colorSwatchStrip(activeColor: color)
            Divider().frame(height: 18).opacity(0.45)
            HStack(spacing: 3) {
                ForEach([("S", 18.0), ("M", 22.0), ("L", 28.0)], id: \.0) { label, val in
                    let active = abs(size - CGFloat(val)) < 2.5
                    Button {
                        session.updateStepSize(CGFloat(val))
                    } label: {
                        Text(label)
                            .toolboxFont(.caption2.weight(.semibold))
                            .frame(width: 28, height: 28)
                            .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .editorTooltip("Badge Size: \(label)")
                    .pointerCursor()
                }
            }
            Divider().frame(height: 18).opacity(0.45)
            HStack(spacing: 3) {
                ForEach(StepBadgeStyle.allCases) { badgeStyle in
                    let active = style == badgeStyle
                    Button {
                        session.updateStepStyle(badgeStyle)
                    } label: {
                        Text(badgeStyle.label)
                            .toolboxFont(.caption2.weight(.medium))
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .focusEffectDisabled()
                    .editorTooltip("Badge Style: \(badgeStyle.label)")
                    .pointerCursor()
                }
            }
            if showNextCounter {
                Divider().frame(height: 18).opacity(0.45)
                HStack(spacing: 4) {
                    Text("Next:")
                        .toolboxFont(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Button {
                        session.setNextStepNumber(session.nextStepNumber - 1)
                    } label: {
                        Image(systemName: "minus")
                            .toolboxFont(.system(size: 10.5, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(session.nextStepNumber <= 1)
                    .editorTooltip("Decrease Next Number")
                    .pointerCursor(session.nextStepNumber > 1)

                    Text("#\(session.nextStepNumber)")
                        .toolboxFont(.caption2.monospacedDigit().weight(.bold))
                        .frame(minWidth: 26)

                    Button {
                        session.setNextStepNumber(session.nextStepNumber + 1)
                    } label: {
                        Image(systemName: "plus")
                            .toolboxFont(.system(size: 10.5, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .editorTooltip("Increase Next Number")
                    .pointerCursor()

                    if session.nextStepNumber > 1 {
                        Button("Reset") {
                            session.resetStepNumber()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .editorTooltip("Reset Next Number to #1")
                        .pointerCursor()
                    }
                }
            }
        }
    }

    private func redactInspector(
        style: RedactStyle,
        strength: RedactStrength,
        solidColor: RedactSolidColor
    ) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(RedactStyle.allCases) { candidate in
                    let active = style == candidate
                    Button {
                        session.updateRedactStyleForExistingSelectionOrTool(candidate)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: candidate.symbolName)
                                .toolboxFont(.system(size: 11, weight: .semibold))
                            Text(candidate.shortLabel)
                                .toolboxFont(.caption2.weight(.medium))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .focusEffectDisabled()
                    .editorTooltip(candidate == .smartErase ? "Smart Erase: Matches surrounding background" : candidate.label)
                    .pointerCursor()
                }
            }

            Divider().frame(height: 18).opacity(0.45)

            if style == .pixelate || style == .blur {
                HStack(spacing: 3) {
                    Text("Strength")
                        .toolboxFont(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 3)
                    ForEach(RedactStrength.allCases) { level in
                        let active = strength == level
                        Button {
                            session.updateRedactStrength(level)
                        } label: {
                            Text(level.label)
                                .toolboxFont(.caption2.weight(.medium))
                                .padding(.horizontal, 9)
                                .frame(height: 28)
                                .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                        .focusEffectDisabled()
                        .editorTooltip("Redaction Strength: \(level.fullLabel)")
                        .pointerCursor()
                    }
                }
            } else if style == .solidBlack {
                HStack(spacing: 4) {
                    Text("Fill")
                        .toolboxFont(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(RedactSolidColor.allCases) { fill in
                        let active = solidColor == fill
                        Button {
                            session.updateRedactSolidColor(fill)
                        } label: {
                            Circle()
                                .fill(fill.swiftUIColor)
                                .frame(width: 16, height: 16)
                                .overlay(
                                    Circle()
                                        .strokeBorder(active ? Color.white : Color.white.opacity(0.32), lineWidth: active ? 2.2 : 1)
                                )
                                .frame(width: 24, height: 24)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .editorTooltip("Solid Fill Color: \(fill.label)")
                        .pointerCursor()
                    }
                }
            } else {
                Text("Samples surrounding background to erase cleanly")
                    .toolboxFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var cropInspector: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(CropAspectRatio.allCases) { aspect in
                    let active = session.toolPresets.crop.aspectRatio == aspect
                    Button {
                        session.updateCropAspectRatio(aspect)
                    } label: {
                        Text(aspect.label)
                            .toolboxFont(.caption2.weight(.medium))
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .focusEffectDisabled()
                    .editorTooltip("Crop Aspect Ratio: \(aspect.label)")
                    .pointerCursor()
                }
            }

            if let crop = uiState.draftCropRect ?? session.cropRect {
                Divider().frame(height: 18).opacity(0.45)
                Text("\(Int(crop.width)) × \(Int(crop.height)) px")
                    .toolboxFont(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)

                Button("Apply") {
                    session.selectTool(.select)
                }
                .buttonStyle(.toolboxProminent(.red))
                .controlSize(.small)
                .editorTooltip("Apply Crop (Return)")
                .pointerCursor()

                Button("Reset") {
                    session.clearCrop()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .editorTooltip("Clear Crop")
                .pointerCursor()
            } else {
                Text("Drag on canvas to set crop · Hold ⇧ for square")
                    .toolboxFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var beautifyInspectorContent: some View {
        let b = session.beautify
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { b.enabled },
                set: { enabled in session.updateBeautify { $0.enabled = enabled } }
            )) {
                Text("Enable")
                    .toolboxFont(.caption2.weight(.medium))
            }
            .toggleStyle(.checkbox)
            .editorTooltip("Toggle Beautify Gradient Frame (B)")
            .pointerCursor()

            Divider().frame(height: 18).opacity(0.45)

            HStack(spacing: 3) {
                ForEach(BeautifyBackdrop.allCases.filter { $0 != .none }) { backdrop in
                    let active = b.backdrop == backdrop
                    Button {
                        session.updateBeautify {
                            $0.enabled = true
                            $0.backdrop = backdrop
                        }
                    } label: {
                        Circle()
                            .fill(backdrop.swiftUIGradient)
                            .frame(width: 17, height: 17)
                            .overlay(
                                Circle()
                                    .strokeBorder(active ? Color.white : Color.white.opacity(0.32), lineWidth: active ? 2.2 : 1)
                            )
                            .frame(width: 24, height: 24)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .editorTooltip("Backdrop: \(backdrop.label)")
                    .pointerCursor()
                }
            }

            Divider().frame(height: 18).opacity(0.45)

            HStack(spacing: 3) {
                Text("Pad")
                    .toolboxFont(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 2)
                ForEach([("S", 24.0), ("M", 48.0), ("L", 80.0)], id: \.0) { label, val in
                    let active = abs(b.padding - CGFloat(val)) < 4
                    Button {
                        session.updateBeautify {
                            $0.enabled = true
                            $0.padding = CGFloat(val)
                        }
                    } label: {
                        Text(label)
                            .toolboxFont(.caption2.weight(.medium))
                            .frame(width: 28, height: 28)
                            .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .editorTooltip("Frame Padding: \(Int(val)) px")
                    .pointerCursor()
                }
            }

            Divider().frame(height: 18).opacity(0.45)

            HStack(spacing: 3) {
                Text("Radius")
                    .toolboxFont(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 2)
                ForEach([("0", 0.0), ("12", 14.0), ("22", 22.0)], id: \.0) { label, val in
                    let active = abs(b.cornerRadius - CGFloat(val)) < 3
                    Button {
                        session.updateBeautify {
                            $0.enabled = true
                            $0.cornerRadius = CGFloat(val)
                        }
                    } label: {
                        Text(label)
                            .toolboxFont(.caption2.monospacedDigit().weight(.medium))
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .focusEffectDisabled()
                    .editorTooltip("Screenshot Corner Radius: \(label) px")
                    .pointerCursor()
                }
            }

            Divider().frame(height: 18).opacity(0.45)

            Button {
                session.updateBeautify { $0.shadowEnabled.toggle() }
            } label: {
                Text("Shadow")
                    .toolboxFont(.caption2.weight(.medium))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(b.shadowEnabled ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .focusEffectDisabled()
            .editorTooltip("Toggle Drop Shadow")
            .pointerCursor()
        }
    }

    private var selectionActionsCluster: some View {
        HStack(spacing: 4) {
            Divider().frame(height: 18).opacity(0.45)
            Button {
                session.duplicateSelected()
            } label: {
                Image(systemName: "plus.square.on.square")
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .editorTooltip("Duplicate Selected (⌘ D)")
            .pointerCursor()

            Button {
                session.sendSelectedToBack()
            } label: {
                Image(systemName: "square.2.layers.3d.bottom.filled")
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .editorTooltip("Send Backward (⌘ [)")
            .pointerCursor()

            Button {
                session.bringSelectedToFront()
            } label: {
                Image(systemName: "square.2.layers.3d.top.filled")
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .editorTooltip("Bring Forward (⌘ ])")
            .pointerCursor()

            Button {
                session.deleteSelected()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .editorTooltip("Delete Selected (⌫)")
            .pointerCursor()
        }
    }

    private func colorSwatchStrip(activeColor: AnnotationColor) -> some View {
        HStack(spacing: 2) {
            ForEach(AnnotationColor.allCases) { color in
                let isSelected = activeColor == color
                Button {
                    session.updateColorForExistingSelectionOrTool(color)
                } label: {
                    Circle()
                        .fill(color.swiftUIColor)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    isSelected ? Color.white : Color.white.opacity(0.28),
                                    lineWidth: isSelected ? 2.2 : 1
                                )
                        )
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .editorTooltip("Color: \(color.label)")
                .pointerCursor()
            }
        }
    }

    private func strokeWeightStrip(
        activeWidth: CGFloat,
        widths: [Double] = [2.0, 4.0, 7.0, 11.0]
    ) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(widths.enumerated()), id: \.offset) { idx, width in
                let isSelected = abs(activeWidth - CGFloat(width)) < 1.1
                let barHeight = CGFloat(1.5 + Double(idx) * 1.5)
                Button {
                    session.updateStrokeWidthForExistingSelectionOrTool(CGFloat(width))
                } label: {
                    Capsule()
                        .fill(isSelected ? Color.white : Color.white.opacity(0.55))
                        .frame(width: 16, height: barHeight)
                        .frame(width: 28, height: 28)
                        .background(
                            isSelected ? Color.white.opacity(0.20) : Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .editorTooltip("Stroke Thickness: \(Int(width)) px")
                .pointerCursor()
            }
        }
    }

    private func dashToggleStrip(activeDash: StrokeDashStyle) -> some View {
        HStack(spacing: 3) {
            ForEach(StrokeDashStyle.allCases) { dash in
                let active = activeDash == dash
                Button {
                    session.updateDashStyle(dash)
                } label: {
                    Image(systemName: dash.symbolName)
                        .toolboxFont(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 28)
                        .background(active ? Color.white.opacity(0.20) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .editorTooltip("\(dash.label) Stroke")
                .pointerCursor()
            }
        }
    }

    private func saveCurrentToolAsDefault() {
        var cfg = configManager.config.quickScreenshot
        switch session.activeTool {
        case .arrow: cfg.toolPresets.arrow = session.toolPresets.arrow
        case .rectangle: cfg.toolPresets.rectangle = session.toolPresets.rectangle
        case .ellipse: cfg.toolPresets.ellipse = session.toolPresets.ellipse
        case .highlighter: cfg.toolPresets.highlighter = session.toolPresets.highlighter
        case .text: cfg.toolPresets.text = session.toolPresets.text
        case .step: cfg.toolPresets.step = session.toolPresets.step
        case .redact:
            cfg.toolPresets.redact = session.toolPresets.redact
            cfg.defaultRedactMode = session.toolPresets.redact.style
        case .crop: cfg.toolPresets.crop = session.toolPresets.crop
        case .select: break
        }
        cfg.toolPresets.beautify = session.beautify
        configManager.config.quickScreenshot = cfg
        uiState.savedDefaultBadge = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            uiState.savedDefaultBadge = false
        }
    }

    // MARK: - Interactive Canvas

    private var canvasArea: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size
            let activeCrop = uiState.draftCropRect ?? session.cropRect
            let isEditingCrop = (session.activeTool == .crop) || (uiState.draftCropRect != nil)
            let isAppliedCropPreview = (session.cropRect != nil) && !isEditingCrop
            let beautifyActive = session.beautify.enabled && session.beautify.backdrop != .none && !isEditingCrop
            let beautifyPadPx = beautifyActive ? session.beautify.padding : 0
            let fitTargetSize = CGSize(
                width: session.imagePixelSize.width + beautifyPadPx * 2,
                height: session.imagePixelSize.height + beautifyPadPx * 2
            )
            let fitScale = CanvasCoordinateMapper.fitScale(
                imageSize: fitTargetSize,
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
            let activeViewCrop = activeCrop.map { mapper.imagePixelToViewRect($0) }
            let cardContentRect = (isAppliedCropPreview ? activeViewCrop : nil) ?? imageRect
            let beautifyCorner = beautifyActive
                ? min(session.beautify.cornerRadius * zoomScale, min(cardContentRect.width, cardContentRect.height) / 2)
                : 0
            let beautifyFrameRect = cardContentRect.insetBy(
                dx: -beautifyPadPx * zoomScale,
                dy: -beautifyPadPx * zoomScale
            )

            ZStack(alignment: .topLeading) {
                checkerboardBackdrop

                if beautifyActive {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(session.beautify.backdrop.swiftUIGradient)
                        .frame(width: beautifyFrameRect.width, height: beautifyFrameRect.height)
                        .position(x: beautifyFrameRect.midX, y: beautifyFrameRect.midY)
                        .shadow(color: .black.opacity(0.42), radius: 14, y: 6)
                        .allowsHitTesting(false)

                    if session.beautify.shadowEnabled {
                        RoundedRectangle(cornerRadius: beautifyCorner)
                            .fill(Color.black)
                            .frame(width: cardContentRect.width, height: cardContentRect.height)
                            .position(x: cardContentRect.midX, y: cardContentRect.midY)
                            .shadow(color: .black.opacity(0.48), radius: 18 * zoomScale, y: 8 * zoomScale)
                            .allowsHitTesting(false)
                    }
                }

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
                        if !beautifyActive {
                            Color(red: 0.06, green: 0.07, blue: 0.09)
                                .frame(width: viewCrop.width, height: viewCrop.height)
                                .position(x: viewCrop.midX, y: viewCrop.midY)
                                .shadow(color: .black.opacity(0.55), radius: 14, y: 6)
                                .allowsHitTesting(false)
                        }

                        Image(decorative: displayCG, scale: 1.0, orientation: .up)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: imageRect.midX, y: imageRect.midY)
                            .clipShape(RoundedCropClipShape(rect: viewCrop, cornerRadius: beautifyCorner))
                    } else {
                        Image(decorative: displayCG, scale: 1.0, orientation: .up)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: imageRect.width, height: imageRect.height)
                            .clipShape(RoundedRectangle(cornerRadius: beautifyCorner))
                            .position(x: imageRect.midX, y: imageRect.midY)
                            .shadow(color: beautifyActive ? .clear : .black.opacity(0.45), radius: 14, y: 6)
                    }
                }

                // Vector annotations + hover/selection handles + crop overlay
                Canvas { context, _ in
                    let drawAnnotations: (inout GraphicsContext, CGRect) -> Void = { targetCtx, clipRect in
                        for item in session.annotations where item.kind == .redact {
                            drawCanvasAnnotation(item, isDraft: false, in: &targetCtx, mapper: mapper, scale: zoomScale)
                        }
                        drawSpotlightScrimIfNeeded(in: &targetCtx, clipRect: clipRect, mapper: mapper, scale: zoomScale)
                        for item in session.annotations where item.kind != .redact {
                            drawCanvasAnnotation(item, isDraft: false, in: &targetCtx, mapper: mapper, scale: zoomScale)
                        }
                        if let draft = uiState.draftAnnotation {
                            drawCanvasAnnotation(draft, isDraft: true, in: &targetCtx, mapper: mapper, scale: zoomScale)
                        }
                    }

                    if isAppliedCropPreview, let viewCrop = activeViewCrop {
                        context.drawLayer { layerCtx in
                            layerCtx.clip(to: Path(roundedRect: viewCrop, cornerRadius: beautifyCorner))
                            drawAnnotations(&layerCtx, viewCrop)
                        }
                        context.stroke(
                            Path(roundedRect: viewCrop, cornerRadius: beautifyCorner),
                            with: .color(.white.opacity(0.18)),
                            lineWidth: 1
                        )
                    } else if beautifyActive {
                        context.drawLayer { layerCtx in
                            layerCtx.clip(to: Path(roundedRect: imageRect, cornerRadius: beautifyCorner))
                            drawAnnotations(&layerCtx, imageRect)
                        }
                        context.stroke(
                            Path(roundedRect: imageRect, cornerRadius: beautifyCorner),
                            with: .color(.white.opacity(0.18)),
                            lineWidth: 1
                        )
                    } else {
                        drawAnnotations(&context, imageRect)
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

                // Compact crop indicator when viewing cropped result outside Crop tool
                if !isEditingCrop, let crop = session.cropRect {
                    HStack(spacing: 8) {
                        Text("Cropped: \(Int(crop.width)) × \(Int(crop.height)) px")
                            .toolboxFont(.caption.weight(.medium))
                            .foregroundStyle(.white)
                        Button("Adjust") {
                            session.selectTool(.crop)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()
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
            .background(
                NonHitTestingAnchorReader { view in
                    onCanvasAnchor?(view)
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
        let fontSize = max(12, item.effectiveTextFontSize * scale)
        let fontDesign: Font.Design = item.textWeightStyle == .mono ? .monospaced : .default
        let fontWeight: Font.Weight = item.textWeightStyle == .regular ? .regular : .bold
        let corner: CGFloat = {
            if item.textCornerRadius == .large {
                return 999
            }
            return item.textCornerRadius.radiusValue * scale
        }()
        let textColor: Color = {
            if item.textBackgroundStyle == .filled {
                return (item.color == .white || item.color == .yellow) ? .black : .white
            }
            return item.color.swiftUIColor
        }()
        let bgColor: Color = {
            switch item.textBackgroundStyle {
            case .pill:
                return item.color == .black
                    ? Color.white.opacity(0.92)
                    : Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.92)
            case .filled:
                return item.color.swiftUIColor
            case .plain:
                return Color.black.opacity(0.35)
            }
        }()
        let isLightBg = (item.textBackgroundStyle == .filled && (item.color == .white || item.color == .yellow))
            || (item.textBackgroundStyle == .pill && item.color == .black)
        let borderColor: Color = isLightBg
            ? Color.black.opacity(0.28)
            : ((item.textBackgroundStyle == .filled && item.color == .black) ? Color.white.opacity(0.35) : item.color.swiftUIColor)

        let padX = max(item.textBackgroundStyle == .plain ? 2 : 4, item.effectiveTextFontSize * AnnotationItem.defaultTextPaddingXRatio(backgroundStyle: item.textBackgroundStyle, cornerRadius: item.textCornerRadius)) * scale
        let padY = max(1, item.effectiveTextFontSize * AnnotationItem.defaultTextPaddingYRatio(backgroundStyle: item.textBackgroundStyle)) * scale
        let liveText = session.annotations.first(where: { $0.id == item.id })?.text ?? item.text
        let sampleText = liveText.isEmpty ? "Type text…" : liveText
        let nsMeasureFont = AnnotationItem.makeTextFont(size: fontSize, weightStyle: item.textWeightStyle)
        let measuredWidth = (sampleText as NSString).size(withAttributes: [.font: nsMeasureFont]).width
        let fittedWidth = max(84, ceil(measuredWidth) + padX * 2 + 16)

        TextField("Type text…", text: Binding(
            get: {
                session.annotations.first(where: { $0.id == item.id })?.text ?? item.text
            },
            set: { newValue in
                session.updateTextAnnotation(id: item.id, text: newValue)
            }
        ))
        .textFieldStyle(.plain)
        .font(.system(size: fontSize, weight: fontWeight, design: fontDesign))
        .foregroundStyle(textColor)
        .environment(\.colorScheme, isLightBg ? .light : .dark)
        .padding(.horizontal, padX)
        .padding(.vertical, padY)
        .frame(width: fittedWidth)
        .background(bgColor, in: RoundedRectangle(cornerRadius: corner))
        .overlay(
            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(borderColor, lineWidth: 1.5)
        )
        .onAppear {
            DispatchQueue.main.async {
                _ = NSApp.keyWindow?.focusFirstEditableTextField()
            }
        }
        .onSubmit {
            session.finishTextEditing()
        }
        .offset(x: origin.x, y: origin.y)
    }

    // MARK: - Auto-Redact Review Tray

    private var autoRedactReviewTray: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash.fill")
                        .foregroundStyle(.orange)
                        .toolboxFont(.caption.weight(.semibold))
                    Text("Auto-Redact Review")
                        .toolboxFont(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(session.reviewItems.count)")
                        .toolboxFont(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                }

                HStack(spacing: 4) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                        .toolboxFont(.system(size: 10.5, weight: .semibold))
                    Text("On-device Apple Vision · Flattened on export")
                        .toolboxFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.05), in: Capsule())
                .editorTooltip("100% on-device Apple Vision (no uploads) · Flattened on export")

                Spacer()

                Button {
                    session.keepAllReviewItems()
                } label: {
                    Label("Keep All", systemImage: "checkmark")
                        .toolboxFont(.caption2.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .editorTooltip("Accept all Auto-Redact boxes and close review")
                .pointerCursor()

                Button(role: .destructive) {
                    session.undoAllReviewItems()
                } label: {
                    Text("Undo All")
                        .toolboxFont(.caption2.weight(.medium))
                }
                .buttonStyle(.toolboxDestructive)
                .controlSize(.small)
                .editorTooltip("Remove all suggested Auto-Redact boxes")
                .pointerCursor()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(session.reviewItems) { item in
                        let isSelected = (session.selectedAnnotationID == item.annotationID)
                        let isHovered = (uiState.hoveredAnnotationID == item.annotationID)
                        HStack(spacing: 8) {
                            Button {
                                session.selectedAnnotationID = isSelected ? nil : item.annotationID
                            } label: {
                                HStack(spacing: 8) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.orange.opacity(0.15))
                                            .frame(width: 24, height: 24)
                                        Image(systemName: item.category.symbolName)
                                            .toolboxFont(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(.orange)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 5) {
                                            Text(item.category.label)
                                                .toolboxFont(.caption2.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            Text("\(Int((item.confidence * 100).rounded()))%")
                                                .toolboxFont(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(item.maskedSnippet)
                                            .toolboxFont(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .editorTooltip(isSelected ? "Click to deselect" : "Click to select this redaction on the canvas")
                            .pointerCursor()

                            HStack(spacing: 5) {
                                Button {
                                    session.selectedAnnotationID = item.annotationID
                                    session.keepReviewItem(item)
                                } label: {
                                    Image(systemName: "checkmark")
                                        .toolboxFont(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.green)
                                        .frame(width: 24, height: 24)
                                        .background(Color.green.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(Color.green.opacity(0.32), lineWidth: 0.75)
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled()
                                .editorTooltip("Keep redaction")
                                .pointerCursor()

                                Button {
                                    session.removeReviewItem(item)
                                } label: {
                                    Image(systemName: "xmark")
                                        .toolboxFont(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.red)
                                        .frame(width: 24, height: 24)
                                        .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(Color.red.opacity(0.30), lineWidth: 0.75)
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled()
                                .editorTooltip("Remove false positive")
                                .pointerCursor()
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            isSelected ? Color.blue.opacity(0.16)
                            : (isHovered ? Color.white.opacity(0.10) : Color.white.opacity(0.06)),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    isSelected ? Color.blue.opacity(0.85)
                                    : (isHovered ? Color.orange.opacity(0.55) : Color.white.opacity(0.12)),
                                    lineWidth: isSelected ? 1.25 : 0.75
                                )
                        )
                        .onHover { hovering in
                            if hovering {
                                uiState.hoveredAnnotationID = item.annotationID
                            } else if uiState.hoveredAnnotationID == item.annotationID {
                                uiState.hoveredAnnotationID = nil
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(red: 0.105, green: 0.112, blue: 0.132))
        .overlay(alignment: .top) {
            Divider().opacity(0.35)
        }
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
            .editorTooltip("On-device Apple Vision · Auto-redact keys, codes & PII")
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
            .editorTooltip("Extract text or QR payloads with Apple Vision")
            .pointerCursor(!session.isRunningOCR)

            Spacer()

            let baseOutputSize = session.cropRect?.size ?? session.imagePixelSize
            let padExtra = (session.beautify.enabled && session.beautify.backdrop != .none)
                ? session.beautify.padding.rounded() * 2
                : 0
            Text("\(Int(baseOutputSize.width + padExtra)) × \(Int(baseOutputSize.height + padExtra)) px")
                .toolboxFont(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                onPin()
            } label: {
                Label("Pin", systemImage: "pin")
            }
            .buttonStyle(.bordered)
            .editorTooltip("Pin floating reference window (⌘ P)")
            .pointerCursor()

            Button {
                onShare(uiState.shareAnchorView)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .background(ShareAnchorReader { view in
                uiState.shareAnchorView = view
            })
            .editorTooltip("Share via AirDrop, Mail, or Messages")
            .pointerCursor()

            Button {
                onSaveAs()
            } label: {
                Text("Save As…")
            }
            .buttonStyle(.bordered)
            .editorTooltip("Save to a chosen folder (⇧ ⌘ S)")
            .pointerCursor()

            Button {
                onSave()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .editorTooltip("Save directly to your configured folder (⌘ S)")
            .pointerCursor()

            let closeAfterCopy = configManager.config.quickScreenshot.closeEditorAfterCopy
            Button {
                onCopy()
            } label: {
                Label(closeAfterCopy ? "Copy & Close" : "Copy", systemImage: "doc.on.clipboard.fill")
            }
            .buttonStyle(.toolboxProminent(.red))
            .fixedSize(horizontal: true, vertical: false)
            .editorTooltip(closeAfterCopy
                  ? "Copy flattened screenshot to clipboard and close editor (⌘ C / Return)"
                  : "Copy flattened screenshot to clipboard (⌘ C / Return)")
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.11, green: 0.12, blue: 0.15))
    }

    // MARK: - Canvas Drawing

    private func drawSpotlightScrimIfNeeded(
        in context: inout GraphicsContext,
        clipRect: CGRect,
        mapper: CanvasCoordinateMapper,
        scale: CGFloat
    ) {
        var spotlightItems = session.annotations.filter {
            ($0.kind == .rectangle || $0.kind == .ellipse) && $0.fillStyle == .spotlight
        }
        if let draft = uiState.draftAnnotation,
           (draft.kind == .rectangle || draft.kind == .ellipse) && draft.fillStyle == .spotlight {
            spotlightItems.append(draft)
        }
        guard !spotlightItems.isEmpty else { return }

        var scrimPath = Path()
        scrimPath.addRect(clipRect)
        for item in spotlightItems {
            let viewRect = mapper.imagePixelToViewRect(item.rect)
            guard viewRect.width >= 1, viewRect.height >= 1 else { continue }
            if item.kind == .ellipse {
                scrimPath.addEllipse(in: viewRect)
            } else {
                let r = min(item.cornerRadius.radiusValue * scale, min(viewRect.width, viewRect.height) / 2)
                scrimPath.addRoundedRect(in: viewRect, cornerSize: CGSize(width: r, height: r))
            }
        }
        context.drawLayer { layerCtx in
            layerCtx.clip(to: Path(clipRect))
            layerCtx.fill(scrimPath, with: .color(.black.opacity(0.56)), style: FillStyle(eoFill: true))
        }
    }

    private func viewStrokeStyle(for item: AnnotationItem, scale: CGFloat, lineCap: CGLineCap = .butt) -> StrokeStyle {
        let width = max(1.5, item.strokeWidth * scale)
        if item.dashStyle == .dashed {
            return StrokeStyle(
                lineWidth: width,
                lineCap: lineCap,
                lineJoin: .round,
                dash: [max(5, item.strokeWidth * 2.4 * scale), max(3.5, item.strokeWidth * 1.6 * scale)]
            )
        }
        return StrokeStyle(lineWidth: width, lineCap: lineCap, lineJoin: .round)
    }

    private func drawCanvasShape(
        path: Path,
        item: AnnotationItem,
        in context: inout GraphicsContext,
        scale: CGFloat
    ) {
        switch item.fillStyle {
        case .outline, .spotlight:
            context.stroke(path, with: .color(item.color.swiftUIColor), style: viewStrokeStyle(for: item, scale: scale))
        case .tinted:
            context.fill(path, with: .color(item.color.swiftUIColor.opacity(0.18)))
            context.stroke(path, with: .color(item.color.swiftUIColor), style: viewStrokeStyle(for: item, scale: scale))
        case .solid:
            context.fill(path, with: .color(item.color.swiftUIColor))
        }
    }

    private func drawCanvasAnnotation(
        _ item: AnnotationItem,
        isDraft: Bool,
        in context: inout GraphicsContext,
        mapper: CanvasCoordinateMapper,
        scale: CGFloat
    ) {
        switch item.kind {
        case .redact:
            let viewRect = mapper.imagePixelToViewRect(item.rect)
            switch item.redactStyle {
            case .solidBlack:
                context.fill(Path(viewRect), with: .color(item.redactSolidColor.swiftUIColor))
            case .blur, .pixelate, .smartErase:
                // Filtered/erased redactions are pre-baked into cachedPixelatedImage without any border;
                // show a live dashed preview box only while actively dragging a new redaction.
                if isDraft {
                    context.fill(Path(viewRect), with: .color(.white.opacity(0.10)))
                    context.stroke(
                        Path(viewRect),
                        with: .color(.white.opacity(0.75)),
                        style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                    )
                }
            }

        case .rectangle:
            let viewRect = mapper.imagePixelToViewRect(item.rect)
            let radius = min(item.cornerRadius.radiusValue * scale, min(viewRect.width, viewRect.height) / 2)
            let path = Path(roundedRect: viewRect, cornerRadius: radius)
            drawCanvasShape(path: path, item: item, in: &context, scale: scale)

        case .ellipse:
            let viewRect = mapper.imagePixelToViewRect(item.rect)
            let path = Path(ellipseIn: viewRect)
            drawCanvasShape(path: path, item: item, in: &context, scale: scale)

        case .highlighter:
            let alpha = item.highlighterOpacity.alpha
            var hlContext = context
            hlContext.blendMode = .multiply
            if item.highlighterMode == .box {
                let viewRect = mapper.imagePixelToViewRect(item.rect)
                let path = Path(roundedRect: viewRect, cornerRadius: max(2, 4 * scale))
                hlContext.fill(path, with: .color(item.color.swiftUIColor.opacity(alpha)))
            } else {
                guard !item.points.isEmpty else { return }
                var path = Path()
                let first = mapper.imagePixelToViewPoint(item.points[0])
                path.move(to: first)
                for pt in item.points.dropFirst() {
                    path.addLine(to: mapper.imagePixelToViewPoint(pt))
                }
                hlContext.stroke(
                    path,
                    with: .color(item.color.swiftUIColor.opacity(alpha)),
                    style: StrokeStyle(lineWidth: max(8, item.strokeWidth * 4.2 * scale), lineCap: .round, lineJoin: .round)
                )
            }

        case .arrow:
            let start = mapper.imagePixelToViewPoint(item.startPoint)
            let end = mapper.imagePixelToViewPoint(item.endPoint)
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length >= 2 else { return }
            let angle = atan2(dy, dx)
            let headLen = max(10, item.strokeWidth * 4.0 * scale)
            let headAngle: CGFloat = .pi / 6.5

            switch item.arrowStyle {
            case .line:
                var line = Path()
                line.move(to: start)
                line.addLine(to: end)
                context.stroke(line, with: .color(item.color.swiftUIColor), style: viewStrokeStyle(for: item, scale: scale, lineCap: .round))

            case .standard:
                let shaftEnd = CGPoint(
                    x: end.x - cos(angle) * headLen * 0.65,
                    y: end.y - sin(angle) * headLen * 0.65
                )
                var shaft = Path()
                shaft.move(to: start)
                shaft.addLine(to: shaftEnd)
                context.stroke(shaft, with: .color(item.color.swiftUIColor), style: viewStrokeStyle(for: item, scale: scale, lineCap: .round))
                drawCanvasArrowHead(tip: end, angle: angle, headLen: headLen, headAngle: headAngle, color: item.color.swiftUIColor, in: &context)

            case .doubleHeaded:
                let trim = min(length * 0.35, headLen * 0.65)
                let shaftStart = CGPoint(x: start.x + cos(angle) * trim, y: start.y + sin(angle) * trim)
                let shaftEnd = CGPoint(x: end.x - cos(angle) * trim, y: end.y - sin(angle) * trim)
                var shaft = Path()
                shaft.move(to: shaftStart)
                shaft.addLine(to: shaftEnd)
                context.stroke(shaft, with: .color(item.color.swiftUIColor), style: viewStrokeStyle(for: item, scale: scale, lineCap: .round))
                drawCanvasArrowHead(tip: end, angle: angle, headLen: headLen, headAngle: headAngle, color: item.color.swiftUIColor, in: &context)
                drawCanvasArrowHead(tip: start, angle: angle + .pi, headLen: headLen, headAngle: headAngle, color: item.color.swiftUIColor, in: &context)

            case .tapered:
                let perpX = -sin(angle)
                let perpY = cos(angle)
                let viewStroke = max(1.5, item.strokeWidth * scale)
                let tailHalf = max(0.9, viewStroke * 0.32)
                let neckHalf = max(2.0, viewStroke * 0.92)
                let neckDist = min(length * 0.8, headLen * 0.72)
                let neckCenter = CGPoint(x: end.x - cos(angle) * neckDist, y: end.y - sin(angle) * neckDist)
                let wingDist = min(length * 0.95, headLen * 1.08)
                let wingHalf = max(headLen * 0.52, neckHalf * 2.1)
                let wingCenter = CGPoint(x: end.x - cos(angle) * wingDist, y: end.y - sin(angle) * wingDist)

                var tapered = Path()
                tapered.move(to: CGPoint(x: start.x + perpX * tailHalf, y: start.y + perpY * tailHalf))
                tapered.addLine(to: CGPoint(x: neckCenter.x + perpX * neckHalf, y: neckCenter.y + perpY * neckHalf))
                tapered.addLine(to: CGPoint(x: wingCenter.x + perpX * wingHalf, y: wingCenter.y + perpY * wingHalf))
                tapered.addLine(to: end)
                tapered.addLine(to: CGPoint(x: wingCenter.x - perpX * wingHalf, y: wingCenter.y - perpY * wingHalf))
                tapered.addLine(to: CGPoint(x: neckCenter.x - perpX * neckHalf, y: neckCenter.y - perpY * neckHalf))
                tapered.addLine(to: CGPoint(x: start.x - perpX * tailHalf, y: start.y - perpY * tailHalf))
                tapered.closeSubpath()
                context.fill(tapered, with: .color(item.color.swiftUIColor))
            }

        case .step:
            let center = mapper.imagePixelToViewPoint(item.startPoint)
            let radius = max(10, item.effectiveStepRadius * scale)
            let circleRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            switch item.stepStyle {
            case .filled:
                context.fill(Path(ellipseIn: circleRect), with: .color(item.color.swiftUIColor))
                let rimColor: Color = item.color == .white ? Color.black.opacity(0.22) : Color.white.opacity(0.9)
                context.stroke(Path(ellipseIn: circleRect), with: .color(rimColor), lineWidth: max(1.5, radius * 0.11))
                let textColor: Color = (item.color == .white || item.color == .yellow) ? .black : .white
                let resolved = context.resolve(
                    Text("\(item.stepNumber)")
                        .font(.system(size: radius * 1.05, weight: .bold))
                        .foregroundStyle(textColor)
                )
                context.draw(resolved, at: center, anchor: .center)
            case .outlined:
                let bgColor: Color = (item.color == .white || item.color == .yellow)
                    ? Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.92)
                    : Color.white.opacity(0.95)
                context.fill(Path(ellipseIn: circleRect), with: .color(bgColor))
                context.stroke(Path(ellipseIn: circleRect), with: .color(item.color.swiftUIColor), lineWidth: max(2.0, radius * 0.16))
                let resolved = context.resolve(
                    Text("\(item.stepNumber)")
                        .font(.system(size: radius * 1.05, weight: .bold))
                        .foregroundStyle(item.color.swiftUIColor)
                )
                context.draw(resolved, at: center, anchor: .center)
            }

        case .text:
            guard session.editingTextAnnotationID != item.id else { return }
            let layout = item.textLayout()
            guard !layout.content.isEmpty else { return }

            let pill = mapper.imagePixelToViewRect(layout.pillRect)
            let corner = item.textCornerRadius.resolvedRadius(forHeight: layout.pillRect.height) * scale
            let textColor: Color = {
                if item.textBackgroundStyle == .filled {
                    return (item.color == .white || item.color == .yellow) ? .black : .white
                }
                return item.color.swiftUIColor
            }()

            switch item.textBackgroundStyle {
            case .pill:
                let backdrop: Color = item.color == .black ? .white.opacity(0.92) : Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.86)
                context.fill(Path(roundedRect: pill, cornerRadius: corner), with: .color(backdrop))
                context.stroke(Path(roundedRect: pill, cornerRadius: corner), with: .color(item.color.swiftUIColor.opacity(0.55)), lineWidth: 1.5)
            case .filled:
                context.fill(Path(roundedRect: pill, cornerRadius: corner), with: .color(item.color.swiftUIColor))
                if item.color == .black {
                    context.stroke(Path(roundedRect: pill, cornerRadius: corner), with: .color(Color.white.opacity(0.20)), lineWidth: 1.2)
                }
            case .plain:
                break
            }

            // Render typography at native font size inside a scaled GraphicsContext so pinch zoom
            // never triggers optical font drift or unintended multi-line wrapping.
            var textCtx = context
            textCtx.translateBy(x: pill.midX, y: pill.midY)
            textCtx.scaleBy(x: scale, y: scale)
            let swiftUIFont = Font(layout.font as CTFont)
            if item.textBackgroundStyle == .plain {
                let shadowColor: Color = item.color == .black ? .white.opacity(0.85) : .black.opacity(0.85)
                let shadowResolved = textCtx.resolve(
                    Text(layout.content)
                        .font(swiftUIFont)
                        .foregroundStyle(shadowColor)
                )
                textCtx.draw(shadowResolved, at: CGPoint(x: 1, y: 1.5), anchor: .center)
            }
            let resolved = textCtx.resolve(
                Text(layout.content)
                    .font(swiftUIFont)
                    .foregroundStyle(textColor)
            )
            textCtx.draw(resolved, at: .zero, anchor: .center)
        }
    }

    private func drawCanvasArrowHead(
        tip: CGPoint,
        angle: CGFloat,
        headLen: CGFloat,
        headAngle: CGFloat,
        color: Color,
        in context: inout GraphicsContext
    ) {
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - cos(angle - headAngle) * headLen, y: tip.y - sin(angle - headAngle) * headLen))
        head.addLine(to: CGPoint(x: tip.x - cos(angle + headAngle) * headLen, y: tip.y - sin(angle + headAngle) * headLen))
        head.closeSubpath()
        context.fill(head, with: .color(color))
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
        if item.kind == .step {
            context.stroke(
                Path(ellipseIn: bounds.insetBy(dx: -3, dy: -3)),
                with: .color(.blue.opacity(0.5)),
                style: StrokeStyle(lineWidth: 1.5)
            )
            return
        }
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
        if item.kind == .text && session.editingTextAnnotationID == item.id {
            return
        }
        if item.kind == .arrow {
            for pt in [item.startPoint, item.endPoint] {
                let vp = mapper.imagePixelToViewPoint(pt)
                let handle = CGRect(x: vp.x - 5.5, y: vp.y - 5.5, width: 11, height: 11)
                context.fill(Path(ellipseIn: handle), with: .color(.white))
                context.stroke(Path(ellipseIn: handle), with: .color(.blue), lineWidth: 1.8)
            }
            return
        }

        let bounds = mapper.imagePixelToViewRect(item.boundingRect)
        if item.kind == .step {
            context.stroke(
                Path(ellipseIn: bounds.insetBy(dx: -3.5, dy: -3.5)),
                with: .color(.blue.opacity(0.95)),
                style: StrokeStyle(lineWidth: 2)
            )
            return
        }

        context.stroke(
            Path(bounds),
            with: .color(.blue.opacity(0.9)),
            style: StrokeStyle(lineWidth: 1.4, dash: [5, 3])
        )

        let showCorners = item.kind == .rectangle
            || item.kind == .ellipse
            || (item.kind == .redact && !item.isAutoRedacted)
            || (item.kind == .highlighter && item.highlighterMode == .box)
            || (item.kind == .text && session.editingTextAnnotationID != item.id)
        if showCorners {
            let corners = [
                CGPoint(x: bounds.minX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.minY),
                CGPoint(x: bounds.minX, y: bounds.maxY),
                CGPoint(x: bounds.maxX, y: bounds.maxY)
            ]
            for corner in corners {
                let handle = CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)
                context.fill(Path(roundedRect: handle, cornerRadius: 2), with: .color(.white))
                context.stroke(Path(roundedRect: handle, cornerRadius: 2), with: .color(.blue), lineWidth: 1.5)
            }

            if item.kind == .text && session.editingTextAnnotationID != item.id {
                var edgeRects: [CGRect] = []
                if bounds.width >= 34 {
                    edgeRects.append(CGRect(x: bounds.midX - 7, y: bounds.minY - 2.5, width: 14, height: 5))
                    edgeRects.append(CGRect(x: bounds.midX - 7, y: bounds.maxY - 2.5, width: 14, height: 5))
                }
                if bounds.height >= 24 {
                    edgeRects.append(CGRect(x: bounds.minX - 2.5, y: bounds.midY - 7, width: 5, height: 14))
                    edgeRects.append(CGRect(x: bounds.maxX - 2.5, y: bounds.midY - 7, width: 5, height: 14))
                }
                for edgeHandle in edgeRects {
                    context.fill(Path(roundedRect: edgeHandle, cornerRadius: 2.5), with: .color(.white))
                    context.stroke(Path(roundedRect: edgeHandle, cornerRadius: 2.5), with: .color(.blue), lineWidth: 1.4)
                }
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
            if hypot(viewPoint.x - startView.x, viewPoint.y - startView.y) <= 15 {
                return .arrowEndpoint(item: selected, isStart: true)
            }
            if hypot(viewPoint.x - endView.x, viewPoint.y - endView.y) <= 15 {
                return .arrowEndpoint(item: selected, isStart: false)
            }
            return nil
        }
        if selected.kind == .rectangle || selected.kind == .ellipse || (selected.kind == .redact && !selected.isAutoRedacted) || (selected.kind == .highlighter && selected.highlighterMode == .box) {
            let viewBounds = mapper.imagePixelToViewRect(selected.rect)
            let handleTargets: [(QuickScreenshotEditorUIState.RectCorner, CGPoint)] = [
                (.topLeft, CGPoint(x: viewBounds.minX, y: viewBounds.minY)),
                (.topRight, CGPoint(x: viewBounds.maxX, y: viewBounds.minY)),
                (.bottomLeft, CGPoint(x: viewBounds.minX, y: viewBounds.maxY)),
                (.bottomRight, CGPoint(x: viewBounds.maxX, y: viewBounds.maxY))
            ]
            if let hit = handleTargets.first(where: { hypot(viewPoint.x - $0.1.x, viewPoint.y - $0.1.y) <= 15 }) {
                return .rectCorner(item: selected, corner: hit.0)
            }
        }
        if selected.kind == .text && session.editingTextAnnotationID != selected.id {
            let pixelBounds = selected.boundingRect
            let viewBounds = mapper.imagePixelToViewRect(pixelBounds)
            let handleTargets: [(QuickScreenshotEditorUIState.RectCorner, CGPoint)] = [
                (.topLeft, CGPoint(x: viewBounds.minX, y: viewBounds.minY)),
                (.topRight, CGPoint(x: viewBounds.maxX, y: viewBounds.minY)),
                (.bottomLeft, CGPoint(x: viewBounds.minX, y: viewBounds.maxY)),
                (.bottomRight, CGPoint(x: viewBounds.maxX, y: viewBounds.maxY))
            ]
            if let hit = handleTargets.first(where: { hypot(viewPoint.x - $0.1.x, viewPoint.y - $0.1.y) <= 14 }) {
                return .textCorner(item: selected, bounds: pixelBounds, corner: hit.0)
            }
            var edgeTargets: [(QuickScreenshotEditorUIState.BoxEdge, CGPoint)] = []
            if viewBounds.width >= 34 {
                edgeTargets.append((.top, CGPoint(x: viewBounds.midX, y: viewBounds.minY)))
                edgeTargets.append((.bottom, CGPoint(x: viewBounds.midX, y: viewBounds.maxY)))
            }
            if viewBounds.height >= 24 {
                edgeTargets.append((.left, CGPoint(x: viewBounds.minX, y: viewBounds.midY)))
                edgeTargets.append((.right, CGPoint(x: viewBounds.maxX, y: viewBounds.midY)))
            }
            if let edgeHit = edgeTargets.first(where: { hypot(viewPoint.x - $0.1.x, viewPoint.y - $0.1.y) <= 12 }) {
                return .textEdge(item: selected, bounds: pixelBounds, edge: edgeHit.0)
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
        if let hit = cornerTargets.first(where: { hypot(viewPoint.x - $0.1.x, viewPoint.y - $0.1.y) <= 15 }) {
            return hit.0
        }
        let edgeTargets: [(QuickScreenshotEditorUIState.CropHandle, CGPoint)] = [
            (.top, CGPoint(x: viewCrop.midX, y: viewCrop.minY)),
            (.bottom, CGPoint(x: viewCrop.midX, y: viewCrop.maxY)),
            (.left, CGPoint(x: viewCrop.minX, y: viewCrop.midY)),
            (.right, CGPoint(x: viewCrop.maxX, y: viewCrop.midY))
        ]
        if let hit = edgeTargets.first(where: { hypot(viewPoint.x - $0.1.x, viewPoint.y - $0.1.y) <= 15 }) {
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
            case .rectCorner(_, let corner), .textCorner(_, _, let corner):
                return (cursorForRectCorner(corner), session.selectedAnnotationID)
            case .textEdge(_, _, let edge):
                let edgeCursor: NSCursor = (edge == .top || edge == .bottom) ? .resizeUpDown : .resizeLeftRight
                return (edgeCursor, session.selectedAnnotationID)
            }
        }

        let pixelTol = max(8, 13 / max(zoomScale, 0.25))
        let hoverPixel = mapper.viewPointToImagePixel(viewPoint)
        if let hit = session.hitTestAnnotation(
            at: hoverPixel,
            tolerance: pixelTol,
            directEditMode: session.activeTool != .select,
            includeRedactions: session.activeTool == .select || session.activeTool == .redact
        ) {
            return (hit.isAutoRedacted ? .pointingHand : .openHand, hit.id)
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
            let hadSelection = (session.selectedAnnotationID != nil)
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
                case .textCorner(let item, let bounds, let corner):
                    uiState.dragInitialAnnotations = session.annotations
                    uiState.dragMode = .resizeTextHandle(initialItem: item, initialBounds: bounds, corner: corner)
                    PointerCursorNSView.activeDragCursor = cursorForRectCorner(corner)
                case .textEdge(let item, let bounds, let edge):
                    uiState.dragInitialAnnotations = session.annotations
                    uiState.dragMode = .resizeTextEdge(initialItem: item, initialBounds: bounds, edge: edge)
                    PointerCursorNSView.activeDragCursor = (edge == .top || edge == .bottom) ? .resizeUpDown : .resizeLeftRight
                }
                return
            }

            let pixelTol = max(8, 13 / max(zoomScale, 0.25))
            if let hit = session.hitTestAnnotation(
                at: startPixel,
                tolerance: pixelTol,
                directEditMode: session.activeTool != .select,
                includeRedactions: session.activeTool == .select || session.activeTool == .redact
            ) {
                session.selectedAnnotationID = hit.id
                if hit.isAutoRedacted {
                    uiState.dragMode = .none
                    PointerCursorNSView.activeDragCursor = .pointingHand
                } else {
                    uiState.dragInitialAnnotations = session.annotations
                    uiState.dragMode = .moveSelected(initialItem: hit)
                    PointerCursorNSView.activeDragCursor = .closedHand
                }
                return
            }

            session.selectedAnnotationID = nil
            switch session.activeTool {
            case .select:
                uiState.dragMode = .panCanvas
                PointerCursorNSView.activeDragCursor = .closedHand
            case .step, .text:
                uiState.dragMode = (wasEditingText || hadSelection) ? .none : .placeTap
            default:
                if wasEditingText || hadSelection {
                    uiState.dragMode = .none
                } else {
                    uiState.dragMode = .drawNew
                    uiState.draftAnnotation = makeDraftAnnotation(start: startPixel, current: currentPixel, previous: nil)
                    PointerCursorNSView.activeDragCursor = .crosshair
                }
            }
            return
        }

        let startPixel = uiState.dragStartPixel ?? currentPixel
        let shiftPressed = NSEvent.modifierFlags.contains(.shift)
        switch uiState.dragMode {
        case .none, .placeTap:
            break
        case .drawNew:
            uiState.draftAnnotation = makeDraftAnnotation(
                start: startPixel,
                current: currentPixel,
                previous: uiState.draftAnnotation,
                shiftPressed: shiftPressed
            )
        case .drawCrop:
            let aspect = session.toolPresets.crop.aspectRatio.ratio ?? (shiftPressed ? 1.0 : nil)
            uiState.draftCropRect = constrainedRect(start: startPixel, current: currentPixel, aspectRatio: aspect, maxSize: session.imagePixelSize)
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
            var candidate = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            if let aspect = session.toolPresets.crop.aspectRatio.ratio ?? (shiftPressed ? 1.0 : nil),
               handle == .topLeft || handle == .topRight || handle == .bottomLeft || handle == .bottomRight {
                let targetH = min(candidate.height, maxH - candidate.minY)
                let adjustedW = min(targetH * aspect, maxW - candidate.minX)
                let adjustedH = adjustedW / aspect
                candidate.size = CGSize(width: max(12, adjustedW), height: max(12, adjustedH))
            }
            uiState.draftCropRect = candidate
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
        case .resizeTextHandle(let initialItem, let initialBounds, let corner):
            let anchor: CGPoint
            switch corner {
            case .topLeft: anchor = CGPoint(x: initialBounds.maxX, y: initialBounds.maxY)
            case .topRight: anchor = CGPoint(x: initialBounds.minX, y: initialBounds.maxY)
            case .bottomLeft: anchor = CGPoint(x: initialBounds.maxX, y: initialBounds.minY)
            case .bottomRight: anchor = CGPoint(x: initialBounds.minX, y: initialBounds.minY)
            }
            let draggedW = max(32, abs(currentPixel.x - anchor.x))
            let draggedH = max(18, abs(currentPixel.y - anchor.y))
            let widthRatio = draggedW / max(1, initialBounds.width)
            let heightRatio = draggedH / max(1, initialBounds.height)
            let scaleRatio = max(widthRatio, heightRatio)
            let newFontSize = min(max(initialItem.effectiveTextFontSize * scaleRatio, 10), 120)
            let newBounds = AnnotationItem.textBounds(
                text: initialItem.text,
                origin: .zero,
                fontSize: newFontSize,
                weightStyle: initialItem.textWeightStyle,
                backgroundStyle: initialItem.textBackgroundStyle,
                cornerRadius: initialItem.textCornerRadius,
                paddingXRatio: initialItem.textPaddingXRatio,
                paddingYRatio: initialItem.textPaddingYRatio
            )
            var updated = initialItem
            updated.textFontSize = newFontSize
            switch corner {
            case .bottomRight:
                updated.startPoint = initialBounds.origin
            case .topRight:
                updated.startPoint = CGPoint(x: anchor.x, y: anchor.y - newBounds.height)
            case .bottomLeft:
                updated.startPoint = CGPoint(x: anchor.x - newBounds.width, y: anchor.y)
            case .topLeft:
                updated.startPoint = CGPoint(x: anchor.x - newBounds.width, y: anchor.y - newBounds.height)
            }
            session.updateAnnotationInPlace(updated)
        case .resizeTextEdge(let initialItem, let initialBounds, let edge):
            let baseLayout = initialItem.textLayout()
            let fontSize = max(10, initialItem.effectiveTextFontSize)
            var updated = initialItem
            switch edge {
            case .right:
                let desiredW = currentPixel.x - initialBounds.minX
                let desiredPadX = (desiredW - baseLayout.textSize.width) / 2
                let minR = AnnotationItem.minTextPaddingXRatio(backgroundStyle: initialItem.textBackgroundStyle, cornerRadius: initialItem.textCornerRadius)
                let clamped = min(max(desiredPadX / fontSize, minR), AnnotationItem.maxTextPaddingXRatio)
                updated.textPaddingXRatio = clamped
                updated.startPoint.x = initialBounds.minX
            case .left:
                let anchorX = initialBounds.maxX
                let desiredW = anchorX - currentPixel.x
                let desiredPadX = (desiredW - baseLayout.textSize.width) / 2
                let minR = AnnotationItem.minTextPaddingXRatio(backgroundStyle: initialItem.textBackgroundStyle, cornerRadius: initialItem.textCornerRadius)
                let clamped = min(max(desiredPadX / fontSize, minR), AnnotationItem.maxTextPaddingXRatio)
                updated.textPaddingXRatio = clamped
                let newBounds = updated.boundingRect
                updated.startPoint.x = anchorX - newBounds.width
            case .bottom:
                let desiredH = currentPixel.y - initialBounds.minY
                let desiredPadY = (desiredH - baseLayout.textSize.height) / 2
                let clamped = min(max(desiredPadY / fontSize, AnnotationItem.minTextPaddingYRatio), AnnotationItem.maxTextPaddingYRatio)
                updated.textPaddingYRatio = clamped
                updated.startPoint.y = initialBounds.minY
            case .top:
                let anchorY = initialBounds.maxY
                let desiredH = anchorY - currentPixel.y
                let desiredPadY = (desiredH - baseLayout.textSize.height) / 2
                let clamped = min(max(desiredPadY / fontSize, AnnotationItem.minTextPaddingYRatio), AnnotationItem.maxTextPaddingYRatio)
                updated.textPaddingYRatio = clamped
                let newBounds = updated.boundingRect
                updated.startPoint.y = anchorY - newBounds.height
            }
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
        case .resizeRectHandle, .moveArrowEndpoint, .resizeTextEdge:
            uiState.lastTapAnnotationID = nil
            if let before = uiState.dragInitialAnnotations {
                let after = session.annotations
                session.commitMutationSnapshot(before: before, after: after)
            }
        case .resizeTextHandle(let initialItem, _, _):
            uiState.lastTapAnnotationID = nil
            if let before = uiState.dragInitialAnnotations {
                let after = session.annotations
                session.commitMutationSnapshot(before: before, after: after)
            }
            if let resized = session.annotations.first(where: { $0.id == initialItem.id }) {
                session.toolPresets.text.fontSize = resized.effectiveTextFontSize
                session.onPresetsChanged?(session.toolPresets, session.activeTool)
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

    private func constrainedRect(
        start: CGPoint,
        current: CGPoint,
        aspectRatio: CGFloat?,
        maxSize: CGSize? = nil
    ) -> CGRect {
        let dx = current.x - start.x
        let dy = current.y - start.y
        var w = abs(dx)
        var h = abs(dy)
        if let ratio = aspectRatio, ratio > 0 {
            if w / max(1, h) > ratio {
                h = w / ratio
            } else {
                w = h * ratio
            }
        }
        let endX = start.x + (dx >= 0 ? w : -w)
        let endY = start.y + (dy >= 0 ? h : -h)
        var result = CGRect(
            x: min(start.x, endX),
            y: min(start.y, endY),
            width: w,
            height: h
        )
        if let maxSize {
            result = result.intersection(CGRect(origin: .zero, size: maxSize))
        }
        return result
    }

    private func makeDraftAnnotation(
        start: CGPoint,
        current: CGPoint,
        previous: AnnotationItem?,
        shiftPressed: Bool = false
    ) -> AnnotationItem {
        let rect = constrainedRect(
            start: start,
            current: current,
            aspectRatio: shiftPressed ? 1.0 : nil
        )
        switch session.activeTool {
        case .arrow:
            let preset = session.toolPresets.arrow
            var endPoint = current
            if shiftPressed {
                let dx = current.x - start.x
                let dy = current.y - start.y
                let dist = hypot(dx, dy)
                let snapped = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
                endPoint = CGPoint(x: start.x + cos(snapped) * dist, y: start.y + sin(snapped) * dist)
            }
            return AnnotationItem(
                kind: .arrow,
                startPoint: start,
                endPoint: endPoint,
                color: preset.color,
                strokeWidth: preset.strokeWidth,
                arrowStyle: preset.style,
                dashStyle: preset.dashStyle
            )
        case .rectangle:
            let preset = session.toolPresets.rectangle
            return AnnotationItem(
                kind: .rectangle,
                rect: rect,
                color: preset.color,
                strokeWidth: preset.strokeWidth,
                dashStyle: preset.dashStyle,
                fillStyle: preset.fillStyle,
                cornerRadius: preset.cornerRadius
            )
        case .ellipse:
            let preset = session.toolPresets.ellipse
            return AnnotationItem(
                kind: .ellipse,
                rect: rect,
                color: preset.color,
                strokeWidth: preset.strokeWidth,
                dashStyle: preset.dashStyle,
                fillStyle: preset.fillStyle
            )
        case .highlighter:
            let preset = session.toolPresets.highlighter
            if preset.mode == .box {
                return AnnotationItem(
                    kind: .highlighter,
                    rect: rect,
                    color: preset.color,
                    strokeWidth: preset.strokeWidth,
                    highlighterMode: .box,
                    highlighterOpacity: preset.opacity
                )
            }
            let targetPoint: CGPoint
            if shiftPressed {
                if abs(current.x - start.x) >= abs(current.y - start.y) {
                    targetPoint = CGPoint(x: current.x, y: start.y)
                } else {
                    targetPoint = CGPoint(x: start.x, y: current.y)
                }
            } else {
                targetPoint = current
            }
            var pts = previous?.points ?? [start]
            if let last = pts.last, hypot(targetPoint.x - last.x, targetPoint.y - last.y) >= 3 {
                pts.append(targetPoint)
            }
            return AnnotationItem(
                kind: .highlighter,
                points: pts,
                color: preset.color,
                strokeWidth: preset.strokeWidth,
                highlighterMode: .freehand,
                highlighterOpacity: preset.opacity
            )
        case .redact:
            let preset = session.toolPresets.redact
            return AnnotationItem(
                kind: .redact,
                rect: rect,
                color: .black,
                strokeWidth: 4,
                redactStyle: preset.style,
                redactStrength: preset.strength,
                redactSolidColor: preset.solidColor
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
            if item.highlighterMode == .box {
                return item.rect.width >= 6 && item.rect.height >= 6
            }
            return item.points.count >= 2
        case .step, .text:
            return true
        }
    }

    private func refreshPixelatedCacheIfNeeded() {
        let filteredKeys = session.annotations
            .filter { $0.kind == .redact && $0.redactStyle != .solidBlack }
            .map {
                QuickScreenshotEditorUIState.FilteredRedactCacheKey(
                    rect: $0.rect,
                    style: $0.redactStyle,
                    strength: $0.redactStrength,
                    solidColor: $0.redactSolidColor
                )
            }
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

private struct RoundedCropClipShape: Shape {
    let rect: CGRect
    let cornerRadius: CGFloat

    func path(in bounds: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: cornerRadius)
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

private struct NonHitTestingAnchorReader: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NonHitTestingAnchorView {
        let view = NonHitTestingAnchorView()
        DispatchQueue.main.async {
            onResolve(view)
        }
        return view
    }

    func updateNSView(_ nsView: NonHitTestingAnchorView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView)
        }
    }
}

private final class NonHitTestingAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct EditorTooltipControllerKey: EnvironmentKey {
    static let defaultValue: EditorTooltipController? = nil
}

extension EnvironmentValues {
    var editorTooltipController: EditorTooltipController? {
        get { self[EditorTooltipControllerKey.self] }
        set { self[EditorTooltipControllerKey.self] = newValue }
    }
}

@MainActor
final class EditorTooltipController {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var showTask: Task<Void, Never>?

    func scheduleShow(text: String, anchorView: NSView?) {
        showTask?.cancel()
        guard let anchorView, let parentWindow = anchorView.window, parentWindow.isVisible else {
            hide()
            return
        }
        showTask = Task { @MainActor [weak self, weak anchorView, weak parentWindow] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled,
                  let self,
                  let anchorView,
                  let parentWindow,
                  anchorView.window === parentWindow,
                  parentWindow.isVisible else {
                return
            }
            let rectInWindow = anchorView.convert(anchorView.bounds, to: nil)
            let screenRect = parentWindow.convertToScreen(rectInWindow)
            self.present(text: text, screenRect: screenRect, parentWindow: parentWindow)
        }
    }

    func hide() {
        showTask?.cancel()
        showTask = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func present(text: String, screenRect: CGRect, parentWindow: NSWindow) {
        let bubble = AnyView(
            Text(text)
                .toolboxFont(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Color(red: 0.14, green: 0.15, blue: 0.18).opacity(0.97),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
                .padding(6)
                .toolboxDarkAppearance()
        )

        let tipPanel: NSPanel
        let controller: NSHostingController<AnyView>
        if let existing = panel, let existingController = hostingController {
            existingController.rootView = bubble
            tipPanel = existing
            controller = existingController
        } else {
            let newTip = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 220, height: 34),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newTip.isFloatingPanel = true
            newTip.level = NSWindow.Level(rawValue: parentWindow.level.rawValue + 2)
            newTip.isOpaque = false
            newTip.backgroundColor = .clear
            newTip.hasShadow = false
            newTip.hidesOnDeactivate = false
            newTip.ignoresMouseEvents = true
            newTip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            ToolboxTheme.applyDarkAppearance(to: newTip)
            let newController = NSHostingController(rootView: bubble)
            newController.sizingOptions = []
            newTip.contentViewController = newController
            self.panel = newTip
            self.hostingController = newController
            tipPanel = newTip
            controller = newController
        }

        let fitted = controller.sizeThatFits(in: CGSize(width: 280, height: 140))
        let size = NSSize(
            width: ceil(min(max(fitted.width, 40), 280)),
            height: ceil(min(max(fitted.height, 28), 140))
        )
        let shadowInset: CGFloat = 6
        let parentFrame = parentWindow.frame
        let minX = parentFrame.minX + 6 - shadowInset
        let maxX = max(minX, parentFrame.maxX - 6 + shadowInset - size.width)
        var originX = min(max(screenRect.midX - size.width / 2, minX), maxX)
        let belowY = screenRect.minY - 4 + shadowInset - size.height
        let aboveY = screenRect.maxY + 4 - shadowInset
        var originY = (belowY + shadowInset >= parentFrame.minY + 6) ? belowY : aboveY

        if let visible = parentWindow.screen?.visibleFrame {
            originX = min(max(originX, visible.minX + 4), max(visible.minX + 4, visible.maxX - size.width - 4))
            originY = min(max(originY, visible.minY + 4), max(visible.minY + 4, visible.maxY - size.height - 4))
        }

        tipPanel.setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height), display: true)
        if tipPanel.parent !== parentWindow {
            parentWindow.addChildWindow(tipPanel, ordered: .above)
        }
        tipPanel.orderFrontRegardless()
    }
}

private struct EditorTooltipModifier: ViewModifier {
    let text: String
    @Environment(\.editorTooltipController) private var controller
    @StateObject private var anchorBox = AnchorBox()

    private final class AnchorBox: ObservableObject {
        weak var view: NSView?
    }

    func body(content: Content) -> some View {
        content
            .background(
                NonHitTestingAnchorReader { view in
                    anchorBox.view = view
                }
            )
            .onHover { hovering in
                if hovering {
                    controller?.scheduleShow(text: text, anchorView: anchorBox.view)
                } else {
                    controller?.hide()
                }
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    controller?.hide()
                }
            )
    }
}

private extension View {
    func editorTooltip(_ text: String) -> some View {
        modifier(EditorTooltipModifier(text: text))
    }
}
