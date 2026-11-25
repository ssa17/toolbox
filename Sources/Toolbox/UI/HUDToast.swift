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

    static func makeToastView(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        tint: Color,
        fixedWidth: CGFloat? = nil,
        isLoading: Bool = false
    ) -> some View {
        HUDToastPillView(
            title: title,
            subtitle: subtitle,
            symbol: symbol,
            tint: tint,
            fixedWidth: fixedWidth,
            isLoading: isLoading
        )
        .toolboxDarkAppearance()
    }

    private static func makeHostedToast(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        tint: Color,
        fixedWidth: CGFloat? = nil,
        isLoading: Bool = false
    ) -> (hosting: NSView, size: NSSize) {
        let hosting = NSHostingView(
            rootView: makeToastView(
                title: title,
                subtitle: subtitle,
                symbol: symbol,
                tint: tint,
                fixedWidth: fixedWidth,
                isLoading: isLoading
            )
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

    static func measuredSize(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        tint: Color = .green
    ) -> NSSize {
        makeHostedToast(title: title, subtitle: subtitle, symbol: symbol, tint: tint).size
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

    func showLoading(
        title: String,
        subtitle: String? = nil,
        tint: Color = .indigo,
        maxDuration: TimeInterval = 10.0
    ) {
        present(
            title: title,
            subtitle: subtitle,
            symbol: "arrow.triangle.2.circlepath",
            tint: tint,
            duration: maxDuration,
            isLoading: true
        )
    }

    func show(
        title: String,
        subtitle: String? = nil,
        symbol: String = "checkmark.circle.fill",
        tint: Color = .green,
        duration: TimeInterval = HUDToast.defaultDuration
    ) {
        present(
            title: title,
            subtitle: subtitle,
            symbol: symbol,
            tint: tint,
            duration: duration,
            isLoading: false
        )
    }

    private func present(
        title: String,
        subtitle: String?,
        symbol: String,
        tint: Color,
        duration: TimeInterval,
        isLoading: Bool
    ) {
        dismissTask?.cancel()
        dismissTask = nil
        dismissGeneration &+= 1
        let generation = dismissGeneration

        var (hosting, size) = Self.makeHostedToast(
            title: title,
            subtitle: subtitle,
            symbol: symbol,
            tint: tint,
            isLoading: isLoading
        )

        let targetFrame: NSRect?
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = Self.defaultTopCenterFrame(forSize: size, inVisibleFrame: screen.visibleFrame)
            if frame.width < size.width {
                (hosting, _) = Self.makeHostedToast(
                    title: title,
                    subtitle: subtitle,
                    symbol: symbol,
                    tint: tint,
                    fixedWidth: frame.width,
                    isLoading: isLoading
                )
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

        let wasHidden = !toastPanel.isVisible
        toastPanel.contentView = hosting
        if let targetFrame {
            toastPanel.setFrame(targetFrame, display: true)
        }
        toastPanel.invalidateShadow()
        if wasHidden && !PermissionsManager.isRunningInDiagnosticMode {
            toastPanel.alphaValue = 0
            toastPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                toastPanel.animator().alphaValue = 1
            }
        } else {
            toastPanel.alphaValue = 1
            toastPanel.orderFrontRegardless()
        }

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
    let subtitle: String?
    let symbol: String
    let tint: Color
    let fixedWidth: CGFloat?
    let isLoading: Bool

    @Environment(\.toolboxTextSize) private var textSize

    var body: some View {
        let hasSubtitle = !(subtitle?.isEmpty ?? true)
        let baseHeight: CGFloat = hasSubtitle ? 52 : HUDToast.fixedHeight
        let pillHeight = textSize == .standard
            ? baseHeight
            : max(baseHeight, ceil(baseHeight * textSize.scaleFactor))
        let iconBoxSize = textSize == .standard
            ? CGFloat(24)
            : max(CGFloat(24), ceil(24 * textSize.scaleFactor))

        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: iconBoxSize + 4, height: iconBoxSize + 4)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                } else {
                    Image(systemName: symbol)
                        .toolboxFont(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: iconBoxSize + 4, height: iconBoxSize + 4)

            if let subtitle, !subtitle.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .toolboxFont(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .toolboxFont(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                Text(title)
                    .toolboxFont(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 16)
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
