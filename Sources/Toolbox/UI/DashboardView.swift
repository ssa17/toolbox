import SwiftUI

enum DashboardLayoutMetrics: Sendable {
    static let twoColumnMinWidth: CGFloat = 520
    static let threeColumnMinWidth: CGFloat = 810

    static func columnCount(forAvailableWidth width: CGFloat) -> Int {
        if width >= threeColumnMinWidth {
            return 3
        }
        if width >= twoColumnMinWidth {
            return 2
        }
        return 1
    }

    static func gridSpacing(showDetails: Bool) -> CGFloat {
        showDetails ? 14 : 18
    }
}

struct DashboardView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var registry = ModuleRegistry.shared
    @ObservedObject private var screenOCR = ModuleRegistry.shared.screenOCR
    @ObservedObject private var windowSnapper = ModuleRegistry.shared.windowSnapper
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onSelectModule: (String) -> Void

    private var toggleableModules: [any ToolboxModule] {
        registry.modules.filter(\.supportsEnableToggle)
    }

    private var activeCount: Int {
        toggleableModules.filter { $0.isEnabled(in: configManager.config) }.count
    }

    private var versionText: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(short)"
    }

    private var layoutAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.16)
            : .spring(duration: 0.32, bounce: 0.04)
    }

    var body: some View {
        let showDetails = configManager.config.general.showModuleCardDetails
        GeometryReader { proxy in
            let availableGridWidth = max(0, proxy.size.width - 44)
            let columnCount = DashboardLayoutMetrics.columnCount(forAvailableWidth: availableGridWidth)
            let gridSpacing = DashboardLayoutMetrics.gridSpacing(showDetails: showDetails)
            let rows = chunkedModules(registry.modules, intoColumns: columnCount)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerBanner

                    if !permissions.isAccessibilityGranted {
                        accessibilityBanner
                    } else if configManager.config.screenOCR.enabled && !screenOCR.screenRecordingGranted {
                        screenRecordingBanner
                    }

                    if configManager.config.windowSnapper.enabled
                        && configManager.config.windowSnapper.drag.enabled
                        && windowSnapper.sequoiaConflictStatus.hasConflictWithToolboxDrag {
                        windowTilingConflictBanner
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Text("Modules")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            DashboardDensityPicker(showDetails: showDetails) { newVal in
                                guard newVal != showDetails else { return }
                                withAnimation(layoutAnimation) {
                                    configManager.config.general.showModuleCardDetails = newVal
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: gridSpacing) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, rowModules in
                                HStack(alignment: .top, spacing: gridSpacing) {
                                    ForEach(rowModules, id: \.id) { module in
                                        DashboardModuleCard(
                                            module: module,
                                            config: configManager.config,
                                            accessibilityGranted: permissions.isAccessibilityGranted,
                                            showDetails: showDetails,
                                            reduceMotion: reduceMotion,
                                            enabledBinding: enabledBinding(for: module),
                                            onSelect: { onSelectModule(module.id) }
                                        )
                                        .id(module.id)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    }

                                    if rowModules.count < columnCount {
                                        ForEach(0..<(columnCount - rowModules.count), id: \.self) { _ in
                                            Color.clear
                                                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: 0)
                                        }
                                    }
                                }
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .animation(layoutAnimation, value: showDetails)
                }
                .padding(22)
            }
        }
        .onAppear {
            permissions.refresh()
            windowSnapper.refreshSequoiaConflictStatus()
        }
    }

    private func chunkedModules(_ modules: [any ToolboxModule], intoColumns columnCount: Int) -> [[any ToolboxModule]] {
        let size = max(1, columnCount)
        var rows: [[any ToolboxModule]] = []
        rows.reserveCapacity((modules.count + size - 1) / size)
        var index = 0
        while index < modules.count {
            let end = min(index + size, modules.count)
            rows.append(Array(modules[index..<end]))
            index = end
        }
        return rows
    }

    private var headerBanner: some View {
        let isAppEnabled = configManager.config.general.appEnabled
        return SectionCard(accentTint: isAppEnabled ? ToolboxTheme.accentBlue : .orange) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    headerBannerIcon
                    headerBannerText(isAppEnabled: isAppEnabled)
                    if !isAppEnabled {
                        Spacer(minLength: 8)
                        headerResumeButton
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        headerBannerIcon
                        headerBannerText(isAppEnabled: isAppEnabled)
                    }
                    if !isAppEnabled {
                        headerResumeButton
                    }
                }
            }
        }
    }

    private var headerBannerIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.18, blue: 0.22), Color(red: 0.08, green: 0.09, blue: 0.11)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 48, height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
            ToolboxBentoMark(size: 26, primaryColor: .white, accentColor: Color(red: 0.29, green: 0.62, blue: 1.0))
        }
    }

    private func headerBannerText(isAppEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text("Toolbox")
                        .font(.title2.bold())
                    headerBannerVersionPill
                    headerBannerStatusBadge(isAppEnabled: isAppEnabled)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Toolbox")
                            .font(.title2.bold())
                        headerBannerVersionPill
                    }
                    headerBannerStatusBadge(isAppEnabled: isAppEnabled)
                }
            }
            Text(
                isAppEnabled
                    ? "Lightweight, config-driven utilities tailored to how you use your Mac."
                    : "Toolbox is paused. Resume to reactivate your enabled modules."
            )
            .font(.callout)
            .foregroundStyle(Color.primary.opacity(0.76))
            .fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
    }

    private var headerBannerVersionPill: some View {
        Text(versionText)
            .font(.caption.monospaced())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private func headerBannerStatusBadge(isAppEnabled: Bool) -> some View {
        StatusBadge(
            text: isAppEnabled
                ? "\(activeCount)/\(toggleableModules.count) enabled"
                : "Paused",
            color: isAppEnabled
                ? (activeCount > 0 ? .green : .secondary)
                : .orange
        )
    }

    private var headerResumeButton: some View {
        Button("Resume") {
            configManager.config.general.appEnabled = true
        }
        .buttonStyle(.toolboxProminent(.orange))
        .fixedSize(horizontal: true, vertical: false)
        .pointerCursor()
    }

    private var accessibilityBanner: some View {
        SectionCard(accentTint: .orange) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.orange.opacity(0.16))
                            .frame(width: 40, height: 40)
                        Image(systemName: "hand.raised.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.orange)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                Text("Enable Accessibility for Input & Window Shortcuts")
                                    .font(.headline)
                                accessibilityBannerBadges
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Enable Accessibility for Input & Window Shortcuts")
                                    .font(.headline)
                                accessibilityBannerBadges
                            }
                        }

                        Text("Turn on Toolbox.app in Privacy & Security → Accessibility for Dock Minimize, Scroll Direction, Call Keybinds, Keyboard Lock, and Auto-Paste. Runs 100% locally.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)

                        if permissions.isAdHocSigned || permissions.hasAttemptedGrantWithoutSuccess {
                            Text("Already enabled in System Settings? Click Reset Permission to clear any stale entry and re-authorize.")
                                .font(.system(size: 12))
                                .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }
                    .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Spacer(minLength: 0)

                    if permissions.isAdHocSigned || permissions.hasAttemptedGrantWithoutSuccess {
                        Button {
                            permissions.resetAndRegrantAccessibility()
                        } label: {
                            Label(
                                permissions.isResettingAccessibility ? "Resetting…" : "Reset Permission",
                                systemImage: "arrow.counterclockwise"
                            )
                            .font(.callout.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .disabled(permissions.isResettingAccessibility)
                        .help("Re-bind Accessibility permission if already enabled in System Settings from an earlier build.")
                        .pointerCursor(!permissions.isResettingAccessibility)
                    }

                    Button {
                        permissions.presentOnboardingModal()
                    } label: {
                        Label("Why This Is Needed", systemImage: "questionmark.circle")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .pointerCursor()

                    Button {
                        permissions.promptAndOpenSettings()
                    } label: {
                        Label(
                            permissions.isAwaitingAccessibilityGrant ? "Open Settings…" : "Grant Access…",
                            systemImage: "hand.raised.fill"
                        )
                        .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.toolboxProminent(.orange))
                    .pointerCursor()
                }
            }
        }
    }

    @ViewBuilder
    private var accessibilityBannerBadges: some View {
        HStack(spacing: 6) {
            if configManager.config.screenOCR.enabled && !screenOCR.screenRecordingGranted {
                StatusBadge(text: "Step 1 of 2", color: .orange)
            }
            if permissions.isAwaitingAccessibilityGrant {
                StatusBadge(text: "Waiting for permission…", color: .orange)
            }
        }
    }

    private var screenRecordingBanner: some View {
        SectionCard(accentTint: .orange) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.orange.opacity(0.16))
                            .frame(width: 42, height: 42)
                        Image(systemName: "text.viewfinder")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.orange)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Enable Screen Recording for Screen OCR")
                                .font(.headline)
                            StatusBadge(
                                text: screenOCR.isAwaitingScreenPermission ? "Waiting for permission…" : "Step 2 of 2",
                                color: .orange
                            )
                        }
                        Text("Accessibility is active. Next, in System Settings → Privacy & Security → Screen & System Audio Recording, turn on Toolbox.app so Screen OCR can capture screen regions offline.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    Spacer(minLength: 0)

                    Button {
                        onSelectModule("screen_ocr")
                    } label: {
                        Label("Screen OCR Settings", systemImage: "slider.horizontal.3")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .pointerCursor()

                    Button {
                        if screenOCR.isAwaitingScreenPermission {
                            screenOCR.openScreenSettings()
                        } else {
                            screenOCR.requestScreenAccess()
                        }
                    } label: {
                        Label(
                            screenOCR.isAwaitingScreenPermission ? "Open Settings…" : "Grant Screen Access…",
                            systemImage: "text.viewfinder"
                        )
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.toolboxProminent(.orange))
                    .controlSize(.large)
                    .pointerCursor()
                }
            }
        }
    }

    private var windowTilingConflictBanner: some View {
        let count = windowSnapper.sequoiaConflictStatus.activeSettingLabels.count
        return SectionCard(accentTint: .orange) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("macOS Native Window Tiling Is Enabled")
                            .font(.headline)
                        Text("\(count) macOS Desktop & Dock tiling option\(count == 1 ? " is" : "s are") enabled. Turn \(count == 1 ? "it" : "them") off so Window Snapper handles every drag cleanly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Button("Desktop & Dock Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.toolboxProminent(.orange))
                    .controlSize(.regular)
                    .pointerCursor()
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("macOS Native Window Tiling Is Enabled")
                                .font(.headline)
                            Text("\(count) macOS Desktop & Dock tiling option\(count == 1 ? " is" : "s are") enabled. Turn \(count == 1 ? "it" : "them") off so Window Snapper handles every drag cleanly.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button("Desktop & Dock Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.toolboxProminent(.orange))
                    .controlSize(.regular)
                    .pointerCursor()
                }
            }
        }
    }

    private func enabledBinding(for module: any ToolboxModule) -> Binding<Bool> {
        Binding(
            get: { module.isEnabled(in: configManager.config) },
            set: { newVal in
                module.setEnabled(newVal, in: &configManager.config)
                if newVal && module.requiresAccessibility && !permissions.isAccessibilityGranted {
                    permissions.promptAndOpenSettings()
                }
            }
        )
    }
}

