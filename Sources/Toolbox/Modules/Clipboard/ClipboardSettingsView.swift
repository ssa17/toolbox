import SwiftUI

private enum PollSpeedPreset: String, CaseIterable, Identifiable {
    case instant = "Instant"
    case balanced = "Balanced"
    case batterySaver = "Battery Saver"
    case custom = "Custom"

    var id: String { rawValue }

    var intervalMs: Int? {
        switch self {
        case .instant: return 150
        case .balanced: return 300
        case .batterySaver: return 750
        case .custom: return nil
        }
    }

    static func matching(ms: Int) -> PollSpeedPreset {
        switch ms {
        case 150: return .instant
        case 300: return .balanced
        case 750: return .batterySaver
        default: return .custom
        }
    }
}

private enum PopoverSizePreset: String, CaseIterable, Identifiable {
    case compact = "Compact"
    case standard = "Default"
    case large = "Large"
    case custom = "Custom"

    var id: String { rawValue }

    var dimensions: (width: Int, height: Int)? {
        switch self {
        case .compact: return (360, 380)
        case .standard: return (420, 460)
        case .large: return (520, 580)
        case .custom: return nil
        }
    }

    static func matching(width: Int, height: Int) -> PopoverSizePreset {
        for preset in [PopoverSizePreset.compact, .standard, .large] {
            if let dims = preset.dimensions, dims.width == width && dims.height == height {
                return preset
            }
        }
        return .custom
    }
}

@MainActor
private final class ClipboardLimitDraftState: ObservableObject {
    @Published var text: String = ""
    @Published var pollMsText: String = ""
    @Published var isCustomPollSelected: Bool = false
    @Published var widthText: String = ""
    @Published var heightText: String = ""
    @Published var isCustomSizeSelected: Bool = false
    @Published var showClearConfirmation = false
    @Published var showClearImageConfirmation = false
}

