import AppKit
import Carbon
import SwiftUI

@MainActor
private final class ShortcutRecorderCoordinator: ObservableObject {
    static let shared = ShortcutRecorderCoordinator()

    @Published private(set) var activeRecorderID: String?
    @Published private(set) var heldModifiers: [KeyModifier] = []
    @Published private(set) var bareKeyHint: String?

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var windowResignObserver: NSObjectProtocol?
    private var windowCloseObserver: NSObjectProtocol?
    private var bareKeyHintTask: Task<Void, Never>?

    func beginRecording(
        id: String,
        anchorButtonFrameInWindow: @escaping () -> CGRect?,
        onCapture: @escaping (ShortcutSpec) -> Void
    ) {
        stopRecording()

        activeRecorderID = id
        heldModifiers = KeyModifier.from(eventFlags: NSEvent.modifierFlags)
        bareKeyHint = nil
        HotKeyManager.shared.setSuspendedForRecording(true)

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopRecording()
            }
        }

        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopRecording()
            }
        }

        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopRecording()
            }
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.activeRecorderID == id else { return event }
            if event.type != .otherMouseDown,
               let buttonFrame = anchorButtonFrameInWindow(),
               buttonFrame.contains(event.locationInWindow) {
                return event
            }
            self.stopRecording()
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.activeRecorderID == id else { return event }

            if event.type == .flagsChanged {
                self.heldModifiers = KeyModifier.from(eventFlags: event.modifierFlags)
                return event
            }

            let mods = KeyModifier.from(eventFlags: event.modifierFlags)

            // Escape with no modifiers cancels recording without changing shortcut.
            if event.keyCode == UInt16(kVK_Escape) && mods.isEmpty {
                self.stopRecording()
                return nil
            }

            // Delete / Forward Delete with no modifiers clears the shortcut.
            if (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) && mods.isEmpty {
                self.stopRecording()
                onCapture(.none)
                return nil
            }

            guard let keyName = ShortcutSpec.keyName(for: event.keyCode) else {
                NSSound.beep()
                return nil
            }

            let captured = ShortcutSpec(key: keyName, modifiers: mods)
            guard !mods.isEmpty || captured.isFunctionKey else {
                NSSound.beep()
                self.showBareKeyHint()
                return nil
            }

            self.stopRecording()
            onCapture(captured)
            return nil
        }
    }

    private func showBareKeyHint() {
        bareKeyHintTask?.cancel()
        bareKeyHint = "Add ⌘, ⌥, ⌃, or ⇧ (or use F1–F20)"
        bareKeyHintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.bareKeyHint = nil
        }
    }

    func stopRecording(ifID matchesID: String? = nil) {
        if let matchesID, activeRecorderID != matchesID {
            return
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        bareKeyHintTask?.cancel()
        bareKeyHintTask = nil
        bareKeyHint = nil
        activeRecorderID = nil
        heldModifiers = []
        HotKeyManager.shared.setSuspendedForRecording(false)
    }
}

private struct RecorderWindowFrameReader: NSViewRepresentable {
    let onAttach: (FrameTrackingNSView) -> Void

    func makeNSView(context: Context) -> FrameTrackingNSView {
        let view = FrameTrackingNSView()
        onAttach(view)
        return view
    }

    func updateNSView(_ nsView: FrameTrackingNSView, context: Context) {
        onAttach(nsView)
    }

    final class FrameTrackingNSView: NSView {
        func liveFrameInWindow() -> CGRect? {
            guard window != nil else { return nil }
            return convert(bounds, to: nil)
        }
    }
}

@MainActor
private final class RecorderInstanceBox: ObservableObject {
    let id = UUID().uuidString
    weak var trackingView: RecorderWindowFrameReader.FrameTrackingNSView?
}

@MainActor
private enum ShortcutConflictResolver {
    enum Issue {
        case inApp(String)
        case registrationError(String)
        case systemOrMenu(String)

        var message: String {
            switch self {
            case .inApp(let msg), .registrationError(let msg), .systemOrMenu(let msg):
                return msg
            }
        }

        var isInApp: Bool {
            if case .inApp = self { return true }
            return false
        }
    }

    static func resolve(
        shortcut: ShortcutSpec,
        sourceID: String?,
        registrationKey: String?,
        config: ToolboxConfig,
        hotKeyManager: HotKeyManager
    ) -> Issue? {
        guard !shortcut.isEmpty else { return nil }
        if let conflict = hotKeyManager.inAppConflictDescription(
            for: shortcut,
            excludingSourceID: sourceID,
            in: config
        ) {
            return .inApp(conflict)
        }
        if let registrationKey, let err = hotKeyManager.registrationErrors[registrationKey] {
            return .registrationError(err)
        }
        if let sysConflict = hotKeyManager.systemOrMenuConflictDescription(for: shortcut) {
            return .systemOrMenu(sysConflict)
        }
        return nil
    }
}