private struct DashboardDensityPicker: View {
    let showDetails: Bool
    let onSelect: (Bool) -> Void

    var body: some View {
        ToolboxSegmentedControl(
            options: [false, true],
            selection: Binding(
                get: { showDetails },
                set: { onSelect($0) }
            ),
            accentColor: ToolboxTheme.accentBlue,
            label: { $0 ? "Detailed" : "Compact" },
            symbol: { $0 ? "list.bullet.rectangle" : "rectangle.grid.2x2" },
            helpText: {
                $0
                    ? "Show module descriptions on Dashboard cards"
                    : "Hide descriptions for compact Dashboard cards"
            }
        )
    }
}

private final class DashboardCardHoverState: ObservableObject {
    @Published var isHovered = false
}

private struct CollapsibleHeightLayout: Layout {
    var progress: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else {
            return .zero
        }
        let clamped = min(max(progress, 0), 1)
        let natural = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(
            width: proposal.width ?? natural.width,
            height: natural.height * clamped
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let natural = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: natural.height)
        )
    }
}

private struct CollapsibleContainer<Content: View>: View, @MainActor Animatable {
    var progress: CGFloat
    let reduceMotion: Bool
    let content: Content

    init(
        progress: CGFloat,
        reduceMotion: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.progress = progress
        self.reduceMotion = reduceMotion
        self.content = content()
    }

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let clamped = min(max(progress, 0), 1)
        let textOpacity = Double(max(0, min(1, (clamped - 0.15) / 0.85)))
        let yOffset: CGFloat = reduceMotion ? 0 : (1 - clamped) * -4

