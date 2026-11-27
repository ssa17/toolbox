import SwiftUI

@MainActor
private final class ModuleAboutState: ObservableObject {
    static let shared = ModuleAboutState()
    @Published var expandedModules: Set<String> = []

    func isExpanded(_ id: String) -> Bool {
        expandedModules.contains(id)
    }

    func toggle(_ id: String) {
        if expandedModules.contains(id) {
            expandedModules.remove(id)
        } else {
            expandedModules.insert(id)
        }
    }
}

struct ModuleDetailContainerView: View {
    let module: any ToolboxModule

    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var registry = ModuleRegistry.shared
    @ObservedObject private var aboutState = ModuleAboutState.shared
    @ObservedObject private var navState = MainWindowController.shared.navState

    private var isEnabled: Bool {
        module.isEnabled(in: configManager.config)
    }

    private var isAboutExpanded: Bool {
        aboutState.isExpanded(module.id)
    }

    private var statusBadgeColor: Color {
        let missingScreenPermission = (module as? ScreenOCRModule).map { !$0.screenRecordingGranted } ?? false
        if !isEnabled { return .secondary }
        if !configManager.config.general.appEnabled { return .orange }
        if module.requiresAccessibility && !permissions.isAccessibilityGranted { return .orange }
        if missingScreenPermission { return .orange }
        if !module.supportsEnableToggle {
            return module.isRunning ? .red : .blue
        }
        return .green
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11)
                                .fill(module.accentColor.opacity(0.18))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11)
                                        .strokeBorder(module.accentColor.opacity(0.28), lineWidth: 1)
                                )
                            Image(systemName: module.symbolName)
                                .toolboxFont(.title3.weight(.semibold))
                                .foregroundStyle(module.accentColor)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) {
                                    Text(module.name)
                                        .toolboxFont(.title3.bold())
                                    StatusBadge(
                                        text: module.statusText(
                                            in: configManager.config,
                                            accessibilityGranted: permissions.isAccessibilityGranted
                                        ),
                                        color: statusBadgeColor
                                    )
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(module.name)
                                        .toolboxFont(.title3.bold())
                                    StatusBadge(
                                        text: module.statusText(
                                            in: configManager.config,
                                            accessibilityGranted: permissions.isAccessibilityGranted
                                        ),
                                        color: statusBadgeColor
                                    )
                                }
                            }
                            Text(module.tagline)
                                .toolboxFont(.callout)
                                .foregroundStyle(Color.primary.opacity(0.74))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .textSelection(.enabled)

                        Spacer()

                        if module.supportsEnableToggle {
                            Toggle("", isOn: Binding(
                                get: { module.isEnabled(in: configManager.config) },
                                set: { newVal in
                                    module.setEnabled(newVal, in: &configManager.config)
                                    if newVal && module.requiresAccessibility && !permissions.isAccessibilityGranted {
                                        permissions.promptAndOpenSettings()
                                    }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(StatusBarSwitchToggleStyle(onColor: .green))
                            .pointerCursor()
                        }
                    }
                    .padding(16)

                    Divider()
                        .opacity(0.55)

                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            aboutState.toggle(module.id)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .toolboxFont(.subheadline.weight(.semibold))
                                .foregroundStyle(ToolboxTheme.readableAccentText(for: module.accentColor))
                            Text("About This Feature")
                                .toolboxFont(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(isAboutExpanded ? "Hide" : "Show details")
                                .toolboxFont(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .toolboxFont(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isAboutExpanded ? 90 : 0))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .menuRowHover(cornerRadius: 0, fillOpacity: 0.065, borderOpacity: 0)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .pointerCursor()

                    if isAboutExpanded {
                        VStack(alignment: .leading, spacing: 10) {
                            Divider()
                                .opacity(0.55)

                            Text(module.aboutSummary)
                                .toolboxFont(.callout)
                                .foregroundStyle(Color.primary.opacity(0.76))

                            if !module.featureTips.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(module.featureTips, id: \.self) { tip in
                                        HStack(alignment: .top, spacing: 7) {
                                            Circle()
                                                .fill(module.accentColor)
                                                .frame(width: 5, height: 5)
                                                .padding(.top, 5)
                                            Text(tip)
                                                .toolboxFont(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
                        .overlay(
                            RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                                .fill(Color.primary.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                                .fill(
                                    LinearGradient(
                                        colors: [module.accentColor.opacity(0.06), .clear],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                        .strokeBorder(
                            isEnabled ? module.accentColor.opacity(0.22) : Color.primary.opacity(0.11),
                            lineWidth: 1
                        )
                )

                if !configManager.config.general.appEnabled && isEnabled {
                    SectionCard(accentTint: .orange) {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.orange.opacity(0.16))
                                    .frame(width: 38, height: 38)
                                Image(systemName: "pause.circle.fill")
                                    .toolboxFont(.title3.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Toolbox is Paused")
                                    .toolboxFont(.headline)
                                Text("All background features are temporarily suspended. Resume Toolbox to reactivate this module.")
                                    .toolboxFont(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button("Resume Toolbox") {
                                configManager.config.general.appEnabled = true
                            }
                            .buttonStyle(.toolboxProminent(.orange))
                            .fixedSize(horizontal: true, vertical: false)
                            .pointerCursor()
                        }
                    }
                }

                if module.requiresAccessibility && !permissions.isAccessibilityGranted {
                    SectionCard(accentTint: .orange) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.orange.opacity(0.16))
                                        .frame(width: 40, height: 40)
                                    Image(systemName: "lock.shield")
                                        .toolboxFont(.title3.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text("Accessibility Required for This Module")
                                            .toolboxFont(.headline)
                                        if permissions.isAwaitingAccessibilityGrant {
                                            StatusBadge(text: "Waiting…", color: .orange)
                                        }
                                    }
                                    Text(module.accessibilityReason)
                                        .toolboxFont(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .textSelection(.enabled)
                            }

                            HStack(spacing: 8) {
                                Spacer(minLength: 0)
                                if permissions.isAdHocSigned || permissions.hasAttemptedGrantWithoutSuccess {
                                    Button(permissions.isResettingAccessibility ? "Resetting…" : "Reset Permission") {
                                        permissions.resetAndRegrantAccessibility()
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(permissions.isResettingAccessibility)
                                    .pointerCursor(!permissions.isResettingAccessibility)
                                }
                                Button(permissions.isAwaitingAccessibilityGrant ? "Open Settings…" : "Grant Access…") {
                                    permissions.promptAndOpenSettings()
                                }
                                .buttonStyle(.toolboxProminent(.orange))
                                .pointerCursor()
                            }
                        }
                    }
                }

                module.makeSettingsView()
            }
            .padding(22)
        }
        .id(module.id)
        .onAppear {
            handlePendingFocusIfNeeded(scrollProxy: scrollProxy)
        }
        .onChange(of: navState.pendingModuleFocus) { _, _ in
            handlePendingFocusIfNeeded(scrollProxy: scrollProxy)
        }
        }
    }

    private func handlePendingFocusIfNeeded(scrollProxy: ScrollViewProxy) {
        guard let pending = navState.pendingModuleFocus,
              pending.moduleID == module.id else {
            return
        }
        let targetID = pending.anchor.rawValue
        let requestID = pending.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            MainActor.assumeIsolated {
                withAnimation(.easeInOut(duration: 0.24)) {
                    scrollProxy.scrollTo(targetID, anchor: .top)
                }
                if navState.pendingModuleFocus?.id == requestID {
                    navState.pendingModuleFocus = nil
                }
            }
        }
    }
}
