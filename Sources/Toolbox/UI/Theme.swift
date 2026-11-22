import AppKit
import SwiftUI

enum ToolboxTheme {
    static let cardCornerRadius: CGFloat = 12
    static let pillCornerRadius: CGFloat = 6

    /// Brand blue used for selected sidebar items and default prominent buttons,
    /// keeping white-on-blue contrast independent of the user's macOS System Accent Color.
    static let accentBlue = Color(red: 0.13, green: 0.44, blue: 0.92)

    /// Forced-dark AppKit appearance applied per Toolbox window/panel rather than on
    /// `NSApp.appearance` so the system menu bar `NSStatusItem` still adapts natively.
    static var darkAppearance: NSAppearance? {
        NSAppearance(named: .darkAqua)
    }

    @MainActor
    static func applyDarkAppearance(to window: NSWindow) {
        window.appearance = darkAppearance
    }

    /// Brightened dark-mode foreground tint for small text, badges, and glyphs on dark card surfaces.
    static func readableAccentText(for color: Color) -> Color {
        switch color {
        case .indigo: return Color(red: 0.64, green: 0.68, blue: 1.0)
        case .blue:   return Color(red: 0.42, green: 0.72, blue: 1.0)
        case .red:    return Color(red: 1.0, green: 0.46, blue: 0.44)
        case .purple: return Color(red: 0.80, green: 0.60, blue: 1.0)
        case .orange: return Color(red: 1.0, green: 0.68, blue: 0.30)
        case .pink:   return Color(red: 1.0, green: 0.48, blue: 0.66)
        case .mint:   return Color(red: 0.38, green: 0.90, blue: 0.82)
        case .teal:   return Color(red: 0.34, green: 0.84, blue: 0.86)
        case .green:  return Color(red: 0.32, green: 0.86, blue: 0.48)
        default:      return color
        }
    }

    /// Calibrated dark-mode switch track color so pure white switch thumbs retain crisp contrast.
    static func switchTrackColor(for color: Color) -> Color {
        switch color {
        case .mint:   return Color(red: 0.12, green: 0.62, blue: 0.56)
        case .teal:   return Color(red: 0.10, green: 0.56, blue: 0.62)
        case .indigo: return Color(red: 0.38, green: 0.40, blue: 0.92)
        default:      return color
        }
    }
}

private struct ToolboxInsideModalKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var toolboxInsideModal: Bool {
        get { self[ToolboxInsideModalKey.self] }
        set { self[ToolboxInsideModalKey.self] = newValue }
    }
}

extension View {
    /// Forces Toolbox's consistent dark theme on root SwiftUI surfaces (windows, popovers, sheets, HUDs).
    func toolboxDarkAppearance() -> some View {
        self
            .preferredColorScheme(.dark)
            .environment(\.colorScheme, .dark)
    }

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

    /// Subtle hover highlight for menu-bar popover rows and buttons. Fades in a translucent
    /// fill + border while the pointer is over the view, giving clear "interactive" feedback
    /// without altering the row's base styling. Holds its own hover state, so it works for
    /// static rows and inside `ForEach` alike.
    func menuRowHover(
        cornerRadius: CGFloat = 8,
        color: Color = .primary,
        fillOpacity: Double = 0.05,
        borderOpacity: Double = 0.14
    ) -> some View {
        MenuRowHover(
            cornerRadius: cornerRadius,
            color: color,
            fillOpacity: fillOpacity,
            borderOpacity: borderOpacity
        ) {
            self
        }
    }
}

extension Notification.Name {
    static let toolboxMenuBarPopoverDidClose = Notification.Name("toolbox.menuBarPopoverDidClose")
}

private final class MenuRowHoverState: ObservableObject {
    @Published var isHovered = false
}

private struct MenuRowHover<Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var state = MenuRowHoverState()
    var cornerRadius: CGFloat
    var color: Color
    var fillOpacity: Double
    var borderOpacity: Double
    @ViewBuilder var content: () -> Content

    var body: some View {
        let isHighlighted = isEnabled && state.isHovered
        content()
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(color.opacity(isHighlighted ? fillOpacity : 0))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(color.opacity(isHighlighted ? borderOpacity : 0), lineWidth: 0.75)
                    .allowsHitTesting(false)
            )
            .onHover { state.isHovered = isEnabled && $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    state.isHovered = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toolboxMenuBarPopoverDidClose)) { _ in
                state.isHovered = false
            }
    }
}

private struct PointerCursorOverlay: NSViewRepresentable {
    @Environment(\.toolboxInsideModal) private var isInsideModal

    func makeNSView(context: Context) -> PointerCursorNSView {
        let view = PointerCursorNSView()
        view.isInsideModalOverlay = isInsideModal
        return view
    }

    func updateNSView(_ nsView: PointerCursorNSView, context: Context) {
        nsView.isInsideModalOverlay = isInsideModal
        nsView.reapplyCursorIfHovered()
    }
}

@MainActor
protocol HoverCursorProviderView: NSView {
    var customHoverCursor: NSCursor { get }
}

