import AppKit
import SwiftUI

private enum PortPopoverSizePreset: String, CaseIterable, Identifiable {
    case compact = "Compact"
    case standard = "Default"
    case large = "Large"
    case custom = "Custom"

    var id: String { rawValue }

    var dimensions: (width: Int, height: Int)? {
        switch self {
        case .compact: return (400, 400)
        case .standard: return (480, 500)
        case .large: return (580, 620)
        case .custom: return nil
        }
    }

    static func matching(width: Int, height: Int) -> PortPopoverSizePreset {
        for preset in [PortPopoverSizePreset.compact, .standard, .large] {
            if let dims = preset.dimensions, dims.width == width && dims.height == height {
                return preset
            }
        }
        return .custom
    }
}

@MainActor
private final class PortKillerSettingsUIState: ObservableObject {
    @Published var searchQuery = ""
    @Published var filterMode: PortFilterMode = .all
    @Published var customPortText = ""
    @Published var isCustomSizeSelected = false
}

struct PortKillerSettingsView: View {
    @ObservedObject var module: PortKillerModule
    @ObservedObject private var configManager = ConfigManager.shared

    @StateObject private var uiState = PortKillerSettingsUIState()

    private let presetDevPorts = [3000, 3001, 4000, 5000, 5173, 5432, 6379, 8000, 8080, 8888]

    private var visiblePorts: [ListeningPort] {
        module.filteredPorts(query: uiState.searchQuery, filterMode: uiState.filterMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            shortcutAndBehaviorSection
            favoritePortsSection
            livePortsSection
        }
        .onAppear {
            module.setSettingsVisible(true)
        }
        .onDisappear {
            module.setSettingsVisible(false)
        }
    }

    // MARK: - Shortcut & Behavior

