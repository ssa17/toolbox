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
        VStack(alignment: .leading, spacing: 22) {
            FeatureSection("Shortcut & Paste Behavior") {
                SettingRow("Open Clipboard Dropdown") {
                    ShortcutRecorderView(
                        shortcut: configManager.config.clipboard.shortcut,
                        defaultShortcut: ShortcutSpec(key: "v", modifiers: [.command, .option]),
                        sourceID: "clipboard",
                        registrationKey: module.hotKeyName
                    ) { newShortcut in
                        configManager.config.clipboard.shortcut = newShortcut
                    }
                }

                Divider()

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
                    .toggleStyle(.switch)
                    .pointerCursor()
                }
            }

            FeatureSection("History Limit & Speed", subtitle: "Control how many recent items are retained and how fast copies are detected.") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Keep up to")
                        TextField("25", text: $limitDraft.text)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            .font(.body.monospacedDigit())
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
                                    return
                                }
                                if let parsed = Int(digitsOnly), !digitsOnly.isEmpty {
                                    let clamped = min(max(parsed, 1), 5000)
                                    if parsed != clamped {
                                        limitDraft.text = String(clamped)
                                    }
                                    if configManager.config.clipboard.maxItems != clamped {
                                        configManager.config.clipboard.maxItems = clamped
                                    }
                                }
                            }
                            .onSubmit {
                                commitLimitDraft()
                            }
                            .onChange(of: configManager.config.clipboard.maxItems, initial: false) { _, newLimit in
                                let desired = String(newLimit)
                                if limitDraft.text != desired && !limitDraft.text.isEmpty {
                                    limitDraft.text = desired
                                }
                            }
                        Stepper("", value: $configManager.config.clipboard.maxItems, in: 1...5000, step: 5)
                            .labelsHidden()
                            .pointerCursor()
                        Text("recent items")

                        Spacer()

                        ForEach([25, 50, 100, 500], id: \.self) { preset in
                            let isSelected = configManager.config.clipboard.maxItems == preset
                            Button("\(preset)") {
                                configManager.config.clipboard.maxItems = preset
                                limitDraft.text = String(preset)
                            }
                            .buttonStyle(.bordered)
                            .tint(isSelected ? .accentColor : nil)
                            .controlSize(.small)
                            .pointerCursor()
                        }
                    }
                    Text("Type any number (1–5000) or pick a preset. Older unpinned items are removed, while pinned items stay saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                let activePollPreset: PollSpeedPreset = limitDraft.isCustomPollSelected
                    ? .custom
                    : PollSpeedPreset.matching(ms: configManager.config.clipboard.pollIntervalMs)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Copy Detection Speed")
                        Spacer()
                        Text("\(configManager.config.clipboard.pollIntervalMs) ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                    }

                    Picker("", selection: Binding(
                        get: { activePollPreset },
                        set: { newPreset in
                            if let ms = newPreset.intervalMs {
                                limitDraft.isCustomPollSelected = false
                                configManager.config.clipboard.pollIntervalMs = ms
                                limitDraft.pollMsText = String(ms)
                            } else {
                                limitDraft.isCustomPollSelected = true
                                limitDraft.pollMsText = String(configManager.config.clipboard.pollIntervalMs)
                            }
                        }
                    )) {
                        ForEach(PollSpeedPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                    .pointerCursor()
                    .onAppear {
                        let ms = configManager.config.clipboard.pollIntervalMs
                        limitDraft.pollMsText = String(ms)
                        limitDraft.isCustomPollSelected = PollSpeedPreset.matching(ms: ms) == .custom
                    }

                    if activePollPreset == .custom {
                        dimensionRow(
                            "Custom Interval",
                            unit: "ms",
                            text: $limitDraft.pollMsText,
                            value: $configManager.config.clipboard.pollIntervalMs,
                            range: 50...5000,
                            step: 50,
                            isFocused: $isPollFocused
                        )
                    }

                    Text("macOS doesn't push notifications when text is copied, so Toolbox checks the clipboard counter at this interval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            FeatureSection("Privacy & Cleanup") {
                SettingRow(
                    "Deduplicate repeated copies",
                    subtitle: "Moves an existing match to the top instead of creating duplicate rows."
                ) {
                    Toggle("", isOn: $configManager.config.clipboard.deduplicate)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }

                Divider()

                SettingRow(
                    "Ignore password manager / concealed items",
                    subtitle: "Skips entries marked secret or temporary by apps like 1Password, Bitwarden, or Apple Passwords."
                ) {
                    Toggle("", isOn: $configManager.config.clipboard.ignoreConcealedTypes)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }

                Divider()

                SettingRow(
                    "Keep unpinned history across restarts",
                    subtitle: "Saves recent unpinned items locally in ~/.config/toolbox/clipboard_history.json. Turn off to keep unpinned history in memory only."
                ) {
                    Toggle("", isOn: $configManager.config.clipboard.persistHistory)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }
            }

            FeatureSection("Dropdown Shortcuts", subtitle: "Keyboard and right-click shortcuts available inside the clipboard dropdown.") {
                shortcutRow("Navigate items", keys: ["↑ / ↓"])
                Divider()
                shortcutRow("Paste selected item", keys: ["⏎"])
                Divider()
                shortcutRow("Quick-paste item 1–9", keys: ["⌘ 1 … ⌘ 9"])
                Divider()
                shortcutRow("View full text", keys: ["→", "Space", "⌘ I"])
                Divider()
                shortcutRow("Pin or unpin item", keys: ["⌘ P"])
                Divider()
                shortcutRow("Move pinned item up / down", keys: ["⌘ ↑", "⌘ ↓", "Drag"])
                Divider()
                shortcutRow("Name or rename item", keys: ["⌘ R"])
                Divider()
                shortcutRow("Delete item (with confirmation)", keys: ["⌫", "⌘ ⌫"])
                Divider()
                shortcutRow("Open actions menu", keys: ["Right-click"])
            }

            FeatureSection("Popover Appearance & Actions") {
                let activePreset: PopoverSizePreset = limitDraft.isCustomSizeSelected
                    ? .custom
                    : PopoverSizePreset.matching(
                        width: configManager.config.clipboard.popoverWidth,
                        height: configManager.config.clipboard.popoverHeight
                    )

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Dropdown Size")
                        Spacer()
                        Text("\(configManager.config.clipboard.popoverWidth) × \(configManager.config.clipboard.popoverHeight) px")
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
                    )) {
                        ForEach(PopoverSizePreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                    .pointerCursor()
                    .onAppear {
                        let w = configManager.config.clipboard.popoverWidth
                        let h = configManager.config.clipboard.popoverHeight
                        limitDraft.widthText = String(w)
                        limitDraft.heightText = String(h)
                        limitDraft.isCustomSizeSelected = PopoverSizePreset.matching(width: w, height: h) == .custom
                    }
                }

                if activePreset == .custom {
                    Divider()

                    dimensionRow(
                        "Custom Width",
                        unit: "px",
                        text: $limitDraft.widthText,
                        value: $configManager.config.clipboard.popoverWidth,
                        range: 280...1200,
                        step: 20,
                        isFocused: $isWidthFocused
                    )

                    Divider()

                    dimensionRow(
                        "Custom Height",
                        unit: "px",
                        text: $limitDraft.heightText,
                        value: $configManager.config.clipboard.popoverHeight,
                        range: 220...1200,
                        step: 20,
                        isFocused: $isHeightFocused
                    )
                }

                Divider()

                let hasUnpinned = module.entries.contains { !$0.isPinned }
                HStack {
                    Button("Open Clipboard Dropdown") {
                        DispatchQueue.main.async {
                            module.showPopover()
                        }
                    }
                    .buttonStyle(.toolboxProminent)
                    .pointerCursor()

                    Spacer()

                    Button("Clear Unpinned History", role: .destructive) {
                        limitDraft.showClearConfirmation = true
                    }
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
        }
    }

    private func shortcutRow(_ title: String, keys: [String]) -> some View {
        SettingRow(title) {
            HStack(spacing: 6) {
                ForEach(Array(keys.enumerated()), id: \.offset) { idx, key in
                    if idx > 0 {
                        Text("/")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(key)
                        .font(.caption.monospaced().weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
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
                    .font(.body.monospacedDigit())
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
