import AppKit
import Carbon
import SwiftUI

enum ShortcutsHubFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case unassigned = "Unassigned"
    case conflicts = "Conflicts"

    var id: String { rawValue }
}

enum KeyMapModifierFamily: String, CaseIterable, Identifiable {
    case toolboxChord = "⌃ ⌥ ⌘"
    case optionCommand = "⌥ ⌘"
    case shiftCommand = "⇧ ⌘"
    case classicHyper = "⌃ ⌥ ⇧ ⌘"

    var id: String { rawValue }

    var modifiers: [KeyModifier] {
        switch self {
        case .toolboxChord: return [.control, .option, .command]
        case .optionCommand: return [.option, .command]
        case .shiftCommand: return [.shift, .command]
        case .classicHyper: return [.control, .option, .shift, .command]
        }
    }
}

@MainActor
private final class ShortcutsHubUIState: ObservableObject {
    @Published var searchQuery: String = ""
    @Published var filter: ShortcutsHubFilter = .all
    @Published var hideDisabledFeatures: Bool = false
    @Published var isKeyMapExpanded: Bool = false
    @Published var selectedKeyMapFamily: KeyMapModifierFamily = .toolboxChord
    @Published var collapsedModuleIDs: Set<String> = []
    @Published var expandedSecondaryModules: Set<String> = []
    @Published var highlightedDescriptorID: String? = nil
    @Published var isPressKeyToFindActive: Bool = false
    @Published var lastFoundShortcut: ShortcutSpec? = nil
    @Published var showingResetAllConfirmation: Bool = false

    private var keyFindMonitor: Any?
    private var highlightClearTask: Task<Void, Never>?

    func togglePressKeyToFind(onCaptured: @escaping (ShortcutSpec) -> Void) {
        if isPressKeyToFindActive {
            stopPressKeyToFind()
        } else {
            startPressKeyToFind(onCaptured: onCaptured)
        }
    }

    func startPressKeyToFind(onCaptured: @escaping (ShortcutSpec) -> Void) {
        stopPressKeyToFind()
        isPressKeyToFindActive = true
        HotKeyManager.shared.setSuspendedForRecording(true)

        keyFindMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isPressKeyToFindActive else { return event }
            let mods = KeyModifier.from(eventFlags: event.modifierFlags)

            if event.keyCode == UInt16(kVK_Escape) && mods.isEmpty {
                self.stopPressKeyToFind()
                return nil
            }

            guard let keyName = ShortcutSpec.keyName(for: event.keyCode) else {
                NSSound.beep()
                return nil
            }

            let captured = ShortcutSpec(key: keyName, modifiers: mods)
            guard !mods.isEmpty || captured.isFunctionKey else {
                NSSound.beep()
                return nil
            }

            self.stopPressKeyToFind()
            onCaptured(captured)
            return nil
        }
    }

    func stopPressKeyToFind() {
        if let keyFindMonitor {
            NSEvent.removeMonitor(keyFindMonitor)
            self.keyFindMonitor = nil
        }
        if isPressKeyToFindActive {
            isPressKeyToFindActive = false
            HotKeyManager.shared.setSuspendedForRecording(false)
        }
    }

    func flashHighlight(for descriptorID: String) {
        highlightClearTask?.cancel()
        highlightedDescriptorID = descriptorID
        highlightClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            if self?.highlightedDescriptorID == descriptorID {
                self?.highlightedDescriptorID = nil
            }
        }
    }
}

struct ShortcutsHubView: View {
    @ObservedObject var navState: NavigationState

    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var registry = ModuleRegistry.shared
    @ObservedObject private var hotKeys = HotKeyManager.shared
    @StateObject private var uiState = ShortcutsHubUIState()

    private struct FeatureGroup: Identifiable {
        let id: String
        let module: any ToolboxModule
        let descriptors: [ShortcutDescriptor]
    }