final class PointerCursorNSView: NSView {
    private var hoverTrackingArea: NSTrackingArea?
    private var cursorTrackingArea: NSTrackingArea?
    private var isHovered = false
    var isInsideModalOverlay = false
    static var modalSuppressionActive = false
    private static var localEventMonitor: Any?
    /// Non-nil while an in-app row drag gesture owns the cursor (e.g. `.closedHand`),
    /// preventing hover/click cursor-sync passes from flashing `.pointingHand` mid-drag.
    static var activeDragCursor: NSCursor?

    static func forcePointingHandCursor() {
        NSCursor.pointingHand.set()
    }

    static func isManagedCursorWindow(_ window: NSWindow) -> Bool {
        guard !window.ignoresMouseEvents else { return false }
        let className = NSStringFromClass(type(of: window))
        if className.contains("MenuWindow") || className.contains("CarbonMenu") {
            return false
        }
        return window.level.rawValue <= NSWindow.Level.popUpMenu.rawValue
    }

    @discardableResult
    static func handleCursorUpdate(in window: NSWindow) -> Bool {
        if let dragCursor = activeDragCursor {
            dragCursor.set()
            return true
        }
        guard window.isVisible,
              isManagedCursorWindow(window),
              let rootView = window.contentView?.superview ?? window.contentView else {
            return false
        }
        let pt = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard rootView.bounds.contains(pt) else { return false }
        if containsPointerCursorView(in: rootView, atWindowPoint: pt) {
            forcePointingHandCursor()
            return true
        }
        if let custom = customHoverCursor(in: rootView, atWindowPoint: pt) {
            custom.set()
            return true
        }
        return false
    }

