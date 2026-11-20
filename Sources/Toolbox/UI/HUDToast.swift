import AppKit
import SwiftUI

@MainActor
final class HUDToast {
    static let shared = HUDToast()
    static let fixedHeight: CGFloat = 44
    static let minWidth: CGFloat = 200
    /// Top edge inset from the top of the screen's visible frame.
    static let topInset: CGFloat = 48

    private var panel: NSPanel?
    private var dismissTask: DispatchWorkItem?

    internal var panelForTesting: NSPanel? {
        panel
    }

    private init() {}

    static func makeToastView(title: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(tint)
            Text(title)
                .font(.title3.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(minWidth: minWidth)
        .frame(height: fixedHeight)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .fixedSize()
        .toolboxDarkAppearance()
    }

    static func measuredSize(title: String, symbol: String, tint: Color = .green) -> NSSize {
        let hosting = NSHostingView(rootView: makeToastView(title: title, symbol: symbol, tint: tint))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        return NSSize(
            width: ceil(max(minWidth, fitting.width)),
            height: fixedHeight
        )
    }

    /// Top-center placement: horizontally centered, with `topInset` of space above the pill.
    static func defaultTopCenterFrame(forSize size: NSSize, inVisibleFrame frame: NSRect) -> NSRect {
        NSRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - topInset,
            width: size.width,
            height: size.height
        )
    }

    func show(title: String, symbol: String = "checkmark.circle.fill", tint: Color = .green) {
        dismissTask?.cancel()

        let view = Self.makeToastView(title: title, symbol: symbol, tint: tint)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let width = ceil(max(Self.minWidth, fitting.width))
        let height = Self.fixedHeight

        let toastPanel: NSPanel
        if let existing = panel {
            toastPanel = existing
        } else {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = .statusBar
            p.hidesOnDeactivate = false
            p.ignoresMouseEvents = true
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            ToolboxTheme.applyDarkAppearance(to: p)
            self.panel = p
            toastPanel = p
        }

        toastPanel.contentView = hosting
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let size = NSSize(width: width, height: height)
            toastPanel.setFrame(Self.defaultTopCenterFrame(forSize: size, inVisibleFrame: screen.visibleFrame), display: true)
        }
        toastPanel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak toastPanel] in
            toastPanel?.orderOut(nil)
        }
        dismissTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
}
