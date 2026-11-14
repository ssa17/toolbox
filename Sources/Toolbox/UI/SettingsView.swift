import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var updateManager = UpdateManager.shared

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? short
        return build == short ? "v\(short)" : "v\(short) (build \(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                FeatureSection("App Presence & Startup", subtitle: "Choose where Toolbox appears and when it opens.") {
                    SettingRow("Show icon in Menu Bar", subtitle: "Quick toggles and shortcuts from the top status bar.") {
                        Toggle("", isOn: Binding(
                            get: { configManager.config.general.showInMenuBar },
                            set: { newVal in
                                configManager.config.general.showInMenuBar = newVal
                                if !newVal && !configManager.config.general.showInDock {
                                    configManager.config.general.showInDock = true
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                    }

                    Divider()

                    SettingRow("Show icon in Dock", subtitle: "Switch quickly with ⌘ Tab or click the Dock icon to reopen.") {
                        Toggle("", isOn: Binding(
                            get: { configManager.config.general.showInDock },
                            set: { newVal in
                                configManager.config.general.showInDock = newVal
                                if !newVal && !configManager.config.general.showInMenuBar {
                                    configManager.config.general.showInMenuBar = true
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                    }

                    Divider()

                    SettingRow("Open Dashboard on launch", subtitle: "Show the Dashboard window when Toolbox starts.") {
                        Toggle("", isOn: $configManager.config.general.openDashboardOnLaunch)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .pointerCursor()
                    }

                    Divider()

                    SettingRow(
                        "Open Dashboard on Dock click",
                        subtitle: "Reopen the window when clicking the Dock icon while Toolbox runs in the background."
                    ) {
                        Toggle("", isOn: $configManager.config.general.openDashboardOnDockClick)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .pointerCursor()
                    }

                    Divider()

                    SettingRow(
                        "When clicking Quit on Dock",
                        subtitle: "Close the Dashboard window when open (keep running in background), or quit Toolbox."
                    ) {
                        Picker("", selection: $configManager.config.general.dockQuitBehavior) {
                            ForEach(DockQuitBehavior.allCases, id: \.self) { behavior in
                                Text(behavior.displayName).tag(behavior)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .pointerCursor()
                    }

                    Divider()

                    SettingRow("Launch Toolbox at login") {
                        Toggle("", isOn: Binding(
                            get: { configManager.config.general.launchAtLogin },
                            set: { newVal in
                                configManager.config.general.launchAtLogin = newVal
                                updateLoginItem(enabled: newVal)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                    }
                }

                FeatureSection("Permissions", subtitle: "System access used locally on your Mac.") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Accessibility Access")
                                    .font(.callout.weight(.semibold))
                                StatusBadge(
                                    text: permissions.isAccessibilityGranted ? "Granted" : "Not Granted",
                                    color: permissions.isAccessibilityGranted ? .green : .orange
                                )
                            }
                            Text(
                                permissions.isAccessibilityGranted
                                    ? "All Accessibility-powered modules (Dock Minimize, Auto-Paste, and Scroll Direction) are authorized."
                                    : "Used only for Dock Click to Minimize, auto-pasting (⌘ V), and Scroll Direction inversion."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !permissions.isAccessibilityGranted {
                            HStack(spacing: 8) {
                                Button("Reset Entry") {
                                    permissions.resetAndRegrantAccessibility()
                                }
                                .buttonStyle(.bordered)
                                .pointerCursor()
                                Button("Grant Access…") {
                                    permissions.promptAndOpenSettings()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                                .pointerCursor()
                            }
                        }
                    }
                }

                FeatureSection("Software Updates") {
                    SettingRow("Automatic Remote Updates (Sparkle)", subtitle: updateManager.statusText) {
                        Button("Check for Updates…") {
                            updateManager.checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!updateManager.isSparkleAvailable)
                        .pointerCursor(updateManager.isSparkleAvailable)
                    }

                    if updateManager.isSparkleAvailable {
                        Divider()

                        SettingRow("Automatically check for updates") {
                            Toggle("", isOn: Binding(
                                get: { updateManager.automaticallyChecksForUpdates },
                                set: { updateManager.automaticallyChecksForUpdates = $0 }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .pointerCursor()
                        }
                    }
                }

                FeatureSection("About Toolbox") {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(
                                    LinearGradient(
                                        colors: [Color(red: 0.16, green: 0.18, blue: 0.22), Color(red: 0.08, green: 0.09, blue: 0.11)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 42, height: 42)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                                )
                            ToolboxBentoMark(size: 22, primaryColor: .white, accentColor: Color(red: 0.29, green: 0.62, blue: 1.0))
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Toolbox \(versionString)")
                                .font(.headline)
                            Text("Extensible, lightweight macOS quality-of-life toolkit.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Config file: \(configManager.configURL.path)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                    }
                }
            }
            .padding(22)
        }
        .onAppear {
            permissions.refresh()
        }
    }

    private func updateLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Toolbox: SMAppService update failed: \(error.localizedDescription)")
            configManager.config.general.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}