    static func isPoint(_ ptInWindow: NSPoint, inside view: NSView) -> Bool {
        guard !view.isHidden, view.alphaValue > 0.01 else { return false }
        if modalSuppressionActive, let pointerView = view as? PointerCursorNSView, !pointerView.isInsideModalOverlay {
            return false
        }
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

    static func customHoverCursor(in view: NSView, atWindowPoint ptInWindow: NSPoint) -> NSCursor? {
        guard !view.isHidden, view.alphaValue > 0.01 else { return nil }
        if let provider = view as? HoverCursorProviderView, isPoint(ptInWindow, inside: provider) {
            return provider.customHoverCursor
        }
        for subview in view.subviews {
            if let cursor = customHoverCursor(in: subview, atWindowPoint: ptInWindow) {
                return cursor
            }
        }
        return nil
    }

    private static func topmostManagedWindow(atScreenPoint mouse: NSPoint) -> NSWindow? {
        var candidates: [NSWindow] = []
        var seen = Set<ObjectIdentifier>()
        for win in NSApp.orderedWindows + NSApp.windows {
            if let sheet = win.attachedSheet,
               sheet.isVisible,
               isManagedCursorWindow(sheet),
               sheet.frame.contains(mouse),
               seen.insert(ObjectIdentifier(sheet)).inserted {
                candidates.append(sheet)
            }
            if win.isVisible,
               isManagedCursorWindow(win),
               win.frame.contains(mouse),
               seen.insert(ObjectIdentifier(win)).inserted {
                candidates.append(win)
            }
        }
        return candidates.max { lhs, rhs in
            lhs.level.rawValue < rhs.level.rawValue
        }
    }

    static func syncCursor(in window: NSWindow) {
        if let dragCursor = activeDragCursor {
            dragCursor.set()
            return
        }
        guard window.isVisible else {
            syncVisibleWindowUnderMouseOrResetCursor()
            return
        }
        guard isManagedCursorWindow(window) else { return }
        let mouse = NSEvent.mouseLocation
        if let topWindow = topmostManagedWindow(atScreenPoint: mouse),
           topWindow !== window,
           topWindow.level.rawValue > window.level.rawValue {
            syncCursor(in: topWindow)
            return
        }
        guard let rootView = window.contentView?.superview ?? window.contentView else { return }
        let ptInWindow = window.convertPoint(fromScreen: mouse)
        guard rootView.bounds.contains(ptInWindow) else { return }
        if containsPointerCursorView(in: rootView, atWindowPoint: ptInWindow) {
            forcePointingHandCursor()
        } else if let custom = customHoverCursor(in: rootView, atWindowPoint: ptInWindow) {
            custom.set()
        } else if NSCursor.currentSystem?.hotSpot == NSCursor.pointingHand.hotSpot
            || NSCursor.currentSystem?.hotSpot == NSCursor.openHand.hotSpot
            || NSCursor.currentSystem?.hotSpot == NSCursor.closedHand.hotSpot {
            // Reset only if we're leaving a pointing-hand or drag-hand region so IBeam/resize cursors remain untouched.
            NSCursor.arrow.set()
        }
    }

    private static func syncCursorOrReset(_ window: NSWindow?) {
        if let window, window.isVisible {
            syncCursor(in: window)
        } else {
            syncVisibleWindowUnderMouseOrResetCursor()
        }
    }

    /// Syncs the hover cursor against whichever visible managed window currently contains the pointer,
    /// or resets a stale pointing-hand cursor back to `.arrow`. Safe to call after a sheet/window deallocates.
    static func syncVisibleWindowUnderMouseOrResetCursor() {
        if let dragCursor = activeDragCursor {
            dragCursor.set()
            return
        }
        let mouse = NSEvent.mouseLocation
        if let candidate = topmostManagedWindow(atScreenPoint: mouse) {
            syncCursor(in: candidate)
        } else if NSCursor.currentSystem?.hotSpot == NSCursor.pointingHand.hotSpot {
            NSCursor.arrow.set()
        }
    }

    private static func ensureLocalEventMonitor() {
        guard localEventMonitor == nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .mouseMoved, .cursorUpdate]
        ) { event in
            guard let window = event.window ?? topmostManagedWindow(atScreenPoint: NSEvent.mouseLocation) ?? NSApp.keyWindow,
                  isManagedCursorWindow(window) else {
                return event
            }
            switch event.type {
            case .leftMouseDown, .leftMouseUp:
                // AppKit controls (NSButton, NSSwitch, NSPopUpButton, toolbar SwiftUIAppKitButton)
                // swallow .leftMouseUp inside trackMouse, so scheduling on .common from both down & up
                // ensures cursor sync runs immediately after tracking completes and again after layout.
                RunLoop.main.perform(inModes: [.common]) { [weak window] in
                    MainActor.assumeIsolated {
                        syncCursorOrReset(window)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak window] in
                    MainActor.assumeIsolated {
                        syncCursorOrReset(window)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak window] in
                    MainActor.assumeIsolated {
                        syncCursorOrReset(window)
                    }
                }
                return event
            case .mouseMoved:
                syncCursor(in: window)
                return event
            case .cursorUpdate:
                if handleCursorUpdate(in: window) {
                    // Prevent NSTitlebarContainerView / NSButton / NSHostingView cursorUpdate from overwriting pointingHand.
                    return nil
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
        // Never capture `self.window` (not even weakly) when `newWindow == nil`:
        // `NSWindow.dealloc` (e.g. closing SwiftUI sheets) tears down subviews with `_setWindow: nil`
        // after deallocation has started, where `objc_initWeak` aborts with SIGABRT.
        if newWindow == nil, isHovered {
            isHovered = false
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    Self.syncVisibleWindowUnderMouseOrResetCursor()
                }
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            if Self.isManagedCursorWindow(window) {
                window.acceptsMouseMovedEvents = true
            }
            Self.ensureLocalEventMonitor()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = bounds.size != newSize
        super.setFrameSize(newSize)
        if changed {
            reapplyCursorIfHovered()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isHidden, alphaValue > 0.01, !bounds.isEmpty else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hoverTrackingArea == nil || cursorTrackingArea == nil {
            if let hoverTrackingArea {
                removeTrackingArea(hoverTrackingArea)
            }
            if let cursorTrackingArea {
                removeTrackingArea(cursorTrackingArea)
            }
            // Per AppKit NSTrackingArea.h, .activeAlways cannot be paired with .cursorUpdate;
            // split hover tracking (.activeAlways) from active-app cursor updates (.cursorUpdate).
            // Because both use .inVisibleRect, AppKit updates their geometry automatically without
            // needing to remove and re-add them on every layout pass (which would otherwise trigger
            // _NSTrackingAreaAKManager.displayCycleUpdateStructuralRegions cursor resets).
            let hoverArea = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            let cursorArea = NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(hoverArea)
            addTrackingArea(cursorArea)
            self.hoverTrackingArea = hoverArea
            self.cursorTrackingArea = cursorArea
        }
        reapplyCursorIfHovered()
    }

    override func mouseMoved(with event: NSEvent) {
        reapplyCursorIfHovered()
    }

    func reapplyCursorIfHovered() {
        if let dragCursor = Self.activeDragCursor {
            dragCursor.set()
            return
        }
        guard let window, window.isVisible else { return }
        let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let nowHovered = Self.isPoint(ptInWindow, inside: self)
        let wasHovered = isHovered
        isHovered = nowHovered
        if nowHovered {
            Self.forcePointingHandCursor()
            RunLoop.main.perform(inModes: [.eventTracking, .common]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let win = self.window, win.isVisible else { return }
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
        if let dragCursor = Self.activeDragCursor {
            dragCursor.set()
            return
        }
        if let window, window.isVisible {
            let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            isHovered = Self.isPoint(ptInWindow, inside: self)
        } else {
            isHovered = false
        }
        if isHovered {
            Self.forcePointingHandCursor()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if let dragCursor = Self.activeDragCursor {
            dragCursor.set()
            return
        }
        guard let window, window.isVisible else { return }
        let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        isHovered = Self.isPoint(ptInWindow, inside: self)
        guard isHovered else { return }
        Self.forcePointingHandCursor()
        // Re-apply on the next tracking-loop turn in case NSMenu resets the cursor upon initial window entry.
        RunLoop.main.perform(inModes: [.eventTracking, .common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let win = self.window, win.isVisible else { return }
                let pt = win.convertPoint(fromScreen: NSEvent.mouseLocation)
                if Self.isPoint(pt, inside: self) {
                    Self.forcePointingHandCursor()
                }
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let window, window.isVisible {
            let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            if Self.isPoint(ptInWindow, inside: self) {
                return
            }
            isHovered = false
            Self.syncCursor(in: window)
        } else {
            isHovered = false
            Self.syncVisibleWindowUnderMouseOrResetCursor()
        }
    }
}

/// `NSHostingView` subclass for windows, popovers, and panels using `.pointerCursor()`.
/// Prevents AppKit `cursorUpdate(with:)` and SwiftUI `layout()` passes from
/// reverting the cursor to `.arrow` while hovering a `.pointerCursor()` control.
final class PointerCursorHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    static func shouldUsePointingHand(in window: NSWindow, atWindowPoint pt: NSPoint) -> Bool {
        guard let rootView = window.contentView?.superview ?? window.contentView,
              rootView.bounds.contains(pt) else {
            return false
        }
        return PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: pt)
    }

    override func cursorUpdate(with event: NSEvent) {
        if let window, PointerCursorNSView.handleCursorUpdate(in: window) {
            return
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

/// Base `NSPanel` for non-activating popovers and floating panels that intercepts
/// responder-chain `cursorUpdate(with:)` events (including from `.fullSizeContentView`
/// titlebar containers and visual-effect chrome views) before AppKit resets `.pointingHand` to `.arrow`.
class PointerCursorNSPanel: NSPanel {
    override func cursorUpdate(with event: NSEvent) {
        if PointerCursorNSView.handleCursorUpdate(in: self) {
            return
        }
        super.cursorUpdate(with: event)
    }
}

struct ToolboxPressFeedbackButtonStyle: ButtonStyle {
    var pressScale: CGFloat = 0.985
    var pressOpacity: Double = 0.88

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressScale : 1.0)
            .opacity(configuration.isPressed ? pressOpacity : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
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
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.75)
                )
                .menuRowHover(cornerRadius: 999)
            }
            .buttonStyle(ToolboxPressFeedbackButtonStyle())
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
                .foregroundStyle(ToolboxTheme.readableAccentText(for: color))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.24), lineWidth: 0.5)
        )
        .fixedSize(horizontal: true, vertical: false)
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
                    .foregroundStyle(Color.primary.opacity(0.84))
                    .lineLimit(1)
                    .frame(minWidth: 16, minHeight: 18)
                    .padding(.horizontal, token.count > 1 ? 4 : 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

struct FeatureSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.55)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
        .textSelection(.enabled)
    }
}

struct SectionCard<Content: View>: View {
    var accentTint: Color? = nil
    var borderOpacity: Double = 0.11
    let content: () -> Content

    init(
        accentTint: Color? = nil,
        borderOpacity: Double = 0.11,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.accentTint = accentTint
        self.borderOpacity = borderOpacity
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                        .fill(Color.primary.opacity(0.03))
                )
                .overlay {
                    if let accentTint {
                        RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                            .fill(
                                LinearGradient(
                                    colors: [accentTint.opacity(0.07), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
        )
        .overlay(
            RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                .strokeBorder(
                    accentTint?.opacity(0.26) ?? Color.primary.opacity(borderOpacity),
                    lineWidth: 1
                )
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
            FeatureSectionHeader(title: title, subtitle: subtitle)

            SectionCard {
                content()
            }
        }
    }
}

/// Airy section header paired directly with card-grid content (without an outer `SectionCard`).
struct FeatureCardGridSection<Content: View>: View {
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
        VStack(alignment: .leading, spacing: 10) {
            FeatureSectionHeader(title: title, subtitle: subtitle)
            content()
        }
    }
}

@MainActor
private final class SelectableOptionCardHoverState: ObservableObject {
    @Published var isHovered = false
}

/// Interactive Sponsor-style selectable card used for multi-option settings pickers.
struct SelectableOptionCard: View {
    let title: String
    let subtitle: String
    let symbolName: String
    let accentColor: Color
    var badge: String? = nil
    let isSelected: Bool
    var isCompact: Bool = false
    var isDisabled: Bool = false
    var isPulsing: Bool = false
    let action: () -> Void

    @StateObject private var hoverState = SelectableOptionCardHoverState()

    var body: some View {
        let radius: CGFloat = isCompact ? 10 : ToolboxTheme.cardCornerRadius
        let isHighlighted = !isDisabled && hoverState.isHovered
        let iconSize: CGFloat = isCompact ? 28 : 34
        let iconRadius: CGFloat = isCompact ? 8 : 9
        let readableAccent = ToolboxTheme.readableAccentText(for: accentColor)

        Button(action: action) {
            VStack(alignment: .leading, spacing: isCompact ? 8 : 10) {
                HStack(alignment: .center, spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: iconRadius)
                            .fill(accentColor.opacity(isSelected ? 0.22 : (isHighlighted ? 0.18 : 0.13)))
                            .frame(width: iconSize, height: iconSize)
                            .overlay(
                                RoundedRectangle(cornerRadius: iconRadius)
                                    .strokeBorder(accentColor.opacity(isSelected ? 0.32 : 0.18), lineWidth: 0.75)
                            )
                        Image(systemName: symbolName)
                            .font(.system(size: isCompact ? 12.5 : 14.5, weight: .semibold))
                            .foregroundStyle(isSelected || isHighlighted ? readableAccent : readableAccent.opacity(0.88))
                    }

                    Spacer(minLength: 4)

                    if let badge {
                        Text(badge)
                            .font(.system(size: isCompact ? 10 : 10.5, weight: .semibold))
                            .foregroundStyle(isSelected ? readableAccent : .secondary)
                            .padding(.horizontal, isCompact ? 6 : 8)
                            .padding(.vertical, 2.5)
                            .background(
                                isSelected ? accentColor.opacity(0.16) : Color.primary.opacity(0.06),
                                in: Capsule()
                            )
                            .lineLimit(1)
                    }

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: isCompact ? 13 : 15, weight: .semibold))
                            .foregroundStyle(readableAccent)
                    } else if !isCompact {
                        Circle()
                            .strokeBorder(
                                Color.primary.opacity(isHighlighted ? 0.34 : 0.22),
                                lineWidth: 1.25
                            )
                            .frame(width: 15, height: 15)
                    }
                }

                VStack(alignment: .leading, spacing: isCompact ? 2 : 4) {
                    Text(title)
                        .font(.system(size: isCompact ? 12.5 : 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(isCompact ? 1 : nil)

                    Text(subtitle)
                        .font(.system(size: isCompact ? 11 : 12))
                        .foregroundStyle(Color.primary.opacity(isSelected ? 0.80 : 0.66))
                        .lineSpacing(1.5)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(isCompact ? 12 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius)
                            .fill(
                                isSelected
                                    ? accentColor.opacity(isHighlighted ? 0.13 : 0.10)
                                    : Color.primary.opacity(isHighlighted ? 0.055 : 0.025)
                            )
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(
                        isPulsing
                            ? readableAccent.opacity(0.75)
                            : (isSelected
                                ? readableAccent.opacity(0.58)
                                : Color.primary.opacity(isHighlighted ? 0.22 : 0.10)),
                        lineWidth: (isSelected || isPulsing) ? 1.25 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: radius))
        }
        .buttonStyle(ToolboxPressFeedbackButtonStyle(pressScale: 0.985, pressOpacity: 0.92))
        .focusEffectDisabled()
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.62 : 1.0)
        .onHover { hoverState.isHovered = !isDisabled && $0 }
        .onChange(of: isDisabled) { _, disabled in
            if disabled { hoverState.isHovered = false }
        }
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .animation(.easeOut(duration: 0.14), value: isHighlighted)
        .pointerCursor(!isDisabled)
    }
}

/// Static informational card matching `SelectableOptionCard` aesthetics for multi-column tips/safety grids.
struct InfoFeatureCard<Footer: View>: View {
    let title: String
    let subtitle: String
    let symbolName: String
    let accentColor: Color
    let footer: () -> Footer

