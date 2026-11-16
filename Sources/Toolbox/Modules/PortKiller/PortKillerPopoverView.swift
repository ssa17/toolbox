import AppKit
import SwiftUI

struct PortKillerPopoverView: View {
    @ObservedObject var module: PortKillerModule
    @ObservedObject var uiState: PortKillerPopoverUIState
    @ObservedObject private var configManager = ConfigManager.shared
    let onClose: () -> Void

    @FocusState private var isSearchFocused: Bool

    private var visiblePorts: [ListeningPort] {
        module.filteredPorts(query: uiState.query, filterMode: uiState.filterMode)
    }

    var body: some View {
        let items = visiblePorts
        VStack(spacing: 0) {
            searchHeader(items: items)
            filterBar(items: items)
            Divider()
            portList(items: items)
            Divider()
            footerBar(count: items.count)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .onAppear {
            isSearchFocused = true
        }
        .onChange(of: uiState.openSequence) { _, _ in
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
    }

    private func searchHeader(items: [ListeningPort]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search port, process, folder, or PID…", text: $uiState.query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onChange(of: uiState.query) {
                    uiState.selectedKey = visiblePorts.first?.id
                }

            Button {
                module.refreshPorts()
            } label: {
                if module.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
            }
            .buttonStyle(.borderless)
            .instantTooltip(id: "header.refresh", text: "Refresh listening TCP ports") { target, clearID in
                module.tooltipState.setTooltip(target, clearingID: clearID)
            }
            .focusEffectDisabled()
            .pointerCursor()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .instantTooltip(id: "header.close", text: "Close popover (Esc)") { target, clearID in
                module.tooltipState.setTooltip(target, clearingID: clearID)
            }
            .focusEffectDisabled()
            .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func filterBar(items: [ListeningPort]) -> some View {
        HStack(spacing: 6) {
            ForEach(PortFilterMode.allCases) { mode in
                let isSelected = uiState.filterMode == mode
                Button {
                    uiState.filterMode = mode
                    uiState.selectedKey = visiblePorts.first?.id
                } label: {
                    Text(mode.rawValue)
                        .font(.caption.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            isSelected ? Color.indigo : Color.primary.opacity(0.07),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .instantTooltip(id: "filter.\(mode.rawValue)", text: filterTooltip(for: mode)) { target, clearID in
                    module.tooltipState.setTooltip(target, clearingID: clearID)
                }
                .focusEffectDisabled()
                .pointerCursor()
            }

            Spacer()

            Button {
                configManager.config.portKiller.hideSystemProcesses.toggle()
            } label: {
                let hiding = configManager.config.portKiller.hideSystemProcesses
                HStack(spacing: 4) {
                    Image(systemName: hiding ? "eye.slash" : "eye")
                        .font(.caption2)
                    Text("Hide System")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(hiding ? Color.indigo : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    hiding ? Color.indigo.opacity(0.14) : Color.primary.opacity(0.06),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .instantTooltip(id: "filter.hideSystem", text: "Hide macOS system daemons (keeps root dev servers visible)") { target, clearID in
                module.tooltipState.setTooltip(target, clearingID: clearID)
            }
            .focusEffectDisabled()
            .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func filterTooltip(for mode: PortFilterMode) -> String {
        switch mode {
        case .all:
            return "Show all listening TCP ports"
        case .devPorts:
            return "Show pinned favorites & common dev ports"
        case .elevated:
            return "Show root / other-user ports (admin prompt to stop)"
        }
    }

    @ViewBuilder
    private func portList(items: [ListeningPort]) -> some View {
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: module.isScanning ? "network" : "checkmark.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(module.isScanning ? "Scanning listening TCP ports…" : "No matching listening ports")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if !uiState.query.isEmpty {
                    Text("Try clearing your search or switching filter chips.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(items) { entry in
                            PortPopoverRowView(
                                entry: entry,
                                isSelected: uiState.selectedKey == entry.id,
                                isFavorite: module.isFavorite(entry.port),
                                isStuck: module.stuckPortKeys.contains(entry.id),
                                isKilling: module.killingPortKeys.contains(entry.id),
                                extraPorts: module.otherPorts(for: entry),
                                defaultSignal: module.config.defaultSignal,
                                onSelect: { uiState.selectedKey = entry.id },
                                onToggleFavorite: { module.toggleFavoritePort(entry.port) },
                                onKill: { sig in module.killPort(entry, signal: sig) },
                                onTooltip: { target, clearID in
                                    module.tooltipState.setTooltip(target, clearingID: clearID)
                                }
                            )
                            .equatable()
                            .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: uiState.selectedKey) {
                    if let newKey = uiState.selectedKey {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newKey)
                        }
                    }
                }
            }
        }
    }

    private func footerBar(count: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(count) listening")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Text("↑↓ Select · ↩ Stop · ⌥↩ Force Kill · Esc Close")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

private extension View {
    func instantTooltip(
        id: String,
        text: String,
        onUpdate: @escaping (HoverTooltipTarget?, String?) -> Void
    ) -> some View {
        self.overlay(
            InstantTooltipOverlay(id: id, text: text, onUpdate: onUpdate)
                .allowsHitTesting(false)
        )
    }
}

private struct InstantTooltipOverlay: NSViewRepresentable {
    let id: String
    let text: String
    let onUpdate: (HoverTooltipTarget?, String?) -> Void

    func makeNSView(context: Context) -> InstantTooltipNSView {
        InstantTooltipNSView(id: id, text: text, onUpdate: onUpdate)
    }

    func updateNSView(_ nsView: InstantTooltipNSView, context: Context) {
        nsView.tooltipID = id
        nsView.tooltipText = text
        nsView.onUpdate = onUpdate
    }
}

private final class InstantTooltipNSView: NSView {
    var tooltipID: String
    var tooltipText: String
    var onUpdate: (HoverTooltipTarget?, String?) -> Void
    private var trackingArea: NSTrackingArea?
    private var isCurrentlyHovered = false

    init(id: String, text: String, onUpdate: @escaping (HoverTooltipTarget?, String?) -> Void) {
        self.tooltipID = id
        self.tooltipText = text
        self.onUpdate = onUpdate
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil && isCurrentlyHovered {
            isCurrentlyHovered = false
            let id = tooltipID
            let cb = onUpdate
            DispatchQueue.main.async {
                cb(nil, id)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isCurrentlyHovered = true
        guard let window else { return }
        let rectInWindow = convert(bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        onUpdate(HoverTooltipTarget(id: tooltipID, text: tooltipText, screenRect: screenRect), nil)
    }

    override func mouseExited(with event: NSEvent) {
        guard isCurrentlyHovered else { return }
        isCurrentlyHovered = false
        onUpdate(nil, tooltipID)
    }
}

private struct PortPopoverRowView: View, Equatable {
    let entry: ListeningPort
    let isSelected: Bool
    let isFavorite: Bool
    let isStuck: Bool
    let isKilling: Bool
    let extraPorts: [Int]
    let defaultSignal: PortKillSignal
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void
    let onKill: (PortKillSignal) -> Void
    let onTooltip: (HoverTooltipTarget?, String?) -> Void

    nonisolated static func == (lhs: PortPopoverRowView, rhs: PortPopoverRowView) -> Bool {
        lhs.entry == rhs.entry &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isFavorite == rhs.isFavorite &&
        lhs.isStuck == rhs.isStuck &&
        lhs.isKilling == rhs.isKilling &&
        lhs.extraPorts == rhs.extraPorts &&
        lhs.defaultSignal == rhs.defaultSignal
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(isFavorite ? Color.orange : Color.secondary.opacity(0.6))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .instantTooltip(
                id: "pin.\(entry.id)",
                text: isFavorite ? "Unpin port :\(String(entry.port))" : "Pin port :\(String(entry.port)) to top",
                onUpdate: onTooltip
            )
            .focusEffectDisabled()
            .pointerCursor()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.processName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    Text(":\(String(entry.port))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.indigo)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.indigo.opacity(0.14), in: Capsule())

                    if entry.requiresElevation {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                            Text(entry.ownerLabel ?? "admin")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                        .instantTooltip(
                            id: "elevated.\(entry.id)",
                            text: "Owned by another user; prompts for admin password when stopped",
                            onUpdate: onTooltip
                        )
                    }
                }

                HStack(spacing: 6) {
                    Text("PID \(String(entry.pid))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Text(entry.bindDisplay)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let folder = entry.cwdBasename {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Label(folder, systemImage: "folder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if !extraPorts.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("+\(extraPorts.count) port\(extraPorts.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer(minLength: 6)

            if isKilling {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 56)
            } else if isStuck {
                Button("Force Kill") {
                    onKill(.sigkill)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .instantTooltip(
                    id: "stuck.\(entry.id)",
                    text: "Still listening; send SIGKILL to force terminate",
                    onUpdate: onTooltip
                )
                .focusEffectDisabled()
                .pointerCursor()
            } else {
                HStack(spacing: 4) {
                    Button(defaultSignal.shortLabel) {
                        onKill(defaultSignal)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .instantTooltip(
                        id: "stop.\(entry.id)",
                        text: primaryKillTooltip,
                        onUpdate: onTooltip
                    )
                    .focusEffectDisabled()
                    .pointerCursor()

                    Button {
                        onKill(.sigkill)
                    } label: {
                        Image(systemName: "bolt.slash.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                    .instantTooltip(
                        id: "kill.\(entry.id)",
                        text: forceKillTooltip,
                        onUpdate: onTooltip
                    )
                    .focusEffectDisabled()
                    .pointerCursor()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.indigo.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSelected ? Color.indigo.opacity(0.45) : Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Stop (SIGTERM)") {
                onKill(.sigterm)
            }
            Button("Force Kill (SIGKILL)") {
                onKill(.sigkill)
            }
            Divider()
            Button(isFavorite ? "Unpin Port :\(String(entry.port))" : "Pin Port :\(String(entry.port))") {
                onToggleFavorite()
            }
            Button("Copy Port (\(String(entry.port)))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(entry.port), forType: .string)
                HUDToast.shared.show(title: "Copied port \(entry.port)", symbol: "doc.on.doc", tint: .indigo)
            }
            Button("Copy PID (\(String(entry.pid)))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(entry.pid), forType: .string)
                HUDToast.shared.show(title: "Copied PID \(entry.pid)", symbol: "doc.on.doc", tint: .indigo)
            }
            if let cwd = entry.workingDirectory {
                Divider()
                Button("Reveal Working Folder in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
                }
            }
            if let execPath = entry.executablePath {
                Button("Reveal Executable in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: execPath)])
                }
            }
        }
    }

    private var primaryKillTooltip: String {
        let action = defaultSignal.label
        if entry.requiresElevation {
            return "\(action) on PID \(String(entry.pid)) (prompts for admin)"
        }
        return "\(action) on PID \(String(entry.pid)) (↩)"
    }

    private var forceKillTooltip: String {
        if entry.requiresElevation {
            return "Force Kill (SIGKILL) with admin prompt (⌥↩)"
        }
        return "Force Kill (SIGKILL) immediately (⌥↩)"
    }
}