    private func computeFilteredFeatureGroups(
        from descriptors: [ShortcutDescriptor],
        conflicts: Set<String>,
        config cfg: ToolboxConfig
    ) -> [FeatureGroup] {
        let query = uiState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let groupedByModule = Dictionary(grouping: descriptors, by: \.moduleID)

        return registry.modules.compactMap { module in
            guard module.id != "hyper_key" else { return nil }
            guard let moduleDescriptors = groupedByModule[module.id], !moduleDescriptors.isEmpty else { return nil }
            if uiState.hideDisabledFeatures && !module.isEnabled(in: cfg) {
                return nil
            }

            let matching = moduleDescriptors.filter { descriptor in
                let shortcut = descriptor.read(cfg)
                switch uiState.filter {
                case .all:
                    break
                case .active:
                    guard descriptor.isModuleEnabled(cfg) && !shortcut.isEmpty else { return false }
                case .unassigned:
                    guard shortcut.isEmpty else { return false }
                case .conflicts:
                    guard conflicts.contains(descriptor.id) else { return false }
                }

                guard !query.isEmpty else { return true }
                return descriptor.moduleName.lowercased().contains(query)
                    || descriptor.actionTitle.lowercased().contains(query)
                    || descriptor.subtitle.lowercased().contains(query)
                    || shortcut.displayString.lowercased().contains(query)
                    || shortcut.key.lowercased().contains(query)
            }

            guard !matching.isEmpty else { return nil }
            return FeatureGroup(id: module.id, module: module, descriptors: matching)
        }
    }

