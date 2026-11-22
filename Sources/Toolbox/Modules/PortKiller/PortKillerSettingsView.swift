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

    private let refreshIntervalOptions = [3, 5, 10, 0]

    private func refreshIntervalLabel(for seconds: Int) -> String {
        seconds == 0 ? "Manual" : "\(seconds)s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            killSignalSection
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

    // MARK: - Default Kill Signal

    private var killSignalSection: some View {
        FeatureCardGridSection(
            "Default Kill Signal",
            subtitle: "Choose which signal clicking a port in the popover sends by default."
        ) {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    SelectableOptionCard(
                        title: "Graceful Stop",
                        subtitle: "Asks processes to flush state and exit cleanly before closing.",
                        symbolName: "hand.raised.circle.fill",
                        accentColor: module.accentColor,
                        badge: "SIGTERM · Safe",
                        isSelected: configManager.config.portKiller.defaultSignal == .sigterm
                    ) {
                        configManager.config.portKiller.defaultSignal = .sigterm
                    }

                    SelectableOptionCard(
                        title: "Force Kill",
                        subtitle: "Terminates unresponsive processes immediately without cleanup.",
                        symbolName: "bolt.slash.circle.fill",
                        accentColor: .red,
                        badge: "SIGKILL · Immediate",
                        isSelected: configManager.config.portKiller.defaultSignal == .sigkill
                    ) {
                        configManager.config.portKiller.defaultSignal = .sigkill
                    }
                }
            }
        }
    }

    // MARK: - Shortcut & Popover

    private var shortcutAndBehaviorSection: some View {
        FeatureSection(
            "Shortcut & Popover",
            subtitle: "Configure the floating Port Killer popover and scan behavior."
        ) {
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
                    Button {
                        module.showPopover()
                    } label: {
                        Label("Open Popover", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusEffectDisabled()
                    .pointerCursor()
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            Divider()

            SettingRow(
                "Auto-Refresh Interval",
                subtitle: "Polls for new listeners only while the popover or this view is open."
            ) {
                ToolboxSegmentedControl(
                    options: refreshIntervalOptions,
                    selection: $configManager.config.portKiller.refreshIntervalSeconds,
                    accentColor: module.accentColor,
                    label: { refreshIntervalLabel(for: $0) }
                )
            }

            Divider()

            SettingRow(
                "Hide macOS System Daemons",
                subtitle: "Filters Apple background services (e.g. ControlCenter, rapportd) while keeping root dev servers visible."
            ) {
                Toggle("", isOn: $configManager.config.portKiller.hideSystemProcesses)
                    .labelsHidden()
                    .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                    .pointerCursor()
            }

            Divider()

            popoverSizeRow
        }
    }

    private var popoverSizeRow: some View {
        let activePreset: PortPopoverSizePreset = uiState.isCustomSizeSelected
            ? .custom
            : PortPopoverSizePreset.matching(
                width: configManager.config.portKiller.popoverWidth,
                height: configManager.config.portKiller.popoverHeight
            )

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Popover Size")
                    .toolboxFont(.callout.weight(.semibold))
                Spacer()
                Text("\(String(configManager.config.portKiller.popoverWidth)) × \(String(configManager.config.portKiller.popoverHeight)) px")
                    .toolboxFont(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            ToolboxSegmentedControl(
                options: Array(PortPopoverSizePreset.allCases),
                selection: Binding(
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
                ),
                accentColor: module.accentColor,
                isFullWidth: true,
                label: { $0.rawValue }
            )
            .onAppear {
                let w = configManager.config.portKiller.popoverWidth
                let h = configManager.config.portKiller.popoverHeight
                uiState.isCustomSizeSelected = PortPopoverSizePreset.matching(width: w, height: h) == .custom
            }

            if activePreset == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) {
                            customWidthStepper
                            customHeightStepper
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            customWidthStepper
                            customHeightStepper
                        }
                    }
                    Text("Allowed size: 360–760 px wide, 300–780 px tall.")
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
    }

    private var customWidthStepper: some View {
        HStack(spacing: 6) {
            Text("Width")
                .toolboxFont(.caption)
                .foregroundStyle(.secondary)
            Text("\(String(configManager.config.portKiller.popoverWidth)) px")
                .toolboxFont(.caption.monospacedDigit().weight(.medium))
            Stepper("", value: $configManager.config.portKiller.popoverWidth, in: 360...760, step: 20)
                .labelsHidden()
                .pointerCursor()
        }
    }

    private var customHeightStepper: some View {
        HStack(spacing: 6) {
            Text("Height")
                .toolboxFont(.caption)
                .foregroundStyle(.secondary)
            Text("\(String(configManager.config.portKiller.popoverHeight)) px")
                .toolboxFont(.caption.monospacedDigit().weight(.medium))
            Stepper("", value: $configManager.config.portKiller.popoverHeight, in: 300...780, step: 20)
                .labelsHidden()
                .pointerCursor()
        }
    }

    // MARK: - Favorite Dev Ports

    private var favoritePortsSection: some View {
        let indigoText = ToolboxTheme.readableAccentText(for: .indigo)

        return FeatureSection(
            "Favorite Dev Ports",
            subtitle: "Pinned ports always sort to the top of the list and appear in the Dev Ports filter."
        ) {
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
                                .toolboxFont(.caption2)
                                .foregroundStyle(isPinned ? Color.orange : .secondary)
                            Text(":\(String(port))")
                                .toolboxFont(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            isPinned ? module.accentColor.opacity(0.22) : Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    isPinned ? module.accentColor.opacity(0.58) : Color.primary.opacity(0.10),
                                    lineWidth: isPinned ? 1.1 : 0.75
                                )
                        )
                        .menuRowHover(cornerRadius: 8)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(isPinned ? "Unpin port :\(port)" : "Pin port :\(port)")
                    .pointerCursor()
                }
            }

            let customFavorites = configManager.config.portKiller.favoritePorts.filter { !presetDevPorts.contains($0) }
            if !customFavorites.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom Pinned Ports")
                        .toolboxFont(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 76, maximum: 100), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(customFavorites, id: \.self) { port in
                            HStack(spacing: 4) {
                                Text(":\(String(port))")
                                    .toolboxFont(.caption.monospaced().weight(.semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                Button {
                                    module.toggleFavoritePort(port)
                                } label: {
                                    Image(systemName: "xmark")
                                        .toolboxFont(.system(size: 9, weight: .bold))
                                        .frame(width: 22, height: 22)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Remove :\(port)")
                                .accessibilityLabel("Remove custom port \(port)")
                                .pointerCursor()
                            }
                            .padding(.leading, 9)
                            .padding(.trailing, 3)
                            .padding(.vertical, 2)
                            .foregroundStyle(indigoText)
                            .background(Color.indigo.opacity(0.14), in: Capsule())
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Add custom port (e.g. 9229)", text: $uiState.customPortText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 210)
                        .onSubmit {
                            if canAddCustomPort {
                                addCustomPort()
                            }
                        }

                    Button("Add Port") {
                        addCustomPort()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canAddCustomPort)
                    .pointerCursor(canAddCustomPort)

                    Spacer()
                }

                if let error = customPortValidationError {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .toolboxFont(.caption)
                        .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                }
            }
        }
    }

    private var parsedCustomPort: Int? {
        let trimmed = uiState.customPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), port > 0 && port <= 65535 else { return nil }
        return port
    }

    private var isDuplicateCustomPort: Bool {
        guard let port = parsedCustomPort else { return false }
        return configManager.config.portKiller.favoritePorts.contains(port)
    }

    private var canAddCustomPort: Bool {
        parsedCustomPort != nil && !isDuplicateCustomPort
    }

    private var customPortValidationError: String? {
        let trimmed = uiState.customPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let port = parsedCustomPort else {
            return "Enter a valid port number from 1 to 65535."
        }
        if isDuplicateCustomPort {
            return "Port :\(port) is already pinned above."
        }
        return nil
    }

    private func addCustomPort() {
        guard let port = parsedCustomPort, !isDuplicateCustomPort else { return }
        configManager.config.portKiller.favoritePorts.append(port)
        configManager.config.portKiller.favoritePorts.sort()
        uiState.customPortText = ""
    }

    // MARK: - Live Listening Ports

    private var livePortsSection: some View {
        let items = visiblePorts
        let hasActiveFilters = !uiState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || uiState.filterMode != .all

        return FeatureSection(
            "Live Listening Ports",
            subtitle: "Includes all active TCP listeners on your Mac, including elevated root/service ports."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Filter by port, process, folder, or PID…", text: $uiState.searchQuery)
                            .textFieldStyle(.plain)
                        if !uiState.searchQuery.isEmpty {
                            Button {
                                uiState.searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .toolboxFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear filter")
                            .pointerCursor()
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                    )

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
                    .controlSize(.regular)
                    .focusEffectDisabled()
                    .pointerCursor()
                }

                HStack(spacing: 8) {
                    ToolboxSegmentedControl(
                        options: Array(PortFilterMode.allCases),
                        selection: $uiState.filterMode,
                        accentColor: module.accentColor,
                        label: { $0.rawValue }
                    )

                    Spacer(minLength: 8)

                    Text(
                        hasActiveFilters
                            ? "\(items.count) of \(module.ports.count) ports"
                            : "\(items.count) \(items.count == 1 ? "port" : "ports")"
                    )
                    .toolboxFont(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }

            Divider()

            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: module.isScanning ? "network" : "checkmark.circle")
                        .toolboxFont(.title2)
                        .foregroundStyle(.secondary)
                    Text(module.isScanning ? "Scanning listening TCP ports…" : "No matching listening ports")
                        .toolboxFont(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    if !module.isScanning && hasActiveFilters {
                        Button("Clear Filters") {
                            uiState.searchQuery = ""
                            uiState.filterMode = .all
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .focusEffectDisabled()
                        .pointerCursor()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 6) {
                    ForEach(items) { entry in
                        settingsPortRow(entry)
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
        let indigoText = ToolboxTheme.readableAccentText(for: .indigo)

        return HStack(spacing: 10) {
            Button {
                module.toggleFavoritePort(entry.port)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .toolboxFont(.caption)
                    .foregroundStyle(isFavorite ? Color.orange : Color.secondary.opacity(0.6))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuRowHover(cornerRadius: 6)
            .help(isFavorite ? "Unpin port :\(entry.port)" : "Pin port :\(entry.port)")
            .pointerCursor()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.processName)
                        .toolboxFont(.callout.weight(.semibold))
                        .lineLimit(1)

                    Text(":\(String(entry.port))")
                        .toolboxFont(.caption.monospaced().weight(.bold))
                        .foregroundStyle(indigoText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.indigo.opacity(0.14), in: Capsule())

                    if entry.requiresElevation {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                                .toolboxFont(.system(size: 10))
                            Text(entry.ownerLabel ?? "admin")
                                .toolboxFont(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                        .help("Owned by another user; prompts for macOS administrator authorization when stopped")
                    }
                }

                HStack(spacing: 6) {
                    Text("PID \(String(entry.pid))")
                        .toolboxFont(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(entry.bindDisplay)
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    if let folder = entry.cwdBasename {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Label(folder, systemImage: "folder")
                            .toolboxFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(entry.workingDirectory ?? folder)
                    }
                    if !extraPorts.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("Also on \(extraPorts.map { ":\($0)" }.joined(separator: ", "))")
                            .toolboxFont(.caption)
                            .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            if isKilling {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 64)
            } else if isStuck {
                Button("Force Kill") {
                    module.killPort(entry, signal: .sigkill)
                }
                .buttonStyle(.toolboxProminent(.red))
                .controlSize(.small)
                .focusEffectDisabled()
                .pointerCursor()
            } else {
                HStack(spacing: 6) {
                    Button("Stop") {
                        module.killPort(entry, signal: .sigterm)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusEffectDisabled()
                    .pointerCursor()

                    Button("Force Kill") {
                        module.killPort(entry, signal: .sigkill)
                    }
                    .buttonStyle(.toolboxDestructive)
                    .controlSize(.small)
                    .focusEffectDisabled()
                    .pointerCursor()
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        )
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
