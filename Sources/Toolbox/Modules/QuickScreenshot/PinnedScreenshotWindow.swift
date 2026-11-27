import AppKit
import Carbon
import SwiftUI

/// Floating always-on-top reference window created by Quick Screenshot's "Pin on Screen" action.
@MainActor
final class PinnedScreenshotWindowController: NSObject, NSWindowDelegate {
    private(set) var image: CGImage?
    private let onClosed: (PinnedScreenshotWindowController) -> Void
    private var panel: PointerCursorNSPanel?
    nonisolated(unsafe) private var keyMonitor: Any?

    init(image: CGImage, onClosed: @escaping (PinnedScreenshotWindowController) -> Void) {
        self.image = image
        self.onClosed = onClosed
        super.init()
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    func present() {
        guard !PermissionsManager.isRunningInDiagnosticMode else { return }
        let p = ensurePanel()
        p.orderFrontRegardless()
        installKeyMonitor(for: p)
    }

    func forceClose() {
        if let panel {
            panel.close()
        } else {
            image = nil
            onClosed(self)
        }
    }

    private func ensurePanel() -> PointerCursorNSPanel {
        if let panel {
            return panel
        }
        guard let image else {
            let empty = PointerCursorNSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 140),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            self.panel = empty
            return empty
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let scale = max(1.0, screen?.backingScaleFactor ?? 2.0)
        let rawW = max(80.0, CGFloat(image.width) / scale)
        let rawH = max(60.0, CGFloat(image.height) / scale)
        let maxW: CGFloat = 520
        let maxH: CGFloat = 400
        let fitRatio = min(1.0, min(maxW / rawW, maxH / rawH))
        let displaySize = NSSize(width: round(rawW * fitRatio), height: round(rawH * fitRatio))

        let p = PointerCursorNSPanel(
            contentRect: NSRect(origin: .zero, size: displaySize),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true
        p.isMovableByWindowBackground = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 120, height: 90)
        p.contentAspectRatio = NSSize(width: max(1, image.width), height: max(1, image.height))
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        ToolboxTheme.applyDarkAppearance(to: p)

        let view = PinnedScreenshotView(
            image: image,
            onCopy: { [weak self] in self?.copyImage() },
            onToggleOpacity: { [weak self] reduced in
                self?.panel?.alphaValue = reduced ? 0.65 : 1.0
            },
            onScaleStep: { [weak self] factor in
                self?.scalePanel(by: factor)
            },
            onClose: { [weak self] in self?.forceClose() }
        )
        p.contentView = PointerCursorHostingView(rootView: view)

        if let vf = screen?.visibleFrame {
            let x = vf.maxX - displaySize.width - 28
            let y = vf.maxY - displaySize.height - 28
            p.setFrameOrigin(NSPoint(x: max(vf.minX + 16, x), y: max(vf.minY + 16, y)))
        }

        self.panel = p
        return p
    }

    private func scalePanel(by factor: CGFloat) {
        guard let panel else { return }
        let frame = panel.frame
        let newW = min(max(140, frame.width * factor), 1100)
        let aspect = panel.contentAspectRatio
        let ratio = aspect.height > 0 ? aspect.width / aspect.height : 1.5
        let newH = max(90, newW / max(0.25, ratio))
        let newOrigin = NSPoint(
            x: frame.midX - newW / 2,
            y: frame.midY - newH / 2
        )
        panel.setFrame(NSRect(origin: newOrigin, size: NSSize(width: round(newW), height: round(newH))), display: true, animate: true)
    }

    private func copyImage() {
        guard let image else { return }
        if ScreenshotRenderer.copyToPasteboard(image) {
            HUDToast.shared.show(
                title: "Copied pinned screenshot",
                symbol: "doc.on.clipboard.fill",
                tint: .red
            )
        }
    }

    private func installKeyMonitor(for panel: NSPanel) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, event.window === panel else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.forceClose()
                return nil
            }
            return event
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        image = nil
        panel?.contentView = nil
        panel = nil
        onClosed(self)
    }
}

@MainActor
private final class PinnedScreenshotUIState: ObservableObject {
    @Published var isHovered = false
    @Published var isTranslucent = false
}

private struct PinnedScreenshotView: View {
    let image: CGImage
    let onCopy: () -> Void
    let onToggleOpacity: (Bool) -> Void
    let onScaleStep: (CGFloat) -> Void
    let onClose: () -> Void

    @StateObject private var uiState = PinnedScreenshotUIState()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(decorative: image, scale: 1.0, orientation: .up)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white.opacity(uiState.isHovered ? 0.34 : 0.16), lineWidth: 1)
                )

            if uiState.isHovered {
                HStack(spacing: 4) {
                    Button {
                        onScaleStep(0.85)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .toolboxFont(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .help("Zoom Out")
                    .pointerCursor()

                    Button {
                        onScaleStep(1.18)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .toolboxFont(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .help("Zoom In")
                    .pointerCursor()

                    Button {
                        uiState.isTranslucent.toggle()
                        onToggleOpacity(uiState.isTranslucent)
                    } label: {
                        Image(systemName: uiState.isTranslucent ? "circle.lefthalf.filled" : "circle.fill")
                            .toolboxFont(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .help(uiState.isTranslucent ? "Restore 100% Opacity" : "Dim to 65% Opacity")
                    .pointerCursor()

                    Button {
                        onCopy()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .toolboxFont(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .help("Copy Image")
                    .pointerCursor()

                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .toolboxFont(.caption2.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .help("Close Pinned Screenshot (Esc)")
                    .pointerCursor()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThickMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75))
                .padding(8)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                uiState.isHovered = hovering
            }
        }
        .contextMenu {
            Button("Copy Image") { onCopy() }
            Button(uiState.isTranslucent ? "100% Opacity" : "65% Opacity") {
                uiState.isTranslucent.toggle()
                onToggleOpacity(uiState.isTranslucent)
            }
            Divider()
            Button("Zoom In") { onScaleStep(1.2) }
            Button("Zoom Out") { onScaleStep(0.82) }
            Divider()
            Button("Close") { onClose() }
        }
        .toolboxDarkAppearance()
    }
}
