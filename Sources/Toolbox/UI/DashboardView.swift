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
            let columnCount = availableGridWidth >= 720 ? 3 : 2
            let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: columnCount)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerBanner

                    if !permissions.isAccessibilityGranted {
                        accessibilityBanner
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Modules")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)

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
                        .foregroundStyle(Color.primary.opacity(0.76))
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
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.orange.opacity(0.16))
                        .frame(width: 40, height: 40)
                    Image(systemName: "hand.raised.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Enable Accessibility for Input & Window Shortcuts")
                        .font(.headline)
                    Text("Optional: needed for Dock Minimize, Scroll Direction, Unified Call Keybinds, Keyboard Lock, and Auto-Paste. Runs 100% locally on your Mac.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.primary.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .textSelection(.enabled)

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    Button("Grant Access…") {
                        permissions.promptAndOpenSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .pointerCursor()

                    HStack(spacing: 6) {
                        Button("Why?") {
                            permissions.presentOnboardingModal()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()

                        Button("Reset") {
                            permissions.resetAndRegrantAccessibility()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Re-bind Accessibility permission if already enabled in System Settings from an earlier build.")
                        .pointerCursor()
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
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
                    VStack(alignment: .leading, spacing: 5) {
                        Text(module.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(module.tagline)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .lineSpacing(1.5)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    HStack {
                        StatusBadge(text: status, color: badgeColor)
                        Spacer(minLength: 6)
                        Text("Customize →")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.tint)
                            .fixedSize(horizontal: true, vertical: false)
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

struct AccessibilityOnboardingModalView: View {
    @ObservedObject var permissions: PermissionsManager

    var body: some View {
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
                    Text("Enable Accessibility for Input & Window Shortcuts")
                        .font(.title3.bold())
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                        Text("100% Local · Zero Keystroke Logging · Zero Network Access")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.12), in: Capsule())
                }
            }

            Text("Toolbox uses macOS Accessibility only when you enable features that react to Dock clicks, scroll events, or global shortcuts:")
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

            Text("Keep Awake, Clipboard history capture, Port Killer, and Audio Device switching work right away without Accessibility.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Skip for Now") {
                    permissions.dismissOnboardingModal(markSeen: true)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .pointerCursor()

                Spacer()

                Button("Grant Accessibility Access…") {
                    permissions.dismissOnboardingModal(markSeen: true)
                    permissions.promptAndOpenSettings()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .keyboardShortcut(.defaultAction)
                .pointerCursor()
            }
        }
        .padding(22)
        .frame(width: 520)
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
