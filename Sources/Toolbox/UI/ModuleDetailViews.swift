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

    private var isEnabled: Bool {
        module.isEnabled(in: configManager.config)
    }

    private var isAboutExpanded: Bool {
        aboutState.isExpanded(module.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                SectionCard {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11)
                                .fill(module.accentColor.opacity(0.16))
                                .frame(width: 44, height: 44)
                            Image(systemName: module.symbolName)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(module.accentColor)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(module.name)
                                    .font(.title3.bold())
                                StatusBadge(
                                    text: module.statusText(
                                        in: configManager.config,
                                        accessibilityGranted: permissions.isAccessibilityGranted
                                    ),
                                    color: {
                                        if !isEnabled { return .secondary }
                                        if !configManager.config.general.appEnabled { return .orange }
                                        return (module.requiresAccessibility && !permissions.isAccessibilityGranted) ? .orange : .green
                                    }()
                                )
                            }
                            Text(module.tagline)
                                .font(.callout)
                                .foregroundStyle(.secondary)
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
                }

                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            aboutState.toggle(module.id)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Label("About This Feature", systemImage: "info.circle")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(isAboutExpanded ? "Hide" : "Show details")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isAboutExpanded ? 90 : 0))
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    if isAboutExpanded {
                        VStack(alignment: .leading, spacing: 8) {
                            Divider()
                                .padding(.bottom, 4)

                            Text(module.aboutSummary)
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            if !module.featureTips.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(module.featureTips, id: \.self) { tip in
                                        HStack(alignment: .top, spacing: 6) {
                                            Text("•")
                                                .foregroundStyle(module.accentColor)
                                            Text(tip)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }
                        .padding([.horizontal, .bottom], 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                        .strokeBorder(Color.primary.opacity(0.11), lineWidth: 1)
                )

                if module.requiresAccessibility && !permissions.isAccessibilityGranted {
                    SectionCard {
                        HStack(spacing: 14) {
                            Image(systemName: "lock.shield")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text("Accessibility Required for This Module")
                                        .font(.headline)
                                    if permissions.isAwaitingAccessibilityGrant {
                                        StatusBadge(text: "Waiting…", color: .orange)
                                    }
                                }
                                Text(module.accessibilityReason)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .textSelection(.enabled)
                            Spacer()
                            HStack(spacing: 8) {
                                if permissions.isAdHocSigned || permissions.hasAttemptedGrantWithoutSuccess {
                                    Button(permissions.isResettingAccessibility ? "Resetting…" : "Reset Entry") {
                                        permissions.resetAndRegrantAccessibility()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.large)
                                    .disabled(permissions.isResettingAccessibility)
                                    .pointerCursor(!permissions.isResettingAccessibility)
                                }
                                Button(permissions.isAwaitingAccessibilityGrant ? "Open Settings…" : "Grant Permission…") {
                                    permissions.promptAndOpenSettings()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .tint(.orange)
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
    }
}
