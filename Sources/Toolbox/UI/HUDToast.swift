import AppKit
import SwiftUI

@MainActor
final class HUDToast {
    static let shared = HUDToast()
    static let fixedHeight: CGFloat = 44
    static let minWidth: CGFloat = 200
    /// Top edge inset from the top of the screen's visible frame.
    static let topInset: CGFloat = 80
    static let screenHorizontalMargin: CGFloat = 16
    static let defaultDuration: TimeInterval = 2.0

    private var panel: NSPanel?
    private var dismissTask: DispatchWorkItem?
    private var dismissGeneration: UInt64 = 0

    internal var panelForTesting: NSPanel? {
        panel
    }

    private init() {}

    static func makeToastView(title: String, symbol: String, tint: Color, fixedWidth: CGFloat? = nil) -> some View {
        HUDToastPillView(title: title, symbol: symbol, tint: tint, fixedWidth: fixedWidth)
            .toolboxDarkAppearance()
    }

    private static func makeHostedToast(
        title: String,
        symbol: String,
        tint: Color,
        fixedWidth: CGFloat? = nil
    ) -> (hosting: NSView, size: NSSize) {
        let hosting = NSHostingView(
            rootView: makeToastView(title: title, symbol: symbol, tint: tint, fixedWidth: fixedWidth)
        )
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let size = NSSize(
            width: ceil(max(fixedWidth ?? minWidth, fitting.width)),
            height: ceil(fitting.height)
        )
        return (hosting, size)
    }

    static func measuredSize(title: String, symbol: String, tint: Color = .green) -> NSSize {
        makeHostedToast(title: title, symbol: symbol, tint: tint).size
    }

    /// Top-center placement: horizontally centered, clamped within `screenHorizontalMargin`,
    /// with `topInset` of space above the pill.
    static func defaultTopCenterFrame(forSize size: NSSize, inVisibleFrame frame: NSRect) -> NSRect {
        let maxAvailableWidth = max(0, frame.width - screenHorizontalMargin * 2)
        let width = maxAvailableWidth > 0 ? min(size.width, maxAvailableWidth) : size.width
        let x = round(frame.midX - width / 2)
        let y = round(frame.maxY - size.height - topInset)
        return NSRect(x: x, y: y, width: width, height: size.height)
    }

    func dismiss() {
        dismissGeneration &+= 1
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    func show(
        title: String,
        symbol: String = "checkmark.circle.fill",
        tint: Color = .green,
        duration: TimeInterval = HUDToast.defaultDuration
    ) {
        dismissTask?.cancel()
        dismissTask = nil
        dismissGeneration &+= 1
        let generation = dismissGeneration

        var (hosting, size) = Self.makeHostedToast(title: title, symbol: symbol, tint: tint)

        let targetFrame: NSRect?
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = Self.defaultTopCenterFrame(forSize: size, inVisibleFrame: screen.visibleFrame)
            if frame.width < size.width {
                (hosting, _) = Self.makeHostedToast(title: title, symbol: symbol, tint: tint, fixedWidth: frame.width)
            }
            targetFrame = frame
        } else {
            targetFrame = nil
        }

        let toastPanel: NSPanel
        if let existing = panel {
            toastPanel = existing
        } else {
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            p.isReleasedWhenClosed = false
            p.isFloatingPanel = true
            p.level = .statusBar
            p.hidesOnDeactivate = false
            p.ignoresMouseEvents = true
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            ToolboxTheme.applyDarkAppearance(to: p)
            self.panel = p
            toastPanel = p
        }

        toastPanel.contentView = hosting
        if let targetFrame {
            toastPanel.setFrame(targetFrame, display: true)
        }
        toastPanel.invalidateShadow()
        toastPanel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self, weak toastPanel] in
            guard let self, self.dismissGeneration == generation else { return }
            toastPanel?.orderOut(nil)
            self.dismissTask = nil
        }
        dismissTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, duration), execute: work)
    }
}

private struct HUDToastPillView: View {
    let title: String
    let symbol: String
    let tint: Color
    let fixedWidth: CGFloat?

    @Environment(\.toolboxTextSize) private var textSize

    var body: some View {
        let pillHeight = textSize == .standard
            ? HUDToast.fixedHeight
            : max(HUDToast.fixedHeight, ceil(HUDToast.fixedHeight * textSize.scaleFactor))
        let iconBoxSize = textSize == .standard
            ? CGFloat(22)
            : max(CGFloat(22), ceil(22 * textSize.scaleFactor))

        HStack(spacing: 10) {
            Image(systemName: symbol)
                .toolboxFont(.system(size: 16, weight: .semibold))
                .frame(width: iconBoxSize, height: iconBoxSize)
                .foregroundStyle(tint)
            Text(title)
                .toolboxFont(.title3.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 18)
        .frame(minWidth: fixedWidth ?? HUDToast.minWidth, maxWidth: fixedWidth)
        .frame(height: pillHeight)
        .fixedSize(horizontal: fixedWidth == nil, vertical: true)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .clipShape(Capsule())
    }
}
