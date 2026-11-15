import AppKit
import Carbon
import SwiftUI

@MainActor
private final class ShortcutRecorderCoordinator: ObservableObject {
    static let shared = ShortcutRecorderCoordinator()

    @Published private(set) var activeRecorderID: String?
    @Published private(set) var heldModifiers: [KeyModifier] = []

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    func beginRecording(
        id: String,
        anchorButtonFrameInWindow: @escaping () -> CGRect?,
        onCapture: @escaping (ShortcutSpec) -> Void
    ) {
        stopRecording()

        activeRecorderID = id
        heldModifiers = KeyModifier.from(eventFlags: NSEvent.modifierFlags)
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

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.activeRecorderID == id else { return event }
            if let buttonFrame = anchorButtonFrameInWindow(),
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
                return nil
            }

            self.stopRecording()
            onCapture(captured)
            return nil
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
        activeRecorderID = nil
        heldModifiers = []
        HotKeyManager.shared.setSuspendedForRecording(false)
    }
}

private struct RecorderWindowFrameReader: NSViewRepresentable {
    let onUpdate: (CGRect?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = FrameTrackingNSView()
        view.onUpdate = onUpdate
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let tracking = nsView as? FrameTrackingNSView {
            tracking.onUpdate = onUpdate
            tracking.reportFrame()
        }
    }

    private final class FrameTrackingNSView: NSView {
        var onUpdate: ((CGRect?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportFrame()
        }

        override func layout() {
            super.layout()
            reportFrame()
        }

        func reportFrame() {
            guard window != nil else {
                onUpdate?(nil)
                return
            }
            onUpdate?(convert(bounds, to: nil))
        }
    }
}

@MainActor
private final class RecorderInstanceBox: ObservableObject {
    let id = UUID().uuidString
    var buttonFrameInWindow: CGRect?
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
            HStack(spacing: 8) {
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)

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
                    .controlSize(.mini)
                    .pointerCursor()
                }
            }
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
                        coordinator.beginRecording(
                            id: instance.id,
                            anchorButtonFrameInWindow: { instance.buttonFrameInWindow },
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
                                Text("Type shortcut… (⌫ clear, Esc cancel)")
                                    .font(.caption.weight(.medium))
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
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
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
                    .background(
                        RecorderWindowFrameReader { frame in
                            instance.buttonFrameInWindow = frame
                        }
                    )
                }
                .buttonStyle(.plain)
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
                            .frame(width: 24, height: 26)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
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
                            .frame(width: 24, height: 26)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Clear shortcut")
                    .pointerCursor()
                }
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