struct ShortcutConflictStatusView: View {
    let shortcut: ShortcutSpec
    var sourceID: String? = nil
    var registrationKey: String? = nil
    var onAssignHere: (() -> Void)? = nil

    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var hotKeyManager = HotKeyManager.shared

    var body: some View {
        if let issue = ShortcutConflictResolver.resolve(
            shortcut: shortcut,
            sourceID: sourceID,
            registrationKey: registrationKey,
            config: configManager.config,
            hotKeyManager: hotKeyManager
        ) {
            HStack(alignment: .center, spacing: 8) {
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                    .fixedSize(horizontal: false, vertical: true)

                if issue.isInApp {
                    Button("Assign Here") {
                        hotKeyManager.clearConflictingShortcuts(
                            matching: shortcut,
                            excludingSourceID: sourceID,
                            in: &configManager.config
                        )
                        onAssignHere?()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.orange.opacity(0.26), lineWidth: 0.75)
            )
        }
    }
}

struct ShortcutRecorderView: View {
    let shortcut: ShortcutSpec
    var defaultShortcut: ShortcutSpec? = nil
    var sourceID: String? = nil
    var registrationKey: String? = nil
    var showConflictWarnings: Bool = true
    let onChange: (ShortcutSpec) -> Void

    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var hotKeyManager = HotKeyManager.shared
    @ObservedObject private var coordinator = ShortcutRecorderCoordinator.shared
    @StateObject private var instance = RecorderInstanceBox()

    private var isRecording: Bool {
        coordinator.activeRecorderID == instance.id
    }

    private var activeIssue: ShortcutConflictResolver.Issue? {
        guard showConflictWarnings else { return nil }
        return ShortcutConflictResolver.resolve(
            shortcut: shortcut,
            sourceID: sourceID,
            registrationKey: registrationKey,
            config: configManager.config,
            hotKeyManager: hotKeyManager
        )
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 5) {
                Button {
                    if isRecording {
                        coordinator.stopRecording(ifID: instance.id)
                    } else {
                        let trackingView = instance.trackingView
                        coordinator.beginRecording(
                            id: instance.id,
                            anchorButtonFrameInWindow: { [weak trackingView] in
                                trackingView?.liveFrameInWindow()
                            },
                            onCapture: onChange
                        )
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isRecording {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                            if coordinator.heldModifiers.isEmpty {
                                Text("Press shortcut…")
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                            } else {
                                ShortcutPill(tokens: coordinator.heldModifiers.map(\.symbol) + ["…"])
                            }
                        } else if !shortcut.isEmpty {
                            ShortcutPill(shortcut: shortcut)
                        } else {
                            Image(systemName: "plus.circle")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text("Record Shortcut")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        isRecording
                            ? Color.accentColor.opacity(0.16)
                            : (activeIssue != nil ? Color.orange.opacity(0.10) : Color.primary.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(
                                isRecording
                                    ? Color.accentColor
                                    : (activeIssue != nil ? Color.orange.opacity(0.6) : Color.primary.opacity(0.14)),
                                lineWidth: 1
                            )
                    )
                    .menuRowHover(cornerRadius: 7, fillOpacity: isRecording ? 0 : 0.05, borderOpacity: isRecording ? 0 : 0.14)
                    .background(
                        RecorderWindowFrameReader { view in
                            instance.trackingView = view
                        }
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(isRecording ? "Press keys (⌫ to clear, Esc to cancel)" : "Click and press a shortcut")
                .pointerCursor()

                if let defaultShortcut, !defaultShortcut.isEmpty, shortcut != defaultShortcut {
                    Button {
                        coordinator.stopRecording(ifID: instance.id)
                        onChange(defaultShortcut)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                            )
                            .menuRowHover(cornerRadius: 7)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .accessibilityLabel("Reset shortcut to default")
                    .help("Reset to default (\(defaultShortcut.displayString))")
                    .pointerCursor()
                }

                if !shortcut.isEmpty {
                    Button {
                        coordinator.stopRecording(ifID: instance.id)
                        onChange(.none)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                            )
                            .menuRowHover(cornerRadius: 7)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .accessibilityLabel("Clear shortcut")
                    .help("Clear shortcut")
                    .pointerCursor()
                }
            }

            if isRecording {
                Text(coordinator.bareKeyHint ?? "⌫ clear · Esc cancel")
                    .font(.caption2)
                    .foregroundStyle(coordinator.bareKeyHint != nil ? ToolboxTheme.readableAccentText(for: .orange) : .secondary)
            }

            if showConflictWarnings {
                ShortcutConflictStatusView(
                    shortcut: shortcut,
                    sourceID: sourceID,
                    registrationKey: registrationKey,
                    onAssignHere: { onChange(shortcut) }
                )
            }
        }
        .onDisappear {
            coordinator.stopRecording(ifID: instance.id)
        }
    }
}
