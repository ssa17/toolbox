import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum WindowSnapperSettingsTab: String, CaseIterable, Identifiable {
    case general = "general"
    case topEdgePanel = "top_edge_panel"
    case zonesAndDisplays = "zones_displays"
    case profiles = "profiles"
    case shortcutsAndHistory = "shortcuts_history"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .topEdgePanel: return "Top Edge Panel"
        case .zonesAndDisplays: return "Display Zones"
        case .profiles: return "Profiles"
        case .shortcutsAndHistory: return "Shortcuts"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .topEdgePanel: return "dock.arrow.down.rectangle"
        case .zonesAndDisplays: return "rectangle.3.group"
        case .profiles: return "sparkles.rectangle.stack"
        case .shortcutsAndHistory: return "keyboard"
        }
    }
}

enum WindowSnapperShortcutCategory: String, CaseIterable, Identifiable {
    case halvesAndCore = "halves_core"
    case quarters = "quarters"
    case multiDisplay = "multi_display"
    case all = "all"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .halvesAndCore: return "Halves & Core"
        case .quarters: return "Quarters"
        case .multiDisplay: return "Multi-Display"
        case .all: return "All (13)"
        }
    }

    var actions: [WindowSnapperHotKeyAction] {
        switch self {
        case .halvesAndCore:
            return [.leftHalf, .rightHalf, .topHalf, .bottomHalf, .maximize, .center, .restorePreSnap]
        case .quarters:
            return [.topLeft, .topRight, .bottomLeft, .bottomRight]
        case .multiDisplay:
            return [.previousDisplay, .nextDisplay]
        case .all:
            return Array(WindowSnapperHotKeyAction.allCases)
        }
    }
}

enum ProfileTemplateFilterCount: String, CaseIterable, Identifiable {
    case all = "all"
    case one = "1"
    case two = "2"
    case three = "3"
    case fourOrSix = "4_6"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All Templates"
        case .one: return "1 App"
        case .two: return "2 Apps"
        case .three: return "3 Apps"
        case .fourOrSix: return "4 & 6 Apps"
        }
    }

    func matches(_ preset: DisplayPresetKind) -> Bool {
        switch self {
        case .all: return preset != .custom
        case .one: return preset.zoneCount == 1
        case .two: return preset.zoneCount == 2
        case .three: return preset.zoneCount == 3
        case .fourOrSix: return preset.zoneCount >= 4
        }
    }
}

struct InstalledAppCandidate: Identifiable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    let name: String
    let bundleIdentifier: String
    let appURL: URL
}

@MainActor
private final class WindowAnimationPreviewState: ObservableObject {
    /// 0 = Floating, 1 = Left Half, 2 = Right Half
    @Published var pose: Int = 0

    func play(speed: WindowAnimationSpeed) {
        let nextPose = (pose + 1) % 3
        if speed.isAnimated {
            withAnimation(.easeOut(duration: speed.snapDuration)) {
                pose = nextPose
            }
        } else {
            var tx = Transaction(animation: nil)
            tx.disablesAnimations = true
            withTransaction(tx) {
                pose = nextPose
            }
        }
    }

    var currentPoseLabel: String {
        switch pose {
        case 1: return "Left Half"
        case 2: return "Right Half"
        default: return "Floating"
        }
    }
}

@MainActor
private final class WindowSnapperSettingsUIState: ObservableObject {
    @Published var selectedTab: WindowSnapperSettingsTab
    @Published var selectedDisplayID: CGDirectDisplayID? = nil
    @Published var editingProfileDraft: WorkspaceProfile? = nil
    @Published var isCreatingNewProfile: Bool = false
    @Published var profileBuilderDisplayID: CGDirectDisplayID? = nil
    @Published var editingVariantDisplayCount: Int = 1
    @Published var editingDisplayRole: ProfileDisplayRole = .main
    @Published var draftAutoApplyOnConnect: Bool = false
    @Published var profileTemplateFilter: ProfileTemplateFilterCount = .all
    @Published var showProfileTemplatePicker: Bool = false
    @Published var showProfileBehaviorOptions: Bool = false
    @Published var shortcutCategory: WindowSnapperShortcutCategory = .halvesAndCore
    @Published var selectedTopEdgeSlotIndex: Int = 0
    @Published var installedApps: [InstalledAppCandidate] = []
    let animationPreview = WindowAnimationPreviewState()

    init(selectedTab: WindowSnapperSettingsTab = .general) {
        self.selectedTab = selectedTab
    }
}

