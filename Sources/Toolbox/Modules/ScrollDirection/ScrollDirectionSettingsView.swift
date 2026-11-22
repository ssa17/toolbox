import AppKit
import SwiftUI

@MainActor
private final class ScrollPreviewState: ObservableObject {
    @Published var offset: CGFloat = 0
    @Published var lastDevice: ScrollTarget?
    @Published var pulsingDevice: ScrollTarget?
    @Published var lastDirectionUp: Bool?
    @Published var eventCount: Int = 0
    @Published var isPadHovered = false

    private var pulseClearTask: Task<Void, Never>?

    func recordScroll(deltaY: CGFloat, isContinuous: Bool) {
        let step = isContinuous ? deltaY : deltaY * 14
        offset += step
        // Wrap offset cleanly over a 6-row period (6 * 32 = 192 pt) for endless preview scrolling.
        offset = offset.truncatingRemainder(dividingBy: 192)
        let device: ScrollTarget = isContinuous ? .trackpad : .mouse
        lastDevice = device
        pulsingDevice = device
        if abs(deltaY) > 0.001 {
            lastDirectionUp = deltaY < 0
        }
        eventCount += 1

        pulseClearTask?.cancel()
        pulseClearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.pulsingDevice = nil
        }
    }

    func reset() {
        pulseClearTask?.cancel()
        pulseClearTask = nil
        offset = 0
        lastDevice = nil
        pulsingDevice = nil
        lastDirectionUp = nil
        eventCount = 0
    }
}

