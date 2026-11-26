import AppKit
import SwiftUI

/// Pure, testable state machine for Window Switcher HUD selection, cycling, navigation, and filtering.
struct WindowSwitcherSelectionState: Equatable, Sendable {
    var allWindows: [SwitcherWindowItem] = []
    var filteredWindows: [SwitcherWindowItem] = []
    var selectedIndex: Int = 0
    var filterQuery: String = ""
    var isFilterModeActive: Bool = false
    var layoutStyle: SwitcherLayoutStyle = .strip
    var isOpen: Bool = false
    var isCurrentAppOnly: Bool = false

    var selectedWindow: SwitcherWindowItem? {
        guard isOpen,
              selectedIndex >= 0,
              selectedIndex < filteredWindows.count else {
            return nil
        }
        return filteredWindows[selectedIndex]
    }

    mutating func open(
        windows: [SwitcherWindowItem],
        reverse: Bool,
        layoutStyle: SwitcherLayoutStyle,
        currentAppOnly: Bool = false
    ) {
        self.allWindows = windows
        self.filteredWindows = windows
        self.filterQuery = ""
        self.isFilterModeActive = false
        self.layoutStyle = layoutStyle
        self.isCurrentAppOnly = currentAppOnly
        self.isOpen = true

        if windows.count >= 2 {
            self.selectedIndex = reverse ? (windows.count - 1) : 1
        } else {
            self.selectedIndex = 0
        }
    }

    mutating func mergeEnrichedWindows(_ enriched: [SwitcherWindowItem]) {
        guard isOpen else { return }
        let previousSelectedID = selectedWindow?.id
        allWindows = enriched
        if filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filteredWindows = enriched
        } else {
            filteredWindows = enriched.filter { WindowEnumerator.matchesQuery(filterQuery, item: $0) }
        }
        reconcileSelection(preferringID: previousSelectedID)
    }

    mutating func cycleForward() {
        guard isOpen, !filteredWindows.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % filteredWindows.count
    }

    mutating func cycleBackward() {
        guard isOpen, !filteredWindows.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + filteredWindows.count) % filteredWindows.count
    }

    mutating func applyCycleDelta(_ delta: Int) {
        guard isOpen, !filteredWindows.isEmpty, delta != 0 else { return }
        let count = filteredWindows.count
        let normalized = ((delta % count) + count) % count
        selectedIndex = (selectedIndex + normalized) % count
    }

    mutating func navigate(_ direction: SwitcherNavigationDirection) {
        guard isOpen, !filteredWindows.isEmpty else { return }
        switch direction {
        case .right, .down:
            cycleForward()
        case .left, .up:
            cycleBackward()
        }
    }

    mutating func updateFilter(_ query: String) {
        let previousSelectedID = selectedWindow?.id
        filterQuery = query
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filteredWindows = allWindows
        } else {
            filteredWindows = allWindows.filter { WindowEnumerator.matchesQuery(query, item: $0) }
        }
        reconcileSelection(preferringID: previousSelectedID)
    }

    mutating func appendFilterCharacter(_ char: String) {
        isFilterModeActive = true
        updateFilter(filterQuery + char)
    }

    mutating func backspaceFilter() {
        guard !filterQuery.isEmpty else { return }
        var next = filterQuery
        next.removeLast()
        updateFilter(next)
    }

    mutating func removeWindow(id: String) {
        let prevIndex = selectedIndex
        allWindows.removeAll { $0.id == id }
        filteredWindows.removeAll { $0.id == id }
        if filteredWindows.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(max(0, prevIndex), filteredWindows.count - 1)
        }
    }

    mutating func removeWindows(pid: pid_t) {
        let prevIndex = selectedIndex
        allWindows.removeAll { $0.pid == pid }
        filteredWindows.removeAll { $0.pid == pid }
        if filteredWindows.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(max(0, prevIndex), filteredWindows.count - 1)
        }
    }

    mutating func updateWindow(_ updated: SwitcherWindowItem) {
        if let idx = allWindows.firstIndex(where: { $0.id == updated.id }) {
            allWindows[idx] = updated
        }
        if let fIdx = filteredWindows.firstIndex(where: { $0.id == updated.id }) {
            filteredWindows[fIdx] = updated
        }
    }

    mutating func commit() -> SwitcherWindowItem? {
        let chosen = selectedWindow
        cancel()
        return chosen
    }

    mutating func cancel() {
        isOpen = false
        isFilterModeActive = false
        filterQuery = ""
        allWindows = []
        filteredWindows = []
        selectedIndex = 0
        isCurrentAppOnly = false
    }

    private mutating func reconcileSelection(preferringID: String?) {
        guard !filteredWindows.isEmpty else {
            selectedIndex = 0
            return
        }
        if let preferringID,
           let matchedIdx = filteredWindows.firstIndex(where: { $0.id == preferringID }) {
            selectedIndex = matchedIdx
        } else {
            selectedIndex = min(max(0, selectedIndex), filteredWindows.count - 1)
        }
    }
}

