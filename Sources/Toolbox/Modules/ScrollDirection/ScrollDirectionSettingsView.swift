import AppKit
import SwiftUI

@MainActor
private final class ScrollPreviewState: ObservableObject {
    @Published var offset: CGFloat = 0
    @Published var lastDevice: ScrollTarget?
    @Published var lastDeltaY: CGFloat = 0
    @Published var eventCount: Int = 0

    func recordScroll(deltaY: CGFloat, isContinuous: Bool) {
        let step = isContinuous ? deltaY : deltaY * 14
        offset += step
        // Wrap offset cleanly over a 6-row period (6 * 32 = 192 pt) for endless preview scrolling.
        offset = offset.truncatingRemainder(dividingBy: 192)
        lastDevice = isContinuous ? .trackpad : .mouse
        lastDeltaY = deltaY
        eventCount += 1
    }

    func reset() {
        offset = 0
        lastDevice = nil
        lastDeltaY = 0
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
            FeatureSection("Inversion", subtitle: "macOS uses one scroll direction for every pointing device. This inverts one of them, relative to the other.") {
                SettingRow(
                    "Which device to invert",
                    subtitle: "Mouse wheels report line based scroll events; the trackpad reports pixel based ones. That is how the two are told apart."
                ) {
                    Picker("", selection: $configManager.config.scrollDirection.target) {
                        ForEach(ScrollTarget.allCases, id: \.self) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    .disabled(!isEnabled)
                    .pointerCursor(isEnabled)
                }
            }

            FeatureSection("Preview", subtitle: "Compare device behavior and test your mouse or trackpad right here.") {
                HStack(spacing: 12) {
                    devicePreviewTile(
                        device: .mouse,
                        symbol: "computermouse",
                        kindLabel: "Line-based wheel"
                    )
                    devicePreviewTile(
                        device: .trackpad,
                        symbol: "rectangle.and.hand.point.up.left",
                        kindLabel: "Pixel-based touch"
                    )
                }

                interactiveScrollPad
            }

            FeatureSection("Live Status", subtitle: "What the inverter has seen across macOS since you turned it on.") {
                SettingRow("Inverted events", subtitle: statsSubtitle) {
                    HStack(spacing: 8) {
                        if let observed = module.lastObservedClass {
                            let isMatched = observed == target
                            Text(observed.label)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    (isMatched ? Color.green : Color.pink).opacity(0.15),
                                    in: Capsule()
                                )
                                .foregroundStyle(isMatched ? .green : .pink)
                        }
                        Text("\(module.eventsInverted)")
                            .font(.body.weight(.semibold).monospacedDigit())
                    }
                }
            }
        }
    }

    private func devicePreviewTile(device: ScrollTarget, symbol: String, kindLabel: String) -> some View {
        let isInverted = isEnabled && target == device
        let isRecentlySeen = previewState.lastDevice == device

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isInverted ? .pink : .secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.label)
                        .font(.callout.weight(.semibold))
                    Text(kindLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(isInverted ? "Inverted" : "System")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        (isInverted ? Color.pink : Color.secondary).opacity(0.14),
                        in: Capsule()
                    )
                    .foregroundStyle(isInverted ? .pink : .secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: isInverted ? "arrow.up.arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(isInverted ? .pink : .secondary)
                Text(
                    isInverted
                        ? "Opposite to System Settings"
                        : "Matches System Settings"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isInverted
                ? Color.pink.opacity(0.08)
                : Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(
                    isRecentlySeen
                        ? (isInverted ? Color.pink.opacity(0.65) : Color.accentColor.opacity(0.55))
                        : Color.primary.opacity(isInverted ? 0.25 : 0.08),
                    lineWidth: isRecentlySeen ? 1.5 : 1
                )
        )
    }

    private var interactiveScrollPad: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Interactive Scroll Test Pad", systemImage: "hand.draw")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if let last = previewState.lastDevice {
                    let deltaText = String(format: "%+.1f", previewState.lastDeltaY)
                    let matchingTarget = isEnabled && module.isTapInstalled && last == target
                    Text("Detected: \(last.label) (\(last == .mouse ? "Line" : "Pixel")) · Δ \(deltaText)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(matchingTarget ? .pink : .secondary)
                } else {
                    Text("Hover here and scroll with mouse or trackpad")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if previewState.eventCount > 0 {
                    Button("Reset") {
                        previewState.reset()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .pointerCursor()
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(0.04))

                // Endless tiled preview rows driven directly by scroll events on the pad.
                VStack(spacing: 0) {
                    ForEach(-3..<10, id: \.self) { idx in
                        let rowNumber = ((idx % 6) + 6) % 6 + 1
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(rowNumber % 2 == 0 ? Color.pink.opacity(0.55) : Color.accentColor.opacity(0.45))
                                .frame(width: 4, height: 14)
                            Text("Sample Line \(rowNumber)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary.opacity(0.82))
                            Spacer()
                            Text(rowNumber == 1 ? "Top of list" : (rowNumber == 6 ? "End of section" : "Scroll to test direction"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        if idx < 9 {
                            Divider().opacity(0.4)
                        }
                    }
                }
                .offset(y: previewState.offset - 48)
                .allowsHitTesting(false)

                ScrollWheelCaptureRepresentable { deltaY, isContinuous in
                    previewState.recordScroll(deltaY: deltaY, isContinuous: isContinuous)
                }
            }
            .frame(height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.primary.opacity(0.11), lineWidth: 1)
            )
        }
    }

    private var statsSubtitle: String {
        if !isEnabled {
            return "Turn inversion on, then scroll with your mouse to confirm."
        }
        guard let observed = module.lastObservedClass else {
            return "Waiting for the first scroll event from your mouse or trackpad."
        }
        if observed == target {
            return "Inverting \(observed.label.lowercased()) scroll events as intended."
        }
        return "Receiving \(observed.label.lowercased()) style events right now (\(module.eventsInverted) inverted). Switch the target above if your mouse reports as \(observed.label)."
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
