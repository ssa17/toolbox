import AppKit
import SwiftUI

enum ToolboxTheme {
    static let cardCornerRadius: CGFloat = 12
    static let pillCornerRadius: CGFloat = 6
}

extension View {
    /// Shows the system pointing-hand cursor on hover for clickable controls and interactive surfaces,
    /// including inside `NSMenu` and `.nonactivatingPanel` popovers where SwiftUI's `.pointerStyle(.link)` does not fire.
    @ViewBuilder
    func pointerCursor(_ active: Bool = true) -> some View {
        if active {
            self.overlay(PointerCursorOverlay().allowsHitTesting(false))
        } else {
            self
        }
    }
}

private struct PointerCursorOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> PointerCursorNSView {
        PointerCursorNSView()
    }

    func updateNSView(_ nsView: PointerCursorNSView, context: Context) {
        nsView.reapplyCursorIfHovered()
    }
}

final class PointerCursorNSView: NSView {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private static var localEventMonitor: Any?

    static func forcePointingHandCursor() {
        // AppKit short-circuits NSCursor.pointingHand.set() if NSCursor.current is already pointingHand,
        // even when WindowServer/AppKit reset the actual system cursor to arrow after a click.
        if NSCursor.currentSystem?.hotSpot != NSCursor.pointingHand.hotSpot {
            NSCursor.arrow.set()
        }
        NSCursor.pointingHand.set()
    }

    static func isPoint(_ ptInWindow: NSPoint, inside view: NSView) -> Bool {
        guard !view.isHidden, view.alphaValue > 0.01 else { return false }
        let localPt = view.convert(ptInWindow, from: nil)
        // On macOS SwiftUI NSHostingView, visibleRect can report an unclipped ancestor container rect
        // larger than bounds; always intersect with bounds so hover never leaks to the surrounding page.
        let clipped = view.bounds.intersection(view.visibleRect)
        guard !clipped.isEmpty, clipped.contains(localPt) else { return false }
        if let clipView = view.enclosingScrollView?.contentView {
            let ptInClip = clipView.convert(ptInWindow, from: nil)
            if !clipView.bounds.contains(ptInClip) {
                return false
            }
        }
        return true
    }

    static func containsPointerCursorView(in view: NSView, atWindowPoint ptInWindow: NSPoint) -> Bool {
        guard !view.isHidden, view.alphaValue > 0.01 else { return false }
        if view is PointerCursorNSView {
            return isPoint(ptInWindow, inside: view)
        }
        for subview in view.subviews {
            if containsPointerCursorView(in: subview, atWindowPoint: ptInWindow) {
                return true
            }
        }
        return false
    }

    static func syncCursor(in window: NSWindow) {
        // NSMenu popups manage their own 40ms cursor sync loop via MenuBarController.
        guard window.level.rawValue < NSWindow.Level.popUpMenu.rawValue,
              let rootView = window.contentView?.superview ?? window.contentView else { return }
        let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard rootView.bounds.contains(ptInWindow) else { return }
        if containsPointerCursorView(in: rootView, atWindowPoint: ptInWindow) {
            forcePointingHandCursor()
        } else if NSCursor.currentSystem?.hotSpot == NSCursor.pointingHand.hotSpot {
            // Reset only if we're leaving a pointing-hand region so IBeam/resize cursors remain untouched.
            NSCursor.arrow.set()
        }
    }