struct ClipboardSettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @StateObject private var limitDraft = ClipboardLimitDraftState()
    @ObservedObject var module: ClipboardModule
    @FocusState private var isLimitFocused: Bool
    @FocusState private var isPollFocused: Bool
    @FocusState private var isWidthFocused: Bool
    @FocusState private var isHeightFocused: Bool

    var body: some View {
        let activePollPreset: PollSpeedPreset = limitDraft.isCustomPollSelected
            ? .custom
            : PollSpeedPreset.matching(ms: configManager.config.clipboard.pollIntervalMs)
        let activeSizePreset: PopoverSizePreset = limitDraft.isCustomSizeSelected
            ? .custom
            : PopoverSizePreset.matching(
                width: configManager.config.clipboard.popoverWidth,
                height: configManager.config.clipboard.popoverHeight
            )
        let unpinnedCount = module.entries.filter { !$0.isPinned }.count
        let hasUnpinned = unpinnedCount > 0
        let imageCount = module.entries.filter { $0.kind == .image }.count
        let hasImages = imageCount > 0
        let hasPinnedImages = module.entries.contains { $0.kind == .image && $0.isPinned }
        let hasImageCache = hasImages || module.imageDiskUsage > 0

        VStack(alignment: .leading, spacing: 22) {
            FeatureSection("Shortcut & Paste Behavior") {
                SettingRow(
                    "Open Clipboard Dropdown",
                    subtitle: "Summon your pinned and recent clips from anywhere."
                ) {
                    HStack(spacing: 8) {
                        ShortcutRecorderView(
                            shortcut: configManager.config.clipboard.shortcut,
                            defaultShortcut: ShortcutSpec(key: "v", modifiers: [.command, .option]),
                            sourceID: "clipboard",
                            registrationKey: module.hotKeyName
                        ) { newShortcut in
                            configManager.config.clipboard.shortcut = newShortcut
                        }

                        Button {
                            DispatchQueue.main.async {
                                module.showPopover()
                            }
                        } label: {
                            Label("Open Dropdown", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .focusEffectDisabled()
                        .pointerCursor()
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    SettingRow(
                        "Auto-paste immediately on selection (⌘ V)",
                        subtitle: "When enabled, choosing an item copies it and sends ⌘ V to your previous app. When off, Toolbox copies it so you can paste manually."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { configManager.config.clipboard.pasteAutomatically },
                            set: { newVal in
                                configManager.config.clipboard.pasteAutomatically = newVal
                                if newVal && !permissions.isAccessibilityGranted {
                                    permissions.promptAndOpenSettings()
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                    }

                    if configManager.config.clipboard.pasteAutomatically && !permissions.isAccessibilityGranted {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .toolboxFont(.caption)
                                .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                            Text("Auto-paste requires Accessibility permission to send ⌘ V. Without it, items will be copied only.")
                                .toolboxFont(.caption)
                                .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            FeatureCardGridSection(
                "Copy Detection Speed",
                subtitle: "macOS doesn't push notifications when text is copied, so Toolbox checks the clipboard counter at this interval."
            ) {
                ToolboxAdaptiveCardGrid(wideColumns: 4, narrowColumns: 2, wideMinWidth: 560, spacing: 10) {
                    pollSpeedCard(
                        preset: .instant,
                        symbol: "bolt.fill",
                        subtitle: "150 ms · Fast",
                        badge: nil,
                        activePreset: activePollPreset
                    )
                    pollSpeedCard(
                        preset: .balanced,
                        symbol: "gauge.medium",
                        subtitle: "300 ms · Everyday",
                        badge: "Default",
                        activePreset: activePollPreset
                    )
                    pollSpeedCard(
                        preset: .batterySaver,
                        symbol: "leaf.fill",
                        subtitle: "750 ms · Low CPU",
                        badge: nil,
                        activePreset: activePollPreset
                    )
                    pollSpeedCard(
                        preset: .custom,
                        symbol: "slider.horizontal.3",
                        subtitle: activePollPreset == .custom
                            ? "\(configManager.config.clipboard.pollIntervalMs) ms"
                            : "Custom ms",
                        badge: nil,
                        activePreset: activePollPreset
                    )
                }
                .onAppear {
                    let ms = configManager.config.clipboard.pollIntervalMs
                    limitDraft.pollMsText = String(ms)
                    limitDraft.isCustomPollSelected = PollSpeedPreset.matching(ms: ms) == .custom
                }

                if activePollPreset == .custom {
                    SectionCard {
                        dimensionRow(
                            "Custom Interval",
                            unit: "ms",
                            text: $limitDraft.pollMsText,
                            value: $configManager.config.clipboard.pollIntervalMs,
                            range: 100...5000,
                            step: 50,
                            isFocused: $isPollFocused
                        )
                    }
                }
            }
            .id(ModuleFocusAnchor.shortcuts.rawValue)

            FeatureSection("History & Privacy", subtitle: "Control retention limits, password manager filtering, and local storage.") {
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            limitInputControls
                            Spacer(minLength: 8)
                            limitPresetChips
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            limitInputControls
                            limitPresetChips
                        }
                    }
                    Text("Type any number (1–5000) or pick a preset. Older unpinned items are removed, while pinned items stay saved.")
                        .toolboxFont(.system(size: 11.5))
                        .foregroundStyle(Color.primary.opacity(0.68))
                }

                Divider()

                SettingRow(
                    "Deduplicate repeated copies",
                    subtitle: "Moves an existing match to the top instead of creating duplicate rows."
                ) {
                    Toggle("", isOn: $configManager.config.clipboard.deduplicate)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                }

                Divider()

                SettingRow(
                    "Ignore password manager / concealed items",
                    subtitle: "Skips entries marked secret or temporary by apps like 1Password, Bitwarden, or Apple Passwords."
                ) {
                    Toggle("", isOn: $configManager.config.clipboard.ignoreConcealedTypes)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                }

                Divider()

                SettingRow(
                    "Keep unpinned history across restarts",
                    subtitle: "Saves recent unpinned items locally on this Mac. Turn off to keep unpinned history in memory only."
                ) {
                    Toggle("", isOn: $configManager.config.clipboard.persistHistory)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                }

                Divider()

                SettingRow(
                    "Clear unpinned history",
                    subtitle: "Pinned items and their custom titles are always preserved."
                ) {
                    Button(unpinnedCount > 0 ? "Clear Unpinned (\(unpinnedCount))" : "Clear Unpinned", role: .destructive) {
                        limitDraft.showClearConfirmation = true
                    }
                    .buttonStyle(.toolboxDestructive)
                    .disabled(!hasUnpinned)
                    .pointerCursor(hasUnpinned)
                    .confirmationDialog(
                        "Clear all unpinned clipboard items?",
                        isPresented: $limitDraft.showClearConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Clear All Unpinned", role: .destructive) {
                            module.clearHistory(keepPinned: true)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Pinned items and their custom names will be kept.")
                    }
                }
            }

            FeatureSection("Image History", subtitle: "Keep copied screenshots and images alongside text, with local PNG storage and compact thumbnails.") {
                SettingRow(
                    "Capture copied images",
                    subtitle: "Ignores Finder file icons and image previews attached to copied text. Raw images larger than the size limit are skipped."
                ) {
                    Toggle("", isOn: $configManager.config.clipboard.captureImages)
                        .labelsHidden()
                        .toggleStyle(ToolboxSwitchToggleStyle(onColor: module.accentColor))
                        .pointerCursor()
                }

                Divider()

                SettingRow(
                    "Max image items",
                    subtitle: "Limits unpinned images independently within the overall recent-history limit. Pinned images stay saved."
                ) {
                    HStack(spacing: 8) {
                        Text("\(configManager.config.clipboard.maxImageItems) items")
                            .toolboxFont(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Stepper("", value: $configManager.config.clipboard.maxImageItems, in: 1...100)
                            .labelsHidden()
                            .pointerCursor()
                    }
                }

                Divider()

                SettingRow(
                    "Max image size (MB)",
                    subtitle: "Rejects unusually large raw pasteboard payloads before decoding or writing them to disk."
                ) {
                    HStack(spacing: 8) {
                        Text("\(configManager.config.clipboard.maxImageSizeMB) MB")
                            .toolboxFont(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Stepper("", value: $configManager.config.clipboard.maxImageSizeMB, in: 1...100)
                            .labelsHidden()
                            .pointerCursor()
                    }
                }

                Divider()

                SettingRow(
                    "Image disk usage",
                    subtitle: "\(imageCount) saved \(imageCount == 1 ? "image" : "images") · \(ByteCountFormatter.string(fromByteCount: module.imageDiskUsage, countStyle: .file)) on disk"
                ) {
                    Button("Clear Image Cache", role: .destructive) {
                        limitDraft.showClearImageConfirmation = true
                    }
                    .buttonStyle(.toolboxDestructive)
                    .disabled(!hasImageCache)
                    .pointerCursor(hasImageCache)
                    .confirmationDialog(
                        "Clear clipboard image cache?",
                        isPresented: $limitDraft.showClearImageConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(hasPinnedImages ? "Clear Unpinned Images" : "Clear Image Cache", role: .destructive) {
                            module.clearImageCache(keepPinned: true)
                        }
                        if hasPinnedImages {
                            Button("Clear All Images", role: .destructive) {
                                module.clearImageCache(keepPinned: false)
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Clearing unpinned images preserves pinned images. Choose Clear All Images only if you also want to delete pinned image entries.")
                    }
                }
                .onAppear {
                    module.refreshImageDiskUsage()
                }
            }

            FeatureSection("Dropdown Size", subtitle: "Choose how large the floating Clipboard dropdown opens.") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        dropdownSizeSegmentedControl(activePreset: activeSizePreset)
                        Spacer(minLength: 8)
                        dropdownDimensionPill
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        dropdownSizeSegmentedControl(activePreset: activeSizePreset)
                        dropdownDimensionPill
                    }
                }
                .onAppear {
                    let w = configManager.config.clipboard.popoverWidth
                    let h = configManager.config.clipboard.popoverHeight
                    limitDraft.widthText = String(w)
                    limitDraft.heightText = String(h)
                    limitDraft.isCustomSizeSelected = PopoverSizePreset.matching(width: w, height: h) == .custom
                }

                if activeSizePreset == .custom {
                    Divider()

                    dimensionRow(
                        "Custom Width",
                        unit: "px",
                        text: $limitDraft.widthText,
                        value: $configManager.config.clipboard.popoverWidth,
                        range: 320...680,
                        step: 20,
                        isFocused: $isWidthFocused
                    )

                    Divider()

                    dimensionRow(
                        "Custom Height",
                        unit: "px",
                        text: $limitDraft.heightText,
                        value: $configManager.config.clipboard.popoverHeight,
                        range: 260...720,
                        step: 20,
                        isFocused: $isHeightFocused
                    )
                }
            }

            FeatureSection("Dropdown Shortcuts", subtitle: "Keyboard and right-click shortcuts available inside the clipboard dropdown.") {
                let shortcutItems: [(String, [String])] = [
                    ("Navigate items", ["↑", "↓"]),
                    ("Paste selected item", ["⏎"]),
                    ("Quick-paste item 1–9", ["⌘ 1…9"]),
                    ("Inspect text or image", ["→", "Space", "⌘ I"]),
                    ("Pin or unpin item", ["⌘ P"]),
                    ("Move pinned item", ["⌘ ↑↓", "Drag"]),
                    ("Name or rename item", ["⌘ R"]),
                    ("Delete item", ["⌫", "⌘ ⌫"]),
                    ("Open actions menu", ["Right-click"]),
                    ("Close dropdown", ["Esc"])
                ]
                let rows = stride(from: 0, to: shortcutItems.count, by: 2).map { idx in
                    Array(shortcutItems[idx..<min(idx + 2, shortcutItems.count)])
                }

                Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                        GridRow {
                            ForEach(pair, id: \.0) { item in
                                shortcutTile(item.0, keys: item.1)
                            }
                            if pair.count < 2 {
                                Color.clear
                                    .gridCellUnsizedAxes([.vertical])
                            }
                        }
                    }
                }
            }
        }
    }

    private var limitInputControls: some View {
        HStack(spacing: 8) {
            Text("Keep up to")
                .toolboxFont(.callout.weight(.semibold))
            TextField("25", text: $limitDraft.text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .toolboxFont(.body.monospacedDigit())
                .frame(width: 62)
                .focused($isLimitFocused)
                .onAppear {
                    limitDraft.text = String(configManager.config.clipboard.maxItems)
                }
                .onChange(of: isLimitFocused, initial: false) { _, focused in
                    if !focused {
                        commitLimitDraft()
                    }
                }
                .onChange(of: limitDraft.text, initial: false) { _, newValue in
                    let digitsOnly = newValue.filter(\.isNumber)
                    if digitsOnly != newValue {
                        limitDraft.text = digitsOnly
                    }
                }
                .onSubmit {
                    commitLimitDraft()
                }
                .onChange(of: configManager.config.clipboard.maxItems, initial: false) { _, newLimit in
                    let desired = String(newLimit)
                    if !isLimitFocused && limitDraft.text != desired {
                        limitDraft.text = desired
                    }
                }
            Stepper("", value: $configManager.config.clipboard.maxItems, in: 1...5000, step: 5)
                .labelsHidden()
                .pointerCursor()
            Text("recent items")
                .toolboxFont(.callout)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var limitPresetChips: some View {
        HStack(spacing: 6) {
            ForEach([25, 50, 100, 500], id: \.self) { preset in
                ToolboxPresetChip(
                    label: "\(preset)",
                    isSelected: configManager.config.clipboard.maxItems == preset,
                    accentColor: module.accentColor
                ) {
                    configManager.config.clipboard.maxItems = preset
                    limitDraft.text = String(preset)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func dropdownSizeSegmentedControl(activePreset: PopoverSizePreset) -> some View {
        ToolboxSegmentedControl(
            options: Array(PopoverSizePreset.allCases),
            selection: Binding(
                get: { activePreset },
                set: { newPreset in
                    if let dims = newPreset.dimensions {
                        limitDraft.isCustomSizeSelected = false
                        configManager.config.clipboard.popoverWidth = dims.width
                        configManager.config.clipboard.popoverHeight = dims.height
                        limitDraft.widthText = String(dims.width)
                        limitDraft.heightText = String(dims.height)
                    } else {
                        limitDraft.isCustomSizeSelected = true
                        limitDraft.widthText = String(configManager.config.clipboard.popoverWidth)
                        limitDraft.heightText = String(configManager.config.clipboard.popoverHeight)
                    }
                }
            ),
            accentColor: module.accentColor,
            label: { $0.rawValue }
        )
    }

    private var dropdownDimensionPill: some View {
        Text("\(configManager.config.clipboard.popoverWidth) × \(configManager.config.clipboard.popoverHeight) px")
            .toolboxFont(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }

    private func pollSpeedCard(
        preset: PollSpeedPreset,
        symbol: String,
        subtitle: String,
        badge: String?,
        activePreset: PollSpeedPreset
    ) -> some View {
        SelectableOptionCard(
            title: preset.rawValue,
            subtitle: subtitle,
            symbolName: symbol,
            accentColor: module.accentColor,
            badge: badge,
            isSelected: activePreset == preset,
            isCompact: true
        ) {
            if let ms = preset.intervalMs {
                limitDraft.isCustomPollSelected = false
                configManager.config.clipboard.pollIntervalMs = ms
                limitDraft.pollMsText = String(ms)
            } else {
                limitDraft.isCustomPollSelected = true
                limitDraft.pollMsText = String(configManager.config.clipboard.pollIntervalMs)
            }
        }
    }

    private func popoverSizeCard(
        preset: PopoverSizePreset,
        symbol: String,
        subtitle: String,
        badge: String?,
        activePreset: PopoverSizePreset
    ) -> some View {
        SelectableOptionCard(
            title: preset.rawValue,
            subtitle: subtitle,
            symbolName: symbol,
            accentColor: module.accentColor,
            badge: badge,
            isSelected: activePreset == preset,
            isCompact: true
        ) {
            if let dims = preset.dimensions {
                limitDraft.isCustomSizeSelected = false
                configManager.config.clipboard.popoverWidth = dims.width
                configManager.config.clipboard.popoverHeight = dims.height
                limitDraft.widthText = String(dims.width)
                limitDraft.heightText = String(dims.height)
            } else {
                limitDraft.isCustomSizeSelected = true
                limitDraft.widthText = String(configManager.config.clipboard.popoverWidth)
                limitDraft.heightText = String(configManager.config.clipboard.popoverHeight)
            }
        }
    }

    private func shortcutTile(_ title: String, keys: [String]) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .toolboxFont(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { idx, key in
                    if idx > 0 {
                        Text("/")
                            .toolboxFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    ShortcutPill(text: key)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        )
    }

    private func dimensionRow(
        _ title: String,
        unit: String,
        text: Binding<String>,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        isFocused: FocusState<Bool>.Binding
    ) -> some View {
        SettingRow(title, subtitle: "Allowed range: \(range.lowerBound)–\(range.upperBound) \(unit)") {
            HStack(spacing: 6) {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .toolboxFont(.body.monospacedDigit())
                    .frame(width: 68)
                    .focused(isFocused)
                    .onChange(of: text.wrappedValue, initial: false) { _, newValue in
                        let digitsOnly = newValue.filter(\.isNumber)
                        if digitsOnly != newValue {
                            text.wrappedValue = digitsOnly
                        }
                    }
                    .onSubmit {
                        commitDimension(text: text, value: value, range: range)
                    }
                    .onChange(of: isFocused.wrappedValue, initial: false) { _, focused in
                        if !focused {
                            commitDimension(text: text, value: value, range: range)
                        }
                    }
                    .onChange(of: value.wrappedValue, initial: false) { _, newVal in
                        let desired = String(newVal)
                        if text.wrappedValue != desired && !isFocused.wrappedValue {
                            text.wrappedValue = desired
                        }
                    }
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
                    .pointerCursor()
                Text(unit)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commitDimension(text: Binding<String>, value: Binding<Int>, range: ClosedRange<Int>) {
        if let parsed = Int(text.wrappedValue) {
            let clamped = min(max(parsed, range.lowerBound), range.upperBound)
            value.wrappedValue = clamped
            text.wrappedValue = String(clamped)
        } else {
            text.wrappedValue = String(value.wrappedValue)
        }
    }

    private func commitLimitDraft() {
        if let parsed = Int(limitDraft.text) {
            let clamped = min(max(parsed, 1), 5000)
            configManager.config.clipboard.maxItems = clamped
            limitDraft.text = String(clamped)
        } else {
            limitDraft.text = String(configManager.config.clipboard.maxItems)
        }
    }
}