@MainActor
final class WindowSwitcherHUDStore: ObservableObject {
    @Published var state = WindowSwitcherSelectionState()
    @Published var thumbnailsByWindowNumber: [Int: NSImage] = [:]
    @Published var iconsByPID: [pid_t: NSImage] = [:]
    @Published var showThumbnails: Bool = true
    @Published var enableQuickActions: Bool = true
    @Published var triggerModifier: SwitcherTriggerModifier = .option
    @Published var triggerKeyLabel: String = "⇥"
    @Published var currentAppName: String? = nil
}

private struct SwitcherFrostedBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = ToolboxTheme.darkAppearance
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.appearance = ToolboxTheme.darkAppearance
    }
}

struct WindowSwitcherPanelView: View {
    @ObservedObject var store: WindowSwitcherHUDStore
    let onSelectIndex: (Int) -> Void
    let onHoverIndex: (Int) -> Void
    let onToggleLayout: (SwitcherLayoutStyle) -> Void
    let onToggleFilterMode: () -> Void
    let onClearFilter: () -> Void
    let onQuickAction: (SwitcherQuickAction, Int) -> Void
    let onCancel: () -> Void

    private var accent: Color { ToolboxTheme.readableAccentText(for: .indigo) }

    var body: some View {
        VStack(spacing: 0) {
            if store.state.isFilterModeActive || !store.state.filterQuery.isEmpty {
                filterBar
                Divider().opacity(0.45)
            }

            if store.state.filteredWindows.isEmpty {
                emptyStateView
            } else {
                switch store.state.layoutStyle {
                case .strip:
                    stripBody
                case .list:
                    listHeaderBar
                    Divider().opacity(0.45)
                    listBody
                }
            }

            Divider().opacity(0.40)

            footerBar
        }
        .background(
            ZStack {
                SwitcherFrostedBackdrop()
                Color(nsColor: .windowBackgroundColor).opacity(0.72)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
        .toolboxDarkAppearance()
    }

    // MARK: - Strip Layout (macOS ⌘ Tab Style)

    private var stripBody: some View {
        VStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(Array(store.state.filteredWindows.enumerated()), id: \.element.id) { idx, item in
                            stripCard(item, index: idx, isSelected: idx == store.state.selectedIndex)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                }
                .onChange(of: store.state.selectedIndex) { _, nextIdx in
                    if nextIdx >= 0, nextIdx < store.state.filteredWindows.count {
                        withAnimation(.easeOut(duration: 0.10)) {
                            proxy.scrollTo(store.state.filteredWindows[nextIdx].id, anchor: .center)
                        }
                    }
                }
            }

            if let selected = store.state.selectedWindow {
                selectedWindowCaptionBar(selected)
            }
        }
    }