    init(
        title: String,
        subtitle: String,
        symbolName: String,
        accentColor: Color,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.accentColor = accentColor
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(accentColor.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: symbolName)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.70))
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            footer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                        .fill(Color.primary.opacity(0.025))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .textSelection(.enabled)
    }
}

extension InfoFeatureCard where Footer == EmptyView {
    init(
        title: String,
        subtitle: String,
        symbolName: String,
        accentColor: Color
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            symbolName: symbolName,
            accentColor: accentColor
        ) {
            EmptyView()
        }
    }
}

@MainActor
private final class SegmentedHoverState: ObservableObject {
    @Published var hoveredIndex: Int?
}

/// Crisp dark-mode pill segmented control with animated sliding indicator.
struct ToolboxSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    var accentColor: Color = ToolboxTheme.accentBlue
    var isFullWidth: Bool = false
    var isDisabled: Bool = false
    let label: (Option) -> String
    var symbol: ((Option) -> String?)? = nil
    var helpText: ((Option) -> String)? = nil

    @Namespace private var indicatorNamespace
    @StateObject private var hoverState = SegmentedHoverState()

    var body: some View {
        let readableAccent = ToolboxTheme.readableAccentText(for: accentColor)

        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { idx, option in
                let isSelected = selection == option
                let isHovered = !isDisabled && !isSelected && hoverState.hoveredIndex == idx
                let iconName = symbol?(option)

                Button {
                    guard !isDisabled, selection != option else { return }
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selection = option
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let iconName {
                            Image(systemName: iconName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isSelected ? readableAccent : (isHovered ? Color.primary.opacity(0.85) : .secondary))
                        }
                        Text(label(option))
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? Color.primary : (isHovered ? Color.primary.opacity(0.88) : Color.secondary))
                    .frame(maxWidth: isFullWidth ? .infinity : nil)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(accentColor.opacity(0.26))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(readableAccent.opacity(0.45), lineWidth: 0.75)
                                )
                                .matchedGeometryEffect(id: "toolboxSegmentedPill", in: indicatorNamespace)
                        } else if isHovered {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.06))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(ToolboxPressFeedbackButtonStyle(pressScale: 0.97, pressOpacity: 0.85))
                .focusEffectDisabled()
                .disabled(isDisabled)
                .onHover { hovering in
                    if hovering && !isDisabled {
                        hoverState.hoveredIndex = idx
                    } else if hoverState.hoveredIndex == idx {
                        hoverState.hoveredIndex = nil
                    }
                }
                .help(helpText?(option) ?? "")
                .pointerCursor(!isDisabled)
            }
        }
        .padding(2.5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
        )
        .opacity(isDisabled ? 0.52 : 1.0)
    }
}

