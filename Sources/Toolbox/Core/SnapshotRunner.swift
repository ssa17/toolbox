import AppKit
import SwiftUI

/// Headless visual snapshot utility (`Toolbox --snapshot-ui <dir>`).
/// Renders key Toolbox views offscreen into PNG files so agents and developers can
/// visually inspect spacing, card hierarchy, contrast, and icon states without
/// touching user configuration or stealing desktop focus.
@MainActor
enum SnapshotRunner {
    static func run(outputDir: String) -> Int32 {
        let fm = FileManager.default
        let outURL = URL(fileURLWithPath: outputDir, isDirectory: true)
        do {
            try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
        } catch {
            fputs("SnapshotRunner failed to create directory \(outputDir): \(error)\n", stderr)
            return 1
        }

        let configManager = ConfigManager.shared
        let registry = ModuleRegistry.shared

        // Reset clean temporary state for deterministic screenshots
        configManager.config = ToolboxConfig()
        registry.reloadAll(with: configManager.config)

        let navDashboard = NavigationState()
        navDashboard.selection = .dashboard
        navDashboard.isSidebarVisible = true

        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDashboard),
            size: NSSize(width: 940, height: 700),
            to: outURL.appendingPathComponent("dashboard_active.png")
        )

        let navModule = NavigationState()
        navModule.selection = .module("dock_minimize")
        navModule.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navModule),
            size: NSSize(width: 940, height: 660),
            to: outURL.appendingPathComponent("module_dock.png")
        )

        let navScroll = NavigationState()
        navScroll.selection = .module("scroll_direction")
        navScroll.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navScroll),
            size: NSSize(width: 940, height: 660),
            to: outURL.appendingPathComponent("module_scroll.png")
        )

        let navClipboard = NavigationState()
        navClipboard.selection = .module("clipboard")
        navClipboard.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navClipboard),
            size: NSSize(width: 940, height: 660),
            to: outURL.appendingPathComponent("module_clipboard.png")
        )

        let navJSON = NavigationState()
        navJSON.selection = .jsonConfig
        navJSON.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navJSON),
            size: NSSize(width: 940, height: 660),
            to: outURL.appendingPathComponent("json_config.png")
        )

        let navSettings = NavigationState()
        navSettings.selection = .settings
        navSettings.isSidebarVisible = true
        UpdateManager.shared.configureStateForTesting(
            isSparkleAvailable: true,
            isChecking: false,
            checkProgress: 0,
            pendingUpdateVersion: nil,
            lastCheckedAt: Date()
        )
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navSettings),
            size: NSSize(width: 940, height: 1220),
            to: outURL.appendingPathComponent("settings_up_to_date.png")
        )

        UpdateManager.shared.configureStateForTesting(
            isSparkleAvailable: true,
            isChecking: true,
            checkProgress: 0.62,
            pendingUpdateVersion: nil,
            lastCheckedAt: Date().addingTimeInterval(-3600)
        )
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navSettings),
            size: NSSize(width: 940, height: 1220),
            to: outURL.appendingPathComponent("settings_checking.png")
        )

        UpdateManager.shared.configureStateForTesting(
            isSparkleAvailable: true,
            isChecking: false,
            checkProgress: 0,
            pendingUpdateVersion: "1.1",
            pendingUpdateSizeBytes: 3_420_000,
            lastCheckedAt: Date()
        )
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navSettings),
            size: NSSize(width: 940, height: 1220),
            to: outURL.appendingPathComponent("settings_update_available.png")
        )

        saveViewSnapshot(
            MenuBarPopoverView(onOpenDashboard: { _ in }, onClosePopover: { _ in }),
            size: NSSize(width: 340, height: 470),
            to: outURL.appendingPathComponent("menubar_update_available.png")
        )

        saveUpdateDialogSnapshot(to: outURL.appendingPathComponent("update_dialog.png"))

        UpdateManager.shared.configureStateForTesting(
            isSparkleAvailable: true,
            isChecking: false,
            checkProgress: 0,
            pendingUpdateVersion: nil,
            lastCheckedAt: nil
        )

        saveViewSnapshot(
            MenuBarPopoverView(onOpenDashboard: { _ in }, onClosePopover: { _ in }),
            size: NSSize(width: 340, height: 470),
            to: outURL.appendingPathComponent("menubar_active.png")
        )

        configManager.config.general.appEnabled = false
        registry.reloadAll(with: configManager.config)

        saveViewSnapshot(
            MenuBarPopoverView(onOpenDashboard: { _ in }, onClosePopover: { _ in }),
            size: NSSize(width: 340, height: 470),
            to: outURL.appendingPathComponent("menubar_paused.png")
        )

        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDashboard),
            size: NSSize(width: 940, height: 700),
            to: outURL.appendingPathComponent("dashboard_paused.png")
        )

        renderStatusBarPreview(to: outURL.appendingPathComponent("statusbar_icons.png"))

        // Clean up temp config dir created by ConfigManager isolated mode
        let tempDir = configManager.configURL.deletingLastPathComponent()
        if tempDir.path.contains("toolbox-isolated-") {
            try? fm.removeItem(at: tempDir)
        }

        print("Saved UI snapshots to \(outURL.path)")
        return 0
    }

    private static func saveViewSnapshot<V: View>(_ view: V, size: NSSize, to url: URL) {
        let darkWrapped = ZStack {
            Color(red: 0.145, green: 0.149, blue: 0.165)
            view
        }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)

        let hosting = NSHostingView(rootView: darkWrapped)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.145, green: 0.149, blue: 0.165, alpha: 1.0)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.10))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fputs("SnapshotRunner could not allocate bitmap rep for \(url.lastPathComponent)\n", stderr)
            window.close()
            return
        }
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
        window.close()
    }

    private static func renderStatusBarPreview(to url: URL) {
        let size = NSSize(width: 320, height: 110)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.17, alpha: 1.0).setFill()
        NSRect(origin: .zero, size: size).fill()

        let activeImg = MenuBarController.makeStatusBarIcon(isActive: true)
        let pausedImg = MenuBarController.makeStatusBarIcon(isActive: false)

        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            activeImg.draw(in: NSRect(x: 56, y: 42, width: 44, height: 44), from: .zero, operation: .sourceOver, fraction: 1.0)
            pausedImg.draw(in: NSRect(x: 206, y: 42, width: 44, height: 44), from: .zero, operation: .sourceOver, fraction: 0.55)
        }

        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 0.9, alpha: 1.0)
        ]
        NSAttributedString(string: "Active (Filled)", attributes: attr).draw(at: NSPoint(x: 34, y: 16))
        NSAttributedString(string: "Paused (Outlined)", attributes: attr).draw(at: NSPoint(x: 174, y: 16))

        NSGraphicsContext.restoreGraphicsState()

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    private static func saveUpdateDialogSnapshot(to url: URL) {
        let controller = ToolboxUpdateWindowController()
        controller.populatePreviewAvailable(
            version: "1.1",
            currentVersion: "1.0",
            sizeBytes: 3_420_000,
            notes: """
            <p><b>What's New in Toolbox 1.1</b></p>
            <ul>
              <li>Inline Settings update checker with progress bar, version badge, and last checked timestamp.</li>
              <li>Custom dark update dialog shown only when a new release is ready.</li>
              <li>Update-available indicators across the sidebar, dashboard banner, and status bar menu.</li>
            </ul>
            """
        )
        guard let view = controller.window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }
}