    private func stripCard(_ item: SwitcherWindowItem, index: Int, isSelected: Bool) -> some View {
        let thumb = store.showThumbnails ? item.windowNumber.flatMap { store.thumbnailsByWindowNumber[$0] } : nil
        let appIcon = store.iconsByPID[item.pid]

        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.32))

                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 52, height: 52)
                        .opacity(item.isMinimized || item.isHiddenApp ? 0.72 : 1.0)
                } else {
                    Image(systemName: "macwindow")
                        .toolboxFont(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(isSelected ? 0.22 : 0.08), lineWidth: 0.75)
            )
            .overlay(alignment: .topTrailing) {
                if item.isMinimized {
                    StatusBadge(text: "Min", color: .orange)
                        .padding(5)
                } else if item.isHiddenApp {
                    StatusBadge(text: "Hidden", color: .purple)
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if thumb != nil, let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                        .padding(5)
                }
            }

            Text(item.appName)
                .toolboxFont(.caption.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: 168)
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(isSelected ? Color.indigo.opacity(0.85) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectIndex(index)
        }
        .onHover { hovering in
            if hovering {
                onHoverIndex(index)
            }
        }
        .pointerCursor()
    }

    private func selectedWindowCaptionBar(_ item: SwitcherWindowItem) -> some View {
        let appIcon = store.iconsByPID[item.pid]
        let total = store.state.filteredWindows.count
        let pos = min(total, store.state.selectedIndex + 1)

        return HStack(spacing: 8) {
            Spacer(minLength: 8)

            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            }

            Text(item.displayTitle)
                .toolboxFont(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.title != item.appName {
                Text("· \(item.appName)")
                    .toolboxFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if item.isMinimized {
                StatusBadge(text: "Minimized", color: .orange)
            } else if item.isHiddenApp {
                StatusBadge(text: "Hidden", color: .purple)
            }

            Text("\(pos)/\(total)")
                .toolboxFont(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.indigo.opacity(0.22), in: Capsule())

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - List Layout

    private var listHeaderBar: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.indigo.opacity(0.22))
                    .frame(width: 26, height: 26)
                Image(systemName: "rectangle.stack")
                    .toolboxFont(.caption.weight(.semibold))
                    .foregroundStyle(accent)
            }

            Text(listHeaderTitle)
                .toolboxFont(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text("\(store.state.filteredWindows.count)")
                .toolboxFont(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.indigo.opacity(0.22), in: Capsule())

            Spacer(minLength: 8)

            Button {
                onToggleLayout(.strip)
            } label: {
                Image(systemName: "rectangle.split.3x1")
                    .toolboxFont(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Switch to Thumbnail Strip")
            .pointerCursor()

            Button {
                onToggleFilterMode()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "magnifyingglass")
                        .toolboxFont(.caption2.weight(.semibold))
                    Text("/")
                        .toolboxFont(.caption2.monospaced().weight(.bold))
                }
                .foregroundStyle(store.state.isFilterModeActive ? .white : .secondary)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(
                    store.state.isFilterModeActive ? Color.indigo.opacity(0.65) : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .help("Type to filter windows (/)")
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var listHeaderTitle: String {
        if store.state.isCurrentAppOnly, let app = store.currentAppName, !app.isEmpty {
            return "\(app) Windows"
        }
        return "Window Switcher"
    }

    private var listBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(Array(store.state.filteredWindows.enumerated()), id: \.element.id) { idx, item in
                        listRow(item, index: idx, isSelected: idx == store.state.selectedIndex)
                            .id(item.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: store.state.selectedIndex) { _, nextIdx in
                if nextIdx >= 0, nextIdx < store.state.filteredWindows.count {
                    withAnimation(.easeOut(duration: 0.10)) {
                        proxy.scrollTo(store.state.filteredWindows[nextIdx].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func listRow(_ item: SwitcherWindowItem, index: Int, isSelected: Bool) -> some View {
        let thumb = store.showThumbnails ? item.windowNumber.flatMap { store.thumbnailsByWindowNumber[$0] } : nil
        let appIcon = store.iconsByPID[item.pid]

        return HStack(spacing: 11) {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 58, height: 38)
                    .background(Color.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if let appIcon {
                            Image(nsImage: appIcon)
                                .resizable()
                                .frame(width: 16, height: 16)
                                .offset(x: 4, y: 4)
                        }
                    }
            } else if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "macwindow")
                            .toolboxFont(.callout)
                            .foregroundStyle(.secondary)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayTitle)
                        .toolboxFont(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if item.isMinimized {
                        StatusBadge(text: "Minimized", color: .orange)
                    } else if item.isHiddenApp {
                        StatusBadge(text: "Hidden", color: .purple)
                    }
                }

                Text(item.appName)
                    .toolboxFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isSelected && store.enableQuickActions {
                HStack(spacing: 4) {
                    quickActionIconButton(
                        symbol: "minus.circle",
                        helpText: item.isMinimized ? "Restore (M)" : "Minimize (M)"
                    ) {
                        onQuickAction(.toggleMinimize, index)
                    }
                    quickActionIconButton(
                        symbol: "eye.slash",
                        helpText: "Hide App (H)"
                    ) {
                        onQuickAction(.hideApp, index)
                    }
                    quickActionIconButton(
                        symbol: "xmark.circle",
                        helpText: "Close Window (W)"
                    ) {
                        onQuickAction(.close, index)
                    }
                }
            } else if index < 9 {
                Text("\(index + 1)")
                    .toolboxFont(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 16)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.indigo.opacity(0.28) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.indigo.opacity(0.75) : Color.primary.opacity(0.06), lineWidth: isSelected ? 1.25 : 0.75)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectIndex(index)
        }
        .onHover { hovering in
            if hovering {
                onHoverIndex(index)
            }
        }
        .pointerCursor()
    }

    private func quickActionIconButton(
        symbol: String,
        helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .toolboxFont(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .pointerCursor()
    }

    // MARK: - Filter Bar, Empty & Footer

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .toolboxFont(.caption)
                .foregroundStyle(accent)

            if store.state.filterQuery.isEmpty {
                Text("Type to filter by window title or app name…")
                    .toolboxFont(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(store.state.filterQuery)
                    .toolboxFont(.callout.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Spacer()

            if !store.state.filterQuery.isEmpty {
                Button {
                    onClearFilter()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .toolboxFont(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.indigo.opacity(0.10))
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: store.state.filterQuery.isEmpty ? "macwindow" : "magnifyingglass")
                .toolboxFont(.title2)
                .foregroundStyle(.secondary)
            Text(store.state.filterQuery.isEmpty ? "No switchable windows found" : "No windows match “\(store.state.filterQuery)”")
                .toolboxFont(.callout.weight(.medium))
                .foregroundStyle(.primary)
            Text(store.state.filterQuery.isEmpty
                 ? "Adjust your filtering options or open an application window."
                 : "Press Delete to clear characters or Esc to cancel.")
                .toolboxFont(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .padding(18)
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            keyHint("\(store.triggerModifier.symbol)\(store.triggerKeyLabel)", "Cycle")
            keyHint(store.state.layoutStyle == .strip ? "←→" : "↑↓", "Move")
            keyHint("⎋", "Cancel")
            keyHint("/", "Filter")

            if store.enableQuickActions {
                Spacer(minLength: 4)
                keyHint("W", "Close")
                keyHint("M", "Min")
                keyHint("H", "Hide")
                keyHint("Q", "Quit")
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .toolboxFont(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
                .toolboxFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