struct WindowSnapperSettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var displayRegistry = DisplayRegistry.shared
    @ObservedObject private var overlayController = ZoneOverlayController.shared
    @ObservedObject private var screenOCR = ModuleRegistry.shared.screenOCR
    @ObservedObject var module: WindowSnapperModule
    @ObservedObject private var profileEngine: ProfileEngine
    @StateObject private var uiState: WindowSnapperSettingsUIState

    init(
        module: WindowSnapperModule,
        initialTab: WindowSnapperSettingsTab = .general
    ) {
        self.module = module
        _profileEngine = ObservedObject(wrappedValue: module.profileEngine)
        _uiState = StateObject(
            wrappedValue: WindowSnapperSettingsUIState(selectedTab: initialTab)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if module.sequoiaConflictStatus.hasConflictWithToolboxDrag && configManager.config.windowSnapper.drag.enabled {
                macOSTilingConflictBanner
            }

            ViewThatFits(in: .horizontal) {
                ToolboxSegmentedControl(
                    options: Array(WindowSnapperSettingsTab.allCases),
                    selection: $uiState.selectedTab,
                    accentColor: module.accentColor,
                    isFullWidth: true,
                    label: { $0.label },
                    symbol: { $0.symbolName }
                )
                .frame(minWidth: 640)

                ToolboxSegmentedControl(
                    options: Array(WindowSnapperSettingsTab.allCases),
                    selection: $uiState.selectedTab,
                    accentColor: module.accentColor,
                    isFullWidth: true,
                    label: { tab in
                        switch tab {
                        case .general: return "General"
                        case .topEdgePanel: return "Top"
                        case .zonesAndDisplays: return "Zones"
                        case .profiles: return "Profiles"
                        case .shortcutsAndHistory: return "Keys"
                        }
                    }
                )

                ToolboxSegmentedControl(
                    options: Array(WindowSnapperSettingsTab.allCases),
                    selection: $uiState.selectedTab,
                    accentColor: module.accentColor,
                    isFullWidth: true,
                    label: { tab in
                        switch tab {
                        case .general: return "Gen"
                        case .topEdgePanel: return "Top"
                        case .zonesAndDisplays: return "Zone"
                        case .profiles: return "Prof"
                        case .shortcutsAndHistory: return "Key"
                        }
                    }
                )
            }

            switch uiState.selectedTab {
            case .general:
                generalTab
            case .topEdgePanel:
                topEdgePanelTab
            case .zonesAndDisplays:
                zonesAndDisplaysTab
            case .profiles:
                profilesTab
            case .shortcutsAndHistory:
                shortcutsAndHistoryTab
            }
        }
        .onAppear {
            displayRegistry.refresh(gaps: configManager.config.windowSnapper.gaps)
            module.refreshSequoiaConflictStatus()
            if !PermissionsManager.isRunningInDiagnosticMode {
                screenOCR.refreshScreenPermission()
            }
            if uiState.selectedDisplayID == nil {
                uiState.selectedDisplayID = displayRegistry.mainDisplay()?.displayID
            }
            if uiState.profileBuilderDisplayID == nil {
                uiState.profileBuilderDisplayID = displayRegistry.mainDisplay()?.displayID
            }
            if uiState.installedApps.isEmpty {
                loadInstalledAppsAsync()
            }
        }
        .onDisappear {
            if !overlayController.isEditingOnScreen {
                overlayController.hideAllPreviews()
            }
        }
    }

    private var macOSTilingConflictBanner: some View {
        let activeLabels = module.sequoiaConflictStatus.activeSettingLabels
        return SectionCard(accentTint: .orange) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .toolboxFont(.title3)
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("macOS Native Window Tiling Is Enabled")
                            .toolboxFont(.headline)
                        Text("Turn off macOS's built-in tiling options in System Settings > Desktop & Dock > Windows so Toolbox Window Snapper handles every drag cleanly without competing overlays.")
                            .toolboxFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !activeLabels.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Currently enabled in Desktop & Dock:")
                            .toolboxFont(.caption.weight(.semibold))
                            .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                        ForEach(activeLabels, id: \.self) { label in
                            HStack(spacing: 6) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 5))
                                    .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                                Text(label)
                                    .toolboxFont(.caption)
                                    .foregroundStyle(.primary.opacity(0.88))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("Re-check") {
                            module.refreshSequoiaConflictStatus()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .pointerCursor()

                        Button("Desktop & Dock Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.toolboxProminent(.orange))
                        .controlSize(.regular)
                        .pointerCursor()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button("Desktop & Dock Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.toolboxProminent(.orange))
                        .controlSize(.regular)
                        .pointerCursor()

                        Button("Re-check") {
                            module.refreshSequoiaConflictStatus()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .pointerCursor()
                    }
                }
            }
        }
    }

    // MARK: - Tab 1: General

    @ViewBuilder
    private var generalTab: some View {
        let cfg = configManager.config.windowSnapper

        FeatureCardGridSection(
            "Drag Snapping Behaviors",
            subtitle: "Choose how dragging windows triggers snap zones. Snapped windows automatically restore their original size when dragged away."
        ) {
            ToolboxAdaptiveCardGrid(wideColumns: 2, narrowColumns: 1, wideMinWidth: 460, spacing: 10) {
                SelectableOptionCard(
                    title: "Edge & Corner Magnetic Snap",
                    subtitle: "Drag windows to left or right edges for halves, corners for quarters, or the top edge to maximize.",
                    symbolName: "rectangle.lefthalf.inset.filled",
                    accentColor: module.accentColor,
                    badge: cfg.drag.enabled ? "On · \(DragSnapConfig.edgeProximityLabel(for: cfg.drag.edgeProximityPoints))" : "Off",
                    isSelected: cfg.drag.enabled
                ) {
                    configManager.config.windowSnapper.drag.enabled.toggle()
                }

                SelectableOptionCard(
                    title: "Top Edge Panel",
                    subtitle: "Drag near the top center and drop straight onto any cell in a template tile, with optional glass panes for empty remaining cells.",
                    symbolName: "dock.arrow.down.rectangle",
                    accentColor: module.accentColor,
                    badge: cfg.topEdgePanel.enabled ? "On · \(TopEdgePanelConfig.triggerDistanceLabel(for: cfg.topEdgePanel.triggerDistancePoints))" : "Off",
                    isSelected: cfg.topEdgePanel.enabled
                ) {
                    configManager.config.windowSnapper.topEdgePanel.enabled.toggle()
                }
            }
        }

        FeatureSection(
            "Edge & Corner Magnetic Pull",
            subtitle: "Fine-tune how close the pointer must get to edges and corners to trigger a snap."
        ) {
            SettingRow(
                "Edge magnetic pull distance",
                subtitle: "How close the pointer must get to Left, Right, or Top edges to preview a snap (Bottom stays free for the Dock)."
            ) {
                HStack(spacing: 6) {
                    ForEach([0, 8, 12, 20], id: \.self) { pts in
                        ToolboxPresetChip(
                            label: DragSnapConfig.edgeProximityLabel(for: Double(pts)),
                            isSelected: Int(round(cfg.drag.edgeProximityPoints)) == pts,
                            accentColor: module.accentColor
                        ) {
                            configManager.config.windowSnapper.drag.edgeProximityPoints = Double(pts)
                            module.flashEdgePullTriggerZone(distancePoints: Double(pts))
                        }
                        .help(pts == 0 ? "0 pt (Requires touching edge)" : "\(pts) pt from edge")
                    }
                }
            }

            Divider()

            SettingRow(
                "Corner quadrant band",
                subtitle: "Corner target size used to trigger Top-Left, Top-Right, Bottom-Left, and Bottom-Right quarters."
            ) {
                HStack(spacing: 6) {
                    ForEach([32, 48, 64, 80], id: \.self) { pts in
                        ToolboxPresetChip(
                            label: DragSnapConfig.cornerBandLabel(for: Double(pts)),
                            isSelected: Int(round(cfg.drag.cornerBandPoints)) == pts,
                            accentColor: module.accentColor
                        ) {
                            configManager.config.windowSnapper.drag.cornerBandPoints = Double(pts)
                            module.flashCornerBandTriggerZone(bandPoints: Double(pts))
                        }
                        .help("\(pts) × \(pts) pt corner region")
                    }
                }
            }
        }

        FeatureSection(
            "Overlay Appearance & Animation",
            subtitle: "Customize zone outline styling, labels, and window glide animation."
        ) {
            SettingRow(
                "Outline color & fill opacity",
                subtitle: "Tint color and interior translucency of highlighted zone rectangles."
            ) {
                let swatches = HStack(spacing: 7) {
                    ForEach(OverlayTintColor.allCases) { tint in
                        let isSelected = cfg.overlayStyle.tintColor == tint
                        Button {
                            configManager.config.windowSnapper.overlayStyle.tintColor = tint
                            module.flashOutlineStylePreview(tintColor: tint)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(tint.swatchColor.gradient)
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(
                                                Color.white.opacity(tint == .neutral ? 0.55 : 0.25),
                                                lineWidth: 1
                                            )
                                    )
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .toolboxFont(.system(size: 10, weight: .bold))
                                        .foregroundStyle(tint == .neutral ? .black : .white)
                                }
                            }
                            .padding(2)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        isSelected ? Color.white.opacity(0.9) : Color.clear,
                                        lineWidth: 1.5
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tint.label)
                        .help(tint.label)
                        .pointerCursor()
                    }
                }

                let opacityChips = HStack(spacing: 5) {
                    ForEach([0.0, 0.10, 0.16, 0.24, 0.32], id: \.self) { val in
                        ToolboxPresetChip(
                            label: "\(Int(round(val * 100)))%",
                            isSelected: abs(cfg.overlayStyle.fillOpacity - val) < 0.02,
                            accentColor: module.accentColor
                        ) {
                            configManager.config.windowSnapper.overlayStyle.fillOpacity = val
                            module.flashOutlineStylePreview(fillOpacity: val)
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        swatches
                        opacityChips
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        swatches
                        opacityChips
                    }
                }
            }

            Divider()

            SettingRow(
                "Outline thickness",
                subtitle: "Line weight of highlighted zone borders on screen."
            ) {
                HStack(spacing: 6) {
                    ForEach([1.0, 2.0, 4.0, 7.0], id: \.self) { pts in
                        ToolboxPresetChip(
                            label: OverlayStyleConfig.borderThicknessLabel(for: pts),
                            isSelected: abs(cfg.overlayStyle.borderWidthPoints - pts) < 0.45,
                            accentColor: module.accentColor
                        ) {
                            configManager.config.windowSnapper.overlayStyle.borderWidthPoints = pts
                            module.flashOutlineThicknessPreview(borderWidthPoints: pts)
                        }
                        .help("\(Int(round(pts))) pt highlighted zone border")
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                SettingRow(
                    "Window animation",
                    subtitle: "Control how fast windows expand or glide when snapping into zones or pulling out of snapped positions."
                ) {
                    HStack(spacing: 6) {
                        ForEach(WindowAnimationSpeed.allCases) { speed in
                            ToolboxPresetChip(
                                label: speed.label,
                                isSelected: cfg.windowAnimationSpeed == speed,
                                accentColor: module.accentColor
                            ) {
                                configManager.config.windowSnapper.windowAnimationSpeed = speed
                                uiState.animationPreview.play(speed: speed)
                            }
                            .help(speed.isAnimated ? String(format: "%.2f s snap glide", speed.snapDuration) : "Instant snap with no glide")
                        }
                    }
                }

                WindowAnimationPreviewStrip(
                    speed: cfg.windowAnimationSpeed,
                    tintColor: cfg.overlayStyle.tintColor,
                    accentColor: module.accentColor,
                    previewState: uiState.animationPreview
                ) {
                    uiState.animationPreview.play(speed: cfg.windowAnimationSpeed)
                }
            }

            Divider()

            SettingRow(
                "Zone labels",
                subtitle: "Show zone dimensions inside previews."
            ) {
                Toggle("", isOn: Binding(
                    get: { configManager.config.windowSnapper.overlayStyle.showZoneLabelsAndDimensions },
                    set: { next in
                        configManager.config.windowSnapper.overlayStyle.showZoneLabelsAndDimensions = next
                        module.flashZoneLabelsPreview(showLabels: next)
                    }
                ))
                .labelsHidden()
                .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                .pointerCursor()
            }
        }
    }

    private func spacingAndOutlinePreviewBanner(cfg: WindowSnapperConfig) -> some View {
        let style = cfg.overlayStyle
        let previewTint: Color = style.tintColor.swatchColor
        let strokeColor: Color = style.tintColor.readableStrokeColor
        let scaledOuter = CGFloat(min(12.0, max(2.0, cfg.gaps.outerMarginPoints * 0.55)))
        let scaledInner = CGFloat(min(12.0, max(0.0, cfg.gaps.innerGapPoints * 0.55)))
        let scaledRadius = CGFloat(min(10.0, max(2.0, style.cornerRadiusPoints * 0.55)))
        let previewBorderWidth = CGFloat(min(5.0, max(0.8, style.borderWidthPoints * 0.72)))

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                spacingPreviewCanvas(
                    tint: previewTint,
                    stroke: strokeColor,
                    fillOpacity: style.fillOpacity,
                    borderWidth: previewBorderWidth,
                    outer: scaledOuter,
                    inner: scaledInner,
                    radius: scaledRadius,
                    showLabels: style.showZoneLabelsAndDimensions
                )
                spacingControlsColumn(cfg: cfg)
            }

            VStack(alignment: .leading, spacing: 12) {
                spacingPreviewCanvas(
                    tint: previewTint,
                    stroke: strokeColor,
                    fillOpacity: style.fillOpacity,
                    borderWidth: previewBorderWidth,
                    outer: scaledOuter,
                    inner: scaledInner,
                    radius: scaledRadius,
                    showLabels: style.showZoneLabelsAndDimensions
                )
                spacingControlsColumn(cfg: cfg)
            }
        }
    }

    private func spacingPreviewCanvas(
        tint: Color,
        stroke: Color,
        fillOpacity: Double,
        borderWidth: CGFloat,
        outer: CGFloat,
        inner: CGFloat,
        radius: CGFloat,
        showLabels: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.14, alpha: 1.0)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                )

            HStack(spacing: inner) {
                ForEach(["1 · Left", "2 · Right"], id: \.self) { label in
                    ZStack {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(tint.opacity(fillOpacity))
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(stroke.opacity(0.88), lineWidth: borderWidth)
                        if showLabels {
                            Text(label)
                                .toolboxFont(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(outer)
        }
        .frame(width: 186, height: 82)
    }

    private func spacingControlsColumn(cfg: WindowSnapperConfig) -> some View {
        let chipForPoints = { (pts: Int) in
            let matches = Int(round(cfg.gaps.outerMarginPoints)) == pts
                && Int(round(cfg.gaps.innerGapPoints)) == pts
            return ToolboxPresetChip(
                label: GapConfig.spacingPresetLabel(for: Double(pts)),
                isSelected: matches,
                accentColor: module.accentColor
            ) {
                var nextGaps = configManager.config.windowSnapper.gaps
                nextGaps.outerMarginPoints = Double(pts)
                nextGaps.innerGapPoints = Double(pts)
                configManager.config.windowSnapper.gaps = nextGaps
                module.flashTileSpacingPreview(spacingPoints: Double(pts))
            }
            .help(pts == 0 ? "0 pt (Flush against screen edges)" : "\(pts) pt outer margin & inner gap")
        }

        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text("Spacing presets:")
                        .toolboxFont(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach([0, 4, 8, 12, 16], id: \.self) { pts in
                        chipForPoints(pts)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Spacing presets:")
                        .toolboxFont(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach([0, 4, 8], id: \.self) { pts in
                            chipForPoints(pts)
                        }
                    }
                    HStack(spacing: 6) {
                        ForEach([12, 16], id: \.self) { pts in
                            chipForPoints(pts)
                        }
                    }
                }
            }

            Text("Sets uniform outer desktop margins and inner gaps between tiled windows. Maximize always fills edge-to-edge.")
                .toolboxFont(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Tab 2: Top Edge Panel

    @ViewBuilder
    private var topEdgePanelTab: some View {
        let cfg = configManager.config.windowSnapper
        let panelCfg = cfg.topEdgePanel
        let normalizedSlots = TopEdgePanelConfig.normalizedSlots(panelCfg.slots)
        let activeTemplateCount = normalizedSlots.compactMap { $0 }.count

        FeatureSection(
            "Top Edge Panel",
            subtitle: "Drag a window near the top center and hover any mini-cell right inside a template on the panel to preview and snap on release. Dragging against the top edge outside the strip always maximizes."
        ) {
            SettingRow(
                "Enable Top Edge Panel",
                subtitle: "Slide down the centered template picker strip when dragging a window toward the top center of the screen."
            ) {
                Toggle("", isOn: $configManager.config.windowSnapper.topEdgePanel.enabled)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            Divider()

            SettingRow(
                "Top-edge trigger distance",
                subtitle: "How close the pointer must get below the menu bar to reveal the Top Edge Panel."
            ) {
                HStack(spacing: 6) {
                    ForEach([0, 12, 24, 44], id: \.self) { pts in
                        ToolboxPresetChip(
                            label: TopEdgePanelConfig.triggerDistanceLabel(for: Double(pts)),
                            isSelected: Int(round(panelCfg.triggerDistancePoints)) == pts,
                            accentColor: module.accentColor
                        ) {
                            configManager.config.windowSnapper.topEdgePanel.triggerDistancePoints = Double(pts)
                            module.flashTopEdgeTriggerZone(distancePoints: Double(pts))
                        }
                        .help(pts == 0 ? "0 pt (Requires touching menu bar)" : "\(pts) pt drop-down distance")
                    }
                }
            }

            Divider()

            SettingRow(
                "Top-edge trigger width",
                subtitle: "Horizontal span along the top edge that reveals the panel; outside this span drags straight to Maximize."
            ) {
                HStack(spacing: 6) {
                    ForEach(TopEdgeTriggerWidth.allCases) { widthChoice in
                        ToolboxPresetChip(
                            label: widthChoice.label,
                            isSelected: panelCfg.triggerWidth == widthChoice,
                            accentColor: module.accentColor
                        ) {
                            configManager.config.windowSnapper.topEdgePanel.triggerWidth = widthChoice
                            module.flashTopEdgeTriggerZone(
                                distancePoints: panelCfg.triggerDistancePoints,
                                triggerWidth: widthChoice
                            )
                        }
                        .help(topEdgeTriggerWidthHelp(widthChoice))
                    }
                }
            }
        }

        let selectedSlotIndex = min(max(0, uiState.selectedTopEdgeSlotIndex), TopEdgePanelConfig.slotCount - 1)
        let selectedSlotPreset = normalizedSlots[selectedSlotIndex]
        let selectedSlotName = topEdgeSlotDisplayName(selectedSlotIndex)
        let readableAccent = ToolboxTheme.readableAccentText(for: module.accentColor)

        FeatureSection(
            "Template Slots",
            subtitle: "Select a slot in the strip below, then click any layout card to assign or swap it. Maximize stays centered."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                topEdgeInteractiveStrip(
                    normalizedSlots: normalizedSlots,
                    selectedSlotIndex: selectedSlotIndex,
                    style: cfg.overlayStyle
                )

                let slotStatusGroup = HStack(spacing: 8) {
                    StatusBadge(
                        text: selectedSlotPreset.map { "\(selectedSlotName) · \($0.label)" } ?? "\(selectedSlotName) · Hidden",
                        color: module.accentColor
                    )
                    StatusBadge(
                        text: "\(activeTemplateCount) / 6 + Maximize",
                        color: .secondary
                    )
                }

                let canMoveLeft = selectedSlotIndex > 0
                let canMoveRight = selectedSlotIndex < TopEdgePanelConfig.slotCount - 1
                let slotActionButtons = HStack(spacing: 6) {
                    Button {
                        let target = selectedSlotIndex - 1
                        if configManager.config.windowSnapper.topEdgePanel.swapSlots(selectedSlotIndex, target) {
                            uiState.selectedTopEdgeSlotIndex = target
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .toolboxFont(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canMoveLeft)
                    .help("Swap \(selectedSlotName) left")
                    .pointerCursor(canMoveLeft)

                    Button {
                        let target = selectedSlotIndex + 1
                        if configManager.config.windowSnapper.topEdgePanel.swapSlots(selectedSlotIndex, target) {
                            uiState.selectedTopEdgeSlotIndex = target
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .toolboxFont(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canMoveRight)
                    .help("Swap \(selectedSlotName) right")
                    .pointerCursor(canMoveRight)

                    if selectedSlotPreset != nil {
                        Button("Hide Slot") {
                            _ = configManager.config.windowSnapper.topEdgePanel.assignOrSwapSlot(nil, at: selectedSlotIndex)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()
                    }

                    Button("Reset Defaults") {
                        configManager.config.windowSnapper.topEdgePanel.resetSlotsToDefault()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(normalizedSlots == TopEdgePanelConfig.defaultSlots)
                    .pointerCursor(normalizedSlots != TopEdgePanelConfig.defaultSlots)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        slotStatusGroup
                        Spacer(minLength: 4)
                        slotActionButtons
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        slotStatusGroup
                        slotActionButtons
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Choose a layout for \(selectedSlotName) — clicking a template already in another slot swaps them")
                    .toolboxFont(.caption)
                    .foregroundStyle(.secondary)

                ToolboxAdaptiveCardGrid(wideColumns: 4, narrowColumns: 2, wideMinWidth: 500, spacing: 8) {
                    ForEach(DisplayPresetKind.topEdgeSlotTemplates) { preset in
                        let assignedIdx = panelCfg.slotIndex(for: preset)
                        let isAssignedToSelected = assignedIdx == selectedSlotIndex
                        let otherSlotLabel: String? = assignedIdx.flatMap { idx in
                            idx == selectedSlotIndex ? nil : topEdgeSlotDisplayName(idx)
                        }

                        TopEdgeSlotTemplateCard(
                            preset: preset,
                            accentColor: module.accentColor,
                            readableAccent: readableAccent,
                            isAssignedToSelectedSlot: isAssignedToSelected,
                            otherSlotLabel: otherSlotLabel
                        ) {
                            _ = configManager.config.windowSnapper.topEdgePanel.assignOrSwapSlot(
                                preset,
                                at: selectedSlotIndex
                            )
                        }
                    }
                }
            }
        }

        FeatureSection(
            "App Cards & Glass Panes",
            subtitle: "After snapping into a template cell, empty remaining cells open as frosted glass panes on that display (cells already filled stay undisturbed). Cards always appear inside one active pane at a time."
        ) {
            SettingRow(
                "Enable app cards",
                subtitle: "Open frosted glass panes with open window cards (including extra windows of the same app) to fill remaining empty cells."
            ) {
                Toggle("", isOn: $configManager.config.windowSnapper.topEdgePanel.showAppCards)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            Divider()

            SettingRow(
                "Window thumbnail previews",
                subtitle: "Show live previews of each app's current open window on cards. Best-effort with Screen Recording access; falls back to app icon and name."
            ) {
                Toggle("", isOn: $configManager.config.windowSnapper.topEdgePanel.showWindowThumbnails)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .disabled(!panelCfg.showAppCards)
                    .pointerCursor(panelCfg.showAppCards)
            }

            if panelCfg.showAppCards && panelCfg.showWindowThumbnails {
                Divider()

                SettingRow(
                    "Screen Recording access",
                    subtitle: screenOCR.screenRecordingGranted
                        ? "Live window thumbnail previews are enabled for app cards."
                        : "Optional — without Screen Recording permission, cards seamlessly show app icon and name."
                ) {
                    HStack(spacing: 8) {
                        StatusBadge(
                            text: screenOCR.screenRecordingGranted ? "Granted" : "Icon & Name Fallback",
                            color: screenOCR.screenRecordingGranted ? .green : .secondary
                        )
                        if !screenOCR.screenRecordingGranted {
                            Button("Screen Recording Settings…") {
                                ScreenCapturePermission.openSystemSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointerCursor()
                        }
                    }
                }
            }
        }
    }

    private func topEdgeInteractiveStrip(
        normalizedSlots: [DisplayPresetKind?],
        selectedSlotIndex: Int,
        style: OverlayStyleConfig
    ) -> some View {
        let tint = style.tintColor.swatchColor
        let stroke = style.tintColor.readableStrokeColor
        let readableAccent = ToolboxTheme.readableAccentText(for: module.accentColor)

        let pill = HStack(alignment: .top, spacing: 7) {
            ForEach(0..<3, id: \.self) { idx in
                TopEdgeStripEditableTile(
                    slotTitle: topEdgeSlotDisplayName(idx),
                    preset: normalizedSlots[idx],
                    isSelected: selectedSlotIndex == idx,
                    accentColor: module.accentColor,
                    readableAccent: readableAccent,
                    onSelect: {
                        uiState.selectedTopEdgeSlotIndex = idx
                    },
                    onClear: {
                        uiState.selectedTopEdgeSlotIndex = idx
                        _ = configManager.config.windowSnapper.topEdgePanel.assignOrSwapSlot(nil, at: idx)
                    }
                )
            }

            Capsule()
                .fill(Color.white.opacity(0.20))
                .frame(width: 1, height: 34)
                .padding(.top, 4)
                .padding(.horizontal, 2)

            VStack(spacing: 4) {
                TopEdgePickerSlotTile(
                    kind: .maximize,
                    isActive: true,
                    tint: tint,
                    strokeColor: stroke
                )
                .frame(width: 50, height: 42)
                .help("Maximize (Fixed Center)")

                Text("Max")
                    .toolboxFont(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.70))
            }

            Capsule()
                .fill(Color.white.opacity(0.20))
                .frame(width: 1, height: 34)
                .padding(.top, 4)
                .padding(.horizontal, 2)

            ForEach(3..<6, id: \.self) { idx in
                TopEdgeStripEditableTile(
                    slotTitle: topEdgeSlotDisplayName(idx),
                    preset: normalizedSlots[idx],
                    isSelected: selectedSlotIndex == idx,
                    accentColor: module.accentColor,
                    readableAccent: readableAccent,
                    onSelect: {
                        uiState.selectedTopEdgeSlotIndex = idx
                    },
                    onClear: {
                        uiState.selectedTopEdgeSlotIndex = idx
                        _ = configManager.config.windowSnapper.topEdgePanel.assignOrSwapSlot(nil, at: idx)
                    }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color.black.opacity(0.36), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )

        return ViewThatFits(in: .horizontal) {
            HStack {
                Spacer(minLength: 0)
                pill
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                pill
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func topEdgeTriggerWidthHelp(_ widthChoice: TopEdgeTriggerWidth) -> String {
        switch widthChoice {
        case .compact: return "Focused center strip around Maximize"
        case .matchPanel: return "Matches the visible template strip width"
        case .wide: return "Covers most of the top edge between corners"
        }
    }

    private func topEdgeSlotDisplayName(_ index: Int) -> String {
        if index < 3 {
            return "Left \(index + 1)"
        }
        return "Right \(index - 2)"
    }

    // MARK: - Tab 3: Display Zones (Drag-to-Snap Grid per Display)

    private var selectedDisplay: ConnectedDisplay? {
        displayRegistry.connectedDisplays.first { $0.displayID == uiState.selectedDisplayID }
            ?? displayRegistry.mainDisplay()
            ?? displayRegistry.connectedDisplays.first
    }

    @ViewBuilder
    private var zonesAndDisplaysTab: some View {
        let cfg = configManager.config.windowSnapper

        if displayRegistry.connectedDisplays.count > 1 {
            FeatureSection(
                "Connected Displays",
                subtitle: "Choose a physical monitor to configure its drag-to-snap zone grid."
            ) {
                ToolboxAdaptiveCardGrid(
                    wideColumns: 2,
                    narrowColumns: 1,
                    wideMinWidth: 500,
                    spacing: 10
                ) {
                    ForEach(displayRegistry.connectedDisplays) { display in
                        connectedDisplayCard(display)
                    }
                }
            }
        }

        if let display = selectedDisplay {
            let currentLayout = DisplayRegistry.layout(
                for: display.signature,
                in: cfg.displayLayouts
            ) ?? DisplayLayoutConfig(display: display.signature)
            let resolvedZones = SnapGeometry.resolveZones(
                layout: currentLayout,
                usableAXRect: display.usableAX,
                primaryScreenHeight: display.primaryScreenHeight,
                gaps: cfg.gaps
            )
            let gridSectionSubtitle: String = {
                if cfg.drag.gridModifier == .none {
                    return "Full-grid overlay is currently Off. Choose a reveal key below to show these zones while dragging a window."
                }
                return "Hold \(cfg.drag.gridModifier.label) while dragging any window to show this grid on \(display.signature.localizedName). Hover near a divider seam to span adjacent zones."
            }()
            let activeLayoutBadgeText = currentLayout.hasCustomDividerProportions
                ? "\(currentLayout.presetKind.label) · Adjusted"
                : currentLayout.presetKind.label

            FeatureSection(
                "Drag-to-Snap Grid",
                subtitle: gridSectionSubtitle
            ) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(display.signature.localizedName)
                                    .toolboxFont(.callout.weight(.semibold))
                                StatusBadge(text: activeLayoutBadgeText, color: module.accentColor)
                                StatusBadge(text: "\(resolvedZones.count) zones", color: .secondary)
                            }
                            Text("Usable \(Int(display.usableAX.width)) × \(Int(display.usableAX.height)) pt")
                                .toolboxFont(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        if currentLayout.hasCustomDividerProportions {
                            Button("Reset") {
                                var updated = currentLayout
                                updated.division = currentLayout.presetKind.defaultDivision
                                module.saveDisplayLayout(updated)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .help("Reset dividers to \(currentLayout.presetKind.label) defaults")
                            .pointerCursor()
                        }

                        Button("Preview (3s)") {
                            module.previewDisplayZones(duration: 3.0)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .pointerCursor()

                        Button("Adjust Dividers on Screen") {
                            module.beginOnScreenLayoutEditor(for: display)
                        }
                        .buttonStyle(.toolboxProminent)
                        .controlSize(.regular)
                        .pointerCursor()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(display.signature.localizedName)
                                .toolboxFont(.callout.weight(.semibold))
                            HStack(spacing: 6) {
                                StatusBadge(text: activeLayoutBadgeText, color: module.accentColor)
                                StatusBadge(text: "\(resolvedZones.count) zones", color: .secondary)
                            }
                            Text("Usable \(Int(display.usableAX.width)) × \(Int(display.usableAX.height)) pt")
                                .toolboxFont(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            if currentLayout.hasCustomDividerProportions {
                                Button("Reset") {
                                    var updated = currentLayout
                                    updated.division = currentLayout.presetKind.defaultDivision
                                    module.saveDisplayLayout(updated)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .help("Reset dividers to \(currentLayout.presetKind.label) defaults")
                                .pointerCursor()
                            }

                            Button("Preview (3s)") {
                                module.previewDisplayZones(duration: 3.0)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .pointerCursor()

                            Button("Adjust Dividers on Screen") {
                                module.beginOnScreenLayoutEditor(for: display)
                            }
                            .buttonStyle(.toolboxProminent)
                            .controlSize(.regular)
                            .pointerCursor()
                        }
                    }
                }

                Divider()

                displayLayoutPreviewCanvas(display: display, resolvedZones: resolvedZones)
            }

            FeatureSection(
                "Drag Controls",
                subtitle: "Choose which modifier key reveals your Display Zones grid while dragging."
            ) {
                displayZonesTriggerRow(cfg: cfg)
            }

            FeatureSection(
                "Tile Spacing",
                subtitle: "Set outer desktop margins and gaps between snapped windows across all snapping modes and profiles."
            ) {
                spacingAndOutlinePreviewBanner(cfg: cfg)
            }

            FeatureSection(
                "Grid Templates",
                subtitle: "Choose the snap grid for \(display.signature.localizedName). Single-row column layouts also shape Left and Right edge pulls."
            ) {
                templateGroupBlock(
                    title: "1 & 2 Zones",
                    presets: [.maximized, .halves, .asymmetric, .asymmetricRight, .verticalStack2],
                    selectedPresetID: currentLayout.presetID
                ) { preset in
                    var updated = currentLayout
                    updated.presetID = preset.rawValue
                    updated.division = preset.defaultDivision
                    module.saveDisplayLayout(updated)
                }

                Divider()

                templateGroupBlock(
                    title: "3 Zones",
                    presets: [.leftMainRightStack, .leftStackRightMain, .thirds, .ultrawideFocus, .verticalStack3],
                    selectedPresetID: currentLayout.presetID
                ) { preset in
                    var updated = currentLayout
                    updated.presetID = preset.rawValue
                    updated.division = preset.defaultDivision
                    module.saveDisplayLayout(updated)
                }

                Divider()

                templateGroupBlock(
                    title: "4 & 6 Zones",
                    presets: [.quarters, .fourColumns, .sixths],
                    selectedPresetID: currentLayout.presetID
                ) { preset in
                    var updated = currentLayout
                    updated.presetID = preset.rawValue
                    updated.division = preset.defaultDivision
                    module.saveDisplayLayout(updated)
                }
            }

            if !currentLayout.customZones.isEmpty {
                FeatureSection(
                    "Drawn Custom Zones",
                    subtitle: "Extra zones drawn in the 1:1 on-screen editor for \(display.signature.localizedName). Available in the drag grid and via optional direct shortcuts."
                ) {
                    ForEach(currentLayout.customZones.indices, id: \.self) { idx in
                        if idx > 0 {
                            Divider()
                        }
                        customZoneCardRow(currentLayout: currentLayout, index: idx)
                    }
                }
            }
        }
    }

    private func templateGroupBlock(
        title: String,
        presets: [DisplayPresetKind],
        selectedPresetID: String,
        onSelect: @escaping (DisplayPresetKind) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .toolboxFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ToolboxAdaptiveCardGrid(wideColumns: 4, narrowColumns: 2, wideMinWidth: 520, spacing: 10) {
                ForEach(presets) { preset in
                    TemplateDiagramCard(
                        preset: preset,
                        accentColor: module.accentColor,
                        isSelected: selectedPresetID == preset.rawValue
                    ) {
                        onSelect(preset)
                    }
                }
            }
        }
    }

    private func connectedDisplayCard(_ display: ConnectedDisplay) -> some View {
        let isSelected = display.displayID == selectedDisplay?.displayID
        let layout = DisplayRegistry.layout(
            for: display.signature,
            in: configManager.config.windowSnapper.displayLayouts
        )
        let presetName = layout?.presetKind.label ?? DisplayPresetKind.halves.label
        let readableAccent = ToolboxTheme.readableAccentText(for: module.accentColor)

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                uiState.selectedDisplayID = display.displayID
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill((isSelected ? module.accentColor : Color.primary).opacity(isSelected ? 0.22 : 0.08))
                            .frame(width: 34, height: 34)
                        Image(systemName: display.isMain ? "laptopcomputer" : "display")
                            .toolboxFont(.callout.weight(.semibold))
                            .foregroundStyle(isSelected ? readableAccent : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(display.signature.localizedName)
                                .toolboxFont(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if display.isMain {
                                StatusBadge(text: "Main", color: .indigo)
                            }
                        }
                        Text("\(presetName) · \(Int(display.frameAX.width)) × \(Int(display.frameAX.height))")
                            .toolboxFont(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .toolboxFont(.system(size: 15, weight: .semibold))
                            .foregroundStyle(readableAccent)
                    } else {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1.25)
                            .frame(width: 15, height: 15)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerCursor()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? module.accentColor.opacity(0.09) : Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isSelected ? readableAccent.opacity(0.58) : Color.primary.opacity(0.09),
                    lineWidth: isSelected ? 1.25 : 1
                )
        )
    }

    private func displayLayoutPreviewCanvas(display: ConnectedDisplay, resolvedZones: [ResolvedZone]) -> some View {
        let aspect = max(0.8, display.usableAX.width / max(1, display.usableAX.height))
        let canvasHeight = min(210.0, max(135.0, 340.0 / aspect))

        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color.white.opacity(0.28)).frame(width: 5, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.22)).frame(width: 24, height: 4)
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.14)).frame(width: 18, height: 4)
                Spacer()
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.22)).frame(width: 32, height: 4)
            }
            .padding(.horizontal, 10)
            .frame(height: 16)
            .background(Color.black.opacity(0.32))

            GeometryReader { geo in
                let canvasW = geo.size.width
                let canvasH = geo.size.height
                ZStack(alignment: .topLeading) {
                    Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.14, alpha: 1.0))

                    ForEach(resolvedZones) { zone in
                        let nx = (zone.frameInAX.minX - display.usableAX.minX) / max(1, display.usableAX.width)
                        let ny = (zone.frameInAX.minY - display.usableAX.minY) / max(1, display.usableAX.height)
                        let nw = zone.frameInAX.width / max(1, display.usableAX.width)
                        let nh = zone.frameInAX.height / max(1, display.usableAX.height)
                        let isCustom = zone.gridCoord == nil
                        let style = configManager.config.windowSnapper.overlayStyle
                        let tint: Color = isCustom ? .teal : style.tintColor.swatchColor
                        let strokeColor: Color = isCustom
                            ? ToolboxTheme.readableAccentText(for: .teal)
                            : style.tintColor.readableStrokeColor
                        let fillOpacity = isCustom ? 0.20 : max(0.10, style.fillOpacity)
                        let badgeForeground: Color = (!isCustom && style.tintColor == .neutral) ? .black : .white

                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(tint.opacity(fillOpacity))
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(strokeColor.opacity(0.84), lineWidth: 1.25)

                            VStack(spacing: 3) {
                                HStack(spacing: 5) {
                                    Text("\(zone.badgeNumber)")
                                        .toolboxFont(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(badgeForeground)
                                        .frame(width: 17, height: 17)
                                        .background(tint.opacity(0.85), in: Circle())
                                    Text(zone.name)
                                        .toolboxFont(.caption.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                }
                                Text("\(Int(round(zone.frameInAX.width))) × \(Int(round(zone.frameInAX.height)))")
                                    .toolboxFont(.caption2.monospacedDigit())
                                    .foregroundStyle(Color.white.opacity(0.75))
                                if !zone.shortcut.isEmpty {
                                    ShortcutPill(shortcut: zone.shortcut)
                                }
                            }
                            .padding(5)
                        }
                        .frame(width: max(22, nw * canvasW), height: max(22, nh * canvasH))
                        .offset(x: nx * canvasW, y: ny * canvasH)
                    }
                }
            }
            .frame(height: canvasHeight)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
        )
    }

    private func displayZonesTriggerRow(cfg: WindowSnapperConfig) -> some View {
        let gridMod = cfg.drag.gridModifier
        let subtitle: String = {
            if gridMod == .none {
                return "Currently turned off. Pick a key to reveal this grid while dragging a window."
            }
            return "Hold \(gridMod.label) while dragging a window to reveal these zones. Left & Right edge pulls also snap to outer columns on single-row grids."
        }()
        return SettingRow("Reveal grid while dragging", subtitle: subtitle) {
            HStack(spacing: 8) {
                if gridMod == .none {
                    StatusBadge(text: "Off", color: .orange)
                }
                Picker("", selection: $configManager.config.windowSnapper.drag.gridModifier) {
                    ForEach(DragModifierChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 152)
                .pointerCursor()
            }
        }
    }

    private func customZoneCardRow(currentLayout: DisplayLayoutConfig, index idx: Int) -> some View {
        let zone = currentLayout.customZones[idx]
        return HStack(spacing: 10) {
            Text("C\(idx + 1)")
                .toolboxFont(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.teal.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                TextField("Zone Name", text: Binding(
                    get: { currentLayout.customZones[idx].name },
                    set: { newName in
                        var updated = currentLayout
                        updated.customZones[idx].name = newName
                        module.saveDisplayLayout(updated)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)

                Text("\(Int(round(zone.normalizedRect.x * 100)))%, \(Int(round(zone.normalizedRect.y * 100)))% · \(Int(round(zone.normalizedRect.width * 100)))% × \(Int(round(zone.normalizedRect.height * 100)))%")
                    .toolboxFont(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            ShortcutRecorderView(
                shortcut: zone.shortcut,
                sourceID: "window_snapper.zone.\(currentLayout.id).\(zone.id)",
                registrationKey: "window_snapper.zone.\(currentLayout.id).\(zone.id)"
            ) { newShortcut in
                var updated = currentLayout
                updated.customZones[idx].shortcut = newShortcut
                module.saveDisplayLayout(updated)
            }

            Button {
                var updated = currentLayout
                updated.customZones.remove(at: idx)
                module.saveDisplayLayout(updated)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(ToolboxTheme.readableAccentText(for: .red))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .pointerCursor()
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Tab 3: Profiles (Visual Click-a-Square Profile Builder)

    @ViewBuilder
    private var profilesTab: some View {
        if let draft = uiState.editingProfileDraft {
            profileDraftEditor(draft: draft)
        } else {
            displayConnectSection
            profilesListSection
        }
    }

    @ViewBuilder
    private var displayConnectSection: some View {
        let cfg = configManager.config.windowSnapper
        let profiles = cfg.profiles
        let hasThreeDisplayProfile = profiles.contains { $0.maxDisplayCount >= 3 }
        let connected = displayRegistry.connectedDisplays
        let hasMultipleConnected = connected.count >= 2 || DisplayRegistry.onlineDisplayIDs().count >= 2
        let setupSummary: String = {
            if connected.isEmpty { return "No displays detected" }
            let names = connected.map(\.signature.localizedName).joined(separator: " + ")
            return "\(connected.count) \(connected.count == 1 ? "Display" : "Displays") Connected · \(names)"
        }()

        FeatureSection(
            "Display Connect & Auto-Setup",
            subtitle: "Control how macOS arranges newly plugged-in monitors and which profile auto-applies."
        ) {
            HStack(spacing: 8) {
                Image(systemName: connected.count >= 2 ? "display.2" : "display")
                    .toolboxFont(.caption.weight(.semibold))
                    .foregroundStyle(ToolboxTheme.readableAccentText(for: module.accentColor))
                Text(setupSummary)
                    .toolboxFont(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if connected.count >= 2 {
                    Button {
                        module.identifyDisplays()
                    } label: {
                        Label("Identify", systemImage: "viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                }
                if let autoID = cfg.autoApplyProfileID,
                   let autoProfile = profiles.first(where: { $0.id == autoID }) {
                    StatusBadge(text: "Auto: \(autoProfile.name)", color: .teal)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))

            Divider()

            SettingRow(
                "On display connect",
                subtitle: cfg.displayConnectMode.explanation
            ) {
                HStack(spacing: 8) {
                    ToolboxSegmentedControl(
                        options: Array(DisplayConnectMode.allCases),
                        selection: Binding(
                            get: { configManager.config.windowSnapper.displayConnectMode },
                            set: { configManager.config.windowSnapper.displayConnectMode = $0 }
                        ),
                        accentColor: module.accentColor,
                        label: { $0.label }
                    )

                    if cfg.displayConnectMode != .systemDefault && hasMultipleConnected {
                        Button("Apply Now") {
                            module.applyDisplayConnectModeNow()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .pointerCursor()
                    }
                }
            }

            Divider()

            SettingRow(
                "Auto-apply profile",
                subtitle: "Automatically applies this profile's matching 1, 2, or 3-display layout whenever displays change."
            ) {
                Picker(
                    "",
                    selection: Binding<String?>(
                        get: { configManager.config.windowSnapper.autoApplyProfileID },
                        set: { configManager.config.windowSnapper.autoApplyProfileID = $0 }
                    )
                ) {
                    Text("Off (Manual Only)").tag(String?.none)
                    ForEach(profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                .pointerCursor()
            }

            if connected.count >= 3 || hasThreeDisplayProfile {
                Divider()

                SettingRow(
                    "External display order",
                    subtitle: "Quickly swap which external monitor acts as External 1 vs External 2 in 3-display layouts."
                ) {
                    HStack(spacing: 8) {
                        StatusBadge(
                            text: cfg.swapExternalDisplays ? "Swapped" : "Default",
                            color: cfg.swapExternalDisplays ? .orange : .secondary
                        )
                        Button {
                            module.swapExternalDisplays()
                        } label: {
                            Label("Swap External 1 & 2", systemImage: "arrow.left.arrow.right")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .pointerCursor()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var profilesListSection: some View {
        FeatureSection(
            "Workspace Profiles",
            subtitle: "Launch and arrange assigned apps into a saved multi-window layout in one click, via hotkey, or when connecting a display."
        ) {
            HStack(spacing: 10) {
                Button {
                    beginBlankProfileDraft()
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                .buttonStyle(.toolboxProminent)
                .controlSize(.regular)
                .pointerCursor()

                Menu("Starter…") {
                    ForEach(WorkspaceProfile.defaultTemplates) { template in
                        Button(template.name) {
                            beginStarterProfileDraft(template)
                        }
                    }
                }
                .menuStyle(.borderedButton)
                .controlSize(.regular)
                .fixedSize()
                .pointerCursor()

                Spacer(minLength: 0)
            }

            if configManager.config.windowSnapper.profiles.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Start with a Template Profile")
                        .toolboxFont(.callout.weight(.semibold))
                    Text("Click a starter profile below or press New Profile to pick a layout and assign apps to each position.")
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)

                    ToolboxAdaptiveCardGrid(wideColumns: 3, narrowColumns: 1, wideMinWidth: 520, spacing: 10) {
                        ForEach(WorkspaceProfile.defaultTemplates) { template in
                            SelectableOptionCard(
                                title: template.name,
                                subtitle: template.appRules.map(\.appName).joined(separator: " · "),
                                symbolName: template.symbolName,
                                accentColor: module.accentColor,
                                badge: "+ Customize",
                                isSelected: false,
                                isCompact: true
                            ) {
                                beginStarterProfileDraft(template)
                            }
                        }
                    }
                }
            } else {
                ForEach(configManager.config.windowSnapper.profiles.indices, id: \.self) { idx in
                    Divider()
                    profileCardRow(index: idx)
                }
            }
        }
    }

    private func beginBlankProfileDraft() {
        let count = configManager.config.windowSnapper.profiles.count + 1
        let defaultDisplay = displayRegistry.mainDisplay() ?? displayRegistry.connectedDisplays.first
        let defaultSig = defaultDisplay?.signature ?? DisplaySignature(localizedName: "Main Display")
        let preset: DisplayPresetKind = .leftMainRightStack
        var draft = WorkspaceProfile(
            name: "Workspace \(count)",
            symbolName: "sparkles.rectangle.stack",
            displayLayoutOverrides: [
                DisplayLayoutConfig(
                    display: defaultSig,
                    presetID: preset.rawValue,
                    division: preset.defaultDivision
                )
            ]
        )
        draft.ensureVariantsUpToMaxDisplayCount()
        uiState.editingProfileDraft = draft
        uiState.isCreatingNewProfile = true
        uiState.showProfileTemplatePicker = true
        uiState.showProfileBehaviorOptions = false
        uiState.editingVariantDisplayCount = min(max(displayRegistry.connectedDisplays.count, 1), draft.maxDisplayCount)
        uiState.editingDisplayRole = .main
        uiState.draftAutoApplyOnConnect = false
    }

    private func beginStarterProfileDraft(_ template: WorkspaceProfile) {
        var copy = template
        copy.id = UUID().uuidString
        copy.ensureVariantsUpToMaxDisplayCount()
        uiState.editingProfileDraft = copy
        uiState.isCreatingNewProfile = true
        uiState.showProfileTemplatePicker = false
        uiState.showProfileBehaviorOptions = false
        uiState.editingVariantDisplayCount = min(max(displayRegistry.connectedDisplays.count, 1), copy.maxDisplayCount)
        uiState.editingDisplayRole = .main
        uiState.draftAutoApplyOnConnect = false
    }

    private func beginEditingProfile(_ profile: WorkspaceProfile, initialVariantCount: Int? = nil) {
        var copy = profile
        copy.ensureVariantsUpToMaxDisplayCount()
        uiState.editingProfileDraft = copy
        uiState.isCreatingNewProfile = false
        uiState.showProfileTemplatePicker = false
        uiState.showProfileBehaviorOptions = false
        let fallbackCount = min(max(displayRegistry.connectedDisplays.count, 1), copy.maxDisplayCount)
        uiState.editingVariantDisplayCount = min(max(initialVariantCount ?? fallbackCount, 1), copy.maxDisplayCount)
        uiState.editingDisplayRole = .main
        uiState.draftAutoApplyOnConnect = (configManager.config.windowSnapper.autoApplyProfileID == copy.id)
    }

    private func saveEditingProfileDraft(andApply: Bool = false) {
        guard var draft = uiState.editingProfileDraft else { return }
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draft.name = "Workspace \(configManager.config.windowSnapper.profiles.count + 1)"
        } else {
            draft.name = trimmed
        }

        draft.ensureVariantsUpToMaxDisplayCount()
        if let v1 = draft.displayVariants.first(where: { $0.displayCount == 1 }) {
            draft.appRules = v1.appRules
        }

        if let existingIdx = configManager.config.windowSnapper.profiles.firstIndex(where: { $0.id == draft.id }) {
            configManager.config.windowSnapper.profiles[existingIdx] = draft
        } else {
            configManager.config.windowSnapper.profiles.append(draft)
        }
        if uiState.draftAutoApplyOnConnect {
            configManager.config.windowSnapper.autoApplyProfileID = draft.id
        } else if configManager.config.windowSnapper.autoApplyProfileID == draft.id {
            configManager.config.windowSnapper.autoApplyProfileID = nil
        }
        uiState.editingProfileDraft = nil
        uiState.isCreatingNewProfile = false
        uiState.showProfileTemplatePicker = false
        uiState.showProfileBehaviorOptions = false
        if andApply {
            module.applyProfileDirectly(draft)
        } else {
            HUDToast.shared.show(
                title: "Saved \(draft.name)",
                subtitle: "Ready to apply",
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        }
    }

    private func cancelEditingProfileDraft() {
        if overlayController.isEditingOnScreen {
            overlayController.endOnScreenEditor()
        }
        uiState.editingProfileDraft = nil
        uiState.isCreatingNewProfile = false
        uiState.showProfileTemplatePicker = false
        uiState.showProfileBehaviorOptions = false
    }

    private func profileCardRow(index: Int) -> some View {
        let profile = configManager.config.windowSnapper.profiles[index]
        let isActive = configManager.config.windowSnapper.activeProfileID == profile.id
        let isAutoApply = configManager.config.windowSnapper.autoApplyProfileID == profile.id
        let readableAccent = ToolboxTheme.readableAccentText(for: module.accentColor)
        let connectedCount = max(displayRegistry.connectedDisplays.count, 1)

        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    profileCardHeaderButton(profile: profile, isActive: isActive, readableAccent: readableAccent)
                    profileCardActionButtons(profile: profile, index: index)
                }

                VStack(alignment: .leading, spacing: 10) {
                    profileCardHeaderButton(profile: profile, isActive: isActive, readableAccent: readableAccent)
                    profileCardActionButtons(profile: profile, index: index)
                }
            }

            if profile.maxDisplayCount > 1 {
                HStack(spacing: 6) {
                    Text("Views:")
                        .toolboxFont(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(1...profile.maxDisplayCount, id: \.self) { count in
                        let isMatched = count == min(connectedCount, profile.maxDisplayCount)
                        let variantApps = profile.effectiveAppRules(forDisplayCount: count).count
                        Button {
                            beginEditingProfile(profile, initialVariantCount: count)
                        } label: {
                            HStack(spacing: 4) {
                                if isMatched {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 5, height: 5)
                                }
                                Text("\(count) \(count == 1 ? "Display" : "Displays")")
                                    .toolboxFont(.caption2.weight(isMatched ? .semibold : .medium))
                                if variantApps > 0 {
                                    Text("· \(variantApps)")
                                        .toolboxFont(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                isMatched ? module.accentColor.opacity(0.14) : Color.primary.opacity(0.05),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    isMatched ? module.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                                    lineWidth: 1
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .pointerCursor()
                    }
                    Spacer(minLength: 0)
                }
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    profileCardAppsSummary(profile: profile)
                    Spacer(minLength: 8)
                    profileCardShortcutControl(profile: profile)
                }

                VStack(alignment: .leading, spacing: 8) {
                    profileCardAppsSummary(profile: profile)
                    HStack {
                        Spacer(minLength: 0)
                        profileCardShortcutControl(profile: profile)
                    }
                }
            }
        }
        .padding(11)
        .background(
            isActive ? module.accentColor.opacity(0.05) : Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isAutoApply ? Color.teal.opacity(0.45) : Color.primary.opacity(0.09),
                    lineWidth: 1
                )
        )
    }

    private func profileCardHeaderButton(
        profile: WorkspaceProfile,
        isActive: Bool,
        readableAccent: Color
    ) -> some View {
        let connectedCount = max(displayRegistry.connectedDisplays.count, 1)
        let matchedPreset: DisplayPresetKind = profile.resolvedVariant(forDisplayCount: connectedCount)?.layout(for: .main).presetKind
            ?? profile.displayLayoutOverrides.first?.presetKind
            ?? .halves

        return Button {
            beginEditingProfile(profile)
        } label: {
            HStack(spacing: 12) {
                TemplateMiniThumbnailView(
                    preset: matchedPreset,
                    cellFill: module.accentColor.opacity(isActive ? 0.52 : 0.34),
                    cellStroke: readableAccent.opacity(0.85),
                    padding: 5,
                    cellGap: 1.5
                )
                .frame(width: 48, height: 32)
                .background(
                    Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.14, alpha: 1.0)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .toolboxFont(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if profile.maxDisplayCount > 1 {
                            StatusBadge(text: "1–\(profile.maxDisplayCount) Displays", color: module.accentColor)
                        } else if let mainSlot = profile.resolvedVariant(forDisplayCount: 1)?.layout(for: .main) {
                            StatusBadge(
                                text: mainSlot.hasCustomDividerProportions
                                    ? "\(mainSlot.presetKind.label) · Adjusted"
                                    : mainSlot.presetKind.label,
                                color: module.accentColor
                            )
                        } else if let firstOverride = profile.displayLayoutOverrides.first {
                            StatusBadge(
                                text: firstOverride.hasCustomDividerProportions
                                    ? "\(firstOverride.presetKind.label) · Adjusted"
                                    : firstOverride.presetKind.label,
                                color: module.accentColor
                            )
                        }
                        if isActive {
                            StatusBadge(text: "Active", color: .green)
                        }
                        if configManager.config.windowSnapper.autoApplyProfileID == profile.id {
                            StatusBadge(text: "Auto-Apply", color: .teal)
                        } else if profile.topologyTriggerMode != .off {
                            StatusBadge(text: profile.topologyTriggerMode.label, color: .teal)
                        }
                    }
                    let effectiveRules = profile.effectiveAppRules(forDisplayCount: displayRegistry.connectedDisplays.count)
                    Text(
                        effectiveRules.isEmpty
                            ? "Layout only · click Edit to assign applications"
                            : "\(effectiveRules.count) app\(effectiveRules.count == 1 ? "" : "s") assigned"
                    )
                    .toolboxFont(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerCursor()
    }

    private func profileCardActionButtons(profile: WorkspaceProfile, index: Int) -> some View {
        let canRestore = module.restoreAvailableProfileID == profile.id
        let isAutoApply = configManager.config.windowSnapper.autoApplyProfileID == profile.id
        let isActive = configManager.config.windowSnapper.activeProfileID == profile.id

        return HStack(spacing: 6) {
            Button("Edit") {
                beginEditingProfile(profile)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .pointerCursor()

            Button {
                module.applyProfile(profile)
            } label: {
                if profileEngine.isApplyingProfile && isActive {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Applying…")
                    }
                } else {
                    Text(canRestore ? "Restore" : "Apply")
                }
            }
            .buttonStyle(.toolboxProminent)
            .controlSize(.regular)
            .disabled(profileEngine.isApplyingProfile)
            .pointerCursor(!profileEngine.isApplyingProfile)

            Menu {
                Button {
                    configManager.config.windowSnapper.autoApplyProfileID = isAutoApply ? nil : profile.id
                } label: {
                    Label(
                        isAutoApply ? "Turn Off Auto-Apply" : "Set as Auto-Apply",
                        systemImage: isAutoApply ? "bolt.slash" : "bolt.fill"
                    )
                }

                Button {
                    module.previewProfile(profile, duration: 3.0)
                } label: {
                    Label("Preview on Screen (3s)", systemImage: "eye")
                }

                if isActive && displayRegistry.connectedDisplays.count >= 3 {
                    Button {
                        module.swapExternalDisplays()
                    } label: {
                        Label("Swap External 1 & 2", systemImage: "arrow.left.arrow.right")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    let removedID = profile.id
                    configManager.config.windowSnapper.profiles.remove(at: index)
                    if configManager.config.windowSnapper.activeProfileID == removedID {
                        configManager.config.windowSnapper.activeProfileID = nil
                    }
                    if configManager.config.windowSnapper.autoApplyProfileID == removedID {
                        configManager.config.windowSnapper.autoApplyProfileID = nil
                    }
                } label: {
                    Label("Delete Profile", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderedButton)
            .controlSize(.regular)
            .fixedSize()
            .pointerCursor()
        }
    }

    @ViewBuilder
    private func profileCardAppsSummary(profile: WorkspaceProfile) -> some View {
        let effectiveRules = profile.effectiveAppRules(forDisplayCount: displayRegistry.connectedDisplays.count)
        if effectiveRules.isEmpty {
            Text("No apps assigned · click Edit")
                .toolboxFont(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ForEach(effectiveRules.prefix(4)) { rule in
                    HStack(spacing: 5) {
                        appIconView(bundleIdentifier: rule.bundleIdentifier, size: 14)
                        Text(rule.appName)
                            .toolboxFont(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                }
                if effectiveRules.count > 4 {
                    Text("+\(effectiveRules.count - 4)")
                        .toolboxFont(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }
            }
        }
    }

    private func profileCardShortcutControl(profile: WorkspaceProfile) -> some View {
        HStack(spacing: 8) {
            Text("Shortcut")
                .toolboxFont(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ShortcutRecorderView(
                shortcut: profile.shortcut,
                sourceID: "window_snapper.profile.\(profile.id)",
                registrationKey: "window_snapper.profile.\(profile.id)"
            ) { newShortcut in
                if let idx = configManager.config.windowSnapper.profiles.firstIndex(where: { $0.id == profile.id }) {
                    configManager.config.windowSnapper.profiles[idx].shortcut = newShortcut
                }
            }
        }
    }

    // MARK: - Visual Profile Draft Editor

    private func resolvedBuilderDisplay(for role: ProfileDisplayRole) -> (display: ConnectedDisplay, isPhysicallyConnected: Bool) {
        let roles = DisplayRegistry.assignLogicalRoles(
            for: displayRegistry.connectedDisplays,
            swapExternalDisplays: configManager.config.windowSnapper.swapExternalDisplays
        )
        if let matched = roles[role] {
            return (matched, true)
        }
        return (
            ConnectedDisplay(
                displayID: role == .main ? 1 : (role == .external1 ? 2 : 3),
                signature: DisplaySignature(
                    localizedName: "\(role.label) (Preview)",
                    arrangementIndex: role == .main ? 0 : (role == .external1 ? 1 : 2)
                ),
                frameAppKit: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrameAppKit: CGRect(x: 0, y: 0, width: 1920, height: 1055),
                frameAX: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                usableAppKit: CGRect(x: 0, y: 0, width: 1920, height: 1055),
                usableAX: CGRect(x: 0, y: 25, width: 1920, height: 1055),
                safeAreaInsets: SafeAreaInsets(),
                isMain: role == .main,
                primaryScreenHeight: 1080
            ),
            false
        )
    }

    @ViewBuilder
    private func profileDraftEditor(draft: WorkspaceProfile) -> some View {
        let variantCount = min(max(uiState.editingVariantDisplayCount, 1), draft.maxDisplayCount)
        let allowedRoles = ProfileDisplayRole.roles(forDisplayCount: variantCount)
        let activeRole = allowedRoles.contains(uiState.editingDisplayRole) ? uiState.editingDisplayRole : .main
        let builderTarget = resolvedBuilderDisplay(for: activeRole)
        let builderDisplay = builderTarget.display
        let activeVariant = draft.displayVariants.first(where: { $0.displayCount == variantCount })
            ?? ProfileDisplayVariant(displayCount: variantCount)
        let slotLayout = activeVariant.layout(for: activeRole)
        let activeLayout = slotLayout.asDisplayLayoutConfig(for: builderDisplay.signature)
        let resolvedZones = SnapGeometry.resolveZones(
            layout: activeLayout,
            usableAXRect: builderDisplay.usableAX,
            primaryScreenHeight: builderDisplay.primaryScreenHeight,
            gaps: configManager.config.windowSnapper.gaps
        )
        let editorTitle = uiState.isCreatingNewProfile
            ? "New Profile"
            : "Edit Profile: \(draft.name.isEmpty ? "Untitled" : draft.name)"

        FeatureSection(
            editorTitle,
            subtitle: "Choose a display setup, pick a layout, and click or drag apps into screen zones."
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    TextField(
                        "Workspace Name",
                        text: Binding(
                            get: { uiState.editingProfileDraft?.name ?? draft.name },
                            set: { uiState.editingProfileDraft?.name = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)

                    Spacer()

                    Button {
                        module.previewProfile(draft, duration: 3.0)
                    } label: {
                        Image(systemName: "eye")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Preview layout on screen (3s)")
                    .pointerCursor()

                    Button("Cancel") {
                        cancelEditingProfileDraft()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .pointerCursor()

                    Button {
                        saveEditingProfileDraft()
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .pointerCursor()

                    Button {
                        saveEditingProfileDraft(andApply: true)
                    } label: {
                        Label("Save & Apply", systemImage: "play.fill")
                    }
                    .buttonStyle(.toolboxProminent)
                    .controlSize(.regular)
                    .pointerCursor()
                }

                VStack(alignment: .leading, spacing: 10) {
                    TextField(
                        "Workspace Name",
                        text: Binding(
                            get: { uiState.editingProfileDraft?.name ?? draft.name },
                            set: { uiState.editingProfileDraft?.name = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)

                    HStack(spacing: 8) {
                        Spacer()
                        Button {
                            module.previewProfile(draft, duration: 3.0)
                        } label: {
                            Image(systemName: "eye")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help("Preview layout on screen (3s)")
                        .pointerCursor()

                        Button("Cancel") {
                            cancelEditingProfileDraft()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .pointerCursor()

                        Button {
                            saveEditingProfileDraft()
                        } label: {
                            Label("Save", systemImage: "checkmark")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .pointerCursor()

                        Button {
                            saveEditingProfileDraft(andApply: true)
                        } label: {
                            Label("Save & Apply", systemImage: "play.fill")
                        }
                        .buttonStyle(.toolboxProminent)
                        .controlSize(.regular)
                        .pointerCursor()
                    }
                }
            }

            Divider()

            // Step 1: Unified Display Setup Views Cards (1, 2, 3 Displays)
            let connectedCount = max(displayRegistry.connectedDisplays.count, 1)
            let currentMatchedCount = min(connectedCount, draft.maxDisplayCount)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("1. Display Setup Views")
                        .toolboxFont(.callout.weight(.semibold))
                    Text("Pick which view to edit, or add 2- and 3-display layouts.")
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                ToolboxAdaptiveCardGrid(wideColumns: 3, narrowColumns: 1, wideMinWidth: 520, spacing: 10) {
                    ForEach(1...3, id: \.self) { count in
                        let isEnabled = count <= draft.maxDisplayCount
                        let isSelected = isEnabled && variantCount == count
                        let isCurrentSetup = isEnabled && count == currentMatchedCount
                        let variant = draft.displayVariants.first(where: { $0.displayCount == count })
                        let appCount = variant.map { ProfileDisplayVariant.deduplicatedRules($0.appRules).count } ?? 0
                        let mainPresetLabel = variant?.layout(for: .main).presetKind.label ?? "Halves"

                        ProfileVariantSelectionCard(
                            displayCount: count,
                            isEnabled: isEnabled,
                            isSelected: isSelected,
                            isCurrentSetup: isCurrentSetup,
                            canRemove: isEnabled && count == draft.maxDisplayCount && count > 1,
                            appCount: appCount,
                            mainPresetLabel: mainPresetLabel,
                            accentColor: module.accentColor,
                            onSelect: {
                                if !isEnabled {
                                    guard var current = uiState.editingProfileDraft else { return }
                                    current.maxDisplayCount = count
                                    current.ensureVariantsUpToMaxDisplayCount()
                                    uiState.editingProfileDraft = current
                                }
                                uiState.editingVariantDisplayCount = count
                                let nextRoles = ProfileDisplayRole.roles(forDisplayCount: count)
                                if !nextRoles.contains(uiState.editingDisplayRole) {
                                    uiState.editingDisplayRole = .main
                                }
                            },
                            onRemove: {
                                guard var current = uiState.editingProfileDraft else { return }
                                let nextMax = max(1, count - 1)
                                current.maxDisplayCount = nextMax
                                current.ensureVariantsUpToMaxDisplayCount()
                                uiState.editingProfileDraft = current
                                if uiState.editingVariantDisplayCount > nextMax {
                                    uiState.editingVariantDisplayCount = nextMax
                                }
                                let nextRoles = ProfileDisplayRole.roles(forDisplayCount: uiState.editingVariantDisplayCount)
                                if !nextRoles.contains(uiState.editingDisplayRole) {
                                    uiState.editingDisplayRole = .main
                                }
                            }
                        )
                    }
                }
            }

            if variantCount > 1 {
                Divider()

                let rolesMap = DisplayRegistry.assignLogicalRoles(
                    for: displayRegistry.connectedDisplays,
                    swapExternalDisplays: configManager.config.windowSnapper.swapExternalDisplays
                )
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("2. Select Screen to Configure")
                            .toolboxFont(.callout.weight(.semibold))
                        Spacer()
                        if displayRegistry.connectedDisplays.count >= 2 {
                            Button {
                                module.identifyDisplays()
                            } label: {
                                Label("Identify", systemImage: "viewfinder")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointerCursor()
                        }
                        if variantCount == 3 {
                            Button {
                                module.swapExternalDisplays()
                            } label: {
                                Label("Swap External 1 & 2", systemImage: "arrow.left.arrow.right")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointerCursor()
                        }
                    }

                    ToolboxAdaptiveCardGrid(
                        wideColumns: variantCount == 2 ? 2 : 3,
                        narrowColumns: 1,
                        wideMinWidth: 460,
                        spacing: 10
                    ) {
                        ForEach(allowedRoles) { role in
                            let roleLayout = activeVariant.layout(for: role)
                            let roleAppCount = activeVariant.appRules.filter {
                                $0.enabled && ruleMatchesRole($0.targetDisplay, role: role)
                            }.count
                            let connectedName = rolesMap[role]?.signature.localizedName

                            ProfileMonitorSelectorCard(
                                role: role,
                                preset: roleLayout.presetKind,
                                connectedDisplayName: connectedName,
                                appCount: roleAppCount,
                                isSelected: activeRole == role,
                                accentColor: module.accentColor
                            ) {
                                uiState.editingDisplayRole = role
                            }
                        }
                    }
                }
            }

            Divider()

            // Step 3: Interactive Template Squares Canvas + Auto-Collapsing Layout Switcher + Drag Tray
            VStack(alignment: .leading, spacing: 10) {
                let assignedCount = resolvedZones.filter { zone in
                    matchingRuleIndex(in: draft, variantCount: variantCount, role: activeRole, for: zone.id) != nil
                }.count

                let layoutToggleBtn = Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        uiState.showProfileTemplatePicker.toggle()
                    }
                } label: {
                    Label(
                        uiState.showProfileTemplatePicker ? "Done" : "Layout: \(activeLayout.presetKind.label)",
                        systemImage: uiState.showProfileTemplatePicker ? "chevron.up" : "rectangle.3.group"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .pointerCursor()

                let toolsMenu = Menu {
                    Button {
                        module.captureOpenWindowsForVariant(displayCount: variantCount) { captured in
                            guard var current = uiState.editingProfileDraft else { return }
                            current.ensureVariantsUpToMaxDisplayCount()
                            if let vIdx = current.displayVariants.firstIndex(where: { $0.displayCount == variantCount }) {
                                current.displayVariants[vIdx] = captured
                            }
                            if variantCount == 1 {
                                current.appRules = captured.appRules
                            }
                            uiState.editingProfileDraft = current
                            HUDToast.shared.show(
                                title: "Captured Open Windows",
                                subtitle: "\(captured.appRules.count) app\(captured.appRules.count == 1 ? "" : "s") assigned",
                                symbol: "camera.viewfinder",
                                tint: .green
                            )
                        }
                    } label: {
                        Label("Capture Open Windows", systemImage: "camera.viewfinder")
                    }

                    Button {
                        let copied = DisplayRegistry.layout(
                            for: builderDisplay.signature,
                            in: configManager.config.windowSnapper.displayLayouts
                        ) ?? DisplayLayoutConfig(display: builderDisplay.signature)
                        applyLayoutToDraft(copied, variantCount: variantCount, role: activeRole, on: builderDisplay)
                        HUDToast.shared.show(
                            title: "Copied Layout",
                            subtitle: copied.presetKind.label,
                            symbol: "rectangle.3.group",
                            tint: .indigo
                        )
                    } label: {
                        Label("Copy from Display Zones", systemImage: "rectangle.3.group")
                    }

                    Button {
                        module.beginOnScreenLayoutEditor(
                            for: builderDisplay,
                            initialLayout: activeLayout
                        ) { updated in
                            applyLayoutToDraft(updated, variantCount: variantCount, role: activeRole, on: builderDisplay)
                        }
                    } label: {
                        Label("Adjust Dividers on Screen", systemImage: "slider.horizontal.3")
                    }
                    .disabled(!builderTarget.isPhysicallyConnected)

                    if assignedCount > 0 {
                        Divider()
                        Button(role: .destructive) {
                            clearAllDraftRules(variantCount: variantCount, role: activeRole)
                        } label: {
                            Label("Clear All Apps", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderedButton)
                .controlSize(.regular)
                .fixedSize()
                .pointerCursor()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(variantCount > 1 ? "3. Assign Apps (\(activeRole.label))" : "2. Assign Apps & Layout")
                            .toolboxFont(.callout.weight(.semibold))
                        StatusBadge(
                            text: "\(assignedCount) of \(resolvedZones.count) filled",
                            color: assignedCount > 0 ? module.accentColor : .secondary
                        )
                        Spacer()
                        layoutToggleBtn
                        toolsMenu
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(variantCount > 1 ? "3. Assign Apps (\(activeRole.label))" : "2. Assign Apps & Layout")
                                .toolboxFont(.callout.weight(.semibold))
                            StatusBadge(
                                text: "\(assignedCount) of \(resolvedZones.count) filled",
                                color: assignedCount > 0 ? module.accentColor : .secondary
                            )
                        }
                        HStack(spacing: 8) {
                            layoutToggleBtn
                            toolsMenu
                        }
                    }
                }

                if uiState.showProfileTemplatePicker {
                    VStack(alignment: .leading, spacing: 10) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                Text("Pick a Layout Template")
                                    .toolboxFont(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                ToolboxSegmentedControl(
                                    options: Array(ProfileTemplateFilterCount.allCases),
                                    selection: $uiState.profileTemplateFilter,
                                    accentColor: module.accentColor,
                                    label: { $0.label }
                                )
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                ToolboxSegmentedControl(
                                    options: Array(ProfileTemplateFilterCount.allCases),
                                    selection: $uiState.profileTemplateFilter,
                                    accentColor: module.accentColor,
                                    label: { $0.label }
                                )
                            }
                        }

                        let filteredTemplates = DisplayPresetKind.builtInTemplates.filter {
                            uiState.profileTemplateFilter.matches($0)
                        }
                        ToolboxAdaptiveCardGrid(wideColumns: 4, narrowColumns: 2, wideMinWidth: 520, spacing: 8) {
                            ForEach(filteredTemplates) { preset in
                                TemplateDiagramCard(
                                    preset: preset,
                                    accentColor: module.accentColor,
                                    isSelected: activeLayout.presetID == preset.rawValue
                                ) {
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        applyTemplateToDraft(preset, variantCount: variantCount, role: activeRole, on: builderDisplay)
                                        uiState.showProfileTemplatePicker = false
                                    }
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }

                profileDraftSquaresCanvas(
                    draft: draft,
                    variantCount: variantCount,
                    role: activeRole,
                    display: builderDisplay,
                    zones: resolvedZones
                )

                if !runningRegularApps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Drag an app onto a zone above, or click any zone to choose.")
                            .toolboxFont(.caption2)
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(runningRegularApps, id: \.processIdentifier) { app in
                                    if let bid = app.bundleIdentifier {
                                        let appName = app.localizedName ?? bid
                                        HStack(spacing: 5) {
                                            appIconView(bundleIdentifier: bid, size: 14)
                                            Text(appName)
                                                .toolboxFont(.caption.weight(.medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(Color.primary.opacity(0.05), in: Capsule())
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                                        )
                                        .onDrag {
                                            NSItemProvider(object: "toolbox-app::\(bid)::\(appName)" as NSString)
                                        }
                                        .pointerCursor()
                                    }
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
            }

            Divider()

            // Step 4: Collapsible Behavior & Options (Progressive Disclosure)
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        uiState.showProfileBehaviorOptions.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: uiState.showProfileBehaviorOptions ? "chevron.down" : "chevron.right")
                            .toolboxFont(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Text("Behavior & Options")
                            .toolboxFont(.callout.weight(.semibold))
                        Spacer()
                        if !uiState.showProfileBehaviorOptions {
                            HStack(spacing: 6) {
                                if !draft.shortcut.isEmpty {
                                    ShortcutPill(text: draft.shortcut.displayString)
                                }
                                if uiState.draftAutoApplyOnConnect {
                                    StatusBadge(text: "Auto-Apply", color: .teal)
                                }
                                if draft.hideUnlistedApps {
                                    StatusBadge(text: "Hide Others", color: module.accentColor)
                                }
                                if draft.shortcut.isEmpty && !uiState.draftAutoApplyOnConnect && !draft.hideUnlistedApps {
                                    StatusBadge(text: "Default", color: .secondary)
                                }
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerCursor()

                if uiState.showProfileBehaviorOptions {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingRow("Global shortcut", subtitle: "Apply or toggle this profile from anywhere.") {
                            ShortcutRecorderView(
                                shortcut: draft.shortcut,
                                sourceID: "window_snapper.profile.\(draft.id)",
                                registrationKey: "window_snapper.profile.\(draft.id)"
                            ) { newShortcut in
                                uiState.editingProfileDraft?.shortcut = newShortcut
                            }
                        }

                        Divider()

                        restoreProfileShortcutSettingRow

                        Divider()

                        SettingRow(
                            "Hide other apps",
                            subtitle: "Hide unlisted apps when applying this profile. Assigned apps launch automatically if closed."
                        ) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { uiState.editingProfileDraft?.hideUnlistedApps ?? draft.hideUnlistedApps },
                                    set: { uiState.editingProfileDraft?.hideUnlistedApps = $0 }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                            .pointerCursor()
                        }

                        Divider()

                        SettingRow(
                            "Auto-apply on display connect",
                            subtitle: "Automatically apply this profile's matching layout whenever monitors connect or disconnect."
                        ) {
                            Toggle("", isOn: $uiState.draftAutoApplyOnConnect)
                                .labelsHidden()
                                .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                                .pointerCursor()
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func profileDraftSquaresCanvas(
        draft: WorkspaceProfile,
        variantCount: Int,
        role: ProfileDisplayRole,
        display: ConnectedDisplay,
        zones: [ResolvedZone]
    ) -> some View {
        let canvasHeight: CGFloat = zones.count >= 6 ? 256 : 240
        let compactSquare = zones.count >= 4

        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color.white.opacity(0.28)).frame(width: 5, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.22)).frame(width: 24, height: 4)
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.14)).frame(width: 18, height: 4)
                Spacer()
                let headerTitle = display.signature.localizedName.hasPrefix(role.label)
                    ? display.signature.localizedName
                    : "\(role.label) · \(display.signature.localizedName)"
                Text(headerTitle)
                    .toolboxFont(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .frame(height: 18)
            .background(Color.black.opacity(0.35))

            GeometryReader { geo in
                let canvasW = geo.size.width
                let canvasH = geo.size.height

                ZStack(alignment: .topLeading) {
                    Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.14, alpha: 1.0))

                    ForEach(zones) { zone in
                        let nx = (zone.frameInAX.minX - display.usableAX.minX) / max(1, display.usableAX.width)
                        let ny = (zone.frameInAX.minY - display.usableAX.minY) / max(1, display.usableAX.height)
                        let nw = zone.frameInAX.width / max(1, display.usableAX.width)
                        let nh = zone.frameInAX.height / max(1, display.usableAX.height)
                        let w = max(60, nw * canvasW)
                        let h = max(54, nh * canvasH)
                        let matchedIdx = matchingRuleIndex(in: draft, variantCount: variantCount, role: role, for: zone.id)
                        let variantRules = draft.displayVariants.first(where: { $0.displayCount == variantCount })?.appRules ?? []
                        let assignedRule = matchedIdx.map { variantRules[$0] }

                        InteractiveTemplateSquareButton(
                            zone: zone,
                            rule: assignedRule,
                            compact: compactSquare,
                            accentColor: module.accentColor,
                            width: w,
                            height: h,
                            runningApps: runningRegularApps,
                            installedApps: uiState.installedApps,
                            onAssignApp: { bid, name in
                                assignAppToDraftSquare(
                                    bundleIdentifier: bid,
                                    appName: name,
                                    zone: zone,
                                    variantCount: variantCount,
                                    role: role
                                )
                            },
                            onPickFromFinder: {
                                pickAppForDraftSquare(zone: zone, variantCount: variantCount, role: role)
                            },
                            onClear: {
                                removeDraftRule(zoneID: zone.id, variantCount: variantCount, role: role)
                            },
                            onDropZoneSwap: { sourceZoneID in
                                swapOrMoveDraftRule(
                                    fromZoneID: sourceZoneID,
                                    toZone: zone,
                                    variantCount: variantCount,
                                    role: role
                                )
                            }
                        )
                        .offset(x: nx * canvasW, y: ny * canvasH)
                    }
                }
            }
            .frame(height: canvasHeight)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
        )
    }

    private func ruleMatchesRole(_ ruleTarget: ProfileTargetDisplay, role: ProfileDisplayRole) -> Bool {
        switch (ruleTarget, role) {
        case (.main, .main):
            return true
        case (.externalSlot(0), .external1), (.anyExternal, .external1):
            return true
        case (.externalSlot(1), .external2):
            return true
        default:
            return false
        }
    }

    private func matchingRuleIndex(
        in profile: WorkspaceProfile,
        variantCount: Int,
        role: ProfileDisplayRole,
        for zoneID: String
    ) -> Int? {
        guard let variant = profile.displayVariants.first(where: { $0.displayCount == variantCount }) else {
            return nil
        }
        return variant.appRules.firstIndex { rule in
            rule.enabled
                && rule.targetZoneID == zoneID
                && ruleMatchesRole(rule.targetDisplay, role: role)
        }
    }

    private func assignAppToDraftSquare(
        bundleIdentifier: String,
        appName: String,
        zone: ResolvedZone,
        variantCount: Int,
        role: ProfileDisplayRole
    ) {
        guard var draft = uiState.editingProfileDraft else { return }
        draft.ensureVariantsUpToMaxDisplayCount()
        guard let vIdx = draft.displayVariants.firstIndex(where: { $0.displayCount == variantCount }) else { return }
        draft.displayVariants[vIdx].appRules.removeAll { rule in
            rule.targetZoneID == zone.id && ruleMatchesRole(rule.targetDisplay, role: role)
        }
        let rule = ProfileAppRule(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            targetDisplay: role.targetDisplay,
            targetZoneID: zone.id,
            fallbackRect: zone.normalizedRect,
            windowPolicy: .frontmost,
            launchIfNotRunning: true
        )
        draft.displayVariants[vIdx].appRules.append(rule)
        if variantCount == 1 {
            draft.appRules = draft.displayVariants[vIdx].appRules
        }
        uiState.editingProfileDraft = draft
    }

    private func removeDraftRule(
        zoneID: String,
        variantCount: Int,
        role: ProfileDisplayRole
    ) {
        guard var draft = uiState.editingProfileDraft else { return }
        guard let vIdx = draft.displayVariants.firstIndex(where: { $0.displayCount == variantCount }) else { return }
        draft.displayVariants[vIdx].appRules.removeAll { rule in
            rule.targetZoneID == zoneID && ruleMatchesRole(rule.targetDisplay, role: role)
        }
        if variantCount == 1 {
            draft.appRules = draft.displayVariants[vIdx].appRules
        }
        uiState.editingProfileDraft = draft
    }

    private func swapOrMoveDraftRule(
        fromZoneID: String,
        toZone: ResolvedZone,
        variantCount: Int,
        role: ProfileDisplayRole
    ) {
        guard fromZoneID != toZone.id,
              var draft = uiState.editingProfileDraft else { return }
        draft.ensureVariantsUpToMaxDisplayCount()
        guard let vIdx = draft.displayVariants.firstIndex(where: { $0.displayCount == variantCount }) else { return }
        guard let srcIdx = draft.displayVariants[vIdx].appRules.firstIndex(where: {
            $0.enabled && $0.targetZoneID == fromZoneID && ruleMatchesRole($0.targetDisplay, role: role)
        }) else { return }

        if let dstIdx = draft.displayVariants[vIdx].appRules.firstIndex(where: {
            $0.enabled && $0.targetZoneID == toZone.id && ruleMatchesRole($0.targetDisplay, role: role)
        }) {
            let srcFallback = draft.displayVariants[vIdx].appRules[srcIdx].fallbackRect
            draft.displayVariants[vIdx].appRules[srcIdx].targetZoneID = toZone.id
            draft.displayVariants[vIdx].appRules[srcIdx].fallbackRect = toZone.normalizedRect
            draft.displayVariants[vIdx].appRules[dstIdx].targetZoneID = fromZoneID
            draft.displayVariants[vIdx].appRules[dstIdx].fallbackRect = srcFallback
        } else {
            draft.displayVariants[vIdx].appRules[srcIdx].targetZoneID = toZone.id
            draft.displayVariants[vIdx].appRules[srcIdx].fallbackRect = toZone.normalizedRect
        }

        if variantCount == 1 {
            draft.appRules = draft.displayVariants[vIdx].appRules
        }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
            uiState.editingProfileDraft = draft
        }
    }

    private func clearAllDraftRules(variantCount: Int, role: ProfileDisplayRole) {
        guard var draft = uiState.editingProfileDraft else { return }
        guard let vIdx = draft.displayVariants.firstIndex(where: { $0.displayCount == variantCount }) else { return }
        draft.displayVariants[vIdx].appRules.removeAll { rule in
            ruleMatchesRole(rule.targetDisplay, role: role)
        }
        if variantCount == 1 {
            draft.appRules = draft.displayVariants[vIdx].appRules
        }
        uiState.editingProfileDraft = draft
    }

    private func applyTemplateToDraft(
        _ preset: DisplayPresetKind,
        variantCount: Int,
        role: ProfileDisplayRole,
        on display: ConnectedDisplay
    ) {
        let layout = DisplayLayoutConfig(
            display: display.signature,
            presetID: preset.rawValue,
            division: preset.defaultDivision
        )
        applyLayoutToDraft(layout, variantCount: variantCount, role: role, on: display)
    }

    private func applyLayoutToDraft(
        _ sourceLayout: DisplayLayoutConfig,
        variantCount: Int,
        role: ProfileDisplayRole,
        on display: ConnectedDisplay
    ) {
        guard var draft = uiState.editingProfileDraft else { return }
        draft.ensureVariantsUpToMaxDisplayCount()
        guard let vIdx = draft.displayVariants.firstIndex(where: { $0.displayCount == variantCount }) else { return }

        let newSlot = ProfileDisplaySlotLayout(
            role: role,
            presetID: sourceLayout.presetID,
            division: sourceLayout.division,
            customZones: sourceLayout.customZones,
            outerMarginPoints: sourceLayout.outerMarginPoints,
            innerGapPoints: sourceLayout.innerGapPoints
        )
        if let sIdx = draft.displayVariants[vIdx].slotLayouts.firstIndex(where: { $0.role == role }) {
            draft.displayVariants[vIdx].slotLayouts[sIdx] = newSlot
        } else {
            draft.displayVariants[vIdx].slotLayouts.append(newSlot)
        }

        let newLayout = newSlot.asDisplayLayoutConfig(for: display.signature)
        let newZones = SnapGeometry.resolveZones(
            layout: newLayout,
            usableAXRect: display.usableAX,
            primaryScreenHeight: display.primaryScreenHeight,
            gaps: configManager.config.windowSnapper.gaps
        )
        let validIDs = Set(newZones.map(\.id))

        // Preserve any rules matching validIDs; remap orphaned rules on this screen onto open squares,
        // and drop any excess orphaned rules that no longer have a zone (e.g. Halves -> Maximized).
        var occupiedIDs = Set(
            draft.displayVariants[vIdx].appRules
                .filter { ruleMatchesRole($0.targetDisplay, role: role) && validIDs.contains($0.targetZoneID) }
                .map(\.targetZoneID)
        )
        let openZones = newZones.filter { !occupiedIDs.contains($0.id) }
        var nextOpenIdx = 0
        var orphanedIndicesToRemove: [Int] = []

        for idx in draft.displayVariants[vIdx].appRules.indices {
            guard ruleMatchesRole(draft.displayVariants[vIdx].appRules[idx].targetDisplay, role: role) else { continue }
            let zid = draft.displayVariants[vIdx].appRules[idx].targetZoneID
            if let matched = newZones.first(where: { $0.id == zid }) {
                draft.displayVariants[vIdx].appRules[idx].fallbackRect = matched.normalizedRect
            } else if nextOpenIdx < openZones.count {
                let targetZone = openZones[nextOpenIdx]
                nextOpenIdx += 1
                occupiedIDs.insert(targetZone.id)
                draft.displayVariants[vIdx].appRules[idx].targetZoneID = targetZone.id
                draft.displayVariants[vIdx].appRules[idx].fallbackRect = targetZone.normalizedRect
            } else {
                orphanedIndicesToRemove.append(idx)
            }
        }

        for idx in orphanedIndicesToRemove.reversed() {
            draft.displayVariants[vIdx].appRules.remove(at: idx)
        }
        draft.displayVariants[vIdx].appRules = ProfileDisplayVariant.deduplicatedRules(
            draft.displayVariants[vIdx].appRules
        )

        if variantCount == 1 && role == .main {
            draft.appRules = draft.displayVariants[vIdx].appRules
            if let firstOverrideIdx = draft.displayLayoutOverrides.firstIndex(where: {
                DisplayRegistry.matchDisplay(for: $0.display, among: [display.signature]) != nil
            }) {
                draft.displayLayoutOverrides[firstOverrideIdx] = newLayout
            } else {
                draft.displayLayoutOverrides = [newLayout]
            }
        }

        uiState.editingProfileDraft = draft
    }

    private func pickAppForDraftSquare(
        zone: ResolvedZone,
        variantCount: Int,
        role: ProfileDisplayRole
    ) {
        let panel = NSOpenPanel()
        panel.title = "Choose App for \(zone.name)"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier {
            let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            assignAppToDraftSquare(
                bundleIdentifier: bid,
                appName: appName,
                zone: zone,
                variantCount: variantCount,
                role: role
            )
        }
    }

    private func loadInstalledAppsAsync() {
        let selfBundleID = Bundle.main.bundleIdentifier?.lowercased()
        Task.detached(priority: .utility) {
            let searchDirs = [
                URL(fileURLWithPath: "/Applications"),
                URL(fileURLWithPath: "/Applications/Utilities"),
                URL(fileURLWithPath: "/System/Applications")
            ]
            var seen = Set<String>()
            var candidates: [InstalledAppCandidate] = []
            let fm = FileManager.default

            for dir in searchDirs {
                guard let urls = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for url in urls where url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                    guard let bundle = Bundle(url: url),
                          let bid = bundle.bundleIdentifier,
                          bid.lowercased() != selfBundleID,
                          seen.insert(bid.lowercased()).inserted else { continue }
                    let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? url.deletingPathExtension().lastPathComponent
                    candidates.append(InstalledAppCandidate(name: name, bundleIdentifier: bid, appURL: url))
                }
            }

            let sorted = candidates.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            await MainActor.run {
                uiState.installedApps = sorted
            }
        }
    }

    // MARK: - Tab 4: Shortcuts

    @ViewBuilder
    private var shortcutsAndHistoryTab: some View {
        let cfg = configManager.config.windowSnapper

        FeatureCardGridSection(
            "Shortcut Preset",
            subtitle: "Apply conflict-free Control + Option + Command chords or switch to classic Rectangle-style bindings."
        ) {
            ToolboxAdaptiveCardGrid(wideColumns: 3, narrowColumns: 1, wideMinWidth: 520, spacing: 10) {
                SelectableOptionCard(
                    title: WindowSnapperShortcutPreset.toolboxSafe.label,
                    subtitle: "Control + Option + Command chords designed to avoid macOS, Terminal, and IDE shortcut collisions.",
                    symbolName: "keyboard.badge.ellipsis",
                    accentColor: module.accentColor,
                    badge: "Conflict-Free",
                    isSelected: cfg.hotKeys == WindowSnapperHotKeys.toolboxSafe
                ) {
                    module.applyShortcutPreset(.toolboxSafe)
                }

                SelectableOptionCard(
                    title: WindowSnapperShortcutPreset.rectangleStyle.label,
                    subtitle: "Familiar Control + Option arrow keys, Return to maximize, and classic corner or display chords.",
                    symbolName: "rectangle.split.2x1",
                    accentColor: module.accentColor,
                    badge: "Classic",
                    isSelected: cfg.hotKeys == WindowSnapperHotKeys.rectangleStyle
                ) {
                    module.applyShortcutPreset(.rectangleStyle)
                }

                SelectableOptionCard(
                    title: WindowSnapperShortcutPreset.manual.label,
                    subtitle: "Start with empty shortcut slots so you can bind only the specific window placements you want.",
                    symbolName: "slider.horizontal.3",
                    accentColor: module.accentColor,
                    badge: "Unbound",
                    isSelected: cfg.hotKeys == WindowSnapperHotKeys.unbound
                ) {
                    module.applyShortcutPreset(.manual)
                }
            }
        }

        FeatureSection(
            "Keyboard Snapping Behavior",
            subtitle: "Hold shortcut modifiers to preview & cycle zones, release to snap, or press ⌫ Backspace to cancel."
        ) {
            SettingRow(
                "Enable keyboard shortcuts",
                subtitle: "Turn global window placement and display-hopping hotkeys on or off."
            ) {
                Toggle("", isOn: $configManager.config.windowSnapper.keyboardSnappingEnabled)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            Divider()

            SettingRow(
                "Cycle 1/2, 2/3, 1/3 on repeat press",
                subtitle: "Pressing Left, Right, Top, or Bottom repeatedly cycles sizes cleanly."
            ) {
                Toggle("", isOn: $configManager.config.windowSnapper.cycleRepeatedDirectionShortcuts)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            Divider()

            SettingRow(
                "Show snap confirmation toasts",
                subtitle: "Display a compact HUD pill naming the snapped window and target zone."
            ) {
                Toggle("", isOn: $configManager.config.windowSnapper.showSnapHUDToasts)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            Divider()

            SettingRow(
                "Center window size",
                subtitle: "Target screen fraction when invoking the Center shortcut."
            ) {
                HStack(spacing: 6) {
                    ForEach([(0.60, 0.72, "Compact 60×72%"), (0.70, 0.80, "Balanced 70×80%"), (0.82, 0.88, "Large 82×88%")], id: \.2) { w, h, label in
                        let isMatch = abs(cfg.centerWidthFraction - w) < 0.03 && abs(cfg.centerHeightFraction - h) < 0.03
                        ToolboxPresetChip(
                            label: label,
                            isSelected: isMatch,
                            accentColor: module.accentColor
                        ) {
                            configManager.config.windowSnapper.centerWidthFraction = w
                            configManager.config.windowSnapper.centerHeightFraction = h
                            module.flashCenterSizePreview(widthFraction: w, heightFraction: h, label: label)
                        }
                        .help("Preview \(Int(round(w * 100)))% × \(Int(round(h * 100)))% centered window on screen")
                    }
                }
            }
        }

        FeatureSection(
            "Window Placement Shortcuts",
            subtitle: "Customize individual shortcuts by category. Collisions with other Toolbox modules or macOS are flagged inline."
        ) {
            if !cfg.keyboardSnappingEnabled {
                HStack(spacing: 8) {
                    StatusBadge(text: "Shortcuts Off", color: .orange)
                    Text("Turn on Enable keyboard shortcuts above to activate these bindings.")
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 2)
            }

            ToolboxSegmentedControl(
                options: Array(WindowSnapperShortcutCategory.allCases),
                selection: $uiState.shortcutCategory,
                accentColor: module.accentColor,
                isFullWidth: true,
                label: { $0.label }
            )

            ForEach(uiState.shortcutCategory.actions) { action in
                Divider()
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(module.accentColor.opacity(0.14))
                            .frame(width: 28, height: 28)
                        Image(systemName: action.symbolName)
                            .toolboxFont(.caption.weight(.semibold))
                            .foregroundStyle(ToolboxTheme.readableAccentText(for: module.accentColor))
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.label)
                            .toolboxFont(.callout.weight(.medium))
                        Text(actionSubtitle(for: action))
                            .toolboxFont(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    ShortcutRecorderView(
                        shortcut: cfg.hotKeys.shortcut(for: action),
                        defaultShortcut: WindowSnapperHotKeys.toolboxSafe.shortcut(for: action),
                        sourceID: action.sourceID,
                        registrationKey: action.registrationName
                    ) { newShortcut in
                        configManager.config.windowSnapper.hotKeys.setShortcut(newShortcut, for: action)
                    }
                }
                .opacity(cfg.keyboardSnappingEnabled ? 1.0 : 0.62)
            }
        }

        FeatureSection(
            "Workspace Profile Shortcuts",
            subtitle: "Bind global shortcuts to apply saved workspace profiles in one keystroke."
        ) {
            restoreProfileShortcutSettingRow

            Divider()

            if cfg.profiles.isEmpty {
                Text("No workspace profiles saved yet. Create a profile in the Profiles tab to assign a shortcut.")
                    .toolboxFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(cfg.profiles.enumerated()), id: \.element.id) { idx, profile in
                    if idx > 0 {
                        Divider()
                    }
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(module.accentColor.opacity(0.14))
                                .frame(width: 28, height: 28)
                            Image(systemName: profile.symbolName)
                                .toolboxFont(.caption.weight(.semibold))
                                .foregroundStyle(ToolboxTheme.readableAccentText(for: module.accentColor))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(profile.name)
                                    .toolboxFont(.callout.weight(.medium))
                                    .lineLimit(1)
                                if let firstOverride = profile.displayLayoutOverrides.first {
                                    StatusBadge(
                                        text: firstOverride.hasCustomDividerProportions
                                            ? "\(firstOverride.presetKind.label) · Adjusted"
                                            : firstOverride.presetKind.label,
                                        color: module.accentColor
                                    )
                                }
                            }
                            let effectiveShortcutRules = profile.effectiveAppRules(forDisplayCount: displayRegistry.connectedDisplays.count)
                            Text(
                                effectiveShortcutRules.isEmpty
                                    ? "Layout only"
                                    : "\(effectiveShortcutRules.count) app\(effectiveShortcutRules.count == 1 ? "" : "s") assigned"
                            )
                            .toolboxFont(.caption2)
                            .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        ShortcutRecorderView(
                            shortcut: profile.shortcut,
                            sourceID: "window_snapper.profile.\(profile.id)",
                            registrationKey: "window_snapper.profile.\(profile.id)"
                        ) { newShortcut in
                            if let targetIdx = configManager.config.windowSnapper.profiles.firstIndex(where: { $0.id == profile.id }) {
                                configManager.config.windowSnapper.profiles[targetIdx].shortcut = newShortcut
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var restoreProfileShortcutSettingRow: some View {
        SettingRow(
            "Press again to restore previous layout",
            subtitle: "First press (shortcut, Apply button, or status bar menu) opens this workspace; pressing it again returns windows and hidden apps to how they were before."
        ) {
            Toggle("", isOn: $configManager.config.windowSnapper.restorePreviousWorkspaceOnShortcutToggle)
                .labelsHidden()
                .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                .pointerCursor()
        }
    }

    private var runningRegularApps: [NSRunningApplication] {
        let selfBundleID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular
                    && $0.bundleIdentifier != nil
                    && $0.bundleIdentifier != selfBundleID
            }
            .sorted {
                ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
            }
    }

    @ViewBuilder
    private func appIconView(bundleIdentifier: String, size: CGFloat) -> some View {
        WindowSnapperAppIconView(bundleIdentifier: bundleIdentifier, size: size)
    }

    private func resolvedAppName(for bundleIdentifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              let bundle = Bundle(url: url) else {
            return nil
        }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func actionSubtitle(for action: WindowSnapperHotKeyAction) -> String {
        switch action {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf:
            return "Cycles 1/2, 2/3, 1/3 on repeated presses"
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return "Snaps window into display quadrant"
        case .maximize:
            return "Fills the usable display area edge-to-edge"
        case .center:
            return "Centers window using your configured size fraction"
        case .previousDisplay, .nextDisplay:
            return "Moves window to adjacent display preserving zone proportion"
        case .restorePreSnap:
            return "Returns focused window to its pre-snap frame"
        }
    }
}

// MARK: - Visual Template Diagram Card

@MainActor
private final class TemplateCardHoverState: ObservableObject {
    @Published var isHovered = false
}

private struct TemplateDiagramCard: View {
    let preset: DisplayPresetKind
    let accentColor: Color
    let isSelected: Bool
    let action: () -> Void

    @StateObject private var hoverState = TemplateCardHoverState()

    var body: some View {
        let readableAccent = ToolboxTheme.readableAccentText(for: accentColor)
        let radius: CGFloat = 10
        let isHighlighted = hoverState.isHovered

        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geo in
                    let pad: CGFloat = 5
                    let gap: CGFloat = 3
                    let availW = max(10, geo.size.width - pad * 2)
                    let availH = max(10, geo.size.height - pad * 2)
                    let rects = preset.templatePreviewRects

                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.14, alpha: 1.0)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)
                            )

                        ForEach(Array(rects.enumerated()), id: \.offset) { _, norm in
                            let leftGap: CGFloat = norm.x > 0.001 ? gap / 2.0 : 0
                            let rightGap: CGFloat = norm.maxX < 0.999 ? gap / 2.0 : 0
                            let topGap: CGFloat = norm.y > 0.001 ? gap / 2.0 : 0
                            let bottomGap: CGFloat = norm.maxY < 0.999 ? gap / 2.0 : 0

                            let x = pad + CGFloat(norm.x) * availW + leftGap
                            let y = pad + CGFloat(norm.y) * availH + topGap
                            let w = max(4, CGFloat(norm.width) * availW - leftGap - rightGap)
                            let h = max(4, CGFloat(norm.height) * availH - topGap - bottomGap)

                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(accentColor.opacity(isSelected ? 0.34 : (isHighlighted ? 0.24 : 0.16)))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(
                                            readableAccent.opacity(isSelected ? 0.92 : (isHighlighted ? 0.74 : 0.50)),
                                            lineWidth: 1
                                        )
                                )
                                .frame(width: w, height: h)
                                .offset(x: x, y: y)
                        }
                    }
                }
                .aspectRatio(16.0 / 9.5, contentMode: .fit)

                HStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preset.label)
                            .toolboxFont(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(preset.shortBadge)
                            .toolboxFont(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .toolboxFont(.system(size: 13, weight: .semibold))
                            .foregroundStyle(readableAccent)
                    } else {
                        Text("\(preset.zoneCount)")
                            .toolboxFont(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
                        isSelected
                            ? readableAccent.opacity(0.62)
                            : Color.primary.opacity(isHighlighted ? 0.22 : 0.10),
                        lineWidth: isSelected ? 1.25 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: radius))
        }
        .buttonStyle(ToolboxPressFeedbackButtonStyle(pressScale: 0.985, pressOpacity: 0.92))
        .focusEffectDisabled()
        .onHover { hoverState.isHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .animation(.easeOut(duration: 0.14), value: isHighlighted)
        .pointerCursor()
    }
}

private struct TopEdgeStripEditableTile: View {
    let slotTitle: String
    let preset: DisplayPresetKind?
    let isSelected: Bool
    let accentColor: Color
    let readableAccent: Color
    let onSelect: () -> Void
    let onClear: () -> Void

    @StateObject private var hoverState = TemplateCardHoverState()

    var body: some View {
        let isHovered = hoverState.isHovered

        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Button(action: onSelect) {
                    ZStack {
                        if let preset {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? accentColor.opacity(0.24) : Color.white.opacity(isHovered ? 0.12 : 0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(
                                            isSelected ? readableAccent : Color.white.opacity(isHovered ? 0.36 : 0.18),
                                            lineWidth: isSelected ? 2.0 : 0.75
                                        )
                                )
                                .shadow(color: isSelected ? accentColor.opacity(0.40) : .clear, radius: 6)

                            TemplateMiniThumbnailView(
                                preset: preset,
                                cellFill: isSelected ? accentColor.opacity(0.58) : Color.white.opacity(0.32),
                                cellStroke: isSelected ? Color.white.opacity(0.80) : Color.white.opacity(0.38),
                                padding: 5,
                                cellGap: 1.25
                            )
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? accentColor.opacity(0.12) : Color.white.opacity(isHovered ? 0.08 : 0.03))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(
                                            isSelected ? readableAccent : Color.white.opacity(isHovered ? 0.38 : 0.22),
                                            style: StrokeStyle(lineWidth: isSelected ? 1.75 : 1.0, dash: [3.5, 2.5])
                                        )
                                )
                            Image(systemName: "plus")
                                .toolboxFont(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isSelected ? readableAccent : Color.white.opacity(0.55))
                        }
                    }
                    .frame(width: 68, height: 42)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(ToolboxPressFeedbackButtonStyle(pressScale: 0.96, pressOpacity: 0.90))
                .focusEffectDisabled()
                .help(preset.map { "\(slotTitle): \($0.label) · Click to select" } ?? "\(slotTitle): Empty (Hidden) · Click to assign")
                .pointerCursor()

                if preset != nil && (isSelected || isHovered) {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .toolboxFont(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .background(Color.black.opacity(0.70), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide \(slotTitle)")
                    .offset(x: 4, y: -4)
                    .pointerCursor()
                }
            }
            .onHover { hoverState.isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isSelected)
            .animation(.easeOut(duration: 0.12), value: isHovered)

            Text(slotTitle)
                .toolboxFont(.system(size: 10, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? readableAccent : Color.white.opacity(0.62))
                .lineLimit(1)
        }
    }
}

private struct TopEdgeSlotTemplateCard: View {
    let preset: DisplayPresetKind
    let accentColor: Color
    let readableAccent: Color
    let isAssignedToSelectedSlot: Bool
    let otherSlotLabel: String?
    let action: () -> Void

    @StateObject private var hoverState = TemplateCardHoverState()

    var body: some View {
        let isHovered = hoverState.isHovered
        let radius: CGFloat = 9

        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                TemplateMiniThumbnailView(
                    preset: preset,
                    cellFill: isAssignedToSelectedSlot
                        ? accentColor.opacity(0.48)
                        : Color.white.opacity(isHovered ? 0.36 : 0.24),
                    cellStroke: isAssignedToSelectedSlot
                        ? readableAccent.opacity(0.95)
                        : Color.white.opacity(isHovered ? 0.56 : 0.36),
                    padding: 6,
                    cellGap: 1.5
                )
                .aspectRatio(16.0 / 9.5, contentMode: .fit)
                .background(
                    Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.14, alpha: 1.0)),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)
                )

                HStack(alignment: .center, spacing: 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preset.label)
                            .toolboxFont(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(preset.shortBadge)
                            .toolboxFont(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)

                    if isAssignedToSelectedSlot {
                        Image(systemName: "checkmark.circle.fill")
                            .toolboxFont(.system(size: 13, weight: .semibold))
                            .foregroundStyle(readableAccent)
                    } else if let otherSlotLabel {
                        Text(otherSlotLabel)
                            .toolboxFont(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                            .lineLimit(1)
                    } else {
                        Text("\(preset.zoneCount)")
                            .toolboxFont(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(
                                isAssignedToSelectedSlot
                                    ? accentColor.opacity(isHovered ? 0.16 : 0.12)
                                    : Color.primary.opacity(isHovered ? 0.06 : 0.025)
                            )
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        isAssignedToSelectedSlot
                            ? readableAccent.opacity(0.75)
                            : Color.primary.opacity(isHovered ? 0.24 : 0.10),
                        lineWidth: isAssignedToSelectedSlot ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(ToolboxPressFeedbackButtonStyle(pressScale: 0.985, pressOpacity: 0.92))
        .focusEffectDisabled()
        .onHover { hoverState.isHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: isAssignedToSelectedSlot)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .help(
            otherSlotLabel.map { "\(preset.label) · Currently in \($0) (click to swap)" }
                ?? "\(preset.label) · Click to assign"
        )
        .pointerCursor()
    }
}

// MARK: - Interactive Profile Template Square & App Picker Menu

@MainActor
private final class SquareMenuCallbackTarget: NSObject {
    let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func invoke(_ sender: Any?) {
        handler()
    }
}

@MainActor
private final class SquareMenuAnchorHolder: ObservableObject {
    @Published var isHovered = false
    @Published var isDropTargeted = false
    weak var anchorView: NSView?
    var activeTargets: [SquareMenuCallbackTarget] = []
}

private struct SquareMenuAnchorNSViewRepresentable: NSViewRepresentable {
    let onViewReady: @MainActor (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        Task { @MainActor in
            onViewReady(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in
            onViewReady(nsView)
        }
    }
}

private struct InteractiveTemplateSquareButton: View {
    let zone: ResolvedZone
    let rule: ProfileAppRule?
    let compact: Bool
    let accentColor: Color
    let width: CGFloat
    let height: CGFloat
    let runningApps: [NSRunningApplication]
    let installedApps: [InstalledAppCandidate]
    let onAssignApp: (String, String) -> Void
    let onPickFromFinder: () -> Void
    let onClear: () -> Void
    let onDropZoneSwap: (String) -> Void

    @StateObject private var state = SquareMenuAnchorHolder()

    var body: some View {
        let readableAccent = ToolboxTheme.readableAccentText(for: accentColor)
        let radius: CGFloat = 8
        let isHovered = state.isHovered
        let isDropTargeted = state.isDropTargeted
        let isShortSquare = compact || height < 140

        ZStack(alignment: .topTrailing) {
            Button {
                presentAppPickerMenu()
            } label: {
                ZStack(alignment: .topLeading) {
                    if let rule {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(accentColor.opacity(isDropTargeted ? 0.38 : (isHovered ? 0.30 : 0.22)))
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(
                                readableAccent.opacity(isDropTargeted ? 1.0 : (isHovered ? 1.0 : 0.88)),
                                lineWidth: isDropTargeted ? 2.2 : 1.5
                            )

                        HStack(spacing: 4) {
                            Text("\(zone.badgeNumber)")
                                .toolboxFont(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(accentColor.opacity(0.92), in: Circle())
                            Text(zone.name)
                                .toolboxFont(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.84))
                                .lineLimit(1)
                        }
                        .padding(.top, 7)
                        .padding(.leading, 8)
                        .padding(.trailing, 28)

                        VStack(spacing: isShortSquare ? 3 : 5) {
                            WindowSnapperAppIconView(bundleIdentifier: rule.bundleIdentifier, size: isShortSquare ? 28 : 36)
                            Text(rule.appName)
                                .toolboxFont(.system(size: compact ? 11.5 : 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if !isShortSquare {
                                Text("Click to change")
                                    .toolboxFont(.system(size: 10))
                                    .foregroundStyle(Color.white.opacity(0.62))
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.top, isShortSquare ? 20 : 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(isDropTargeted ? accentColor.opacity(0.18) : Color.white.opacity(isHovered ? 0.08 : 0.04))
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(
                                isDropTargeted ? readableAccent.opacity(0.95) : Color.white.opacity(isHovered ? 0.48 : 0.24),
                                style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.25, dash: isDropTargeted ? [] : [5, 4])
                            )

                        HStack(spacing: 4) {
                            Text("\(zone.badgeNumber)")
                                .toolboxFont(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.75))
                                .frame(width: 16, height: 16)
                                .background(Color.white.opacity(0.14), in: Circle())
                            Text(zone.name)
                                .toolboxFont(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.65))
                                .lineLimit(1)
                        }
                        .padding(.top, 7)
                        .padding(.leading, 8)

                        VStack(spacing: isShortSquare ? 4 : 6) {
                            Image(systemName: "plus.circle.fill")
                                .toolboxFont(.system(size: isShortSquare ? 18 : 22, weight: .medium))
                                .foregroundStyle(readableAccent.opacity(0.95))
                            Text("Choose App…")
                                .toolboxFont(.system(size: isShortSquare ? 11 : 12, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.86))
                                .lineLimit(1)
                        }
                        .padding(.top, isShortSquare ? 18 : 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: width, height: height)
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
            .buttonStyle(ToolboxPressFeedbackButtonStyle(pressScale: 0.99, pressOpacity: 0.94))
            .focusEffectDisabled()
            .onHover { state.isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .background(SquareMenuAnchorNSViewRepresentable { state.anchorView = $0 })
            .pointerCursor()

            if rule != nil {
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .toolboxFont(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .background(Color.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Clear app from \(zone.name)")
                .padding(7)
                .pointerCursor()
            }
        }
        .frame(width: width, height: height)
        .scaleEffect(isDropTargeted ? 1.015 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isDropTargeted)
        .onDrag {
            if rule != nil {
                return NSItemProvider(object: "toolbox-zone::\(zone.id)" as NSString)
            }
            return NSItemProvider()
        }
        .onDrop(of: [.plainText, .text], isTargeted: $state.isDropTargeted) { providers in
            guard let provider = providers.first(where: {
                $0.canLoadObject(ofClass: NSString.self)
            }) else {
                return false
            }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let payload = object as? String else { return }
                DispatchQueue.main.async {
                    if payload.hasPrefix("toolbox-app::") {
                        let parts = payload.components(separatedBy: "::")
                        if parts.count >= 3 {
                            let bid = parts[1]
                            let name = parts.dropFirst(2).joined(separator: "::")
                            onAssignApp(bid, name)
                        }
                    } else if payload.hasPrefix("toolbox-zone::") {
                        let sourceZoneID = String(payload.dropFirst("toolbox-zone::".count))
                        onDropZoneSwap(sourceZoneID)
                    }
                }
            }
            return true
        }
    }

    private func presentAppPickerMenu() {
        let menu = NSMenu(title: "Choose App")
        menu.appearance = ToolboxTheme.darkAppearance
        state.activeTargets.removeAll()

        let runningIDs = Set(runningApps.compactMap { $0.bundleIdentifier?.lowercased() })
        let otherInstalled = installedApps.filter { !runningIDs.contains($0.bundleIdentifier.lowercased()) }

        func addAppItem(title: String, bundleID: String, appURL: URL?) {
            let target = SquareMenuCallbackTarget {
                onAssignApp(bundleID, title)
            }
            state.activeTargets.append(target)
            let item = NSMenuItem(
                title: title,
                action: #selector(SquareMenuCallbackTarget.invoke(_:)),
                keyEquivalent: ""
            )
            item.target = target
            if let appURL {
                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                icon.size = NSSize(width: 18, height: 18)
                item.image = icon
            }
            if rule?.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame {
                item.state = .on
            }
            menu.addItem(item)
        }

        if !runningApps.isEmpty {
            let header = NSMenuItem(title: "Running Apps", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for app in runningApps {
                if let bid = app.bundleIdentifier {
                    addAppItem(title: app.localizedName ?? bid, bundleID: bid, appURL: app.bundleURL)
                }
            }
        }

        if !otherInstalled.isEmpty {
            if !runningApps.isEmpty {
                menu.addItem(.separator())
            }
            let header = NSMenuItem(title: "Installed Apps", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for candidate in otherInstalled {
                addAppItem(title: candidate.name, bundleID: candidate.bundleIdentifier, appURL: candidate.appURL)
            }
        }

        menu.addItem(.separator())

        let finderTarget = SquareMenuCallbackTarget { onPickFromFinder() }
        state.activeTargets.append(finderTarget)
        let finderItem = NSMenuItem(
            title: "Choose Application in Finder…",
            action: #selector(SquareMenuCallbackTarget.invoke(_:)),
            keyEquivalent: ""
        )
        finderItem.target = finderTarget
        menu.addItem(finderItem)

        if rule != nil {
            menu.addItem(.separator())
            let clearTarget = SquareMenuCallbackTarget { onClear() }
            state.activeTargets.append(clearTarget)
            let clearItem = NSMenuItem(
                title: "Clear Square",
                action: #selector(SquareMenuCallbackTarget.invoke(_:)),
                keyEquivalent: ""
            )
            clearItem.target = clearTarget
            menu.addItem(clearItem)
        }

        if let view = state.anchorView {
            let clickInView: NSPoint = {
                if let win = view.window {
                    let ptInWindow = win.convertPoint(fromScreen: NSEvent.mouseLocation)
                    let local = view.convert(ptInWindow, from: nil)
                    if view.bounds.contains(local) {
                        return local
                    }
                }
                return NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            }()
            menu.popUp(positioning: nil, at: clickInView, in: view)
        }
    }
}

private struct WindowSnapperAppIconView: View {
    let bundleIdentifier: String
    let size: CGFloat

    var body: some View {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.65))
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WindowAnimationPreviewStrip: View {
    let speed: WindowAnimationSpeed
    let tintColor: OverlayTintColor
    let accentColor: Color
    @ObservedObject var previewState: WindowAnimationPreviewState
    let onPlay: () -> Void

    var body: some View {
        let strokeColor = tintColor.readableStrokeColor
        let readableAccent = ToolboxTheme.readableAccentText(for: accentColor)

        let canvas = miniDesktopCanvas(strokeColor: strokeColor)
        let details = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(speed.isAnimated ? "\(speed.label) · \(String(format: "%.2f", speed.snapDuration))s glide" : "Off · Instant snap")
                    .toolboxFont(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                StatusBadge(text: previewState.currentPoseLabel, color: accentColor)
            }

            Text("Click any speed preset above or press Play to compare how windows expand and glide between zones.")
                .toolboxFont(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(readableAccent)
            .pointerCursor()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                canvas
                details
            }

            VStack(alignment: .leading, spacing: 10) {
                canvas
                details
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
    }

    private func miniDesktopCanvas(strokeColor: Color) -> some View {
        let winRect: CGRect = {
            switch previewState.pose {
            case 1:
                return CGRect(x: 5, y: 12, width: 94, height: 61)
            case 2:
                return CGRect(x: 105, y: 12, width: 94, height: 61)
            default:
                return CGRect(x: 56, y: 20, width: 92, height: 44)
            }
        }()

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.14, alpha: 1.0)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                )

            // Tiny simulated menu bar
            HStack(spacing: 4) {
                Circle().fill(Color.white.opacity(0.35)).frame(width: 4, height: 4)
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.22)).frame(width: 16, height: 3)
                Spacer()
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.22)).frame(width: 20, height: 3)
            }
            .padding(.horizontal, 6)
            .frame(height: 8)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            // Left / Right snap target guides
            ForEach([(1, CGFloat(5)), (2, CGFloat(105))], id: \.0) { poseIdx, xPos in
                let isTarget = (previewState.pose == poseIdx)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isTarget ? strokeColor.opacity(0.55) : Color.white.opacity(0.14),
                        style: StrokeStyle(lineWidth: 0.75, dash: [3, 2])
                    )
                    .frame(width: 94, height: 61)
                    .offset(x: xPos, y: 12)
            }

            // Animated mini window card
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 2.5) {
                    Circle().fill(Color.red.opacity(0.85)).frame(width: 3.5, height: 3.5)
                    Circle().fill(Color.yellow.opacity(0.85)).frame(width: 3.5, height: 3.5)
                    Circle().fill(Color.green.opacity(0.85)).frame(width: 3.5, height: 3.5)
                    Spacer()
                }
                .padding(.horizontal, 5)
                .frame(height: 10)
                .background(Color.white.opacity(0.07))

                Spacer(minLength: 0)
            }
            .frame(width: winRect.width, height: winRect.height)
            .background(Color(nsColor: NSColor(calibratedRed: 0.17, green: 0.20, blue: 0.29, alpha: 1.0)))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(strokeColor.opacity(0.88), lineWidth: 1.25)
            )
            .shadow(color: accentColor.opacity(0.28), radius: 5, y: 2)
            .offset(x: winRect.minX, y: winRect.minY)
        }
        .frame(width: 204, height: 78)
        .clipped()
    }
}

private struct ProfileVariantSelectionCard: View {
    let displayCount: Int
    let isEnabled: Bool
    let isSelected: Bool
    let isCurrentSetup: Bool
    let canRemove: Bool
    let appCount: Int
    let mainPresetLabel: String
    let accentColor: Color
    let onSelect: () -> Void
    let onRemove: () -> Void

    @StateObject private var hoverState = TemplateCardHoverState()

    var body: some View {
        let readableAccent = ToolboxTheme.readableAccentText(for: accentColor)
        let title = displayCount == 1 ? "1 Display" : "\(displayCount) Displays"
        let isHovered = hoverState.isHovered

        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                if isEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: displayCount == 1 ? "display" : "display.2")
                                .toolboxFont(.caption.weight(.semibold))
                                .foregroundStyle(isSelected ? readableAccent : .secondary)
                            Text(title)
                                .toolboxFont(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            if isCurrentSetup {
                                StatusBadge(text: "Current", color: .green)
                            }
                        }

                        Text(appCount == 0 ? "\(mainPresetLabel) · No apps" : "\(mainPresetLabel) · \(appCount) app\(appCount == 1 ? "" : "s")")
                            .toolboxFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        isSelected
                            ? accentColor.opacity(0.14)
                            : Color.primary.opacity(isHovered ? 0.055 : 0.03),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isSelected
                                    ? readableAccent.opacity(0.85)
                                    : Color.primary.opacity(isHovered ? 0.22 : 0.10),
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .toolboxFont(.caption.weight(.semibold))
                                .foregroundStyle(readableAccent)
                            Text("Add \(title)")
                                .toolboxFont(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }

                        Text("Configure layout for \(displayCount) screens")
                            .toolboxFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.primary.opacity(isHovered ? 0.045 : 0.02),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                Color.primary.opacity(isHovered ? 0.34 : 0.18),
                                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                            )
                    )
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { hoverState.isHovered = $0 }
            .animation(.easeOut(duration: 0.14), value: isSelected)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .pointerCursor()

            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .toolboxFont(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove \(title) view")
                .padding(6)
                .pointerCursor()
            }
        }
    }
}

private struct ProfileMonitorSelectorCard: View {
    let role: ProfileDisplayRole
    let preset: DisplayPresetKind
    let connectedDisplayName: String?
    let appCount: Int
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    @StateObject private var hoverState = TemplateCardHoverState()

    var body: some View {
        let readableAccent = ToolboxTheme.readableAccentText(for: accentColor)
        let isHovered = hoverState.isHovered

        Button(action: action) {
            HStack(spacing: 10) {
                TemplateMiniThumbnailView(
                    preset: preset,
                    cellFill: isSelected ? accentColor.opacity(0.48) : Color.white.opacity(isHovered ? 0.32 : 0.24),
                    cellStroke: isSelected ? readableAccent.opacity(0.95) : Color.white.opacity(isHovered ? 0.54 : 0.40),
                    padding: 5,
                    cellGap: 1.5
                )
                .frame(width: 48, height: 32)
                .background(
                    Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.14, alpha: 1.0)),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(role.label)
                            .toolboxFont(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        StatusBadge(
                            text: appCount == 0 ? "Empty" : "\(appCount) app\(appCount == 1 ? "" : "s")",
                            color: appCount > 0 ? accentColor : .secondary
                        )
                    }

                    Text(connectedDisplayName ?? "Not connected · Preview")
                        .toolboxFont(.caption2)
                        .foregroundStyle(connectedDisplayName != nil ? .secondary : .tertiary)
                        .lineLimit(1)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? accentColor.opacity(0.13)
                    : Color.primary.opacity(isHovered ? 0.055 : 0.03),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? readableAccent.opacity(0.85)
                            : Color.primary.opacity(isHovered ? 0.22 : 0.09),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hoverState.isHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .pointerCursor()
    }
}