struct ScrollDirectionSettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject var module: ScrollDirectionModule
    @StateObject private var previewState = ScrollPreviewState()

    private var isEnabled: Bool {
        configManager.config.scrollDirection.enabled
    }

    private var target: ScrollTarget {
        configManager.config.scrollDirection.target
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            FeatureCardGridSection(
                "Device to Invert",
                subtitle: "macOS uses one scroll direction for every pointing device. Pick which one to flip relative to System Settings."
            ) {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        SelectableOptionCard(
                            title: "Mouse Wheel",
                            subtitle: "Flips classic line-based mouse wheels while your trackpad keeps macOS System Settings direction.",
                            symbolName: "computermouse",
                            accentColor: module.accentColor,
                            badge: target == .mouse ? (isEnabled ? "Inverted" : "Will Invert") : "macOS Default",
                            isSelected: target == .mouse,
                            isPulsing: previewState.pulsingDevice == .mouse
                        ) {
                            configManager.config.scrollDirection.target = .mouse
                        }

                        SelectableOptionCard(
                            title: "Trackpad",
                            subtitle: "Flips pixel-based touch gestures and high-resolution mice like the Magic Mouse.",
                            symbolName: "rectangle.and.hand.point.up.left",
                            accentColor: module.accentColor,
                            badge: target == .trackpad ? (isEnabled ? "Inverted" : "Will Invert") : "macOS Default",
                            isSelected: target == .trackpad,
                            isPulsing: previewState.pulsingDevice == .trackpad
                        ) {
                            configManager.config.scrollDirection.target = .trackpad
                        }
                    }
                }
            }

            FeatureSection(
                "Interactive Scroll Test",
                subtitle: "Hover and scroll with your mouse or trackpad to verify which device class macOS reports."
            ) {
                interactiveScrollPad

                Divider()

                HStack(spacing: 10) {
                    Text(statsSubtitle)
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    if let observed = module.lastObservedClass {
                        let isMatched = observed == target
                        StatusBadge(
                            text: observed.label,
                            color: isMatched ? .green : .secondary
                        )
                    }

                    if isEnabled {
                        Text("Inverted: \(module.eventsInverted)")
                            .toolboxFont(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
            }

            FeatureSection("Shortcut") {
                SettingRow(
                    "Toggle shortcut",
                    subtitle: "Optional global shortcut to turn scroll inversion on or off."
                ) {
                    ShortcutRecorderView(
                        shortcut: configManager.config.scrollDirection.shortcut,
                        defaultShortcut: ShortcutSpec.none,
                        sourceID: "scroll_direction",
                        registrationKey: module.hotKeyName
                    ) { newShortcut in
                        configManager.config.scrollDirection.shortcut = newShortcut
                    }
                }
            }
        }
    }

    private var interactiveScrollPad: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    padTitleLabel
                    Spacer(minLength: 8)
                    padStatusControls
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        padTitleLabel
                        Spacer(minLength: 8)
                        if previewState.eventCount > 0 {
                            resetPadButton
                        }
                    }
                    padStatusLabel
                }
            }

            RoundedRectangle(cornerRadius: 9)
                .fill(Color.primary.opacity(0.04))
                .frame(height: 112)
                .overlay(alignment: .top) {
                    // Endless tiled preview rows driven directly by scroll events on the pad.
                    // Each row is 32 pt tall; starting at idx -6 places Sample Line 1 flush at top when offset == 0.
                    VStack(spacing: 0) {
                        ForEach(-6..<12, id: \.self) { idx in
                            let rowNumber = ((idx % 6) + 6) % 6 + 1
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(rowNumber % 2 == 0 ? Color.pink.opacity(0.55) : Color.accentColor.opacity(0.45))
                                    .frame(width: 4, height: 14)
                                Text("Sample Line \(rowNumber)")
                                    .toolboxFont(.caption.monospaced())
                                    .foregroundStyle(.primary.opacity(0.82))
                                Spacer()
                                Text(rowNumber == 1 ? "Top of list" : (rowNumber == 6 ? "End of section" : "Scroll to test direction"))
                                    .toolboxFont(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .overlay(alignment: .bottom) {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                    .offset(y: previewState.offset - 192)
                    .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay {
                    ScrollWheelCaptureRepresentable { deltaY, isContinuous in
                        previewState.recordScroll(deltaY: deltaY, isContinuous: isContinuous)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(
                            previewState.isPadHovered ? module.accentColor.opacity(0.45) : Color.primary.opacity(0.11),
                            lineWidth: previewState.isPadHovered ? 1.25 : 1
                        )
                        .allowsHitTesting(false)
                )
                .onHover { previewState.isPadHovered = $0 }
        }
    }

    private var padTitleLabel: some View {
        Label("Interactive Scroll Test Pad", systemImage: "hand.draw")
            .toolboxFont(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var padStatusControls: some View {
        HStack(spacing: 8) {
            padStatusLabel
            if previewState.eventCount > 0 {
                resetPadButton
            }
        }
    }

    @ViewBuilder
    private var padStatusLabel: some View {
        if let last = previewState.lastDevice {
            let matchingTarget = isEnabled && module.isTapInstalled && last == target
            let movingUp = previewState.lastDirectionUp ?? true
            HStack(spacing: 4) {
                Text("Detected: \(last.label) (\(last == .mouse ? "Line" : "Pixel")) ·")
                Image(systemName: movingUp ? "arrow.up" : "arrow.down")
                    .toolboxFont(.caption2.weight(.semibold))
                Text(movingUp ? "Moving Up" : "Moving Down")
            }
            .toolboxFont(.caption2)
            .foregroundStyle(matchingTarget ? ToolboxTheme.readableAccentText(for: .pink) : .secondary)
            .lineLimit(1)
        } else {
            Text("Hover here and scroll with mouse or trackpad")
                .toolboxFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var resetPadButton: some View {
        Button("Reset") {
            previewState.reset()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .pointerCursor()
    }

    private var statsSubtitle: String {
        if !isEnabled {
            if !permissions.isAccessibilityGranted {
                return "Grant Accessibility permission and turn inversion on to invert \(target.label.lowercased()) scrolling."
            }
            return "Turn inversion on, then scroll with your \(target.label.lowercased()) to confirm."
        }
        guard let observed = module.lastObservedClass else {
            return "Waiting for the first scroll event from your mouse or trackpad."
        }
        if observed == target {
            return "Inverting \(observed.label.lowercased()) scroll events as intended."
        }
        return "Receiving \(observed.label.lowercased()) style events right now (\(module.eventsInverted) inverted). Switch the target above if your device reports as \(observed.label)."
    }
}

private struct ScrollWheelCaptureRepresentable: NSViewRepresentable {
    let onScroll: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> ScrollWheelCaptureView {
        let view = ScrollWheelCaptureView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelCaptureView, context: Context) {
        nsView.onScroll = onScroll
    }
}

private final class ScrollWheelCaptureView: NSView {
    var onScroll: ((CGFloat, Bool) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
    }
}
