import AppKit
import SwiftUI

@MainActor
final class CleanLockHUDState: ObservableObject {
    @Published var remainingSeconds: Int = 60
    @Published var remainingInterval: TimeInterval = 60
    @Published var totalSeconds: Int = 60
    @Published var lockMouseAndTrackpad: Bool = true
    @Published var blockedCount: Int = 0
    @Published var killSwitchProgress: Double = 0.0

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1.0, max(0.0, remainingInterval / Double(totalSeconds)))
    }
}

/// Non-activating, click-through center-screen countdown HUD shown while Clean Lock is active.
@MainActor
final class CleanLockHUDPanel {
    private var panel: NSPanel?
    let state = CleanLockHUDState()

    func show(totalSeconds: Int, remainingSeconds: Int, lockMouseAndTrackpad: Bool) {
        state.totalSeconds = max(1, totalSeconds)
        state.remainingSeconds = max(0, remainingSeconds)
        state.remainingInterval = TimeInterval(max(0, remainingSeconds))
        state.lockMouseAndTrackpad = lockMouseAndTrackpad
        state.blockedCount = 0
        state.killSwitchProgress = 0.0

        let cardSize = NSSize(width: 320, height: 340)
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.midX - cardSize.width / 2,
            y: screenFrame.midY - cardSize.height / 2
        )
        let frame = NSRect(origin: origin, size: cardSize)

        if let existing = panel {
            existing.setFrame(frame, display: true)
            existing.orderFrontRegardless()
            return
        }

        let newPanel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .screenSaver
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.ignoresMouseEvents = true
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        newPanel.contentView = NSHostingView(rootView: CleanLockHUDCardView(state: state))
        newPanel.orderFrontRegardless()
        self.panel = newPanel
    }

    func update(
        remainingSeconds: Int,
        remainingInterval: TimeInterval,
        blockedCount: Int,
        killSwitchProgress: Double
    ) {
        state.remainingSeconds = max(0, remainingSeconds)
        state.remainingInterval = max(0, remainingInterval)
        state.blockedCount = max(0, blockedCount)
        state.killSwitchProgress = min(1.0, max(0.0, killSwitchProgress))
    }

    func close() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

struct CleanLockHUDCardView: View {
    @ObservedObject var state: CleanLockHUDState

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 10)
                    .frame(width: 148, height: 148)

                Circle()
                    .trim(from: 0, to: state.progress)
                    .stroke(
                        Color.red,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 148, height: 148)
                    .animation(.linear(duration: 0.12), value: state.progress)

                VStack(spacing: 2) {
                    Text("\(state.remainingSeconds)")
                        .font(.system(size: 66, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                    Text("sec")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
            }
            .padding(.top, 4)

            VStack(spacing: 4) {
                Text("Keyboard Lock Active")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(state.lockMouseAndTrackpad ? "Keyboard & Trackpad Locked" : "Keyboard Locked")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "hand.raised.slash.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                Text("\(state.blockedCount) \(state.blockedCount == 1 ? "input" : "inputs") blocked")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())

            VStack(spacing: 6) {
                Text("Hold ⌃ ⌥ ⌘ Esc (3s) to unlock early")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(state.killSwitchProgress > 0 ? .red : .secondary)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.12))
                        Capsule()
                            .fill(Color.red)
                            .frame(width: geo.size.width * state.killSwitchProgress)
                            .animation(.linear(duration: 0.06), value: state.killSwitchProgress)
                    }
                }
                .frame(width: 210, height: 6)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 320, height: 340)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }
}