        CollapsibleHeightLayout(progress: clamped) {
            content
                .opacity(textOpacity)
                .offset(y: yOffset)
        }
        .clipped()
        .allowsHitTesting(clamped > 0.5)
        .accessibilityHidden(clamped < 0.01)
    }
}

private struct CleanLockDashboardButton: View {
    @ObservedObject var cleanLock: CleanLockModule
    let durationSeconds: Int
    let isAppEnabled: Bool
    let accessibilityGranted: Bool

    var body: some View {
        let secs = CleanLockConfig.clampedDuration(durationSeconds)
        let durationLabel = secs >= 60 && secs % 60 == 0 ? "\(secs / 60)m" : "\(secs)s"
        let canLockNow = isAppEnabled && accessibilityGranted
        Button {
            _ = cleanLock.lock()
        } label: {
            Label(
                cleanLock.isLocked ? "\(cleanLock.remainingSeconds)s" : "Lock (\(durationLabel))",
                systemImage: cleanLock.isLocked ? "lock.fill" : "lock"
            )
            .font(.caption.weight(.semibold))
            .lineLimit(1)
        }
        .buttonStyle(.toolboxProminent(.red))
        .controlSize(.small)
        .disabled(!canLockNow)
        .fixedSize(horizontal: true, vertical: false)
        .help(!isAppEnabled ? "Resume Toolbox to lock input" : (!accessibilityGranted ? "Grant Accessibility to lock input" : "Lock keyboard & pointer for \(durationLabel)"))
        .pointerCursor(canLockNow)
    }
}

