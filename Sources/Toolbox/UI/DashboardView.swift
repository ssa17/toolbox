import SwiftUI

struct DashboardView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var registry = ModuleRegistry.shared
    @ObservedObject private var screenOCR = ModuleRegistry.shared.screenOCR

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
                    } else if configManager.config.screenOCR.enabled && !screenOCR.screenRecordingGranted {
                        screenRecordingBanner
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
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.orange.opacity(0.16))
                            .frame(width: 42, height: 42)
                        Image(systemName: "hand.raised.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.orange)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Enable Accessibility for Input & Window Shortcuts")
                                .font(.headline)
                            if configManager.config.screenOCR.enabled && !screenOCR.screenRecordingGranted {
                                StatusBadge(text: "Step 1 of 2", color: .orange)
                            }
                            if permissions.isAwaitingAccessibilityGrant {
                                StatusBadge(text: "Waiting for permission…", color: .orange)
                            }
                        }
                        Text("In System Settings → Privacy & Security → Device Control and Data Access (Accessibility), turn on Toolbox.app for Dock Minimize, Scroll Direction, Unified Call Keybinds, Keyboard Lock, and Auto-Paste. Runs 100% locally on your Mac.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)

                        if permissions.isAdHocSigned || permissions.hasAttemptedGrantWithoutSuccess {
                            Text("Already enabled in System Settings? Click Reset Permission to clear any stale entry from an earlier build and re-authorize this app.")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }
                    .textSelection(.enabled)
                }

                HStack(spacing: 10) {
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
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(permissions.isResettingAccessibility)
                        .help("Re-bind Accessibility permission if already enabled in System Settings from an earlier build.")
                        .pointerCursor(!permissions.isResettingAccessibility)
                    }

                    Button {
                        permissions.presentOnboardingModal()
                    } label: {
                        Label("Why This Is Needed", systemImage: "questionmark.circle")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .pointerCursor()

                    Button {
                        permissions.promptAndOpenSettings()
                    } label: {
                        Label(
                            permissions.isAwaitingAccessibilityGrant ? "Open Settings…" : "Grant Access…",
                            systemImage: "hand.raised.fill"
                        )
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.orange)
                    .pointerCursor()
                }
            }
        }
    }

    private var screenRecordingBanner: some View {
        SectionCard {
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
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.orange)
                    .pointerCursor()
                }
            }
        }
    }

    private func moduleCard(_ module: any ToolboxModule) -> some View {
        let isEnabled = module.isEnabled(in: configManager.config)
        let status = module.statusText(in: configManager.config, accessibilityGranted: permissions.isAccessibilityGranted)
        let missingScreenPermission = (module as? ScreenOCRModule).map { !$0.screenRecordingGranted } ?? false
        let badgeColor: Color = {
            if !isEnabled { return .secondary }
            if !configManager.config.general.appEnabled { return .orange }
            if module.requiresAccessibility && !permissions.isAccessibilityGranted { return .orange }
            if missingScreenPermission { return .orange }
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

                Spacer(minLength: 8)

                Button {
                    permissions.dismissOnboardingModal(markSeen: true)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
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
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
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
