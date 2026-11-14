import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class DockSettingsInputState: ObservableObject {
    @Published var newBundleID = ""
}

struct DockMinimizeSettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var inputState = DockSettingsInputState()
    @ObservedObject var module: DockMinimizeModule

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let err = module.lastError {
                SectionCard {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            FeatureSection("Click Action", subtitle: "What happens when you click the active app's Dock icon.") {
                Picker("", selection: $configManager.config.dockMinimize.actionMode) {
                    ForEach(DockActionMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .pointerCursor()

                Text(configManager.config.dockMinimize.actionMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }

            FeatureSection("Trigger & Modifiers", subtitle: "Fine-tune how Dock clicks are recognized.") {
                SettingRow("Activation click") {
                    Picker("", selection: $configManager.config.dockMinimize.clickMode) {
                        ForEach(DockClickMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .pointerCursor()
                }

                Divider()

                SettingRow(
                    "Ignore modified clicks",
                    subtitle: "Hold ⌘, ⌥, ⌃, or ⇧ to keep macOS's native Dock click behaviors."
                ) {
                    Toggle("", isOn: $configManager.config.dockMinimize.ignoreModifiedClicks)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }
            }

            FeatureSection("Excluded Applications", subtitle: "Apps listed here keep macOS's default Dock click behavior.") {
                HStack(spacing: 8) {
                    TextField("Bundle ID (e.g. com.apple.finder)", text: $inputState.newBundleID)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addExclusion(inputState.newBundleID)
                            inputState.newBundleID = ""
                        }

                    Menu("Running App") {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            if let bundleID = app.bundleIdentifier {
                                let isExcluded = configManager.config.dockMinimize.excludedBundleIDs.contains(bundleID)
                                Button(isExcluded ? "\(app.localizedName ?? bundleID) (Excluded)" : (app.localizedName ?? bundleID)) {
                                    addExclusion(bundleID)
                                }
                                .disabled(isExcluded)
                            }
                        }
                    }
                    .pointerCursor()

                    Button("Choose App…") {
                        pickAppBundle()
                    }
                    .pointerCursor()

                    Button("Add") {
                        addExclusion(inputState.newBundleID)
                        inputState.newBundleID = ""
                    }
                    .disabled(inputState.newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .pointerCursor(!inputState.newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Divider()

                if configManager.config.dockMinimize.excludedBundleIDs.isEmpty {
                    Text("No excluded apps. Works for all apps including Finder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                } else {
                    VStack(spacing: 6) {
                        ForEach(configManager.config.dockMinimize.excludedBundleIDs, id: \.self) { bundleID in
                            HStack(spacing: 8) {
                                if let appName = resolvedAppName(for: bundleID) {
                                    Text(appName)
                                        .font(.callout.weight(.medium))
                                    Text(bundleID)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(bundleID)
                                        .font(.system(.callout, design: .monospaced))
                                }
                                Spacer()
                                Button {
                                    configManager.config.dockMinimize.excludedBundleIDs.removeAll { $0 == bundleID }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red.opacity(0.85))
                                }
                                .buttonStyle(.plain)
                                .help("Remove exclusion")
                                .pointerCursor()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
    }

    private func pickAppBundle() {
        let panel = NSOpenPanel()
        panel.title = "Choose Application to Exclude"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let bundleID = Bundle(url: url)?.bundleIdentifier {
                    addExclusion(bundleID)
                }
            }
        }
    }

    private func resolvedAppName(for bundleID: String) -> String? {
        if let running = runningApps.first(where: { $0.bundleIdentifier == bundleID })?.localizedName {
            return running
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url) {
            return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        }
        return nil
    }

    private func addExclusion(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !configManager.config.dockMinimize.excludedBundleIDs.contains(trimmed) else { return }
        configManager.config.dockMinimize.excludedBundleIDs.append(trimmed)
    }
}