@MainActor
private final class PresetChipHoverState: ObservableObject {
    @Published var isHovered = false
}

/// Reusable selectable preset pill chip calibrated for high legibility across all accent colors.
struct ToolboxPresetChip: View {
    let label: String
    let isSelected: Bool
    var accentColor: Color = ToolboxTheme.accentBlue
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var hoverState = PresetChipHoverState()

    var body: some View {
        let isHovered = isEnabled && hoverState.isHovered
        let readableAccent = ToolboxTheme.readableAccentText(for: accentColor)

        Button(action: action) {
            Text(label)
                .font(.caption.monospacedDigit().weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.86))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minWidth: 34, minHeight: 26)
                .background(
                    isSelected
                        ? accentColor.opacity(isHovered ? 0.30 : 0.24)
                        : Color.primary.opacity(isHovered ? 0.11 : 0.065),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? readableAccent.opacity(0.65)
                                : Color.primary.opacity(isHovered ? 0.22 : 0.10),
                            lineWidth: isSelected ? 1.0 : 0.75
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(ToolboxPressFeedbackButtonStyle(pressScale: 0.96, pressOpacity: 0.86))
        .focusEffectDisabled()
        .opacity(isEnabled ? 1.0 : 0.5)
        .onHover { hoverState.isHovered = isEnabled && $0 }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { hoverState.isHovered = false }
        }
        .pointerCursor(isEnabled)
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
        SettingRowLayout(spacing: 14, verticalSpacing: 10, minLabelWidth: 170) {
            labelBlock
            HStack(spacing: 8) {
                trailing()
            }
        }
    }

    private var labelBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.callout.weight(.semibold))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.primary.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }
}