    private var shortcutAndBehaviorSection: some View {
        FeatureSection(
            "SHORTCUT & BEHAVIOR",
            subtitle: "Configure the floating Port Killer popover and termination behavior."
        ) {
            VStack(spacing: 0) {
                SettingRow(
                    "Global Popover Shortcut",
                    subtitle: "Opens the searchable Port Killer dropdown near your cursor."
                ) {
                    HStack(spacing: 8) {
                        ShortcutRecorderView(
                            shortcut: configManager.config.portKiller.shortcut,
                            defaultShortcut: ShortcutSpec(key: "p", modifiers: [.control, .option, .command]),
                            sourceID: "port_killer",
                            registrationKey: module.hotKeyName
                        ) { newShortcut in
                            configManager.config.portKiller.shortcut = newShortcut
                        }
                        Button("Open Popover") {
                            module.showPopover()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .focusEffectDisabled()
                        .pointerCursor()
                    }
                }

                Divider()

                SettingRow(
                    "Auto-Refresh Interval",
                    subtitle: "Polls for new listeners only while the popover or this view is open."
                ) {
                    Picker("", selection: $configManager.config.portKiller.refreshIntervalSeconds) {
                        Text("3 seconds").tag(3)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                        Text("Manual only").tag(0)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .pointerCursor()
                }

                Divider()

                SettingRow(
                    "Default Kill Signal",
                    subtitle: "SIGTERM asks processes to exit cleanly; SIGKILL terminates immediately."
                ) {
                    Picker("", selection: $configManager.config.portKiller.defaultSignal) {
                        ForEach(PortKillSignal.allCases, id: \.self) { sig in
                            Text(sig.label).tag(sig)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .pointerCursor()
                }

                Divider()

                SettingRow(
                    "Hide macOS System Daemons",
                    subtitle: "Filters Apple background services (e.g. ControlCenter, rapportd) while keeping root dev servers visible."
                ) {
                    Toggle("", isOn: $configManager.config.portKiller.hideSystemProcesses)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }

                Divider()

                popoverSizeRow
            }
        }
    }

    private var popoverSizeRow: some View {
        let activePreset: PortPopoverSizePreset = uiState.isCustomSizeSelected
            ? .custom
            : PortPopoverSizePreset.matching(
                width: configManager.config.portKiller.popoverWidth,
                height: configManager.config.portKiller.popoverHeight
            )

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Popover Size")
                    .font(.body)
                Spacer()
                Text("\(String(configManager.config.portKiller.popoverWidth)) × \(String(configManager.config.portKiller.popoverHeight)) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
            }

            Picker("", selection: Binding(
                get: { activePreset },
                set: { newPreset in
                    if let dims = newPreset.dimensions {
                        uiState.isCustomSizeSelected = false
                        configManager.config.portKiller.popoverWidth = dims.width
                        configManager.config.portKiller.popoverHeight = dims.height
                    } else {
                        uiState.isCustomSizeSelected = true
                    }
                }
            )) {
                ForEach(PortPopoverSizePreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .pointerCursor()

            if activePreset == .custom {
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Text("Width")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Stepper(
                            "\(String(configManager.config.portKiller.popoverWidth)) px",
                            value: $configManager.config.portKiller.popoverWidth,
                            in: 360...760,
                            step: 20
                        )
                        .font(.caption.monospacedDigit())
                        .pointerCursor()
                    }

                    HStack(spacing: 6) {
                        Text("Height")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Stepper(
                            "\(String(configManager.config.portKiller.popoverHeight)) px",
                            value: $configManager.config.portKiller.popoverHeight,
                            in: 300...780,
                            step: 20
                        )
                        .font(.caption.monospacedDigit())
                        .pointerCursor()
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Favorite Dev Ports

    private var favoritePortsSection: some View {
        FeatureSection(
            "FAVORITE DEV PORTS",
            subtitle: "Pinned ports always sort to the top of the list and appear in the Dev Ports filter."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 74, maximum: 92), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(presetDevPorts, id: \.self) { port in
                        let isPinned = configManager.config.portKiller.favoritePorts.contains(port)
                        Button {
                            module.toggleFavoritePort(port)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isPinned ? "star.fill" : "star")
                                    .font(.caption2)
                                Text(":\(String(port))")
                                    .font(.caption.monospaced().weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .foregroundStyle(isPinned ? Color.white : Color.primary)
                            .background(
                                isPinned ? Color.indigo : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        isPinned ? Color.indigo : Color.primary.opacity(0.1),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .pointerCursor()
                    }
                }

                let customFavorites = configManager.config.portKiller.favoritePorts.filter { !presetDevPorts.contains($0) }
                if !customFavorites.isEmpty {
                    HStack(spacing: 6) {
                        Text("Custom:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(customFavorites, id: \.self) { port in
                            HStack(spacing: 4) {
                                Text(":\(String(port))")
                                    .font(.caption.monospaced().weight(.semibold))
                                Button {
                                    module.toggleFavoritePort(port)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(Color.indigo)
                            .background(Color.indigo.opacity(0.14), in: Capsule())
                        }
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    TextField("Add custom port (e.g. 9229)", text: $uiState.customPortText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 210)
                        .onSubmit { addCustomPort() }

                    Button("Add Port") {
                        addCustomPort()
                    }
                    .buttonStyle(.bordered)
                    .disabled(parsedCustomPort == nil)
                    .pointerCursor()

                    Spacer()
                }
            }
            .padding(14)
        }
    }

    private var parsedCustomPort: Int? {
        let trimmed = uiState.customPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), port > 0 && port <= 65535 else { return nil }
        return port
    }

    private func addCustomPort() {
        guard let port = parsedCustomPort else { return }
        if !configManager.config.portKiller.favoritePorts.contains(port) {
            configManager.config.portKiller.favoritePorts.append(port)
            configManager.config.portKiller.favoritePorts.sort()
        }
        uiState.customPortText = ""
    }

    // MARK: - Live Listening Ports

    private var livePortsSection: some View {
        FeatureSection(
            "LIVE LISTENING PORTS",
            subtitle: "Includes all active TCP listeners on your Mac, including elevated root/service ports."
        ) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Filter by port, process, folder, or PID…", text: $uiState.searchQuery)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

                    Picker("", selection: $uiState.filterMode) {
                        ForEach(PortFilterMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .pointerCursor()

                    Button {
                        module.refreshPorts()
                    } label: {
                        HStack(spacing: 5) {
                            if module.isScanning {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Refresh")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                }
                .padding(12)

                Divider()

                let items = visiblePorts
                if items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: module.isScanning ? "network" : "checkmark.circle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(module.isScanning ? "Scanning listening TCP ports…" : "No matching listening ports")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, entry in
                            if idx > 0 {
                                Divider()
                            }
                            settingsPortRow(entry)
                        }
                    }
                }
            }
        }
    }

    private func settingsPortRow(_ entry: ListeningPort) -> some View {
        let isFavorite = module.isFavorite(entry.port)
        let isStuck = module.stuckPortKeys.contains(entry.id)
        let isKilling = module.killingPortKeys.contains(entry.id)
        let extraPorts = module.otherPorts(for: entry)

        return HStack(spacing: 10) {
            Button {
                module.toggleFavoritePort(entry.port)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(isFavorite ? Color.orange : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Unpin port :\(entry.port)" : "Pin port :\(entry.port)")
            .pointerCursor()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.processName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    Text(":\(String(entry.port))")
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(Color.indigo)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.indigo.opacity(0.14), in: Capsule())

                    if entry.requiresElevation {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                            Text(entry.ownerLabel ?? "admin")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                        .help("Owned by another user; prompts for macOS administrator authorization when stopped")
                    }
                }

                HStack(spacing: 6) {
                    Text("PID \(String(entry.pid))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(entry.bindDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let folder = entry.cwdBasename {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Label(folder, systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(entry.workingDirectory ?? folder)
                    }
                    if !extraPorts.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("Also on \(extraPorts.map { ":\($0)" }.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .textSelection(.enabled)
            }

            Spacer()

            if isKilling {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 64)
            } else if isStuck {
                Button("Still running: Force Kill?") {
                    module.killPort(entry, signal: .sigkill)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .pointerCursor()
            } else {
                HStack(spacing: 6) {
                    Button("Stop") {
                        module.killPort(entry, signal: .sigterm)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()

                    Button("Force Kill") {
                        module.killPort(entry, signal: .sigkill)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                    .pointerCursor()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Stop (SIGTERM)") {
                module.killPort(entry, signal: .sigterm)
            }
            Button("Force Kill (SIGKILL)") {
                module.killPort(entry, signal: .sigkill)
            }
            Divider()
            Button("Copy Port (\(entry.port))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(entry.port), forType: .string)
            }
            Button("Copy PID (\(entry.pid))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(entry.pid), forType: .string)
            }
            if let cwd = entry.workingDirectory {
                Button("Reveal Working Folder in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
                }
            }
        }
    }
}