    var body: some View {
        let cfg = configManager.config
        let descriptors = ShortcutCatalog.descriptors(in: cfg)
        let conflicts = ShortcutCatalog.activeConflictDescriptorIDs(in: cfg, hotKeyManager: hotKeys)
        let activeCount = descriptors.reduce(0) { count, d in
            count + (d.isModuleEnabled(cfg) && !d.read(cfg).isEmpty ? 1 : 0)
        }
        let groups = computeFilteredFeatureGroups(from: descriptors, conflicts: conflicts, config: cfg)

        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerBanner(
                        activeCount: activeCount,
                        conflicts: conflicts,
                        descriptors: descriptors,
                        scrollProxy: scrollProxy
                    )

                    searchAndFilterBar(
                        descriptors: descriptors,
                        groups: groups,
                        scrollProxy: scrollProxy
                    )

                    CapsLockHyperKeySectionView()

                    visualKeyMapSection(descriptors: descriptors, scrollProxy: scrollProxy)

                    featureGroupsSection(groups: groups)

                    footerSection
                }
                .padding(22)
            }
            .onDisappear {
                uiState.stopPressKeyToFind()
            }
        }
        .alert("Reset All Shortcuts to Defaults?", isPresented: $uiState.showingResetAllConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset All Shortcuts", role: .destructive) {
                var next = configManager.config
                ShortcutCatalog.resetAllShortcutsToDefaults(in: &next)
                configManager.config = next
                uiState.lastFoundShortcut = nil
                HUDToast.shared.show(
                    title: "All Toolbox shortcuts reset to defaults",
                    symbol: "arrow.counterclockwise",
                    tint: .blue
                )
            }
        } message: {
            Text("This restores every module's keyboard shortcut to its default binding without changing your other preferences.")
        }
    }

    // MARK: - Header

    private func headerBanner(
        activeCount: Int,
        conflicts: Set<String>,
        descriptors: [ShortcutDescriptor],
        scrollProxy: ScrollViewProxy
    ) -> some View {
        let conflictCount = conflicts.count

        return SectionCard(accentTint: conflictCount > 0 ? .orange : .indigo) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.indigo.opacity(0.18))
                        .frame(width: 44, height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 11)
                                .strokeBorder(Color.indigo.opacity(0.28), lineWidth: 1)
                        )
                    Image(systemName: "keyboard")
                        .toolboxFont(.title3.weight(.semibold))
                        .foregroundStyle(ToolboxTheme.readableAccentText(for: .indigo))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Keyboard Shortcuts")
                        .toolboxFont(.title3.bold())
                    Text("Inspect, search, test, and organize every Toolbox keybind from one command center.")
                        .toolboxFont(.callout)
                        .foregroundStyle(Color.primary.opacity(0.74))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .textSelection(.enabled)

                Spacer(minLength: 8)

                if conflictCount > 0 {
                    Button {
                        uiState.filter = .conflicts
                        if let firstConflict = descriptors.first(where: { conflicts.contains($0.id) }) {
                            jumpToDescriptor(firstConflict, scrollProxy: scrollProxy)
                        }
                    } label: {
                        StatusBadge(
                            text: "\(conflictCount) Conflict\(conflictCount == 1 ? "" : "s")",
                            color: .orange
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Filter to conflicting shortcuts")
                    .pointerCursor()
                } else {
                    StatusBadge(text: "\(activeCount) Active · 0 Conflicts", color: .green)
                }
            }
        }
    }

    // MARK: - Search & Filter Bar

    private func searchAndFilterBar(
        descriptors: [ShortcutDescriptor],
        groups: [FeatureGroup],
        scrollProxy: ScrollViewProxy
    ) -> some View {
        let groupIDs = Set(groups.map(\.id))
        let allCollapsed = !groupIDs.isEmpty && groupIDs.isSubset(of: uiState.collapsedModuleIDs)

        return SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .toolboxFont(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("Search feature, action, or shortcut…", text: $uiState.searchQuery)
                            .textFieldStyle(.plain)
                            .toolboxFont(.callout)
                        if !uiState.searchQuery.isEmpty {
                            Button {
                                uiState.searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6.5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.75)
                    )

                    Button {
                        uiState.togglePressKeyToFind { captured in
                            handleFoundShortcut(captured, descriptors: descriptors, scrollProxy: scrollProxy)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if uiState.isPressKeyToFindActive {
                                Circle()
                                    .fill(Color.indigo)
                                    .frame(width: 6, height: 6)
                                Text("Press any chord… (Esc)")
                            } else {
                                Image(systemName: "command")
                                Text("Press Key to Find")
                            }
                        }
                        .toolboxFont(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6.5)
                        .background(
                            uiState.isPressKeyToFindActive ? Color.indigo.opacity(0.22) : Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    uiState.isPressKeyToFindActive ? Color.indigo : Color.primary.opacity(0.12),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .pointerCursor()
                }

                if let found = uiState.lastFoundShortcut, !found.isEmpty {
                    foundShortcutBanner(found, descriptors: descriptors, scrollProxy: scrollProxy)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        ToolboxSegmentedControl(
                            options: ShortcutsHubFilter.allCases,
                            selection: $uiState.filter,
                            accentColor: .indigo,
                            label: \.rawValue
                        )
                        Spacer(minLength: 8)
                        collapseAllButton(groupIDs: groupIDs, allCollapsed: allCollapsed)
                        hideDisabledToggle
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ToolboxSegmentedControl(
                            options: ShortcutsHubFilter.allCases,
                            selection: $uiState.filter,
                            accentColor: .indigo,
                            label: \.rawValue
                        )
                        HStack(spacing: 12) {
                            collapseAllButton(groupIDs: groupIDs, allCollapsed: allCollapsed)
                            Spacer(minLength: 8)
                            hideDisabledToggle
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func collapseAllButton(groupIDs: Set<String>, allCollapsed: Bool) -> some View {
        if !groupIDs.isEmpty {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if allCollapsed {
                        uiState.collapsedModuleIDs.subtract(groupIDs)
                    } else {
                        uiState.collapsedModuleIDs.formUnion(groupIDs)
                    }
                }
            } label: {
                Label(
                    allCollapsed ? "Expand All" : "Collapse All",
                    systemImage: allCollapsed ? "chevron.down.square" : "chevron.right.square"
                )
                .toolboxFont(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerCursor()
        }
    }

    private var hideDisabledToggle: some View {
        Toggle(isOn: $uiState.hideDisabledFeatures) {
            Text("Hide disabled features")
                .toolboxFont(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .pointerCursor()
    }

    private func foundShortcutBanner(
        _ shortcut: ShortcutSpec,
        descriptors: [ShortcutDescriptor],
        scrollProxy: ScrollViewProxy
    ) -> some View {
        let cfg = configManager.config
        let owners = descriptors.filter { $0.read(cfg) == shortcut }
        let sysConflict = hotKeys.systemOrMenuConflictDescription(for: shortcut)

        return HStack(spacing: 10) {
            ShortcutPill(shortcut: shortcut)

            if let first = owners.first {
                Text(
                    owners.count == 1
                        ? "Bound to \(first.moduleName) · \(first.actionTitle)"
                        : "Bound to \(owners.map { "\($0.moduleName) · \($0.actionTitle)" }.joined(separator: ", "))"
                )
                .toolboxFont(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

                Spacer(minLength: 8)

                Button("Jump") {
                    jumpToDescriptor(first, scrollProxy: scrollProxy)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointerCursor()
            } else {
                Text(sysConflict != nil ? "\(shortcut.displayString) — \(sysConflict!)" : "\(shortcut.displayString) is available")
                    .toolboxFont(.caption.weight(.medium))
                    .foregroundStyle(sysConflict != nil ? ToolboxTheme.readableAccentText(for: .orange) : ToolboxTheme.readableAccentText(for: .green))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                assignMenu(for: shortcut, descriptors: descriptors, label: "Assign…")
            }

            Button {
                uiState.lastFoundShortcut = nil
            } label: {
                Image(systemName: "xmark")
                    .toolboxFont(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.indigo.opacity(0.26), lineWidth: 0.75)
        )
    }

    // MARK: - Section 2: Visual Key Map

    private func visualKeyMapSection(
        descriptors: [ShortcutDescriptor],
        scrollProxy: ScrollViewProxy
    ) -> some View {
        FeatureSection(
            "Visual Key Map",
            subtitle: "Inspect assigned, available, and macOS-reserved chords across a modifier family."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        uiState.isKeyMapExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "keyboard.badge.ellipsis")
                            .toolboxFont(.subheadline.weight(.semibold))
                            .foregroundStyle(ToolboxTheme.readableAccentText(for: .indigo))
                        Text(uiState.isKeyMapExpanded ? "Hide Availability Matrix" : "Show Availability Matrix")
                            .toolboxFont(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        ShortcutPill(text: uiState.selectedKeyMapFamily.rawValue)
                        Image(systemName: "chevron.right")
                            .toolboxFont(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(uiState.isKeyMapExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerCursor()

                if uiState.isKeyMapExpanded {
                    Divider()

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            ToolboxSegmentedControl(
                                options: KeyMapModifierFamily.allCases,
                                selection: $uiState.selectedKeyMapFamily,
                                accentColor: .indigo,
                                label: \.rawValue
                            )
                            Spacer(minLength: 8)
                            keyMapLegend
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            ToolboxSegmentedControl(
                                options: KeyMapModifierFamily.allCases,
                                selection: $uiState.selectedKeyMapFamily,
                                accentColor: .indigo,
                                label: \.rawValue
                            )
                            keyMapLegend
                        }
                    }

                    keyMapGrid(descriptors: descriptors, scrollProxy: scrollProxy)
                }
            }
        }
    }

    private var keyMapLegend: some View {
        HStack(spacing: 10) {
            legendItem(color: .indigo, label: "Assigned")
            legendItem(color: .orange, label: "System")
            legendItem(color: .secondary, label: "Available")
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(color.opacity(0.65), lineWidth: 0.75)
                )
                .frame(width: 10, height: 10)
            Text(label)
                .toolboxFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func keyMapGrid(
        descriptors: [ShortcutDescriptor],
        scrollProxy: ScrollViewProxy
    ) -> some View {
        let rows: [[(key: String, label: String, weight: CGFloat)]] = [
            [
                ("1", "1", 1), ("2", "2", 1), ("3", "3", 1), ("4", "4", 1), ("5", "5", 1),
                ("6", "6", 1), ("7", "7", 1), ("8", "8", 1), ("9", "9", 1), ("0", "0", 1),
                ("-", "-", 1), ("=", "=", 1), ("delete", "⌫", 1.35)
            ],
            [
                ("q", "Q", 1), ("w", "W", 1), ("e", "E", 1), ("r", "R", 1), ("t", "T", 1),
                ("y", "Y", 1), ("u", "U", 1), ("i", "I", 1), ("o", "O", 1), ("p", "P", 1),
                ("[", "[", 1), ("]", "]", 1)
            ],
            [
                ("a", "A", 1), ("s", "S", 1), ("d", "D", 1), ("f", "F", 1), ("g", "G", 1),
                ("h", "H", 1), ("j", "J", 1), ("k", "K", 1), ("l", "L", 1), (";", ";", 1),
                ("'", "'", 1), ("return", "↩", 1.4)
            ],
            [
                ("z", "Z", 1), ("x", "X", 1), ("c", "C", 1), ("v", "V", 1), ("b", "B", 1),
                ("n", "N", 1), ("m", "M", 1), (",", ",", 1), (".", ".", 1), ("/", "/", 1),
                ("up", "↑", 1)
            ],
            [
                ("space", "Space", 4.5), ("left", "←", 1), ("down", "↓", 1), ("right", "→", 1)
            ]
        ]

        return VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(row, id: \.key) { item in
                        keycapCell(
                            key: item.key,
                            label: item.label,
                            weight: item.weight,
                            descriptors: descriptors,
                            scrollProxy: scrollProxy
                        )
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private func keycapCell(
        key: String,
        label: String,
        weight: CGFloat,
        descriptors: [ShortcutDescriptor],
        scrollProxy: ScrollViewProxy
    ) -> some View {
        let spec = ShortcutSpec(key: key, modifiers: uiState.selectedKeyMapFamily.modifiers)
        let cfg = configManager.config
        let matchingDescriptors = descriptors.filter { $0.read(cfg) == spec }
        let preferredOwner = matchingDescriptors.first(where: { $0.isModuleEnabled(cfg) }) ?? matchingDescriptors.first
        let systemDesc = HotKeyManager.wellKnownSystemShortcuts[spec]

        if let owner = preferredOwner {
            let accent = registry.module(withID: owner.moduleID)?.accentColor ?? .indigo
            Button {
                jumpToDescriptor(owner, scrollProxy: scrollProxy)
            } label: {
                keycapVisual(
                    label: label,
                    weight: weight,
                    fill: accent.opacity(owner.isModuleEnabled(cfg) ? 0.24 : 0.12),
                    border: accent.opacity(owner.isModuleEnabled(cfg) ? 0.65 : 0.35),
                    textColor: .primary
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("\(owner.moduleName): \(owner.actionTitle) (\(spec.displayString))")
            .pointerCursor()
        } else if let systemDesc {
            keycapVisual(
                label: label,
                weight: weight,
                fill: Color.orange.opacity(0.10),
                border: Color.orange.opacity(0.45),
                textColor: ToolboxTheme.readableAccentText(for: .orange)
            )
            .help("System Reserved: \(systemDesc) (\(spec.displayString))")
        } else {
            Menu {
                ForEach(descriptors) { descriptor in
                    Button {
                        assignShortcut(spec, to: descriptor)
                    } label: {
                        Text("\(descriptor.moduleName) — \(descriptor.actionTitle)")
                    }
                }
            } label: {
                keycapVisual(
                    label: label,
                    weight: weight,
                    fill: Color.primary.opacity(0.04),
                    border: Color.primary.opacity(0.12),
                    textColor: .secondary
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("\(spec.displayString) is available — click to assign")
            .pointerCursor()
        }
    }

    private func keycapVisual(
        label: String,
        weight: CGFloat,
        fill: Color,
        border: Color,
        textColor: Color
    ) -> some View {
        Text(label)
            .toolboxFont(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(textColor)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .layoutPriority(Double(weight))
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(border, lineWidth: 0.75)
            )
    }

    // MARK: - Section 3: Feature-by-Feature Keybind Cards

    @ViewBuilder
    private func featureGroupsSection(groups: [FeatureGroup]) -> some View {
        if groups.isEmpty {
            SectionCard {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .toolboxFont(.title3)
                        .foregroundStyle(.secondary)
                    Text("No matching shortcuts")
                        .toolboxFont(.callout.weight(.semibold))
                    Text("Try clearing your search query or switching back to All shortcuts.")
                        .toolboxFont(.caption)
                        .foregroundStyle(.secondary)
                    if uiState.filter != .all || !uiState.searchQuery.isEmpty || uiState.hideDisabledFeatures {
                        Button("Show All Shortcuts") {
                            uiState.filter = .all
                            uiState.searchQuery = ""
                            uiState.hideDisabledFeatures = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(groups) { group in
                    featureCard(for: group)
                }
            }
        }
    }

    private func featureCard(for group: FeatureGroup) -> some View {
        let cfg = configManager.config
        let module = group.module
        let isEnabled = module.isEnabled(in: cfg)
        let status = module.statusText(in: cfg, accessibilityGranted: permissions.isAccessibilityGranted)
        let badgeColor: Color = {
            if !isEnabled { return .secondary }
            if !cfg.general.appEnabled { return .orange }
            if module.requiresAccessibility && !permissions.isAccessibilityGranted { return .orange }
            return .green
        }()

        let forceExpanded = !uiState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || uiState.filter == .conflicts
        let isCollapsed = !forceExpanded && uiState.collapsedModuleIDs.contains(module.id)
        let boundCount = group.descriptors.filter { !$0.read(cfg).isEmpty }.count

        let primary = group.descriptors.filter(\.isPrimary)
        let secondary = group.descriptors.filter { !$0.isPrimary }
        let autoExpandSecondary = forceExpanded
            || primary.isEmpty
            || uiState.expandedSecondaryModules.contains(module.id)

        return SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            if uiState.collapsedModuleIDs.contains(module.id) {
                                uiState.collapsedModuleIDs.remove(module.id)
                            } else {
                                uiState.collapsedModuleIDs.insert(module.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "chevron.right")
                                .toolboxFont(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                                .frame(width: 12)

                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(module.accentColor.opacity(0.16))
                                    .frame(width: 28, height: 28)
                                Image(systemName: module.symbolName)
                                    .toolboxFont(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(ToolboxTheme.readableAccentText(for: module.accentColor))
                            }

                            Text(module.name)
                                .toolboxFont(.headline)
                                .foregroundStyle(.primary)

                            StatusBadge(text: status, color: badgeColor)

                            if isCollapsed {
                                Text("\(boundCount) bound")
                                    .toolboxFont(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .pointerCursor()

                    Button {
                        navState.navigate(toModule: module.id, focusing: .shortcuts)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Open Feature")
                            Image(systemName: "arrow.right")
                        }
                        .toolboxFont(.caption.weight(.semibold))
                        .foregroundStyle(ToolboxTheme.readableAccentText(for: module.accentColor))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                if !isCollapsed {
                    Divider()

                    ForEach(Array(primary.enumerated()), id: \.element.id) { index, descriptor in
                        if index > 0 {
                            Divider()
                        }
                        descriptorRow(descriptor)
                    }

                    if !secondary.isEmpty {
                        if !primary.isEmpty {
                            Divider()

                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    if uiState.expandedSecondaryModules.contains(module.id) {
                                        uiState.expandedSecondaryModules.remove(module.id)
                                    } else {
                                        uiState.expandedSecondaryModules.insert(module.id)
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.right")
                                        .toolboxFont(.caption.weight(.semibold))
                                        .rotationEffect(.degrees(autoExpandSecondary ? 90 : 0))
                                    Text("More shortcuts (\(secondary.count))")
                                        .toolboxFont(.caption.weight(.semibold))
                                    Spacer()
                                }
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .pointerCursor()
                        }

                        if autoExpandSecondary {
                            ForEach(Array(secondary.enumerated()), id: \.element.id) { index, descriptor in
                                if index > 0 || !primary.isEmpty {
                                    Divider()
                                }
                                descriptorRow(descriptor)
                            }
                        }
                    }
                }
            }
        }
    }

    private func descriptorRow(_ descriptor: ShortcutDescriptor) -> some View {
        let currentSpec = descriptor.read(configManager.config)
        let isHighlighted = uiState.highlightedDescriptorID == descriptor.id

        return SettingRow(
            descriptor.actionTitle,
            subtitle: descriptor.subtitle
        ) {
            ShortcutRecorderView(
                shortcut: currentSpec,
                defaultShortcut: descriptor.defaultSpec,
                sourceID: descriptor.id,
                registrationKey: descriptor.registrationKey,
                showConflictWarnings: true
            ) { next in
                assignShortcut(next, to: descriptor)
            }
        }
        .padding(.horizontal, isHighlighted ? 8 : 0)
        .padding(.vertical, isHighlighted ? 4 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHighlighted ? Color.indigo.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isHighlighted ? Color.indigo.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: isHighlighted)
        .id(descriptor.id)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Text("All shortcuts support one-click conflict resolution and instant defaults restore.")
                .toolboxFont(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button("Reset All Shortcuts to Defaults") {
                uiState.showingResetAllConfirmation = true
            }
            .buttonStyle(.toolboxDestructive)
            .pointerCursor()
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func assignMenu(
        for shortcut: ShortcutSpec,
        descriptors: [ShortcutDescriptor],
        label: String
    ) -> some View {
        Menu(label) {
            ForEach(descriptors) { descriptor in
                Button("\(descriptor.moduleName) — \(descriptor.actionTitle)") {
                    assignShortcut(shortcut, to: descriptor)
                }
            }
        }
        .controlSize(.small)
        .pointerCursor()
    }

    private func assignShortcut(_ shortcut: ShortcutSpec, to descriptor: ShortcutDescriptor) {
        var next = configManager.config
        descriptor.write(shortcut, &next)
        configManager.config = next
    }

    private func handleFoundShortcut(
        _ shortcut: ShortcutSpec,
        descriptors: [ShortcutDescriptor],
        scrollProxy: ScrollViewProxy
    ) {
        uiState.lastFoundShortcut = shortcut
        let cfg = configManager.config
        if let match = descriptors.first(where: { $0.read(cfg) == shortcut }) {
            jumpToDescriptor(match, scrollProxy: scrollProxy)
        }
    }

    private func jumpToDescriptor(_ descriptor: ShortcutDescriptor, scrollProxy: ScrollViewProxy) {
        if uiState.hideDisabledFeatures && !descriptor.isModuleEnabled(configManager.config) {
            uiState.hideDisabledFeatures = false
        }
        if uiState.filter != .all && uiState.filter != .conflicts {
            uiState.filter = .all
        }
        uiState.collapsedModuleIDs.remove(descriptor.moduleID)
        if !descriptor.isPrimary {
            uiState.expandedSecondaryModules.insert(descriptor.moduleID)
        }
        uiState.flashHighlight(for: descriptor.id)
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.22)) {
                scrollProxy.scrollTo(descriptor.id, anchor: .center)
            }
        }
    }
}