private struct SettingRowLayout: Layout {
    var spacing: CGFloat = 14
    var verticalSpacing: CGFloat = 10
    var minLabelWidth: CGFloat = 170

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let label = subviews[0]
        let control = subviews[1]

        let controlSize = control.sizeThatFits(.unspecified)
        guard let totalWidth = proposal.width, totalWidth.isFinite else {
            let labelSize = label.sizeThatFits(.unspecified)
            return CGSize(
                width: labelSize.width + spacing + controlSize.width,
                height: max(labelSize.height, controlSize.height)
            )
        }

        let horizontalLabelWidth = totalWidth - controlSize.width - spacing
        if horizontalLabelWidth >= minLabelWidth && controlSize.width <= totalWidth * 0.56 {
            let labelSize = label.sizeThatFits(ProposedViewSize(width: horizontalLabelWidth, height: nil))
            return CGSize(width: totalWidth, height: max(labelSize.height, controlSize.height))
        } else {
            let labelSize = label.sizeThatFits(ProposedViewSize(width: totalWidth, height: nil))
            return CGSize(width: totalWidth, height: labelSize.height + verticalSpacing + controlSize.height)
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let label = subviews[0]
        let control = subviews[1]

        let controlSize = control.sizeThatFits(.unspecified)
        let horizontalLabelWidth = bounds.width - controlSize.width - spacing
        if horizontalLabelWidth >= minLabelWidth && controlSize.width <= bounds.width * 0.56 {
            let labelSize = label.sizeThatFits(ProposedViewSize(width: horizontalLabelWidth, height: nil))
            label.place(
                at: CGPoint(x: bounds.minX, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: horizontalLabelWidth, height: labelSize.height)
            )
            control.place(
                at: CGPoint(x: bounds.maxX, y: bounds.midY),
                anchor: .trailing,
                proposal: ProposedViewSize(width: controlSize.width, height: controlSize.height)
            )
        } else {
            let labelSize = label.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            label.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: labelSize.height)
            )
            let clampedControlWidth = min(controlSize.width, bounds.width)
            control.place(
                at: CGPoint(x: bounds.maxX, y: bounds.maxY),
                anchor: .bottomTrailing,
                proposal: ProposedViewSize(width: clampedControlWidth, height: controlSize.height)
            )
        }
    }
}

