import AppKit
import SwiftUI

@MainActor
private final class ShortcutRecorderState: ObservableObject {
    @Published var isRecording = false
    @Published var showBuilderPopover = false
    @Published var heldModifiers: [KeyModifier] = []
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    func beginRecording(onCapture: @escaping (ShortcutSpec) -> Void) {
        stopRecording()
        showBuilderPopover = false
        isRecording = true
        heldModifiers = KeyModifier.from(eventFlags: NSEvent.modifierFlags)

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.stopRecording()
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }

            if event.type == .flagsChanged {
                self.heldModifiers = KeyModifier.from(eventFlags: event.modifierFlags)
                return event
            }

            // Escape cancels recording without changing shortcut
            if event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                self.stopRecording()
                return nil
            }

            let mods = KeyModifier.from(eventFlags: event.modifierFlags)
            guard !mods.isEmpty else {
                NSSound.beep()
                return nil
            }

            guard let keyName = ShortcutSpec.keyName(for: event.keyCode) else {
                NSSound.beep()
                return nil
            }

            let captured = ShortcutSpec(key: keyName, modifiers: mods)
            self.stopRecording()
            onCapture(captured)
            return nil
        }
    }

    func stopRecording() {
        isRecording = false
        heldModifiers = []
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }
}

struct ShortcutRecorderView: View {
    let shortcut: ShortcutSpec
    let onChange: (ShortcutSpec) -> Void

    @StateObject private var state = ShortcutRecorderState()

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if state.isRecording {
                    state.stopRecording()
                } else {
                    state.beginRecording(onCapture: onChange)
                }
            } label: {
                HStack(spacing: 5) {
                    if state.isRecording {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                        if state.heldModifiers.isEmpty {
                            Text("Press keys…")
                                .font(.caption.weight(.medium))
                        } else {
                            Text(state.heldModifiers.map(\.symbol).joined(separator: " ") + " + key…")
                                .font(.caption.monospaced().weight(.medium))
                        }
                    } else {
                        ShortcutPill(shortcut: shortcut)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    state.isRecording ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            state.isRecording ? Color.accentColor : Color.primary.opacity(0.14),
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.plain)
            .help("Click and press a shortcut (Esc to cancel)")
            .pointerCursor()

            Button {
                state.stopRecording()
                state.showBuilderPopover.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 26)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Pick modifiers and key from list")
            .pointerCursor()
            .popover(isPresented: $state.showBuilderPopover, arrowEdge: .bottom) {
                ShortcutBuilderPopover(shortcut: shortcut, onChange: onChange) {
                    state.showBuilderPopover = false
                }
            }
        }
        .onDisappear {
            state.stopRecording()
        }
    }
}

private struct ShortcutBuilderPopover: View {
    let shortcut: ShortcutSpec
    let onChange: (ShortcutSpec) -> Void
    let onClose: () -> Void

    private let orderedModifiers: [(mod: KeyModifier, title: String)] = [
        (.control, "⌃ Ctrl"),
        (.option, "⌥ Opt"),
        (.shift, "⇧ Shift"),
        (.command, "⌘ Cmd")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Shortcut")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Modifiers")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    ForEach(orderedModifiers, id: \.mod) { item in
                        let isSelected = shortcut.modifiers.contains(item.mod)
                        Button {
                            var nextMods = shortcut.modifiers
                            if isSelected {
                                if nextMods.count > 1 {
                                    nextMods.removeAll { $0 == item.mod }
                                }
                            } else {
                                nextMods.append(item.mod)
                            }
                            onChange(ShortcutSpec(key: shortcut.key, modifiers: nextMods))
                        } label: {
                            Text(item.title)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(
                                            isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                            lineWidth: 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }

            HStack {
                Text("Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { shortcut.key.lowercased() },
                    set: { newKey in
                        onChange(ShortcutSpec(key: newKey, modifiers: shortcut.modifiers))
                    }
                )) {
                    ForEach(ShortcutSpec.selectableKeys, id: \.self) { key in
                        Text(key.uppercased()).tag(key)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                .pointerCursor()
            }

            Divider()

            HStack {
                ShortcutPill(shortcut: shortcut)
                Spacer()
                Button("Done") {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointerCursor()
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}