    private static func ensureLocalEventMonitor() {
        guard localEventMonitor == nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .mouseMoved, .cursorUpdate]
        ) { event in
            guard let window = event.window ?? NSApp.keyWindow,
                  window.level.rawValue < NSWindow.Level.popUpMenu.rawValue else {
                return event
            }
            switch event.type {
            case .leftMouseDown, .leftMouseUp:
                // AppKit controls (NSButton, NSSwitch, NSPopUpButton, toolbar SwiftUIAppKitButton)
                // swallow .leftMouseUp inside trackMouse, so scheduling on .common from both down & up
                // ensures cursor sync runs immediately after tracking completes and again after layout.
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated {
                        syncCursor(in: window)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    MainActor.assumeIsolated {
                        syncCursor(in: window)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    MainActor.assumeIsolated {
                        syncCursor(in: window)
                    }
                }
                return event
            case .mouseMoved:
                syncCursor(in: window)
                return event
            case .cursorUpdate:
                if let rootView = window.contentView?.superview ?? window.contentView {
                    let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                    if containsPointerCursorView(in: rootView, atWindowPoint: ptInWindow) {
                        forcePointingHandCursor()
                        // Prevent NSTitlebarContainerView / NSButton cursorUpdate from overwriting pointingHand.
                        return nil
                    }
                }
                if NSCursor.currentSystem?.hotSpot == NSCursor.pointingHand.hotSpot {
                    NSCursor.arrow.set()
                }
                return event
            default:
                return event
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let oldWindow = window, isHovered {
            isHovered = false
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    Self.syncCursor(in: oldWindow)
                }
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            if window.level.rawValue < NSWindow.Level.popUpMenu.rawValue {
                window.acceptsMouseMovedEvents = true
            }
            Self.ensureLocalEventMonitor()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
        reapplyCursorIfHovered()
    }

    func reapplyCursorIfHovered() {
        guard let window else { return }
        let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let nowHovered = Self.isPoint(ptInWindow, inside: self)
        let wasHovered = isHovered
        isHovered = nowHovered
        if nowHovered {
            Self.forcePointingHandCursor()
            RunLoop.main.perform(inModes: [.eventTracking, .common]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let win = self.window else { return }
                    let pt = win.convertPoint(fromScreen: NSEvent.mouseLocation)
                    if Self.isPoint(pt, inside: self) {
                        Self.forcePointingHandCursor()
                    }
                }
            }
        } else if wasHovered {
            Self.syncCursor(in: window)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if let window {
            let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            isHovered = Self.isPoint(ptInWindow, inside: self)
        }
        if isHovered {
            Self.forcePointingHandCursor()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let window else { return }
        let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        isHovered = Self.isPoint(ptInWindow, inside: self)
        guard isHovered else { return }
        Self.forcePointingHandCursor()
        // Re-apply on the next tracking-loop turn in case NSMenu resets the cursor upon initial window entry.
        RunLoop.main.perform(inModes: [.eventTracking, .common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let win = self.window else { return }
                let pt = win.convertPoint(fromScreen: NSEvent.mouseLocation)
                if Self.isPoint(pt, inside: self) {
                    Self.forcePointingHandCursor()
                }
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let window {
            let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            if Self.isPoint(ptInWindow, inside: self) {
                return
            }
            isHovered = false
            Self.syncCursor(in: window)
        } else {
            isHovered = false
            NSCursor.arrow.set()
        }
    }
}

/// `NSHostingView` subclass for popovers and panels using `.pointerCursor()`.
/// Prevents AppKit `cursorUpdate(with:)` and SwiftUI `layout()` passes from
/// reverting the cursor to `.arrow` while hovering a `.pointerCursor()` control.
final class PointerCursorHostingView<Content: View>: NSHostingView<Content> {
    static func shouldUsePointingHand(in window: NSWindow, atWindowPoint pt: NSPoint) -> Bool {
        guard let rootView = window.contentView?.superview ?? window.contentView,
              rootView.bounds.contains(pt) else {
            return false
        }
        return PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: pt)
    }

    override func cursorUpdate(with event: NSEvent) {
        if let window, window.isVisible {
            let pt = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            if Self.shouldUsePointingHand(in: window, atWindowPoint: pt) {
                PointerCursorNSView.forcePointingHandCursor()
                return
            }
        }
        super.cursorUpdate(with: event)
    }

    override func layout() {
        super.layout()
        if let window, window.isVisible {
            PointerCursorNSView.syncCursor(in: window)
        }
    }
}

struct BackToDashboardBar: View {
    let onBackToDashboard: () -> Void

    var body: some View {
        HStack {
            Button(action: onBackToDashboard) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                    Text("Back to Dashboard")
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerCursor()

            Spacer()
        }
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }
}

struct ShortcutPill: View {
    private let tokens: [String]

    init(shortcut: ShortcutSpec) {
        self.tokens = shortcut.tokens
    }

    init(tokens: [String]) {
        self.tokens = tokens
    }

    init(text: String) {
        self.tokens = text
            .split(separator: " ")
            .map(String.init)
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Text(token)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16, minHeight: 18)
                    .padding(.horizontal, token.count > 1 ? 4 : 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            }
        }
    }
}

struct SectionCard<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                .strokeBorder(Color.primary.opacity(0.11), lineWidth: 1)
        )
    }
}

/// Clearly separated settings section with an external uppercase title and a crisp grouped card.
struct FeatureSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let content: () -> Content

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)
            .textSelection(.enabled)

            SectionCard {
                content()
            }
        }
    }
}

struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    let trailing: () -> Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)

            Spacer(minLength: 12)

            trailing()
        }
    }
}

/// High-contrast pill switch for status bar menus (and other non-key surfaces) where
/// macOS renders native `.switch` toggles in muted gray regardless of on/off state.
struct StatusBarSwitchToggleStyle: ToggleStyle {
    var onColor: Color = .green

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? onColor : Color.primary.opacity(0.16))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                configuration.isOn ? onColor.opacity(0.35) : Color.primary.opacity(0.24),
                                lineWidth: 1
                            )
                    )
                    .frame(width: 34, height: 19)

                Circle()
                    .fill(configuration.isOn ? Color.white : Color.white.opacity(0.82))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, x: 0, y: 0.5)
                    .frame(width: 15, height: 15)
                    .padding(2)
            }
            .contentShape(Capsule())
            .animation(.easeInOut(duration: 0.16), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// Bento Option C brand mark: 3 top squares over 1 wide bar.
struct ToolboxBentoMark: View {
    var size: CGFloat = 18
    var primaryColor: Color = .primary
    var accentColor: Color = .accentColor

    var body: some View {
        let sq = size * 0.255
        let gx = size * 0.115
        let gy = size * 0.125
        let barH = size * 0.285
        let totalW = sq * 3 + gx * 2
        let r = sq * 0.26

        VStack(spacing: gy) {
            HStack(spacing: gx) {
                RoundedRectangle(cornerRadius: r)
                    .fill(primaryColor)
                    .frame(width: sq, height: sq)
                RoundedRectangle(cornerRadius: r)
                    .fill(primaryColor)
                    .frame(width: sq, height: sq)
                RoundedRectangle(cornerRadius: r)
                    .fill(accentColor)
                    .frame(width: sq, height: sq)
            }
            RoundedRectangle(cornerRadius: r)
                .fill(primaryColor)
                .frame(width: totalW, height: barH)
        }
        .frame(width: size, height: size)
    }
}