private struct DashboardModuleCard: View {
    let module: any ToolboxModule
    let config: ToolboxConfig
    let accessibilityGranted: Bool
    let showDetails: Bool
    let reduceMotion: Bool
    let enabledBinding: Binding<Bool>
    let onSelect: () -> Void

    @StateObject private var hoverState = DashboardCardHoverState()

    private var status: String {
        module.statusText(in: config, accessibilityGranted: accessibilityGranted)
    }

    private var badgeColor: Color {
        let isEnabled = module.isEnabled(in: config)
        let missingScreenPermission = (module as? ScreenOCRModule).map { !$0.screenRecordingGranted } ?? false
        if !isEnabled { return .secondary }
        if !config.general.appEnabled { return .orange }
        if module.requiresAccessibility && !accessibilityGranted { return .orange }
        if missingScreenPermission { return .orange }
        if !module.supportsEnableToggle {
            return module.isRunning ? .red : .blue
        }
        return .green
    }

    private var isModuleTinted: Bool {
        guard config.general.appEnabled else { return false }
        return module.supportsEnableToggle ? module.isEnabled(in: config) : module.isRunning
    }

    var body: some View {
        let isHighlighted = hoverState.isHovered
        let isTinted = isModuleTinted
        let shortcut = module.shortcutText(in: config)
        let compactStatusText = (shortcut != nil && status == "Needs Accessibility") ? "Needs Access" : status

        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(module.accentColor.opacity(isTinted ? (isHighlighted ? 0.22 : 0.17) : (isHighlighted ? 0.16 : 0.12)))
                            .frame(width: 30, height: 30)
                        Image(systemName: module.symbolName)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(
                                isTinted || isHighlighted
                                    ? ToolboxTheme.readableAccentText(for: module.accentColor)
                                    : ToolboxTheme.readableAccentText(for: module.accentColor).opacity(0.85)
                            )
                    }

                    Text(module.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear
                        .frame(width: module.supportsEnableToggle ? 44 : 88, height: 1)
                }
                .frame(minHeight: 30)