/// Equal-width responsive card grid that adapts column count directly from concrete container width.
struct ToolboxAdaptiveCardGrid: Layout {
    let wideColumns: Int
    let narrowColumns: Int
    let wideMinWidth: CGFloat
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = (proposal.width?.isFinite == true) ? (proposal.width ?? wideMinWidth) : wideMinWidth
        let cols = width >= wideMinWidth ? wideColumns : narrowColumns
        return measureGrid(width: width, columns: max(1, cols), subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let cols = max(1, bounds.width >= wideMinWidth ? wideColumns : narrowColumns)
        let measured = measureGrid(width: bounds.width, columns: cols, subviews: subviews)
        var y = bounds.minY
        for (rowIndex, rowHeight) in measured.rowHeights.enumerated() {
            for colIndex in 0..<cols {
                let idx = rowIndex * cols + colIndex
                guard idx < subviews.count else { break }
                let x = bounds.minX + CGFloat(colIndex) * (measured.colWidth + spacing)
                subviews[idx].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: measured.colWidth, height: rowHeight)
                )
            }
            y += rowHeight + spacing
        }
    }

    private func measureGrid(width: CGFloat, columns: Int, subviews: Subviews) -> (size: CGSize, colWidth: CGFloat, rowHeights: [CGFloat]) {
        let totalSpacing = spacing * CGFloat(max(0, columns - 1))
        let colWidth = max(40, (width - totalSpacing) / CGFloat(columns))
        var rowHeights: [CGFloat] = []
        var totalHeight: CGFloat = 0

        for start in stride(from: 0, to: subviews.count, by: columns) {
            let end = min(start + columns, subviews.count)
            var maxH: CGFloat = 0
            for idx in start..<end {
                let size = subviews[idx].sizeThatFits(ProposedViewSize(width: colWidth, height: nil))
                maxH = max(maxH, size.height)
            }
            rowHeights.append(maxH)
            totalHeight += maxH
        }
        if rowHeights.count > 1 {
            totalHeight += spacing * CGFloat(rowHeights.count - 1)
        }
        return (CGSize(width: width, height: totalHeight), colWidth, rowHeights)
    }
}

typealias ToolboxSwitchToggleStyle = StatusBarSwitchToggleStyle

/// High-contrast pill switch for status bar menus and settings rows where macOS renders
/// native `.switch` toggles in muted gray.
struct StatusBarSwitchToggleStyle: ToggleStyle {
    var onColor: Color = .green

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let trackColor = ToolboxTheme.switchTrackColor(for: onColor)

        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? trackColor : Color.primary.opacity(0.16))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                configuration.isOn ? trackColor.opacity(0.45) : Color.primary.opacity(0.24),
                                lineWidth: 1
                            )
                    )
                    .frame(width: 34, height: 19)

                Circle()
                    .fill(configuration.isOn ? Color.white : Color.white.opacity(0.86))
                    .overlay(
                        Circle()
                            .strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.32), radius: 1.5, x: 0, y: 0.5)
                    .frame(width: 15, height: 15)
                    .padding(2)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 3)
            .opacity(isEnabled ? 1.0 : 0.45)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.16), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// Semantic fills for `ToolboxProminentButtonStyle`, calibrated for consistent
/// white-on-color contrast independent of system Light/Dark Mode or Accent Color.
enum ToolboxProminentTone: CaseIterable, Equatable, Sendable {
    case accent
    case red
    case orange
    case green
    case purple
    case teal
    case pink
    case neutral

    var sRGBComponents: (r: Double, g: Double, b: Double) {
        switch self {
        case .accent:  return (0.13, 0.44, 0.92)
        case .red:     return (0.84, 0.20, 0.22)
        case .orange:  return (0.79, 0.40, 0.04)
        case .green:   return (0.12, 0.54, 0.25)
        case .purple:  return (0.56, 0.24, 0.84)
        case .teal:    return (0.07, 0.50, 0.46)
        case .pink:    return (0.80, 0.16, 0.40)
        case .neutral: return (0.34, 0.35, 0.38)
        }
    }

    var fillColor: Color {
        let c = sRGBComponents
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

/// Crisp dark-mode destructive button style so red destructive actions stay clearly visible.
struct ToolboxDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolboxDestructiveButtonBody(configuration: configuration)
    }
}

