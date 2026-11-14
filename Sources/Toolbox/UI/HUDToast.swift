import AppKit
import SwiftUI

@MainActor
final class HUDToast {
    static let shared = HUDToast()

    private var panel: NSPanel?
    private var dismissTask: DispatchWorkItem?

    private init() {}

    func show(title: String, symbol: String = "checkmark.circle.fill", tint: Color = .green) {
        dismissTask?.cancel()

        let view = HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )

        let hosting = NSHostingView(rootView: view)
        let fitting = hosting.fittingSize
        let width = max(180, fitting.width + 8)
        let height = max(36, fitting.height + 4)

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
            self.panel = p
            toastPanel = p
        }

        toastPanel.contentView = hosting
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            let x = frame.midX - width / 2
            let y = frame.maxY - height - 24
            toastPanel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
        toastPanel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak toastPanel] in
            toastPanel?.orderOut(nil)
        }
        dismissTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
}
