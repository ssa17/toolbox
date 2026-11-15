import SwiftUI

struct DashboardView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var registry = ModuleRegistry.shared

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

    var body: some View {
        GeometryReader { proxy in
            let availableGridWidth = max(0, proxy.size.width - 44)
            let columnCount = availableGridWidth >= 660 ? 3 : 2
            let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: columnCount)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerBanner

                    if !permissions.isAccessibilityGranted {
                        accessibilityBanner
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Modules")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(registry.modules, id: \.id) { module in
                                moduleCard(module)
                            }
                        }
                    }
                }
                .padding(22)
            }
        }
        .onAppear {
            permissions.refresh()
        }
    }

    private var headerBanner: some View {
        SectionCard {
            HStack(spacing: 14) {
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

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Toolbox")
                            .font(.title2.bold())
                        Text(versionText)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                        StatusBadge(
                            text: configManager.config.general.appEnabled
                                ? "\(activeCount)/\(toggleableModules.count) enabled"
                                : "Paused",
                            color: configManager.config.general.appEnabled
                                ? (activeCount > 0 ? .green : .secondary)
                                : .orange
                        )
                    }
                    Text(
                        configManager.config.general.appEnabled
                            ? "Lightweight, config-driven utilities tailored to how you use your Mac."
                            : "Toolbox is paused from the status bar. Resume to reactivate your enabled modules."
                    )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)

                if !configManager.config.general.appEnabled {
                    Spacer()

                    Button("Resume") {
                        configManager.config.general.appEnabled = true
                    }
                    .buttonStyle(.borderedProminent)
                    .fixedSize(horizontal: true, vertical: false)
                    .pointerCursor()
                }
            }
        }
    }

    private var accessibilityBanner: some View {
        SectionCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "hand.raised.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Accessibility Permission Optional (Recommended for Full Power)")
                        .font(.headline)
                    Text("Toolbox works right away for Keep Awake, Clipboard capture, and Shell Commands. Grant Accessibility only if you want **Dock Click to Minimize**, **Auto-Paste (⌘ V)**, or **Scroll Direction inversion**. Toolbox never logs keystrokes or sends data off your Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Already toggled ON in System Settings from an earlier build? Click \"Reset & Grant\" to bind it to this signed app.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Button("Grant Access…") {
                        permissions.promptAndOpenSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .pointerCursor()

                    Button("Reset & Grant") {
                        permissions.resetAndRegrantAccessibility()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                }
            }
        }
    }

    private func moduleCard(_ module: any ToolboxModule) -> some View {
        let isEnabled = module.isEnabled(in: configManager.config)
        let status = module.statusText(in: configManager.config, accessibilityGranted: permissions.isAccessibilityGranted)
        let badgeColor: Color = {
            if !isEnabled { return .secondary }
            if !configManager.config.general.appEnabled { return .orange }
            if module.requiresAccessibility && !permissions.isAccessibilityGranted { return .orange }
            return module.isRunning ? .green : .blue
        }()

        return SectionCard {
            HStack(alignment: .top) {
                Button {
                    onSelectModule(module.id)
                } label: {
                    HStack(alignment: .top) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(module.accentColor.opacity(0.15))
                                .frame(width: 34, height: 34)
                            Image(systemName: module.symbolName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(module.accentColor)
                        }

                        Spacer()

                        if let shortcut = module.shortcutText(in: configManager.config) {
                            ShortcutPill(text: shortcut)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()

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
                } else if let cleanLock = module as? CleanLockModule {
                    let secs = CleanLockConfig.clampedDuration(configManager.config.cleanLock.durationSeconds)
                    let durationLabel = secs >= 60 && secs % 60 == 0 ? "\(secs / 60)m" : "\(secs)s"
                    Button {
                        _ = cleanLock.lock()
                    } label: {
                        Label(
                            cleanLock.isLocked ? "\(cleanLock.remainingSeconds)s" : "Lock (\(durationLabel))",
                            systemImage: cleanLock.isLocked ? "lock.fill" : "lock"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.red)
                    .pointerCursor()
                }
            }

            Button {
                onSelectModule(module.id)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(module.name)
                            .font(.headline)
                        Text(module.tagline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(minHeight: 30, alignment: .topLeading)
                    }

                    HStack {
                        StatusBadge(text: status, color: badgeColor)
                        Spacer()
                        Text("Customize →")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }
}