private struct ToolboxDestructiveButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @StateObject private var hoverState = ProminentButtonHoverState()

    private var metrics: (font: Font, hPad: CGFloat, vPad: CGFloat, radius: CGFloat) {
        switch controlSize {
        case .mini:
            return (.system(size: 11, weight: .semibold), 8, 2, 5)
        case .small:
            return (.caption.weight(.semibold), 10, 3.5, 6)
        case .regular:
            return (.callout.weight(.semibold), 12, 4.0, 7)
        case .large:
            return (.callout.weight(.semibold), 14, 6.5, 8)
        case .extraLarge:
            return (.callout.weight(.semibold), 16, 8, 9)
        @unknown default:
            return (.callout.weight(.semibold), 12, 4.0, 7)
        }
    }

    var body: some View {
        let m = metrics
        let shape = RoundedRectangle(cornerRadius: m.radius, style: .continuous)
        let isHovered = isEnabled && hoverState.isHovered
        let isPressed = isEnabled && configuration.isPressed
        let redText = ToolboxTheme.readableAccentText(for: .red)

        configuration.label
            .font(m.font)
            .foregroundStyle(isEnabled ? redText : redText.opacity(0.45))
            .tint(redText)
            .padding(.horizontal, m.hPad)
            .padding(.vertical, m.vPad)
            .background {
                shape.fill(Color.red.opacity(isEnabled ? (isPressed ? 0.28 : (isHovered ? 0.22 : 0.14)) : 0.06))
            }
            .overlay(
                shape.strokeBorder(
                    Color.red.opacity(isEnabled ? (isHovered ? 0.50 : 0.34) : 0.14),
                    lineWidth: 0.75
                )
            )
            .contentShape(shape)
            .onHover { hoverState.isHovered = isEnabled && $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { hoverState.isHovered = false }
            }
    }
}

extension ButtonStyle where Self == ToolboxDestructiveButtonStyle {
    static var toolboxDestructive: ToolboxDestructiveButtonStyle {
        ToolboxDestructiveButtonStyle()
    }
}

private final class ProminentButtonHoverState: ObservableObject {
    @Published var isHovered = false
}

/// Consistent prominent button style with crisp white text/icons across active,
/// inactive, Light Mode, Dark Mode, and non-activating popover surfaces.
struct ToolboxProminentButtonStyle: ButtonStyle {
    var tone: ToolboxProminentTone = .accent

    func makeBody(configuration: Configuration) -> some View {
        ToolboxProminentButtonBody(configuration: configuration, tone: tone)
    }
}

private struct ToolboxProminentButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tone: ToolboxProminentTone

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @StateObject private var hoverState = ProminentButtonHoverState()

    private var metrics: (font: Font, hPad: CGFloat, vPad: CGFloat, radius: CGFloat) {
        switch controlSize {
        case .mini:
            return (.system(size: 11, weight: .semibold), 8, 2, 5)
        case .small:
            return (.caption.weight(.semibold), 10, 3.5, 6)
        case .regular:
            return (.callout.weight(.semibold), 12, 4.0, 7)
        case .large:
            return (.callout.weight(.semibold), 14, 6.5, 8)
        case .extraLarge:
            return (.callout.weight(.semibold), 16, 8, 9)
        @unknown default:
            return (.callout.weight(.semibold), 12, 4.0, 7)
        }
    }

    var body: some View {
        let m = metrics
        let shape = RoundedRectangle(cornerRadius: m.radius, style: .continuous)
        let isHovered = isEnabled && hoverState.isHovered
        let isPressed = isEnabled && configuration.isPressed

        configuration.label
            .font(m.font)
            .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.45))
            .tint(.white)
            .padding(.horizontal, m.hPad)
            .padding(.vertical, m.vPad)
            .background {
                ZStack {
                    shape.fill(isEnabled ? tone.fillColor : tone.fillColor.opacity(0.32))
                    if isEnabled {
                        shape.fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.11), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                    if isPressed {
                        shape.fill(Color.black.opacity(0.16))
                    } else if isHovered {
                        shape.fill(Color.white.opacity(0.08))
                    }
                }
            }
            .overlay(
                shape.strokeBorder(
                    Color.white.opacity(!isEnabled ? 0.08 : (isHovered ? 0.24 : 0.16)),
                    lineWidth: 0.75
                )
            )
            .contentShape(shape)
            .onHover { hoverState.isHovered = isEnabled && $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    hoverState.isHovered = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toolboxMenuBarPopoverDidClose)) { _ in
                hoverState.isHovered = false
            }
    }
}

extension ButtonStyle where Self == ToolboxProminentButtonStyle {
    static var toolboxProminent: ToolboxProminentButtonStyle {
        ToolboxProminentButtonStyle(tone: .accent)
    }

    static func toolboxProminent(_ tone: ToolboxProminentTone) -> ToolboxProminentButtonStyle {
        ToolboxProminentButtonStyle(tone: tone)
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

extension NSWindow {
    /// Finds the first visible editable text field in `contentView`.
    @MainActor
    func firstEditableTextField() -> NSTextField? {
        Self.findEditableTextField(in: contentView)
    }

    /// Lays out the content view and moves first-responder focus into its first editable text field.
    @MainActor
    @discardableResult
    func focusFirstEditableTextField() -> NSTextField? {
        contentView?.layoutSubtreeIfNeeded()
        guard let field = firstEditableTextField() else { return nil }
        makeFirstResponder(field)
        return field
    }

    @MainActor
    private static func findEditableTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let textField = view as? NSTextField,
           textField.isEditable,
           !textField.isHidden {
            return textField
        }
        for subview in view.subviews {
            if let match = findEditableTextField(in: subview) {
                return match
            }
        }
        return nil
    }
}