                CollapsibleContainer(progress: showDetails ? 1 : 0, reduceMotion: reduceMotion) {
                    Text(module.tagline)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(0.74))
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 9)
                        .padding(.bottom, 2)
                }

                Spacer(minLength: 12)

                HStack(alignment: .center, spacing: 6) {
                    StatusBadge(text: compactStatusText, color: badgeColor)
                        .help(status)

                    Spacer(minLength: 0)

                    if let shortcut {
                        ShortcutPill(text: shortcut)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            isHighlighted
                                ? ToolboxTheme.readableAccentText(for: module.accentColor)
                                : Color.secondary.opacity(0.55)
                        )
                        .offset(x: isHighlighted ? 2 : 0)
                        .animation(.easeOut(duration: 0.14), value: isHighlighted)
                }
                .frame(minHeight: 22)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, showDetails ? 15 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
                    .overlay(
                        RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                            .fill(
                                isTinted
                                    ? Color.clear
                                    : Color.primary.opacity(isHighlighted ? 0.055 : 0.025)
                            )
                    )
                    .overlay {
                        if isTinted {
                            RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            module.accentColor.opacity(isHighlighted ? 0.10 : 0.05),
                                            Color.primary.opacity(isHighlighted ? 0.03 : 0.01)
                                        ],
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
                        isTinted
                            ? module.accentColor.opacity(isHighlighted ? 0.44 : 0.22)
                            : Color.primary.opacity(isHighlighted ? 0.22 : 0.10),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius))
        }
        .buttonStyle(ToolboxPressFeedbackButtonStyle(pressScale: 0.99, pressOpacity: 0.93))
        .focusEffectDisabled()
        .overlay(alignment: .topTrailing) {
            Group {
                if module.supportsEnableToggle {
                    Toggle("", isOn: enabledBinding)
                        .labelsHidden()
                        .toggleStyle(StatusBarSwitchToggleStyle(onColor: .green))
                        .pointerCursor()
                } else if let cleanLock = module as? CleanLockModule {
                    CleanLockDashboardButton(
                        cleanLock: cleanLock,
                        durationSeconds: config.cleanLock.durationSeconds,
                        isAppEnabled: config.general.appEnabled,
                        accessibilityGranted: accessibilityGranted
                    )
                }
            }
            .padding(.top, showDetails ? 15 : 14)
            .padding(.trailing, 14)
        }
        .animation(.easeOut(duration: 0.14), value: isHighlighted)
        .onHover { hoverState.isHovered = $0 }
        .pointerCursor()
        .accessibilityElement(children: .contain)
    }
}

struct AccessibilityOnboardingModalView: View {
    @ObservedObject var permissions: PermissionsManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.orange.opacity(0.24), Color.accentColor.opacity(0.16)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 48, height: 48)
                        Image(systemName: "hand.raised.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Accessibility Access")
                            .font(.title3.bold())
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                            Text("100% Local · Zero Keystroke Logging · Zero Network Access")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ToolboxTheme.readableAccentText(for: .green))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    }

                    Spacer(minLength: 8)

                    Button {
                        permissions.dismissOnboardingModal(markSeen: true)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.08), in: Circle())
                            .menuRowHover(cornerRadius: 14)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .accessibilityLabel("Close")
                    .help("Close")
                    .pointerCursor()
                }

                Text("In System Settings → Privacy & Security → Device Control and Data Access (Accessibility), toggle on Toolbox.app to enable features that react to Dock clicks, scroll events, or global shortcuts:")
                    .font(.callout)
                    .foregroundStyle(Color.primary.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    onboardingFeatureRow(
                        symbol: "dock.rectangle",
                        tint: .blue,
                        title: "Window & Mouse Utilities",
                        detail: "Dock Click to Minimize, Scroll Direction inversion, and Keyboard Lock."
                    )
                    Divider()
                    onboardingFeatureRow(
                        symbol: "mic.fill",
                        tint: .green,
                        title: "Unified Call Keybinds",
                        detail: "Single Mic & Video shortcut across Teams, Zoom, Slack & Meet, plus Auto-Mute While Typing."
                    )
                    Divider()
                    onboardingFeatureRow(
                        symbol: "doc.on.clipboard",
                        tint: .teal,
                        title: "Clipboard Auto-Paste",
                        detail: "Automatically send ⌘ V into your active app when selecting a clipboard item."
                    )
                }
                .padding(14)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )

                Text("One toggle covers all Accessibility & Input Monitoring shortcuts. If Screen OCR is enabled, Toolbox will guide you to Screen Recording next.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button("Skip for Now") {
                        permissions.dismissOnboardingModal(markSeen: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()

                    Spacer()

                    Button("Grant Accessibility Access…") {
                        permissions.dismissOnboardingModal(markSeen: true)
                        permissions.promptAndOpenSettings()
                    }
                    .buttonStyle(.toolboxProminent(.orange))
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .pointerCursor()
                }
            }
            .padding(22)
        }
        .frame(maxWidth: 520, maxHeight: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func onboardingFeatureRow(
        symbol: String,
        tint: Color,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(tint.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
