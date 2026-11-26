import AppKit
import Carbon
import CoreAudio
import CoreGraphics
import Foundation
import SwiftUI

/// Built-in diagnostic & regression test runner (`Toolbox --self-test`).
/// Runs isolated checks without modifying user config or requiring XCTest.
@MainActor
enum SelfTestRunner {
    private static var failures: [String] = []

    static func runAll() -> Int32 {
        failures.removeAll()
        print("Running Toolbox self-tests...")

        testShortcutSpecTokensAndDisplaySpacing()
        testLegacyV1ConfigMigrationAndExtensions()
        testGeneralConfigDefaults()
        testNavigationHistoryAndPreservation()
        testClipboardCaptureDedupConcealedAndPinning()
        testClipboardImageHistory()
        testClipboardPanelDoesNotHideOnDeactivate()
        testClipboardDeleteAndPopoverUIState()
        testClipboardPinnedReordering()
        testKeepAwakePmsetParsing()
        testHotKeyManagerRegistrationAndUnregistration()
        testCustomCommandsShellExecution()
        testModuleRegistryAndSettingsViews()
        testKeepAwakeLifecycle()
        testMasterTogglePauseResumeAndInstantPopover()
        testScrollDirectionConfigAndMigration()
        testScrollInversionClassificationAndInversion()
        testScrollDirectionModuleLifecycleAndRegistry()
        testDockMinimizeWindowsBehaviorAndPreFilter()
        testDockMinimizeDecideMatrix()
        testUpdateManagerAndCustomDialog()
        testMenuBarCustomizationOrderAndVisibility()
        testPortScannerParsersAndElevatedMerge()
        testPortKillerSafetyAndLiveLoopbackListener()
        testDeveloperModeAndSimulations()
        testCleanLockEventFilteringAndLifecycle()
        testCallControlsConfigAndCoreAudioEnumeration()
        testCallControlsShortcutRemapper()
        testCallControlsTypingMicStateMachine()
        testCallControlsHotKeyConflictsAndLifecycle()
        testCallControlsDeveloperSimulation()
        testCallControlsBluetoothMicLock()
        testScreenOCRConfigAndLifecycle()
        testScreenOCREngineRecognition()
        testMultiScreenOnboardingClipboardScrollAndMicSync()
        testSupportLinks()
        testPermissionsFlowAndPointerCursorSheetDealloc()
        testForcedDarkAppearanceAndProminentButtons()
        testHUDToastSizingAndPositioning()
        testWindowSnapperGeometryAndCoordinateConversion()
        testWindowSnapperMinSizeClampingAndDragLogic()
        testWindowSnapperDisplayRegistryAndUndoStack()
        testWindowSnapperConfigHotKeysProfilesAndLifecycle()
        testWindowDragMonitorEndToEndLifecycle()
        testFinderEnhancerConfigAndMigration()
        testFinderCutStateMachineAndKeyInterceptor()
        testLastWindowQuitEligibilityAndWindowCounting()
        testFinderEnhancerModuleLifecycleAndRegistry()

        if failures.isEmpty {
            print("All 47 self-test suites passed.")
            return 0
        } else {
            for f in failures {
                fputs("FAIL: \(f)\n", stderr)
            }
            return 1
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures.append(message)
        }
    }

    private static func testShortcutSpecTokensAndDisplaySpacing() {
        let shortcut = ShortcutSpec(key: "d", modifiers: [.command, .option, .shift])
        expect(shortcut.tokens == ["⌥", "⇧", "⌘", "D"], "ShortcutSpec.tokens order/content mismatch: \(shortcut.tokens)")
        expect(shortcut.displayString == "⌥ ⇧ ⌘ D", "ShortcutSpec.displayString spacing mismatch: \(shortcut.displayString)")
        expect(shortcut.carbonKeyCode != nil, "ShortcutSpec.carbonKeyCode should resolve 'd'")

        if let data = try? JSONEncoder().encode(shortcut),
           let decoded = try? JSONDecoder().decode(ShortcutSpec.self, from: data) {
            expect(decoded == shortcut, "ShortcutSpec Codable round-trip mismatch")
        } else {
            failures.append("ShortcutSpec Codable encode/decode failed")
        }

        // Unbound / empty spec
        expect(ShortcutSpec.none.isEmpty, "ShortcutSpec.none should be empty")
        expect(ShortcutSpec.none.tokens.isEmpty, "ShortcutSpec.none.tokens should be empty")
        expect(ShortcutSpec.none.displayString.isEmpty, "ShortcutSpec.none.displayString should be empty")
        expect(ShortcutSpec.none.carbonKeyCode == nil, "ShortcutSpec.none.carbonKeyCode should be nil")

        // Function key, arrow key, special glyph, and modifier normalization
        let fnKey = ShortcutSpec(key: "f5", modifiers: [])
        expect(fnKey.isFunctionKey, "f5 should be recognized as a function key")
        expect(fnKey.tokens == ["F5"], "Function key tokens mismatch: \(fnKey.tokens)")
        expect(fnKey.carbonKeyCode != nil, "ShortcutSpec.carbonKeyCode should resolve 'f5'")

        let arrowKey = ShortcutSpec(key: "up", modifiers: [.option, .control])
        expect(arrowKey.tokens == ["⌃", "⌥", "↑"], "Arrow key tokens mismatch: \(arrowKey.tokens)")
        expect(arrowKey.displayString == "⌃ ⌥ ↑", "Arrow key displayString mismatch: \(arrowKey.displayString)")
        expect(arrowKey.carbonKeyCode != nil, "ShortcutSpec.carbonKeyCode should resolve 'up'")

        let returnKey = ShortcutSpec(key: "return", modifiers: [.command])
        expect(returnKey.tokens == ["⌘", "↩"], "Return key tokens mismatch: \(returnKey.tokens)")

        let unnormalized = ShortcutSpec(key: "D", modifiers: [.command, .shift, .option, .command])
        expect(unnormalized == shortcut, "ShortcutSpec should normalize key case, modifier order, and duplicates")
    }

    private static func testLegacyV1ConfigMigrationAndExtensions() {
        let legacyV1JSON = """
        {
          "version": 1,
          "dockMinimize": {
            "enabled": true,
            "hideInsteadOfMinimize": true,
            "excludedBundleIDs": ["com.apple.finder", "com.apple.Terminal"]
          },
          "clipboard": {
            "enabled": true,
            "maxItems": 42,
            "pasteAutomatically": false,
            "pollIntervalMs": 350
          },
          "extensions": {
            "my_plugin": { "threshold": 3.5, "active": true }
          }
        }
        """
        guard let data = legacyV1JSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) else {
            failures.append("Failed to decode legacy v1 JSON config")
            return
        }

        expect(decoded.dockMinimize.actionMode == .hideApp, "Legacy hideInsteadOfMinimize should migrate to .hideApp")
        expect(decoded.dockMinimize.excludedBundleIDs == ["com.apple.finder", "com.apple.Terminal"], "Excluded bundle IDs mismatch")
        expect(decoded.clipboard.maxItems == 42, "Clipboard maxItems mismatch")
        expect(!decoded.clipboard.pasteAutomatically, "Clipboard pasteAutomatically mismatch")
        expect(decoded.clipboard.shortcut == ShortcutSpec(key: "v", modifiers: [.command, .option]), "Clipboard default shortcut mismatch")
        expect(decoded.clipboard.captureImages && decoded.clipboard.maxImageItems == 15 && decoded.clipboard.maxImageSizeMB == 20, "Legacy ClipboardConfig should receive image-history defaults")
        expect(decoded.extensions["my_plugin"] == .object(["threshold": .number(3.5), "active": .bool(true)]), "Extensions JSONValue mismatch")
    }

    private static func testClipboardCaptureDedupConcealedAndPinning() {
        let clipboard = ClipboardModule()
        clipboard.clearHistory(keepPinned: false)

        var cfg = ToolboxConfig()
        cfg.clipboard.maxItems = 3
        cfg.clipboard.deduplicate = true
        cfg.clipboard.ignoreConcealedTypes = true
        clipboard.reload(with: cfg)
        // Clear any item captured from the live system pasteboard during start()
        clipboard.clearHistory(keepPinned: false)

        clipboard.recordText(
            "super-secret-password",
            pasteboardTypes: [NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]
        )
        expect(clipboard.entries.isEmpty, "Concealed pasteboard type should be ignored")

        clipboard.recordText("first")
        clipboard.recordText("second")
        clipboard.recordText("first")
        expect(clipboard.entries.map(\.text) == ["first", "second"], "Clipboard deduplication order mismatch")

        let second = clipboard.entries[1]
        clipboard.togglePin(second)
        clipboard.renameEntry(second, title: "My Snippet")
        clipboard.recordText("third")
        clipboard.recordText("fourth")

        expect(clipboard.entries.count == 3, "Clipboard history should respect maxItems=3")
        expect(clipboard.entries.contains(where: { $0.text == "second" && $0.isPinned && $0.customTitle == "My Snippet" }), "Pinned & renamed entry should survive trim")

        // Unpinned history persistence across restarts (with persistHistory toggle)
        let historyFileURL = ConfigManager.shared.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("clipboard_history.json")
        expect(FileManager.default.fileExists(atPath: historyFileURL.path), "Unpinned clipboard history should be saved to clipboard_history.json when persistHistory is enabled")

        let restoredClipboard = ClipboardModule()
        restoredClipboard.reload(with: cfg)
        expect(
            restoredClipboard.entries.contains(where: { $0.text == "fourth" && !$0.isPinned }),
            "New ClipboardModule instance should restore unpinned history when persistHistory is true (got: \(restoredClipboard.entries.map(\.text)))"
        )
        restoredClipboard.stop()

        clipboard.clearHistory(keepPinned: true)
        expect(clipboard.entries.map(\.text) == ["second"], "clearHistory(keepPinned: true) should keep pinned items")
        expect(!FileManager.default.fileExists(atPath: historyFileURL.path), "clearHistory(keepPinned: true) should delete clipboard_history.json")

        clipboard.recordText("temporary")
        expect(FileManager.default.fileExists(atPath: historyFileURL.path), "Recording unpinned item should recreate clipboard_history.json")
        cfg.clipboard.persistHistory = false
        clipboard.reload(with: cfg)
        expect(!FileManager.default.fileExists(atPath: historyFileURL.path), "Disabling persistHistory must delete clipboard_history.json")

        clipboard.clearHistory(keepPinned: false)
        clipboard.stop()
    }

    private static func testClipboardImageHistory() {
        func makeImage(width: Int = 320, height: Int = 200, color: CGColor) -> CGImage? {
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }

        let legacyEntryJSON = #"{"id":"6CFF2A75-66F2-42E7-9F60-9D49FC6B93E2","text":"legacy","copiedAt":0}"#
        if let decoded = try? JSONDecoder().decode(ClipboardEntry.self, from: Data(legacyEntryJSON.utf8)) {
            expect(decoded.kind == .text && decoded.image == nil, "Legacy ClipboardEntry should decode as text without image metadata")
        } else {
            failures.append("Failed to decode legacy ClipboardEntry JSON")
        }
        if let legacyConfig = try? JSONDecoder().decode(ClipboardConfig.self, from: Data("{}".utf8)) {
            expect(legacyConfig.captureImages && legacyConfig.maxImageItems == 15 && legacyConfig.maxImageSizeMB == 20, "Legacy ClipboardConfig image defaults mismatch")
        } else {
            failures.append("Failed to decode legacy ClipboardConfig JSON")
        }

        let fileURL = NSPasteboard.PasteboardType.fileURL
        let tiff = NSPasteboard.PasteboardType.tiff
        let png = NSPasteboard.PasteboardType.png
        expect(ClipboardModule.classifyPasteboard(types: [fileURL, tiff], text: nil) == .ignored, "Finder file icon TIFF should be ignored")
        expect(ClipboardModule.classifyPasteboard(types: [fileURL, tiff], text: "file name") == .text, "Finder guard should still preserve real text")
        expect(ClipboardModule.classifyPasteboard(types: [tiff], text: "rich text") == .text, "Text should take precedence over a rich-text TIFF preview")
        expect(ClipboardModule.classifyPasteboard(types: [png, tiff], text: nil) == .image(png), "PNG should take priority over TIFF")
        expect(ClipboardModule.classifyPasteboard(types: [tiff], text: "") == .image(tiff), "A TIFF-only pasteboard should capture an image")
        expect(ClipboardModule.classifyPasteboard(types: [png], text: nil, captureImages: false) == .ignored, "Disabled image capture should ignore PNG")
        expect(ClipboardModule.classifyPasteboard(types: [png, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], text: nil) == .ignored, "Concealed images should be ignored")
        expect(!ClipboardModule.isImagePayloadAllowed(byteCount: 20 * 1024 * 1024 + 1, maxImageSizeMB: 20), "Raw image payload above maxImageSizeMB should be rejected")
        expect(ClipboardModule.isImagePayloadAllowed(byteCount: 20 * 1024 * 1024, maxImageSizeMB: 20), "Raw image payload at maxImageSizeMB should be accepted")

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardImageStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let store = ClipboardImageStore(directoryURL: tempDirectory)
        guard let redImage = makeImage(color: CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1)),
              let first = try? store.saveImage(redImage),
              let duplicate = try? store.saveImage(redImage) else {
            failures.append("ClipboardImageStore failed to save synthetic CGImage")
            return
        }
        expect(first.pixelWidth == 320 && first.pixelHeight == 200, "ClipboardImageStore should preserve exact pixel dimensions")
        expect(first.sha256.count == 64 && first.sha256 == duplicate.sha256, "Normalized duplicate PNGs should have matching SHA-256 hashes")
        expect(FileManager.default.fileExists(atPath: store.fullImageURL(for: first).path), "ClipboardImageStore should create the full PNG")
        expect(FileManager.default.fileExists(atPath: store.thumbnailURL(for: first).path), "ClipboardImageStore should create the thumbnail PNG")
        if let thumbnail = store.thumbnail(for: first) {
            expect(max(thumbnail.size.width, thumbnail.size.height) <= 240, "Clipboard thumbnail should be at most 240 px")
        } else {
            failures.append("ClipboardImageStore failed to load its thumbnail")
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: store.fullImageURL(for: first).path),
           let permissions = attributes[.posixPermissions] as? NSNumber {
            expect(permissions.intValue == 0o600, "Clipboard image files should be owner-only (0600)")
        } else {
            failures.append("Could not inspect clipboard image file permissions")
        }
        expect(store.diskUsage() > 0, "Clipboard image disk usage should include saved PNGs")

        let orphanURL = tempDirectory.appendingPathComponent("orphan.png")
        try? Data("orphan".utf8).write(to: orphanURL)
        store.sweepOrphanedFiles(referencedFilenames: [first.filename, first.thumbnailFilename])
        expect(FileManager.default.fileExists(atPath: store.fullImageURL(for: first).path), "Orphan sweep should keep referenced image files")
        expect(!FileManager.default.fileExists(atPath: store.fullImageURL(for: duplicate).path), "Orphan sweep should remove unreferenced image files")
        expect(!FileManager.default.fileExists(atPath: orphanURL.path), "Orphan sweep should remove unknown cache files")
        store.deleteImage(first)
        expect(!FileManager.default.fileExists(atPath: store.fullImageURL(for: first).path), "Deleting image metadata should remove its full PNG")
        expect(!FileManager.default.fileExists(atPath: store.thumbnailURL(for: first).path), "Deleting image metadata should remove its thumbnail")

        let clipboard = ClipboardModule()
        clipboard.clearHistory(keepPinned: false)
        var cfg = ToolboxConfig()
        cfg.clipboard.enabled = false
        cfg.clipboard.captureImages = false
        cfg.clipboard.maxItems = 10
        cfg.clipboard.maxImageItems = 1
        cfg.clipboard.deduplicate = true
        cfg.clipboard.persistHistory = true
        clipboard.reload(with: cfg)
        clipboard.clearHistory(keepPinned: false)

        let moduleStore = ClipboardImageStore(
            directoryURL: ConfigManager.shared.configURL
                .deletingLastPathComponent()
                .appendingPathComponent("clipboard-images", isDirectory: true)
        )
        guard let blueImage = makeImage(color: CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)),
              let greenImage = makeImage(width: 640, height: 360, color: CGColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1)),
              let redMetadata = try? moduleStore.saveImage(redImage),
              let redDuplicate = try? moduleStore.saveImage(redImage),
              let blueMetadata = try? moduleStore.saveImage(blueImage),
              let greenMetadata = try? moduleStore.saveImage(greenImage) else {
            failures.append("Failed to prepare module-level clipboard image tests")
            clipboard.stop()
            return
        }

        clipboard.recordImage(redMetadata)
        clipboard.recordImage(redDuplicate)
        expect(clipboard.entries.count == 1 && clipboard.entries[0].kind == .image, "Image deduplication should leave one entry")
        expect(clipboard.entries[0].image?.filename == redMetadata.filename, "Deduplication should reuse the original image files")
        expect(!FileManager.default.fileExists(atPath: moduleStore.fullImageURL(for: redDuplicate).path), "Deduplication should delete the redundant new files")
        if let imageEntry = clipboard.entries.first {
            expect(imageEntry.matches(query: "320 × 200", filter: .images), "Image search should match pixel dimensions")
            expect(imageEntry.matches(query: "PNG", filter: .all), "Image search should match format labels")
            expect(!imageEntry.matches(query: "", filter: .text), "Text filter should exclude image entries")
        }

        clipboard.togglePin(clipboard.entries[0])
        clipboard.renameEntry(clipboard.entries[0], title: "Pinned screenshot")
        clipboard.recordImage(redDuplicate)
        expect(clipboard.entries.count == 1 && clipboard.entries[0].isPinned && clipboard.entries[0].customTitle == "Pinned screenshot", "Recopying an image should preserve pin, title, and order")

        clipboard.recordImage(blueMetadata)
        clipboard.recordImage(greenMetadata)
        expect(clipboard.entries.filter { $0.kind == .image && !$0.isPinned }.count == 1, "maxImageItems should limit unpinned images independently of pinned images")
        expect(clipboard.entries.contains { $0.image?.sha256 == redMetadata.sha256 && $0.isPinned }, "Pinned image should survive image-limit eviction")
        expect(!clipboard.entries.contains { $0.image?.sha256 == blueMetadata.sha256 }, "Older unpinned image should be evicted")
        expect(!FileManager.default.fileExists(atPath: moduleStore.fullImageURL(for: blueMetadata).path), "Evicting an unreferenced image should delete its PNG")
        expect(FileManager.default.fileExists(atPath: moduleStore.fullImageURL(for: redMetadata).path), "Eviction must not delete pinned image files")

        clipboard.clearImageCache(keepPinned: true)
        expect(clipboard.entries.count == 1 && clipboard.entries[0].isPinned, "Clearing unpinned image cache should preserve pinned images")
        clipboard.clearImageCache(keepPinned: false)
        expect(clipboard.entries.isEmpty, "Clearing all image cache should remove pinned image entries too")
        expect(!FileManager.default.fileExists(atPath: moduleStore.fullImageURL(for: redMetadata).path), "Clearing all image cache should delete pinned image files")

        guard let sharedMetadata = try? moduleStore.saveImage(blueImage) else {
            failures.append("Failed to prepare shared image deletion test")
            clipboard.stop()
            return
        }
        cfg.clipboard.deduplicate = false
        cfg.clipboard.maxImageItems = 5
        clipboard.reload(with: cfg)
        clipboard.recordImage(sharedMetadata)
        clipboard.recordImage(sharedMetadata)
        let sharedEntries = clipboard.entries.filter { $0.image?.filename == sharedMetadata.filename }
        expect(sharedEntries.count == 2, "Disabled deduplication should allow entries sharing image files")
        if let firstShared = sharedEntries.first {
            clipboard.deleteEntry(firstShared)
        }
        expect(FileManager.default.fileExists(atPath: moduleStore.fullImageURL(for: sharedMetadata).path), "Deleting one entry must preserve image files still referenced by another")
        clipboard.clearHistory(keepPinned: false)
        expect(!FileManager.default.fileExists(atPath: moduleStore.fullImageURL(for: sharedMetadata).path), "Deleting the final reference should remove image files")

        guard let temporaryMetadata = try? moduleStore.saveImage(greenImage) else {
            failures.append("Failed to prepare nonpersistent image test")
            clipboard.stop()
            return
        }
        clipboard.recordImage(temporaryMetadata)
        cfg.clipboard.persistHistory = false
        clipboard.reload(with: cfg)
        expect(!clipboard.entries.contains { $0.image?.sha256 == temporaryMetadata.sha256 }, "Disabling history persistence should purge unpinned image entries")
        expect(!FileManager.default.fileExists(atPath: moduleStore.fullImageURL(for: temporaryMetadata).path), "Disabling history persistence should purge unpinned image files")

        let orphanedCacheURL = ConfigManager.shared.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("clipboard-images", isDirectory: true)
            .appendingPathComponent("orphaned-cache.png")
        try? Data("orphan".utf8).write(to: orphanedCacheURL)
        clipboard.clearImageCache(keepPinned: true)
        expect(!FileManager.default.fileExists(atPath: orphanedCacheURL.path), "Clear Image Cache should sweep orphans even with no image entries")

        clipboard.clearHistory(keepPinned: false)
        clipboard.stop()
    }

    private static func testGeneralConfigDefaults() {
        let cfg = ToolboxConfig()
        expect(cfg.general.showInDock, "Toolbox should show in Dock by default")
        expect(cfg.general.showInMenuBar, "Toolbox should show in Menu Bar by default")
        expect(cfg.general.openDashboardOnDockClick, "Toolbox should reopen Dashboard on Dock click by default")
        expect(cfg.general.dockQuitBehavior == .closeWindow, "Dock Quit behavior should default to closeWindow")
        expect(!cfg.keepAwake.enabled, "KeepAwake should default to disabled (off by default)")
        expect(!cfg.screenOCR.enabled, "ScreenOCR should default to disabled (off by default)")
        expect(cfg.screenOCR.shortcut == ShortcutSpec(key: "0", modifiers: [.command, .shift]), "ScreenOCR default shortcut should be ⇧ ⌘ 0")
        expect(!cfg.customCommands.enabled, "CustomCommands should default to disabled (off by default)")
        expect(!cfg.scrollDirection.enabled, "ScrollDirection should default to disabled (off by default)")
        expect(cfg.dockMinimize.excludedBundleIDs.isEmpty, "No apps should be excluded by default")
        expect(DockActionMode.allCases.contains(.sendToBack), "DockActionMode should include sendToBack")
        expect(cfg.clipboard.maxItems == 25, "Clipboard default maxItems should be 25")
        expect(cfg.clipboard.persistHistory, "Clipboard default persistHistory should be true")
        expect(cfg.clipboard.captureImages, "Clipboard image capture should default to true")
        expect(cfg.clipboard.maxImageItems == 15, "Clipboard default maxImageItems should be 15")
        expect(cfg.clipboard.maxImageSizeMB == 20, "Clipboard default maxImageSizeMB should be 20")
        expect(cfg.general.showModuleCardDetails, "Dashboard showModuleCardDetails should default to true")
        expect(cfg.general.textSize == .standard, "General textSize should default to .standard")

        if let legacyGeneral = try? JSONDecoder().decode(GeneralConfig.self, from: Data("{}".utf8)) {
            expect(legacyGeneral.showModuleCardDetails, "Decoding legacy GeneralConfig without showModuleCardDetails should default to true")
            expect(legacyGeneral.textSize == .standard, "Decoding legacy GeneralConfig without textSize should default to .standard")
        } else {
            failures.append("Failed to decode legacy GeneralConfig")
        }

        var compactCfg = ToolboxConfig()
        compactCfg.general.showModuleCardDetails = false
        if let encoded = try? JSONEncoder().encode(compactCfg),
           let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: encoded) {
            expect(!decoded.general.showModuleCardDetails, "showModuleCardDetails=false should round-trip through Codable")
        } else {
            failures.append("ToolboxConfig Codable round-trip for showModuleCardDetails=false failed")
        }

        for size in AppTextSize.allCases {
            var sizeCfg = ToolboxConfig()
            sizeCfg.general.textSize = size
            if let encoded = try? JSONEncoder().encode(sizeCfg),
               let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: encoded) {
                expect(decoded.general.textSize == size, "textSize=\(size.rawValue) should round-trip through Codable")
            } else {
                failures.append("ToolboxConfig Codable round-trip for textSize=\(size.rawValue) failed")
            }
            expect(cfg.runtimeBehaviorEquals(sizeCfg), "runtimeBehaviorEquals should ignore general.textSize=\(size.rawValue)")
        }

        for base in [CGFloat(10), CGFloat(12), CGFloat(13), CGFloat(15)] {
            let small = AppTextSize.small.scaledPointSize(base)
            let standard = AppTextSize.standard.scaledPointSize(base)
            let large = AppTextSize.large.scaledPointSize(base)
            let extraLarge = AppTextSize.extraLarge.scaledPointSize(base)
            expect(standard == base, "AppTextSize.standard.scaledPointSize(\(base)) must equal \(base), got \(standard)")
            expect(
                small < standard && standard < large && large < extraLarge,
                "AppTextSize.scaledPointSize(\(base)) must be strictly monotonic: \(small) < \(standard) < \(large) < \(extraLarge)"
            )
        }

        let previousTextSize = ConfigManager.shared.config.general.textSize
        defer { ConfigManager.shared.config.general.textSize = previousTextSize }

        func measureSampleTextSize(for textSize: AppTextSize) -> CGSize {
            ConfigManager.shared.config.general.textSize = textSize
            let hosting = NSHostingView(
                rootView: Text("Toolbox Readability Sample")
                    .toolboxFont(.body)
                    .toolboxDarkAppearance()
            )
            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize
        }

        let smallSample = measureSampleTextSize(for: .small)
        let standardSample = measureSampleTextSize(for: .standard)
        let largeSample = measureSampleTextSize(for: .large)
        let extraLargeSample = measureSampleTextSize(for: .extraLarge)
        expect(
            smallSample.width < standardSample.width
                && standardSample.width < largeSample.width
                && largeSample.width < extraLargeSample.width,
            "Live SwiftUI text width must scale across text sizes: \(smallSample.width) < \(standardSample.width) < \(largeSample.width) < \(extraLargeSample.width)"
        )
        expect(
            largeSample.height > standardSample.height,
            "Live SwiftUI text height must grow at .large: \(largeSample.height) > \(standardSample.height)"
        )

        ConfigManager.shared.config.general.textSize = .standard
        let standardToast = HUDToast.measuredSize(title: "Toolbox Readability Scaling Toast", symbol: "checkmark.circle.fill", tint: .green)
        ConfigManager.shared.config.general.textSize = .large
        let largeToast = HUDToast.measuredSize(title: "Toolbox Readability Scaling Toast", symbol: "checkmark.circle.fill", tint: .green)
        expect(
            largeToast.width > standardToast.width && largeToast.height > standardToast.height,
            "HUDToast size must scale at .large: standard=\(standardToast), large=\(largeToast)"
        )
        ConfigManager.shared.config.general.textSize = previousTextSize

        expect(cfg.runtimeBehaviorEquals(compactCfg), "runtimeBehaviorEquals should ignore showModuleCardDetails differences")
        var pausedCfg = cfg
        pausedCfg.general.appEnabled = false
        expect(!cfg.runtimeBehaviorEquals(pausedCfg), "runtimeBehaviorEquals should return false when general.appEnabled differs")
        var toggledModuleCfg = cfg
        toggledModuleCfg.dockMinimize.enabled.toggle()
        expect(!cfg.runtimeBehaviorEquals(toggledModuleCfg), "runtimeBehaviorEquals should return false when dockMinimize.enabled differs")

        expect(DashboardLayoutMetrics.columnCount(forAvailableWidth: 400) == 1, "400pt available width should use 1 column")
        expect(DashboardLayoutMetrics.columnCount(forAvailableWidth: 547) == 2, "547pt available width should use 2 columns")
        expect(DashboardLayoutMetrics.columnCount(forAvailableWidth: 667) == 2, "667pt available width should use 2 columns")
        expect(DashboardLayoutMetrics.columnCount(forAvailableWidth: 809) == 2, "809pt available width should use 2 columns")
        expect(DashboardLayoutMetrics.columnCount(forAvailableWidth: 810) == 3, "810pt available width should use 3 columns")
        expect(DashboardLayoutMetrics.columnCount(forAvailableWidth: 867) == 3, "867pt available width should use 3 columns")
        expect(DashboardLayoutMetrics.gridSpacing(showDetails: true) == 14, "Detailed grid spacing should be 14pt")
        expect(DashboardLayoutMetrics.gridSpacing(showDetails: false) == 18, "Compact grid spacing should be 18pt")
    }

    private static func testNavigationHistoryAndPreservation() {
        let nav = NavigationState()
        expect(nav.selection == .dashboard, "Initial selection should be dashboard")
        expect(nav.isSidebarVisible, "Sidebar should start visible by default")
        nav.toggleSidebar()
        expect(!nav.isSidebarVisible, "Sidebar should collapse when toggled")
        nav.toggleSidebar()
        expect(nav.isSidebarVisible, "Sidebar should reopen when toggled again")
        expect(!nav.canGoBack, "Initial back history should be empty")
        expect(!nav.canGoForward, "Initial forward history should be empty")
        expect(nav.previousDestination == nil, "Initial previousDestination should be nil")
        expect(nav.nextDestination == nil, "Initial nextDestination should be nil")
        expect(nav.backHelpText == "Back (⌘[)", "Initial backHelpText mismatch: \(nav.backHelpText)")
        expect(nav.forwardHelpText == "Forward (⌘])", "Initial forwardHelpText mismatch: \(nav.forwardHelpText)")
        expect(!nav.goBack(), "goBack() at root with empty history should return false")
        expect(!nav.goForward(), "goForward() with empty forwardHistory should return false")

        nav.navigate(to: .module("clipboard"))
        expect(nav.previousDestination == .dashboard, "previousDestination after navigating from dashboard should be dashboard")
        expect(nav.backHelpText == "Back to Dashboard (⌘[)", "backHelpText mismatch: \(nav.backHelpText)")

        nav.navigate(to: .jsonConfig)
        expect(nav.canGoBack, "Should be able to go back after navigation")
        expect(!nav.canGoForward, "Forward history should be empty before going back")
        expect(nav.selection == .jsonConfig, "Current selection should be jsonConfig")
        expect(nav.previousDestination == .module("clipboard"), "previousDestination should be clipboard module")

        // Going back populates forwardHistory; a no-op navigate(to: current) must preserve it.
        expect(nav.goBack(), "goBack() from jsonConfig should return true")
        expect(nav.selection == .module("clipboard"), "Back should return to clipboard module")
        expect(nav.canGoForward, "Should be able to go forward after going back")
        expect(nav.nextDestination == .jsonConfig, "nextDestination should be jsonConfig")
        expect(nav.forwardHelpText == "Forward to JSON Config (⌘])", "forwardHelpText mismatch: \(nav.forwardHelpText)")

        nav.navigate(to: .module("clipboard"))
        expect(nav.canGoForward, "No-op navigate(to: current) must preserve forwardHistory")

        expect(nav.goForward(), "goForward() should return true when forwardHistory is non-empty")
        expect(nav.selection == .jsonConfig, "Forward should restore jsonConfig")
        expect(!nav.canGoForward, "Forward history should be empty after advancing to the end")

        expect(nav.goBack(), "goBack() should return true")
        expect(nav.goBack(), "Second goBack() should return true")
        expect(nav.selection == .dashboard, "Back should return to dashboard")
        expect(nav.canGoForward, "Forward history should have two entries after going back twice")
        expect(!nav.goBack(), "goBack() at dashboard with empty history should return false")

        // Branching navigation clears forwardHistory.
        nav.navigate(to: .settings)
        expect(!nav.canGoForward, "Navigating to a new branch must clear forwardHistory")

        // Clicking "< Back to Dashboard" appends to history so mouse Back can undo it.
        nav.navigate(to: .dashboard)
        expect(nav.selection == .dashboard, "Navigating to dashboard should set selection to dashboard")
        expect(nav.goBack(), "Back after returning to dashboard should undo back to settings")
        expect(nav.selection == .settings, "Back after returning to dashboard should restore settings")
        expect(nav.goForward(), "Forward should return to dashboard")
        expect(nav.selection == .dashboard, "Forward should restore dashboard")

        // History stack capping at 50 entries.
        nav.resetHistoryForTesting(selection: .dashboard)
        let capCycle: [SidebarDestination] = [.module("clipboard"), .settings, .jsonConfig, .support]
        for i in 0..<60 {
            nav.navigate(to: capCycle[i % capCycle.count])
        }
        expect(nav.history.count == 50, "History should be capped at 50 entries (got \(nav.history.count))")
        var backSteps = 0
        while nav.goBack() {
            backSteps += 1
            if backSteps > 60 { break }
        }
        // 50 steps pop the capped history stack, plus 1 implicit fallback step to .dashboard when the oldest retained entry is not .dashboard.
        expect(backSteps == 51, "Expected 51 back steps (50 history entries + implicit dashboard fallback, got \(backSteps))")
        expect(nav.selection == .dashboard, "Exhausting goBack() must end at dashboard")
        expect(nav.forwardHistory.count == 50, "Forward history should also cap at 50 entries (got \(nav.forwardHistory.count))")

        // Prune developer destinations across both stacks and deduplicate consecutive / top-matching entries.
        nav.resetHistoryForTesting(selection: .dashboard)
        nav.navigate(to: .settings)
        nav.navigate(to: .developer(.eventsAndTaps))
        nav.navigate(to: .settings)
        nav.navigate(to: .developer(.updates))
        nav.navigate(to: .support)
        expect(nav.goBack(), "goBack() to developer(.updates) should succeed")
        expect(nav.selection == .developer(.updates), "Expected selection to be developer(.updates)")
        nav.pruneDeveloperDestinations(fallback: .settings)
        expect(nav.selection == .settings, "pruneDeveloperDestinations should fall back to settings")
        expect(nav.history == [.dashboard], "Pruning should remove developer items and collapse duplicate settings entries (got \(nav.history))")
        expect(nav.forwardHistory == [.support], "Pruning should preserve valid forwardHistory (got \(nav.forwardHistory))")

        // Also check top-matching forwardHistory deduplication when fallback matches forward item.
        nav.resetHistoryForTesting(selection: .dashboard)
        nav.navigate(to: .developer(.updates))
        nav.navigate(to: .settings)
        _ = nav.goBack()
        nav.pruneDeveloperDestinations(fallback: .settings)
        expect(nav.selection == .settings, "Selection should fall back to settings")
        expect(nav.forwardHistory.isEmpty, "Pruning should strip trailing forwardHistory matching fallback destination")

        // Static button & swipe direction mapping checks.
        expect(ToolboxWindow.navigationDirection(forOtherMouseButton: 2) == nil, "Middle mouse button (2) must not trigger navigation")
        expect(ToolboxWindow.navigationDirection(forOtherMouseButton: 3) == .back, "Mouse button 3 must map to back")
        expect(ToolboxWindow.navigationDirection(forOtherMouseButton: 4) == .forward, "Mouse button 4 must map to forward")
        expect(ToolboxWindow.navigationDirection(forOtherMouseButton: 5) == nil, "Mouse button 5 must not trigger navigation")
        expect(ToolboxWindow.navigationDirection(forSwipeDeltaX: 1.0) == .back, "Swipe deltaX > 0 must map to back")
        expect(ToolboxWindow.navigationDirection(forSwipeDeltaX: -1.0) == .forward, "Swipe deltaX < 0 must map to forward")
        expect(ToolboxWindow.navigationDirection(forSwipeDeltaX: 0.0) == nil, "Swipe deltaX == 0 must not trigger navigation")

        // End-to-end ToolboxWindow mouse side-button and keyboard equivalent dispatch.
        guard let win = MainWindowController.shared.ensureWindow() as? ToolboxWindow else {
            failures.append("MainWindowController.ensureWindow() must return a ToolboxWindow")
            return
        }
        let mainNav = MainWindowController.shared.navState
        let prevOnboarding = PermissionsManager.shared.isPresentingOnboardingModal
        defer {
            PermissionsManager.shared.isPresentingOnboardingModal = prevOnboarding
            win.makeFirstResponder(nil)
            mainNav.resetHistoryForTesting(selection: .dashboard)
        }

        mainNav.resetHistoryForTesting(selection: .dashboard)
        mainNav.navigate(to: .module("clipboard"))
        mainNav.navigate(to: .settings)

        func makeOtherMouseEvent(type: CGEventType, buttonNumber: Int64) -> NSEvent? {
            guard let cg = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: .zero,
                mouseButton: .center
            ) else { return nil }
            cg.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
            return NSEvent(cgEvent: cg)
        }

        if let backDown = makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 3),
           let backUp = makeOtherMouseEvent(type: .otherMouseUp, buttonNumber: 3) {
            expect(backDown.buttonNumber == 3, "Synthetic CGEvent otherMouseDown should preserve buttonNumber 3")
            win.sendEvent(backDown)
            win.sendEvent(backUp)
            expect(mainNav.selection == .module("clipboard"), "Mouse button 3 down+up must go back once to clipboard module")
        } else {
            failures.append("Failed to create synthetic mouse button 3 event")
        }

        if let middleDown = makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 2) {
            win.sendEvent(middleDown)
            expect(mainNav.selection == .module("clipboard"), "Middle mouse button (2) must not navigate")
        }

        if let forwardDown = makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 4),
           let forwardUp = makeOtherMouseEvent(type: .otherMouseUp, buttonNumber: 4) {
            expect(forwardDown.buttonNumber == 4, "Synthetic CGEvent otherMouseDown should preserve buttonNumber 4")
            win.sendEvent(forwardDown)
            win.sendEvent(forwardUp)
            expect(mainNav.selection == .settings, "Mouse button 4 down+up must go forward once to settings")
        } else {
            failures.append("Failed to create synthetic mouse button 4 event")
        }

        // Keyboard equivalents: ⌘ [, ⌘ ], ⌘ ←, ⌘ →
        if let cmdBack = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: win.windowNumber,
            context: nil,
            characters: "[",
            charactersIgnoringModifiers: "[",
            isARepeat: false,
            keyCode: 33
        ) {
            expect(win.performKeyEquivalent(with: cmdBack), "⌘ [ must be handled by ToolboxWindow")
            expect(mainNav.selection == .module("clipboard"), "⌘ [ must navigate back to clipboard")
        }
        if let cmdForward = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: win.windowNumber,
            context: nil,
            characters: "]",
            charactersIgnoringModifiers: "]",
            isARepeat: false,
            keyCode: 30
        ) {
            expect(win.performKeyEquivalent(with: cmdForward), "⌘ ] must be handled by ToolboxWindow")
            expect(mainNav.selection == .settings, "⌘ ] must navigate forward to settings")
        }

        let leftArrowStr = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let rightArrowStr = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        if let cmdLeft = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: win.windowNumber,
            context: nil,
            characters: leftArrowStr,
            charactersIgnoringModifiers: leftArrowStr,
            isARepeat: false,
            keyCode: 123
        ), let cmdRight = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: win.windowNumber,
            context: nil,
            characters: rightArrowStr,
            charactersIgnoringModifiers: rightArrowStr,
            isARepeat: false,
            keyCode: 124
        ) {
            expect(win.performKeyEquivalent(with: cmdLeft), "⌘ ← must be handled when no text editor is focused")
            expect(mainNav.selection == .module("clipboard"), "⌘ ← must navigate back")
            expect(win.performKeyEquivalent(with: cmdRight), "⌘ → must be handled when no text editor is focused")
            expect(mainNav.selection == .settings, "⌘ → must navigate forward")

            // While an NSTextView is firstResponder, ⌘ ← / ⌘ → must NOT navigate (preserve cursor jump to line start/end).
            let tempTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
            win.contentView?.addSubview(tempTextView)
            win.makeFirstResponder(tempTextView)
            expect(win.firstResponder === tempTextView, "Temporary NSTextView should become firstResponder")
            _ = win.performKeyEquivalent(with: cmdLeft)
            expect(mainNav.selection == .settings, "⌘ ← must NOT hijack line-start cursor movement inside NSTextView")
            _ = win.performKeyEquivalent(with: cmdRight)
            expect(mainNav.selection == .settings, "⌘ → must NOT hijack line-end cursor movement inside NSTextView")

            // ⌘ [ must still navigate back even while NSTextView is focused, committing responder cleanly.
            if let cmdBackInText = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: win.windowNumber,
                context: nil,
                characters: "[",
                charactersIgnoringModifiers: "[",
                isARepeat: false,
                keyCode: 33
            ) {
                expect(win.performKeyEquivalent(with: cmdBackInText), "⌘ [ should still navigate when NSTextView is focused")
                expect(mainNav.selection == .module("clipboard"), "⌘ [ should navigate back from NSTextView")
                expect(!(win.firstResponder is NSText), "Navigation should clear active text responder")
            }
            tempTextView.removeFromSuperview()
        }

        // Onboarding modal guard: mouse side buttons and keyboard shortcuts must not navigate while onboarding modal is shown.
        PermissionsManager.shared.isPresentingOnboardingModal = true
        let selectionBeforeModal = mainNav.selection
        let historyBeforeModal = mainNav.history
        let forwardBeforeModal = mainNav.forwardHistory
        if let backDown = makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 3),
           let forwardDown = makeOtherMouseEvent(type: .otherMouseDown, buttonNumber: 4) {
            win.sendEvent(backDown)
            win.sendEvent(forwardDown)
            expect(mainNav.selection == selectionBeforeModal, "Mouse Back/Forward must not navigate while onboarding modal is presented")
            expect(mainNav.history == historyBeforeModal && mainNav.forwardHistory == forwardBeforeModal,
                   "Mouse Back/Forward must not mutate navigation stacks while onboarding modal is presented")
        }
        if let cmdBack = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: win.windowNumber,
            context: nil,
            characters: "[",
            charactersIgnoringModifiers: "[",
            isARepeat: false,
            keyCode: 33
        ), let cmdForward = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: win.windowNumber,
            context: nil,
            characters: "]",
            charactersIgnoringModifiers: "]",
            isARepeat: false,
            keyCode: 30
        ) {
            _ = win.performKeyEquivalent(with: cmdBack)
            expect(mainNav.selection == selectionBeforeModal, "⌘ [ must not navigate while onboarding modal is presented")
            _ = win.performKeyEquivalent(with: cmdForward)
            expect(mainNav.selection == selectionBeforeModal, "⌘ ] must not navigate while onboarding modal is presented")
            expect(mainNav.history == historyBeforeModal && mainNav.forwardHistory == forwardBeforeModal,
                   "Keyboard shortcuts must not mutate navigation stacks while onboarding modal is presented")
        }
        if let cmdLeft = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: win.windowNumber,
            context: nil,
            characters: leftArrowStr,
            charactersIgnoringModifiers: leftArrowStr,
            isARepeat: false,
            keyCode: 123
        ), let cmdRight = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: win.windowNumber,
            context: nil,
            characters: rightArrowStr,
            charactersIgnoringModifiers: rightArrowStr,
            isARepeat: false,
            keyCode: 124
        ) {
            expect(!win.performKeyEquivalent(with: cmdLeft), "⌘ ← must not navigate while onboarding modal is presented")
            expect(!win.performKeyEquivalent(with: cmdRight), "⌘ → must not navigate while onboarding modal is presented")
            expect(mainNav.selection == selectionBeforeModal, "⌘ ← / ⌘ → must leave selection unchanged during onboarding modal")
        }
    }

    private static func testKeepAwakePmsetParsing() {
        let current = """
        System-wide power settings:
        Currently in use:
         disksleep            10
         displaysleep         60
         sleep                0
        """
        let custom = """
        Battery Power:
         displaysleep         10
        AC Power:
         displaysleep         60
        """
        let info = KeepAwakeModule.parsePmset(currentOutput: current, customOutput: custom)
        expect(info.activeDisplaySleepMinutes == 60, "Active displaysleep should be 60")
        expect(info.batteryDisplaySleepMinutes == 10, "Battery displaysleep should be 10")
        expect(info.acDisplaySleepMinutes == 60, "AC displaysleep should be 60")
    }

    private static func testClipboardPanelDoesNotHideOnDeactivate() {
        let clipboard = ClipboardModule()
        let panel = clipboard.ensurePanel(width: 360, height: 400)
        expect(!panel.hidesOnDeactivate, "Clipboard NSPanel must have hidesOnDeactivate = false")
        expect(panel.acceptsMouseMovedEvents, "Clipboard NSPanel must have acceptsMouseMovedEvents = true for row hover")
        expect(panel.styleMask.contains(.nonactivatingPanel), "Clipboard NSPanel must be nonactivatingPanel")
        clipboard.showPopover()
        expect(clipboard.isPopoverVisible, "Clipboard showPopover() should make panel visible")
        clipboard.hidePopover()
        expect(!clipboard.isPopoverVisible, "Clipboard hidePopover() should hide panel")
    }

    private static func testClipboardDeleteAndPopoverUIState() {
        let clipboard = ClipboardModule()
        var cfg = ToolboxConfig()
        cfg.clipboard.maxItems = 5
        clipboard.reload(with: cfg)
        clipboard.clearHistory(keepPinned: false)
        clipboard.recordText("first item")
        clipboard.recordText("second item")
        expect(clipboard.entries.count == 2, "Expected 2 recorded clipboard entries")
        let e1 = clipboard.entries[0]
        let e2 = clipboard.entries[1]

        let uiState = ClipboardPopoverUIState()
        uiState.resetForOpen(entries: clipboard.entries)
        expect(uiState.selectedEntryID == e1.id, "resetForOpen should select first entry")
        expect(uiState.pendingDeleteEntry == nil, "resetForOpen should clear pendingDeleteEntry")
        expect(!uiState.pendingClearAll, "resetForOpen should clear pendingClearAll")

        uiState.pendingDeleteEntry = e1
        uiState.pendingClearAll = true
        uiState.previewEntryID = e2.id
        uiState.hoveredEntryID = e1.id
        uiState.resetForOpen(entries: clipboard.entries)
        expect(uiState.pendingDeleteEntry == nil, "resetForOpen must reset pendingDeleteEntry")
        expect(!uiState.pendingClearAll, "resetForOpen must reset pendingClearAll")
        expect(uiState.previewEntryID == nil, "resetForOpen must reset previewEntryID")
        expect(uiState.hoveredEntryID == nil, "resetForOpen must clear hoveredEntryID")

        let refNow = Date(timeIntervalSince1970: 1_700_000_000)
        let pinnedSingle = ClipboardEntry(text: "a", copiedAt: refNow, isPinned: true)
        let pinnedFive = ClipboardEntry(text: "hello", copiedAt: refNow, isPinned: true)
        let pinnedMultiline = ClipboardEntry(text: "one\ntwo\n3rd", copiedAt: refNow, isPinned: true)
        expect(ClipboardPopoverView.formatRowMetadata(for: pinnedSingle, now: refNow) == "1 char", "Singular pinned metadata mismatch")
        expect(ClipboardPopoverView.formatRowMetadata(for: pinnedFive, now: refNow) == "5 chars", "Single-line pinned metadata must omit redundant Pinned label")
        expect(ClipboardPopoverView.formatRowMetadata(for: pinnedMultiline, now: refNow) == "3 lines · 11 chars", "Multiline pinned metadata mismatch")

        let recentNow = ClipboardEntry(text: "hi", copiedAt: refNow.addingTimeInterval(-10), isPinned: false)
        let recentMinutes = ClipboardEntry(text: "hi", copiedAt: refNow.addingTimeInterval(-5 * 60), isPinned: false)
        let recentHours = ClipboardEntry(text: "hi", copiedAt: refNow.addingTimeInterval(-2 * 3600), isPinned: false)
        let recentDays = ClipboardEntry(text: "line1\nline2", copiedAt: refNow.addingTimeInterval(-3 * 86400), isPinned: false)
        expect(ClipboardPopoverView.formatRowMetadata(for: recentNow, now: refNow) == "Just now · 2 chars", "Just now metadata mismatch")
        expect(ClipboardPopoverView.formatRowMetadata(for: recentMinutes, now: refNow) == "5m ago · 2 chars", "Minutes ago metadata mismatch")
        expect(ClipboardPopoverView.formatRowMetadata(for: recentHours, now: refNow) == "2h ago · 2 chars", "Hours ago metadata mismatch")
        expect(ClipboardPopoverView.formatRowMetadata(for: recentDays, now: refNow) == "3d ago · 2 lines · 11 chars", "Days ago multiline metadata mismatch")

        clipboard.deleteEntry(e1)
        expect(clipboard.entries.map(\.id) == [e2.id], "deleteEntry should remove target entry")
        clipboard.clearHistory(keepPinned: false)
        clipboard.stop()
    }

    private static func testClipboardPinnedReordering() {
        let clipboard = ClipboardModule()
        var cfg = ToolboxConfig()
        cfg.clipboard.enabled = false // keep the suite off the live pasteboard / hotkey
        cfg.clipboard.maxItems = 10
        cfg.clipboard.deduplicate = true
        cfg.clipboard.persistHistory = true
        clipboard.reload(with: cfg)
        clipboard.clearHistory(keepPinned: false)

        clipboard.recordText("alpha")
        clipboard.recordText("beta")
        clipboard.recordText("gamma")
        expect(clipboard.entries.map(\.text) == ["gamma", "beta", "alpha"], "Unpinned entries should stay newest-first")

        // Pin the oldest, then the middle one: the most recently pinned item goes on top.
        let alpha = clipboard.entries[2]
        let beta = clipboard.entries[1]
        clipboard.togglePin(alpha)
        clipboard.togglePin(beta)
        expect(clipboard.entries.map(\.text) == ["beta", "alpha", "gamma"], "Newly pinned item should land at the top of the pinned group")
        let pinnedIndexes = clipboard.entries.filter(\.isPinned).map(\.sortIndex)
        expect(pinnedIndexes == [0, 1], "Pinned sortIndex values should be dense in display order (got \(pinnedIndexes))")

        // Keyboard move: ⌘ ↓ moves the top pinned item down one slot (swap).
        clipboard.movePinnedEntry(clipboard.entries[0], by: 1)
        expect(clipboard.entries.map(\.text) == ["alpha", "beta", "gamma"], "movePinnedEntry(by: 1) should swap with the next pinned item (got \(clipboard.entries.map(\.text)))")

        // Drag moves use the entries' IDs (captured up front so each step targets
        // the same items, regardless of how the list reorders between steps).
        let topID = clipboard.entries[0].id
        let secondID = clipboard.entries[1].id

        // Dropping over the top half of a row keeps the item above it.
        // Alpha is already above beta, so this must be a no-op (idempotency).
        clipboard.movePinnedEntry(topID, relativeTo: secondID, insertAfter: false)
        expect(clipboard.entries.map(\.text) == ["alpha", "beta", "gamma"], "Drag into the top half of a row should be a no-op when the item is already above it (got \(clipboard.entries.map(\.text)))")

        // Dropping over the bottom half of a row places the item below it.
        clipboard.movePinnedEntry(topID, relativeTo: secondID, insertAfter: true)
        expect(clipboard.entries.map(\.text) == ["beta", "alpha", "gamma"], "Drag into the bottom half of a row should place the item below it (got \(clipboard.entries.map(\.text)))")

        // The same hover decision re-applied (drop-updated fires continuously) is a no-op.
        clipboard.movePinnedEntry(topID, relativeTo: secondID, insertAfter: true)
        expect(clipboard.entries.map(\.text) == ["beta", "alpha", "gamma"], "Repeated drag moves with the same decision should be idempotent (got \(clipboard.entries.map(\.text)))")

        // Re-copying a pinned item keeps its explicit pinned slot instead of jumping to the top.
        clipboard.recordText("alpha")
        expect(clipboard.entries.map(\.text) == ["beta", "alpha", "gamma"], "Re-copying a pinned item should keep its pinned position (got \(clipboard.entries.map(\.text)))")

        // Moving an unpinned item is a no-op (its order is chronological).
        let gamma = clipboard.entries.last
        clipboard.movePinnedEntry(gamma!, by: -1)
        expect(clipboard.entries.map(\.text) == ["beta", "alpha", "gamma"], "Moving an unpinned item should be a no-op")

        // 3+ pinned items: non-adjacent drag moves and filtered keyboard moves.
        clipboard.togglePin(gamma!) // lands on top: [gamma, beta, alpha]
        expect(clipboard.entries.map(\.text) == ["gamma", "beta", "alpha"], "Pinning third item should put it on top (got \(clipboard.entries.map(\.text)))")
        let idGamma = clipboard.entries[0].id
        let idBeta = clipboard.entries[1].id
        let idAlpha = clipboard.entries[2].id

        // Regression check for the broken `alreadyAfter` guard:
        // Dragging bottom (alpha) after top (gamma) must move alpha to slot 1 -> [gamma, alpha, beta].
        clipboard.movePinnedEntry(idAlpha, relativeTo: idGamma, insertAfter: true)
        expect(clipboard.entries.map(\.text) == ["gamma", "alpha", "beta"], "Dragging bottom item after top item should insert at slot 1 (got \(clipboard.entries.map(\.text)))")

        // Symmetric regression check:
        // Dragging top (gamma) before bottom (beta) must move gamma to slot 1 -> [alpha, gamma, beta].
        clipboard.movePinnedEntry(idGamma, relativeTo: idBeta, insertAfter: false)
        expect(clipboard.entries.map(\.text) == ["alpha", "gamma", "beta"], "Dragging top item before bottom item should insert at slot 1 (got \(clipboard.entries.map(\.text)))")

        // Already-adjacent moves remain no-ops.
        clipboard.movePinnedEntry(idAlpha, relativeTo: idGamma, insertAfter: false)
        expect(clipboard.entries.map(\.text) == ["alpha", "gamma", "beta"], "Adjacent before-move should be a no-op")
        clipboard.movePinnedEntry(idGamma, relativeTo: idAlpha, insertAfter: true)
        expect(clipboard.entries.map(\.text) == ["alpha", "gamma", "beta"], "Adjacent after-move should be a no-op")

        // Filtered ⌘ ↑ / ⌘ ↓ moves operate within the visible filtered subset.
        clipboard.recordText("delta")
        clipboard.togglePin(clipboard.entries.last!) // [delta, alpha, gamma, beta]
        expect(clipboard.entries.map(\.text) == ["delta", "alpha", "gamma", "beta"], "Four pinned items should be ordered cleanly")
        let filteredSlice = [clipboard.entries[0], clipboard.entries[3]] // [delta, beta]
        clipboard.movePinnedEntry(filteredSlice[1], by: -1, within: filteredSlice)
        expect(clipboard.entries.map(\.text) == ["beta", "delta", "alpha", "gamma"], "Filtered move up should place beta before delta (got \(clipboard.entries.map(\.text)))")

        // Naming an unpinned item auto-pins it at slot 0 and keeps sortIndex dense.
        clipboard.recordText("unpinned-note")
        let unpinnedItem = clipboard.entries.last!
        expect(!unpinnedItem.isPinned, "Newly recorded item should start unpinned")
        clipboard.renameEntry(unpinnedItem, title: "Quick Note")
        expect(clipboard.entries.first?.text == "unpinned-note" && clipboard.entries.first?.isPinned == true, "Renaming an unpinned item should pin it at slot 0 (got \(clipboard.entries.map(\.text)))")
        let denseAfterRename = clipboard.entries.filter(\.isPinned).map(\.sortIndex)
        expect(denseAfterRename == [0, 1, 2, 3, 4], "Auto-pinning via rename should produce dense sortIndex values (got \(denseAfterRename))")

        // Reset back to [beta, alpha, gamma] before persistence check.
        clipboard.clearHistory(keepPinned: false)
        clipboard.recordText("alpha")
        clipboard.recordText("beta")
        clipboard.recordText("gamma")
        clipboard.togglePin(clipboard.entries[2]) // alpha
        clipboard.togglePin(clipboard.entries[2]) // beta -> [beta, alpha, gamma]

        // Persistence: a fresh module instance restores the user's pinned order.
        let restored = ClipboardModule()
        restored.reload(with: cfg)
        expect(restored.entries.map(\.text) == ["beta", "alpha", "gamma"], "Pinned order should persist across restarts (got \(restored.entries.map(\.text).joined(separator: ",")))")

        // Legacy pinned files (no sortIndex key) still decode, fall back to
        // most-recently-copied ordering, and immediately renumber in memory.
        let legacyJSON = """
        [
          {"id": "11111111-1111-1111-1111-111111111111", "text": "legacy-a", "copiedAt": 1000, "isPinned": true, "customTitle": "A"},
          {"id": "22222222-2222-2222-2222-222222222222", "text": "legacy-b", "copiedAt": 2000, "isPinned": true, "customTitle": null}
        ]
        """
        guard let legacyData = legacyJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: legacyData) else {
            failures.append("Legacy pinned_clipboard.json without sortIndex should still decode")
            return
        }
        expect(decoded.map(\.text) == ["legacy-a", "legacy-b"], "Legacy pinned entries should decode in file order")
        expect(decoded.allSatisfy { $0.sortIndex == 0 }, "Legacy pinned entries should default sortIndex to 0")

        // End-to-end legacy restore: write the file and construct a fresh module.
        let configDir = ConfigManager.shared.configURL.deletingLastPathComponent()
        let pinnedURL = configDir.appendingPathComponent("pinned_clipboard.json")
        do {
            try legacyData.write(to: pinnedURL, options: .atomic)
        } catch {
            failures.append("Failed to write legacy pinned_clipboard.json: \(error)")
            return
        }
        try? FileManager.default.removeItem(at: configDir.appendingPathComponent("clipboard_history.json"))
        let legacy = ClipboardModule()
        legacy.reload(with: cfg)
        expect(legacy.entries.map(\.text) == ["legacy-b", "legacy-a"], "Legacy pinned file without sortIndex should restore in most-recently-copied order (got \(legacy.entries.map(\.text).joined(separator: ",")))")
        expect(legacy.entries.filter(\.isPinned).map(\.sortIndex) == [0, 1], "Legacy pinned entries should be renumbered densely on load (got \(legacy.entries.filter(\.isPinned).map(\.sortIndex)))")
        legacy.recordText("legacy-a")
        expect(legacy.entries.map(\.text) == ["legacy-b", "legacy-a"], "Re-copying a legacy pinned item must keep its restored slot instead of jumping to top")

        // Drag layout geometry math with variable row heights.
        let p0 = UUID()
        let p1 = UUID()
        let p2 = UUID()
        expect(
            ClipboardPinnedDragLayout(pinnedIDs: [p0], heights: [p0: 50], draggedID: p0) == nil,
            "ClipboardPinnedDragLayout should return nil for a single pinned item"
        )
        let heights: [UUID: CGFloat] = [p0: 80, p1: 40, p2: 40]
        guard let dragTop = ClipboardPinnedDragLayout(pinnedIDs: [p0, p1, p2], heights: heights, draggedID: p0) else {
            failures.append("ClipboardPinnedDragLayout should initialize for 3 pinned items")
            return
        }
        expect(dragTop.slotTop(for: 0) == 8, "slotTop(0) should be topInset 8")
        expect(dragTop.slotTop(for: 1) == 53, "slotTop(1) with 40pt neighbor should be 53 (got \(dragTop.slotTop(for: 1)))")
        expect(dragTop.slotTop(for: 2) == 98, "slotTop(2) with two 40pt neighbors should be 98 (got \(dragTop.slotTop(for: 2)))")
        expect(dragTop.targetIndex(for: -200) == 0, "Dragging far above top should clamp targetIndex to 0")
        expect(dragTop.targetIndex(for: 300) == 2, "Dragging far below bottom should clamp targetIndex to 2")
        expect(dragTop.targetIndex(for: 45) == 1, "Dragging to slot 1 center should target index 1 (got \(dragTop.targetIndex(for: 45)))")
        expect(dragTop.clampedOffset(for: -200, overshoot: 10) == -10, "clampedOffset above top should honor overshoot")
        expect(dragTop.clampedOffset(for: 300, overshoot: 10) == 100, "clampedOffset below bottom should honor overshoot (got \(dragTop.clampedOffset(for: 300, overshoot: 10)))")
        expect(dragTop.restingShift(forRowAt: 0, targetIndex: 2) == 0, "Dragged row should have 0 restingShift")
        expect(dragTop.restingShift(forRowAt: 1, targetIndex: 2) == -85, "Row 1 shifting past 80pt card should shift -85 (got \(dragTop.restingShift(forRowAt: 1, targetIndex: 2)))")
        expect(dragTop.restingShift(forRowAt: 2, targetIndex: 2) == -85, "Row 2 shifting past 80pt card should shift -85 (got \(dragTop.restingShift(forRowAt: 2, targetIndex: 2)))")
        expect(dragTop.moveInstruction(for: 0) == nil, "moveInstruction at sourceIndex should be nil")
        expect(dragTop.moveInstruction(for: 2)?.targetID == p2 && dragTop.moveInstruction(for: 2)?.insertAfter == true, "Moving index 0 -> 2 should insert after p2")
        expect(dragTop.residualSettleOffset(releaseOffsetY: 30, committedTargetIndex: 1) == -15, "Residual offset from +30 to slot 1 (top 53) should be -15")

        guard let dragBottom = ClipboardPinnedDragLayout(pinnedIDs: [p0, p1, p2], heights: heights, draggedID: p2) else {
            failures.append("ClipboardPinnedDragLayout should initialize for bottom item")
            return
        }
        expect(dragBottom.targetIndex(for: -130) == 0, "Dragging bottom item over tall top row should target index 0")
        expect(dragBottom.restingShift(forRowAt: 0, targetIndex: 0) == 45, "Tall row shifting down past 40pt card should shift +45")
        expect(dragBottom.restingShift(forRowAt: 1, targetIndex: 0) == 45, "Middle row shifting down past 40pt card should shift +45")
        expect(dragBottom.moveInstruction(for: 0)?.targetID == p0 && dragBottom.moveInstruction(for: 0)?.insertAfter == false, "Moving index 2 -> 0 should insert before p0")

        // ClipboardPopoverUIState drag lifecycle (commit, cancel, reset).
        let uiState = ClipboardPopoverUIState()
        uiState.rowHeights = heights
        var externalCancelCount = 0
        var movedArgs: (UUID, UUID, Bool)?
        expect(
            uiState.beginDrag(entryID: p0, pinnedIDs: [p0, p1, p2], onExternalCancel: { externalCancelCount += 1 }),
            "beginDrag should succeed with multiple pinned items"
        )
        expect(uiState.isDragging && uiState.draggedEntryID == p0, "UI state should track active dragged entry")
        uiState.updateDrag(rawDeltaY: 90)
        expect(uiState.dragTargetIndex == 2, "updateDrag(+90) should select target slot 2 (got \(String(describing: uiState.dragTargetIndex)))")
        uiState.finishDrag { d, t, after in movedArgs = (d, t, after) }
        expect(!uiState.isDragging, "finishDrag should clear active drag")
        expect(movedArgs?.0 == p0 && movedArgs?.1 == p2 && movedArgs?.2 == true, "finishDrag should emit expected move instruction")
        expect(uiState.selectedEntryID == p0, "finishDrag should select moved item")

        expect(
            uiState.beginDrag(entryID: p2, pinnedIDs: [p0, p1, p2], onExternalCancel: { externalCancelCount += 1 }),
            "Second beginDrag should succeed"
        )
        uiState.updateDrag(rawDeltaY: -130)
        movedArgs = nil
        uiState.cancelActiveDrag()
        expect(!uiState.isDragging && externalCancelCount == 1 && movedArgs == nil, "cancelActiveDrag should invoke cancel hook without reordering")

        expect(uiState.beginDrag(entryID: p1, pinnedIDs: [p0, p1, p2]), "Third beginDrag should succeed")
        uiState.resetForOpen(entries: [])
        expect(!uiState.isDragging && uiState.settlingEntryID == nil, "resetForOpen should clear all drag and settle state")

        // Clean up shared state files for subsequent suites.
        legacy.clearHistory(keepPinned: false)
        restored.stop()
        clipboard.stop()
    }

    private static func testHotKeyManagerRegistrationAndUnregistration() {
        let manager = HotKeyManager.shared
        let shortcut = ShortcutSpec(key: "j", modifiers: [.command, .option, .shift])
        let registered = manager.register(name: "selftest.hotkey", shortcut: shortcut) {}
        expect(registered, "HotKeyManager failed to register test shortcut")
        expect(manager.isRegistered(name: "selftest.hotkey"), "HotKeyManager should report registered")
        expect(manager.registrationErrors["selftest.hotkey"] == nil, "Unexpected registration error")

        manager.unregister(name: "selftest.hotkey")
        expect(!manager.isRegistered(name: "selftest.hotkey"), "HotKeyManager should unregister cleanly")

        let emptyRegistered = manager.register(name: "selftest.empty", shortcut: .none) {}
        expect(emptyRegistered && !manager.isRegistered(name: "selftest.empty"), "Registering .none should cleanly leave hotkey unregistered")
        expect(manager.registrationErrors["selftest.empty"] == nil, "Registering .none should not produce an error")

        let suspendOk = manager.register(name: "selftest.suspend", shortcut: shortcut) {}
        expect(suspendOk, "HotKeyManager failed to register suspend test shortcut")
        manager.setSuspendedForRecording(true)
        expect(manager.isSuspendedForRecording, "HotKeyManager should report suspended for recording")
        expect(manager.isRegistered(name: "selftest.suspend"), "Suspended registration should remain tracked by name")
        manager.setSuspendedForRecording(false)
        expect(!manager.isSuspendedForRecording, "HotKeyManager should resume after recording")
        expect(manager.isRegistered(name: "selftest.suspend"), "Resumed registration should remain active")
        manager.unregister(name: "selftest.suspend")

        var cfg = ToolboxConfig()
        cfg.clipboard.enabled = true
        cfg.keepAwake.enabled = true
        cfg.keepAwake.shortcut = cfg.clipboard.shortcut
        let conflict = manager.inAppConflictDescription(
            for: cfg.keepAwake.shortcut,
            excludingSourceID: "keep_awake",
            in: cfg
        )
        expect(conflict != nil, "inAppConflictDescription should detect KeepAwake vs Clipboard collision")

        manager.clearConflictingShortcuts(
            matching: cfg.keepAwake.shortcut,
            excludingSourceID: "keep_awake",
            in: &cfg
        )
        expect(cfg.clipboard.shortcut.isEmpty, "clearConflictingShortcuts should unbind colliding Clipboard shortcut")
        expect(!cfg.keepAwake.shortcut.isEmpty, "clearConflictingShortcuts must preserve excluded KeepAwake shortcut")
        expect(
            manager.inAppConflictDescription(for: cfg.keepAwake.shortcut, excludingSourceID: "keep_awake", in: cfg) == nil,
            "Conflict should be cleared after clearConflictingShortcuts"
        )

        let scrollShortcut = ShortcutSpec(key: "s", modifiers: [.command, .option])
        cfg.scrollDirection.shortcut = scrollShortcut
        cfg.dockMinimize.shortcut = scrollShortcut
        expect(
            manager.inAppConflictDescription(for: scrollShortcut, excludingSourceID: "scroll_direction", in: cfg) != nil,
            "inAppConflictDescription should detect ScrollDirection vs DockMinimize collision"
        )
        manager.clearConflictingShortcuts(matching: scrollShortcut, excludingSourceID: "scroll_direction", in: &cfg)
        expect(cfg.dockMinimize.shortcut.isEmpty, "clearConflictingShortcuts should clear colliding DockMinimize shortcut")
    }

    private static func testCustomCommandsShellExecution() {
        let res = CustomCommandsModule.executeShellSync("echo toolbox_ok")
        expect(res.exitCode == 0, "Shell command exitCode should be 0")
        expect(res.output == "toolbox_ok", "Shell command output mismatch: \(res.output)")
    }

    private static func testModuleRegistryAndSettingsViews() {
        let registry = ModuleRegistry.shared
        let ids = registry.modules.map(\.id)
        expect(Set(ids).count == ids.count, "ModuleRegistry IDs must be unique")
        expect(ids.count >= 4, "Expected at least 4 built-in modules")
        for module in registry.modules {
            expect(!module.name.isEmpty, "Module \(module.id) name must not be empty")
            expect(NSImage(systemSymbolName: module.symbolName, accessibilityDescription: nil) != nil,
                   "Module \(module.id) symbol \(module.symbolName) must exist on macOS")
            _ = module.makeSettingsView()
        }
        let uiSymbols = [
            "eye.slash.fill", "square.2.layers.3d.bottom.filled", "rectangle.compress.vertical",
            "rectangle.stack.badge.minus", "rectangle.badge.minus", "cursorarrow.click", "cursorarrow.click.2",
            "arrow.up.right.square", "bolt.fill", "gauge.medium", "leaf.fill",
            "slider.horizontal.3", "rectangle", "rectangle.expand.vertical", "aspectratio",
            "hand.raised.circle.fill", "bolt.slash.circle.fill", "bolt.shield.fill",
            "cursorarrow.motionlines", "battery.100.bolt", "timer", "key.fill", "checkmark.shield.fill",
            "escape", "power", "hand.draw", "mic.fill", "chevron.down", "chevron.up",
            "doc.on.doc", "arrow.uturn.backward", "arrow.clockwise", "text.alignleft",
            "text.viewfinder", "qrcode", "hands.clap.fill", "sparkles",
            "terminal", "app.badge", "globe", "doc.on.clipboard", "computermouse",
            "rectangle.and.hand.point.up.left", "macwindow.on.rectangle", "macwindow",
            "list.bullet.indent", "curlybraces", "gearshape.fill",
            "folder.badge.gearshape", "scissors", "lock.shield", "waveform.path.ecg",
            "checkmark.shield", "nosign"
        ]
        for sym in uiSymbols {
            expect(NSImage(systemSymbolName: sym, accessibilityDescription: nil) != nil,
                   "UI symbol \(sym) must exist on macOS")
        }
    }

    private static func testKeepAwakeLifecycle() {
        let keepAwake = KeepAwakeModule()
        keepAwake.activate(minutes: 15)
        expect(keepAwake.isAwakeActive, "KeepAwake should become active")
        expect(keepAwake.expiresAt != nil, "KeepAwake with 15m should set expiresAt")
        keepAwake.deactivate()
        expect(!keepAwake.isAwakeActive, "KeepAwake should deactivate cleanly")
    }

    private static func testMasterTogglePauseResumeAndInstantPopover() {
        var cfg = ToolboxConfig()
        expect(cfg.general.appEnabled, "GeneralConfig.appEnabled should default to true")

        let registry = ModuleRegistry.shared
        cfg.keepAwake.enabled = true
        cfg.general.appEnabled = true
        registry.reloadAll(with: cfg)
        expect(registry.clipboard.isRunning == cfg.clipboard.enabled, "Registry reloadAll active state mismatch")

        cfg.general.appEnabled = false
        registry.reloadAll(with: cfg)
        for module in registry.modules {
            expect(!module.isRunning, "Module \(module.id) must stop when general.appEnabled is false")
            if module.isEnabled(in: cfg) {
                expect(module.statusText(in: cfg, accessibilityGranted: true) == "Paused", "Enabled module \(module.id) statusText should be Paused when appEnabled is false")
            }
        }
        expect(cfg.keepAwake.enabled, "Per-module enabled state must stay preserved while paused")

        let menuBar = MenuBarController()
        menuBar.setVisible(true, isActive: true)
        expect(menuBar.attachedMenuForTesting == nil, "NSStatusItem must not attach NSMenu so macOS 26 does not auto-cancel tracking while inactive")
        expect(menuBar.statusButtonForTesting?.action != nil, "NSStatusItem button must handle clicks to toggle popover")
        expect(menuBar.pointerCursorViewCountForTesting >= 10, "Menu bar interactive controls must attach PointerCursorNSView overlays (found \(menuBar.pointerCursorViewCountForTesting))")
        menuBar.showPopoverForTesting()
        expect(menuBar.isPopoverVisibleForTesting, "showPopoverForTesting must display the status bar popover")
        expect(menuBar.popoverPanelForTesting?.styleMask.contains(.nonactivatingPanel) == true, "Status bar popover panel must use .nonactivatingPanel")
        expect(menuBar.visualEffectMaterialForTesting == .windowBackground, "Status bar popover must use high-legibility .windowBackground material instead of thin .popover glass")
        expect(menuBar.popoverPanelForTesting?.hidesOnDeactivate == false, "Status bar popover panel must stay open when Toolbox is inactive")
        expect(menuBar.popoverPanelForTesting?.canBecomeKey == false, "Status bar popover panel must refuse key status so it never activates Toolbox or raises a background Dashboard")
        expect(menuBar.popoverPanelForTesting?.canBecomeMain == false, "Status bar popover panel must never become main window")
        expect(menuBar.popoverPanelForTesting?.becomesKeyOnlyIfNeeded == true, "Status bar popover panel must set becomesKeyOnlyIfNeeded = true")
        expect(menuBar.popoverPanelForTesting?.isKeyWindow == false, "Showing the status bar popover must not make it key window")
        expect(!NSApp.isActive, "Showing the status bar popover must not activate Toolbox")
        expect(menuBar.popoverPanelForTesting?.contentView?.acceptsFirstMouse(for: nil) == true, "Status bar popover chrome view must accept first mouse while non-key")
        expect(
            menuBar.popoverPanelForTesting?.contentView?.subviews.first?.acceptsFirstMouse(for: nil) == true,
            "Status bar popover PointerCursorHostingView must accept first mouse so buttons work on first click while non-key"
        )

        let savedMenuBarConfig = ConfigManager.shared.config
        ConfigManager.shared.config.callControls.enabled = true
        ConfigManager.shared.config.general.showQuickActionsInMenuBar = true
        ConfigManager.shared.config.general.appEnabled = true
        registry.reloadAll(with: ConfigManager.shared.config)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        menuBar.refreshHostedViewSizeForTesting()
        let activeHeight = menuBar.popoverPanelForTesting?.frame.height ?? 0
        let activePointerCount = menuBar.pointerCursorViewCountForTesting

        ConfigManager.shared.config.general.appEnabled = false
        registry.reloadAll(with: ConfigManager.shared.config)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        menuBar.refreshHostedViewSizeForTesting()
        let pausedHeight = menuBar.popoverPanelForTesting?.frame.height ?? 0
        let pausedPointerCount = menuBar.pointerCursorViewCountForTesting

        expect(
            abs(activeHeight - pausedHeight) <= 1,
            "Status bar popover height must not jump when toggling Toolbox on/off (active=\(activeHeight), paused=\(pausedHeight))"
        )
        expect(
            pausedPointerCount < activePointerCount,
            "Paused module rows and quick actions must drop PointerCursorNSView overlays (active=\(activePointerCount), paused=\(pausedPointerCount))"
        )
        expect(
            pausedPointerCount >= 4,
            "Header, master toggle, and footer controls must retain pointer cursor overlays while paused (found \(pausedPointerCount))"
        )

        ConfigManager.shared.config = savedMenuBarConfig
        registry.reloadAll(with: savedMenuBarConfig)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        menuBar.refreshHostedViewSizeForTesting()

        // Section visibility predicate matrix tests
        var visConfig = ToolboxConfig()
        visConfig.general.showQuickActionsInMenuBar = false
        visConfig.general.showQuickCommandsInMenuBar = true
        visConfig.callControls.enabled = false
        visConfig.customCommands.enabled = false
        visConfig.customCommands.commands = [
            CustomCommand(
                id: "cmd-test",
                name: "Test Command",
                enabled: true,
                shortcut: .none,
                kind: .shell,
                payload: "echo hi"
            )
        ]
        visConfig.windowSnapper.enabled = false
        visConfig.windowSnapper.profiles = [
            WorkspaceProfile(id: "prof-test", name: "Ultra Wide Coding & Documentation Workspace")
        ]
        let visAllOff = MenuBarPopoverSectionVisibility.evaluate(for: visConfig)
        expect(!visAllOff.hasAnyActions && !visAllOff.showGapAfterQuickActions && !visAllOff.showGapAfterQuickCommands, "All sections disabled must report no visible actions or gaps")

        visConfig.general.showQuickActionsInMenuBar = true
        visConfig.callControls.enabled = true
        let visQuickAndCall = MenuBarPopoverSectionVisibility.evaluate(for: visConfig)
        expect(visQuickAndCall.showQuickActions && visQuickAndCall.showCallControlsActions && visQuickAndCall.showCallControlsPill, "Enabled Quick Actions + Call Controls must expose row and pill")
        expect(visQuickAndCall.hasAnyActions && !visQuickAndCall.showGapAfterQuickActions && !visQuickAndCall.showGapAfterQuickCommands, "Quick Actions alone must not insert trailing section gaps")

        visConfig.general.showQuickActionsInMenuBar = false
        let visQuickHiddenWithCallOn = MenuBarPopoverSectionVisibility.evaluate(for: visConfig)
        expect(!visQuickHiddenWithCallOn.showQuickActions && !visQuickHiddenWithCallOn.showCallControlsActions && visQuickHiddenWithCallOn.showCallControlsPill, "Call Controls quick actions must stay hidden when Quick Actions bar is off while keeping row pill")

        visConfig.general.showQuickActionsInMenuBar = true
        visConfig.customCommands.enabled = true
        visConfig.windowSnapper.enabled = true
        let visAllOn = MenuBarPopoverSectionVisibility.evaluate(for: visConfig)
        expect(visAllOn.showQuickCommands && visAllOn.showWindowProfiles && visAllOn.showGapAfterQuickActions && visAllOn.showGapAfterQuickCommands, "Quick Actions + Quick Commands + Window Profiles must enable both inter-section gaps")

        visConfig.customCommands.commands[0].enabled = false
        let visInactiveCmd = MenuBarPopoverSectionVisibility.evaluate(for: visConfig)
        expect(!visInactiveCmd.showQuickCommands && visInactiveCmd.showGapAfterQuickActions && !visInactiveCmd.showGapAfterQuickCommands, "Disabled/empty custom commands must hide Quick Commands and keep Quick Actions -> Profiles gap")

        visConfig.customCommands.commands[0].enabled = true
        visConfig.general.showQuickActionsInMenuBar = false
        let visCmdAndProfiles = MenuBarPopoverSectionVisibility.evaluate(for: visConfig)
        expect(!visCmdAndProfiles.showGapAfterQuickActions && visCmdAndProfiles.showGapAfterQuickCommands, "Quick Commands + Window Profiles without Quick Actions must only enable second gap")

        // EaseInOut curve boundaries & monotonicity
        expect(abs(MenuBarPopoverLayoutAnimator.easeInOut(0) - 0) < 0.0001, "easeInOut(0) must be 0")
        expect(abs(MenuBarPopoverLayoutAnimator.easeInOut(0.5) - 0.5) < 0.0001, "easeInOut(0.5) must be 0.5")
        expect(abs(MenuBarPopoverLayoutAnimator.easeInOut(1) - 1) < 0.0001, "easeInOut(1) must be 1")
        let e25 = MenuBarPopoverLayoutAnimator.easeInOut(0.25)
        let e75 = MenuBarPopoverLayoutAnimator.easeInOut(0.75)
        expect(e25 > 0 && e25 < 0.5 && 0.5 < e75 && e75 < 1.0, "easeInOut must be strictly monotonic on [0, 1]")

        // Live MenuBarController synchronized collapse/expand & top-edge anchoring tests
        menuBar.hidePopoverForTesting()
        var animTestConfig = savedMenuBarConfig
        animTestConfig.general.appEnabled = true
        animTestConfig.general.showQuickActionsInMenuBar = true
        animTestConfig.general.showQuickCommandsInMenuBar = true
        animTestConfig.general.menuBarHiddenModules = ["dock_minimize", "clipboard", "port_killer", "screen_ocr"]
        animTestConfig.callControls.enabled = true
        animTestConfig.customCommands.enabled = true
        animTestConfig.customCommands.commands = [
            CustomCommand(
                id: "anim-cmd-1",
                name: "Run Smoke Test With Very Long Name That Must Truncate Cleanly",
                enabled: true,
                shortcut: ShortcutSpec(key: "r", modifiers: [.command, .option]),
                kind: .shell,
                payload: "echo ok"
            )
        ]
        animTestConfig.windowSnapper.enabled = true
        animTestConfig.windowSnapper.profiles = [
            WorkspaceProfile(
                id: "anim-prof-1",
                name: "Ultra Wide Coding & Documentation Workspace",
                shortcut: ShortcutSpec(key: "1", modifiers: [.command, .option])
            )
        ]
        animTestConfig.windowSnapper.activeProfileID = "anim-prof-1"
        ConfigManager.shared.config = animTestConfig
        menuBar.layoutAnimatorForTesting.reduceMotionOverrideForTesting = false
        menuBar.showPopoverForTesting()

        let initialTopY = menuBar.popoverPanelForTesting?.frame.maxY ?? 0
        let expandedHeight = menuBar.popoverPanelForTesting?.frame.height ?? 0
        expect(expandedHeight > 300, "Expanded menu bar popover must have non-trivial height (got \(expandedHeight))")

        // Toggle Window Snapper OFF while popover is open
        ConfigManager.shared.config.windowSnapper.enabled = false
        expect(menuBar.layoutAnimatorForTesting.isAnimating, "Toggling Window Snapper off while open must start layout animation")
        let frame0TopY = menuBar.popoverPanelForTesting?.frame.maxY ?? 0
        let frame0Height = menuBar.popoverPanelForTesting?.frame.height ?? 0
        expect(abs(frame0TopY - initialTopY) <= 0.5, "Frame 0 topY must stay anchored on toggle (expected \(initialTopY), got \(frame0TopY))")
        expect(abs(frame0Height - expandedHeight) <= 1.0, "Frame 0 height must stay at expanded height before stepping (expected \(expandedHeight), got \(frame0Height))")

        menuBar.stepLayoutAnimationForTesting(fraction: 0.25)
        let top25 = menuBar.popoverPanelForTesting?.frame.maxY ?? 0
        let h25 = menuBar.popoverPanelForTesting?.frame.height ?? 0
        menuBar.stepLayoutAnimationForTesting(fraction: 0.50)
        let top50 = menuBar.popoverPanelForTesting?.frame.maxY ?? 0
        let h50 = menuBar.popoverPanelForTesting?.frame.height ?? 0
        menuBar.stepLayoutAnimationForTesting(fraction: 0.75)
        let top75 = menuBar.popoverPanelForTesting?.frame.maxY ?? 0
        let h75 = menuBar.popoverPanelForTesting?.frame.height ?? 0
        menuBar.stepLayoutAnimationForTesting(fraction: 1.0)
        let top100 = menuBar.popoverPanelForTesting?.frame.maxY ?? 0
        let h100 = menuBar.popoverPanelForTesting?.frame.height ?? 0

        expect(
            abs(top25 - initialTopY) <= 0.5 && abs(top50 - initialTopY) <= 0.5 && abs(top75 - initialTopY) <= 0.5 && abs(top100 - initialTopY) <= 0.5,
            "Popover top edge must remain locked within 0.5pt across collapse steps (initial=\(initialTopY), steps=\([top25, top50, top75, top100]))"
        )
        expect(
            expandedHeight > h25 && h25 > h50 && h50 > h75 && h75 > h100,
            "Popover height must shrink strictly monotonically during collapse without RunLoop delay (heights=\([expandedHeight, h25, h50, h75, h100]))"
        )

        // Mid-flight reversal test: toggle ON -> step 0.5 -> toggle OFF immediately -> step 1.0
        ConfigManager.shared.config.windowSnapper.enabled = true
        menuBar.stepLayoutAnimationForTesting(fraction: 0.50)
        let midReversalProgress = menuBar.layoutAnimatorForTesting.progress.windowProfiles
        expect(abs(midReversalProgress - 0.5) < 0.05, "Midpoint progress must be near 0.5 (got \(midReversalProgress))")
        ConfigManager.shared.config.windowSnapper.enabled = false
        let afterFlipProgress = menuBar.layoutAnimatorForTesting.progress.windowProfiles
        expect(abs(afterFlipProgress - midReversalProgress) < 0.01, "Reversing mid-flight must not jump progress (before=\(midReversalProgress), after=\(afterFlipProgress))")
        menuBar.stepLayoutAnimationForTesting(fraction: 1.0)
        let revFinalTopY = menuBar.popoverPanelForTesting?.frame.maxY ?? 0
        let revFinalHeight = menuBar.popoverPanelForTesting?.frame.height ?? 0
        expect(abs(revFinalTopY - initialTopY) <= 0.5, "Top edge must stay anchored after mid-flight reversal")
        expect(abs(revFinalHeight - h100) <= 0.5, "Mid-flight reversal back to OFF must settle at collapsed height \(h100) (got \(revFinalHeight))")

        // Toggle Call Controls OFF -> ON while open
        let baselineCollapsedPointers = menuBar.pointerCursorViewCountForTesting
        ConfigManager.shared.config.callControls.enabled = false
        menuBar.stepLayoutAnimationForTesting(fraction: 0.50)
        let callOffTop50 = menuBar.popoverPanelForTesting?.frame.maxY ?? 0
        let callOffH50 = menuBar.popoverPanelForTesting?.frame.height ?? 0
        menuBar.stepLayoutAnimationForTesting(fraction: 1.0)
        let callOffTop100 = menuBar.popoverPanelForTesting?.frame.maxY ?? 0
        let callOffH100 = menuBar.popoverPanelForTesting?.frame.height ?? 0
        let callOffPointers = menuBar.pointerCursorViewCountForTesting
        expect(abs(callOffTop50 - initialTopY) <= 0.5 && abs(callOffTop100 - initialTopY) <= 0.5, "Top edge must stay locked when Call Controls toggles OFF")
        expect(h100 > callOffH50 && callOffH50 > callOffH100, "Call Controls OFF must smoothly shrink height (h100=\(h100), h50=\(callOffH50), end=\(callOffH100))")
        expect(callOffPointers < baselineCollapsedPointers, "Collapsing Call Controls must drop its quick action & pill pointer overlays")

        ConfigManager.shared.config.callControls.enabled = true
        menuBar.stepLayoutAnimationForTesting(fraction: 0.50)
        let callOnTop50 = menuBar.popoverPanelForTesting?.frame.maxY ?? 0
        let callOnH50 = menuBar.popoverPanelForTesting?.frame.height ?? 0
        menuBar.stepLayoutAnimationForTesting(fraction: 1.0)
        let callOnTop100 = menuBar.popoverPanelForTesting?.frame.maxY ?? 0
        let callOnH100 = menuBar.popoverPanelForTesting?.frame.height ?? 0
        let callOnPointers = menuBar.pointerCursorViewCountForTesting
        expect(abs(callOnTop50 - initialTopY) <= 0.5 && abs(callOnTop100 - initialTopY) <= 0.5, "Top edge must stay locked when Call Controls toggles ON")
        expect(callOffH100 < callOnH50 && callOnH50 < callOnH100 && abs(callOnH100 - h100) <= 0.5, "Call Controls ON must smoothly restore height")
        expect(callOnPointers == baselineCollapsedPointers, "Restoring Call Controls must restore exact pointer cursor overlay count")

        // Toggle Custom Commands OFF -> ON while open
        ConfigManager.shared.config.customCommands.enabled = false
        menuBar.stepLayoutAnimationForTesting(fraction: 0.50)
        let cmdOffTop50 = menuBar.popoverPanelForTesting?.frame.maxY ?? 0
        let cmdOffH50 = menuBar.popoverPanelForTesting?.frame.height ?? 0
        menuBar.stepLayoutAnimationForTesting(fraction: 1.0)
        let cmdOffTop100 = menuBar.popoverPanelForTesting?.frame.maxY ?? 0
        let cmdOffH100 = menuBar.popoverPanelForTesting?.frame.height ?? 0
        let cmdOffPointers = menuBar.pointerCursorViewCountForTesting
        expect(abs(cmdOffTop50 - initialTopY) <= 0.5 && abs(cmdOffTop100 - initialTopY) <= 0.5, "Top edge must stay locked when Custom Commands toggles OFF")
        expect(h100 > cmdOffH50 && cmdOffH50 > cmdOffH100, "Custom Commands OFF must smoothly shrink height")
        expect(cmdOffPointers < baselineCollapsedPointers, "Collapsing Quick Commands must drop its pointer cursor overlays")

        ConfigManager.shared.config.customCommands.enabled = true
        menuBar.stepLayoutAnimationForTesting(fraction: 0.50)
        let cmdOnTop50 = menuBar.popoverPanelForTesting?.frame.maxY ?? 0
        let cmdOnH50 = menuBar.popoverPanelForTesting?.frame.height ?? 0
        menuBar.stepLayoutAnimationForTesting(fraction: 1.0)
        let cmdOnTop100 = menuBar.popoverPanelForTesting?.frame.maxY ?? 0
        let cmdOnH100 = menuBar.popoverPanelForTesting?.frame.height ?? 0
        let cmdOnPointers = menuBar.pointerCursorViewCountForTesting
        expect(abs(cmdOnTop50 - initialTopY) <= 0.5 && abs(cmdOnTop100 - initialTopY) <= 0.5, "Top edge must stay locked when Custom Commands toggles ON")
        expect(cmdOffH100 < cmdOnH50 && cmdOnH50 < cmdOnH100 && abs(cmdOnH100 - h100) <= 0.5, "Custom Commands ON must smoothly restore height")
        expect(cmdOnPointers == baselineCollapsedPointers, "Restoring Quick Commands must restore exact pointer cursor overlay count")

        menuBar.layoutAnimatorForTesting.reduceMotionOverrideForTesting = nil
        ConfigManager.shared.config = savedMenuBarConfig
        registry.reloadAll(with: savedMenuBarConfig)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        menuBar.refreshHostedViewSizeForTesting()

        final class PopoverCloseObserverState: @unchecked Sendable {
            var didPost = false
        }
        let closeState = PopoverCloseObserverState()
        let closeObserver = NotificationCenter.default.addObserver(
            forName: .toolboxMenuBarPopoverDidClose,
            object: nil,
            queue: nil
        ) { _ in
            closeState.didPost = true
        }
        menuBar.hidePopoverForTesting()
        NotificationCenter.default.removeObserver(closeObserver)
        expect(closeState.didPost, "Dismissing the status bar popover must post toolboxMenuBarPopoverDidClose so hover highlights reset")
        expect(!menuBar.isPopoverVisibleForTesting, "hidePopoverForTesting must dismiss the status bar popover")
        menuBar.setVisible(false)
        expect(menuBar.statusButtonForTesting == nil, "Hiding status item must remove status bar button")

        let primaryScreen = (frame: NSRect(x: 0, y: 0, width: 1728, height: 1117), visibleFrame: NSRect(x: 0, y: 78, width: 1728, height: 1007))
        let secondaryScreen = (frame: NSRect(x: -132, y: 1117, width: 2560, height: 1440), visibleFrame: NSRect(x: -132, y: 1117, width: 2560, height: 1415))
        let originOnSecondDisplay = MenuBarController.popoverOrigin(
            size: NSSize(width: 340, height: 470),
            cursorPoint: NSPoint(x: 2100, y: 2545),
            buttonScreenRect: NSRect(x: 1320, y: 1088, width: 32, height: 24),
            screenFrames: [primaryScreen, secondaryScreen],
            fallbackVisibleFrame: primaryScreen.visibleFrame
        )
        expect(secondaryScreen.frame.contains(originOnSecondDisplay), "Menu bar click on secondary display must open popover on secondary display even if button.window frame is still on primary display (got \(originOnSecondDisplay))")

        let originWithUnpositionedButton = MenuBarController.popoverOrigin(
            size: NSSize(width: 340, height: 470),
            cursorPoint: NSPoint(x: 900, y: 1100),
            buttonScreenRect: NSRect(x: 0, y: 0, width: 24, height: 22),
            screenFrames: [primaryScreen],
            fallbackVisibleFrame: primaryScreen.visibleFrame
        )
        expect(
            originWithUnpositionedButton.y > primaryScreen.visibleFrame.minY + 100,
            "Unpositioned status button rect at (0, 0) must not pin popover to bottom of screen (got \(originWithUnpositionedButton))"
        )

        let win = MainWindowController.shared.ensureWindow()
        win.layoutIfNeeded()
        expect(win.acceptsMouseMovedEvents, "Dashboard NSWindow must accept mouse moved events so hover cursors reset outside clickable items")
        expect(
            win.contentView is PointerCursorHostingView<MainSplitView>,
            "Main window must use PointerCursorHostingView so SwiftUI hover and click state updates never revert pointingHand to arrow"
        )
        expect(
            PointerCursorNSView.isManagedCursorWindow(win),
            "Main window must be recognized as a managed cursor window"
        )
        let menuPopoverPanel = MenuBarController()
        _ = menuPopoverPanel.pointerCursorViewCountForTesting
        if let popPanel = menuPopoverPanel.popoverPanelForTesting {
            expect(
                popPanel is PointerCursorNSPanel && PointerCursorNSView.isManagedCursorWindow(popPanel),
                "Menu bar popover panel at .popUpMenu level must use PointerCursorNSPanel and be managed by PointerCursorNSView"
            )
        }
        if let rootView = win.contentView?.superview ?? win.contentView {
            let contentTop = win.contentLayoutRect.maxY
            let windowTop = rootView.bounds.maxY

            // 1. Blank areas on the page (e.g. header banner, bottom margin below grid) must NOT match PointerCursorNSView.
            let emptyBannerPt = NSPoint(x: 500, y: contentTop - 30)
            let emptySideMarginPt = NSPoint(x: 230, y: 300)
            expect(!PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: emptyBannerPt),
                   "Blank header area on Dashboard must not trigger pointingHand cursor")
            expect(!PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: emptySideMarginPt),
                   "Empty margin on Dashboard must not trigger pointingHand cursor")

            // 2. Clickable toolbar sidebar toggle and sidebar Dashboard item must match PointerCursorNSView.
            let toolbarBtnPt = NSPoint(x: 104, y: windowTop - 16)
            let sidebarDashboardPt = NSPoint(x: 80, y: contentTop - 42)
            expect(PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: toolbarBtnPt),
                   "Toolbar sidebar toggle button must match PointerCursorNSView")
            expect(PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: sidebarDashboardPt),
                   "Sidebar Dashboard row must match PointerCursorNSView")

            // 3. Verify all other destinations keep PointerCursorNSView tightly scoped to clickable controls (not empty areas).
            let detailEmptyY = contentTop - 80
            let destinations: [(String, SidebarDestination, NSPoint)] = [
                ("settings", .settings, NSPoint(x: 350, y: detailEmptyY)),
                ("support", .support, NSPoint(x: 500, y: detailEmptyY)),
                ("jsonConfig", .jsonConfig, NSPoint(x: 500, y: 350)),
                ("dock_minimize", .module("dock_minimize"), NSPoint(x: 500, y: detailEmptyY)),
                ("clipboard", .module("clipboard"), NSPoint(x: 500, y: detailEmptyY)),
                ("keep_awake", .module("keep_awake"), NSPoint(x: 500, y: detailEmptyY)),
                ("custom_commands", .module("custom_commands"), NSPoint(x: 500, y: detailEmptyY)),
                ("scroll_direction", .module("scroll_direction"), NSPoint(x: 500, y: detailEmptyY)),
                ("screen_ocr", .module("screen_ocr"), NSPoint(x: 500, y: detailEmptyY)),
                ("call_controls", .module("call_controls"), NSPoint(x: 500, y: detailEmptyY)),
                ("window_snapper", .module("window_snapper"), NSPoint(x: 500, y: detailEmptyY)),
            ]
            for (label, dest, emptyPt) in destinations {
                MainWindowController.shared.navState.navigate(to: dest)
                win.layoutIfNeeded()
                expect(!PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: emptyPt),
                       "Non-clickable area on \(label) page must not trigger pointingHand cursor")
                expect(PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: toolbarBtnPt),
                       "Toolbar sidebar toggle button must stay active on \(label) page")
            }
            MainWindowController.shared.navState.selection = .dashboard
            MainWindowController.shared.navState.navigate(to: .settings)
            MainWindowController.shared.navState.goBack()
            expect(MainWindowController.shared.navState.selection == .dashboard, "NavigationState.goBack() must return to dashboard")
            win.layoutIfNeeded()
        }
        expect(win.contentMinSize.width == 340 && win.contentMinSize.height == 300, "Dashboard NSWindow contentMinSize must shrink to 340x300: \(win.contentMinSize)")
        expect(win.minSize.width == 340 && win.minSize.height >= 328 && win.minSize.height <= 380, "Dashboard NSWindow minSize mismatch: \(win.minSize)")

        for module in registry.modules {
            let texts = [module.name, module.tagline, module.aboutSummary] + module.featureTips
            for t in texts {
                expect(!t.contains("\u{2014}"), "Em dash found in module \(module.id) copy: \(t)")
            }
        }
        for mode in DockActionMode.allCases {
            expect(!mode.explanation.contains("\u{2014}"), "Em dash found in DockActionMode \(mode.rawValue)")
        }

        let activeIcon = MenuBarController.makeStatusBarIcon(isActive: true)
        let pausedIcon = MenuBarController.makeStatusBarIcon(isActive: false)
        expect(activeIcon.isTemplate && pausedIcon.isTemplate, "Status bar icons must be template images")
        expect(activeIcon.tiffRepresentation != pausedIcon.tiffRepresentation, "Active (filled) and paused (outlined) icons must differ")
    }

    private static func testScrollDirectionConfigAndMigration() {
        let cfg = ToolboxConfig()
        expect(!cfg.scrollDirection.enabled, "ScrollDirection should default to disabled (off by default)")
        expect(cfg.scrollDirection.target == .mouse, "ScrollDirection should default to inverting the mouse")

        if let data = try? JSONEncoder().encode(cfg),
           let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(decoded.scrollDirection == cfg.scrollDirection, "ScrollDirectionConfig Codable round-trip mismatch")
            expect(decoded.schemaVersion == 15, "ToolboxConfig schemaVersion should be 15")
        } else {
            failures.append("ToolboxConfig Codable encode/decode failed")
        }

        // A config written by an older build has no scrollDirection key; it must decode
        // with the safe defaults instead of failing.
        let oldJSON = "{\"schemaVersion\": 2, \"general\": {\"appEnabled\": true}}"
        guard let data = oldJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) else {
            failures.append("Failed to decode pre-ScrollDirection config JSON")
            return
        }
        expect(!decoded.scrollDirection.enabled, "Legacy config should migrate ScrollDirection to disabled")
        expect(decoded.scrollDirection.target == .mouse, "Legacy config should migrate ScrollDirection target to mouse")

        let onJSON = "{\"schemaVersion\": 3, \"scrollDirection\": {\"enabled\": true, \"target\": \"trackpad\"}}"
        guard let data = onJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) else {
            failures.append("Failed to decode ScrollDirection config JSON")
            return
        }
        expect(decoded.scrollDirection.enabled, "ScrollDirection enabled should decode")
        expect(decoded.scrollDirection.target == .trackpad, "ScrollDirection target should decode")
    }

    private static func testScrollInversionClassificationAndInversion() {
        // Line based (classic mouse wheel) event: IsContinuous = 0.
        guard let mouseEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 5, wheel2: -3, wheel3: 0) else {
            failures.append("Could not create test scroll event (line)")
            return
        }
        mouseEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        mouseEvent.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 5)
        mouseEvent.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -3)

        // Pixel based (trackpad / high resolution) event: IsContinuous = 1.
        guard let trackpadEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 42, wheel2: -17, wheel3: 0) else {
            failures.append("Could not create test scroll event (pixel)")
            return
        }
        trackpadEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        trackpadEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 42)
        trackpadEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -17)

        // Target = mouse: invert wheel events (line based), leave trackpad events untouched.
        expect(ScrollInversionTap.applyInversion(to: mouseEvent, target: .mouse), "Line based event should be inverted for the mouse target")
        expect(mouseEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -5, "Vertical line delta should be negated")
        expect(mouseEvent.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 3, "Horizontal line delta should be negated")
        // The line fields are the master: negating them re-derives the pixel and fixed
        // point mirrors, so those follow the same sign flip (8 px per line).
        expect(mouseEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -40, "Derived pixel mirror should follow the negated master delta")
        expect(mouseEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 24, "Derived pixel mirror (horizontal) should follow the negated master delta")
        expect(!ScrollInversionTap.applyInversion(to: trackpadEvent, target: .mouse), "Pixel based event must NOT be inverted for the mouse target")
        expect(trackpadEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 42, "Trackpad pixel delta must stay untouched for the mouse target")

        // Target = trackpad: invert pixel based events, leave wheel events untouched.
        guard let mouseEvent2 = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0) else { return }
        mouseEvent2.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        mouseEvent2.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 5)
        expect(!ScrollInversionTap.applyInversion(to: mouseEvent2, target: .trackpad), "Line based event must NOT be inverted for the trackpad target")
        expect(mouseEvent2.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 5, "Mouse line delta must stay untouched for the trackpad target")

        let trackpadDeltaBefore = trackpadEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        expect(ScrollInversionTap.applyInversion(to: trackpadEvent, target: .trackpad), "Pixel based event should be inverted for the trackpad target")
        expect(trackpadEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -42, "Vertical pixel delta should be negated")
        expect(trackpadEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 17, "Horizontal pixel delta should be negated")
        // The coarse line derivative on a pixel based event must not be touched,
        // because writing it would re-derive the pixel mirrors and destroy precision.
        expect(trackpadEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1) == trackpadDeltaBefore, "Coarse line derivative on pixel event must stay untouched")

        // Zero delta events must invert harmlessly (no-op) without crashing.
        guard let idle = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0) else { return }
        idle.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        expect(ScrollInversionTap.applyInversion(to: idle, target: .mouse), "Zero delta event should still match the mouse target")

        // Mismatched events must still update lastObservedClass so smooth-scroll mice are surfaced in Live Status.
        let probeTap = ScrollInversionTap()
        probeTap.setTarget(.mouse)
        guard let mismatched = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0) else { return }
        mismatched.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        expect(!probeTap.processScrollWheelEvent(mismatched), "Continuous event should not be inverted when target is mouse")
        expect(probeTap.eventsInverted == 0, "eventsInverted should remain 0 on non-matching event")
        expect(probeTap.eventsObserved == 1 && probeTap.lastObservedClass == .trackpad, "lastObservedClass must track non-matching trackpad-style events")
    }

    private static func testScrollDirectionModuleLifecycleAndRegistry() {
        let registry = ModuleRegistry.shared
        let module = registry.scrollDirection
        expect(module.requiresAccessibility, "ScrollDirection must require Accessibility (it modifies events)")
        expect(module.category == .system, "ScrollDirection should be in the System category")
        expect(ModuleRegistry.shared.module(withID: "scroll_direction") === module, "Registry should resolve scroll_direction")

        // Status text is deterministic regardless of the live permission state.
        var off = ToolboxConfig()
        expect(module.statusText(in: off, accessibilityGranted: true) == "Disabled", "Disabled status text mismatch: \(module.statusText(in: off, accessibilityGranted: true))")
        off.scrollDirection.enabled = true
        off.general.appEnabled = false
        expect(module.statusText(in: off, accessibilityGranted: true) == "Paused", "Paused status text mismatch")
        off.general.appEnabled = true
        expect(module.statusText(in: off, accessibilityGranted: false) == "Needs Accessibility", "No-permission status text mismatch")

        // Lifecycle: enabled starts the module; the tap is installed only when allowed.
        var cfg = ToolboxConfig()
        cfg.scrollDirection.enabled = true
        module.reload(with: cfg)
        expect(module.isRunning, "Module should start when enabled")
        let granted = AXIsProcessTrusted()
        if granted {
            expect(module.isTapInstalled || module.statusText(in: cfg, accessibilityGranted: true) == "Standby",
                   "With Accessibility the tap should be installed (or report Standby)")
            let bgTap = ScrollInversionTap()
            if bgTap.install() {
                expect(bgTap.runsOnDedicatedBackgroundRunLoopForTesting, "ScrollInversionTap must run on a dedicated non-main background Thread CFRunLoop")
                bgTap.uninstall()
                expect(!bgTap.isInstalled, "ScrollInversionTap uninstall must clear tap")
            }
        } else {
            expect(!module.isTapInstalled, "Without Accessibility the tap must not be installed")
        }

        // Disabled always tears the tap down, in any permission state.
        cfg.scrollDirection.enabled = false
        module.reload(with: cfg)
        expect(!module.isRunning, "Module should stop when disabled")
        expect(!module.isTapInstalled, "Tap must be uninstalled when disabled")

        // Target change is applied to the tap without reinstall churn.
        cfg.scrollDirection.enabled = true
        cfg.scrollDirection.target = .trackpad
        module.reload(with: cfg)
        module.stop()
        expect(!module.isRunning, "stop() should deactivate the module")
    }

    private static func testDockMinimizeWindowsBehaviorAndPreFilter() {
        let cfg = DockMinimizeConfig()
        expect(cfg.actionMode == .hideApp, "Default DockActionMode should be .hideApp (Windows style hide & restore)")
        expect(DockActionMode.allCases.first == .hideApp, "DockActionMode.allCases should put .hideApp first")
        expect(Set(DockActionMode.allCases) == Set([.hideApp, .sendToBack, .minimizeAll, .minimizeFrontWindow]),
               "DockActionMode must contain all 4 modes")
        if let minimalData = "{\"enabled\": true}".data(using: .utf8),
           let decoded = try? JSONDecoder().decode(DockMinimizeConfig.self, from: minimalData) {
            expect(decoded.actionMode == .hideApp, "Decoded DockMinimizeConfig without actionMode should default to .hideApp")
        } else {
            failures.append("Failed to decode minimal DockMinimizeConfig JSON")
        }

        let primaryBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        expect(DockMinimizeModule.isPointNearDockEdge(CGPoint(x: 960, y: 1050), inDisplayBounds: primaryBounds),
               "Bottom Dock edge point should pass pre-filter")
        expect(DockMinimizeModule.isPointNearDockEdge(CGPoint(x: 40, y: 540), inDisplayBounds: primaryBounds),
               "Left Dock edge point should pass pre-filter")
        expect(DockMinimizeModule.isPointNearDockEdge(CGPoint(x: 1880, y: 540), inDisplayBounds: primaryBounds),
               "Right Dock edge point should pass pre-filter")
        expect(!DockMinimizeModule.isPointNearDockEdge(CGPoint(x: 100, y: 12), inDisplayBounds: primaryBounds),
               "Top menu bar point must be rejected by pre-filter")
        expect(!DockMinimizeModule.isPointNearDockEdge(CGPoint(x: 960, y: 540), inDisplayBounds: primaryBounds),
               "Center of display must be rejected by pre-filter")

        let secondaryBounds = CGRect(x: 1920, y: 100, width: 1440, height: 900)
        expect(DockMinimizeModule.isPointNearDockEdge(CGPoint(x: 2600, y: 970), inDisplayBounds: secondaryBounds),
               "Bottom Dock edge on offset secondary display should pass pre-filter")
        expect(!DockMinimizeModule.isPointNearDockEdge(CGPoint(x: 2000, y: 110), inDisplayBounds: secondaryBounds),
               "Top menu bar on offset secondary display must be rejected")

        let down = CGPoint(x: 500, y: 1040)
        expect(DockMinimizeModule.shouldExecuteDockClick(downLocation: down, upLocation: down, maxTravel: 0),
               "Zero-travel press/release should be treated as a Dock click")
        expect(DockMinimizeModule.shouldExecuteDockClick(downLocation: down, upLocation: CGPoint(x: 502, y: 1042), maxTravel: 2.8),
               "Tiny jitter within drag threshold should still count as a Dock click")
        expect(!DockMinimizeModule.shouldExecuteDockClick(downLocation: down, upLocation: CGPoint(x: 520, y: 1040), maxTravel: 20),
               "Drag past threshold must yield to the Dock")
        expect(!DockMinimizeModule.shouldExecuteDockClick(downLocation: down, upLocation: down, maxTravel: 12),
               "Drag-out-and-back exceeding maxTravel must still count as a drag, not a click")
        expect(!DockMinimizeModule.shouldExecuteDockClick(downLocation: down, upLocation: CGPoint(x: 510, y: 1040), maxTravel: 0),
               "Release location past threshold without intermediate drag events must still count as a drag")
    }

    private static func testDockMinimizeDecideMatrix() {
        let window = AXUIElementCreateApplication(1)

        let withOpen = DockMinimizeModule.WindowInspection(openWindows: [window], minimizableOpenWindows: [window])
        let withMinimized = DockMinimizeModule.WindowInspection(minimizedWindows: [window])
        let fullscreen = DockMinimizeModule.WindowInspection(openWindows: [window], minimizableOpenWindows: [window], hasActiveFullscreen: true)
        let empty = DockMinimizeModule.WindowInspection()

        func decision(
            _ mode: DockActionMode,
            _ isFrontmost: Bool,
            _ isHidden: Bool,
            _ inspection: DockMinimizeModule.WindowInspection,
            layerZero: Bool = false,
            wasHidden: Bool = false
        ) -> DockMinimizeModule.DockClickAction? {
            DockMinimizeModule.decideExternalClickAction(
                actionMode: mode,
                isFrontmost: isFrontmost,
                isHidden: isHidden,
                inspection: inspection,
                hasLayerZeroWindow: layerZero,
                wasHiddenByDockClick: wasHidden
            )
        }

        // Fullscreen apps are never acted on.
        expect(decision(.hideApp, true, false, fullscreen) == nil, "Fullscreen app must be left alone")
        expect(decision(.minimizeAll, true, false, fullscreen) == nil, "Fullscreen app must be left alone (minimizeAll)")

        // Hidden apps: restore if there is anything to bring back.
        expect(decision(.hideApp, false, true, withOpen) == .unhideAndFocus, "Hidden app with windows should unhide+focus")
        expect(decision(.hideApp, false, true, withMinimized) == .unhideAndFocus, "Hidden app with minimized windows should unhide+focus")
        expect(decision(.hideApp, false, true, empty, wasHidden: true) == .unhideAndFocus, "App we hid ourselves should unhide even with no windows")
        expect(decision(.hideApp, false, true, empty) == nil, "Hidden app with no windows and no hidden-state must be left alone")

        // All windows in the Dock tray: restore (sendToBack mode excepted).
        expect(decision(.hideApp, false, false, withMinimized) == .restore, "All-minimized app should restore")
        expect(decision(.minimizeFrontWindow, false, false, withMinimized) == .restore, "minimizeFrontWindow mode should also restore from tray")
        expect(decision(.sendToBack, false, false, withMinimized) == nil, "sendToBack mode must not restore from tray")

        // Only the frontmost app is hidden/sent back/minimized.
        expect(decision(.hideApp, true, false, withOpen) == .hideApp, "Frontmost app should hide in hideApp mode")
        expect(decision(.sendToBack, true, false, withOpen) == .sendToBack, "Frontmost app should send to back in sendToBack mode")
        expect(decision(.minimizeAll, true, false, withOpen) == .minimizeAll, "Frontmost app should minimize all")
        expect(decision(.minimizeFrontWindow, true, false, withOpen) == .minimizeFrontWindow, "Frontmost app should minimize front")
        expect(decision(.hideApp, false, false, withOpen) == nil, "Non-frontmost app must be left alone")

        // hideApp/sendToBack needs something to hide (AX windows or a layer-zero window).
        expect(decision(.hideApp, true, false, empty, layerZero: true) == .hideApp, "Frontmost app with on-screen layer-0 window should hide")
        expect(decision(.hideApp, true, false, empty) == nil, "Frontmost app with no windows at all must be left alone")

        // Minimizing requires a minimizable window.
        expect(decision(.minimizeAll, true, false, empty) == nil, "minimizeAll with nothing minimizable must be left alone")
    }

    private static func testUpdateManagerAndCustomDialog() {
        expect(UpdateManager.isNewerVersion("1.1", than: "1.0"), "1.1 should be newer than 1.0")
        expect(UpdateManager.isNewerVersion("1.10", than: "1.9"), "1.10 should be newer than 1.9 numerically")
        expect(!UpdateManager.isNewerVersion("1.0", than: "1.0"), "Equal versions must not count as newer")
        expect(!UpdateManager.isNewerVersion("0.9", than: "1.0"), "Older version must not count as newer")
        expect(UpdateManager.isNewerVersion("1.2", than: "1.2-beta"), "Plain release should supersede suffixed prerelease")
        expect(!UpdateManager.isNewerVersion("1.2-beta", than: "1.2"), "Prerelease must not supersede plain release")

        let manager = UpdateManager.shared
        expect(!manager.currentVersion.isEmpty, "UpdateManager.currentVersion must not be empty")

        let baseNow = Date()
        manager.configureStateForTesting(lastCheckedAt: nil)
        expect(manager.formattedLastChecked(relativeTo: baseNow) == "Never", "Nil lastCheckedAt must format as Never")

        manager.configureStateForTesting(lastCheckedAt: baseNow.addingTimeInterval(-10))
        expect(manager.formattedLastChecked(relativeTo: baseNow).hasPrefix("Just now"), "Recent check must format as Just now")

        manager.configureStateForTesting(lastCheckedAt: baseNow.addingTimeInterval(-3600))
        let hourAgoFormatted = manager.formattedLastChecked(relativeTo: baseNow)
        expect(hourAgoFormatted.hasPrefix("Today at ") || hourAgoFormatted.hasPrefix("Yesterday at "),
               "Check from 1h ago formatted unexpectedly: \(hourAgoFormatted)")

        manager.configureStateForTesting(
            isSparkleAvailable: true,
            isChecking: true,
            checkProgress: 0.45,
            pendingUpdateVersion: nil,
            lastCheckedAt: baseNow
        )
        expect(manager.isChecking && manager.checkProgress == 0.45, "Checking progress state mismatch")

        manager.configureStateForTesting(
            isSparkleAvailable: true,
            isChecking: false,
            checkProgress: 0,
            pendingUpdateVersion: "1.1",
            pendingUpdateSizeBytes: 2_500_000,
            lastCheckedAt: baseNow
        )
        expect(manager.pendingUpdateVersion == "1.1", "pendingUpdateVersion mismatch")
        expect(manager.formattedPendingSize != nil, "formattedPendingSize should format non-zero byte counts")

        let dialog = ToolboxUpdateWindowController()
        dialog.populatePreviewAvailable(
            version: "1.1",
            currentVersion: "1.0",
            sizeBytes: 2_500_000,
            notes: "<p><b>New Update</b></p>"
        )
        expect(dialog.currentTitleForTesting == "Toolbox v1.1 Available", "Custom update dialog title mismatch")
        expect(dialog.currentSubtitleForTesting.contains("v1.0"), "Custom update dialog subtitle must include current version")
        expect(!dialog.window.isVisible, "populatePreviewAvailable must stay offscreen during headless testing")

        manager.configureStateForTesting(
            isChecking: false,
            checkProgress: 0,
            pendingUpdateVersion: nil,
            lastCheckedAt: nil
        )
    }

    private static func testMenuBarCustomizationOrderAndVisibility() {
        var cfg = ToolboxConfig()
        let registry = ModuleRegistry.shared
        let expectedDefaultOrder = ["dock_minimize", "clipboard", "port_killer", "screen_ocr", "keep_awake", "custom_commands", "scroll_direction", "call_controls", "window_snapper", "finder_enhancer"]

        expect(!cfg.general.hasCustomMenuBarLayout, "Default config should not report custom menu bar layout")
        expect(cfg.general.showQuickActionsInMenuBar, "Quick actions should be shown in menu bar by default")
        expect(cfg.general.showQuickCommandsInMenuBar, "Quick commands should be shown in menu bar by default")
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == expectedDefaultOrder,
            "Default menu bar module order mismatch: \(registry.orderedMenuBarModules(for: cfg).map(\.id))"
        )
        expect(
            registry.visibleMenuBarModules(for: cfg).map(\.id) == expectedDefaultOrder,
            "All 10 menu-bar-eligible modules should be visible in menu bar by default"
        )

        cfg.general.moveModuleInMenuBar(id: "keep_awake", direction: -1)
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == ["dock_minimize", "clipboard", "port_killer", "keep_awake", "screen_ocr", "custom_commands", "scroll_direction", "call_controls", "window_snapper", "finder_enhancer"],
            "Moving keep_awake up by 1 should place it before screen_ocr"
        )
        expect(cfg.general.hasCustomMenuBarLayout, "Reordering should mark hasCustomMenuBarLayout = true")

        cfg.general.moveModuleInMenuBar(fromId: "scroll_direction", toId: "dock_minimize")
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == ["scroll_direction", "dock_minimize", "clipboard", "port_killer", "keep_awake", "screen_ocr", "custom_commands", "call_controls", "window_snapper", "finder_enhancer"],
            "Dragging scroll_direction to dock_minimize should place it first"
        )

        cfg.general.setModuleVisibleInMenuBar("dock_minimize", visible: false)
        expect(
            registry.visibleMenuBarModules(for: cfg).map(\.id) == ["scroll_direction", "clipboard", "port_killer", "keep_awake", "screen_ocr", "custom_commands", "call_controls", "window_snapper", "finder_enhancer"],
            "Hiding dock_minimize from menu bar should omit it from visibleMenuBarModules"
        )
        expect(cfg.dockMinimize.enabled, "Hiding dock_minimize from status bar menu must not disable the module itself")

        cfg.general.menuBarModuleOrder = ["keep_awake", "clean_lock", "keep_awake", "unknown_id"]
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == ["keep_awake", "dock_minimize", "clipboard", "port_killer", "screen_ocr", "custom_commands", "scroll_direction", "call_controls", "window_snapper", "finder_enhancer"],
            "Partial, non-menu-bar, or unknown menuBarModuleOrder must normalize with remaining eligible modules and no duplicates"
        )

        cfg.general.showQuickActionsInMenuBar = false
        cfg.general.showQuickCommandsInMenuBar = false
        expect(cfg.general.hasCustomMenuBarLayout, "Hiding quick actions/commands should mark custom layout")

        cfg.general.resetMenuBarLayout()
        expect(!cfg.general.hasCustomMenuBarLayout, "resetMenuBarLayout must clear custom layout state")
        expect(registry.visibleMenuBarModules(for: cfg).map(\.id) == expectedDefaultOrder, "resetMenuBarLayout must restore default visible modules")
        expect(cfg.general.showQuickActionsInMenuBar && cfg.general.showQuickCommandsInMenuBar, "resetMenuBarLayout must restore quick actions & quick commands")

        // VerticalDragReorderLayout<String> & VerticalDragReorderState<String> (Settings Status Bar Menu drag-to-reorder)
        let eligibleIDs = registry.modules.filter(\.supportsMenuBar).map(\.id)
        expect(!eligibleIDs.contains("clean_lock"), "Eligible menu bar IDs must exclude clean_lock")
        let settingsHeights = Dictionary(uniqueKeysWithValues: expectedDefaultOrder.map { ($0, CGFloat(52)) })
        guard let settingsLayout = VerticalDragReorderLayout(
            itemIDs: expectedDefaultOrder,
            heights: settingsHeights,
            draggedID: "keep_awake",
            spacing: 8,
            topInset: 0
        ) else {
            failures.append("VerticalDragReorderLayout<String> should initialize for Settings menu bar rows")
            return
        }
        expect(settingsLayout.distanceAboveDraggedCenter == 266, "distanceAboveDraggedCenter for index 4 should be 266 (got \(settingsLayout.distanceAboveDraggedCenter))")
        expect(settingsLayout.distanceBelowDraggedCenter == 326, "distanceBelowDraggedCenter for index 4 of 10 should be 326 (got \(settingsLayout.distanceBelowDraggedCenter))")
        expect(settingsLayout.restingShift(forRowAt: 2, targetIndex: 1) == 60, "Row shifting down past 52pt card + 8pt spacing should shift +60")

        let dragState = VerticalDragReorderState<String>()
        dragState.rowHeights = settingsHeights

        // Downward drag: dock_minimize (0) -> keep_awake slot (4)
        let currentOrder1 = registry.orderedMenuBarModules(for: cfg).map(\.id)
        let bounds1 = dragState.beginDrag(id: "dock_minimize", itemIDs: currentOrder1, spacing: 8, topInset: 0, fallbackHeight: 52)
        expect(bounds1 != nil && dragState.isDragging, "VerticalDragReorderState should start downward drag")
        dragState.updateDrag(rawDeltaY: 240)
        dragState.finishDrag { draggedID, targetID, _ in
            cfg.general.moveModuleInMenuBar(fromId: draggedID, toId: targetID, allModuleIDs: eligibleIDs)
        }
        expect(!dragState.isDragging, "finishDrag should end active drag")
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == ["clipboard", "port_killer", "screen_ocr", "keep_awake", "dock_minimize", "custom_commands", "scroll_direction", "call_controls", "window_snapper", "finder_enhancer"],
            "Downward Settings drag should place dock_minimize after keep_awake (got \(registry.orderedMenuBarModules(for: cfg).map(\.id)))"
        )
        expect(!cfg.general.menuBarModuleOrder.contains("clean_lock"), "menuBarModuleOrder must never include non-menu-bar clean_lock")

        // Upward drag: call_controls (7) -> top slot (0)
        let currentOrder2 = registry.orderedMenuBarModules(for: cfg).map(\.id)
        let bounds2 = dragState.beginDrag(id: "call_controls", itemIDs: currentOrder2, spacing: 8, topInset: 0, fallbackHeight: 52)
        expect(bounds2 != nil, "VerticalDragReorderState should start upward drag")
        dragState.updateDrag(rawDeltaY: -420)
        dragState.finishDrag { draggedID, targetID, _ in
            cfg.general.moveModuleInMenuBar(fromId: draggedID, toId: targetID, allModuleIDs: eligibleIDs)
        }
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == ["call_controls", "clipboard", "port_killer", "screen_ocr", "keep_awake", "dock_minimize", "custom_commands", "scroll_direction", "window_snapper", "finder_enhancer"],
            "Upward Settings drag should place call_controls at top (got \(registry.orderedMenuBarModules(for: cfg).map(\.id)))"
        )

        // Cancel drag without mutating order
        let preCancelOrder = registry.orderedMenuBarModules(for: cfg).map(\.id)
        var settingsCancelHooks = 0
        let bounds3 = dragState.beginDrag(
            id: "port_killer",
            itemIDs: preCancelOrder,
            spacing: 8,
            topInset: 0,
            fallbackHeight: 52,
            onExternalCancel: { settingsCancelHooks += 1 }
        )
        expect(bounds3 != nil, "Third Settings drag should start")
        dragState.updateDrag(rawDeltaY: -120)
        dragState.cancelActiveDrag()
        expect(!dragState.isDragging && settingsCancelHooks == 1, "cancelActiveDrag should invoke cancel hook and clear isDragging")
        expect(registry.orderedMenuBarModules(for: cfg).map(\.id) == preCancelOrder, "cancelActiveDrag must not reorder modules")
    }

    private static func testPortScannerParsersAndElevatedMerge() {
        let syntheticLsof = """
        p1234
        cnode
        u501
        f19
        n127.0.0.1:3000
        f20
        n[::1]:3000
        f21
        n127.0.0.1:9229
        p5678
        cpython3.11
        u501
        f5
        n*:8080
        """

        let syntheticNetstat = """
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state
        tcp4       0      0  127.0.0.1.3000         *.*                    LISTEN                 0            0  131072  131072             node:1234   00100
        tcp6       0      0  ::1.3000               *.*                    LISTEN                 0            0  131072  131072             node:1234   00100
        tcp4       0      0  *.80                   *.*                    LISTEN                 0            0  131072  131072            nginx:412    00100
        tcp4       0      0  127.0.0.1.49401        *.*                    LISTEN                 0            0  131072  131072 Antigravity Help:1616   00100
        tcp4       0      0  127.0.0.1.8000         127.0.0.1.51603        ESTABLISHED          760         2122  408000  146988       python3.11:1384   00102
        """

        let lsofRecs = PortScanner.parseLsofOutput(syntheticLsof)
        let netstatRecs = PortScanner.parseNetstatOutput(syntheticNetstat)

        expect(lsofRecs.count == 4, "Expected 4 lsof socket records, got \(lsofRecs.count)")
        expect(netstatRecs.count == 4, "Expected 4 netstat LISTEN records (ignoring ESTABLISHED), got \(netstatRecs.count)")
        expect(netstatRecs.contains(where: { $0.pid == 1616 && $0.command == "Antigravity Help" && $0.port == 49401 }), "netstat parser should preserve spaces in process names")

        let merged = PortScanner.mergeAndDeduplicate(
            lsofRecords: lsofRecs,
            netstatRecords: netstatRecs,
            currentUID: 501
        ) { pid in
            if pid == 412 {
                return ProcessMetadata(command: "nginx", uid: 0, executablePath: "/opt/homebrew/bin/nginx", workingDirectory: "/etc/nginx")
            }
            if pid == 1234 {
                return ProcessMetadata(command: "node", uid: 501, executablePath: "/usr/local/bin/node", workingDirectory: "/Users/dev/myapp")
            }
            return ProcessMetadata(command: nil, uid: nil, executablePath: nil, workingDirectory: nil)
        }

        // Expect: 412:80, 1234:3000 (deduped), 5678:8080, 1234:9229, 1616:49401 -> 5 entries
        expect(merged.count == 5, "Expected 5 deduplicated entries, got \(merged.count)")

        if let node3000 = merged.first(where: { $0.pid == 1234 && $0.port == 3000 }) {
            expect(node3000.addresses == ["127.0.0.1", "[::1]"], "Dual-stack node:3000 should collapse IPv4+IPv6: \(node3000.addresses)")
            expect(node3000.bindDisplay == "localhost (IPv4 + IPv6)", "bindDisplay mismatch: \(node3000.bindDisplay)")
            expect(!node3000.requiresElevation, "Same-UID process must not require elevation")
            expect(node3000.cwdBasename == "myapp", "cwdBasename mismatch: \(node3000.cwdBasename ?? "nil")")
        } else {
            failures.append("Missing merged entry for node:3000")
        }

        expect(merged.contains(where: { $0.pid == 1234 && $0.port == 9229 }), "Multi-port process should keep distinct (pid, port) entries")

        if let nginx80 = merged.first(where: { $0.pid == 412 && $0.port == 80 }) {
            expect(nginx80.requiresElevation, "Root-owned nginx:80 must be marked requiresElevation = true")
            expect(nginx80.ownerLabel == "root", "Root-owned nginx:80 ownerLabel should be 'root'")
            expect(!nginx80.seenInLsof, "Root-owned nginx:80 was surfaced via netstat, not lsof")
            expect(!nginx80.isSystemDaemon, "Root dev server nginx must not be hidden as an Apple system daemon")
        } else {
            failures.append("Missing root-owned nginx:80 entry from netstat merge")
        }
    }

    private static func testPortKillerSafetyAndLiveLoopbackListener() {
        expect(!PortKillerModule.validateKillTarget(pid: 0), "Must refuse PID 0")
        expect(!PortKillerModule.validateKillTarget(pid: 1), "Must refuse PID 1 (launchd)")
        expect(!PortKillerModule.validateKillTarget(pid: -1), "Must refuse negative PID")
        expect(!PortKillerModule.validateKillTarget(pid: ProcessInfo.processInfo.processIdentifier), "Must refuse self PID")
        expect(PortKillerModule.validateKillTarget(pid: 999_999), "Should allow normal non-self PID > 1")

        let module = PortKillerModule()
        let panel = module.ensurePanel()
        expect(!panel.hidesOnDeactivate, "PortKiller nonactivatingPanel must set hidesOnDeactivate = false")
        expect(panel.acceptsMouseMovedEvents, "PortKiller panel must accept mouse moved events for hover tooltips and cursors")
        expect(
            panel.contentView?.subviews.contains(where: { $0 is PointerCursorHostingView<PortKillerPopoverView> }) == true,
            "PortKiller panel must use PointerCursorHostingView to preserve hover cursors across layout and cursorUpdate"
        )

        // Verify PortKillerTooltipState respects 0.5s delay and exit-after-enter race protection
        let tipState = PortKillerTooltipState()
        var presented: HoverTooltipTarget?
        tipState.onPresent = { presented = $0 }
        tipState.setTooltip(HoverTooltipTarget(id: "btnA", text: "A", screenRect: CGRect(x: 10, y: 10, width: 20, height: 20)))
        expect(presented == nil, "Tooltip must wait 0.5s before presenting")
        tipState.setTooltip(HoverTooltipTarget(id: "btnB", text: "B", screenRect: CGRect(x: 40, y: 10, width: 20, height: 20)))
        tipState.setTooltip(nil, clearingID: "btnA") // Delayed exit from A must NOT cancel B
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        expect(presented?.id == "btnB", "Delayed exit for previous control must not cancel newer hovered tooltip")
        tipState.setTooltip(nil)
        expect(presented == nil, "Clearing tooltip state must hide presented tooltip")

        // Verify tooltip presents in an ignoresMouseEvents child NSPanel without mutating the popover hosting view
        panel.setFrame(NSRect(x: -5000, y: -5000, width: 400, height: 400), display: true)
        panel.orderFrontRegardless()
        let hostingView = panel.contentView?.subviews.first { $0 is PointerCursorHostingView<PortKillerPopoverView> }
        let hostingSubviewsBefore = hostingView?.subviews.count ?? -1
        module.updateTooltipPanel(
            with: HoverTooltipTarget(
                id: "test.tip",
                text: "Graceful Stop (SIGTERM)",
                screenRect: CGRect(x: -4720, y: -4760, width: 44, height: 20)
            ),
            requireMouseInside: false
        )
        let tipPanel = module.tooltipPanel
        expect(tipPanel != nil, "Tooltip must allocate a dedicated child NSPanel")
        expect(tipPanel?.ignoresMouseEvents == true, "Tooltip panel must ignore mouse events so hover stays on button")
        expect(tipPanel?.parent === panel, "Tooltip panel must attach as a child window of the popover panel")
        expect((hostingView?.subviews.count ?? -1) == hostingSubviewsBefore, "Presenting tooltip must not mutate popover hosting view")
        module.updateTooltipPanel(with: nil)
        expect(tipPanel?.parent == nil && tipPanel?.isVisible == false, "Clearing tooltip must detach and hide child panel")
        panel.orderOut(nil)

        // Bind a real ephemeral TCP loopback socket and verify PortScanner detects it live
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        expect(fd >= 0, "Should create test loopback socket")
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        expect(bindResult == 0, "Should bind test loopback socket to 127.0.0.1:0")
        expect(Darwin.listen(fd, 1) == 0, "Should listen on test loopback socket")

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.getsockname(fd, saPtr, &len)
            }
        }
        expect(nameResult == 0, "getsockname should succeed")
        let assignedPort = Int(UInt16(bigEndian: boundAddr.sin_port))
        expect(assignedPort > 0, "Assigned ephemeral port should be > 0")

        let scannedPorts = PortScanner.scanListeningPortsSync()

        let selfPID = ProcessInfo.processInfo.processIdentifier
        expect(
            scannedPorts.contains(where: { $0.pid == selfPID && $0.port == assignedPort }),
            "Live PortScanner.scanListeningPortsSync() should detect self PID \(selfPID) listening on :\(assignedPort)"
        )
    }

    private static func testDeveloperModeAndSimulations() {
        let suiteName = "com.toolbox.selftest.devmode.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            failures.append("Failed to allocate isolated UserDefaults suite")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let devMode = DeveloperModeManager(userDefaults: testDefaults, isSessionOnly: false)
        expect(!devMode.isUnlocked, "Developer mode must be locked by default")
        expect(!devMode.isPinPromptPresented, "PIN prompt must be hidden by default")
        expect(!devMode.stayUnlockedAcrossLaunches, "Session-only unlock should default to false")
        expect(devMode.unlockProgressHint == nil, "No hint should show before 2 taps")

        expect(!devMode.registerAboutHeaderTap(), "Tap 1 must not trigger PIN prompt")
        expect(devMode.unlockProgressHint == nil, "Tap 1 must not show hint yet")
        expect(!devMode.registerAboutHeaderTap(), "Tap 2 must not trigger PIN prompt")
        expect(devMode.unlockProgressHint == "3 more clicks to enter developer PIN", "Tap 2 hint mismatch: \(devMode.unlockProgressHint ?? "nil")")
        expect(!devMode.registerAboutHeaderTap(), "Tap 3 must not trigger PIN prompt")
        expect(!devMode.registerAboutHeaderTap(), "Tap 4 must not trigger PIN prompt")
        expect(devMode.unlockProgressHint == "1 more click to enter developer PIN", "Tap 4 hint mismatch: \(devMode.unlockProgressHint ?? "nil")")
        expect(devMode.registerAboutHeaderTap(), "Tap 5 must trigger PIN prompt")
        expect(devMode.isPinPromptPresented, "Tap 5 should present PIN prompt")
        expect(!devMode.isUnlocked, "Tap 5 must NOT bypass the PIN gate")
        expect(devMode.unlockProgressHint == nil, "Hint must clear once PIN prompt triggers")

        // Verify PIN validation, brute-force rate limiting, and cooldown recovery
        expect(!devMode.verifyPIN("0000") && devMode.verifyPIN("1708"), "PIN verification mismatch")
        let t0 = Date()
        expect(devMode.submitPIN("1111", now: t0) == .wrongPin(remainingAttempts: 4), "Attempt 1 wrong PIN mismatch")
        expect(devMode.submitPIN("2222", now: t0) == .wrongPin(remainingAttempts: 3), "Attempt 2 wrong PIN mismatch")
        expect(devMode.submitPIN("3333", now: t0) == .wrongPin(remainingAttempts: 2), "Attempt 3 wrong PIN mismatch")
        expect(devMode.submitPIN("4444", now: t0) == .wrongPin(remainingAttempts: 1), "Attempt 4 wrong PIN mismatch")
        expect(devMode.submitPIN("5555", now: t0) == .lockedOut(remainingSeconds: 15), "Attempt 5 should trigger 15s lockout")
        expect(devMode.submitPIN("1708", now: t0.addingTimeInterval(2)) == .lockedOut(remainingSeconds: 13), "Even correct PIN must be blocked during lockout")
        expect(!devMode.isUnlocked, "Must stay locked during cooldown")

        expect(devMode.submitPIN("1708", now: t0.addingTimeInterval(16)) == .unlocked, "Correct PIN after cooldown should unlock")
        expect(devMode.isUnlocked && !devMode.isPinPromptPresented, "Unlock should dismiss PIN prompt")

        // Session-only by default (does not persist unless opt-in is enabled)
        let sessionReload = DeveloperModeManager(userDefaults: testDefaults, isSessionOnly: false)
        expect(!sessionReload.isUnlocked, "Developer mode must re-lock across launches by default")

        // Opt-in persistent unlock
        devMode.stayUnlockedAcrossLaunches = true
        let persistedReload = DeveloperModeManager(userDefaults: testDefaults, isSessionOnly: false)
        expect(persistedReload.isUnlocked, "Developer mode should persist when stayUnlockedAcrossLaunches is enabled")
        persistedReload.lock()
        let postLockReload = DeveloperModeManager(userDefaults: testDefaults, isSessionOnly: false)
        expect(!postLockReload.isUnlocked, "Explicit lock() must require PIN on next launch")

        // Developer sections, presets, and release notes templates
        expect(DeveloperSection.allCases.count == 7 && DeveloperSection.allCases.contains(.screenOCR) && DeveloperSection.allCases.contains(.callControls), "Expected 7 DeveloperSection cases including .screenOCR and .callControls")
        expect(
            UpdateSimulationPreset.allCases.allSatisfy { !$0.summary.isEmpty },
            "All UpdateSimulationPreset cases should have non-empty summaries"
        )
        devMode.selectedReleaseNotesPreset = .longScrollable
        expect(
            devMode.effectiveReleaseNotes(for: "2.0.0").contains("Bug Fixes & Hardening"),
            "Long release notes preset should populate extended changelog"
        )
        devMode.selectedErrorPreset = .eddsaSignatureInvalid
        expect(
            devMode.simulatedUpdateError.contains("SUPublicEDKey"),
            "Selecting UpdateErrorPreset should update simulatedUpdateError"
        )
        devMode.selectedErrorPreset = .networkTimeout
        devMode.selectedReleaseNotesPreset = .standard

        // Navigation pruning when locking
        let nav = NavigationState()
        nav.navigate(to: .settings)
        nav.navigate(to: .developer(.eventsAndTaps))
        nav.navigate(to: .developer(.hotKeysAndConfig))
        expect(nav.selection == .developer(.hotKeysAndConfig), "NavigationState should allow .developer subsections")
        nav.pruneDeveloperDestinations(fallback: .settings)
        expect(nav.selection == .settings, "pruneDeveloperDestinations should navigate away from .developer destinations")
        expect(
            !nav.history.contains {
                if case .developer = $0 { return true }
                return false
            },
            "pruneDeveloperDestinations should remove all .developer destinations from history"
        )

        // UpdateManager simulation presets
        let updateMgr = UpdateManager.shared
        updateMgr.applySimulationPreset(.updateAvailable, version: "2.4.0", sizeBytes: 4_200_000)
        expect(updateMgr.isSimulatingState, "isSimulatingState should be true during preset simulation")
        expect(updateMgr.activeSimulationPreset == .updateAvailable, "activeSimulationPreset mismatch")
        expect(updateMgr.pendingUpdateVersion == "2.4.0", "Simulated pendingUpdateVersion mismatch")
        expect(updateMgr.pendingReleaseNotes?.contains("Toolbox v2.4.0") == true, "Simulated release notes should reference simulated version")

        updateMgr.applySimulationPreset(.checking)
        expect(updateMgr.isChecking && updateMgr.checkProgress == 0.62, "Checking preset should hold at 62%")

        updateMgr.applySimulationPreset(.checkFailed, errorMessage: "Simulated timeout")
        expect(updateMgr.lastCheckFailed && updateMgr.lastCheckError == "Simulated timeout", "Check failed preset mismatch")

        // One-shot 5s background schedule test & cancel/restore
        updateMgr.setDeveloperScheduleInterval(5)
        expect(
            updateMgr.isUsingCustomScheduleInterval
                && Int(updateMgr.scheduledCheckIntervalSeconds) == 5
                && updateMgr.customScheduleNextFireDate != nil,
            "5s dev schedule test should set scheduledCheckIntervalSeconds and start a live countdown"
        )
        updateMgr.setDeveloperScheduleInterval(nil)
        expect(
            !updateMgr.isUsingCustomScheduleInterval
                && Int(updateMgr.scheduledCheckIntervalSeconds) == Int(UpdateManager.defaultCheckIntervalSeconds)
                && updateMgr.customScheduleNextFireDate == nil,
            "Clearing dev schedule interval should restore default and clear custom countdown"
        )
        let initialBgCount = updateMgr.backgroundChecksCount
        updateMgr.recordBackgroundCheckOutcome("Up to date (v1.1)")
        expect(
            updateMgr.backgroundChecksCount == initialBgCount + 1 && updateMgr.lastBackgroundCheckAt != nil && updateMgr.lastBackgroundCheckOutcome == "Up to date (v1.1)",
            "recordBackgroundCheckOutcome should increment counter and store timestamp/outcome"
        )

        // Update dialog centering over app window and screen fallback
        let screenVisible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let appFrame = NSRect(x: 300, y: 120, width: 960, height: 680)
        let centeredOnApp = ToolboxUpdateWindowController.centeredOrigin(
            for: NSSize(width: 468, height: 344),
            relativeTo: appFrame,
            within: screenVisible
        )
        expect(
            centeredOnApp.x == 546 && centeredOnApp.y == 288,
            "Update dialog should center over Toolbox window, got \(centeredOnApp)"
        )
        let centeredOnScreen = ToolboxUpdateWindowController.centeredOrigin(
            for: NSSize(width: 468, height: 196),
            relativeTo: nil,
            within: screenVisible
        )
        expect(
            centeredOnScreen.x == 486 && centeredOnScreen.y == 340,
            "Update dialog should center vertically on screen when main window is closed, got \(centeredOnScreen)"
        )
        let clampedOrigin = ToolboxUpdateWindowController.centeredOrigin(
            for: NSSize(width: 468, height: 344),
            relativeTo: NSRect(x: 1300, y: 800, width: 400, height: 300),
            within: screenVisible
        )
        expect(
            clampedOrigin.x == screenVisible.maxX - 468 && clampedOrigin.y == screenVisible.maxY - 344,
            "Update dialog centering should clamp inside screen visibleFrame, got \(clampedOrigin)"
        )

        // PermissionsManager UI override
        let perms = PermissionsManager.shared
        let liveActual = perms.actualAccessibilityGranted
        perms.setSimulatedAccessibilityGranted(!liveActual)
        expect(perms.isAccessibilityGranted == !liveActual, "Simulated accessibility override must update UI state")
        expect(perms.actualAccessibilityGranted == liveActual, "Simulated accessibility override must not alter actualAccessibilityGranted")

        // Health checks & appcast XML parsing
        let checks = DeveloperHealthCheckRunner.shared.runAllChecks()
        expect(checks.count == 10, "Expected 10 preflight health checks, got \(checks.count)")
        expect(checks.contains(where: { $0.id == "security_hardening" }), "Expected security_hardening health check")
        expect(checks.contains(where: { $0.id == "login_app_policy" }), "Expected login_app_policy health check")
        expect(checks.contains(where: { $0.id == "simulation_guard" && $0.severity == .warning }), "Simulation guard check should warn while overrides are active")
        if let lifecycleCheck = checks.first(where: { $0.id == "module_lifecycle" }) {
            expect(
                lifecycleCheck.detail?.contains("Keyboard Lock") != true,
                "Module Lifecycle Consistency must not flag idle on-demand Keyboard Lock (got: \(lifecycleCheck.detail ?? "nil"))"
            )
        } else {
            failures.append("Expected module_lifecycle health check")
        }
        expect(
            DeveloperHealthCheckRunner.moduleLifecycleMismatch(
                for: ModuleRegistry.shared.cleanLock,
                config: ToolboxConfig(),
                actualAX: true
            ) == nil,
            "Idle on-demand CleanLockModule must pass lifecycle consistency check"
        )
        let scenarios = ToastTestScenario.allCases
        expect(scenarios.count == 4, "Expected 4 HUD toast visual test scenarios (got \(scenarios.count))")
        if scenarios.count == 4 {
            expect(
                scenarios[0].title.count < scenarios[1].title.count
                    && scenarios[1].title.count < scenarios[2].title.count
                    && scenarios[2].title.count < scenarios[3].title.count,
                "ToastTestScenario titles must increase strictly in length (short < standard < long < overflow)"
            )
        }

        let sampleSpctl = "/Applications/Toolbox.app: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Example (TEAMID)"
        expect(
            DeveloperHealthCheckRunner.parseGatekeeperSource(from: sampleSpctl) == "Notarized Developer ID",
            "Gatekeeper source parser mismatch"
        )

        let sampleAppcast = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <sparkle:shortVersionString>1.3.0</sparkle:shortVersionString>
              <enclosure url="https://example.com/Toolbox.zip" sparkle:version="1.3.0" />
            </item>
          </channel>
        </rss>
        """.data(using: .utf8)!
        let parsedVersions = DeveloperHealthCheckRunner.parseAppcastVersions(from: sampleAppcast)
        expect(parsedVersions == ["1.3.0"], "Appcast XML version parser mismatch: \(parsedVersions)")

        // Runtime diagnostics snapshot & signing report
        let diag = RuntimeDiagnosticsSnapshot.capture()
        let report = diag.formattedReport(healthChecks: checks)
        let signingReport = diag.formattedSigningReport()
        expect(!diag.signing.signingIdentifier.isEmpty, "CodeSigningInspection should populate signingIdentifier")
        expect(!diag.architectureSummary.isEmpty && diag.pid > 0, "RuntimeDiagnosticsSnapshot should populate architecture and PID")
        expect(!diag.version.isEmpty && report.contains("Toolbox Diagnostics Report") && report.contains("Health Checks:") && report.contains("CDHash:"), "Diagnostics report should include header, CDHash, version, and health checks")
        expect(signingReport.contains("Toolbox Signing & Packaging Details") && signingReport.contains("Hardened Runtime:"), "Signing report should include hardened runtime and details")

        // Event log ring buffer, filtering, and export
        let eventLog = DeveloperEventLog.shared
        eventLog.clear()
        for idx in 0..<(DeveloperEventLog.maxEntries + 12) {
            eventLog.record(.dock, "Event \(idx)", detail: idx % 2 == 0 ? "tag-even" : nil)
        }
        expect(eventLog.entries.count == DeveloperEventLog.maxEntries, "DeveloperEventLog should cap at \(DeveloperEventLog.maxEntries) entries")
        expect(eventLog.entries.first?.message == "Event \(DeveloperEventLog.maxEntries + 11)", "DeveloperEventLog should store newest entries first")
        let filteredEvents = eventLog.filteredEntries(category: .dock, query: "tag-even")
        expect(!filteredEvents.isEmpty && filteredEvents.allSatisfy { $0.detail == "tag-even" }, "Event log filter mismatch")
        expect(eventLog.formattedExport(category: .dock, query: "tag-even").contains("Toolbox Event Log"), "Event log export mismatch")
        eventLog.clear()

        // Config checkpoint, diff, and section reset
        let checkpointStore = ConfigCheckpointStore.shared
        var baseCfg = ToolboxConfig()
        baseCfg.clipboard.maxItems = 50
        var modifiedCfg = baseCfg
        modifiedCfg.clipboard.maxItems = 99
        let diffs = ConfigCheckpointStore.diff(from: baseCfg, to: modifiedCfg)
        expect(
            diffs == [ConfigDiffItem(keyPath: "clipboard.maxItems", baselineValue: "50", currentValue: "99")],
            "Config diff mismatch: \(diffs)"
        )
        checkpointStore.saveCheckpoint(from: baseCfg)
        expect(!checkpointStore.diffsAgainstCheckpoint(current: modifiedCfg).isEmpty, "Checkpoint diff should detect changes")
        checkpointStore.clearCheckpoint()

        // HotKeyManager snapshot & simulated trigger
        let hkMgr = HotKeyManager.shared
        var didFireSimulatedHotKey = false
        _ = hkMgr.register(name: "dev.self_test.trigger", shortcut: ShortcutSpec.none) {}
        expect(!hkMgr.registeredHotKeys.contains(where: { $0.name == "dev.self_test.trigger" }), "Empty shortcut should not register")
        let regOK = hkMgr.register(name: "dev.self_test.trigger", shortcut: ShortcutSpec(key: "F19", modifiers: [.control, .option])) {
            didFireSimulatedHotKey = true
        }
        expect(regOK && hkMgr.registeredHotKeys.contains(where: { $0.name == "dev.self_test.trigger" }), "Registered hotkey should appear in snapshot")
        expect(hkMgr.simulateTrigger(name: "dev.self_test.trigger") && didFireSimulatedHotKey, "simulateTrigger should invoke registered handler")
        hkMgr.unregister(name: "dev.self_test.trigger")
        eventLog.clear()

        // Locking cleans up all simulations
        devMode.lock()
        expect(!devMode.isUnlocked, "lock() must disable Developer Tools")
        expect(!updateMgr.isSimulatingState && updateMgr.pendingUpdateVersion == nil, "lock() must clear UpdateManager simulation")
        expect(perms.simulatedAccessibilityGranted == nil, "lock() must clear PermissionsManager simulation")
    }

    private static func testCleanLockEventFilteringAndLifecycle() {
        // Config defaults & duration clamping
        let defaultCleanLock = CleanLockConfig()
        expect(!ModuleRegistry.shared.cleanLock.supportsEnableToggle, "CleanLock should not expose an enable/disable toggle")
        expect(!ModuleRegistry.shared.cleanLock.supportsMenuBar, "CleanLock should not appear in the Status Bar menu")
        expect(defaultCleanLock.durationSeconds == 60, "CleanLock default duration should be 60s")
        expect(defaultCleanLock.lockMouseAndTrackpad, "CleanLock should lock mouse & trackpad by default")
        expect(CleanLockConfig.clampedDuration(2) == 10, "Duration below 10s must clamp to 10s")
        expect(CleanLockConfig.clampedDuration(999) == 300, "Duration above 300s must clamp to 300s")
        expect(CleanLockConfig.clampedDuration(45) == 45, "In-range duration should be preserved")

        // Pure event filtering & kill-switch hold tests using synthesized CGEvents
        let tap = InputLockTap()
        let t0: TimeInterval = 1000.0
        tap.configureSession(lockMouseAndTrackpad: true, now: t0)

        // Sticky modifier grace (< 150ms) lets flagsChanged through without incrementing blockedCount
        if let flagsRelease = CGEvent(source: nil) {
            flagsRelease.type = .flagsChanged
            let decision = tap.evaluateEvent(flagsRelease, now: t0 + 0.05)
            expect(decision == .passThrough, "flagsChanged within sticky grace period should passThrough")
            expect(tap.currentBlockedCount == 0, "Grace period flagsChanged should not increment blockedCount")
        } else {
            failures.append("Failed to synthesize CGEvent for sticky modifier test")
        }

        // Keyboard keyDown ('A' = keyCode 0) after grace period should swallow & increment blockedCount
        if let keyA = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
            let decision = tap.evaluateEvent(keyA, now: t0 + 0.5)
            expect(decision == .swallow, "keyDown('A') should be swallowed during Clean Lock")
            expect(tap.currentBlockedCount == 1, "Swallowed keyDown should increment blockedCount to 1")
        } else {
            failures.append("Failed to synthesize CGEvent for keyDown('A')")
        }

        // mouseMoved must always passThrough
        if let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left
        ) {
            expect(tap.evaluateEvent(moveEvent, now: t0 + 0.6) == .passThrough, "mouseMoved must passThrough")
        }

        // Mouse click & scroll when lockMouseAndTrackpad == true -> swallow
        if let clickEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left
        ) {
            expect(tap.evaluateEvent(clickEvent, now: t0 + 0.7) == .swallow, "leftMouseDown should swallow when lockMouseAndTrackpad is true")
        }
        if let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 3,
            wheel2: 0,
            wheel3: 0
        ) {
            expect(tap.evaluateEvent(scrollEvent, now: t0 + 0.8) == .swallow, "scrollWheel should swallow when lockMouseAndTrackpad is true")
        }

        // Mouse click & scroll when lockMouseAndTrackpad == false -> passThrough
        tap.configureSession(lockMouseAndTrackpad: false, now: t0)
        if let clickEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left
        ) {
            expect(tap.evaluateEvent(clickEvent, now: t0 + 0.7) == .passThrough, "leftMouseDown should passThrough when lockMouseAndTrackpad is false")
        }
        if let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 3,
            wheel2: 0,
            wheel3: 0
        ) {
            expect(tap.evaluateEvent(scrollEvent, now: t0 + 0.8) == .passThrough, "scrollWheel should passThrough when lockMouseAndTrackpad is false")
        }

        // Quick tap of Ctrl+Opt+Cmd+Esc released before 3s -> resets hold progress & stays locked
        tap.configureSession(lockMouseAndTrackpad: true, now: t0)
        let killFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        if let escDown1 = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(InputLockTap.escapeKeyCode), keyDown: true),
           let escUp1 = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(InputLockTap.escapeKeyCode), keyDown: false),
           let escDown2 = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(InputLockTap.escapeKeyCode), keyDown: true) {
            escDown1.flags = killFlags
            escUp1.flags = killFlags
            escDown2.flags = killFlags

            expect(tap.evaluateEvent(escDown1, now: t0 + 1.0) == .swallow, "Initial kill switch keyDown should swallow")
            expect(tap.currentKillSwitchProgress(now: t0 + 2.5) > 0.4, "Kill switch progress should advance while held")
            expect(tap.evaluateEvent(escUp1, now: t0 + 2.6) == .swallow, "Early Esc keyUp should swallow and reset")
            expect(tap.currentKillSwitchProgress(now: t0 + 2.7) == 0.0, "Early Esc release must reset kill switch progress")

            // Continuous hold >= 3s -> triggers .unlock while swallowing Esc
            expect(tap.evaluateEvent(escDown2, now: t0 + 3.0) == .swallow, "Restarted kill switch hold should swallow at 0s")
            expect(tap.evaluateEvent(escDown2, now: t0 + 5.9) == .swallow, "Kill switch hold at 2.9s should still swallow")
            expect(tap.evaluateEvent(escDown2, now: t0 + 6.0) == .unlock, "Kill switch hold >= 3.0s must trigger .unlock")

            // Post-unlock Esc release grace: swallow held Esc repeats/keyUp (avoiding macOS beep) while passing other keys through
            expect(tap.evaluateEvent(escDown2, now: t0 + 6.1) == .swallow, "Held Esc repeat right after unlock should be swallowed")
            if let keyA = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                expect(tap.evaluateEvent(keyA, now: t0 + 6.2) == .passThrough, "Other keys must passThrough immediately after unlock")
            }
            expect(tap.evaluateEvent(escUp1, now: t0 + 6.3) == .swallow, "Final Esc keyUp after unlock should be swallowed")
        } else {
            failures.append("Failed to synthesize Esc CGEvents for kill switch test")
        }

        // Countdown timer expiration & stop() teardown
        let module = ModuleRegistry.shared.cleanLock
        module.beginCountdownSession(durationSeconds: 10, lockMouseAndTrackpad: true, showHUD: false)
        expect(module.isLocked && module.remainingSeconds == 10, "Countdown session should enter locked state with 10s remaining")
        module.tickCountdown(now: Date().addingTimeInterval(11))
        expect(!module.isLocked && module.remainingSeconds == 0, "Timer reaching 0 must clear locked state")

        module.beginCountdownSession(durationSeconds: 15, lockMouseAndTrackpad: true, showHUD: false)
        expect(module.isLocked, "Countdown session should be locked before stop()")
        module.stop()
        expect(!module.isLocked, "stop() must cancel countdown and clear locked state")

        let prevAppEnabled = ConfigManager.shared.config.general.appEnabled
        ConfigManager.shared.config.general.appEnabled = false
        expect(!module.lock(), "CleanLockModule.lock() must refuse when general.appEnabled is false")
        ConfigManager.shared.config.general.appEnabled = prevAppEnabled
    }

    private static func testCallControlsConfigAndCoreAudioEnumeration() {
        let cfg = ToolboxConfig()
        expect(cfg.schemaVersion == 15, "ToolboxConfig schemaVersion should be 15")
        expect(!cfg.callControls.enabled, "Call Controls should default to disabled")
        expect(cfg.callControls.overrideScope == .everywhere, "Default overrideScope should be everywhere")
        expect(cfg.callControls.typingUnmuteDelayMs == 450, "Default typingUnmuteDelayMs should be 450")
        expect(cfg.callControls.showFloatingMicIndicator, "showFloatingMicIndicator should default to true")
        expect(cfg.callControls.showVideoInFloatingIndicator, "showVideoInFloatingIndicator should default to true")
        expect(cfg.callControls.showFloatingPillOnlyDuringCalls, "showFloatingPillOnlyDuringCalls should default to true")
        expect(cfg.callControls.showToasts, "showToasts should default to true")

        let presetIDs = Set(cfg.callControls.appShortcutMappings.map(\.id))
        expect(
            presetIDs == Set(["teams", "zoom", "slack", "google_meet", "discord", "facetime"]),
            "Call Controls defaults should include all 6 built-in call apps: \(presetIDs)"
        )

        var customCfg = ToolboxConfig()
        customCfg.callControls.enabled = true
        customCfg.callControls.micShortcut = ShortcutSpec(key: "space", modifiers: [.command, .shift])
        customCfg.callControls.videoShortcut = ShortcutSpec(key: "v", modifiers: [.control, .option, .command])
        customCfg.callControls.typingUnmuteDelayMs = 600
        customCfg.callControls.showVideoInFloatingIndicator = false
        customCfg.callControls.showFloatingPillOnlyDuringCalls = false
        customCfg.callControls.favoriteOutputUIDs = ["BuiltInSpeakerDevice"]

        if let data = try? JSONEncoder().encode(customCfg),
           let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(decoded.callControls == customCfg.callControls, "CallControlsConfig Codable round-trip mismatch")
        } else {
            failures.append("CallControlsConfig Codable encode/decode failed")
        }

        // Legacy v5 config without callControls/audioGuard key must migrate cleanly
        let legacyJSON = "{\"schemaVersion\": 5, \"general\": {\"appEnabled\": true}}"
        if let data = legacyJSON.data(using: .utf8),
           let migrated = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(migrated.schemaVersion == 15, "Legacy config should upgrade to schemaVersion 15")
            expect(!migrated.callControls.enabled, "Legacy config must migrate callControls.enabled = false")
            expect(migrated.callControls.overrideScope == .everywhere, "Migrated default overrideScope should be everywhere")
            expect(migrated.callControls.showFloatingPillOnlyDuringCalls, "Legacy config must migrate showFloatingPillOnlyDuringCalls = true")
            expect(migrated.callControls.appShortcutMappings.count == 6, "Legacy config must populate 6 default call app presets")
        } else {
            failures.append("Failed to decode pre-CallControls JSON config")
        }

        // Legacy v6 config with active_call_app_only upgrades to everywhere
        let v6JSON = """
        {"schemaVersion": 6, "general": {"appEnabled": true}, "audioGuard": {"enabled": true, "overrideScope": "active_call_app_only"}}
        """
        if let data = v6JSON.data(using: .utf8),
           let upgraded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(upgraded.schemaVersion == 15, "v6 config should migrate to schemaVersion 15")
            expect(upgraded.callControls.overrideScope == .everywhere, "v6 active_call_app_only should upgrade to everywhere")
            expect(upgraded.callControls.showFloatingPillOnlyDuringCalls, "v6 config should upgrade showFloatingPillOnlyDuringCalls to true")
        } else {
            failures.append("Failed to migrate v6 audioGuard config")
        }

        // Legacy v7 config upgrades call-only pill default to true
        let v7JSON = """
        {"schemaVersion": 7, "general": {"appEnabled": true}, "audioGuard": {"enabled": true, "showFloatingPillOnlyDuringCalls": false}}
        """
        if let data = v7JSON.data(using: .utf8),
           let upgradedV7 = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(upgradedV7.schemaVersion == 15, "v7 config should migrate to schemaVersion 15")
            expect(upgradedV7.callControls.showFloatingPillOnlyDuringCalls, "v7 showFloatingPillOnlyDuringCalls should upgrade to true")
        } else {
            failures.append("Failed to migrate v7 audioGuard config")
        }

        // Legacy v8 config using audioGuard + audio_guard menu bar IDs must migrate cleanly to callControls + call_controls
        let v8JSON = """
        {"schemaVersion": 8, "general": {"appEnabled": true, "menuBarModuleOrder": ["dock_minimize", "audio_guard", "clipboard"], "menuBarHiddenModules": ["audio_guard"]}, "audioGuard": {"enabled": true, "typingUnmuteDelayMs": 725}}
        """
        if let data = v8JSON.data(using: .utf8),
           let upgradedV8 = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(upgradedV8.schemaVersion == 15, "v8 config should migrate to schemaVersion 15")
            expect(upgradedV8.callControls.enabled, "v8 audioGuard.enabled must migrate to callControls.enabled")
            expect(upgradedV8.callControls.typingUnmuteDelayMs == 725, "v8 audioGuard fields must be preserved in callControls")
            expect(
                upgradedV8.general.menuBarModuleOrder.contains("call_controls") && !upgradedV8.general.menuBarModuleOrder.contains("audio_guard"),
                "v8 menuBarModuleOrder must rewrite audio_guard to call_controls"
            )
            expect(
                upgradedV8.general.menuBarHiddenModules.contains("call_controls") && !upgradedV8.general.menuBarHiddenModules.contains("audio_guard"),
                "v8 menuBarHiddenModules must rewrite audio_guard to call_controls"
            )
        } else {
            failures.append("Failed to migrate v8 audioGuard config")
        }

        // CoreAudio & CoreMediaIO enumeration must complete safely even on headless Macs
        let devices = CoreAudioController.listDevices()
        for dev in devices {
            expect(dev.hasInput || dev.hasOutput, "Enumerated audio device \(dev.name) must have input or output channels")
        }
        _ = CoreAudioController.currentCameraStatus()
        _ = CoreAudioController.isDefaultInputRunningSomewhere()
    }

    private static func testCallControlsShortcutRemapper() {
        let micShortcut = ShortcutSpec(key: "space", modifiers: [.command, .shift])
        let videoShortcut = ShortcutSpec(key: "v", modifiers: [.control, .option, .command])
        let spaceCode = UInt16(micShortcut.carbonKeyCode ?? 49)
        let vCode = UInt16(videoShortcut.carbonKeyCode ?? 9)
        var mappings = CallAppShortcutMapping.defaults

        // 1. Same-shortcut pass-through in Slack (Slack native mic is already Cmd+Shift+Space)
        let slackPass = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeCallAppOnly,
            mappings: mappings,
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            frontmostPID: 101,
            frontmostWindowTitle: "Slack",
            runningApps: []
        )
        expect(slackPass == .passThrough, "Pressing Cmd+Shift+Space in Slack when micShortcut == Cmd+Shift+Space should passThrough")

        // 2. Microsoft Teams active -> remaps Cmd+Shift+Space to Cmd+Shift+M
        let teamsRemap = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeCallAppOnly,
            mappings: mappings,
            frontmostBundleID: "com.microsoft.teams2",
            frontmostPID: 202,
            frontmostWindowTitle: "Microsoft Teams",
            runningApps: []
        )
        if case .remap(let action, let app, let pid, let targetShortcut, let focusRestore) = teamsRemap {
            expect(action == .mic, "Teams remap action should be .mic")
            expect(app.id == "teams", "Target app should be Teams")
            expect(pid == 202, "Target PID should match frontmost Teams PID")
            expect(targetShortcut == ShortcutSpec(key: "m", modifiers: [.command, .shift]), "Teams mic target shortcut mismatch")
            expect(!focusRestore, "Frontmost Teams remap must not trigger background focus restore")
        } else {
            failures.append("Expected .remap for active Teams window, got \(teamsRemap)")
        }

        // 3. Toggled-off app is never matched
        if let idx = mappings.firstIndex(where: { $0.id == "teams" }) {
            mappings[idx].enabled = false
        }
        let disabledTeams = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeCallAppOnly,
            mappings: mappings,
            frontmostBundleID: "com.microsoft.teams2",
            frontmostPID: 202,
            frontmostWindowTitle: "Microsoft Teams",
            runningApps: []
        )
        expect(disabledTeams == .passThrough, "Disabled call app mapping must passThrough")
        if let idx = mappings.firstIndex(where: { $0.id == "teams" }) {
            mappings[idx].enabled = true
        }

        // 4. Non-call frontmost app passes through in activeCallAppOnly, and routes in activeOrRunningBackground
        let xcodePass = CallShortcutRemapper.resolveDecision(
            keyCode: vCode,
            modifiers: [.control, .option, .command],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeCallAppOnly,
            mappings: mappings,
            frontmostBundleID: "com.apple.dt.Xcode",
            frontmostPID: 303,
            frontmostWindowTitle: "Toolbox.swift",
            runningApps: [RunningCallAppSnapshot(bundleIdentifier: "com.microsoft.teams2", pid: 202, windowTitles: ["Teams"])]
        )
        expect(xcodePass == .passThrough, "Non-call app in activeCallAppOnly must passThrough")

        let backgroundTeams = CallShortcutRemapper.resolveDecision(
            keyCode: vCode,
            modifiers: [.control, .option, .command],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeOrRunningBackground,
            mappings: mappings,
            frontmostBundleID: "com.apple.dt.Xcode",
            frontmostPID: 303,
            frontmostWindowTitle: "Toolbox.swift",
            runningApps: [RunningCallAppSnapshot(bundleIdentifier: "com.microsoft.teams2", pid: 202, windowTitles: ["Teams"])]
        )
        if case .remap(let action, let app, let pid, let targetShortcut, let focusRestore) = backgroundTeams {
            expect(action == .video, "Background Teams action should be .video")
            expect(app.id == "teams", "Background target app should be Teams")
            expect(pid == 202, "Background target PID mismatch")
            expect(targetShortcut == ShortcutSpec(key: "o", modifiers: [.command, .shift]), "Teams video target shortcut mismatch")
            expect(focusRestore, "Background Teams remap should request brief focus restore")
        } else {
            failures.append("Expected .remap for background Teams in activeOrRunningBackground mode")
        }

        // 5. Window-title gate for Google Meet in Chrome
        let regularChrome = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeCallAppOnly,
            mappings: mappings,
            frontmostBundleID: "com.google.Chrome",
            frontmostPID: 404,
            frontmostWindowTitle: "GitHub - Pull Requests",
            runningApps: []
        )
        expect(regularChrome == .passThrough, "Regular Chrome tab without 'Meet' in title must passThrough")

        let meetChrome = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeCallAppOnly,
            mappings: mappings,
            frontmostBundleID: "com.google.Chrome",
            frontmostPID: 404,
            frontmostWindowTitle: "Meet - Weekly Standup",
            runningApps: []
        )
        if case .remap(let action, let app, _, let targetShortcut, _) = meetChrome {
            expect(action == .mic && app.id == "google_meet", "Chrome window titled 'Meet - Weekly Standup' should match Google Meet")
            expect(targetShortcut == ShortcutSpec(key: "d", modifiers: [.command]), "Google Meet mic shortcut should be Cmd+D")
        } else {
            failures.append("Expected .remap for Google Meet window in Chrome")
        }

        // 6. Synthetic event tag 0x544C4258 prevents infinite tap recursion
        let taggedEvent = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: CallShortcutRemapper.syntheticEventTag,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeCallAppOnly,
            mappings: mappings,
            frontmostBundleID: "com.microsoft.teams2",
            frontmostPID: 202,
            frontmostWindowTitle: "Microsoft Teams",
            runningApps: []
        )
        expect(taggedEvent == .passThrough, "Synthetic event carrying 0x544C4258 tag must always passThrough")

        // 7. Everywhere scope toggles hardware mic when no call app runs, relays to FaceTime when running, and syncs on same-key Slack
        let everywhereNoCall = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .everywhere,
            mappings: mappings,
            frontmostBundleID: "com.apple.finder",
            frontmostPID: 501,
            frontmostWindowTitle: "Finder",
            runningApps: []
        )
        expect(everywhereNoCall == .globalHardwareOnly(action: .mic), "Everywhere scope without call app must return globalHardwareOnly(.mic)")

        let everywhereFaceTime = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .everywhere,
            mappings: mappings,
            frontmostBundleID: "com.apple.finder",
            frontmostPID: 501,
            frontmostWindowTitle: "Finder",
            runningApps: [RunningCallAppSnapshot(bundleIdentifier: "com.apple.FaceTime", pid: 601, windowTitles: ["FaceTime"])]
        )
        if case .remap(let action, let app, let pid, let targetShortcut, let focusRestore) = everywhereFaceTime {
            expect(action == .mic && app.id == "facetime" && pid == 601, "Everywhere scope should match running FaceTime in background")
            expect(targetShortcut == ShortcutSpec(key: "m", modifiers: [.command, .shift]), "FaceTime mic shortcut should be Cmd+Shift+M")
            expect(focusRestore, "FaceTime preset should allow fallback focus restore when needed")
        } else {
            failures.append("Expected .remap for running FaceTime in everywhere scope")
        }

        let everywhereSlackSame = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .everywhere,
            mappings: mappings,
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            frontmostPID: 101,
            frontmostWindowTitle: "Slack",
            runningApps: []
        )
        expect(everywhereSlackSame == .passThroughWithHardwareSync(action: .mic), "Everywhere scope with matching Slack native key must passThroughWithHardwareSync")

        expect(
            CallShortcutRemapper.axMenuModifiersMatch(1, expected: [.command, .shift]),
            "AX menu modifier 1 must match Command+Shift"
        )
        expect(
            CallShortcutRemapper.axMenuModifiersMatch(0, expected: [.command]),
            "AX menu modifier 0 must match Command only"
        )
        expect(
            !CallShortcutRemapper.axMenuModifiersMatch(8, expected: [.command]),
            "AX menu modifier 8 (kMenuNoCommandModifier) must not match Command"
        )

        // Menu control extraction & classification used by Add Call App auto-scan
        let parsedMic = CallShortcutRemapper.shortcutFromMenuItem(cmdChar: "M", virtualKey: nil, axMods: 1)
        expect(parsedMic == ShortcutSpec(key: "m", modifiers: [.command, .shift]), "AX menu item 'M' + mods 1 must parse to Cmd+Shift+M")

        let parsedVirtualSpace = CallShortcutRemapper.shortcutFromMenuItem(cmdChar: nil, virtualKey: 49, axMods: 1)
        expect(parsedVirtualSpace == ShortcutSpec(key: "space", modifiers: [.command, .shift]), "AX menu item virtualKey 49 + mods 1 must parse to Cmd+Shift+Space")

        expect(
            CallShortcutRemapper.classifyControlKind(title: "Mute Audio", menuPath: "Meeting > Mute Audio")?.kind == .mic,
            "'Mute Audio' should classify as .mic"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Start Video", menuPath: "Meeting > Start Video")?.kind == .video,
            "'Start Video' should classify as .video"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Quit App", menuPath: "File > Quit App") == nil,
            "Unrelated menu item 'Quit App' should not classify as mic or video"
        )

        // Verify PointerCursorNSView separates .cursorUpdate from .activeAlways (illegal AppKit combination)
        let pointerView = PointerCursorNSView()
        pointerView.frame = NSRect(x: 0, y: 0, width: 80, height: 28)
        pointerView.updateTrackingAreas()
        let initialTrackingAreas = pointerView.trackingAreas
        expect(initialTrackingAreas.count == 2, "PointerCursorNSView should install 2 distinct tracking areas (found \(initialTrackingAreas.count))")
        for area in initialTrackingAreas {
            let hasIllegalCombo = area.options.contains(.cursorUpdate) && area.options.contains(.activeAlways)
            expect(!hasIllegalCombo, "PointerCursorNSView must never combine .cursorUpdate with .activeAlways")
        }
        pointerView.updateTrackingAreas()
        expect(
            pointerView.trackingAreas.count == 2
                && pointerView.trackingAreas[0] === initialTrackingAreas[0]
                && pointerView.trackingAreas[1] === initialTrackingAreas[1],
            "PointerCursorNSView.updateTrackingAreas() must retain existing .inVisibleRect tracking areas rather than recreating them on every layout pass"
        )
    }

    private static func testCallControlsTypingMicStateMachine() {
        var sm = TypingMicStateMachine(isManuallyMuted: false, isTypingMuted: false, unmuteDelayMs: 450)
        expect(sm.unmuteDelaySeconds == 0.45, "Typing unmute delay should convert 450ms to 0.45s")

        // 1. Typing starts -> mute & schedule unmute; subsequent keys reschedule
        expect(sm.handleFilteredKeystroke() == .muteAndScheduleUnmute, "First keystroke should mute and schedule unmute")
        expect(sm.isTypingMuted, "isTypingMuted should become true")
        expect(sm.handleFilteredKeystroke() == .rescheduleUnmute, "Second keystroke should reschedule unmute")
        expect(sm.handleUnmuteTimerFired(), "Unmute timer firing should unmute when not manually muted")
        expect(!sm.isTypingMuted, "isTypingMuted should clear after unmute timer fires")

        // 2. Manual mute precedence: typing must NEVER unmute a manually muted mic
        _ = sm.setManualMute(true)
        expect(sm.isManuallyMuted && !sm.isTypingMuted, "setManualMute(true) must mark manual mute and clear typing mute")
        expect(sm.handleFilteredKeystroke() == .none, "Keystrokes while manually muted must return .none")
        expect(!sm.handleUnmuteTimerFired(), "Timer firing while manually muted must never unmute")

        // 3. Manual unmute clears manual mute cleanly
        _ = sm.setManualMute(false)
        expect(!sm.isManuallyMuted && !sm.isTypingMuted, "setManualMute(false) should clear manual mute")

        // 4. forceStopAndRestore forces unmute if typing-muted
        expect(sm.handleFilteredKeystroke() == .muteAndScheduleUnmute, "Keystroke after unmute should engage typing mute")
        expect(sm.forceStopAndRestore(), "forceStopAndRestore must return true while typing-muted")
        expect(!sm.isTypingMuted, "forceStopAndRestore must clear isTypingMuted")

        // 5. Keystroke filtering: Command/Control chords, call shortcuts, and synthetic tag are ignored
        let micShortcut = ShortcutSpec(key: "m", modifiers: [.option, .shift])
        let mCode = UInt16(micShortcut.carbonKeyCode ?? 46)
        expect(
            TypingMicStateMachine.shouldIgnoreKeystroke(keyCode: 0, flags: .maskCommand, eventUserData: 0, ignoredShortcuts: [micShortcut]),
            "Command chord must be ignored by typing detector"
        )
        expect(
            TypingMicStateMachine.shouldIgnoreKeystroke(keyCode: 0, flags: .maskControl, eventUserData: 0, ignoredShortcuts: [micShortcut]),
            "Control chord must be ignored by typing detector"
        )
        expect(
            TypingMicStateMachine.shouldIgnoreKeystroke(keyCode: 0, flags: [], eventUserData: CallShortcutRemapper.syntheticEventTag, ignoredShortcuts: []),
            "Synthetic 0x544C4258 event must be ignored by typing detector"
        )
        expect(
            TypingMicStateMachine.shouldIgnoreKeystroke(keyCode: mCode, flags: [.maskAlternate, .maskShift], eventUserData: 0, ignoredShortcuts: [micShortcut]),
            "Configured call shortcut must be ignored by typing detector"
        )
        expect(
            !TypingMicStateMachine.shouldIgnoreKeystroke(keyCode: 0, flags: [], eventUserData: 0, ignoredShortcuts: [micShortcut]),
            "Plain typing keystroke 'A' must not be ignored"
        )
    }

    private static func testCallControlsHotKeyConflictsAndLifecycle() {
        let manager = HotKeyManager.shared
        var cfg = ToolboxConfig()
        cfg.callControls.enabled = true
        cfg.clipboard.enabled = true
        cfg.callControls.osMuteShortcut = cfg.clipboard.shortcut

        let conflict = manager.inAppConflictDescription(
            for: cfg.callControls.osMuteShortcut,
            excludingSourceID: "call_controls.os_mute",
            in: cfg
        )
        expect(conflict != nil, "HotKeyManager should detect collision between call_controls.os_mute and Clipboard")

        manager.clearConflictingShortcuts(
            matching: cfg.callControls.osMuteShortcut,
            excludingSourceID: "call_controls.os_mute",
            in: &cfg
        )
        expect(cfg.clipboard.shortcut.isEmpty, "clearConflictingShortcuts should clear colliding Clipboard shortcut")
        expect(!cfg.callControls.osMuteShortcut.isEmpty, "clearConflictingShortcuts must preserve excluded call_controls.os_mute")

        // Slack's Cmd+Shift+Space should not be falsely flagged via internal macOS hotkey slot 232
        let slackStyle = ShortcutSpec(key: "space", modifiers: [.command, .shift])
        let sysConflictOnSlack = manager.systemOrMenuConflictDescription(for: slackStyle)
        expect(
            sysConflictOnSlack == nil,
            "Cmd+Shift+Space should not trigger a false-positive macOS system shortcut conflict unless explicitly configured by user (got: \(sysConflictOnSlack ?? "nil"))"
        )

        // Call Controls mic vs video collision check
        let shared = ShortcutSpec(key: "v", modifiers: [.command, .shift])
        cfg.callControls.micShortcut = shared
        cfg.callControls.videoShortcut = shared
        expect(
            manager.inAppConflictDescription(for: shared, excludingSourceID: "call_controls.video", in: cfg) != nil,
            "HotKeyManager should detect call_controls.mic vs call_controls.video collision"
        )
        manager.clearConflictingShortcuts(matching: shared, excludingSourceID: "call_controls.video", in: &cfg)
        expect(cfg.callControls.micShortcut.isEmpty, "clearConflictingShortcuts should clear colliding call_controls.mic shortcut")

        // Module lifecycle & deterministic statusText
        let callModule = ModuleRegistry.shared.callControls
        expect(ModuleRegistry.shared.module(withID: "call_controls") === callModule, "Registry must resolve call_controls")

        var statusCfg = ToolboxConfig()
        expect(callModule.statusText(in: statusCfg, accessibilityGranted: true) == "Disabled", "Disabled statusText mismatch")
        statusCfg.callControls.enabled = true
        statusCfg.general.appEnabled = false
        expect(callModule.statusText(in: statusCfg, accessibilityGranted: true) == "Paused", "Paused statusText mismatch")

        statusCfg.general.appEnabled = true
        statusCfg.callControls.micShortcut = ShortcutSpec(key: "space", modifiers: [.command, .shift])
        expect(
            callModule.statusText(in: statusCfg, accessibilityGranted: false) == "Needs Accessibility",
            "Should report Needs Accessibility when unified keybind is set without permission"
        )

        let defaultCC = CallControlsConfig()
        expect(
            defaultCC.micShortcut == ShortcutSpec(key: "m", modifiers: [.control, .option, .command]),
            "Default CallControls micShortcut should be Ctrl+Option+Cmd+M"
        )
        expect(
            defaultCC.videoShortcut == ShortcutSpec(key: "v", modifiers: [.control, .option, .command]),
            "Default CallControls videoShortcut should be Ctrl+Option+Cmd+V"
        )

        let videoCapableSummary = CallControlsModule.videoCapableAppsSummary(from: CallAppShortcutMapping.defaults)
        expect(
            videoCapableSummary == "Teams, Zoom, or Meet",
            "Default video-capable summary should list Teams, Zoom, or Meet (got: \(videoCapableSummary))"
        )
        expect(
            CallControlsModule.videoUnavailableMessage(
                frontUnsupportedAppName: "FaceTime",
                anyUnsupportedAppName: "FaceTime",
                backgroundCapableAppName: nil,
                overrideScope: .everywhere,
                videoCapableSummary: videoCapableSummary
            ) == "FaceTime doesn't allow video shortcuts (macOS has no OS camera mute)",
            "Frontmost FaceTime video-unavailable toast should explain FaceTime doesn't allow video shortcuts"
        )
        expect(
            CallControlsModule.videoUnavailableMessage(
                frontUnsupportedAppName: nil,
                anyUnsupportedAppName: nil,
                backgroundCapableAppName: "Zoom",
                overrideScope: .activeCallAppOnly,
                videoCapableSummary: videoCapableSummary
            ) == "Focus Zoom or switch scope to Everywhere to toggle camera",
            "Active-app-only scope with background Zoom should prompt user to focus Zoom or change scope"
        )
        expect(
            CallControlsModule.videoUnavailableMessage(
                frontUnsupportedAppName: nil,
                anyUnsupportedAppName: nil,
                backgroundCapableAppName: nil,
                overrideScope: .everywhere,
                videoCapableSummary: videoCapableSummary
            ) == "Open Teams, Zoom, or Meet to toggle camera (macOS has no OS camera mute)",
            "Idle video-unavailable toast should accurately reflect enabled video-capable presets"
        )

        statusCfg.callControls.micShortcut = .none
        statusCfg.callControls.autoMuteWhileTyping = false
        callModule.reload(with: statusCfg)
        expect(callModule.isRunning, "CallControlsModule should start when enabled without requiring Accessibility for CoreAudio controls")
        callModule.stop()
        expect(!callModule.isRunning, "CallControlsModule.stop() must clear isRunning")
        expect(!callModule.isRemapperTapInstalled && !callModule.isTypingTapInstalled, "CallControlsModule.stop() must uninstall event taps")
    }

    private static func testCallControlsDeveloperSimulation() {
        let callModule = ModuleRegistry.shared.callControls
        let devManager = DeveloperModeManager.shared

        callModule.clearDeveloperSimulation()
        expect(!devManager.hasActiveSimulation, "hasActiveSimulation should be false initially")

        // 1. Zoom frontmost call preset + dry-run + interactive action simulation
        callModule.applyDeveloperSimulationPreset(.zoomCall)
        expect(callModule.developerSimulation != nil, "applyDeveloperSimulationPreset(.zoomCall) must populate developerSimulation")
        expect(devManager.hasActiveSimulation, "DeveloperModeManager.hasActiveSimulation must reflect active Call Controls simulation")

        var simConfig = CallControlsConfig()
        simConfig.enabled = true
        simConfig.overrideScope = .everywhere
        let micDecision = callModule.simulatedRoutingDecision(for: .mic, using: simConfig)
        if case .remap(let action, let targetApp, _, _, _) = micDecision {
            expect(action == .mic && targetApp.id == "zoom", "Simulated Zoom mic decision should remap to zoom")
        } else {
            failures.append("Simulated Zoom mic decision should return .remap (got: \(micDecision))")
        }
        let videoDecision = callModule.simulatedRoutingDecision(for: .video, using: simConfig)
        if case .remap(let action, let targetApp, _, _, _) = videoDecision {
            expect(action == .video && targetApp.id == "zoom", "Simulated Zoom video decision should remap to zoom")
        } else {
            failures.append("Simulated Zoom video decision should return .remap (got: \(videoDecision))")
        }

        let floatingState = FloatingMicIndicatorState()
        callModule.populateFloatingState(floatingState)
        expect(floatingState.hasInputDevice && !floatingState.isMuted, "Zoom preset should report live unmuted mic in FloatingMicIndicatorState")
        expect(floatingState.isCameraActive && floatingState.canToggleVideo, "Zoom preset should report live toggleable camera in FloatingMicIndicatorState")

        callModule.triggerSimulatedAction(.mic)
        expect(callModule.developerSimulation?.isMuted == true, "triggerSimulatedAction(.mic) should toggle simulated isMuted to true")
        callModule.triggerSimulatedAction(.video)
        expect(callModule.developerSimulation?.isCameraActive == false, "triggerSimulatedAction(.video) should toggle simulated isCameraActive to false")

        // 1b. Simulation dry-run parity: unbound keybind returns .passThrough unless fallback is requested, and respects Accessibility simulation & disabled apps
        var unboundConfig = simConfig
        unboundConfig.micShortcut = .none
        expect(
            callModule.simulatedRoutingDecision(for: .mic, using: unboundConfig, fallbackToDefaultIfUnbound: false) == .passThrough,
            "Unbound mic shortcut must report .passThrough in routing dry-run"
        )
        if case .remap(let action, let app, _, _, _) = callModule.simulatedRoutingDecision(for: .mic, using: unboundConfig, fallbackToDefaultIfUnbound: true) {
            expect(action == .mic && app.id == "zoom", "Fallback-enabled mic test should resolve to zoom")
        } else {
            failures.append("Fallback-enabled mic test should return .remap")
        }

        var disabledZoomCfg = simConfig
        if let idx = disabledZoomCfg.appShortcutMappings.firstIndex(where: { $0.id == "zoom" }) {
            disabledZoomCfg.appShortcutMappings[idx].enabled = false
        }
        expect(
            callModule.simulatedRoutingDecision(for: .video, using: disabledZoomCfg) == .globalHardwareOnly(action: .video),
            "Disabling Zoom mapping should surface Video Blocked in simulation dry-run"
        )

        if let sim = callModule.developerSimulation {
            let ctx = CallControlsModule.buildSimulatedContext(sim: sim, config: simConfig)
            let micCode = UInt16(simConfig.micShortcut.carbonKeyCode ?? 46)
            let tapDecision = CallShortcutRemapper.resolveDecision(
                keyCode: micCode,
                modifiers: simConfig.micShortcut.modifiers,
                eventUserData: 0,
                micShortcut: simConfig.micShortcut,
                videoShortcut: simConfig.videoShortcut,
                overrideScope: simConfig.overrideScope,
                mappings: simConfig.appShortcutMappings,
                frontmostBundleID: ctx.frontmostBundleID,
                frontmostPID: ctx.frontmostPID,
                frontmostWindowTitle: ctx.frontmostWindowTitle,
                runningApps: ctx.runningApps
            )
            expect(
                tapDecision == callModule.simulatedRoutingDecision(for: .mic, using: simConfig),
                "Simulated tap context resolution must match simulatedRoutingDecision identically"
            )
        }

        // Simulated Accessibility = false blocks keybind actions, while pill mic click still toggles hardware mic
        callModule.developerSimulation?.isMuted = false
        callModule.developerSimulation?.simulateAccessibilityGranted = false
        callModule.triggerSimulatedAction(.mic, fallbackToDefaultIfUnbound: true, respectSimulatedAccessibility: true)
        expect(
            callModule.developerSimulation?.isMuted == false,
            "Keybind simulation must be blocked when simulateAccessibilityGranted == false"
        )
        callModule.toggleSimulatedMicFromPill()
        expect(
            callModule.developerSimulation?.isMuted == true,
            "Pill mic click must still toggle mic even when simulateAccessibilityGranted == false"
        )

        // reload(with: disabled) must preserve active developer simulation
        var disabledModuleCfg = ToolboxConfig()
        disabledModuleCfg.callControls.enabled = false
        callModule.reload(with: disabledModuleCfg)
        expect(callModule.developerSimulation != nil, "reload(with: disabled) must preserve active developerSimulation")

        // 2. FaceTime call preset must report video unavailable rather than toggling video
        callModule.applyDeveloperSimulationPreset(.faceTimeCall)
        let ftVideoDecision = callModule.simulatedRoutingDecision(for: .video, using: simConfig)
        expect(ftVideoDecision == .globalHardwareOnly(action: .video), "Simulated FaceTime video decision must fall back to .globalHardwareOnly(action: .video) (got: \(ftVideoDecision))")
        callModule.triggerSimulatedAction(.video)
        expect(
            callModule.lastSimulationOutcome?.contains("FaceTime") == true,
            "Simulated FaceTime video action outcome should mention FaceTime (got: \(callModule.lastSimulationOutcome ?? "nil"))"
        )

        // 3. Floating pill top-right frame stability when toggling Mic / Camera
        let testScreenFrame = NSRect(x: 0, y: 0, width: 1512, height: 950)
        for deviceName in ["AirPods", "MacBook Pro Microphone"] {
            let pillState = FloatingMicIndicatorState()
            pillState.inputDeviceName = deviceName
            pillState.showVideoStatus = true
            pillState.hasCameraDevice = true
            pillState.canToggleVideo = true
            pillState.videoTargetAppName = "Zoom"
            pillState.cameraDeviceName = "FaceTime HD"
            pillState.isCameraActive = true
            pillState.isMuted = false
            pillState.isTypingMuted = false

            let liveSize = FloatingMicIndicatorPanel.measuredPillSize(for: pillState)
            expect(liveSize.width > 280 && liveSize.height == 44, "Dual Mic+Video pill should measure full natural width & 44pt height (got: \(liveSize))")
            let liveFrame = FloatingMicIndicatorPanel.defaultTopRightFrame(for: liveSize, inVisibleFrame: testScreenFrame)

            pillState.isMuted = true
            let mutedSize = FloatingMicIndicatorPanel.measuredPillSize(for: pillState)
            let mutedFrame = FloatingMicIndicatorPanel.defaultTopRightFrame(for: mutedSize, inVisibleFrame: testScreenFrame)

            pillState.isTypingMuted = true
            let typingSize = FloatingMicIndicatorPanel.measuredPillSize(for: pillState)
            let typingFrame = FloatingMicIndicatorPanel.defaultTopRightFrame(for: typingSize, inVisibleFrame: testScreenFrame)

            expect(
                liveFrame == mutedFrame && liveFrame == typingFrame,
                "Top-right floating pill must not move or resize when toggling mute for '\(deviceName)' (live: \(liveFrame), muted: \(mutedFrame), typing: \(typingFrame))"
            )

            pillState.isTypingMuted = false
            pillState.isMuted = false
            pillState.isCameraActive = false
            pillState.videoTargetAppName = "Microsoft Teams"
            let camOffSize = FloatingMicIndicatorPanel.measuredPillSize(for: pillState)
            let camOffFrame = FloatingMicIndicatorPanel.defaultTopRightFrame(for: camOffSize, inVisibleFrame: testScreenFrame)
            expect(
                liveFrame == camOffFrame,
                "Top-right floating pill must not move or resize when toggling camera for '\(deviceName)' even with long app name (live: \(liveFrame), camOff: \(camOffFrame))"
            )

            pillState.showVideoStatus = false
            let micOnlySize = FloatingMicIndicatorPanel.measuredPillSize(for: pillState)
            expect(micOnlySize.width > 160 && micOnlySize.width < liveSize.width - 60, "Mic-only pill should shrink cleanly when video is hidden (got: \(micOnlySize))")
        }

        // 3b. Real FloatingMicIndicatorPanel: initial position == resetToDefaultPosition() and zero shift at very-most top-right
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let panel = FloatingMicIndicatorPanel(userDefaults: nil)
            panel.update(
                isMuted: false,
                isTypingMuted: false,
                inputDeviceName: "MacBook Pro Microphone",
                hasInputDevice: true,
                showVideoStatus: true,
                isCameraActive: true,
                cameraDeviceName: "FaceTime HD",
                hasCameraDevice: true,
                canToggleVideo: true,
                videoTargetAppName: "Microsoft Teams"
            )
            panel.show()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let initialFrame = panel.currentFrame

            let customDraggedOrigin = NSPoint(x: screen.visibleFrame.minX + 120, y: screen.visibleFrame.minY + 120)
            if let f = initialFrame {
                panel.recordDraggedFrameForTesting(NSRect(origin: customDraggedOrigin, size: f.size))
                panel.resetToDefaultPosition()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                expect(
                    panel.currentFrame == initialFrame,
                    "Floating pill resetToDefaultPosition() must match initial position identically (initial: \(String(describing: initialFrame)), reset: \(String(describing: panel.currentFrame)))"
                )

                // Move to very-most top-right (screenPadding = 6pt) and toggle Mic & Video
                let pad = FloatingMicIndicatorPanel.screenPadding
                let cornerFrame = NSRect(
                    x: round(screen.visibleFrame.maxX - f.size.width - pad),
                    y: round(screen.visibleFrame.maxY - f.size.height - pad),
                    width: f.size.width,
                    height: f.size.height
                )
                panel.recordDraggedFrameForTesting(cornerFrame)
                panel.update(
                    isMuted: true,
                    isTypingMuted: false,
                    inputDeviceName: "MacBook Pro Microphone",
                    hasInputDevice: true,
                    showVideoStatus: true,
                    isCameraActive: false,
                    cameraDeviceName: "FaceTime HD",
                    hasCameraDevice: true,
                    canToggleVideo: true,
                    videoTargetAppName: "Microsoft Teams"
                )
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                expect(
                    panel.currentFrame == cornerFrame,
                    "Pill dragged to very-most top-right must not shift when toggling Mic/Video (expected: \(cornerFrame), got: \(String(describing: panel.currentFrame)))"
                )
            } else {
                failures.append("FloatingMicIndicatorPanel.show() did not produce a valid frame")
            }
            panel.hide()

            // Regression test: clicking/hiding the pill while PointerCursorNSView deferred cursor sync
            // timers (RunLoop.main.perform, 0.04s, 0.2s) are pending must not crash on closed NSPanel.
            var hideCallbackInvoked = false
            panel.onHidePill = {
                hideCallbackInvoked = true
                panel.hide()
            }
            panel.show()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if let f = panel.currentFrame {
                let center = NSPoint(x: f.width - 12, y: f.height / 2)
                let downEvent = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: center,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0,
                    context: nil,
                    eventNumber: 1,
                    clickCount: 1,
                    pressure: 1.0
                )
                let upEvent = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: center,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0,
                    context: nil,
                    eventNumber: 1,
                    clickCount: 1,
                    pressure: 0.0
                )
                if let downEvent { NSApp.postEvent(downEvent, atStart: false) }
                if let upEvent { NSApp.postEvent(upEvent, atStart: false) }
            }
            panel.onHidePill?()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            expect(hideCallbackInvoked, "Floating pill onHidePill callback must execute cleanly")
            expect(panel.currentFrame == nil, "Floating pill currentFrame must be nil after onHidePill -> hide()")
        }

        // 3c. New simulation presets, simulated scope override, device profile, and pill hide override
        callModule.applyDeveloperSimulationPreset(.teamsBackground)
        callModule.developerSimulation?.simulatedScopeOverride = .activeCallAppOnly
        expect(
            callModule.simulatedRoutingDecision(for: .mic, using: simConfig) == .passThrough,
            "simulatedScopeOverride = .activeCallAppOnly must override saved .everywhere scope for background Teams"
        )
        callModule.applyDeveloperSimulationPreset(.discordCall)
        expect(callModule.developerSimulation?.targetAppID == "discord", "Discord preset should target discord")
        callModule.applyDeveloperSimulationPreset(.noCallApp)
        expect(callModule.developerSimulation?.targetAppID == "none", "No Call App preset should target none")
        callModule.developerSimulation?.deviceProfile = .noHardware
        callModule.toggleSimulatedMicFromPill()
        expect(
            callModule.lastSimulationOutcome?.contains("No input microphone") == true,
            "No-hardware profile pill toggle must report missing microphone"
        )
        callModule.developerSimulation?.pillVisibilityMode = .forceHide
        expect(!callModule.isFloatingPillVisible, "pillVisibilityMode = .forceHide must hide desktop pill even if streams were active")

        // 4. DeveloperModeManager.resetAllSimulations() clears Call Controls simulation cleanly
        devManager.resetAllSimulations()
        expect(callModule.developerSimulation == nil, "resetAllSimulations() must clear CallControlsModule.developerSimulation")
        expect(!callModule.isRemapperTapInstalled, "resetAllSimulations() must uninstall simulation event tap when module is off")
        expect(!devManager.hasActiveSimulation, "hasActiveSimulation must be false after resetAllSimulations()")

        // 5. ToolboxConfigSection.callControls & pure ConfigCheckpointStore diff detection
        expect(ToolboxConfigSection.allCases.contains(.callControls), "ToolboxConfigSection must include .callControls")
        let checkpointCfg = ToolboxConfig()
        var modifiedCfg = checkpointCfg
        modifiedCfg.callControls.typingUnmuteDelayMs = 900
        let diffs = ConfigCheckpointStore.diff(from: checkpointCfg, to: modifiedCfg)
        expect(
            diffs == [ConfigDiffItem(keyPath: "callControls.typingUnmuteDelayMs", baselineValue: "450", currentValue: "900")],
            "ConfigCheckpointStore.diff should detect callControls changes cleanly (got: \(diffs))"
        )
        DeveloperEventLog.shared.clear()
    }


    private static func testCallControlsBluetoothMicLock() {
        func makeDevice(
            _ uid: String,
            _ name: String,
            _ transport: AudioTransportType,
            hasInput: Bool = true,
            hasOutput: Bool = false,
            isDefaultInput: Bool = false
        ) -> AudioDeviceInfo {
            AudioDeviceInfo(
                deviceID: AudioDeviceID(abs(uid.hashValue % 4096) + 1),
                uid: uid,
                name: name,
                transport: transport,
                inputChannelCount: hasInput ? 1 : 0,
                outputChannelCount: hasOutput ? 2 : 0,
                isDefaultInput: isDefaultInput,
                isDefaultOutput: false,
                isInputMuted: false,
                isOutputMuted: false,
                inputVolumeScalar: hasInput ? 0.8 : nil,
                outputVolumeScalar: hasOutput ? 0.8 : nil,
                supportsHardwareInputMute: true
            )
        }

        let airpods = makeDevice("bt-airpods", "AirPods Pro", .bluetooth, hasOutput: true)
        let usbMic = makeDevice("usb-yeti", "Blue Yeti", .usb)
        let builtInMic = makeDevice("builtin-mic", "MacBook Pro Microphone", .builtIn)
        let loopback = makeDevice("virtual-loopback", "Loopback Audio", .virtual)

        // 1. Pure policy: preferred fallback wins over everything else.
        expect(
            BluetoothMicLockPolicy.resolveRevertTarget(
                currentDefaultInput: airpods,
                availableInputs: [airpods, builtInMic, usbMic],
                preferredFallbackUID: "builtin-mic",
                lastNonBluetoothUID: "usb-yeti",
                bypassedBluetoothUID: nil
            )?.uid == "builtin-mic",
            "Preferred fallback must win over last-used and USB priority"
        )

        // 2. Unplugged preferred USB mic falls back to the last known non-Bluetooth default.
        expect(
            BluetoothMicLockPolicy.resolveRevertTarget(
                currentDefaultInput: airpods,
                availableInputs: [airpods, builtInMic],
                preferredFallbackUID: "usb-yeti",
                lastNonBluetoothUID: "builtin-mic",
                bypassedBluetoothUID: nil
            )?.uid == "builtin-mic",
            "Unplugged preferred fallback must fall through to the last known non-Bluetooth mic"
        )

        // 3. Auto priority: USB before built-in when nothing is preferred or remembered.
        expect(
            BluetoothMicLockPolicy.resolveRevertTarget(
                currentDefaultInput: airpods,
                availableInputs: [airpods, builtInMic, usbMic],
                preferredFallbackUID: nil,
                lastNonBluetoothUID: nil,
                bypassedBluetoothUID: nil
            )?.uid == "usb-yeti",
            "Auto fallback must prefer a USB microphone over the built-in mic"
        )
        expect(
            BluetoothMicLockPolicy.resolveRevertTarget(
                currentDefaultInput: airpods,
                availableInputs: [airpods, builtInMic],
                preferredFallbackUID: nil,
                lastNonBluetoothUID: nil,
                bypassedBluetoothUID: nil
            )?.uid == "builtin-mic",
            "Auto fallback must use the built-in mic when no USB mic exists"
        )

        // 4. Never leave the user without a microphone (Mac mini / Mac Studio with only AirPods).
        expect(
            BluetoothMicLockPolicy.resolveRevertTarget(
                currentDefaultInput: airpods,
                availableInputs: [airpods],
                preferredFallbackUID: nil,
                lastNonBluetoothUID: nil,
                bypassedBluetoothUID: nil
            ) == nil,
            "Policy must return nil when the Bluetooth headset is the only microphone"
        )

        // 5. Non-Bluetooth default never triggers a revert.
        expect(
            BluetoothMicLockPolicy.resolveRevertTarget(
                currentDefaultInput: builtInMic,
                availableInputs: [airpods, builtInMic],
                preferredFallbackUID: nil,
                lastNonBluetoothUID: nil,
                bypassedBluetoothUID: nil
            ) == nil,
            "Policy must not revert when the default input is already a wired mic"
        )

        // 6. Temporary bypass suppresses the revert for that device only.
        expect(
            BluetoothMicLockPolicy.resolveRevertTarget(
                currentDefaultInput: airpods,
                availableInputs: [airpods, builtInMic, usbMic],
                preferredFallbackUID: nil,
                lastNonBluetoothUID: nil,
                bypassedBluetoothUID: "bt-airpods"
            ) == nil,
            "Bypassed Bluetooth UID must suppress the revert"
        )

        // 7. Virtual / aggregate devices are avoided unless nothing else exists.
        expect(
            BluetoothMicLockPolicy.fallbackCandidates(from: [airpods, builtInMic, loopback]).map(\.uid) == ["builtin-mic"],
            "Fallback candidates must exclude virtual devices when a physical mic exists"
        )
        expect(
            BluetoothMicLockPolicy.fallbackCandidates(from: [airpods, loopback]).map(\.uid) == ["virtual-loopback"],
            "Fallback candidates must allow virtual devices when nothing physical remains"
        )

        // 7b. Pinned-app detection: an app that opens the Bluetooth mic itself defeats the guard.
        let zoomCapture = ProcessInputCapture(
            pid: 4242,
            bundleID: "us.zoom.xos",
            deviceIDs: [airpods.deviceID]
        )
        let meetCapture = ProcessInputCapture(
            pid: 4343,
            bundleID: "com.google.Chrome",
            deviceIDs: [builtInMic.deviceID]
        )
        expect(
            BluetoothMicLockPolicy.pinnedBluetoothMicBundleIDs(
                captures: [zoomCapture],
                devices: [airpods, builtInMic],
                defaultInputUID: "builtin-mic"
            ) == ["us.zoom.xos"],
            "An app capturing the Bluetooth mic while the default is a wired mic must be reported as pinned"
        )
        expect(
            BluetoothMicLockPolicy.pinnedBluetoothMicBundleIDs(
                captures: [meetCapture],
                devices: [airpods, builtInMic],
                defaultInputUID: "builtin-mic"
            ).isEmpty,
            "An app capturing the fallback mic must not be reported as pinned"
        )
        expect(
            BluetoothMicLockPolicy.pinnedBluetoothMicBundleIDs(
                captures: [zoomCapture],
                devices: [airpods, builtInMic],
                defaultInputUID: "bt-airpods"
            ).isEmpty,
            "Capturing the Bluetooth mic that IS the system default is expected, not pinned"
        )
        expect(
            BluetoothMicLockPolicy.pinnedBluetoothMicBundleIDs(
                captures: [ProcessInputCapture(pid: 1, bundleID: nil, deviceIDs: [airpods.deviceID])],
                devices: [airpods, builtInMic],
                defaultInputUID: "builtin-mic"
            ).isEmpty,
            "Captures without a bundle ID must be ignored (nothing actionable to report)"
        )
        expect(
            BluetoothMicLockPolicy.pinnedBluetoothMicBundleIDs(
                captures: [
                    zoomCapture,
                    ProcessInputCapture(pid: 4444, bundleID: "us.zoom.xos", deviceIDs: [airpods.deviceID])
                ],
                devices: [airpods, builtInMic],
                defaultInputUID: "builtin-mic"
            ) == ["us.zoom.xos"],
            "Pinned bundle IDs must be deduplicated"
        )
        expect(
            BluetoothMicLockPolicy.pinnedBluetoothMicBundleIDs(
                captures: [zoomCapture],
                devices: [builtInMic, usbMic],
                defaultInputUID: "builtin-mic"
            ).isEmpty,
            "No connected Bluetooth input means nothing can be pinned to it"
        )
        expect(
            zoomCapture.isCapturing(anyDeviceIn: [airpods.deviceID]),
            "ProcessInputCapture.isCapturing must match on shared device IDs"
        )
        expect(
            BluetoothMicLockPolicy.isActionableCaptureBundleID("us.zoom.xos")
                && BluetoothMicLockPolicy.isActionableCaptureBundleID("com.google.Chrome")
                && BluetoothMicLockPolicy.isActionableCaptureBundleID("com.apple.Safari"),
            "Real user-facing apps (Zoom, Chrome, Safari) must stay actionable"
        )
        expect(
            !BluetoothMicLockPolicy.isActionableCaptureBundleID("com.apple.Siri")
                && !BluetoothMicLockPolicy.isActionableCaptureBundleID("com.apple.CoreSpeech")
                && !BluetoothMicLockPolicy.isActionableCaptureBundleID("systemsoundserverd"),
            "Assistants and audio daemons must be excluded so the warning never cries wolf"
        )
        expect(
            BluetoothMicLockPolicy.pinnedBluetoothMicBundleIDs(
                captures: [
                    ProcessInputCapture(pid: 99, bundleID: "com.apple.Siri", deviceIDs: [airpods.deviceID]),
                    zoomCapture
                ],
                devices: [airpods, builtInMic],
                defaultInputUID: "builtin-mic"
            ) == ["us.zoom.xos"],
            "Siri opening the headset mic must not be reported, but Zoom must be"
        )

        // 7c. Manual device selection must not desynchronise the temporary override.
        expect(
            BluetoothMicLockPolicy.bypassActionAfterManualInputSelection(
                selectedUID: "bt-airpods", selectedIsBluetooth: true,
                switchSucceeded: true, guardEnabled: true, currentlyBypassed: false
            ) == .arm("bt-airpods"),
            "Picking a Bluetooth mic while the guard is on must arm the override"
        )
        expect(
            BluetoothMicLockPolicy.bypassActionAfterManualInputSelection(
                selectedUID: "builtin-mic", selectedIsBluetooth: false,
                switchSucceeded: true, guardEnabled: true, currentlyBypassed: true
            ) == .clear,
            "Picking a wired mic while bypassed must clear the override (back to stereo)"
        )
        expect(
            BluetoothMicLockPolicy.bypassActionAfterManualInputSelection(
                selectedUID: "builtin-mic", selectedIsBluetooth: false,
                switchSucceeded: true, guardEnabled: true, currentlyBypassed: false
            ) == .unchanged,
            "Picking a wired mic with no override active must change nothing"
        )
        expect(
            BluetoothMicLockPolicy.bypassActionAfterManualInputSelection(
                selectedUID: "bt-airpods", selectedIsBluetooth: true,
                switchSucceeded: false, guardEnabled: true, currentlyBypassed: false
            ) == .unchanged,
            "A failed device switch must never arm the override"
        )
        expect(
            BluetoothMicLockPolicy.bypassActionAfterManualInputSelection(
                selectedUID: "bt-airpods", selectedIsBluetooth: true,
                switchSucceeded: true, guardEnabled: false, currentlyBypassed: false
            ) == .unchanged,
            "Selecting a Bluetooth mic with the guard off must not arm an override"
        )
        expect(
            BluetoothMicLockPolicy.bypassActionAfterManualInputSelection(
                selectedUID: "bt-airpods", selectedIsBluetooth: false,
                switchSucceeded: false, guardEnabled: true, currentlyBypassed: true
            ) == .unchanged,
            "A failed switch must leave an existing override untouched"
        )

        // 7d. The fallback picker must keep a valid selection when its saved mic is unplugged.
        expect(
            BluetoothMicLockPolicy.disconnectedFallbackUID("usb-yeti", available: [builtInMic]) == "usb-yeti",
            "A saved fallback UID that is no longer connected must be reported as disconnected"
        )
        expect(
            BluetoothMicLockPolicy.disconnectedFallbackUID("usb-yeti", available: [usbMic, builtInMic]) == nil,
            "A connected saved fallback UID must not be flagged"
        )
        expect(
            BluetoothMicLockPolicy.disconnectedFallbackUID(nil, available: [builtInMic]) == nil
                && BluetoothMicLockPolicy.disconnectedFallbackUID("", available: [builtInMic]) == nil,
            "Auto (nil/empty) fallback must never be flagged as disconnected"
        )

        // 8. Loop breaker: the 5th revert inside a 5 s window pauses auto-revert for 15 s.
        var breaker = BluetoothMicRevertLoopBreaker()
        for idx in 0..<BluetoothMicRevertLoopBreaker.maxRevertsPerWindow {
            expect(
                !breaker.registerRevert(at: 1000 + Double(idx) * 0.5),
                "Revert \(idx + 1) inside the window must not trip the loop breaker"
            )
        }
        expect(!breaker.isPaused(at: 1002.5), "Loop breaker must stay armed at 4 reverts")
        expect(
            breaker.registerRevert(at: 1002.6),
            "The 5th revert inside 5 s must trip the loop breaker"
        )
        expect(breaker.isPaused(at: 1003), "Loop breaker must pause immediately after tripping")
        expect(
            breaker.isPaused(at: 1002.6 + BluetoothMicRevertLoopBreaker.pauseSeconds - 0.5),
            "Loop breaker pause must last ~15 s"
        )
        expect(
            !breaker.isPaused(at: 1002.6 + BluetoothMicRevertLoopBreaker.pauseSeconds + 0.5),
            "Loop breaker must resume after the 15 s pause"
        )

        // 9. Controller end-to-end against a fake CoreAudio store.
        var fakeNow: TimeInterval = 5000
        var connected: [AudioDeviceInfo] = [airpods, usbMic, builtInMic]
        var defaultInputUID = "bt-airpods"
        var revertCount = 0
        var lastRevertPair: (String, String)?

        func fakeSnapshot() -> [AudioDeviceInfo] {
            connected.map { device in
                AudioDeviceInfo(
                    deviceID: device.deviceID,
                    uid: device.uid,
                    name: device.name,
                    transport: device.transport,
                    inputChannelCount: device.inputChannelCount,
                    outputChannelCount: device.outputChannelCount,
                    isDefaultInput: device.uid == defaultInputUID,
                    isDefaultOutput: false,
                    isInputMuted: false,
                    isOutputMuted: false,
                    inputVolumeScalar: device.inputVolumeScalar,
                    outputVolumeScalar: device.outputVolumeScalar,
                    supportsHardwareInputMute: true
                )
            }
        }

        let controller = BluetoothMicLockController(
            listDevices: { fakeSnapshot() },
            setDefaultInputDevice: { uid in
                guard connected.contains(where: { $0.uid == uid && $0.hasInput }) else { return false }
                defaultInputUID = uid
                return true
            },
            now: { fakeNow }
        )
        controller.onReverted = { from, to in
            revertCount += 1
            lastRevertPair = (from.name, to.name)
        }

        controller.configure(enabled: true, fallbackUID: "builtin-mic")
        var outcome = controller.evaluate()
        expect(outcome == .reverted(targetUID: "builtin-mic"), "Controller must revert a Bluetooth default to the preferred mic (got: \(outcome))")
        expect(defaultInputUID == "builtin-mic", "Controller must move the default input off the Bluetooth headset")
        expect(revertCount == 1 && lastRevertPair?.1 == "MacBook Pro Microphone", "Revert callback must report the new fallback mic")
        expect(controller.state.resolvedFallbackName == "MacBook Pro Microphone", "State must expose the resolved fallback microphone")

        // Temporary override until disconnect.
        defaultInputUID = "bt-airpods"
        controller.armBypass(bluetoothUID: "bt-airpods")
        outcome = controller.evaluate()
        expect(outcome == .suppressedByBypass(bluetoothUID: "bt-airpods"), "Bypass must suppress the revert (got: \(outcome))")
        expect(defaultInputUID == "bt-airpods", "Bypassed controller must leave the Bluetooth mic selected")
        expect(controller.state.isBluetoothMicBypassed, "State must report the temporary override")

        // Disconnecting the headset clears the override automatically.
        connected = [usbMic, builtInMic]
        controller.handleDevicesChanged()
        expect(!controller.state.isBluetoothMicBypassed, "Bypass must clear once the headset disconnects")
        connected = [airpods, usbMic, builtInMic]
        defaultInputUID = "usb-yeti"
        controller.configure(enabled: true, fallbackUID: nil)
        _ = controller.evaluate()
        expect(defaultInputUID == "usb-yeti", "Cleared bypass must leave a non-Bluetooth default untouched")

        // Rapid Bluetooth re-selection trips the loop breaker (and never thrashes CoreAudio).
        var loopDefaultUID = "bt-airpods"
        var loopReverts = 0
        let loopController = BluetoothMicLockController(
            listDevices: {
                [airpods, usbMic, builtInMic].map { device in
                    AudioDeviceInfo(
                        deviceID: device.deviceID,
                        uid: device.uid,
                        name: device.name,
                        transport: device.transport,
                        inputChannelCount: device.inputChannelCount,
                        outputChannelCount: device.outputChannelCount,
                        isDefaultInput: device.uid == loopDefaultUID,
                        isDefaultOutput: false,
                        isInputMuted: false,
                        isOutputMuted: false,
                        inputVolumeScalar: device.inputVolumeScalar,
                        outputVolumeScalar: device.outputVolumeScalar,
                        supportsHardwareInputMute: true
                    )
                }
            },
            setDefaultInputDevice: { uid in
                loopDefaultUID = uid
                return true
            },
            now: { fakeNow }
        )
        loopController.onReverted = { _, _ in loopReverts += 1 }
        loopController.configure(enabled: true, fallbackUID: "builtin-mic")

        var lastOutcome = BluetoothMicLockOutcome.idle
        for idx in 0..<5 {
            fakeNow = 6000 + Double(idx) * 0.2
            loopDefaultUID = "bt-airpods"
            lastOutcome = loopController.evaluate()
        }
        expect(lastOutcome == .reverted(targetUID: "builtin-mic"), "All five rapid reverts must still succeed (got: \(lastOutcome))")
        expect(loopReverts == 5, "Loop breaker test expected 5 reverts, got \(loopReverts)")

        fakeNow = 6001.0
        loopDefaultUID = "bt-airpods"
        expect(
            loopController.evaluate() == .suppressedByLoopBreaker(bluetoothUID: "bt-airpods"),
            "A 5th rapid Bluetooth switch must pause auto-revert instead of thrashing CoreAudio"
        )
        expect(loopDefaultUID == "bt-airpods", "Paused controller must stop writing the default input device")
        expect(loopController.state.isThrottled, "State must surface the loop-breaker warning")

        expect(
            loopController.hasPendingLoopBreakerRetry,
            "Tripping the loop breaker must schedule the promised automatic retry"
        )

        fakeNow = 6000.8 + BluetoothMicRevertLoopBreaker.pauseSeconds + 1
        loopDefaultUID = "bt-airpods"
        expect(
            loopController.evaluate() == .reverted(targetUID: "builtin-mic"),
            "Controller must resume reverting once the 15 s pause elapses"
        )
        expect(
            !loopController.hasPendingLoopBreakerRetry,
            "A successful revert must clear the pending retry"
        )

        // A paused guard keeps a retry armed while it suppresses evaluations, so it can never
        // stay dormant if the call app holds the Bluetooth mic and no further event arrives.
        loopController.invalidate()
        loopController.configure(enabled: true, fallbackUID: "builtin-mic")
        for idx in 0..<5 {
            fakeNow = 7000 + Double(idx) * 0.2
            loopDefaultUID = "bt-airpods"
            _ = loopController.evaluate()
        }
        expect(
            loopController.hasPendingLoopBreakerRetry,
            "The 5th rapid revert must arm the automatic retry"
        )
        loopDefaultUID = "bt-airpods" // the app grabs the headset mic again during the pause
        expect(
            loopController.evaluate() == .suppressedByLoopBreaker(bluetoothUID: "bt-airpods"),
            "The guard must stay paused during the retry window"
        )
        expect(
            loopController.hasPendingLoopBreakerRetry,
            "A suppressed evaluation must keep the retry armed rather than going dormant"
        )

        // Disabling the guard drops the retry, the override, and the throttle flag.
        loopController.armBypass(bluetoothUID: "bt-airpods")
        loopController.invalidate()
        expect(!loopController.hasPendingLoopBreakerRetry, "invalidate() must cancel the loop-breaker retry")
        expect(!loopController.hasPendingEvaluation, "invalidate() must cancel the debounce work")
        expect(loopController.bypassedUID == nil, "invalidate() must clear the temporary override")
        expect(!loopController.state.isThrottled, "invalidate() must clear the throttle flag")
        expect(loopController.state.bypassedBluetoothName == nil, "invalidate() must clear bypassed state")
        expect(loopController.evaluate() == .idle, "A disabled controller must stay idle after invalidate()")

        // No fallback microphone at all: the headset stays the mic.
        let soloController = BluetoothMicLockController(
            listDevices: { [makeDevice("bt-airpods", "AirPods Pro", .bluetooth, isDefaultInput: true)] },
            setDefaultInputDevice: { _ in
                failures.append("Controller must not write the default input when no fallback mic exists")
                return true
            },
            now: { fakeNow }
        )
        soloController.configure(enabled: true, fallbackUID: nil)
        expect(
            soloController.evaluate() == .suppressedByNoFallback(bluetoothUID: "bt-airpods"),
            "Controller must leave the Bluetooth mic alone when it is the only microphone"
        )

        // Disabled controller stays inert and drops pending debounce work.
        controller.configure(enabled: false, fallbackUID: nil)
        expect(!controller.hasPendingEvaluation, "Disabling the guard must clear pending debounce work")
        expect(controller.evaluate() == .idle, "Disabled controller must not revert")
        expect(!controller.state.isEnabled, "Disabled controller state must report isEnabled = false")

        // 9b. Pinned-app warning copy resolves friendly app names from the call app presets.
        let callModule = ModuleRegistry.shared.callControls
        expect(
            callModule.displayName(forBundleID: "us.zoom.xos") == "Zoom",
            "Known call apps must map to their preset name for the pinned-mic warning"
        )
        expect(
            callModule.displayName(forBundleID: "com.microsoft.teams2.helper") == "Microsoft Teams",
            "Helper processes must resolve to their owning call app name"
        )
        expect(
            callModule.displayName(forBundleID: "com.example.unknown-app") == "com.example.unknown-app",
            "Unknown bundle IDs must fall back to the identifier instead of an empty label"
        )
        expect(
            callModule.pinnedBluetoothMicHint(for: "Zoom").contains("Same as System"),
            "Pinned-mic hint must tell the user exactly what to change"
        )

        // 10. Backward-compatible config: legacy JSON without the 3 new keys.
        let legacyCallControlsJSON = "{\"enabled\": true, \"overrideScope\": \"everywhere\", \"showToasts\": true}"
        if let data = legacyCallControlsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(CallControlsConfig.self, from: data) {
            expect(!decoded.preventBluetoothMicSwitch, "Legacy CallControlsConfig must default preventBluetoothMicSwitch = false")
            expect(decoded.bluetoothMicLockFallbackUID == nil, "Legacy CallControlsConfig must default bluetoothMicLockFallbackUID = nil")
            expect(decoded.showBluetoothMicLockToast, "Legacy CallControlsConfig must default showBluetoothMicLockToast = true")
        } else {
            failures.append("Failed to decode legacy CallControlsConfig without mic-lock keys")
        }

        var micLockCfg = ToolboxConfig()
        micLockCfg.callControls.preventBluetoothMicSwitch = true
        micLockCfg.callControls.bluetoothMicLockFallbackUID = "usb-yeti"
        micLockCfg.callControls.showBluetoothMicLockToast = false
        if let data = try? JSONEncoder().encode(micLockCfg),
           let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(decoded.callControls == micLockCfg.callControls, "CallControlsConfig mic-lock round-trip mismatch")
            expect(decoded.callControls.bluetoothMicLockFallbackUID == "usb-yeti", "Mic-lock fallback UID must survive a config round-trip")
            expect(decoded.schemaVersion == 15, "Mic-lock config must serialize at schemaVersion 15")
        } else {
            failures.append("CallControlsConfig mic-lock encode/decode failed")
        }
    }

    private static func testScreenOCRConfigAndLifecycle() {
        // Defaults
        let cfg = ToolboxConfig()
        expect(!cfg.screenOCR.enabled, "ScreenOCR should default to disabled")
        expect(cfg.screenOCR.preserveLineBreaks, "ScreenOCR should default to preserving line breaks")
        expect(cfg.screenOCR.detectQRCodes, "ScreenOCR should default to detecting QR/barcodes")
        expect(cfg.screenOCR.showToast, "ScreenOCR should default to showing toasts")
        expect(
            cfg.screenOCR.shortcut == ShortcutSpec(key: "0", modifiers: [.command, .shift]),
            "ScreenOCR default shortcut should be ⇧ ⌘ 0"
        )

        // Codable round-trip
        var customCfg = ToolboxConfig()
        customCfg.screenOCR.enabled = true
        customCfg.screenOCR.preserveLineBreaks = false
        customCfg.screenOCR.detectQRCodes = false
        customCfg.screenOCR.showToast = false
        customCfg.screenOCR.shortcut = ShortcutSpec(key: "s", modifiers: [.control, .option, .command])
        if let data = try? JSONEncoder().encode(customCfg),
           let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(decoded.screenOCR == customCfg.screenOCR, "ScreenOCRConfig Codable round-trip mismatch")
            expect(decoded.schemaVersion == 15, "ToolboxConfig schemaVersion should be 15")
        } else {
            failures.append("ToolboxConfig with screenOCR failed Codable encode/decode")
        }

        // A config written by the previous build (schema 9, no screenOCR key) must decode
        // with the safe defaults and upgrade the schema.
        let legacyJSON = "{\"schemaVersion\": 9, \"general\": {\"appEnabled\": true}}"
        if let data = legacyJSON.data(using: .utf8),
           let migrated = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(migrated.schemaVersion == 15, "Legacy v9 config should upgrade to schemaVersion 15")
            expect(!migrated.screenOCR.enabled, "Legacy config must migrate screenOCR.enabled = false")
        } else {
            failures.append("Failed to decode pre-ScreenOCR JSON config")
        }

        // A partial screenOCR object (including removed legacy keys like recognitionLevel)
        // must decode cleanly and fill missing keys with safe defaults.
        let partialJSON = "{\"schemaVersion\": 10, \"screenOCR\": {\"enabled\": true, \"recognitionLevel\": \"fast\"}}"
        if let data = partialJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(decoded.screenOCR.enabled, "Partial screenOCR decode mismatch")
            expect(
                decoded.screenOCR.preserveLineBreaks && decoded.screenOCR.detectQRCodes && decoded.screenOCR.showToast,
                "Partial screenOCR should fill missing fields with defaults"
            )
            expect(
                decoded.screenOCR.shortcut == ShortcutSpec(key: "0", modifiers: [.command, .shift]),
                "Partial screenOCR shortcut should default to ⇧ ⌘ 0"
            )
        } else {
            failures.append("Failed to decode partial screenOCR JSON")
        }

        // In-app hotkey conflict detection & one-click resolution
        let manager = HotKeyManager.shared
        var conflictCfg = ToolboxConfig()
        conflictCfg.screenOCR.enabled = true
        conflictCfg.clipboard.enabled = true
        conflictCfg.clipboard.shortcut = conflictCfg.screenOCR.shortcut
        let conflict = manager.inAppConflictDescription(
            for: conflictCfg.screenOCR.shortcut,
            excludingSourceID: "screen_ocr",
            in: conflictCfg
        )
        expect(conflict != nil, "HotKeyManager should detect collision between Screen OCR and Clipboard")
        manager.clearConflictingShortcuts(
            matching: conflictCfg.screenOCR.shortcut,
            excludingSourceID: "screen_ocr",
            in: &conflictCfg
        )
        expect(conflictCfg.clipboard.shortcut.isEmpty, "clearConflictingShortcuts should clear colliding Clipboard shortcut")
        expect(!conflictCfg.screenOCR.shortcut.isEmpty, "clearConflictingShortcuts must preserve excluded Screen OCR shortcut")

        // Registry & lifecycle (shortcut .none so no global hotkey is armed in the test process)
        let module = ModuleRegistry.shared.screenOCR
        expect(ModuleRegistry.shared.module(withID: "screen_ocr") === module, "Registry must resolve screen_ocr")
        expect(!module.requiresAccessibility, "ScreenOCR must not require Accessibility")
        expect(module.category == .developer, "ScreenOCR should be in the Developer Tools category")
        expect(module.supportsEnableToggle, "ScreenOCR should expose an enable toggle")

        var moduleCfg = ToolboxConfig()
        moduleCfg.screenOCR.enabled = true
        moduleCfg.screenOCR.shortcut = .none
        module.reload(with: moduleCfg)
        expect(module.isRunning, "Module should start when enabled")

        moduleCfg.screenOCR.enabled = false
        module.reload(with: moduleCfg)
        expect(!module.isRunning, "Module should stop when disabled")

        moduleCfg.screenOCR.enabled = true
        moduleCfg.general.appEnabled = false
        module.reload(with: moduleCfg)
        expect(!module.isRunning, "Module must stop when the whole app is paused")

        module.stop()
        expect(!module.isRunning, "stop() should clear isRunning")

        // Deterministic status text across permission states
        var statusCfg = ToolboxConfig()
        expect(module.statusText(in: statusCfg, accessibilityGranted: true) == "Disabled", "Disabled statusText mismatch")
        statusCfg.screenOCR.enabled = true
        statusCfg.general.appEnabled = false
        expect(module.statusText(in: statusCfg, accessibilityGranted: true) == "Paused", "Paused statusText mismatch")
        statusCfg.general.appEnabled = true
        module.setScreenRecordingGrantedForTesting(false)
        expect(
            module.statusText(in: statusCfg, accessibilityGranted: true) == "Needs Screen Access",
            "Enabled module without Screen Recording permission must report Needs Screen Access"
        )
        module.setScreenRecordingGrantedForTesting(true)
        moduleCfg.general.appEnabled = true
        module.reload(with: moduleCfg)
        expect(module.statusText(in: moduleCfg, accessibilityGranted: true) == "Active", "Running module with permission must report Active")
        module.stop()

        // shortcutText formatting
        expect(
            module.shortcutText(in: statusCfg) == ShortcutSpec(key: "0", modifiers: [.command, .shift]).displayString,
            "shortcutText should format the default shortcut"
        )
        statusCfg.screenOCR.shortcut = .none
        expect(module.shortcutText(in: statusCfg) == nil, "shortcutText should be nil for .none")

        // Recent captures: newest first, capped at 10, clearable
        module.replaceRecentCaptures([])
        for idx in 0..<12 {
            module.appendRecent(OCRResult(text: "line \(idx)", qrPayloads: []))
        }
        expect(module.recentCaptures.count == ScreenOCRModule.maxRecentCaptures, "Recent captures should cap at 10")
        expect(module.recentCaptures.first?.text == "line 11", "Newest capture should be first")
        expect(module.recentCaptures.first?.lineCount == 1, "Single-line capture should report 1 line")
        module.clearRecentCaptures()
        expect(module.recentCaptures.isEmpty, "clearRecentCaptures should empty the session list")

        // Developer self-check lifecycle: renders the synthetic sample, runs the real
        // engine path off the main thread, and stores the result. Shortcut .none keeps
        // the global hotkey un-armed in the test process.
        var selfCheckCfg = ToolboxConfig()
        selfCheckCfg.screenOCR.enabled = true
        selfCheckCfg.screenOCR.shortcut = .none
        selfCheckCfg.screenOCR.detectQRCodes = true
        module.reload(with: selfCheckCfg)
        module.clearSelfCheckResults()
        expect(module.lastSelfCheck == nil, "clearSelfCheckResults must clear the stored result")
        module.runSelfCheck()
        expect(module.isRunningSelfCheck, "runSelfCheck must mark the check in flight")
        let selfCheckDeadline = Date().addingTimeInterval(10)
        while module.isRunningSelfCheck && Date() < selfCheckDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        expect(!module.isRunningSelfCheck, "runSelfCheck must finish within the deadline")
        expect(
            module.lastSelfCheck?.recognizedText.contains("Toolbox OCR self-check") == true,
            "Self-check must recognize the sample headline (got: \(module.lastSelfCheck?.recognizedText ?? "nil"))"
        )
        expect(
            module.lastSelfCheck?.qrPayloads.contains(ScreenOCREngine.selfCheckQRPayload) == true,
            "Self-check must decode the sample QR payload (got: \(module.lastSelfCheck?.qrPayloads ?? []))"
        )
        module.stop()

        // Developer pipeline test: report struct semantics, then a real full-screen
        // control run. Content-dependent stages (vision/output) may legitimately fail on
        // a machine without Screen Recording permission, so assert completion + launch,
        // never the recognition outcome.
        var reportProbe = OCRPipelineReport(
            kind: .fullScreen,
            stages: [
                OCRPipelineStage(id: "a", name: "A", status: .pass, detail: "ok"),
                OCRPipelineStage(id: "b", name: "B")
            ],
            startedAt: Date(),
            artifactPath: nil,
            outputPreview: nil
        )
        expect(!reportProbe.isComplete && !reportProbe.hasFailure, "Pending stage must block completion and not count as failure")
        reportProbe.stages[1].status = .fail
        expect(reportProbe.isComplete && reportProbe.hasFailure, "Fail stage must complete the report and flag failure")

        module.runPipelineTest(interactive: false)
        expect(module.isRunningPipelineTest, "runPipelineTest must mark the run in flight")
        let pipelineDeadline = Date().addingTimeInterval(20)
        while module.isRunningPipelineTest && Date() < pipelineDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        expect(!module.isRunningPipelineTest, "Pipeline test must finish within the deadline")
        if let report = module.pipelineReport {
            let stageSummary = report.stages.map { "\($0.id)=\(String(describing: $0.status))" }.joined(separator: ", ")
            expect(report.isComplete, "Pipeline report must resolve every stage (got: \(stageSummary))")
            let launch = report.stages.first { $0.id == "launch" }
            expect(launch?.status == .pass, "screencapture must launch in the pipeline test")
        } else {
            failures.append("Pipeline report missing after run")
        }
        module.cancelPipelineTest()
        module.clearPipelineReport()

        // Stale temp sweep (launch hygiene): previous-session capture artifacts must be
        // removed, unrelated files must survive.
        let tempDir = FileManager.default.temporaryDirectory
        let staleURL = tempDir.appendingPathComponent("toolbox-ocr-selftest-sweep-\(UUID().uuidString).png")
        let keepURL = tempDir.appendingPathComponent("not-toolbox-selftest-\(UUID().uuidString).txt")
        try? Data([1]).write(to: staleURL)
        try? Data([1]).write(to: keepURL)
        ScreenOCRModule.sweepStaleTempFiles()
        expect(!FileManager.default.fileExists(atPath: staleURL.path), "sweepStaleTempFiles must remove stale toolbox-ocr-* artifacts")
        expect(FileManager.default.fileExists(atPath: keepURL.path), "sweepStaleTempFiles must leave unrelated files alone")
        try? FileManager.default.removeItem(at: keepURL)
    }

    private static func testScreenOCREngineRecognition() {
        // 1. Pure formatting: top-to-bottom ordering, same-row grouping, line-break joining
        let lines = [
            RecognizedTextLine(text: "right", normalizedY: 0.80, normalizedX: 0.60, confidence: 0.9),
            RecognizedTextLine(text: "alpha", normalizedY: 0.90, normalizedX: 0.10, confidence: 0.9),
            RecognizedTextLine(text: "bottom", normalizedY: 0.20, normalizedX: 0.30, confidence: 0.9),
            RecognizedTextLine(text: "left", normalizedY: 0.805, normalizedX: 0.05, confidence: 0.9)
        ]
        let lineBreaks = ScreenOCREngine.formattedText(from: lines, preserveLineBreaks: true)
        expect(lineBreaks == "alpha\nleft right\nbottom", "formattedText top-to-bottom + same-row grouping mismatch: \(lineBreaks)")
        let joined = ScreenOCREngine.formattedText(from: lines, preserveLineBreaks: false)
        expect(joined == "alpha left right bottom", "formattedText with preserveLineBreaks=false must join rows with spaces: \(joined)")
        expect(ScreenOCREngine.formattedText(from: [], preserveLineBreaks: true) == "", "Empty input must format to an empty string")

        // 1b. Height-relative same-row tolerance: adjacent lines in a dense document must
        // stay separate rows even when their spacing is well under the fixed 2% fallback
        // (regression: the old image-height tolerance merged them in large selections).
        let denseLines = (0..<6).map { i in
            RecognizedTextLine(
                text: "line \(i)",
                normalizedY: 0.95 - 0.015 * CGFloat(i),
                normalizedX: 0.20,
                normalizedHeight: 0.015,
                confidence: 0.9
            )
        }
        let denseOut = ScreenOCREngine.formattedText(from: denseLines, preserveLineBreaks: true)
        let denseRowCount = denseOut.components(separatedBy: "\n").count
        expect(denseRowCount == 6, "Dense lines (spacing 0.015, height 0.015) must stay 6 rows (got \(denseRowCount): \(denseOut.replacingOccurrences(of: "\n", with: " | ")))" )

        // Same visual line: two columns whose origins differ by less than half the line
        // height share one row and are joined left-to-right.
        let columnLines = [
            RecognizedTextLine(text: "colA", normalizedY: 0.800, normalizedX: 0.10, normalizedHeight: 0.015, confidence: 0.9),
            RecognizedTextLine(text: "colB", normalizedY: 0.806, normalizedX: 0.55, normalizedHeight: 0.015, confidence: 0.9)
        ]
        expect(
            ScreenOCREngine.formattedText(from: columnLines, preserveLineBreaks: true) == "colA colB",
            "Columns within half a line height must share one row"
        )

        // Paragraph gaps: a vertical gap wider than one median line height becomes a blank
        // line (line-breaks mode only); gaps exactly one height stay inside the paragraph.
        let paraLines = [
            RecognizedTextLine(text: "para one A", normalizedY: 0.94, normalizedX: 0.10, normalizedHeight: 0.02, confidence: 0.9),
            RecognizedTextLine(text: "para one B", normalizedY: 0.90, normalizedX: 0.10, normalizedHeight: 0.02, confidence: 0.9),
            RecognizedTextLine(text: "para two", normalizedY: 0.80, normalizedX: 0.10, normalizedHeight: 0.02, confidence: 0.9)
        ]
        let paraOut = ScreenOCREngine.formattedText(from: paraLines, preserveLineBreaks: true)
        expect(paraOut == "para one A\npara one B\n\npara two", "Paragraph gap must add a blank line only for the wide gap (got: \(paraOut.debugDescription))")
        let paraJoined = ScreenOCREngine.formattedText(from: paraLines, preserveLineBreaks: false)
        expect(paraJoined == "para one A para one B para two", "preserveLineBreaks=false must never emit blank lines (got: \(paraJoined.debugDescription))")

        // Textual paragraph break: Vision emitted a blank line inside the observation.
        let blankParaLines = [
            RecognizedTextLine(text: "first", normalizedY: 0.90, normalizedX: 0.10, normalizedHeight: 0.02, confidence: 0.9),
            RecognizedTextLine(text: "second", normalizedY: 0.86, normalizedX: 0.10, normalizedHeight: 0.02, confidence: 0.9, hadBlankBefore: true)
        ]
        expect(
            ScreenOCREngine.formattedText(from: blankParaLines, preserveLineBreaks: true) == "first\n\nsecond",
            "hadBlankBefore must re-emit the paragraph break"
        )

        // Unknown heights (legacy/test lines) must fall back to the fixed 2% tolerance.
        expect(
            ScreenOCREngine.sameRowTolerance(for: [RecognizedTextLine(text: "a", normalizedY: 0.5, normalizedX: 0.1, confidence: 0.9)]) == ScreenOCREngine.sameRowYtolerance,
            "sameRowTolerance without heights must fall back to sameRowYtolerance"
        )

        // 2. Pure text + QR combination
        expect(ScreenOCREngine.combinedOutput(text: "", qrPayloads: []) == "", "Empty text + empty QR must produce empty output")
        expect(ScreenOCREngine.combinedOutput(text: "  hello ", qrPayloads: []) == "hello", "Text-only output should be trimmed")
        expect(
            ScreenOCREngine.combinedOutput(text: "", qrPayloads: ["https://toolbox.dev", "https://toolbox.dev", " "]) == "https://toolbox.dev",
            "QR-only output should trim and dedupe payloads"
        )
        expect(
            ScreenOCREngine.combinedOutput(text: "hello", qrPayloads: ["https://x.dev", "https://y.dev"]) == "hello\nhttps://x.dev\nhttps://y.dev",
            "Combined text + QR output mismatch"
        )

        // 3. OCRResult helpers
        let multiLine = OCRResult(text: "A\nB\n\nC", qrPayloads: [])
        expect(multiLine.lineCount == 3, "lineCount should ignore blank lines (got \(multiLine.lineCount))")
        expect(multiLine.toastSummary == "Copied 3 lines", "toastSummary for multi-line text mismatch: \(multiLine.toastSummary)")
        let singleLine = OCRResult(text: "one", qrPayloads: [])
        expect(singleLine.toastSummary == "Copied 1 line", "toastSummary for single line mismatch: \(singleLine.toastSummary)")
        let qrOnly = OCRResult(text: "", qrPayloads: ["https://a.dev", "https://b.dev"])
        expect(qrOnly.toastSummary == "Copied 2 QR codes", "QR toastSummary mismatch: \(qrOnly.toastSummary)")
        expect(qrOnly.clipboardString == "https://a.dev\nhttps://b.dev", "QR-only clipboardString mismatch")
        expect(OCRResult(text: "  ", qrPayloads: []).isEmpty, "Whitespace-only result must count as empty")

        // 4. Small-region upscaling (spec: heights < 32 px get a 2x render)
        if let small = Self.drawTestImage(width: 120, height: 20, lines: ["tiny"], fontSize: 12) {
            let prepared = ScreenOCREngine.prepareImage(small)
            expect(prepared.width == 240 && prepared.height == 40, "prepareImage must upscale sub-32px images 2x (got \(prepared.width)x\(prepared.height))")
        } else {
            failures.append("Could not render small test bitmap")
        }
        if let normal = Self.drawTestImage(width: 400, height: 200, lines: ["normal"], fontSize: 40) {
            expect(ScreenOCREngine.prepareImage(normal) === normal, "prepareImage must leave >= 32px images untouched")
        }

        // 5. Real on-device Vision OCR over an offscreen-rendered bitmap
        if let image = Self.drawTestImage(
            width: 900,
            height: 300,
            lines: ["Toolbox Vision OCR 42", "second line here", "third line here"],
            fontSize: 64
        ) {
            let result = ScreenOCREngine.recognize(in: image, preserveLineBreaks: true, detectBarcodes: false)
            expect(result.text.contains("Toolbox Vision OCR 42"), "Vision OCR must recognize the rendered headline (got: \(result.text))")
            expect(result.text.contains("second line here"), "Vision OCR must recognize the second line (got: \(result.text))")
            expect(result.lineCount == 3, "Vision OCR should produce 3 lines (got: \(result.lineCount): \(result.text))")
            expect(!result.text.contains("third line here") || result.lineCount == 3, "Recognized output should stay on 3 lines")

            let joinedResult = ScreenOCREngine.recognize(in: image, preserveLineBreaks: false, detectBarcodes: false)
            expect(
                !joinedResult.text.contains("\n") && joinedResult.text.contains("Toolbox Vision OCR 42"),
                "preserveLineBreaks=false must join lines with spaces (got: \(joinedResult.text))"
            )

            // Empty image (blank white bitmap) must recognize as empty, not crash — and a
            // bright blank is NOT the near-black permission signature.
            if let blank = Self.drawTestImage(width: 300, height: 200, lines: [""], fontSize: 40) {
                let blankResult = ScreenOCREngine.recognize(in: blank, preserveLineBreaks: true, detectBarcodes: true)
                expect(blankResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Blank image must produce no text (got: \(blankResult.text))")
                expect(blankResult.isEmpty, "Blank image must produce an empty result")
                expect(!blankResult.looksBlank, "Bright blank image must not flag looksBlank")
            }

            // A near-black image is the classic Screen Recording permission failure
            // signature: empty result + looksBlank must both be true.
            if let black = Self.drawTestImage(width: 300, height: 200, lines: [""], fontSize: 40, background: .black) {
                let blackResult = ScreenOCREngine.recognize(in: black, preserveLineBreaks: true, detectBarcodes: true)
                expect(blackResult.isEmpty, "Black image must produce an empty result")
                expect(blackResult.looksBlank, "Near-black image must flag looksBlank")
            }
        } else {
            failures.append("Could not render offscreen OCR test bitmap")
        }

        // 6. Missing / cancelled capture file handling
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-ocr-selftest-missing-\(UUID().uuidString).png")
        let cancelled = ScreenOCREngine.loadCapturedImage(at: missingURL)
        expect(cancelled.kind == .cancelled && cancelled.image == nil, "Missing capture file must map to .cancelled")
        expect(
            ScreenOCREngine.recognizeFile(at: missingURL, preserveLineBreaks: true, detectBarcodes: true) == nil,
            "recognizeFile on a missing file must return nil (clean Esc cancellation)"
        )

        // 7. Full file round-trip: render -> PNG on disk -> loadCapturedImage -> recognizeFile
        if let image = Self.drawTestImage(width: 700, height: 200, lines: ["toolbox file round trip"], fontSize: 56) {
            let rep = NSBitmapImageRep(cgImage: image)
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("toolbox-ocr-selftest-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: fileURL) }
            guard let pngData = rep.representation(using: .png, properties: [:]) else {
                failures.append("Could not encode test bitmap as PNG")
                return
            }
            do {
                try pngData.write(to: fileURL)
            } catch {
                failures.append("Could not write test PNG: \(error)")
                return
            }

            let loaded = ScreenOCREngine.loadCapturedImage(at: fileURL)
            expect(loaded.kind == .loaded && loaded.image != nil, "Valid capture PNG must map to .loaded")

            let fileResult = ScreenOCREngine.recognizeFile(
                at: fileURL,
                preserveLineBreaks: true,
                detectBarcodes: true
            )
            expect(fileResult?.text.contains("toolbox file round trip") == true, "recognizeFile must OCR the on-disk capture (got: \(fileResult?.text ?? "nil"))")
        } else {
            failures.append("Could not build round-trip test bitmap")
        }

        // 8. End-to-end QR/barcode path: generate a real QR code (CoreImage) and decode
        // it with Vision's VNDetectBarcodesRequest. Previously only the pure
        // combinedOutput helper was tested, never the barcode request itself.
        if let qr = ScreenOCREngine.qrCodeImage(payload: "https://toolbox.dev/self-test", targetSize: 240) {
            if let framed = Self.frameImage(qr, in: 320, margin: 16) {
                let qrResult = ScreenOCREngine.recognize(in: framed, preserveLineBreaks: true, detectBarcodes: true)
                expect(
                    qrResult.qrPayloads.contains("https://toolbox.dev/self-test"),
                    "Vision must decode the generated QR code (got: \(qrResult.qrPayloads))"
                )
                expect(
                    qrResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "QR-only bitmap must not produce spurious text lines (got: \(qrResult.text))"
                )
            } else {
                failures.append("Could not frame QR test bitmap")
            }
        } else {
            failures.append("CoreImage could not generate the QR test code")
        }

        // 9. Developer self-check sample: the exact image the Developer Tools button
        // renders must round-trip through the engine (3 text lines + 1 QR payload).
        if let sample = ScreenOCREngine.makeSelfCheckSample() {
            let sampleResult = ScreenOCREngine.recognize(
                in: ScreenOCREngine.prepareImage(sample),
                preserveLineBreaks: true,
                detectBarcodes: true
            )
            expect(
                sampleResult.text.contains("Toolbox OCR self-check"),
                "Self-check sample text must be recognized (got: \(sampleResult.text))"
            )
            expect(
                sampleResult.qrPayloads.contains(ScreenOCREngine.selfCheckQRPayload),
                "Self-check sample QR must be decoded (got: \(sampleResult.qrPayloads))"
            )
        } else {
            failures.append("Could not render the developer self-check sample")
        }

        // 10. Transparent images must not false-positive as uniform black.
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
           let transparentCtx = CGContext(
               data: nil,
               width: 64,
               height: 64,
               bitsPerComponent: 8,
               bytesPerRow: 0,
               space: srgb,
               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
           ),
           let transparentImage = transparentCtx.makeImage() {
            expect(
                !ScreenOCREngine.imageLooksBlank(transparentImage),
                "Transparent image must not trip the uniform-black permission gate"
            )
        }
    }

    /// Centers `image` on a white `size`×`size` bitmap with a `margin` quiet zone.
    private static func frameImage(_ image: CGImage, in size: Int, margin: Int) -> CGImage? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        let inner = CGFloat(size) - CGFloat(margin) * 2
        let nsImage = NSImage(cgImage: image, size: NSSize(width: inner, height: inner))
        nsImage.draw(in: NSRect(x: CGFloat(margin), y: CGFloat(margin), width: inner, height: inner))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Renders high-contrast text lines into an offscreen bitmap for engine tests.
    private static func drawTestImage(width: Int, height: Int, lines: [String], fontSize: CGFloat, background: NSColor = .white) -> CGImage? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        background.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let lineHeight = fontSize * 1.7
        for (idx, line) in lines.enumerated() where !line.isEmpty {
            let y = CGFloat(height) - lineHeight * CGFloat(idx + 1) + fontSize * 0.25
            (line as NSString).draw(at: NSPoint(x: CGFloat(width) * 0.1, y: y), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    private static func testMultiScreenOnboardingClipboardScrollAndMicSync() {
        // 1. Multi-screen window frame centering clamps cleanly inside secondary display bounds
        let secondaryVisible = NSRect(x: 1920, y: 25, width: 1440, height: 875)
        let centered = MainWindowController.centeredWindowFrame(
            currentSize: NSSize(width: 960, height: 680),
            onScreenVisibleFrame: secondaryVisible
        )
        expect(secondaryVisible.contains(centered), "Centered window frame must fit inside secondary screen visibleFrame: \(centered)")
        expect(abs(centered.midX - secondaryVisible.midX) <= 1.0, "Window should horizontally center on target screen")
        expect(abs(centered.midY - secondaryVisible.midY) <= 1.0, "Window should vertically center on target screen")

        // 2. First-open Accessibility onboarding modal state & seen flag persistence
        var cfg = ToolboxConfig()
        expect(!cfg.general.hasSeenAccessibilityOnboarding, "hasSeenAccessibilityOnboarding should default to false")
        cfg.general.hasSeenAccessibilityOnboarding = true
        if let data = try? JSONEncoder().encode(cfg),
           let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(decoded.general.hasSeenAccessibilityOnboarding, "hasSeenAccessibilityOnboarding must survive JSON round-trip")
        } else {
            failures.append("GeneralConfig with hasSeenAccessibilityOnboarding failed Codable round-trip")
        }

        let perms = PermissionsManager.shared
        let prevSeen = ConfigManager.shared.config.general.hasSeenAccessibilityOnboarding
        perms.presentOnboardingModal()
        expect(perms.isPresentingOnboardingModal, "presentOnboardingModal() must set isPresentingOnboardingModal = true")
        perms.dismissOnboardingModal(markSeen: true)
        expect(!perms.isPresentingOnboardingModal, "dismissOnboardingModal() must close onboarding modal")
        expect(ConfigManager.shared.config.general.hasSeenAccessibilityOnboarding, "dismissOnboardingModal(markSeen: true) must mark flag seen")
        ConfigManager.shared.config.general.hasSeenAccessibilityOnboarding = prevSeen

        // 3. Clipboard minimal scroll math keeps down-arrow selection at bottom (not top) and preserves selection on preview open/close
        let docBounds = NSRect(x: 0, y: 0, width: 400, height: 1000)
        let flippedVisible = NSRect(x: 0, y: 0, width: 400, height: 300)
        expect(
            ClipboardRowVisibilityNSView.minimalVerticalScrollOriginY(
                rowRect: NSRect(x: 8, y: 120, width: 384, height: 50),
                visibleRect: flippedVisible,
                documentBounds: docBounds,
                isFlipped: true
            ) == nil,
            "Fully visible row must not trigger scroll"
        )
        expect(
            ClipboardRowVisibilityNSView.minimalVerticalScrollOriginY(
                rowRect: NSRect(x: 8, y: 290, width: 384, height: 50),
                visibleRect: flippedVisible,
                documentBounds: docBounds,
                isFlipped: true
            ) == 40,
            "Scrolling down past bottom (flipped) should place row at bottom edge (y=40), not top (y=290)"
        )
        expect(
            ClipboardRowVisibilityNSView.minimalVerticalScrollOriginY(
                rowRect: NSRect(x: 8, y: 20, width: 384, height: 50),
                visibleRect: NSRect(x: 0, y: 100, width: 400, height: 300),
                documentBounds: docBounds,
                isFlipped: true
            ) == 20,
            "Scrolling up past top (flipped) should place row at top edge (y=20)"
        )
        expect(
            ClipboardRowVisibilityNSView.minimalVerticalScrollOriginY(
                rowRect: NSRect(x: 8, y: 360, width: 384, height: 50),
                visibleRect: NSRect(x: 0, y: 400, width: 400, height: 300),
                documentBounds: docBounds,
                isFlipped: false
            ) == 360,
            "Scrolling down past bottom (unflipped) should place row at bottom edge (y=360)"
        )

        // 4. Call Controls mute label classification, effective state sync, and idle background Teams guard
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Mute mic (⌘⇧M)") == false, "'Mute mic (⌘⇧M)' means currently unmuted (false)")
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Unmute mic (⌘⇧M)") == true, "'Unmute mic (⌘⇧M)' means currently muted (true)")
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Turn off microphone (⌘ + d)") == false, "Google Meet turn off mic label should classify as unmuted (false)")
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Turn on microphone (⌘ + d)") == true, "Google Meet turn on mic label should classify as muted (true)")
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Unmute huddle") == true, "Slack 'Unmute huddle' label should classify as muted (true)")
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Mute huddle") == false, "Slack 'Mute huddle' label should classify as unmuted (false)")
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Mute notifications") == nil, "Unrelated 'Mute notifications' must return nil")
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Mute all participants") == nil, "Unrelated 'Mute all participants' must return nil")

        expect(!CallControlsModule.resolveEffectiveMuteState(isTypingMuted: false, hardwareMuted: false, callAppMuted: false), "Live hardware + live app must resolve to live")
        expect(CallControlsModule.resolveEffectiveMuteState(isTypingMuted: false, hardwareMuted: false, callAppMuted: true), "App muted must resolve to muted even if hardware unmuted")
        expect(CallControlsModule.resolveEffectiveMuteState(isTypingMuted: false, hardwareMuted: true, callAppMuted: false), "Hardware muted must resolve to muted")
        expect(CallControlsModule.resolveEffectiveMuteState(isTypingMuted: true, hardwareMuted: false, callAppMuted: false), "Typing mute must resolve to muted")

        let initialSyncPlan = CallControlsModule.planObservedCallMuteSync(
            observedMuted: true,
            previousCallAppMuted: nil,
            hardwareInputMuted: false,
            syncHardwareWithApp: true,
            isTypingMuted: false,
            withinPostRelaySettleWindow: false,
            defaultInputAvailable: true
        )
        expect(
            initialSyncPlan == CallControlsModule.ObservedCallMutePlan(
                adoptCallAppMuted: true,
                hardwareMuteTarget: true,
                announceHardwareSyncLog: true
            ),
            "First read when joining an already-muted call with HW sync enabled must copy app mute to hardware"
        )
        let appOnlyPlan = CallControlsModule.planObservedCallMuteSync(
            observedMuted: true,
            previousCallAppMuted: nil,
            hardwareInputMuted: false,
            syncHardwareWithApp: false,
            isTypingMuted: false,
            withinPostRelaySettleWindow: false,
            defaultInputAvailable: true
        )
        expect(
            appOnlyPlan == CallControlsModule.ObservedCallMutePlan(
                adoptCallAppMuted: true,
                hardwareMuteTarget: nil,
                announceHardwareSyncLog: false
            ),
            "App-only mode must adopt app mute status in Toolbox without muting OS hardware (prevents Slack system-mute banner)"
        )
        let postRelayStale = CallControlsModule.planObservedCallMuteSync(
            observedMuted: false,
            previousCallAppMuted: true,
            hardwareInputMuted: true,
            syncHardwareWithApp: true,
            isTypingMuted: false,
            withinPostRelaySettleWindow: true,
            defaultInputAvailable: true
        )
        expect(postRelayStale == nil, "Post-relay settle window must ignore stale pre-flip AX poll")

        let micShortcut = ShortcutSpec(key: "m", modifiers: [.control, .option, .command])
        let mCode = UInt16(micShortcut.carbonKeyCode ?? 46)
        let idleTeamsEverywhere = CallShortcutRemapper.resolveDecision(
            keyCode: mCode,
            modifiers: [.control, .option, .command],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: .none,
            overrideScope: .everywhere,
            mappings: CallAppShortcutMapping.defaults,
            frontmostBundleID: "com.apple.Xcode",
            frontmostPID: 303,
            frontmostWindowTitle: "Toolbox.swift",
            runningApps: [RunningCallAppSnapshot(bundleIdentifier: "com.microsoft.teams2", pid: 202, windowTitles: ["Chat | Microsoft Teams"], hasActiveCallControl: false)],
            isCallActivityActive: false
        )
        expect(
            idleTeamsEverywhere == .globalHardwareOnly(action: .mic),
            "Idle background Teams without active call must not steal focus; should use globalHardwareOnly(.mic)"
        )

        expect(
            CoreAudioController.bundleID("com.tinyspeck.slackmacgap", matchesActiveInputProcessBundleIDs: ["com.tinyspeck.slackmacgap.helper"]),
            "Electron audio helper bundle ID must match its host call app"
        )
        expect(
            !CoreAudioController.bundleID("com.microsoft.teams", matchesActiveInputProcessBundleIDs: ["com.microsoft.teams2"]),
            "Similar bundle prefix without dot boundary must not cross-match"
        )
        expect(
            CoreAudioController.isNonCallSystemInputBundleID("com.apple.Sound-Settings.extension"),
            "System Settings Sound meter extension must be excluded from call mic activity detection"
        )
        expect(
            !CoreAudioController.isNonCallSystemInputBundleID("com.tinyspeck.slackmacgap.helper"),
            "Call app audio helpers must not be filtered as system settings extensions"
        )

        let videoShortcut = ShortcutSpec(key: "v", modifiers: [.control, .option, .command])
        let vCode = UInt16(videoShortcut.carbonKeyCode ?? 9)
        let slackActiveTeamsIdleSnapshots = [
            RunningCallAppSnapshot(
                bundleIdentifier: "com.microsoft.teams2",
                pid: 202,
                windowTitles: ["Chat | Microsoft Teams"],
                hasActiveCallControl: false,
                hasActiveAudioInput: false
            ),
            RunningCallAppSnapshot(
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                pid: 405,
                windowTitles: ["Slack Huddle"],
                hasActiveCallControl: true,
                hasActiveAudioInput: true
            )
        ]

        let frontSlackVideo = CallShortcutRemapper.resolveDecision(
            keyCode: vCode,
            modifiers: [.control, .option, .command],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .everywhere,
            mappings: CallAppShortcutMapping.defaults,
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            frontmostPID: 405,
            frontmostWindowTitle: "Slack Huddle",
            runningApps: slackActiveTeamsIdleSnapshots,
            isCallActivityActive: true
        )
        expect(
            frontSlackVideo == .globalHardwareOnly(action: .video),
            "Frontmost Slack (no video shortcut) must not fall through to idle background Teams for .video"
        )

        let bgSlackCallVideo = CallShortcutRemapper.resolveTargetPreview(
            action: .video,
            overrideScope: .everywhere,
            mappings: CallAppShortcutMapping.defaults,
            frontmostBundleID: "com.apple.Xcode",
            frontmostPID: 303,
            frontmostWindowTitle: "Toolbox.swift",
            runningApps: slackActiveTeamsIdleSnapshots,
            isCallActivityActive: true
        )
        expect(
            bgSlackCallVideo == nil,
            "Active Slack Huddle owning mic input must block .video fallback to idle background Teams"
        )

        let bgSlackCallMic = CallShortcutRemapper.resolveTargetPreview(
            action: .mic,
            overrideScope: .everywhere,
            mappings: CallAppShortcutMapping.defaults,
            frontmostBundleID: "com.apple.Xcode",
            frontmostPID: 303,
            frontmostWindowTitle: "Toolbox.swift",
            runningApps: slackActiveTeamsIdleSnapshots,
            isCallActivityActive: true
        )
        expect(
            bgSlackCallMic?.app.id == "slack",
            "Active Slack Huddle owning mic input must receive .mic even if idle Teams precedes it in snapshot list"
        )

        // Browser / Google Meet safety: browser menu bar items (Bookmark This Tab Cmd+D, Use Selection Cmd+E) must never match call controls
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Bookmark This Tab…", menuPath: "Bookmarks > Bookmark This Tab…") == nil,
            "Browser 'Bookmark This Tab…' must not classify as a call control"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Use Selection for Find", menuPath: "Edit > Find > Use Selection for Find") == nil,
            "Browser 'Use Selection for Find' must not classify as a call control"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Minimize", menuPath: "Window > Minimize") == nil,
            "Window 'Minimize' must not classify as a call control"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Dynamic Island", menuPath: "View > Dynamic Island") == nil,
            "Unrelated word containing 'mic' substring must not classify as .mic"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Mute All", menuPath: "Participants > Mute All") == nil,
            "Host 'Mute All' must not classify as personal mic mute"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Mute", menuPath: "Video > Mute")?.kind == .mic,
            "FaceTime 'Video > Mute' must classify as .mic"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Stop Video", menuPath: "Meeting > Stop Video")?.kind == .video,
            "Zoom 'Meeting > Stop Video' must classify as .video"
        )

        if let meetMapping = CallAppShortcutMapping.defaults.first(where: { $0.id == "google_meet" }),
           let zoomMapping = CallAppShortcutMapping.defaults.first(where: { $0.id == "zoom" }) {
            expect(CallShortcutRemapper.isBrowserMapping(meetMapping), "Google Meet preset must be identified as a browser mapping")
            expect(!CallShortcutRemapper.isBrowserMapping(zoomMapping), "Zoom preset must not be treated as a browser mapping")
        }
        expect(CallShortcutRemapper.isBrowserBundleID("com.google.Chrome"), "Chrome must be recognized as a browser bundle ID")
        expect(!CallShortcutRemapper.isBrowserBundleID("com.apple.FaceTime"), "FaceTime must not be recognized as a browser bundle ID")

        // Web-area mute classification rejects bare video-player "Mute"/"Unmute" while keeping Google Meet mic labels
        expect(
            CallShortcutRemapper.classifyCallMuteControlLabel("Mute (m)", isMenuItem: false, allowBareMuteWord: false) == nil,
            "Browser web-area inspection must ignore bare video-player 'Mute (m)' controls"
        )
        expect(
            CallShortcutRemapper.classifyCallMuteControlLabel("Turn off microphone (⌘ + d)", isMenuItem: false, allowBareMuteWord: false) == false,
            "Google Meet 'Turn off microphone' must classify as live (false) inside browser web area"
        )
        expect(
            CallShortcutRemapper.classifyCallMuteControlLabel("Turn on microphone", isMenuItem: false, allowBareMuteWord: false) == true,
            "Google Meet 'Turn on microphone' must classify as muted (true) inside browser web area"
        )

        // Video control classification for in-page Google Meet camera buttons
        expect(CallShortcutRemapper.classifyCallVideoControlLabel("Turn off camera (⌘ + e)") == true, "'Turn off camera' means camera is active (true)")
        expect(CallShortcutRemapper.classifyCallVideoControlLabel("Turn on camera") == false, "'Turn on camera' means camera is off (false)")
        expect(CallShortcutRemapper.classifyCallVideoControlLabel("Blur background") == nil, "'Blur background' must return nil")
        expect(CallShortcutRemapper.classifyCallVideoControlLabel("Video settings") == nil, "'Video settings' must return nil")

        // Floating pill stays visible when camera is turned off if active call app session remains open (e.g. muted Google Meet)
        expect(
            CallControlsModule.resolveCallOrMediaActive(isCameraActive: false, isMicStreamActive: false, hasActiveCallAppSession: true),
            "Active call app session must keep floating pill visible even when camera is off and mic stream is idle"
        )
        expect(
            !CallControlsModule.resolveCallOrMediaActive(isCameraActive: false, isMicStreamActive: false, hasActiveCallAppSession: false),
            "Floating pill must hide once camera, mic stream, and active call app session are all inactive"
        )

        // Both Ctrl+Opt+Cmd+M and Cmd+Shift+Space route to Google Meet when Meet tab is active in Chrome
        let slackStyleMic = ShortcutSpec(key: "space", modifiers: [.command, .shift])
        let slackSpaceCode = UInt16(slackStyleMic.carbonKeyCode ?? 49)
        for (label, testShortcut, code) in [("Ctrl+Opt+Cmd+M", micShortcut, mCode), ("Cmd+Shift+Space", slackStyleMic, slackSpaceCode)] {
            let meetFront = CallShortcutRemapper.resolveDecision(
                keyCode: code,
                modifiers: testShortcut.modifiers,
                eventUserData: 0,
                micShortcut: testShortcut,
                videoShortcut: videoShortcut,
                overrideScope: .everywhere,
                mappings: CallAppShortcutMapping.defaults,
                frontmostBundleID: "com.google.Chrome",
                frontmostPID: 707,
                frontmostWindowTitle: "Meet – qgs-xoum-qzq – Camera and microphone recording - Google Chrome",
                runningApps: []
            )
            if case .remap(let action, let app, _, let targetShortcut, _) = meetFront {
                expect(
                    action == .mic && app.id == "google_meet" && targetShortcut == ShortcutSpec(key: "d", modifiers: [.command]),
                    "\(label) on active Google Meet Chrome tab must remap to google_meet Cmd+D"
                )
            } else {
                failures.append("\(label) on active Google Meet Chrome tab should return .remap (got: \(meetFront))")
            }
        }

        // 5. Live Clipboard panel navigation: Down x12, Up x12, Right preview, Left back
        let liveClipboard = ClipboardModule()
        var clipCfg = ToolboxConfig()
        clipCfg.clipboard.maxItems = 30
        clipCfg.clipboard.persistHistory = false
        clipCfg.clipboard.captureImages = false
        liveClipboard.reload(with: clipCfg)
        liveClipboard.clearHistory(keepPinned: false)
        for idx in (1...20).reversed() {
            liveClipboard.recordText("Clip item \(idx)\nSecond line for realistic height")
        }
        let clipPanel = liveClipboard.ensurePanel(width: 420, height: 420)
        liveClipboard.showPopover()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        let clipSearchField = clipPanel.firstEditableTextField()
        expect(clipSearchField != nil, "Clipboard popover must contain an editable NSTextField search box")
        let clipResponder = clipPanel.firstResponder
        let isClipSearchFocused = ((clipResponder as? NSTextView)?.delegate as AnyObject?) === clipSearchField || clipResponder === clipSearchField
        expect(isClipSearchFocused, "Clipboard showPopover must auto-focus search so character keys filter instead of beeping")

        func firstScrollView(in view: NSView?) -> NSScrollView? {
            guard let view else { return nil }
            if let sv = view as? NSScrollView { return sv }
            for sub in view.subviews {
                if let found = firstScrollView(in: sub) { return found }
            }
            return nil
        }

        let clipScrollView = firstScrollView(in: clipPanel.contentView)
        expect(clipScrollView != nil, "Clipboard popover must contain an NSScrollView")
        let initialClipY = clipScrollView?.contentView.documentVisibleRect.origin.y ?? -1

        for _ in 0..<12 {
            liveClipboard.popoverState.moveSelection(delta: 1, in: liveClipboard.entries)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        expect(liveClipboard.popoverState.selectedEntryID == liveClipboard.entries[12].id, "12 down steps should select index 12")
        let downClipY = clipScrollView?.contentView.documentVisibleRect.origin.y ?? 0
        expect(downClipY > initialClipY + 20, "Navigating down 12 rows must scroll Clipboard downward (got \(downClipY) from \(initialClipY))")

        for _ in 0..<12 {
            liveClipboard.popoverState.moveSelection(delta: -1, in: liveClipboard.entries)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        expect(liveClipboard.popoverState.selectedEntryID == liveClipboard.entries[0].id, "12 up steps should return to index 0")
        let upClipY = clipScrollView?.contentView.documentVisibleRect.origin.y ?? 999
        expect(abs(upClipY) <= 1.0, "Navigating back up to index 0 must align cleanly at top y=0 (got \(upClipY))")

        for _ in 0..<8 {
            liveClipboard.popoverState.moveSelection(delta: 1, in: liveClipboard.entries)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        let viewedEntry = liveClipboard.entries[8]
        let yBeforePreview = clipScrollView?.contentView.documentVisibleRect.origin.y ?? 0
        expect(liveClipboard.popoverState.selectedEntryID == viewedEntry.id, "8 down steps should select index 8")
        liveClipboard.popoverState.previewEntryID = viewedEntry.id
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        if let previewID = liveClipboard.popoverState.previewEntryID {
            liveClipboard.popoverState.selectedEntryID = previewID
            liveClipboard.popoverState.previewEntryID = nil
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        expect(liveClipboard.popoverState.previewEntryID == nil, "Closing preview must clear previewEntryID")
        expect(liveClipboard.popoverState.selectedEntryID == viewedEntry.id, "Closing preview must stay on viewed entry (index 8), never jump to another row")
        let yAfterPreview = clipScrollView?.contentView.documentVisibleRect.origin.y ?? -1
        expect(abs(yAfterPreview - yBeforePreview) <= 2.0, "Closing preview must preserve list scroll position (before=\(yBeforePreview), after=\(yAfterPreview))")
        liveClipboard.hidePopover()
        liveClipboard.clearHistory(keepPinned: false)
        liveClipboard.stop()

        // 6. PortKiller search bar auto-focus & openSequence tracking
        let pkModule = PortKillerModule()
        let pkPanel = pkModule.ensurePanel(width: 460, height: 480)
        let seqBefore = pkModule.popoverState.openSequence
        pkModule.showPopover()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        expect(pkModule.popoverState.openSequence == seqBefore + 1, "PortKiller showPopover must increment openSequence")
        let pkSearchField = pkPanel.firstEditableTextField()
        expect(pkSearchField != nil, "PortKiller popover must provide an editable NSTextField search box")
        let pkResponder = pkPanel.firstResponder
        let isPKSearchFocused = ((pkResponder as? NSTextView)?.delegate as AnyObject?) === pkSearchField || pkResponder === pkSearchField
        expect(isPKSearchFocused, "PortKiller showPopover must focus the search bar automatically")
        pkModule.hidePopover()
        pkModule.stop()
    }

    private static func testSupportLinks() {
        expect(SupportLinks.githubSponsors.scheme == "https", "GitHub Sponsors URL must use https")
        expect(SupportLinks.githubSponsors.host == "github.com", "GitHub Sponsors URL host mismatch")
        expect(SupportLinks.githubSponsors.path == "/sponsors/ssa17", "GitHub Sponsors URL path mismatch")
        expect(SupportLinks.koFi.scheme == "https", "Ko-fi URL must use https")
        expect(SupportLinks.koFi.host == "ko-fi.com", "Ko-fi URL host mismatch")
        expect(SupportLinks.koFi.path == "/ssa17", "Ko-fi URL path mismatch")
        expect(SupportLinks.githubRepo.scheme == "https", "GitHub Repo URL must use https")
        expect(SupportLinks.githubRepo.host == "github.com", "GitHub Repo URL host mismatch")
        expect(SupportLinks.githubRepo.path == "/ssa17/toolbox", "GitHub Repo URL path mismatch")
        expect(SupportLinks.githubIssues.scheme == "https", "GitHub Issues URL must use https")
        expect(SupportLinks.githubIssues.host == "github.com", "GitHub Issues URL host mismatch")
        expect(SupportLinks.githubIssues.path == "/ssa17/toolbox/issues", "GitHub Issues URL path mismatch")

        let suiteName = "com.toolbox.selfTest.support.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            failures.append("Failed to allocate isolated UserDefaults suite for SupportState")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let state = SupportState(userDefaults: testDefaults)
        expect(state.highFiveCount == 0, "Fresh SupportState highFiveCount must start at 0")
        expect(state.highFiveStatusMessage == nil, "Fresh SupportState must have nil highFiveStatusMessage")
        expect(!state.isSupporterUnlocked, "Fresh SupportState must start with supporter badge locked")

        expect(state.sendHighFive() == 1, "First high-five must return 1")
        expect(state.highFiveStatusMessage != nil, "High-five status message must appear after tapping")
        state.toggleSupporterBadge()
        expect(state.isSupporterUnlocked, "toggleSupporterBadge must unlock supporter badge")

        let reloaded = SupportState(userDefaults: testDefaults)
        expect(reloaded.highFiveCount == 1, "SupportState must persist highFiveCount")
        expect(reloaded.isSupporterUnlocked, "SupportState must persist isSupporterUnlocked")

        let sampleBase = NSImage(size: NSSize(width: 256, height: 256))
        sampleBase.lockFocus()
        NSColor(calibratedRed: 89/255.0, green: 176/255.0, blue: 1.0, alpha: 1.0).setFill()
        NSRect(x: 0, y: 0, width: 256, height: 256).fill()
        sampleBase.unlockFocus()
        let badged = SupportState.makeSupporterDockIcon(from: sampleBase)
        expect(badged.size == NSSize(width: 512, height: 512), "Supporter Dock icon must render at 512x512")
        if let tiff = badged.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let center = rep.colorAt(x: 128, y: 128) {
            expect(center.redComponent > center.blueComponent && center.greenComponent > center.blueComponent,
                   "Supporter Dock icon must tint blue accent pixels toward warm gold (got r=\(center.redComponent), g=\(center.greenComponent), b=\(center.blueComponent))")
        } else {
            failures.append("Supporter Dock icon must produce valid bitmap representation")
        }
    }

    private static func testPermissionsFlowAndPointerCursorSheetDealloc() {
        // 1. Direct Privacy & Security deep-link URLs
        expect(
            PermissionsManager.accessibilitySettingsURL.absoluteString == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "Accessibility settings URL must target PrivacySecurity extension Privacy_Accessibility anchor"
        )
        expect(
            PermissionsManager.legacyAccessibilitySettingsURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "Legacy Accessibility fallback URL mismatch"
        )
        expect(
            PermissionsManager.screenRecordingSettingsURL.absoluteString == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "Screen Recording settings URL must target PrivacySecurity extension Privacy_ScreenCapture anchor"
        )

        // 2. Return-to-app decision helper only triggers on false -> true transition while awaiting in live mode
        expect(
            PermissionsManager.shouldReturnToAppOnGrant(
                isAwaiting: true,
                wasGranted: false,
                nowGranted: true,
                isDiagnosticMode: false,
                simulatedOverride: nil
            ),
            "Must return to app when Accessibility flips false -> true while awaiting"
        )
        expect(
            !PermissionsManager.shouldReturnToAppOnGrant(
                isAwaiting: false,
                wasGranted: false,
                nowGranted: true,
                isDiagnosticMode: false,
                simulatedOverride: nil
            ),
            "Must NOT steal focus when not awaiting a permission grant"
        )
        expect(
            !PermissionsManager.shouldReturnToAppOnGrant(
                isAwaiting: true,
                wasGranted: true,
                nowGranted: true,
                isDiagnosticMode: false,
                simulatedOverride: nil
            ),
            "Must NOT return to app when permission was already granted"
        )
        expect(
            !PermissionsManager.shouldReturnToAppOnGrant(
                isAwaiting: true,
                wasGranted: false,
                nowGranted: true,
                isDiagnosticMode: true,
                simulatedOverride: nil
            ),
            "Diagnostic CLI runs must never activate the app window"
        )
        expect(
            !PermissionsManager.shouldReturnToAppOnGrant(
                isAwaiting: true,
                wasGranted: false,
                nowGranted: true,
                isDiagnosticMode: false,
                simulatedOverride: false
            ),
            "Simulated Accessibility override must not trigger return-to-app activation"
        )

        // 3. PointerCursorNSView must never crash (objc_initWeak on deallocating NSWindow)
        // when a sheet/window with isReleasedWhenClosed = true closes while hovered.
        let mouse = NSEvent.mouseLocation
        autoreleasepool {
            var sheetLikeWindow: NSWindow? = NSWindow(
                contentRect: NSRect(x: mouse.x - 100, y: mouse.y - 100, width: 200, height: 200),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            sheetLikeWindow?.isReleasedWhenClosed = false
            let pointerView = PointerCursorNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            sheetLikeWindow?.contentView = pointerView
            sheetLikeWindow?.orderFrontRegardless()
            pointerView.reapplyCursorIfHovered()
            sheetLikeWindow?.close()
            sheetLikeWindow = nil
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        PointerCursorNSView.syncVisibleWindowUnderMouseOrResetCursor()

        // 4. PermissionsManager live state guards
        let perms = PermissionsManager.shared
        let prevSim = perms.simulatedAccessibilityGranted
        let prevReturnHook = perms.onReturnToAppRequested
        defer {
            perms.setSimulatedAccessibilityGranted(prevSim)
            perms.onReturnToAppRequested = prevReturnHook
            perms.setAwaitingGrantForTesting(false)
            perms.markAttemptedGrantWithoutSuccessForTesting(false)
            perms.refresh()
        }

        if perms.actualAccessibilityGranted {
            perms.setSimulatedAccessibilityGranted(false)
            perms.promptAndOpenSettings()
            expect(!perms.isAwaitingAccessibilityGrant, "Must NOT enter awaiting/prompt flow when real Accessibility is already granted")
        }

        perms.markAttemptedGrantWithoutSuccessForTesting(true)
        expect(perms.hasAttemptedGrantWithoutSuccess, "Attempted-grant diagnostic flag must update")
        perms.applyAccessibilityStateForTesting(wasGranted: false, nowGranted: true)
        expect(!perms.hasAttemptedGrantWithoutSuccess, "Granting Accessibility must clear stale-entry warning flag")
        expect(!perms.isAwaitingAccessibilityGrant, "Granting Accessibility must stop fast awaiting poll")
        // 5. Event tap re-arm guard must never re-enable on tapDisabledByUserInput or untrusted state
        expect(
            PermissionsManager.shouldRearmEventTap(for: .tapDisabledByTimeout, isTrusted: true),
            "Event tap should re-arm on timeout when Accessibility is trusted"
        )
        expect(
            !PermissionsManager.shouldRearmEventTap(for: .tapDisabledByTimeout, isTrusted: false),
            "Event tap must NOT re-arm on timeout when Accessibility is revoked"
        )
        expect(
            !PermissionsManager.shouldRearmEventTap(for: .tapDisabledByUserInput, isTrusted: true),
            "Event tap must NEVER re-arm on tapDisabledByUserInput"
        )
        expect(
            !PermissionsManager.shouldRearmEventTap(for: .tapDisabledByUserInput, isTrusted: false),
            "Event tap must NEVER re-arm on tapDisabledByUserInput when untrusted"
        )

        // 6. Uncached TCCAccessCheckAuditToken symbol & HIServices cache synchronization
        expect(
            PermissionsManager.tccCheckAccessibilityGranted() != nil,
            "TCCAccessCheckAuditToken must resolve from TCC.framework for kTCCServiceAccessibility"
        )
        expect(
            PermissionsManager.tccCheckAccessibilityGranted() == PermissionsManager.isProcessTrusted(),
            "isProcessTrusted() must match uncached TCCAccessCheckAuditToken for kTCCServiceAccessibility"
        )
        expect(
            PermissionsManager.isProcessTrustedFast() == PermissionsManager.isProcessTrusted(),
            "isProcessTrustedFast() must stay synchronized with isProcessTrusted()"
        )
    }

    private static func testForcedDarkAppearanceAndProminentButtons() {
        // 1. Keep NSApp.appearance unset so NSStatusBarButton template icons adapt to light/dark menu bars.
        expect(
            NSApp.appearance == nil,
            "NSApp.appearance must stay nil so the menu bar template icon adapts to Light and Dark menu bars"
        )

        // 2. Every Toolbox window and popover panel must explicitly force Dark Aqua.
        expect(
            MainWindowController.shared.ensureWindow().appearance?.name == .darkAqua,
            "Main dashboard NSWindow must use .darkAqua appearance"
        )

        let menuBar = MenuBarController()
        menuBar.refreshHostedViewSizeForTesting()
        expect(
            menuBar.popoverPanelForTesting?.appearance?.name == .darkAqua,
            "Menu bar popover panel must use .darkAqua appearance"
        )
        menuBar.hidePopoverForTesting()
        menuBar.setVisible(false)

        expect(
            ModuleRegistry.shared.clipboard.ensurePanel().appearance?.name == .darkAqua,
            "Clipboard popover panel must use .darkAqua appearance"
        )
        expect(
            ModuleRegistry.shared.portKiller.ensurePanel().appearance?.name == .darkAqua,
            "Port Killer popover panel must use .darkAqua appearance"
        )
        expect(
            ToolboxUpdateWindowController().window.appearance?.name == .darkAqua,
            "Custom update dialog window must use .darkAqua appearance"
        )

        // 3. Every ToolboxProminentTone must meet strong WCAG contrast against pure white text/icons.
        func linearChannel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        for tone in ToolboxProminentTone.allCases {
            let rgb = tone.sRGBComponents
            let lum = 0.2126 * linearChannel(rgb.r) + 0.7152 * linearChannel(rgb.g) + 0.0722 * linearChannel(rgb.b)
            let contrast = (1.0 + 0.05) / (lum + 0.05)
            expect(
                contrast >= 3.8,
                "ToolboxProminentTone.\(tone) must have >= 3.8:1 contrast against white (got \(String(format: "%.2f", contrast)):1)"
            )
        }

        // 4. Offscreen render of red Lock button under both Light Mode + inactive window AND Dark Mode + key window.
        func verifyRedButtonRender(
            appearanceName: NSAppearance.Name,
            activeState: ControlActiveState,
            label: String
        ) {
            let scheme: ColorScheme = (appearanceName == .darkAqua) ? .dark : .light
            let view = ZStack {
                Color(white: 0.45)
                Button {} label: {
                    Label("Lock (1m)", systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.toolboxProminent(.red))
                .controlSize(.small)
            }
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
            .environment(\.controlActiveState, activeState)

            let size = NSSize(width: 160, height: 56)
            guard let rep = renderOffscreenBitmap(
                view,
                size: size,
                appearanceName: appearanceName,
                settleSeconds: 0.08
            ) else {
                failures.append("Could not allocate bitmap rep for prominent button render check (\(label))")
                return
            }

            var redCount = 0
            var minX = rep.pixelsWide
            var maxX = -1
            var minY = rep.pixelsHigh
            var maxY = -1

            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if c.redComponent > 0.60 && c.greenComponent < 0.35 && c.blueComponent < 0.35 {
                        redCount += 1
                        minX = min(minX, x)
                        maxX = max(maxX, x)
                        minY = min(minY, y)
                        maxY = max(maxY, y)
                    }
                }
            }

            expect(
                redCount > 50,
                "Prominent red Lock button (\(label)) must render saturated red background fill (found \(redCount) red pixels)"
            )
            guard maxX - minX >= 4, maxY - minY >= 4 else { return }

            var whiteCount = 0
            var nearBlackCount = 0
            for y in (minY + 2)...(maxY - 2) {
                for x in (minX + 2)...(maxX - 2) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if c.redComponent > 0.85 && c.greenComponent > 0.85 && c.blueComponent > 0.85 {
                        whiteCount += 1
                    } else if c.redComponent < 0.25 && c.greenComponent < 0.25 && c.blueComponent < 0.25 {
                        nearBlackCount += 1
                    }
                }
            }

            expect(
                whiteCount > 10,
                "Prominent red Lock button (\(label)) must render crisp white label text & icon (found \(whiteCount) white pixels)"
            )
            expect(
                nearBlackCount == 0,
                "Prominent red Lock button (\(label)) must never render black/dark text on red fill (found \(nearBlackCount) near-black pixels)"
            )
        }

        verifyRedButtonRender(appearanceName: .aqua, activeState: .inactive, label: "Light Mode + inactive")
        verifyRedButtonRender(appearanceName: .darkAqua, activeState: .key, label: "Dark Mode + key")
    }

    private static func renderOffscreenBitmap<V: View>(
        _ view: V,
        size: NSSize,
        appearanceName: NSAppearance.Name,
        settleSeconds: TimeInterval = 0.08
    ) -> NSBitmapImageRep? {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearanceName)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearanceName)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: settleSeconds))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.close()
            return nil
        }
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        window.close()
        return rep
    }

    private static func testHUDToastSizingAndPositioning() {
        let testScreen = NSRect(x: 0, y: 0, width: 1512, height: 950)

        // Geometry & timing defaults (explicit checks prevent silent regressions).
        expect(HUDToast.fixedHeight == 44, "HUDToast.fixedHeight must be 44pt (got \(HUDToast.fixedHeight))")
        expect(HUDToast.minWidth == 200, "HUDToast.minWidth must be 200pt (got \(HUDToast.minWidth))")
        expect(HUDToast.topInset == 80, "HUDToast.topInset must be 80pt (got \(HUDToast.topInset))")
        expect(HUDToast.defaultDuration == 2.0, "HUDToast.defaultDuration must be 2.0s (got \(HUDToast.defaultDuration))")

        // 1. Height must stay constant across different SF Symbols (non-tautological: measuredSize returns real fitting height).
        let toastSymbols: [(String, Color)] = [
            ("checkmark.circle.fill", .green),
            ("doc.on.clipboard", .green),
            ("mic.slash.fill", .red),
            ("video.fill", .blue),
            ("exclamationmark.triangle.fill", .orange),
            ("keyboard", .orange),
            ("bolt.fill", .orange),
            ("info.circle.fill", .blue),
            ("arrow.clockwise", .blue),
            ("xmark.octagon.fill", .red)
        ]
        let toastHeights = toastSymbols.map { HUDToast.measuredSize(title: "Sample Toast Title", symbol: $0.0, tint: $0.1).height }
        expect(
            toastHeights.allSatisfy { abs($0 - HUDToast.fixedHeight) < 0.5 },
            "HUDToast height must remain constant (\(HUDToast.fixedHeight)pt) across all icons (got: \(toastHeights))"
        )

        // 2. Short titles clamp to the pill's minimum width.
        let shortSize = HUDToast.measuredSize(title: "Hi", symbol: "checkmark.circle.fill", tint: .green)
        expect(
            abs(shortSize.width - HUDToast.minWidth) < 0.5,
            "Short HUDToast must clamp to minimum width (\(HUDToast.minWidth)pt) (got: \(shortSize.width))"
        )

        // 3. Long titles get their full natural width instead of clamping.
        let longSize = HUDToast.measuredSize(
            title: "Focus Zoom or switch scope to Everywhere to toggle camera",
            symbol: "video.slash",
            tint: .orange
        )
        expect(
            longSize.width > HUDToast.minWidth + 100,
            "Long HUDToast must measure full natural width instead of clamping (got: \(longSize.width))"
        )
        expect(
            longSize.width > shortSize.width,
            "HUDToast width must grow with title length (long \(longSize.width) <= short \(shortSize.width))"
        )

        // 4. Pure placement math: pixel-rounded, horizontally centered, multi-display safe, and clamped on narrow screens.
        let frame = HUDToast.defaultTopCenterFrame(forSize: longSize, inVisibleFrame: testScreen)
        expect(
            abs(frame.width - longSize.width) < 0.5 && abs(frame.height - longSize.height) < 0.5,
            "HUDToast placement frame must preserve the measured size (got: \(frame))"
        )
        expect(
            abs(frame.midX - testScreen.midX) <= 0.5,
            "HUDToast must be horizontally centered (got midX \(frame.midX), screen midX \(testScreen.midX))"
        )
        expect(
            frame.origin.x == floor(frame.origin.x) && frame.origin.y == floor(frame.origin.y),
            "HUDToast placement frame origin must be pixel-rounded (got: \(frame.origin))"
        )
        expect(
            abs(frame.maxY - (testScreen.maxY - HUDToast.topInset)) < 0.5,
            "HUDToast top edge must sit \(HUDToast.topInset)pt below the top of the visible frame (got maxY \(frame.maxY))"
        )

        let oddFrame = HUDToast.defaultTopCenterFrame(forSize: NSSize(width: 221, height: 44), inVisibleFrame: testScreen)
        expect(
            oddFrame.origin.x == floor(oddFrame.origin.x) && abs(oddFrame.midX - testScreen.midX) <= 0.5,
            "Odd-width HUDToast must stay pixel-aligned and centered (got: \(oddFrame))"
        )

        let secondaryScreen = NSRect(x: 1580, y: -200, width: 2560, height: 1415)
        let secFrame = HUDToast.defaultTopCenterFrame(forSize: longSize, inVisibleFrame: secondaryScreen)
        expect(
            abs(secFrame.midX - secondaryScreen.midX) <= 0.5 && abs(secFrame.maxY - (secondaryScreen.maxY - HUDToast.topInset)) < 0.5,
            "HUDToast placement must honor non-zero origin screens (got \(secFrame) for \(secondaryScreen))"
        )

        let narrowScreen = NSRect(x: 0, y: 0, width: 320, height: 600)
        let narrowFrame = HUDToast.defaultTopCenterFrame(forSize: NSSize(width: 520, height: 44), inVisibleFrame: narrowScreen)
        let expectedNarrowWidth = narrowScreen.width - HUDToast.screenHorizontalMargin * 2
        expect(
            abs(narrowFrame.width - expectedNarrowWidth) < 0.5
                && narrowFrame.minX >= HUDToast.screenHorizontalMargin
                && narrowFrame.maxX <= narrowScreen.width - HUDToast.screenHorizontalMargin,
            "HUDToast must clamp width within horizontal margins on narrow screens (got: \(narrowFrame))"
        )

        // 5. Live panel: show() presents, reuses the same panel, resizes, cancels stale timers, auto-dismisses, and dismiss() hides immediately.
        let toast = HUDToast.shared
        let firstTitle = "Self-test toast"
        toast.show(title: firstTitle, symbol: "checkmark.circle.fill", tint: .green, duration: 0.12)
        if let panel = toast.panelForTesting {
            expect(panel.isVisible, "HUDToast panel must be visible after show()")
            expect(panel.level == .statusBar, "HUDToast panel must float at .statusBar level (got: \(panel.level.rawValue))")
            expect(panel.ignoresMouseEvents, "HUDToast panel must ignore mouse events so it never steals clicks")
            expect(!panel.isOpaque, "HUDToast panel must be non-opaque for clean capsule edges")
            expect(panel.appearance?.name == .darkAqua, "HUDToast panel must force .darkAqua appearance")
            expect(panel.collectionBehavior.contains(.canJoinAllSpaces), "HUDToast panel must join all spaces")

            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let expected = HUDToast.defaultTopCenterFrame(
                    forSize: HUDToast.measuredSize(title: firstTitle, symbol: "checkmark.circle.fill", tint: .green),
                    inVisibleFrame: screen.visibleFrame
                )
                expect(
                    abs(panel.frame.midX - expected.midX) < 1
                        && abs(panel.frame.maxY - expected.maxY) < 1
                        && abs(panel.frame.width - expected.width) < 1,
                    "HUDToast panel frame must match top-center placement math (got \(panel.frame), expected \(expected))"
                )
            }

            let firstWidth = panel.frame.width
            let longTitle = "A much longer replacement toast for the self-test run"
            toast.show(title: longTitle, symbol: "info.circle.fill", tint: .blue, duration: 0.35)
            expect(toast.panelForTesting === panel, "HUDToast must reuse the same panel instead of allocating a new one")
            expect(panel.isVisible, "Re-showing a new toast must keep the panel visible")
            expect(
                panel.frame.width > firstWidth + 80,
                "Re-showing a longer toast must widen panel frame (first \(firstWidth), new \(panel.frame.width))"
            )
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let expectedLong = HUDToast.defaultTopCenterFrame(
                    forSize: HUDToast.measuredSize(title: longTitle, symbol: "info.circle.fill", tint: .blue),
                    inVisibleFrame: screen.visibleFrame
                )
                expect(
                    abs(panel.frame.midX - expectedLong.midX) < 1
                        && abs(panel.frame.maxY - expectedLong.maxY) < 1
                        && abs(panel.frame.width - expectedLong.width) < 1,
                    "Replacement HUDToast panel frame must match new size & center (got \(panel.frame), expected \(expectedLong))"
                )
            }

            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.20))
            expect(panel.isVisible, "Re-showing a toast must cancel the previous auto-dismiss timer")

            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
            expect(!panel.isVisible, "HUDToast must auto-dismiss after replacement duration expires")

            toast.show(title: "Dismiss test", duration: 2.0)
            expect(panel.isVisible, "HUDToast panel must be visible before dismiss()")
            toast.dismiss()
            expect(!panel.isVisible, "HUDToast.dismiss() must immediately hide the floating panel")
        } else {
            failures.append("HUDToast.show() must create the floating panel")
        }

        // 6. Offscreen render: tinted icon, light title text, and clean capsule silhouette without stray side bars.
        let size = NSSize(width: 280, height: 88)
        guard let rep = renderOffscreenBitmap(
            ZStack {
                Color(red: 0.145, green: 0.149, blue: 0.165)
                HUDToast.makeToastView(title: "Copied to clipboard", symbol: "doc.on.clipboard", tint: .green)
            },
            size: size,
            appearanceName: .darkAqua,
            settleSeconds: 0.1
        ) else {
            failures.append("Could not allocate bitmap rep for HUDToast render check")
            return
        }

        var tintedIconPixels = 0
        var lightTextPixels = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.greenComponent > 0.55 && c.redComponent < 0.45 && c.blueComponent < 0.55 {
                    tintedIconPixels += 1
                }
                if c.redComponent > 0.8 && c.greenComponent > 0.8 && c.blueComponent > 0.8 {
                    lightTextPixels += 1
                }
            }
        }
        expect(tintedIconPixels > 20, "HUDToast must render its tinted SF Symbol (found \(tintedIconPixels) green pixels)")
        expect(lightTextPixels > 40, "HUDToast must render light title text (found \(lightTextPixels) light pixels)")

        if let bg = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB) {
            let topY = rep.pixelsHigh / 2 - max(4, Int(round(10 * CGFloat(rep.pixelsHigh) / size.height)))
            var runs = 0
            var inRun = false
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: topY)?.usingColorSpace(.sRGB) else { continue }
                let diff = abs(c.redComponent - bg.redComponent)
                    + abs(c.greenComponent - bg.greenComponent)
                    + abs(c.blueComponent - bg.blueComponent)
                if diff > 0.02 {
                    if !inRun {
                        runs += 1
                        inRun = true
                    }
                } else {
                    inRun = false
                }
            }
            expect(runs == 1, "HUDToast capsule edge must render as a single contiguous pill without stray side artifacts (found \(runs) runs)")
        } else {
            failures.append("Could not sample background pixel for HUDToast edge check")
        }
    }

    private static func testWindowSnapperGeometryAndCoordinateConversion() {
        // 1. Primary-screen height invariant round-trip across asymmetric multi-display geometries
        let primaryHeight: CGFloat = 1117
        let primaryRectAppKit = CGRect(x: 0, y: 78, width: 1728, height: 1007)
        let primaryAX = SnapGeometry.appKitToAX(primaryRectAppKit, primaryScreenHeight: primaryHeight)
        expect(primaryAX == CGRect(x: 0, y: 32, width: 1728, height: 1007), "Primary AX conversion mismatch: \(primaryAX)")
        expect(SnapGeometry.axToAppKit(primaryAX, primaryScreenHeight: primaryHeight) == primaryRectAppKit, "Primary round-trip mismatch")

        // Secondary display positioned ABOVE primary (y > primaryHeight in AppKit -> negative y in AX)
        let aboveAppKit = CGRect(x: -200, y: 1117, width: 2560, height: 1415)
        let aboveAX = SnapGeometry.appKitToAX(aboveAppKit, primaryScreenHeight: primaryHeight)
        expect(aboveAX == CGRect(x: -200, y: -1415, width: 2560, height: 1415), "Above-primary AX conversion mismatch: \(aboveAX)")
        expect(SnapGeometry.axToAppKit(aboveAX, primaryScreenHeight: primaryHeight) == aboveAppKit, "Above-primary round-trip mismatch")

        // Secondary display positioned BELOW primary (negative y in AppKit -> y > primaryHeight in AX)
        let belowAppKit = CGRect(x: 100, y: -900, width: 1440, height: 875)
        let belowAX = SnapGeometry.appKitToAX(belowAppKit, primaryScreenHeight: primaryHeight)
        expect(belowAX == CGRect(x: 100, y: 1142, width: 1440, height: 875), "Below-primary AX conversion mismatch: \(belowAX)")
        expect(SnapGeometry.axToAppKit(belowAX, primaryScreenHeight: primaryHeight) == belowAppKit, "Below-primary round-trip mismatch")

        // 2. Usable rect calculation: visibleFrame + notch safeAreaInsets + Stage Manager strip
        let notchedScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let autoHideMenuVisible = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let usableNotchSM = SnapGeometry.usableAppKitRect(
            screenFrame: notchedScreen,
            visibleFrame: autoHideMenuVisible,
            safeAreaInsets: SafeAreaInsets(top: 38, left: 0, bottom: 0, right: 0),
            stageManagerActive: true,
            stageManagerEdge: .left,
            stageManagerReservePoints: 78
        )
        expect(
            usableNotchSM == CGRect(x: 78, y: 0, width: 1434, height: 944),
            "Usable rect with notch + left Stage Manager strip mismatch: \(usableNotchSM)"
        )

        // When visibleFrame already excluded menu bar, safeAreaInsets must NOT double-subtract
        let shownMenuVisible = CGRect(x: 0, y: 78, width: 1512, height: 866)
        let usableNoDoubleSubtract = SnapGeometry.usableAppKitRect(
            screenFrame: notchedScreen,
            visibleFrame: shownMenuVisible,
            safeAreaInsets: SafeAreaInsets(top: 38, left: 0, bottom: 0, right: 0),
            stageManagerActive: false
        )
        expect(usableNoDoubleSubtract == shownMenuVisible, "Shown menu bar visibleFrame must not double-subtract notch safe area (got \(usableNoDoubleSubtract))")

        expect(
            SnapGeometry.isStageManagerStripVisible(windowManagerDefaults: ["GloballyEnabled": true, "AutoHide": false]),
            "Stage Manager enabled + non-autohide must report strip visible"
        )
        expect(
            !SnapGeometry.isStageManagerStripVisible(windowManagerDefaults: ["GloballyEnabled": true, "AutoHide": true]),
            "Stage Manager with AutoHide=true must report strip hidden"
        )

        // 3. Outer margin (P_out) & inner gap (G_in) division formulas across all built-in presets
        let usableAX = CGRect(x: 100, y: 50, width: 1800, height: 1000)
        let pOut: CGFloat = 10
        let gIn: CGFloat = 12
        let gaps = GapConfig(outerMarginPoints: Double(pOut), innerGapPoints: Double(gIn))

        for preset in DisplayPresetKind.allCases where preset != .custom {
            let layout = DisplayLayoutConfig(
                display: DisplaySignature(localizedName: "Test"),
                presetID: preset.rawValue,
                division: preset.defaultDivision
            )
            let zones = SnapGeometry.resolveZones(
                layout: layout,
                usableAXRect: usableAX,
                primaryScreenHeight: 1100,
                gaps: gaps
            )
            let expectedCount = preset.zoneCount
            expect(zones.count == expectedCount, "Preset \(preset.rawValue) zone count mismatch: \(zones.count) vs \(expectedCount)")

            // No zone overflows outer margins
            for z in zones {
                expect(z.frameInAX.minX >= usableAX.minX + pOut - 0.5, "\(preset.rawValue) minX overflow: \(z.frameInAX)")
                expect(z.frameInAX.maxX <= usableAX.maxX - pOut + 0.5, "\(preset.rawValue) maxX overflow: \(z.frameInAX)")
                expect(z.frameInAX.minY >= usableAX.minY + pOut - 0.5, "\(preset.rawValue) minY overflow: \(z.frameInAX)")
                expect(z.frameInAX.maxY <= usableAX.maxY - pOut + 0.5, "\(preset.rawValue) maxY overflow: \(z.frameInAX)")
            }

            if preset == .leftMainRightStack {
                let leftMain = zones[0]
                let topRight = zones[1]
                let bottomRight = zones[2]
                expect(abs((topRight.frameInAX.minX - leftMain.frameInAX.maxX) - gIn) <= 1.0, "leftMainRightStack horizontal gap mismatch")
                expect(abs((bottomRight.frameInAX.minY - topRight.frameInAX.maxY) - gIn) <= 1.0, "leftMainRightStack vertical gap mismatch")
                expect(abs(leftMain.frameInAX.height - (bottomRight.frameInAX.maxY - topRight.frameInAX.minY)) <= 1.0, "leftMainRightStack Left Main must span full usable height")
            } else if preset == .leftStackRightMain {
                let topLeft = zones[0]
                let bottomLeft = zones[1]
                let rightMain = zones[2]
                expect(abs((rightMain.frameInAX.minX - topLeft.frameInAX.maxX) - gIn) <= 1.0, "leftStackRightMain horizontal gap mismatch")
                expect(abs((bottomLeft.frameInAX.minY - topLeft.frameInAX.maxY) - gIn) <= 1.0, "leftStackRightMain vertical gap mismatch")
                expect(abs(rightMain.frameInAX.height - (bottomLeft.frameInAX.maxY - topLeft.frameInAX.minY)) <= 1.0, "leftStackRightMain Right Main must span full usable height")
            } else {
                // Adjacent horizontal & vertical cells maintain exact G_in gap
                let cols = preset.defaultDivision.columnWeights.count
                let rows = preset.defaultDivision.rowWeights.count
                if cols > 1 {
                    for c in 0..<(cols - 1) {
                        let leftCell = zones.first { $0.gridCoord == GridCellCoord(col: c, row: 0) }!
                        let rightCell = zones.first { $0.gridCoord == GridCellCoord(col: c + 1, row: 0) }!
                        let actualGap = rightCell.frameInAX.minX - leftCell.frameInAX.maxX
                        expect(abs(actualGap - gIn) <= 1.0, "\(preset.rawValue) col gap mismatch: \(actualGap) vs \(gIn)")
                    }
                }
                if rows > 1 {
                    for r in 0..<(rows - 1) {
                        let topCell = zones.first { $0.gridCoord == GridCellCoord(col: 0, row: r) }!
                        let bottomCell = zones.first { $0.gridCoord == GridCellCoord(col: 0, row: r + 1) }!
                        let actualGap = bottomCell.frameInAX.minY - topCell.frameInAX.maxY
                        expect(abs(actualGap - gIn) <= 1.0, "\(preset.rawValue) row gap mismatch: \(actualGap) vs \(gIn)")
                    }
                }
            }
        }

        // 4. Multi-cell span union collapses internal seams cleanly while preserving outer margins
        let thirds = DisplayPresetKind.thirds.defaultDivision
        if let spannedLeftTwoThirds = SnapGeometry.resolveSpannedZone(
            span: GridSpan(startCol: 0, endCol: 1, startRow: 0, endRow: 0),
            division: thirds,
            usableAXRect: usableAX,
            primaryScreenHeight: 1100,
            outerMargin: pOut,
            innerGap: gIn
        ), let rightOneThird = SnapGeometry.resolveSpannedZone(
            span: GridSpan(startCol: 2, endCol: 2, startRow: 0, endRow: 0),
            division: thirds,
            usableAXRect: usableAX,
            primaryScreenHeight: 1100,
            outerMargin: pOut,
            innerGap: gIn
        ) {
            expect(spannedLeftTwoThirds.frameInAX.minX == usableAX.minX + pOut, "Spanned left 2/3 must align with outer margin")
            expect(abs((rightOneThird.frameInAX.minX - spannedLeftTwoThirds.frameInAX.maxX) - gIn) <= 1.0, "Gap after spanned 2/3 to right 1/3 must equal gIn")
            expect(spannedLeftTwoThirds.id == "span:0:1:0:0", "Spanned zoneID mismatch: \(spannedLeftTwoThirds.id)")
        } else {
            failures.append("Failed to resolve spanned 2/3 zone")
        }

        // 5. Repeat-direction cycling steps (1/2 -> 2/3 -> 1/3)
        expect(abs(SnapDirectionAction.leftHalf.normalizedRect(forStep: 0).width - 0.5) < 0.01, "Step 0 width must be 1/2")
        expect(abs(SnapDirectionAction.leftHalf.normalizedRect(forStep: 1).width - (2.0 / 3.0)) < 0.01, "Step 1 width must be 2/3")
        expect(abs(SnapDirectionAction.leftHalf.normalizedRect(forStep: 2).width - (1.0 / 3.0)) < 0.01, "Step 2 width must be 1/3")
    }

    private static func testWindowSnapperMinSizeClampingAndDragLogic() {
        // 1. Normal shrink snap (1400 -> 700) succeeds; min-size overflow clamps origin strictly inside usable rect
        let usable = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let rightZone = CGRect(x: 724, y: 33, width: 708, height: 859)
        let normalShrink = SnapGeometry.clampFrameForMinimumSize(
            targetFrame: rightZone,
            actualSize: CGSize(width: 708, height: 859),
            usableRect: usable
        )
        expect(normalShrink == rightZone, "Normal shrink snap to 708pt wide must keep exact target origin (got \(normalShrink))")

        // App enforces 900x920 min size inside a 708x859 right-edge zone: origin must shift left/up to stay inside usable rect
        let minConstrained = SnapGeometry.clampFrameForMinimumSize(
            targetFrame: rightZone,
            actualSize: CGSize(width: 900, height: 920),
            usableRect: usable
        )
        expect(minConstrained.maxX <= usable.maxX, "Clamped maxX must not overflow right screen edge (got \(minConstrained.maxX) > \(usable.maxX))")
        expect(minConstrained.minX >= usable.minX, "Clamped minX must stay inside left screen edge")
        expect(minConstrained.minY >= usable.minY, "Clamped minY must stay below menu bar")

        // 2. Confirmed window-drag gate
        let initialWin = CGRect(x: 200, y: 150, width: 900, height: 600)
        expect(
            WindowDragMonitor.evaluateConfirmedWindowDrag(
                initialFrameAX: initialWin,
                currentFrameAX: CGRect(x: 215, y: 158, width: 900, height: 600)
            ) == .confirmedMove,
            "Origin movement with constant size must confirm window drag"
        )
        expect(
            WindowDragMonitor.evaluateConfirmedWindowDrag(
                initialFrameAX: initialWin,
                currentFrameAX: CGRect(x: 200, y: 150, width: 940, height: 600)
            ) == .rejectedResizeOrSelection,
            "Width change must reject drag snapping (window resize)"
        )
        expect(
            WindowDragMonitor.evaluateConfirmedWindowDrag(
                initialFrameAX: initialWin,
                currentFrameAX: initialWin
            ) == .pending,
            "Unchanged frame with zero pointer movement must stay pending"
        )
        expect(
            WindowDragMonitor.evaluateConfirmedWindowDrag(
                initialFrameAX: initialWin,
                currentFrameAX: initialWin,
                pointerDistance: 28
            ) == .pending,
            "Unchanged frame after >= 18pt pointer movement must remain pending so delayed Electron/custom-titlebar drags can confirm once the window moves"
        )
        expect(
            !MainWindowController.shared.ensureWindow().isMovableByWindowBackground,
            "ToolboxWindow must keep isMovableByWindowBackground=false so text selection never moves the window"
        )
        let snappedFrameForRestoreTest = CGRect(x: 0, y: 25, width: 720, height: 875)
        let preSnapFrameForRestoreTest = CGRect(x: 200, y: 150, width: 900, height: 600)
        expect(
            WindowDragMonitor.shouldTriggerMidDragSizeRestore(
                currentFrameAX: snappedFrameForRestoreTest,
                preSnapFrameAX: preSnapFrameForRestoreTest,
                dragDistance: 6
            ),
            "Confirmed drag >= 3pt away from a differently sized snapped frame must trigger mid-drag animated size restore"
        )
        expect(
            !WindowDragMonitor.shouldTriggerMidDragSizeRestore(
                currentFrameAX: snappedFrameForRestoreTest,
                preSnapFrameAX: preSnapFrameForRestoreTest,
                dragDistance: 2.5
            ),
            "Drag distance < 3pt must not trigger mid-drag size restore yet"
        )
        expect(
            !WindowDragMonitor.shouldTriggerMidDragSizeRestore(
                currentFrameAX: CGRect(x: 0, y: 25, width: 902, height: 598),
                preSnapFrameAX: preSnapFrameForRestoreTest,
                dragDistance: 12
            ),
            "Window already within 4pt of pre-snap size must skip mid-drag size restore"
        )
        expect(
            !WindowDragMonitor.shouldReleaseTopPullAwaySuppression(
                downPointAX: CGPoint(x: 600, y: 30),
                pointerAX: CGPoint(x: 620, y: 33),
                velocityY: 120,
                usableMinY: 25,
                topTriggerBand: 18
            ),
            "Diagonal downward pull away from top edge must keep top-edge suppression active"
        )
        expect(
            !WindowDragMonitor.shouldReleaseTopPullAwaySuppression(
                downPointAX: CGPoint(x: 600, y: 30),
                pointerAX: CGPoint(x: 625, y: 30),
                velocityY: 0,
                usableMinY: 25,
                topTriggerBand: 18
            ),
            "Horizontal drag inside top band must not prematurely activate Top Edge Panel"
        )
        expect(
            WindowDragMonitor.shouldReleaseTopPullAwaySuppression(
                downPointAX: CGPoint(x: 600, y: 30),
                pointerAX: CGPoint(x: 600, y: 55),
                velocityY: 150,
                usableMinY: 25,
                topTriggerBand: 18
            ),
            "Pulling clearly below top trigger band must release top pull-away suppression"
        )
        expect(
            WindowDragMonitor.shouldReleaseTopPullAwaySuppression(
                downPointAX: CGPoint(x: 600, y: 36),
                pointerAX: CGPoint(x: 600, y: 31),
                velocityY: -90,
                usableMinY: 25,
                topTriggerBand: 18
            ),
            "Intentionally pushing upward toward the top edge must release top pull-away suppression"
        )

        // 3. Inter-display pass-through suppression across shared seams vs outer boundaries
        let leftDisp = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let rightDisp = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let bothDisplays = [leftDisp, rightDisp]
        expect(
            WindowDragMonitor.shouldSuppressSharedEdgeSnap(
                pointerAX: CGPoint(x: 1502, y: 400),
                velocityX: 920,
                velocityY: 0,
                displayFrameAX: leftDisp,
                allDisplayFramesAX: bothDisplays
            ),
            "Fast rightward transit across shared seam into rightDisp must suppress outgoing edge snap"
        )
        expect(
            !WindowDragMonitor.shouldSuppressSharedEdgeSnap(
                pointerAX: CGPoint(x: 1502, y: 400),
                velocityX: 120,
                velocityY: 0,
                displayFrameAX: leftDisp,
                allDisplayFramesAX: bothDisplays
            ),
            "Slow deliberate approach near shared seam must allow edge snap"
        )
        expect(
            !WindowDragMonitor.shouldSuppressSharedEdgeSnap(
                pointerAX: CGPoint(x: 5, y: 400),
                velocityX: -1100,
                velocityY: 0,
                displayFrameAX: leftDisp,
                allDisplayFramesAX: bothDisplays
            ),
            "Fast transit against outer unshared left edge must NOT suppress snap"
        )

        // 4. Built-in template -> cell resolution & Maximize edge-to-edge behavior
        let dropDispSig = DisplaySignature(localizedName: "Drop Test Display")
        let dropDisp = ConnectedDisplay(
            displayID: 91,
            signature: dropDispSig,
            frameAppKit: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrameAppKit: CGRect(x: 0, y: 0, width: 1440, height: 875),
            frameAX: CGRect(x: 0, y: 0, width: 1440, height: 900),
            usableAppKit: CGRect(x: 0, y: 0, width: 1440, height: 875),
            usableAX: usable,
            safeAreaInsets: SafeAreaInsets(),
            isMain: true,
            primaryScreenHeight: 900
        )
        let halvesLayout = DisplayLayoutConfig(
            display: dropDispSig,
            presetID: DisplayPresetKind.halves.rawValue,
            division: DisplayPresetKind.halves.defaultDivision
        )
        for preset in DisplayPresetKind.builtInTemplates {
            for spacing in [GapConfig(), GapConfig(outerMarginPoints: 12, innerGapPoints: 12)] {
                let cells = SnapGeometry.resolveTemplateZones(
                    preset: preset,
                    usableAXRect: dropDisp.usableAX,
                    primaryScreenHeight: 900,
                    gaps: spacing
                )
                expect(
                    cells.count == preset.zoneCount,
                    "Template \(preset.label) must resolve to \(preset.zoneCount) cells (got \(cells.count))"
                )
                for (i, cell) in cells.enumerated() {
                    expect(
                        dropDisp.usableAX.insetBy(dx: -1, dy: -1).contains(cell.frameInAX),
                        "Template \(preset.label) cell \(i) must stay inside usableAXRect"
                    )
                    for j in (i + 1)..<cells.count {
                        let inter = cell.frameInAX.intersection(cells[j].frameInAX)
                        expect(
                            inter.isNull || inter.width <= 1 || inter.height <= 1,
                            "Template \(preset.label) cells \(i) and \(j) must not overlap"
                        )
                    }
                }
            }
        }
        let maximizeWithSpacing = SnapGeometry.resolveUniversalOrBuiltInZone(
            id: "universal:maximize",
            usableAXRect: dropDisp.usableAX,
            primaryScreenHeight: 900,
            gaps: GapConfig(outerMarginPoints: 16, innerGapPoints: 16)
        )
        expect(
            maximizeWithSpacing?.frameInAX == dropDisp.usableAX,
            "Maximize must always fill usableAXRect edge-to-edge even with 16pt Tile Spacing"
        )

        // 5. Top edge always Maximizes and bottom edge stays inert (while bottom corners still snap)
        let defaultDragCfg = DragSnapConfig()
        let topEdgeDefault = SnapGeometry.hitTestEdgeOrCorner(
            pointerAX: CGPoint(x: 720, y: 2),
            screenFrameAX: dropDisp.frameAX,
            usableAXRect: dropDisp.usableAX,
            primaryScreenHeight: 900,
            dragConfig: defaultDragCfg,
            gaps: GapConfig(),
            layout: halvesLayout
        )
        let bottomEdgeDefault = SnapGeometry.hitTestEdgeOrCorner(
            pointerAX: CGPoint(x: 720, y: 896),
            screenFrameAX: dropDisp.frameAX,
            usableAXRect: dropDisp.usableAX,
            primaryScreenHeight: 900,
            dragConfig: defaultDragCfg,
            gaps: GapConfig(),
            layout: halvesLayout
        )
        let bottomRightCorner = SnapGeometry.hitTestEdgeOrCorner(
            pointerAX: CGPoint(x: 1435, y: 895),
            screenFrameAX: dropDisp.frameAX,
            usableAXRect: dropDisp.usableAX,
            primaryScreenHeight: 900,
            dragConfig: defaultDragCfg,
            gaps: GapConfig(),
            layout: halvesLayout
        )
        expect(topEdgeDefault?.id == "universal:maximize", "Top edge drag must always target Maximize")
        expect(bottomEdgeDefault == nil, "Bottom edge drag must always stay inert")
        expect(bottomRightCorner?.id == "preset:bottom_right", "Bottom-right corner drag must still target Bottom Right")

        let leftDockUsable = CGRect(x: 80, y: 25, width: 1360, height: 875)
        let leftDockEdgeHit = SnapGeometry.hitTestEdgeOrCorner(
            pointerAX: CGPoint(x: 84, y: 450),
            screenFrameAX: dropDisp.frameAX,
            usableAXRect: leftDockUsable,
            primaryScreenHeight: 900,
            dragConfig: defaultDragCfg,
            gaps: GapConfig(),
            layout: halvesLayout
        )
        expect(leftDockEdgeHit?.id == "cell:0:0", "Left Dock boundary drag must snap to left zone (got \(String(describing: leftDockEdgeHit?.id)))")

        let rightDockUsable = CGRect(x: 0, y: 25, width: 1360, height: 875)
        let rightDockEdgeHit = SnapGeometry.hitTestEdgeOrCorner(
            pointerAX: CGPoint(x: 1354, y: 450),
            screenFrameAX: dropDisp.frameAX,
            usableAXRect: rightDockUsable,
            primaryScreenHeight: 900,
            dragConfig: defaultDragCfg,
            gaps: GapConfig(),
            layout: halvesLayout
        )
        expect(rightDockEdgeHit?.id == "cell:1:0", "Right Dock boundary drag must snap to right zone (got \(String(describing: rightDockEdgeHit?.id)))")

        expect(
            SnapGeometry.easeOutCubic(0) == 0
                && SnapGeometry.easeOutCubic(1) == 1
                && abs(SnapGeometry.easeOutCubic(0.5) - 0.875) < 0.0001,
            "easeOutCubic must match cubic ease-out curve at 0, 0.5, and 1"
        )
        let animRectStart = CGRect(x: 0, y: 25, width: 720, height: 875)
        let animRectEnd = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let animRectMid = SnapGeometry.interpolatedRect(from: animRectStart, to: animRectEnd, progress: 0.5)
        expect(
            SnapGeometry.interpolatedRect(from: animRectStart, to: animRectEnd, progress: 0) == animRectStart
                && animRectMid.width == 1350
                && SnapGeometry.interpolatedRect(from: animRectStart, to: animRectEnd, progress: 1) == animRectEnd,
            "interpolatedRect must interpolate smoothly between start and end frames"
        )
        expect(
            SnapGeometry.interpolatedSize(from: animRectStart.size, to: CGSize(width: 900, height: 600), progress: 1) == CGSize(width: 900, height: 600),
            "interpolatedSize at progress 1.0 must reach target size"
        )

        // 6. Zone min-size pre-flight evaluation (large-min-size app vs shrinkable 340x328 Toolbox window)
        let laptopUsable = CGRect(x: 0, y: 32, width: 1728, height: 1017)
        let largeMinApp = CGSize(width: 820, height: 588)
        let toolboxCompactMin = CGSize(width: 340, height: 328)
        let halfTarget = CGRect(x: 8, y: 40, width: 852, height: 1001)
        let thirdTarget = CGRect(x: 8, y: 40, width: 565, height: 1001)
        let bottomRightQuarterTarget = CGRect(x: 868, y: 545, width: 852, height: 496)
        expect(
            SnapGeometry.evaluateMinSizeFit(targetFrameAX: halfTarget, minSize: largeMinApp, usableAXRect: laptopUsable) == nil,
            "Half zone (852x1001) must fit 820x588 window without min-size warning"
        )
        expect(
            SnapGeometry.evaluateMinSizeFit(targetFrameAX: thirdTarget, minSize: toolboxCompactMin, usableAXRect: laptopUsable) == nil
                && SnapGeometry.evaluateMinSizeFit(targetFrameAX: bottomRightQuarterTarget, minSize: toolboxCompactMin, usableAXRect: laptopUsable) == nil,
            "Toolbox 340x328 min size must fit cleanly in laptop thirds and quarters"
        )
        let thirdWarning = SnapGeometry.evaluateMinSizeFit(targetFrameAX: thirdTarget, minSize: largeMinApp, usableAXRect: laptopUsable)
        expect(
            thirdWarning != nil && thirdWarning!.exceedsWidth && !thirdWarning!.exceedsHeight && thirdWarning!.clampedFrameAX.width == 820,
            "Third zone (565pt wide) must warn on width for 820x588 window (got \(String(describing: thirdWarning)))"
        )
        let quarterWarning = SnapGeometry.evaluateMinSizeFit(targetFrameAX: bottomRightQuarterTarget, minSize: largeMinApp, usableAXRect: laptopUsable)
        expect(
            quarterWarning != nil && !quarterWarning!.exceedsWidth && quarterWarning!.exceedsHeight && quarterWarning!.clampedFrameAX.height == 588 && quarterWarning!.clampedFrameAX.maxY <= laptopUsable.maxY,
            "Quarter zone (496pt tall) must warn on height and clamp inside usable rect (got \(String(describing: quarterWarning)))"
        )

        // 7. Hold-to-preview keyboard state cycling and modifier release checks
        let chord: [KeyModifier] = [.control, .option, .command]
        var kbState = KeyboardPreviewState(target: .directional(.leftHalf), requiredModifiers: chord)
        expect(kbState.directionalStep == 0, "Initial directional preview step must be 0")
        kbState.apply(nextTarget: .directional(.leftHalf), requiredModifiers: chord, cycleEnabled: true)
        expect(kbState.directionalStep == 1, "Second Left tap must advance preview step to 1 (2/3)")
        kbState.apply(nextTarget: .directional(.leftHalf), requiredModifiers: chord, cycleEnabled: true)
        expect(kbState.directionalStep == 2, "Third Left tap must advance preview step to 2 (1/3)")
        kbState.apply(nextTarget: .directional(.leftHalf), requiredModifiers: chord, cycleEnabled: true)
        expect(kbState.directionalStep == 0, "Fourth Left tap must wrap back to step 0 (1/2)")
        kbState.apply(nextTarget: .directional(.rightHalf), requiredModifiers: chord, cycleEnabled: true)
        expect(kbState.directionalAction == .rightHalf && kbState.directionalStep == 0, "Switching direction must reset step to 0")
        kbState.apply(nextTarget: .preset(id: "universal:maximize", fallbackName: "Maximize"), requiredModifiers: chord, cycleEnabled: true)
        expect(kbState.directionalAction == nil, "Preset target must clear directionalAction")
        expect(
            KeyboardPreviewState.modifiersStillHeld(chord, liveFlags: [.maskControl, .maskAlternate, .maskCommand]),
            "modifiersStillHeld must return true while all chord modifiers remain held"
        )
        expect(
            !KeyboardPreviewState.modifiersStillHeld(chord, liveFlags: [.maskControl, .maskCommand]),
            "modifiersStillHeld must return false when any chord modifier is released"
        )
        expect(
            !KeyboardPreviewState.modifiersStillHeld([], liveFlags: [.maskControl]),
            "modifiersStillHeld must return false for unmodified shortcuts"
        )
        expect(
            KeyboardSnapPreviewTap.isCancelKeyCode(UInt16(kVK_Delete))
                && KeyboardSnapPreviewTap.isCancelKeyCode(UInt16(kVK_ForwardDelete))
                && KeyboardSnapPreviewTap.isCancelKeyCode(UInt16(kVK_Escape))
                && KeyboardSnapPreviewTap.isCancelKeyCode(UInt16(kVK_ANSI_KeypadClear)),
            "KeyboardSnapPreviewTap.isCancelKeyCode must accept Delete, Forward Delete, Escape, and Keypad Clear"
        )
        expect(
            !KeyboardSnapPreviewTap.isCancelKeyCode(UInt16(kVK_LeftArrow))
                && !KeyboardSnapPreviewTap.isCancelKeyCode(UInt16(kVK_Return)),
            "KeyboardSnapPreviewTap.isCancelKeyCode must ignore directional and snap keys"
        )
        expect(
            WindowSnapperModule.shouldSuppressPostCancelRestore(now: 100.1, cancelUptime: 100.0)
                && !WindowSnapperModule.shouldSuppressPostCancelRestore(now: 100.5, cancelUptime: 100.0)
                && !WindowSnapperModule.shouldSuppressPostCancelRestore(now: 100.1, cancelUptime: 0),
            "shouldSuppressPostCancelRestore must guard briefly after cancel and expire after grace interval"
        )
    }

    private static func testWindowSnapperDisplayRegistryAndUndoStack() {
        // 1. DisplayRegistry matching: exact UUID, identical-monitor collision fallback, topology matching
        let builtin = DisplaySignature(
            uuidString: "UUID-BUILTIN",
            vendorNumber: 1552,
            modelNumber: 40998,
            serialNumber: 0,
            localizedName: "Built-in Retina Display",
            arrangementIndex: 0
        )
        let dellLeft = DisplaySignature(
            uuidString: "UUID-DELL-1",
            vendorNumber: 4268,
            modelNumber: 16800,
            serialNumber: 0,
            localizedName: "DELL U2723QE",
            arrangementIndex: 1
        )
        let dellRight = DisplaySignature(
            uuidString: "UUID-DELL-2",
            vendorNumber: 4268,
            modelNumber: 16800,
            serialNumber: 0,
            localizedName: "DELL U2723QE",
            arrangementIndex: 2
        )

        let candidates = [builtin, dellLeft, dellRight]
        expect(DisplayRegistry.matchDisplay(for: dellRight, among: candidates) == dellRight, "Exact UUID match must resolve dellRight")

        // Simulated Apple Silicon identical-monitor UUID swap after wake: UUID changed, slot/hardware matches
        let dellRightSwapped = DisplaySignature(
            uuidString: "UUID-NEW-SWAPPED",
            vendorNumber: 4268,
            modelNumber: 16800,
            serialNumber: 0,
            localizedName: "DELL U2723QE",
            arrangementIndex: 2
        )
        expect(
            DisplayRegistry.matchDisplay(for: dellRightSwapped, among: candidates) == dellRight,
            "Hardware tuple + arrangementIndex fallback must resolve right-side identical Dell monitor"
        )
        expect(
            DisplayRegistry.topologiesMatch(bound: [builtin, dellLeft], connected: [dellLeft, builtin]),
            "topologiesMatch must match connected displays regardless of array order"
        )
        expect(
            !DisplayRegistry.topologiesMatch(bound: [builtin, dellLeft, dellRight], connected: [builtin]),
            "topologiesMatch must return false when external displays are unplugged"
        )

        // 2. Atomic Undo stack: single snap, grouped Profile batch, drag-away lookup, maxDepth eviction
        var stack = WindowSnapUndoStack(maxDepth: 5)
        let preDragRect = CGRect(x: 120, y: 120, width: 1000, height: 700)
        let snappedRect = CGRect(x: 0, y: 32, width: 720, height: 900)
        let item1 = WindowSnapUndoItem(
            pid: 1001,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "Docs",
            initialFrameAX: preDragRect,
            afterFrameAX: snappedRect,
            zoneName: "Left Half"
        )
        stack.pushSingle(item1)

        if let foundPreSnap = stack.latestPreSnapItem(forPID: 1001, windowTitle: "Docs", currentFrameAX: snappedRect) {
            expect(foundPreSnap.initialFrameAX == preDragRect, "Pre-snap drag-away lookup must return initialFrameAX captured before drag")
        } else {
            failures.append("latestPreSnapItem failed to match recently snapped window")
        }

        let profA = WindowSnapUndoItem(
            pid: 2001,
            bundleIdentifier: "com.microsoft.VSCode",
            appName: "VS Code",
            windowTitle: "Toolbox",
            initialFrameAX: CGRect(x: 50, y: 50, width: 900, height: 650),
            afterFrameAX: CGRect(x: 0, y: 32, width: 1100, height: 900),
            zoneName: "Left 2/3"
        )
        let profB = WindowSnapUndoItem(
            pid: 2002,
            bundleIdentifier: "com.apple.Terminal",
            appName: "Terminal",
            windowTitle: "zsh",
            initialFrameAX: CGRect(x: 300, y: 200, width: 600, height: 400),
            afterFrameAX: CGRect(x: 1108, y: 32, width: 540, height: 900),
            zoneName: "Right 1/3"
        )
        stack.pushBatch(title: "Profile 'Coding'", isProfileBatch: true, items: [profA, profB])
        expect(stack.batches.count == 2, "Stack should hold single + profile batch")

        let poppedProfile = stack.popUndo()
        expect(poppedProfile?.isProfileBatch == true && poppedProfile?.items.count == 2, "popUndo must pop entire multi-window profile batch atomically")
        expect(stack.popUndo()?.items.first?.initialFrameAX == preDragRect, "Second popUndo must return Safari pre-drag frame")
        expect(stack.popUndo() == nil, "Empty stack must return nil")

        // Eviction at maxDepth = 5
        for i in 0..<8 {
            stack.pushSingle(WindowSnapUndoItem(
                pid: Int32(3000 + i),
                bundleIdentifier: "com.test.app",
                appName: "App \(i)",
                windowTitle: "W\(i)",
                initialFrameAX: preDragRect,
                afterFrameAX: snappedRect,
                zoneName: "Zone \(i)"
            ))
        }
        expect(stack.batches.count == 5, "Undo stack must enforce maxDepth=5 (got \(stack.batches.count))")
        expect(stack.batches.first?.items.first?.zoneName == "Zone 7", "Newest batch must stay at top of undo stack")

        // 3. PreSnapFrameStore: remembers original unsnapped size across chained snaps, origin shift & title change
        var preSnapStore = PreSnapFrameStore()
        let origRect = CGRect(x: 180, y: 140, width: 800, height: 600)
        let leftHalfRect = CGRect(x: 0, y: 25, width: 720, height: 900)
        let topMaxRect = CGRect(x: 0, y: 25, width: 1440, height: 900)
        let testBox = AXElementBox(AXUIElementCreateApplication(4242), selfWindowNumber: 777)

        let snap1Win = DiscoveredAXWindow(
            pid: 4242,
            windowNumber: 777,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            title: "Original Tab",
            frameAX: origRect,
            isFullscreen: false,
            isMinimized: false,
            elementBox: testBox
        )
        let effOrig1 = preSnapStore.lookupOriginalFrameIfSnapped(for: snap1Win) ?? snap1Win.frameAX
        preSnapStore.recordSnap(window: snap1Win, preSnapFrameAX: effOrig1, appliedFrameAX: leftHalfRect)

        // Chained second snap from Left Half -> Top Maximize must preserve original 800x600 size
        let snap2Win = DiscoveredAXWindow(
            pid: 4242,
            windowNumber: 777,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            title: "Original Tab",
            frameAX: leftHalfRect,
            isFullscreen: false,
            isMinimized: false,
            elementBox: testBox
        )
        let effOrig2 = preSnapStore.lookupOriginalFrameIfSnapped(for: snap2Win) ?? snap2Win.frameAX
        expect(effOrig2 == origRect, "Chained snap must preserve initial 800x600 frame (got \(effOrig2))")
        preSnapStore.recordSnap(window: snap2Win, preSnapFrameAX: effOrig2, appliedFrameAX: topMaxRect)

        // Dragging away: origin moved by 120pt and title changed, size still Top Maximize -> must return 800x600
        let draggedAwayWin = DiscoveredAXWindow(
            pid: 4242,
            windowNumber: 777,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            title: "Renamed Tab",
            frameAX: CGRect(x: topMaxRect.minX + 120, y: topMaxRect.minY + 120, width: topMaxRect.width, height: topMaxRect.height),
            isFullscreen: false,
            isMinimized: false,
            elementBox: testBox
        )
        expect(
            preSnapStore.lookupOriginalFrameIfSnapped(for: draggedAwayWin) == origRect,
            "PreSnapFrameStore must look up original 800x600 frame despite 120pt origin shift and title change"
        )

        preSnapStore.clearRecord(for: draggedAwayWin)
        expect(
            preSnapStore.lookupOriginalFrameIfSnapped(for: draggedAwayWin) == nil,
            "PreSnapFrameStore.clearRecord must clear restored window record"
        )

        // 4. Detached release origin alignment & idempotent hideDragOverlays
        let usableArea = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let inBoundsFrame = CGRect(x: -100, y: 120, width: 800, height: 600)
        expect(
            WindowDragMonitor.detachedReleaseOriginIfNeeded(
                liveFrameAX: inBoundsFrame,
                releasePointAX: CGPoint(x: 420, y: 140),
                horizontalGrabRatio: 0.5,
                usableAXRect: usableArea
            ) == nil,
            "detachedReleaseOriginIfNeeded must return nil when pointer remains within restored window bounds"
        )

        let shrunkLeftFrame = CGRect(x: 0, y: 160, width: 600, height: 500)
        let detachedAligned = WindowDragMonitor.detachedReleaseOriginIfNeeded(
            liveFrameAX: shrunkLeftFrame,
            releasePointAX: CGPoint(x: 1220, y: 180),
            horizontalGrabRatio: 0.85,
            usableAXRect: usableArea
        )
        expect(
            detachedAligned == CGPoint(x: 710, y: 160),
            "detachedReleaseOriginIfNeeded must re-center horizontally under detached cursor while preserving liveFrameAX.minY (got \(String(describing: detachedAligned)))"
        )

        ZoneOverlayController.shared.hideDragOverlays()
        ZoneOverlayController.shared.hideDragOverlays()
        expect(
            !ZoneOverlayController.shared.anyPassivePanelIsVisibleForTesting(),
            "Repeated hideDragOverlays must leave passive overlay panels hidden"
        )
    }

    private static func testWindowSnapperConfigHotKeysProfilesAndLifecycle() {
        // 1. Config defaults, migration from schema 10 -> 11, and lenient partial decode
        let defaultCfg = ToolboxConfig()
        expect(defaultCfg.schemaVersion == 15, "ToolboxConfig schemaVersion must be 15")
        expect(!defaultCfg.windowSnapper.enabled, "WindowSnapper should default to disabled")
        expect(
            defaultCfg.windowSnapper.gaps.outerMarginPoints == 0 && defaultCfg.windowSnapper.gaps.innerGapPoints == 0,
            "Default WindowSnapper Tile Spacing must be 0 pt flush"
        )
        expect(defaultCfg.windowSnapper.hotKeys == .toolboxSafe, "Default WindowSnapper hotkeys must use conflict-free Toolbox Safe (Ctrl+Opt+Cmd)")

        let legacyV10 = "{\"schemaVersion\": 10, \"general\": {\"appEnabled\": true}}"
        if let data = legacyV10.data(using: .utf8),
           let migrated = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(migrated.schemaVersion == 15, "v10 config must upgrade to schemaVersion 15")
            expect(!migrated.windowSnapper.enabled, "Migrated windowSnapper.enabled must default to false")
            expect(
                migrated.windowSnapper.gaps.outerMarginPoints == 0 && migrated.windowSnapper.gaps.innerGapPoints == 0,
                "Migrated outerMarginPoints and innerGapPoints must default to 0"
            )
        } else {
            failures.append("Failed to decode legacy v10 config")
        }

        if let neutralData = "{\"useAccentTint\": false}".data(using: .utf8),
           let neutralStyle = try? JSONDecoder().decode(OverlayStyleConfig.self, from: neutralData),
           let indigoData = "{\"useAccentTint\": true}".data(using: .utf8),
           let indigoStyle = try? JSONDecoder().decode(OverlayStyleConfig.self, from: indigoData),
           let tealData = "{\"tintColor\": \"teal\", \"useAccentTint\": true}".data(using: .utf8),
           let tealStyle = try? JSONDecoder().decode(OverlayStyleConfig.self, from: tealData) {
            expect(neutralStyle.tintColor == .neutral, "Legacy useAccentTint=false must decode to .neutral")
            expect(indigoStyle.tintColor == .indigo, "Legacy useAccentTint=true must decode to .indigo")
            expect(tealStyle.tintColor == .teal, "Explicit tintColor=teal must decode to .teal")
        } else {
            failures.append("Failed to decode OverlayStyleConfig legacy/tintColor variants")
        }
        expect(
            OverlayStyleConfig(fillOpacity: 0.0).fillOpacity == 0.0,
            "OverlayStyleConfig must preserve 0% outline-only fill opacity"
        )
        expect(
            OverlayStyleConfig(borderWidthPoints: 1.0).borderWidthPoints == 1.0
                && OverlayStyleConfig(borderWidthPoints: 7.0).borderWidthPoints == 7.0
                && OverlayStyleConfig(borderWidthPoints: 12.0).borderWidthPoints == 8.0,
            "OverlayStyleConfig must preserve Thin (1 pt) through Bold (7 pt) border widths and clamp at 8 pt"
        )
        expect(
            WindowAnimationSpeed.off.snapDuration == 0
                && WindowAnimationSpeed.snappy.snapDuration <= 0.12
                && WindowAnimationSpeed.smooth.snapDuration >= 0.20
                && WindowAnimationSpeed.gentle.snapDuration >= 0.40
                && WindowAnimationSpeed.snappy.snapDuration < WindowAnimationSpeed.smooth.snapDuration
                && WindowAnimationSpeed.smooth.snapDuration < WindowAnimationSpeed.gentle.snapDuration,
            "WindowAnimationSpeed durations must have a clear spread from off to gentle"
        )
        expect(
            defaultCfg.windowSnapper.animateWindowTransitions && defaultCfg.windowSnapper.windowAnimationSpeed == .smooth,
            "WindowSnapperConfig must default windowAnimationSpeed to .smooth"
        )
        if let offData = "{\"animateWindowTransitions\": false}".data(using: .utf8),
           let offCfg = try? JSONDecoder().decode(WindowSnapperConfig.self, from: offData),
           let snappyData = "{\"windowAnimationSpeed\": \"snappy\"}".data(using: .utf8),
           let snappyCfg = try? JSONDecoder().decode(WindowSnapperConfig.self, from: snappyData) {
            expect(offCfg.windowAnimationSpeed == .off && !offCfg.animateWindowTransitions, "Legacy animateWindowTransitions=false must decode to .off")
            expect(snappyCfg.windowAnimationSpeed == .snappy && snappyCfg.animateWindowTransitions, "Explicit windowAnimationSpeed=snappy must decode cleanly")
        } else {
            failures.append("Failed to decode WindowAnimationSpeed legacy/explicit variants")
        }

        let legacyKeyJSON = """
        {
          "schemaVersion": 11,
          "general": {
            "menuBarModuleOrder": ["window_snapping", "clipboard"],
            "menuBarHiddenModules": ["window_snapping"]
          },
          "windowSnapping": {
            "enabled": true,
            "gaps": { "outerMarginPoints": 14 }
          }
        }
        """
        if let data = legacyKeyJSON.data(using: .utf8),
           let decodedLegacy = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(decodedLegacy.windowSnapper.enabled, "Legacy windowSnapping key must migrate to windowSnapper.enabled")
            expect(decodedLegacy.windowSnapper.gaps.outerMarginPoints == 14, "Legacy windowSnapping.gaps must migrate to windowSnapper.gaps")
            expect(decodedLegacy.general.menuBarModuleOrder.first == "window_snapper", "Legacy menuBarModuleOrder must migrate window_snapping -> window_snapper")
            expect(decodedLegacy.general.menuBarHiddenModules == ["window_snapper"], "Legacy menuBarHiddenModules must migrate window_snapping -> window_snapper")
        } else {
            failures.append("Failed to decode legacy windowSnapping JSON config")
        }

        var roundTripCfg = ToolboxConfig()
        roundTripCfg.windowSnapper.enabled = true
        roundTripCfg.windowSnapper.windowAnimationSpeed = .gentle
        roundTripCfg.windowSnapper.gaps.outerMarginPoints = 12
        roundTripCfg.windowSnapper.overlayStyle.fillOpacity = 0.0
        roundTripCfg.windowSnapper.overlayStyle.borderWidthPoints = 3.0
        roundTripCfg.windowSnapper.hotKeys = .rectangleStyle
        roundTripCfg.windowSnapper.profiles = WorkspaceProfile.defaultTemplates
        roundTripCfg.windowSnapper.restorePreviousWorkspaceOnShortcutToggle = false
        roundTripCfg.windowSnapper.displayConnectMode = .alwaysExtend
        roundTripCfg.windowSnapper.autoApplyProfileID = "template-coding-split"
        roundTripCfg.windowSnapper.swapExternalDisplays = true
        var multiVariantProfile = WorkspaceProfile(
            id: "multi-var-prof",
            name: "Multi-Screen Profile",
            maxDisplayCount: 3,
            displayVariants: [
                ProfileDisplayVariant(
                    displayCount: 1,
                    slotLayouts: [ProfileDisplaySlotLayout(role: .main, presetID: DisplayPresetKind.halves.rawValue)],
                    appRules: [ProfileAppRule(bundleIdentifier: "com.apple.Terminal", appName: "Terminal", targetDisplay: .main, targetZoneID: "cell:0:0")]
                ),
                ProfileDisplayVariant(
                    displayCount: 2,
                    slotLayouts: [
                        ProfileDisplaySlotLayout(role: .main, presetID: DisplayPresetKind.maximized.rawValue),
                        ProfileDisplaySlotLayout(role: .external1, presetID: DisplayPresetKind.halves.rawValue)
                    ],
                    appRules: [
                        ProfileAppRule(bundleIdentifier: "com.apple.Terminal", appName: "Terminal", targetDisplay: .main, targetZoneID: "cell:0:0"),
                        ProfileAppRule(bundleIdentifier: "com.apple.Safari", appName: "Safari", targetDisplay: .externalSlot(0), targetZoneID: "cell:1:0")
                    ]
                ),
                ProfileDisplayVariant(
                    displayCount: 3,
                    slotLayouts: [
                        ProfileDisplaySlotLayout(role: .main, presetID: DisplayPresetKind.maximized.rawValue),
                        ProfileDisplaySlotLayout(role: .external1, presetID: DisplayPresetKind.halves.rawValue),
                        ProfileDisplaySlotLayout(role: .external2, presetID: DisplayPresetKind.thirds.rawValue)
                    ],
                    appRules: [
                        ProfileAppRule(bundleIdentifier: "com.apple.Terminal", appName: "Terminal", targetDisplay: .main, targetZoneID: "cell:0:0"),
                        ProfileAppRule(bundleIdentifier: "com.apple.Safari", appName: "Safari", targetDisplay: .externalSlot(0), targetZoneID: "cell:0:0"),
                        ProfileAppRule(bundleIdentifier: "com.apple.Notes", appName: "Notes", targetDisplay: .externalSlot(1), targetZoneID: "cell:2:0")
                    ]
                )
            ]
        )
        multiVariantProfile.ensureVariantsUpToMaxDisplayCount()
        roundTripCfg.windowSnapper.profiles.append(multiVariantProfile)

        expect(
            ToolboxConfig().windowSnapper.restorePreviousWorkspaceOnShortcutToggle,
            "WindowSnapperConfig.restorePreviousWorkspaceOnShortcutToggle must default to true"
        )
        expect(
            ToolboxConfig().windowSnapper.displayConnectMode == .systemDefault
                && ToolboxConfig().windowSnapper.autoApplyProfileID == nil
                && !ToolboxConfig().windowSnapper.swapExternalDisplays,
            "WindowSnapperConfig display connect defaults must be systemDefault, nil autoApplyProfileID, and swapExternalDisplays=false"
        )
        if let encoded = try? JSONEncoder().encode(roundTripCfg),
           let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: encoded) {
            expect(decoded.windowSnapper == roundTripCfg.windowSnapper, "WindowSnapperConfig Codable round-trip mismatch")
            expect(
                !decoded.windowSnapper.restorePreviousWorkspaceOnShortcutToggle,
                "restorePreviousWorkspaceOnShortcutToggle=false must round-trip cleanly"
            )
            expect(
                decoded.windowSnapper.displayConnectMode == .alwaysExtend
                    && decoded.windowSnapper.autoApplyProfileID == "template-coding-split"
                    && decoded.windowSnapper.swapExternalDisplays,
                "DisplayConnectMode, autoApplyProfileID, and swapExternalDisplays must round-trip cleanly"
            )
        } else {
            failures.append("WindowSnapperConfig Codable round-trip failed")
        }

        // Multi-display variant resolution & logical display role mapping tests
        expect(
            multiVariantProfile.resolvedVariant(forDisplayCount: 1)?.displayCount == 1
                && multiVariantProfile.resolvedVariant(forDisplayCount: 2)?.displayCount == 2
                && multiVariantProfile.resolvedVariant(forDisplayCount: 3)?.displayCount == 3
                && multiVariantProfile.resolvedVariant(forDisplayCount: 4)?.displayCount == 3,
            "resolvedVariant(forDisplayCount:) must resolve 1, 2, 3 and clamp 4->3"
        )
        let legacyProfile = WorkspaceProfile.defaultTemplates[0]
        expect(
            legacyProfile.resolvedVariant(forDisplayCount: 2) == nil
                && legacyProfile.effectiveAppRules(forDisplayCount: 2) == legacyProfile.appRules,
            "Legacy profile without displayVariants must fall back to appRules"
        )

        let makeFakeDisplay: (CGDirectDisplayID, String, Bool, CGFloat) -> ConnectedDisplay = { id, name, isMain, xOrigin in
            ConnectedDisplay(
                displayID: id,
                signature: DisplaySignature(localizedName: name, arrangementIndex: Int(id)),
                frameAppKit: CGRect(x: xOrigin, y: 0, width: 1920, height: 1080),
                visibleFrameAppKit: CGRect(x: xOrigin, y: 0, width: 1920, height: 1055),
                frameAX: CGRect(x: xOrigin, y: 0, width: 1920, height: 1080),
                usableAppKit: CGRect(x: xOrigin, y: 0, width: 1920, height: 1055),
                usableAX: CGRect(x: xOrigin, y: 25, width: 1920, height: 1055),
                safeAreaInsets: SafeAreaInsets(),
                isMain: isMain,
                primaryScreenHeight: 1080
            )
        }
        let dMain = makeFakeDisplay(1, "Built-in", true, 0)
        let dExtA = makeFakeDisplay(2, "Ext A", false, 1920)
        let dExtB = makeFakeDisplay(3, "Ext B", false, 3840)

        let rolesDefault = DisplayRegistry.assignLogicalRoles(for: [dMain, dExtA, dExtB], swapExternalDisplays: false)
        expect(
            rolesDefault[.main]?.displayID == 1
                && rolesDefault[.external1]?.displayID == 2
                && rolesDefault[.external2]?.displayID == 3,
            "assignLogicalRoles(swap: false) must map Main=1, Ext1=2, Ext2=3"
        )
        let rolesSwapped = DisplayRegistry.assignLogicalRoles(for: [dMain, dExtA, dExtB], swapExternalDisplays: true)
        expect(
            rolesSwapped[.main]?.displayID == 1
                && rolesSwapped[.external1]?.displayID == 3
                && rolesSwapped[.external2]?.displayID == 2,
            "assignLogicalRoles(swap: true) must swap External 1 and External 2"
        )

        let resolvedExt1Default = ProfileEngine.resolveTargetDisplay(
            for: .externalSlot(0),
            fallback: .moveToMainDisplay,
            displays: [dMain, dExtA, dExtB],
            swapExternalDisplays: false
        )
        let resolvedExt1Swapped = ProfileEngine.resolveTargetDisplay(
            for: .externalSlot(0),
            fallback: .moveToMainDisplay,
            displays: [dMain, dExtA, dExtB],
            swapExternalDisplays: true
        )
        let resolvedExtFallback = ProfileEngine.resolveTargetDisplay(
            for: .externalSlot(0),
            fallback: .moveToMainDisplay,
            displays: [dMain],
            swapExternalDisplays: false
        )
        expect(
            resolvedExt1Default?.display.displayID == 2
                && resolvedExt1Default?.usedFallback == false
                && resolvedExt1Swapped?.display.displayID == 3
                && resolvedExtFallback?.display.displayID == 1
                && resolvedExtFallback?.usedFallback == true,
            "resolveTargetDisplay must route .externalSlot(0) with swap and fallback to main when disconnected"
        )

        var previewCfg = WindowSnapperConfig()
        let preview1 = ProfileEngine.buildDryRunPreview(
            profile: multiVariantProfile,
            displays: [dMain],
            visibleWindows: [],
            runningBundleIDs: [],
            config: previewCfg
        )
        let preview3 = ProfileEngine.buildDryRunPreview(
            profile: multiVariantProfile,
            displays: [dMain, dExtA, dExtB],
            visibleWindows: [],
            runningBundleIDs: [],
            config: previewCfg
        )
        previewCfg.swapExternalDisplays = true
        let preview3Swapped = ProfileEngine.buildDryRunPreview(
            profile: multiVariantProfile,
            displays: [dMain, dExtA, dExtB],
            visibleWindows: [],
            runningBundleIDs: [],
            config: previewCfg
        )
        expect(
            preview1[1]?.count == 1
                && preview3[1]?.first?.bundleIdentifier == "com.apple.Terminal"
                && preview3[2]?.first?.bundleIdentifier == "com.apple.Safari"
                && preview3[3]?.first?.bundleIdentifier == "com.apple.Notes"
                && preview3Swapped[3]?.first?.bundleIdentifier == "com.apple.Safari"
                && preview3Swapped[2]?.first?.bundleIdentifier == "com.apple.Notes",
            "buildDryRunPreview must select 1- vs 3-display variant and respect swapExternalDisplays"
        )

        let dupRules = [
            ProfileAppRule(bundleIdentifier: "com.google.antigravity", appName: "Antigravity", targetDisplay: .main, targetZoneID: "cell:0:0"),
            ProfileAppRule(bundleIdentifier: "com.microsoft.VSCode", appName: "Code", targetDisplay: .main, targetZoneID: "cell:0:0"),
            ProfileAppRule(bundleIdentifier: "com.apple.Safari", appName: "Safari", targetDisplay: .externalSlot(0), targetZoneID: "cell:0:0")
        ]
        let deduped = ProfileDisplayVariant.deduplicatedRules(dupRules)
        expect(
            deduped.count == 2
                && deduped[0].bundleIdentifier == "com.google.antigravity"
                && deduped[1].bundleIdentifier == "com.apple.Safari",
            "deduplicatedRules must keep first rule per (role, zoneID) and preserve distinct roles"
        )

        var legacyTwoDisplayProfile = WorkspaceProfile(
            name: "Legacy 2-Display",
            appRules: [
                ProfileAppRule(bundleIdentifier: "com.google.antigravity", appName: "Antigravity", targetDisplay: .main, targetZoneID: "cell:0:0"),
                ProfileAppRule(bundleIdentifier: "com.apple.Safari", appName: "Safari", targetDisplay: .anyExternal, targetZoneID: "cell:0:0")
            ]
        )
        legacyTwoDisplayProfile.ensureVariantsUpToMaxDisplayCount()
        expect(
            legacyTwoDisplayProfile.maxDisplayCount == 2
                && legacyTwoDisplayProfile.effectiveAppRules(forDisplayCount: 1).count == 1
                && legacyTwoDisplayProfile.effectiveAppRules(forDisplayCount: 1).first?.bundleIdentifier == "com.google.antigravity"
                && legacyTwoDisplayProfile.effectiveAppRules(forDisplayCount: 2).count == 2,
            "ensureVariantsUpToMaxDisplayCount must keep .main rules in Variant 1 and move external rules to Variant 2"
        )

        let usable = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let leftHalf = CGRect(x: 0, y: 25, width: 720, height: 875)
        let rightHalf = CGRect(x: 720, y: 25, width: 720, height: 875)
        let slideInLeft = SnapGeometry.slideInStartFrame(for: leftHalf, inside: usable)
        let slideInRight = SnapGeometry.slideInStartFrame(for: rightHalf, inside: usable)
        let slideInMax = SnapGeometry.slideInStartFrame(for: usable, inside: usable)
        let slideOutLeft = SnapGeometry.slideOutTargetFrame(for: leftHalf, inside: usable)
        let slideOutRight = SnapGeometry.slideOutTargetFrame(for: rightHalf, inside: usable)
        expect(
            slideInLeft.minX < leftHalf.minX
                && slideInRight.minX > rightHalf.minX
                && slideInMax.minY > usable.minY
                && slideOutLeft.minX < leftHalf.minX
                && slideOutRight.minX > rightHalf.minX,
            "slideInStartFrame and slideOutTargetFrame must offset left/right/maximized frames in expected directions"
        )

        HUDToast.shared.showLoading(
            title: "Display Detected",
            subtitle: "Loading Work…",
            tint: .indigo
        )
        expect(
            HUDToast.shared.panelForTesting?.isVisible == true,
            "HUDToast.showLoading must present the floating HUD panel"
        )
        let twoLineSize = HUDToast.measuredSize(
            title: "Work",
            subtitle: "2 Displays · 3 windows placed",
            symbol: "checkmark.circle.fill"
        )
        expect(
            twoLineSize.height >= 50,
            "HUDToast with subtitle must size taller than single-line pill"
        )
        HUDToast.shared.dismiss()
        expect(
            HUDToast.shared.panelForTesting?.isVisible != true,
            "HUDToast.dismiss must hide the loading HUD panel"
        )

        expect(
            !DisplayRegistry.shouldAnnounceReconfigurationBegan(
                flags: .beginConfigurationFlag,
                isScreenLocked: false,
                isDisplayAsleep: false,
                inUnlockSettleWindow: false
            ).announce
                && !DisplayRegistry.shouldAnnounceReconfigurationBegan(
                    flags: .setModeFlag,
                    isScreenLocked: false,
                    isDisplayAsleep: false,
                    inUnlockSettleWindow: false
                ).announce
                && !DisplayRegistry.shouldAnnounceReconfigurationBegan(
                    flags: .desktopShapeChangedFlag,
                    isScreenLocked: false,
                    isDisplayAsleep: false,
                    inUnlockSettleWindow: false
                ).announce
                && !DisplayRegistry.shouldAnnounceReconfigurationBegan(
                    flags: .addFlag,
                    isScreenLocked: true,
                    isDisplayAsleep: false,
                    inUnlockSettleWindow: false
                ).announce
                && !DisplayRegistry.shouldAnnounceReconfigurationBegan(
                    flags: .removeFlag,
                    isScreenLocked: false,
                    isDisplayAsleep: true,
                    inUnlockSettleWindow: false
                ).announce
                && !DisplayRegistry.shouldAnnounceReconfigurationBegan(
                    flags: .addFlag,
                    isScreenLocked: false,
                    isDisplayAsleep: false,
                    inUnlockSettleWindow: true
                ).announce,
            "DisplayRegistry must not announce display reconfiguration during beginConfiguration, non-topology changes, lock, sleep, or unlock settle window"
        )

        let addDecision = DisplayRegistry.shouldAnnounceReconfigurationBegan(
            flags: .addFlag,
            isScreenLocked: false,
            isDisplayAsleep: false,
            inUnlockSettleWindow: false
        )
        let removeDecision = DisplayRegistry.shouldAnnounceReconfigurationBegan(
            flags: .removeFlag,
            isScreenLocked: false,
            isDisplayAsleep: false,
            inUnlockSettleWindow: false
        )
        expect(
            addDecision.announce && !addDecision.isRemoved
                && removeDecision.announce && removeDecision.isRemoved,
            "DisplayRegistry must announce add/remove reconfiguration when unlocked, awake, and settled"
        )

        let clamshellUnlock = DisplayRegistry.nextLockSleepStateOnActiveOrWake(
            isScreenLocked: true,
            isDisplayAsleep: true,
            isLockEvent: true
        )
        let wakeWhileLocked = DisplayRegistry.nextLockSleepStateOnActiveOrWake(
            isScreenLocked: true,
            isDisplayAsleep: true,
            isLockEvent: false
        )
        let wakeWhileUnlocked = DisplayRegistry.nextLockSleepStateOnActiveOrWake(
            isScreenLocked: false,
            isDisplayAsleep: true,
            isLockEvent: false
        )
        expect(
            !clamshellUnlock.isScreenLocked && !clamshellUnlock.isDisplayAsleep && clamshellUnlock.shouldScheduleReconcile
                && wakeWhileLocked.isScreenLocked && !wakeWhileLocked.isDisplayAsleep && !wakeWhileLocked.shouldScheduleReconcile
                && !wakeWhileUnlocked.isScreenLocked && !wakeWhileUnlocked.isDisplayAsleep && wakeWhileUnlocked.shouldScheduleReconcile,
            "DisplayRegistry must clear sleep state on unlock for clamshell wake and defer reconcile until unlocked"
        )

        let seededEngine = ProfileEngine(axController: AXWindowController())
        let seededDisplay = ConnectedDisplay(
            displayID: 42,
            signature: DisplaySignature(
                uuidString: "SEED-TEST-UUID",
                vendorNumber: 1,
                modelNumber: 2,
                serialNumber: 3,
                localizedName: "Test Display",
                arrangementIndex: 0
            ),
            frameAppKit: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrameAppKit: CGRect(x: 0, y: 0, width: 1440, height: 875),
            frameAX: CGRect(x: 0, y: 0, width: 1440, height: 900),
            usableAppKit: CGRect(x: 0, y: 0, width: 1440, height: 875),
            usableAX: CGRect(x: 0, y: 25, width: 1440, height: 875),
            safeAreaInsets: SafeAreaInsets(),
            isMain: true,
            primaryScreenHeight: 900
        )
        seededEngine.seedCurrentTopology(connectedDisplays: [seededDisplay], swapExternalDisplays: false)
        var seededCfg = WindowSnapperConfig()
        let testProfile = WorkspaceProfile(id: "test-auto-profile", name: "Test Profile")
        seededCfg.profiles = [testProfile]
        seededCfg.autoApplyProfileID = testProfile.id
        seededEngine.handleDisplaysReconfigured(
            connectedDisplays: [seededDisplay],
            config: seededCfg
        ) { _ in }
        expect(
            seededEngine.lastAutoTriggeredTopologyKey != nil && !seededEngine.isApplyingProfile,
            "ProfileEngine.seedCurrentTopology must prevent handleDisplaysReconfigured from auto-applying when topology is unchanged"
        )

        expect(
            DisplayRegistry.debounceDelay(inUnlockSettleWindow: true) == 1.5
                && DisplayRegistry.debounceDelay(inUnlockSettleWindow: false) == 1.0,
            "DisplayRegistry.debounceDelay must preserve 1.5s settle delay during unlock/wake window"
        )

        let keyBeforeEmpty = seededEngine.lastAutoTriggeredTopologyKey
        seededEngine.handleDisplaysReconfigured(
            connectedDisplays: [],
            config: seededCfg
        ) { _ in }
        expect(
            seededEngine.lastAutoTriggeredTopologyKey == keyBeforeEmpty,
            "ProfileEngine.handleDisplaysReconfigured must ignore transient empty display lists"
        )

        let extDisplay = ConnectedDisplay(
            displayID: 43,
            signature: DisplaySignature(
                uuidString: "SEED-EXT-UUID",
                vendorNumber: 1,
                modelNumber: 3,
                serialNumber: 4,
                localizedName: "External Display",
                arrangementIndex: 1
            ),
            frameAppKit: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrameAppKit: CGRect(x: 1440, y: 0, width: 1920, height: 1055),
            frameAX: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            usableAppKit: CGRect(x: 1440, y: 0, width: 1920, height: 1055),
            usableAX: CGRect(x: 1440, y: 25, width: 1920, height: 1055),
            safeAreaInsets: SafeAreaInsets(),
            isMain: false,
            primaryScreenHeight: 900
        )
        let boundEngine = ProfileEngine(axController: AXWindowController())
        boundEngine.seedCurrentTopology(connectedDisplays: [seededDisplay, extDisplay], swapExternalDisplays: false)
        var boundCfg = WindowSnapperConfig()
        var boundProfile = WorkspaceProfile(id: "bound-two-display", name: "Dual Desk")
        boundProfile.boundDisplaySignatures = [seededDisplay.signature, extDisplay.signature]
        boundProfile.topologyTriggerMode = .askViaHUD
        boundCfg.profiles = [boundProfile]

        boundEngine.handleDisplaysReconfigured(
            connectedDisplays: [seededDisplay],
            config: boundCfg
        ) { _ in }
        let unmatchedOneDisplayKey = ProfileEngine.topologyKey(for: [seededDisplay], swapExternalDisplays: false)
        let disconnectedUpdatedKey = boundEngine.lastAutoTriggeredTopologyKey == unmatchedOneDisplayKey
            && boundEngine.suggestedTopologyProfileID == nil

        boundEngine.handleDisplaysReconfigured(
            connectedDisplays: [seededDisplay, extDisplay],
            config: boundCfg
        ) { _ in }
        expect(
            disconnectedUpdatedKey && boundEngine.suggestedTopologyProfileID == boundProfile.id,
            "ProfileEngine must update lastAutoTriggeredTopologyKey on unmatched disconnect so reconnecting re-triggers bound profiles"
        )

        expect(
            DisplayPresetKind.builtInTemplates.contains(.maximized)
                && !DisplayPresetKind.topEdgeSlotTemplates.contains(.maximized),
            "DisplayPresetKind.maximized must appear in builtInTemplates and be excluded from topEdgeSlotTemplates"
        )
        let maximizedTemplateZones = SnapGeometry.resolveTemplateZones(
            preset: .maximized,
            usableAXRect: CGRect(x: 0, y: 25, width: 1440, height: 875),
            primaryScreenHeight: 900,
            gaps: GapConfig()
        )
        expect(
            maximizedTemplateZones.count == 1
                && maximizedTemplateZones[0].id == "cell:0:0"
                && maximizedTemplateZones[0].name == "Maximized"
                && maximizedTemplateZones[0].frameInAX == CGRect(x: 0, y: 25, width: 1440, height: 875),
            "DisplayPresetKind.maximized must resolve to a single full usable-rect zone named Maximized"
        )

        let legacySpanDragJSON = "{\"enabled\": true, \"gridModifier\": \"option\", \"spanModifier\": \"control_option\", \"edgeProximityPoints\": 12}"
        if let legacySpanData = legacySpanDragJSON.data(using: .utf8),
           let decodedLegacyDrag = try? JSONDecoder().decode(DragSnapConfig.self, from: legacySpanData) {
            expect(
                decodedLegacyDrag.enabled && decodedLegacyDrag.gridModifier == .option && decodedLegacyDrag.edgeProximityPoints == 12,
                "Legacy DragSnapConfig JSON with spanModifier must decode cleanly"
            )
        } else {
            failures.append("Failed to decode legacy DragSnapConfig JSON containing spanModifier")
        }

        let defaultHalvesLayout = DisplayLayoutConfig(
            display: DisplaySignature(),
            presetID: DisplayPresetKind.halves.rawValue,
            division: DisplayPresetKind.halves.defaultDivision
        )
        var adjustedStackLayout = DisplayLayoutConfig(
            display: DisplaySignature(),
            presetID: DisplayPresetKind.leftMainRightStack.rawValue,
            division: DisplayPresetKind.leftMainRightStack.defaultDivision
        )
        expect(
            !defaultHalvesLayout.hasCustomDividerProportions && !adjustedStackLayout.hasCustomDividerProportions,
            "Default template divisions must report hasCustomDividerProportions == false"
        )
        adjustedStackLayout.division = DisplayDivision(columnWeights: [1.5, 0.5], rowWeights: [0.6, 1.4])
        expect(
            adjustedStackLayout.hasCustomDividerProportions && adjustedStackLayout.presetKind == .leftMainRightStack,
            "Adjusted divider weights must report hasCustomDividerProportions == true while preserving presetKind"
        )
        let stackUsableAX = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let customStackZones = SnapGeometry.resolveZones(
            layout: adjustedStackLayout,
            usableAXRect: stackUsableAX,
            primaryScreenHeight: 900,
            gaps: GapConfig()
        )
        expect(
            customStackZones.count == 3
                && abs(customStackZones[0].frameInAX.width - (1440 * 0.75)) <= 2.0
                && abs(customStackZones[0].frameInAX.height - 875) <= 2.0
                && abs(customStackZones[1].frameInAX.height - (875 * 0.30)) <= 2.0
                && abs(customStackZones[2].frameInAX.height - (875 * 0.70)) <= 2.0,
            "Adjusted Left + 2 Right layout must stay 3 zones with proportional column/row sizing"
        )

        // 2. Sequoia native tiling preference parser & flash auto-hide regression check
        let allOnConflict = SnapGeometry.evaluateSequoiaTilingConflict(
            windowManagerDefaults: [
                "EnableTilingByEdgeDrag": true,
                "EnableTopTilingByEdgeDrag": true,
                "EnableTilingOptionAccelerator": true
            ],
            macOSMajorVersion: 15
        )
        expect(
            allOnConflict.hasConflictWithToolboxDrag && allOnConflict.activeSettingLabels.count == 3,
            "All 3 Sequoia tiling options enabled must flag conflict with 3 active labels (got \(allOnConflict.activeSettingLabels.count))"
        )
        let optionOnlyConflict = SnapGeometry.evaluateSequoiaTilingConflict(
            windowManagerDefaults: [
                "EnableTilingByEdgeDrag": false,
                "EnableTopTilingByEdgeDrag": false,
                "EnableTilingOptionAccelerator": true
            ],
            macOSMajorVersion: 15
        )
        expect(
            optionOnlyConflict.hasConflictWithToolboxDrag && optionOnlyConflict.activeSettingLabels.count == 1,
            "Option-key-only Sequoia tiling must still flag conflict with 1 active label"
        )
        let appleDefaultConflict = SnapGeometry.evaluateSequoiaTilingConflict(
            windowManagerDefaults: [:],
            macOSMajorVersion: 15
        )
        expect(
            appleDefaultConflict.hasConflictWithToolboxDrag && appleDefaultConflict.activeSettingLabels.count == 3,
            "Missing keys on macOS 15+ must treat Apple defaults as enabled"
        )
        let allDisabledConflict = SnapGeometry.evaluateSequoiaTilingConflict(
            windowManagerDefaults: [
                "EnableTilingByEdgeDrag": false,
                "EnableTopTilingByEdgeDrag": false,
                "EnableTilingOptionAccelerator": false
            ],
            macOSMajorVersion: 15
        )
        expect(
            !allDisabledConflict.hasConflictWithToolboxDrag && allDisabledConflict.activeSettingLabels.isEmpty,
            "Disabled Sequoia tiling options must NOT flag conflict"
        )
        expect(
            !SnapGeometry.evaluateSequoiaTilingConflict(
                windowManagerDefaults: [
                    "EnableTilingByEdgeDrag": true,
                    "EnableTopTilingByEdgeDrag": true,
                    "EnableTilingOptionAccelerator": true
                ],
                macOSMajorVersion: 14
            ).hasConflictWithToolboxDrag,
            "Pre-Sequoia macOS 14 must NOT flag Sequoia tiling conflict"
        )

        // 3. HotKeyManager conflict detection & one-click resolution across built-in actions, custom zones, and profiles
        let hk = HotKeyManager.shared
        var conflictCfg = ToolboxConfig()
        conflictCfg.windowSnapper.enabled = true
        conflictCfg.clipboard.enabled = true
        conflictCfg.clipboard.shortcut = conflictCfg.windowSnapper.hotKeys.leftHalf
        expect(
            hk.inAppConflictDescription(
                for: conflictCfg.windowSnapper.hotKeys.leftHalf,
                excludingSourceID: WindowSnapperHotKeyAction.leftHalf.sourceID,
                in: conflictCfg
            ) != nil,
            "HotKeyManager must detect collision between Window Snapper Left Half and Clipboard"
        )
        hk.clearConflictingShortcuts(
            matching: conflictCfg.windowSnapper.hotKeys.leftHalf,
            excludingSourceID: WindowSnapperHotKeyAction.leftHalf.sourceID,
            in: &conflictCfg
        )
        expect(conflictCfg.clipboard.shortcut.isEmpty, "clearConflictingShortcuts must clear colliding Clipboard shortcut")
        expect(!conflictCfg.windowSnapper.hotKeys.leftHalf.isEmpty, "clearConflictingShortcuts must preserve excluded Left Half shortcut")

        // 4. ProfileEngine dry-run preview builder (Ready, Will launch, Already placed, Main display fallback)
        let mainSig = DisplaySignature(uuidString: "MAIN-1", localizedName: "Built-in", arrangementIndex: 0)
        let extSig = DisplaySignature(uuidString: "EXT-1", localizedName: "Studio Display", arrangementIndex: 1)
        let mainDisp = ConnectedDisplay(
            displayID: 1,
            signature: mainSig,
            frameAppKit: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrameAppKit: CGRect(x: 0, y: 0, width: 1440, height: 875),
            frameAX: CGRect(x: 0, y: 0, width: 1440, height: 900),
            usableAppKit: CGRect(x: 0, y: 0, width: 1440, height: 875),
            usableAX: CGRect(x: 0, y: 25, width: 1440, height: 875),
            safeAreaInsets: SafeAreaInsets(),
            isMain: true,
            primaryScreenHeight: 900
        )

        var wsCfg = WindowSnapperConfig()
        let leftZone = SnapGeometry.resolveZones(
            layout: nil,
            usableAXRect: mainDisp.usableAX,
            primaryScreenHeight: 900,
            gaps: wsCfg.gaps
        ).first!

        let dummyElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let visibleWins = [
            DiscoveredAXWindow(
                pid: 10,
                windowNumber: 1,
                bundleIdentifier: "com.apple.Safari",
                appName: "Safari",
                title: "Docs",
                frameAX: leftZone.frameInAX,
                isFullscreen: false,
                isMinimized: false,
                elementBox: AXElementBox(dummyElement)
            )
        ]

        let profile = WorkspaceProfile(
            name: "Dry Run Test",
            appRules: [
                ProfileAppRule(bundleIdentifier: "com.apple.Safari", appName: "Safari", targetDisplay: .main, targetZoneID: "cell:0:0"),
                ProfileAppRule(bundleIdentifier: "com.apple.Notes", appName: "Notes", targetDisplay: .main, targetZoneID: "cell:1:0", launchIfNotRunning: true),
                ProfileAppRule(bundleIdentifier: "com.apple.Terminal", appName: "Terminal", targetDisplay: .specific(extSig), targetZoneID: "cell:1:0")
            ],
            disconnectedFallback: .moveToMainDisplay
        )

        let dryRun = ProfileEngine.buildDryRunPreview(
            profile: profile,
            displays: [mainDisp],
            visibleWindows: visibleWins,
            runningBundleIDs: ["com.apple.Safari"],
            config: wsCfg
        )
        let mainItems = dryRun[mainDisp.displayID] ?? []
        expect(mainItems.count == 3, "Dry-run preview should map all 3 rules onto main display (got \(mainItems.count))")
        expect(mainItems.first { $0.appName == "Safari" }?.status == .alreadyPlaced, "Safari already inside target zone must report .alreadyPlaced")
        expect(mainItems.first { $0.appName == "Notes" }?.status == .willLaunch, "Closed Notes with launchIfNotRunning must report .willLaunch")
        expect(mainItems.first { $0.appName == "Terminal" }?.status == .mainDisplayFallback, "Unplugged external monitor rule must report .mainDisplayFallback")

        expect(
            ProfileEngine.isWindowFramePositionedCorrectly(
                actualFrameAX: leftZone.frameInAX,
                targetFrameAX: leftZone.frameInAX,
                usableAXRect: mainDisp.usableAX
            ),
            "isWindowFramePositionedCorrectly must return true when frame matches target zone"
        )
        expect(
            !ProfileEngine.isWindowFramePositionedCorrectly(
                actualFrameAX: CGRect(x: 100, y: 100, width: 400, height: 300),
                targetFrameAX: leftZone.frameInAX,
                usableAXRect: mainDisp.usableAX
            ),
            "isWindowFramePositionedCorrectly must return false when app window has not filled target zone"
        )
        let minSizeClampTarget = CGRect(x: 1000, y: 25, width: 440, height: 875)
        let minSizeClampedActual = CGRect(x: 840, y: 25, width: 600, height: 875)
        expect(
            ProfileEngine.isWindowFramePositionedCorrectly(
                actualFrameAX: minSizeClampedActual,
                targetFrameAX: minSizeClampTarget,
                minSize: CGSize(width: 600, height: 400),
                usableAXRect: mainDisp.usableAX
            ),
            "isWindowFramePositionedCorrectly must treat min-size clamped frame as positioned"
        )

        let testProfileEngine = ProfileEngine(axController: AXWindowController())
        var toggleTestCfg = WindowSnapperConfig()
        toggleTestCfg.activeProfileID = profile.id
        toggleTestCfg.restorePreviousWorkspaceOnShortcutToggle = true
        expect(
            !testProfileEngine.canRestorePreviousWorkspace(forProfileID: profile.id, config: toggleTestCfg),
            "canRestorePreviousWorkspace must be false when no restore snapshot is stored"
        )
        testProfileEngine.seedRestoreSnapshotForTesting(
            WorkspaceProfileRestoreSnapshot(
                profileID: profile.id,
                profileName: profile.name,
                previousActiveProfileID: nil,
                previousDisplayLayouts: [],
                preProfileWindows: [],
                preProfileElementsByUndoID: [:],
                unminimizedElements: [],
                unhiddenBundleIDs: [],
                appsHiddenByProfile: [],
                newlyLaunchedBundleIDs: [],
                wasToolboxMainWindowVisible: false,
                previouslyFrontmostBundleID: nil
            )
        )
        expect(
            testProfileEngine.canRestorePreviousWorkspace(forProfileID: profile.id, config: toggleTestCfg),
            "canRestorePreviousWorkspace must be true when profile matches activeProfileID and toggle setting is enabled"
        )
        toggleTestCfg.restorePreviousWorkspaceOnShortcutToggle = false
        expect(
            !testProfileEngine.canRestorePreviousWorkspace(forProfileID: profile.id, config: toggleTestCfg),
            "canRestorePreviousWorkspace must be false when restorePreviousWorkspaceOnShortcutToggle is disabled"
        )
        toggleTestCfg.restorePreviousWorkspaceOnShortcutToggle = true
        toggleTestCfg.activeProfileID = "different-profile-id"
        expect(
            !testProfileEngine.canRestorePreviousWorkspace(forProfileID: profile.id, config: toggleTestCfg),
            "canRestorePreviousWorkspace must be false for a different active profile"
        )
        testProfileEngine.seedRestoreSnapshotForTesting(nil)

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfBox = AXElementBox(AXUIElementCreateApplication(selfPID))
        let remoteBox = AXElementBox(AXUIElementCreateApplication(selfPID + 50000))
        let taggedSelfBox = AXElementBox(AXUIElementCreateApplication(selfPID + 50000), selfWindowNumber: 42)
        expect(selfBox.isSelfProcess, "AXElementBox targeting own PID must report isSelfProcess=true")
        expect(taggedSelfBox.isSelfProcess, "AXElementBox with selfWindowNumber must report isSelfProcess=true")
        expect(!remoteBox.isSelfProcess, "AXElementBox targeting foreign PID must report isSelfProcess=false")

        final class OffMainResultBox: @unchecked Sendable {
            var value: WindowSnapExecutionResult? = WindowSnapExecutionResult(
                appliedFrameAX: .zero,
                clampedForMinSize: false,
                minSizeReported: nil
            )
        }
        let offMainGuardGroup = DispatchGroup()
        let offMainBox = OffMainResultBox()
        offMainGuardGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            offMainBox.value = AXWindowController.applyFrameSequenceSync(
                to: selfBox.element,
                currentFrameAX: CGRect(x: 0, y: 0, width: 800, height: 600),
                targetFrameAX: mainDisp.usableAX,
                usableAXRect: mainDisp.usableAX
            )
            offMainGuardGroup.leave()
        }
        offMainGuardGroup.wait()
        expect(offMainBox.value == nil, "AXWindowController.applyFrameSequenceSync must refuse self-process AX calls off the main thread")

        // 5. Module lifecycle & clean hotkey cleanup on stop()
        let mod = ModuleRegistry.shared.windowSnapper
        expect(ModuleRegistry.shared.module(withID: "window_snapper") === mod, "ModuleRegistry must resolve window_snapper")
        expect(mod.category == .windowAndDock, "WindowSnapper category must be .windowAndDock")
        expect(mod.requiresAccessibility, "WindowSnapper must require Accessibility")

        var activeCfg = ToolboxConfig()
        activeCfg.windowSnapper.enabled = true
        activeCfg.windowSnapper.drag.enabled = false
        activeCfg.windowSnapper.hotKeys = .unbound
        activeCfg.windowSnapper.hotKeys.maximize = ShortcutSpec(key: "F18", modifiers: [.control, .option, .command])
        mod.reload(with: activeCfg)
        expect(mod.isRunning, "WindowSnapperModule must report isRunning=true when enabled")
        expect(hk.isRegistered(name: WindowSnapperHotKeyAction.maximize.registrationName), "WindowSnapper hotkey must register when active")

        mod.stop()
        expect(!mod.isRunning, "WindowSnapperModule.stop() must clear isRunning")
        expect(!hk.isRegistered(name: WindowSnapperHotKeyAction.maximize.registrationName), "WindowSnapperModule.stop() must unregister all window_snapper.* hotkeys")
        expect(!mod.dragMonitor.isTapInstalled, "WindowSnapperModule.stop() must uninstall drag event tap")

        // 7. Top Edge Panel slot config, legacy migration, picker hit-testing, app card sizing & glass pane state
        var panelCfg = TopEdgePanelConfig()
        expect(
            panelCfg.slots == [.halves, .asymmetric, .asymmetricRight, .leftMainRightStack, .leftStackRightMain, .quarters],
            "TopEdgePanelConfig defaultSlots must match Left [Side by Side, Focus Left, Focus Right] / Right [Left + 2 Right, 2 Left + Right, 4 Quarters]"
        )
        expect(
            TopEdgePanelConfig.normalizedSlots([.halves, .custom, .halves, .thirds]) == [.halves, nil, nil, .thirds, nil, nil],
            "normalizedSlots must reject .custom, deduplicate duplicates, and pad to 6 slots"
        )
        expect(
            !panelCfg.setSlot(.thirds, at: -1) && !panelCfg.setSlot(.custom, at: 0),
            "setSlot must reject out-of-bounds indices and .custom"
        )
        expect(!panelCfg.setSlot(.quarters, at: 0), "setSlot must prevent duplicate template across slots")
        expect(panelCfg.setSlot(.thirds, at: 0) && panelCfg.slots[0] == .thirds, "setSlot must accept non-duplicate template")
        expect(panelCfg.setSlot(nil, at: 4) && panelCfg.slots[4] == nil, "setSlot(nil) must clear a slot")

        var swapCfg = TopEdgePanelConfig()
        expect(!swapCfg.assignOrSwapSlot(.custom, at: 0) && !swapCfg.assignOrSwapSlot(.halves, at: 9), "assignOrSwapSlot must reject .custom and out-of-bounds index")
        expect(swapCfg.assignOrSwapSlot(.thirds, at: 0) && swapCfg.slots[0] == .thirds, "assignOrSwapSlot must assign unassigned template")
        expect(
            swapCfg.assignOrSwapSlot(.quarters, at: 0)
                && swapCfg.slots[0] == .quarters
                && swapCfg.slots[5] == .thirds,
            "assignOrSwapSlot must swap when selecting a template already assigned to another slot"
        )
        expect(
            swapCfg.swapSlots(0, 5)
                && swapCfg.slots[0] == .thirds
                && swapCfg.slots[5] == .quarters,
            "swapSlots must swap two valid slot indices"
        )
        expect(swapCfg.assignOrSwapSlot(nil, at: 4) && swapCfg.slots[4] == nil, "assignOrSwapSlot(nil) must hide slot")

        let legacyTopDropJSON = """
        {
          "schemaVersion": 11,
          "windowSnapper": {
            "enabled": true,
            "drag": {
              "showTopEdgeDropBar": false,
              "topDropBarTriggerDistancePoints": 44,
              "snapOnTopEdgeMaximize": false
            }
          }
        }
        """
        if let legacyData = legacyTopDropJSON.data(using: .utf8),
           let migratedPanelCfg = try? JSONDecoder().decode(ToolboxConfig.self, from: legacyData) {
            expect(!migratedPanelCfg.windowSnapper.topEdgePanel.enabled, "Legacy drag.showTopEdgeDropBar must migrate to topEdgePanel.enabled")
            expect(migratedPanelCfg.windowSnapper.topEdgePanel.triggerDistancePoints == 44, "Legacy drag.topDropBarTriggerDistancePoints must migrate to topEdgePanel.triggerDistancePoints")
            expect(migratedPanelCfg.windowSnapper.topEdgePanel.slots == TopEdgePanelConfig.defaultSlots, "Legacy config without slots must populate default TopEdgePanelConfig slots")
        } else {
            failures.append("Failed to decode legacy topEdgePanel migration JSON")
        }

        var customPanelRoundTrip = ToolboxConfig()
        customPanelRoundTrip.windowSnapper.topEdgePanel = TopEdgePanelConfig(
            enabled: true,
            triggerDistancePoints: 12,
            slots: [.halves, nil, .thirds, nil, nil, .quarters],
            showAppCards: false,
            showWindowThumbnails: false
        )
        if let encodedPanel = try? JSONEncoder().encode(customPanelRoundTrip),
           let decodedPanel = try? JSONDecoder().decode(ToolboxConfig.self, from: encodedPanel) {
            expect(decodedPanel.windowSnapper.topEdgePanel == customPanelRoundTrip.windowSnapper.topEdgePanel, "TopEdgePanelConfig Codable round-trip mismatch")
        } else {
            failures.append("TopEdgePanelConfig Codable round-trip failed")
        }

        let asymCfg = TopEdgePanelConfig(
            slots: [.halves, .asymmetric, .thirds, .quarters, nil, nil]
        )
        let asymVisible = TopEdgePanelGeometry.visibleSlots(for: asymCfg)
        expect(
            asymVisible.count == 5 && asymVisible[3].kind == .maximize,
            "visibleSlots must omit nil slots and place Maximize at index 3 (got \(asymVisible.count))"
        )
        let symLayout = TopEdgePanelGeometry.pickerLayout(
            for: mainDisp,
            slots: TopEdgePanelGeometry.visibleSlots(for: TopEdgePanelConfig())
        )
        let asymLayout = TopEdgePanelGeometry.pickerLayout(for: mainDisp, slots: asymVisible)
        let maxOnlyLayout = TopEdgePanelGeometry.pickerLayout(
            for: mainDisp,
            slots: TopEdgePanelGeometry.visibleSlots(for: TopEdgePanelConfig(slots: [nil, nil, nil, nil, nil, nil]))
        )
        expect(
            abs((symLayout.maximizeSlot?.frameAX.midX ?? 0) - mainDisp.usableAX.midX) <= 1.0
                && abs((asymLayout.maximizeSlot?.frameAX.midX ?? 0) - mainDisp.usableAX.midX) <= 1.0
                && abs((maxOnlyLayout.maximizeSlot?.frameAX.midX ?? 0) - mainDisp.usableAX.midX) <= 1.0,
            "Maximize slot must stay centered on screen across symmetric, asymmetric, and Maximize-only slot configurations"
        )
        expect(
            TopEdgePanelGeometry.isPointerInTriggerZone(
                pointerAX: CGPoint(x: mainDisp.usableAX.midX, y: 40),
                display: mainDisp,
                layout: symLayout,
                triggerDistancePoints: 24,
                cornerBandPoints: 48
            ) && !TopEdgePanelGeometry.isPointerInTriggerZone(
                pointerAX: CGPoint(x: mainDisp.usableAX.midX, y: 40),
                display: mainDisp,
                layout: symLayout,
                triggerDistancePoints: 12,
                cornerBandPoints: 48
            ) && TopEdgePanelGeometry.isPointerInTriggerZone(
                pointerAX: CGPoint(x: mainDisp.usableAX.midX, y: 26),
                display: mainDisp,
                layout: symLayout,
                triggerDistancePoints: 0,
                cornerBandPoints: 48
            ) && !TopEdgePanelGeometry.isPointerInTriggerZone(
                pointerAX: CGPoint(x: 10, y: 10),
                display: mainDisp,
                layout: symLayout,
                triggerDistancePoints: 24,
                cornerBandPoints: 48
            ),
            "TopEdgePanelGeometry trigger zone must respect triggerDistancePoints and exclude corners"
        )

        // Direct mini-cell hit-testing inside Top Edge Panel picker tiles
        guard let left2RightSlot = symLayout.slots.first(where: { $0.item.kind == .template(.leftMainRightStack) }),
              let quartersSlot = symLayout.slots.first(where: { $0.item.kind == .template(.quarters) }),
              let maximizeSlot = symLayout.maximizeSlot else {
            expect(false, "Default picker layout must contain leftMainRightStack, quarters, and maximize slots")
            return
        }
        expect(
            left2RightSlot.cells.count == 3 && quartersSlot.cells.count == 4 && maximizeSlot.cells.count == 1,
            "Picker slots must expose mini-cells matching each template cell count"
        )
        for cellIdx in 0..<3 {
            let cellRect = left2RightSlot.cells[cellIdx].frameAX
            let hit = TopEdgePanelGeometry.hitTestPickerCell(
                pointerAX: CGPoint(x: cellRect.midX, y: cellRect.midY),
                in: symLayout
            )
            expect(
                hit?.slotKind == .template(.leftMainRightStack) && hit?.cellIndex == cellIdx,
                "hitTestPickerCell must directly hit Left + 2 Right mini-cell \(cellIdx)"
            )
        }
        for cellIdx in 0..<4 {
            let cellRect = quartersSlot.cells[cellIdx].frameAX
            let hit = TopEdgePanelGeometry.hitTestPickerCell(
                pointerAX: CGPoint(x: cellRect.midX, y: cellRect.midY),
                in: symLayout
            )
            expect(
                hit?.slotKind == .template(.quarters) && hit?.cellIndex == cellIdx,
                "hitTestPickerCell must directly hit 4 Quarters mini-cell \(cellIdx)"
            )
        }
        // Gutter forgiveness between mini-cells inside the same template tile
        let gutterPoint = CGPoint(
            x: (quartersSlot.cells[0].frameAX.maxX + quartersSlot.cells[1].frameAX.minX) * 0.5,
            y: quartersSlot.cells[0].frameAX.midY
        )
        let gutterHit = TopEdgePanelGeometry.hitTestPickerCell(pointerAX: gutterPoint, in: symLayout)
        expect(
            gutterHit?.slotKind == .template(.quarters) && gutterHit?.cellIndex != nil,
            "hitTestPickerCell must snap gutter hover inside a template tile to the nearest mini-cell"
        )
        let maxHit = TopEdgePanelGeometry.hitTestPickerCell(
            pointerAX: CGPoint(x: maximizeSlot.frameAX.midX, y: maximizeSlot.frameAX.midY),
            in: symLayout
        )
        expect(
            maxHit?.slotKind == .maximize && maxHit?.cellIndex == 0,
            "hitTestPickerCell must hit Maximize slot center"
        )
        expect(
            TopEdgePanelGeometry.hitTestPickerCell(pointerAX: CGPoint(x: 20, y: 400), in: symLayout) == nil,
            "hitTestPickerCell must return nil outside the picker strip"
        )

        // Occupied split-cell filtering & z-order occlusion checks
        let halvesZones = SnapGeometry.resolveTemplateZones(
            preset: .halves,
            usableAXRect: mainDisp.usableAX,
            primaryScreenHeight: 900,
            gaps: GapConfig()
        )
        let quartersZones = SnapGeometry.resolveTemplateZones(
            preset: .quarters,
            usableAXRect: mainDisp.usableAX,
            primaryScreenHeight: 900,
            gaps: GapConfig(outerMarginPoints: 8, innerGapPoints: 8)
        )
        let leftHalfOccupiedOnly = TopEdgePanelGeometry.unoccupiedRemainingCells(
            allCells: halvesZones,
            snappedCellID: halvesZones[0].id,
            snappedWindowNumber: 300,
            visibleWindowsFrontToBack: [
                VisibleWindowFootprint(windowNumber: 301, ownerPID: 202, boundsAX: halvesZones[1].frameInAX)
            ]
        )
        expect(
            leftHalfOccupiedOnly.unoccupiedCells.isEmpty && leftHalfOccupiedOnly.occupiedWindowNumbers == [301],
            "Attaching right half when another window already occupies right/opposite cell must skip glass panes"
        )
        let backgroundMaxDoesNotSuppress = TopEdgePanelGeometry.unoccupiedRemainingCells(
            allCells: halvesZones,
            snappedCellID: halvesZones[0].id,
            snappedWindowNumber: 300,
            visibleWindowsFrontToBack: [
                VisibleWindowFootprint(windowNumber: 302, ownerPID: 203, boundsAX: mainDisp.usableAX)
            ]
        )
        expect(
            backgroundMaxDoesNotSuppress.unoccupiedCells.count == 1 && backgroundMaxDoesNotSuppress.occupiedWindowNumbers.isEmpty,
            "A maximized background window behind a split must not mark a split cell occupied"
        )
        let occludedBehindFrontMax = TopEdgePanelGeometry.unoccupiedRemainingCells(
            allCells: halvesZones,
            snappedCellID: halvesZones[0].id,
            snappedWindowNumber: 300,
            visibleWindowsFrontToBack: [
                VisibleWindowFootprint(windowNumber: 303, ownerPID: 204, boundsAX: mainDisp.usableAX),
                VisibleWindowFootprint(windowNumber: 304, ownerPID: 205, boundsAX: halvesZones[1].frameInAX)
            ]
        )
        expect(
            occludedBehindFrontMax.unoccupiedCells.count == 1 && occludedBehindFrontMax.occupiedWindowNumbers.isEmpty,
            "A front window covering most of the cell must stop the z-order scan so hidden split windows underneath do not count as occupying"
        )
        let quarterMixOccupancy = TopEdgePanelGeometry.unoccupiedRemainingCells(
            allCells: quartersZones,
            snappedCellID: quartersZones[0].id,
            snappedWindowNumber: 306,
            visibleWindowsFrontToBack: [
                VisibleWindowFootprint(windowNumber: 305, ownerPID: 206, boundsAX: quartersZones[2].frameInAX),
                VisibleWindowFootprint(windowNumber: 306, ownerPID: 201, boundsAX: quartersZones[0].frameInAX)
            ]
        )
        expect(
            quarterMixOccupancy.unoccupiedCells.map(\.id) == [quartersZones[1].id, quartersZones[3].id]
                && quarterMixOccupancy.occupiedWindowNumbers == [305],
            "4 Quarters with cell 0 snapped and cell 2 already occupied must open glass panes only for the 2 unoccupied cells"
        )

        // Multi-window same-app card retention, per-window filtering, footprint sizing & flow layout
        let rawCards: [AppCardCandidate] = [
            AppCardCandidate(pid: selfPID, bundleIdentifier: "app.toolbox.desktop", appName: "Toolbox", windowTitle: "Settings", windowNumber: 100, windowFrameAX: CGRect(x: 0, y: 25, width: 940, height: 660), isMinimized: false, zOrderRank: 0),
            AppCardCandidate(pid: 201, bundleIdentifier: "com.apple.Safari", appName: "Safari", windowTitle: "Snapped Tab", windowNumber: 101, windowFrameAX: CGRect(x: 0, y: 25, width: 720, height: 875), isMinimized: false, zOrderRank: 1),
            AppCardCandidate(pid: 201, bundleIdentifier: "com.apple.Safari", appName: "Safari", windowTitle: "Reference Docs", windowNumber: 102, windowFrameAX: CGRect(x: 100, y: 60, width: 1280, height: 800), isMinimized: false, zOrderRank: 2),
            AppCardCandidate(pid: 201, bundleIdentifier: "com.apple.Safari", appName: "Safari", windowTitle: "Reference Docs", windowNumber: 102, windowFrameAX: CGRect(x: 100, y: 60, width: 1280, height: 800), isMinimized: false, zOrderRank: 3),
            AppCardCandidate(pid: 204, bundleIdentifier: "com.apple.Notes", appName: "Notes", windowTitle: "Scratchpad", windowNumber: 104, windowFrameAX: CGRect(x: 200, y: 120, width: 820, height: 540), isMinimized: false, zOrderRank: 4),
            AppCardCandidate(pid: 205, bundleIdentifier: "com.apple.Calculator", appName: "Calculator", windowTitle: "Basic", windowNumber: 105, windowFrameAX: CGRect(x: 40, y: 200, width: 320, height: 240), isMinimized: false, zOrderRank: 5)
        ]
        let dedupedCards = AppCardLayoutEngine.dedupeAndFilterCandidates(
            rawCards,
            excludingPIDs: [selfPID],
            excludingWindowNumbers: [101]
        )
        expect(
            dedupedCards.map(\.windowNumber) == [102, 104, 105],
            "dedupeAndFilterCandidates must keep sibling Safari window 102 when window 101 is snapped, drop Toolbox & exact duplicate window 102, and sort descending by footprint"
        )
        let cardItems = AppCardLayoutEngine.cardSizes(for: dedupedCards, in: CGSize(width: 680, height: 420))
        expect(cardItems.count == 3, "cardSizes must emit one item per deduped window candidate")
        expect(
            cardItems[0].area > cardItems[1].area && cardItems[1].area > cardItems[2].area,
            "App card sizes must scale monotonically with window footprint (got \(cardItems.map { "\(Int($0.size.width))x\(Int($0.size.height))" }))"
        )
        let narrowRows = AppCardLayoutEngine.layoutRows(for: dedupedCards, in: CGSize(width: 280, height: 320), spacing: 12)
        expect(!narrowRows.isEmpty, "layoutRows must emit rows for narrow panes")
        for row in narrowRows {
            let rowW = row.items.reduce(CGFloat(0)) { $0 + $1.size.width } + CGFloat(max(0, row.items.count - 1)) * 12
            expect(rowW <= 280.1 && row.items.allSatisfy { $0.size.width >= 96 && $0.size.height >= 70 }, "Narrow pane card row must stay readable and within pane width")
        }

        // Glass pane state machine (per-window placement + sibling window retention)
        let maxGlass = GlassPaneSessionState.begin(
            remainingZones: [],
            snappedWindowNumber: 101,
            snappedCandidateID: rawCards[1].id,
            selfPID: selfPID,
            initialCandidates: rawCards
        )
        expect(!maxGlass.isActive, "Maximize snap with 0 remaining zones must not activate glass panes")

        let twoPaneGlass = GlassPaneSessionState.begin(
            remainingZones: [quartersZones[1]],
            snappedWindowNumber: 101,
            snappedCandidateID: rawCards[1].id,
            selfPID: selfPID,
            initialCandidates: rawCards
        )
        expect(
            twoPaneGlass.isActive
                && twoPaneGlass.activePaneID == quartersZones[1].id
                && twoPaneGlass.candidates.contains(where: { $0.windowNumber == 102 }),
            "Single remaining pane must activate automatically and still offer sibling windows of the snapped app"
        )

        var multiGlass = GlassPaneSessionState.begin(
            remainingZones: Array(quartersZones.dropFirst()),
            snappedWindowNumber: 101,
            snappedCandidateID: rawCards[1].id,
            occupiedWindowNumbers: [105],
            selfPID: selfPID,
            initialCandidates: rawCards
        )
        expect(
            multiGlass.panes.count == 3
                && multiGlass.activePaneID == nil
                && multiGlass.candidates.map(\.windowNumber) == [102, 104],
            "Multiple remaining panes must start with no active pane and exclude already-occupied window numbers"
        )
        let safariSecondCandidate = multiGlass.candidates[0]
        multiGlass.activatePane(id: quartersZones[2].id)
        expect(multiGlass.activePaneID == quartersZones[2].id, "activatePane must activate the clicked pane only")
        multiGlass.completePlacement(paneID: quartersZones[2].id, placedCandidate: safariSecondCandidate)
        expect(
            multiGlass.panes.count == 2
                && multiGlass.activePaneID == nil
                && !multiGlass.candidates.contains(where: { $0.windowNumber == 102 }),
            "Completing placement in a 3-pane session must leave 2 inactive panes and remove only the placed window"
        )
        let notesCandidate = multiGlass.candidates[0]
        multiGlass.activatePane(id: quartersZones[1].id)
        multiGlass.completePlacement(paneID: quartersZones[1].id, placedCandidate: notesCandidate)
        expect(
            multiGlass.panes.count == 1 && multiGlass.activePaneID == quartersZones[3].id,
            "When 1 pane remains after placement, that sole remaining pane should activate"
        )
        multiGlass.completePlacement(paneID: quartersZones[3].id, placedCandidate: notesCandidate)
        expect(!multiGlass.isActive, "Completing placement in the last pane must end the glass pane session")

        // Trigger-area flash geometry & overlay auto-hide verification
        let triggerRect24 = TopEdgePanelGeometry.triggerZoneRectAX(
            for: mainDisp,
            layout: symLayout,
            triggerDistancePoints: 24,
            cornerBandPoints: 48
        )
        let triggerRect0 = TopEdgePanelGeometry.triggerZoneRectAX(
            for: mainDisp,
            layout: symLayout,
            triggerDistancePoints: 0,
            cornerBandPoints: 48
        )
        expect(
            abs(triggerRect24.minY - mainDisp.usableAX.minY) <= 0.1
                && abs(triggerRect24.height - 24) <= 0.1
                && abs(triggerRect0.height - 4) <= 0.1
                && triggerRect24.width >= 96,
            "TopEdgePanelGeometry.triggerZoneRectAX must anchor directly below the menu bar and clamp 0 pt to a 4 pt hairline"
        )

        let edgeRects20 = SnapGeometry.edgePullFlashRectsAX(
            usableAX: mainDisp.usableAX,
            edgeProximityPoints: 20,
            cornerBandPoints: 48
        )
        let edgeRects0 = SnapGeometry.edgePullFlashRectsAX(
            usableAX: mainDisp.usableAX,
            edgeProximityPoints: 0,
            cornerBandPoints: 48
        )
        expect(
            edgeRects20.count == 3
                && abs(edgeRects20[0].width - 20) <= 0.1
                && abs(edgeRects20[1].maxX - mainDisp.usableAX.maxX) <= 0.1
                && abs(edgeRects20[2].height - 20) <= 0.1
                && abs(edgeRects0[0].width - 4) <= 0.1
                && !edgeRects20[0].intersects(edgeRects20[2])
                && !edgeRects20[1].intersects(edgeRects20[2])
                && !edgeRects20[0].intersects(edgeRects20[1]),
            "SnapGeometry.edgePullFlashRectsAX must emit non-overlapping Left, Right, and Top strips with hairline floor at 0 pt"
        )

        let cornerRects64 = SnapGeometry.cornerBandFlashRectsAX(usableAX: mainDisp.usableAX, cornerBandPoints: 64)
        expect(
            cornerRects64.count == 4
                && cornerRects64.allSatisfy { abs($0.width - 64) <= 0.1 && abs($0.height - 64) <= 0.1 }
                && abs(cornerRects64[0].minX - mainDisp.usableAX.minX) <= 0.1
                && abs(cornerRects64[3].maxX - mainDisp.usableAX.maxX) <= 0.1
                && abs(cornerRects64[3].maxY - mainDisp.usableAX.maxY) <= 0.1,
            "SnapGeometry.cornerBandFlashRectsAX must emit four 64x64 corner squares inside usableAX"
        )

        ZoneOverlayController.shared.hideAllPreviews()
        ZoneOverlayController.shared.flashTriggerZones(
            on: [mainDisp],
            regionsProvider: { _ in
                (
                    regions: [
                        TriggerFlashRegion(
                            id: "top-edge-test",
                            frameAX: triggerRect24,
                            isZeroHairline: false,
                            cornerRadius: 8
                        )
                    ],
                    bannerAnchorAX: CGPoint(x: triggerRect24.midX, y: triggerRect24.maxY + 20)
                )
            },
            bannerText: "Top-Edge Trigger · 24 pt",
            style: OverlayStyleConfig(),
            holdDuration: 0.02,
            fadeDuration: 0.04
        )
        expect(
            ZoneOverlayController.shared.anyPassivePanelIsVisibleForTesting(),
            "flashTriggerZones must show passive overlay panel immediately"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.20))
        expect(
            !ZoneOverlayController.shared.anyPassivePanelIsVisibleForTesting(),
            "flashTriggerZones must auto-hide overlay panel after hold and fade expire"
        )
        ZoneOverlayController.shared.hideAllPreviews()

        let flushStyleZones = SnapGeometry.stylePreviewZonesAX(
            usableAXRect: mainDisp.usableAX,
            primaryScreenHeight: 900,
            gaps: GapConfig(outerMarginPoints: 0, innerGapPoints: 0)
        )
        let spaciousStyleZones = SnapGeometry.stylePreviewZonesAX(
            usableAXRect: mainDisp.usableAX,
            primaryScreenHeight: 900,
            gaps: GapConfig(outerMarginPoints: 16, innerGapPoints: 16)
        )
        expect(
            flushStyleZones.count == 2
                && abs(flushStyleZones[0].frameInAX.minX - mainDisp.usableAX.minX) <= 1.0
                && abs(flushStyleZones[0].frameInAX.minY - mainDisp.usableAX.minY) <= 1.0
                && abs(flushStyleZones[1].frameInAX.minX - flushStyleZones[0].frameInAX.maxX) <= 1.0
                && abs(flushStyleZones[1].frameInAX.maxX - mainDisp.usableAX.maxX) <= 1.0
                && abs(flushStyleZones[1].frameInAX.maxY - mainDisp.usableAX.maxY) <= 1.0,
            "SnapGeometry.stylePreviewZonesAX with 0 pt gaps must emit two flush zones touching all outer edges with 0 pt inner gap"
        )
        expect(
            spaciousStyleZones.count == 2
                && abs(spaciousStyleZones[0].frameInAX.minX - (mainDisp.usableAX.minX + 16)) <= 1.0
                && abs(spaciousStyleZones[0].frameInAX.minY - (mainDisp.usableAX.minY + 16)) <= 1.0
                && abs((spaciousStyleZones[1].frameInAX.minX - spaciousStyleZones[0].frameInAX.maxX) - 16) <= 1.0
                && abs(spaciousStyleZones[1].frameInAX.maxX - (mainDisp.usableAX.maxX - 16)) <= 1.0
                && abs(spaciousStyleZones[1].frameInAX.maxY - (mainDisp.usableAX.maxY - 16)) <= 1.0,
            "SnapGeometry.stylePreviewZonesAX with 16 pt gaps must inset all 4 outer edges by 16 pt and maintain an exact 16 pt inner gap"
        )

        ZoneOverlayController.shared.flashZoneStylePreview(
            on: [mainDisp],
            zonesProvider: { _ in spaciousStyleZones },
            bannerText: "Tile Spacing · Spacious (16 pt)",
            style: OverlayStyleConfig(borderWidthPoints: 4.0),
            showZoneLabels: true,
            holdDuration: 0.02,
            fadeDuration: 0.04
        )
        expect(
            ZoneOverlayController.shared.anyPassivePanelIsVisibleForTesting(),
            "flashZoneStylePreview with zone labels must show passive overlay panel immediately"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.20))
        expect(
            !ZoneOverlayController.shared.anyPassivePanelIsVisibleForTesting(),
            "flashZoneStylePreview must auto-hide overlay panel after hold and fade expire"
        )
        ZoneOverlayController.shared.hideAllPreviews()

        expect(
            ZoneOnScreenEditorView.zoneMetricsLabel(
                normalizedRect: NormalizedRect(x: 0, y: 0, width: 1.0, height: 1.0),
                widthPoints: 1264,
                heightPoints: 720
            ) == "1264 × 720"
                && ZoneOnScreenEditorView.zoneMetricsLabel(
                    normalizedRect: NormalizedRect(x: 0, y: 0, width: 0.65, height: 1.0),
                    widthPoints: 816,
                    heightPoints: 720
                ) == "65% · 816 × 720"
                && ZoneOnScreenEditorView.zoneMetricsLabel(
                    normalizedRect: NormalizedRect(x: 0, y: 0, width: 1.0, height: 0.50),
                    widthPoints: 1264,
                    heightPoints: 356
                ) == "50% · 1264 × 356"
                && ZoneOnScreenEditorView.zoneMetricsLabel(
                    normalizedRect: NormalizedRect(x: 0, y: 0, width: 0.35, height: 0.40),
                    widthPoints: 440,
                    heightPoints: 285
                ) == "35% × 40% · 440 × 285",
            "ZoneOnScreenEditorView.zoneMetricsLabel must format full, column, row, and quadrant zone dimensions accurately"
        )

        let compactCenter = SnapGeometry.resolveUniversalOrBuiltInZone(
            id: "universal:center",
            usableAXRect: mainDisp.usableAX,
            primaryScreenHeight: 900,
            gaps: GapConfig(outerMarginPoints: 8, innerGapPoints: 8),
            layoutOverride: nil,
            centerWidthFraction: 0.60,
            centerHeightFraction: 0.72
        )
        let largeCenter = SnapGeometry.resolveUniversalOrBuiltInZone(
            id: "universal:center",
            usableAXRect: mainDisp.usableAX,
            primaryScreenHeight: 900,
            gaps: GapConfig(outerMarginPoints: 8, innerGapPoints: 8),
            layoutOverride: nil,
            centerWidthFraction: 0.82,
            centerHeightFraction: 0.88
        )
        expect(
            compactCenter != nil
                && largeCenter != nil
                && abs((compactCenter?.frameInAX.width ?? 0) - mainDisp.usableAX.width * 0.60) <= 2.0
                && abs((compactCenter?.frameInAX.height ?? 0) - mainDisp.usableAX.height * 0.72) <= 2.0
                && abs((compactCenter?.frameInAX.midX ?? 0) - mainDisp.usableAX.midX) <= 2.0
                && abs((compactCenter?.frameInAX.midY ?? 0) - mainDisp.usableAX.midY) <= 2.0
                && abs((largeCenter?.frameInAX.width ?? 0) - mainDisp.usableAX.width * 0.82) <= 2.0
                && abs((largeCenter?.frameInAX.height ?? 0) - mainDisp.usableAX.height * 0.88) <= 2.0
                && (largeCenter?.frameInAX.width ?? 0) > (compactCenter?.frameInAX.width ?? 0),
            "Universal center resolution must match Compact (60x72%) and Large (82x88%) centered fractions"
        )

        // TopEdgeTriggerWidth Codable + trigger rect width ordering + descriptive preset labels
        var widthRoundTrip = ToolboxConfig()
        widthRoundTrip.windowSnapper.topEdgePanel.triggerWidth = .wide
        if let encodedW = try? JSONEncoder().encode(widthRoundTrip),
           let decodedW = try? JSONDecoder().decode(ToolboxConfig.self, from: encodedW) {
            expect(
                decodedW.windowSnapper.topEdgePanel.triggerWidth == .wide,
                "TopEdgeTriggerWidth must round-trip through JSON Codable"
            )
        } else {
            failures.append("TopEdgeTriggerWidth Codable round-trip failed")
        }
        if let legacyNoWidthData = legacyTopDropJSON.data(using: .utf8),
           let decodedNoWidth = try? JSONDecoder().decode(ToolboxConfig.self, from: legacyNoWidthData) {
            expect(
                decodedNoWidth.windowSnapper.topEdgePanel.triggerWidth == .matchPanel,
                "Missing triggerWidth in JSON must default to .matchPanel"
            )
        }

        let compactRect = TopEdgePanelGeometry.triggerZoneRectAX(
            for: mainDisp,
            layout: symLayout,
            triggerDistancePoints: 24,
            cornerBandPoints: 48,
            triggerWidth: .compact
        )
        let matchRect = TopEdgePanelGeometry.triggerZoneRectAX(
            for: mainDisp,
            layout: symLayout,
            triggerDistancePoints: 24,
            cornerBandPoints: 48,
            triggerWidth: .matchPanel
        )
        let wideRect = TopEdgePanelGeometry.triggerZoneRectAX(
            for: mainDisp,
            layout: symLayout,
            triggerDistancePoints: 24,
            cornerBandPoints: 48,
            triggerWidth: .wide
        )
        expect(
            compactRect.width < matchRect.width
                && matchRect.width < wideRect.width
                && compactRect.minX >= mainDisp.usableAX.minX + 48 - 0.1
                && wideRect.maxX <= mainDisp.usableAX.maxX - 48 + 0.1,
            "TopEdgeTriggerWidth must order compact < matchPanel < wide while staying clear of corner bands"
        )

        expect(
            TopEdgePanelConfig.triggerDistanceLabel(for: 0) == "Edge Only"
                && TopEdgePanelConfig.triggerDistanceLabel(for: 12) == "Close"
                && TopEdgePanelConfig.triggerDistanceLabel(for: 24) == "Medium"
                && TopEdgePanelConfig.triggerDistanceLabel(for: 44) == "Generous"
                && DragSnapConfig.edgeProximityLabel(for: 0) == "Touch Edge"
                && DragSnapConfig.edgeProximityLabel(for: 8) == "Tight"
                && DragSnapConfig.edgeProximityLabel(for: 12) == "Medium"
                && DragSnapConfig.edgeProximityLabel(for: 20) == "Wide"
                && DragSnapConfig.cornerBandLabel(for: 32) == "Small"
                && DragSnapConfig.cornerBandLabel(for: 48) == "Medium"
                && DragSnapConfig.cornerBandLabel(for: 64) == "Large"
                && DragSnapConfig.cornerBandLabel(for: 80) == "Extra Large"
                && GapConfig.spacingPresetLabel(for: 0) == "Flush"
                && GapConfig.spacingPresetLabel(for: 4) == "Tight"
                && GapConfig.spacingPresetLabel(for: 8) == "Cozy"
                && GapConfig.spacingPresetLabel(for: 12) == "Relaxed"
                && GapConfig.spacingPresetLabel(for: 16) == "Spacious"
                && OverlayStyleConfig.borderThicknessLabel(for: 1.0) == "Thin"
                && OverlayStyleConfig.borderThicknessLabel(for: 2.0) == "Medium"
                && OverlayStyleConfig.borderThicknessLabel(for: 4.0) == "Thick"
                && OverlayStyleConfig.borderThicknessLabel(for: 7.0) == "Bold",
            "Descriptive spacing, border thickness, and trigger preset labels must map cleanly across all tiers"
        )

        wsCfg.enabled = false
        _ = wsCfg
    }

    private static func testWindowDragMonitorEndToEndLifecycle() {
        DisplayRegistry.shared.refresh()
        let usable = DisplayRegistry.shared.mainDisplay()?.usableAX ?? CGRect(x: 0, y: 25, width: 1440, height: 875)
        let originalFrame = CGRect(
            x: usable.minX + 120,
            y: usable.minY + 120,
            width: max(400, round(usable.width * 0.45)),
            height: max(300, round(usable.height * 0.55))
        )
        let leftHalfFrame = CGRect(
            x: usable.minX,
            y: usable.minY,
            width: round(usable.width * 0.5),
            height: usable.height
        )
        let fakePID: pid_t = ProcessInfo.processInfo.processIdentifier + 50001
        let fakeBox = AXElementBox(AXUIElementCreateApplication(fakePID))

        let makeWindow: (Int, CGRect) -> DiscoveredAXWindow = { winNum, frame in
            DiscoveredAXWindow(
                pid: fakePID,
                windowNumber: winNum,
                bundleIdentifier: "com.example.testapp",
                appName: "TestApp",
                title: "Document",
                frameAX: frame,
                isFullscreen: false,
                isMinimized: false,
                elementBox: fakeBox
            )
        }

        var store = PreSnapFrameStore()
        let axController = AXWindowController()
        let monitor = WindowDragMonitor(axController: axController)
        var cfg = WindowSnapperConfig()
        cfg.enabled = true
        cfg.drag.enabled = true
        cfg.windowAnimationSpeed = .smooth
        cfg.topEdgePanel.enabled = true
        cfg.topEdgePanel.triggerDistancePoints = 44
        monitor.updateConfig(cfg)

        var midDragRestores: [(size: CGSize, speed: WindowAnimationSpeed)] = []
        var unsnapCommits: [CGSize] = []
        monitor.preSnapLookup = { win in
            store.lookupOriginalFrameIfSnapped(for: win)
        }
        monitor.onMidDragResizeRequestedForTesting = { size, speed in
            midDragRestores.append((size, speed))
        }
        monitor.onUnsnapCommitted = { _, preSnapRect, _, _ in
            unsnapCommits.append(preSnapRect.size)
        }
        monitor.onExternalMaximizeDetected = { winNum, pid, bundleID, preFrame, postFrame in
            let dummy = makeWindow(winNum ?? 0, preFrame)
            let effectiveOriginal = store.lookupOriginalFrameIfSnapped(for: dummy, currentSizeAX: preFrame.size) ?? preFrame
            store.recordSnap(
                pid: pid,
                windowNumber: winNum,
                bundleIdentifier: bundleID,
                preSnapFrameAX: effectiveOriginal,
                appliedFrameAX: postFrame
            )
        }
        monitor.onExternalUnmaximizeDetected = { winNum, pid, _ in
            store.clearRecord(pid: pid, windowNumber: winNum, sizeAX: nil)
        }

        // 1. Pulling a Toolbox-snapped window off Left Half triggers animated mid-drag size restore
        let leftWin = makeWindow(990001, leftHalfFrame)
        store.recordSnap(window: leftWin, preSnapFrameAX: originalFrame, appliedFrameAX: leftHalfFrame)
        let leftGrabStart = CGPoint(x: leftHalfFrame.midX, y: usable.minY + 120)
        monitor.beginSimulatedDragSessionForTesting(
            downPointAX: leftGrabStart,
            window: leftWin,
            initialFrameAX: leftHalfFrame,
            timestamp: 1.0
        )
        let leftStep = monitor.advanceSimulatedDragForTesting(
            pointerAX: CGPoint(x: leftGrabStart.x + 24, y: leftGrabStart.y + 40),
            liveWindowFrameAX: leftHalfFrame.offsetBy(dx: 24, dy: 40),
            timestamp: 1.05
        )
        expect(
            leftStep.confirmation == .confirmedMove
                && midDragRestores.count == 1
                && midDragRestores.first?.size == originalFrame.size
                && midDragRestores.first?.speed == .smooth,
            "Pulling a snapped window off Left Half must confirm move and request animated mid-drag resize back to pre-snap size"
        )
        monitor.finishSimulatedDragForTesting(
            releasePointAX: CGPoint(x: leftGrabStart.x + 80, y: leftGrabStart.y + 80),
            timestamp: 1.15
        )
        expect(unsnapCommits.count == 1, "Releasing unsnapped window outside zones must commit unsnap")

        // 2. Pulling a Toolbox-maximized window down from the top edge animates size restore & keeps Top Edge Panel closed
        midDragRestores.removeAll()
        let maxWin = makeWindow(990002, usable)
        store.recordSnap(window: maxWin, preSnapFrameAX: originalFrame, appliedFrameAX: usable)
        let topGrabStart = CGPoint(x: usable.midX, y: usable.minY + 10)
        monitor.beginSimulatedDragSessionForTesting(
            downPointAX: topGrabStart,
            window: maxWin,
            initialFrameAX: usable,
            timestamp: 2.0
        )
        let maxPull1 = monitor.advanceSimulatedDragForTesting(
            pointerAX: CGPoint(x: usable.midX + 6, y: usable.minY + 16),
            liveWindowFrameAX: usable.offsetBy(dx: 6, dy: 6),
            timestamp: 2.03
        )
        expect(
            maxPull1.confirmation == .confirmedMove
                && !maxPull1.topPanelVisible
                && midDragRestores.count == 1
                && midDragRestores.first?.size == originalFrame.size,
            "Pulling down from Maximize must animate back to original size without opening the Top Edge Panel"
        )
        let maxPull2 = monitor.advanceSimulatedDragForTesting(
            pointerAX: CGPoint(x: usable.midX + 18, y: usable.minY + 28),
            liveWindowFrameAX: usable.offsetBy(dx: 18, dy: 18),
            timestamp: 2.06
        )
        expect(
            !maxPull2.topPanelVisible,
            "Continuing downward pull from Maximize inside top band must keep Top Edge Panel suppressed"
        )
        monitor.finishSimulatedDragForTesting(
            releasePointAX: CGPoint(x: usable.midX + 30, y: usable.minY + 160),
            timestamp: 2.16
        )

        // 3. Double-clicking titlebar to maximize records pre-zoom size, and pulling off restores it
        midDragRestores.removeAll()
        let zoomWinNum = 990003
        monitor.handleExternalZoomTransition(
            windowNumber: zoomWinNum,
            pid: fakePID,
            bundleIdentifier: "com.example.testapp",
            preClickFrameAX: originalFrame,
            postClickFrameAX: usable,
            displayUsableAX: usable
        )
        let zoomedWin = makeWindow(zoomWinNum, usable)
        expect(
            store.lookupOriginalFrameIfSnapped(for: zoomedWin) == originalFrame,
            "Double-click maximize transition must store original pre-zoom frame in PreSnapFrameStore"
        )
        monitor.beginSimulatedDragSessionForTesting(
            downPointAX: CGPoint(x: usable.midX, y: usable.minY + 10),
            window: zoomedWin,
            initialFrameAX: usable,
            timestamp: 3.0
        )
        let zoomedPull = monitor.advanceSimulatedDragForTesting(
            pointerAX: CGPoint(x: usable.midX + 12, y: usable.minY + 22),
            liveWindowFrameAX: usable.offsetBy(dx: 12, dy: 12),
            timestamp: 3.05
        )
        expect(
            zoomedPull.confirmation == .confirmedMove
                && !zoomedPull.topPanelVisible
                && midDragRestores.count == 1
                && midDragRestores.first?.size == originalFrame.size,
            "Dragging away from macOS double-click maximize must animate back to pre-zoom size without opening Top Edge Panel"
        )
        monitor.finishSimulatedDragForTesting(
            releasePointAX: CGPoint(x: usable.midX + 40, y: usable.minY + 180),
            timestamp: 3.15
        )

        // 4. Double-clicking again to un-maximize clears PreSnapFrameStore record
        monitor.handleExternalZoomTransition(
            windowNumber: zoomWinNum,
            pid: fakePID,
            bundleIdentifier: "com.example.testapp",
            preClickFrameAX: usable,
            postClickFrameAX: originalFrame,
            displayUsableAX: usable
        )
        expect(
            store.lookupOriginalFrameIfSnapped(for: zoomedWin) == nil,
            "Double-click un-maximize transition must clear stored pre-snap record"
        )

        // 5. Delayed Electron/custom-titlebar drag confirms once window moves after 30pt pointer lead
        midDragRestores.removeAll()
        let delayedWin = makeWindow(990004, leftHalfFrame)
        store.recordSnap(window: delayedWin, preSnapFrameAX: originalFrame, appliedFrameAX: leftHalfFrame)
        let delayedGrab = CGPoint(x: leftHalfFrame.midX, y: usable.minY + 16)
        monitor.beginSimulatedDragSessionForTesting(
            downPointAX: delayedGrab,
            window: delayedWin,
            initialFrameAX: leftHalfFrame,
            timestamp: 4.0
        )
        let leadPhase = monitor.advanceSimulatedDragForTesting(
            pointerAX: CGPoint(x: delayedGrab.x + 30, y: delayedGrab.y + 10),
            liveWindowFrameAX: leftHalfFrame,
            timestamp: 4.02
        )
        expect(
            leadPhase.confirmation == .pending,
            "Delayed Electron drag with 30pt pointer lead before window moves must remain pending"
        )
        let catchUpPhase = monitor.advanceSimulatedDragForTesting(
            pointerAX: CGPoint(x: delayedGrab.x + 35, y: delayedGrab.y + 15),
            liveWindowFrameAX: leftHalfFrame.offsetBy(dx: 5, dy: 5),
            timestamp: 4.05
        )
        expect(
            catchUpPhase.confirmation == .confirmedMove
                && midDragRestores.count == 1
                && midDragRestores.first?.size == originalFrame.size,
            "Delayed Electron drag must confirm and trigger mid-drag restore as soon as window moves"
        )
        monitor.finishSimulatedDragForTesting(
            releasePointAX: CGPoint(x: usable.midX, y: usable.midY),
            timestamp: 4.15
        )

        // 6. Text selection inside snapped window triggers neither mid-drag resize nor unsnap commit
        midDragRestores.removeAll()
        unsnapCommits.removeAll()
        let selectionWin = makeWindow(990005, leftHalfFrame)
        store.recordSnap(window: selectionWin, preSnapFrameAX: originalFrame, appliedFrameAX: leftHalfFrame)
        let selectStart = CGPoint(x: leftHalfFrame.midX, y: usable.midY)
        monitor.beginSimulatedDragSessionForTesting(
            downPointAX: selectStart,
            window: selectionWin,
            initialFrameAX: leftHalfFrame,
            timestamp: 5.0
        )
        let selectEnd = monitor.advanceSimulatedDragForTesting(
            pointerAX: CGPoint(x: selectStart.x + 80, y: selectStart.y + 20),
            liveWindowFrameAX: leftHalfFrame,
            timestamp: 5.10
        )
        expect(
            selectEnd.confirmation == .pending && midDragRestores.isEmpty,
            "Text selection inside snapped window must not trigger mid-drag size restore"
        )
        monitor.finishSimulatedDragForTesting(
            releasePointAX: CGPoint(x: selectStart.x + 80, y: selectStart.y + 20),
            timestamp: 5.15
        )
        expect(
            unsnapCommits.isEmpty,
            "Releasing text selection inside snapped window must never trigger unsnap commit"
        )

        // 7. PreSnapFrameStore JSON save/load persistence preserves live PIDs and prunes dead PIDs
        let tmpStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-presnap-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpStoreURL) }
        var persistedStore = PreSnapFrameStore()
        let liveWin = makeWindow(990006, leftHalfFrame)
        let deadPID: pid_t = fakePID + 999
        let deadWin = DiscoveredAXWindow(
            pid: deadPID,
            windowNumber: 990007,
            bundleIdentifier: "com.example.dead",
            appName: "DeadApp",
            title: "Gone",
            frameAX: leftHalfFrame,
            isFullscreen: false,
            isMinimized: false,
            elementBox: fakeBox
        )
        persistedStore.recordSnap(window: liveWin, preSnapFrameAX: originalFrame, appliedFrameAX: leftHalfFrame)
        persistedStore.recordSnap(window: deadWin, preSnapFrameAX: originalFrame, appliedFrameAX: leftHalfFrame)
        persistedStore.save(to: tmpStoreURL)
        let reloadedStore = PreSnapFrameStore.load(from: tmpStoreURL, livePIDs: [fakePID])
        expect(
            reloadedStore.lookupOriginalFrameIfSnapped(for: liveWin) == originalFrame
                && reloadedStore.lookupOriginalFrameIfSnapped(for: deadWin) == nil,
            "PreSnapFrameStore persistence must survive restart for live PIDs and prune dead PIDs"
        )

        ZoneOverlayController.shared.hideDragOverlays()
        ZoneOverlayController.shared.hideAllPreviews()
    }

    // MARK: - Finder Enhancer Tests

    private static func testFinderEnhancerConfigAndMigration() {
        let defaults = ToolboxConfig()
        expect(defaults.schemaVersion == 15, "ToolboxConfig schemaVersion should be 15")
        expect(!defaults.finderEnhancer.enabled, "FinderEnhancer should default to disabled")
        expect(defaults.finderEnhancer.enableCutAndPaste, "enableCutAndPaste should default to true")
        expect(defaults.finderEnhancer.showCutToast, "showCutToast should default to true")
        expect(!defaults.finderEnhancer.enableReturnToOpen, "enableReturnToOpen should default to false")
        expect(!defaults.finderEnhancer.enableF2ToRename, "enableF2ToRename should default to false")
        expect(!defaults.finderEnhancer.enableAutoQuitOnLastWindowClose, "enableAutoQuitOnLastWindowClose should default to false")
        expect(defaults.finderEnhancer.autoQuitMode == .allowlistOnly, "autoQuitMode should default to .allowlistOnly")
        expect(defaults.finderEnhancer.autoQuitDelayMs == 500, "autoQuitDelayMs should default to 500")
        expect(
            defaults.finderEnhancer.autoQuitAllowlistBundleIDs == FinderEnhancerConfig.defaultAllowlistBundleIDs,
            "Default allowlist should include Preview, TextEdit, QuickTime Player, System Settings, Calculator, Font Book"
        )
        expect(defaults.finderEnhancer.autoQuitExcludedBundleIDs.isEmpty, "Default exclusions should be empty")

        // Codable round-trip
        var custom = ToolboxConfig()
        custom.finderEnhancer.enabled = true
        custom.finderEnhancer.enableCutAndPaste = false
        custom.finderEnhancer.showCutToast = false
        custom.finderEnhancer.enableReturnToOpen = true
        custom.finderEnhancer.enableF2ToRename = true
        custom.finderEnhancer.enableAutoQuitOnLastWindowClose = true
        custom.finderEnhancer.autoQuitMode = .allExceptExcluded
        custom.finderEnhancer.autoQuitDelayMs = 1250
        custom.finderEnhancer.autoQuitAllowlistBundleIDs = ["com.apple.Preview"]
        custom.finderEnhancer.autoQuitExcludedBundleIDs = ["com.google.Chrome", "com.apple.Safari"]

        if let data = try? JSONEncoder().encode(custom),
           let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(decoded.finderEnhancer == custom.finderEnhancer, "FinderEnhancerConfig Codable round-trip mismatch")
            expect(decoded.schemaVersion == 15, "Encoded FinderEnhancer config must preserve schemaVersion 15")
        } else {
            failures.append("FinderEnhancerConfig Codable encode/decode failed")
        }

        // Legacy v14 JSON without finderEnhancer key migrates cleanly
        let legacyV14 = "{\"schemaVersion\": 14, \"general\": {\"appEnabled\": true}}"
        if let data = legacyV14.data(using: .utf8),
           let migrated = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(migrated.schemaVersion == 15, "v14 config should upgrade to schemaVersion 15")
            expect(migrated.finderEnhancer == FinderEnhancerConfig(), "Migrated finderEnhancer should equal defaults")
        } else {
            failures.append("Failed to decode legacy v14 config")
        }

        // Partial JSON + delay clamping
        let partialJSON = """
        {"schemaVersion": 15, "finderEnhancer": {"enabled": true, "autoQuitDelayMs": 99999}}
        """
        if let data = partialJSON.data(using: .utf8),
           let decodedPartial = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(decodedPartial.finderEnhancer.enabled, "Partial finderEnhancer.enabled should decode")
            expect(decodedPartial.finderEnhancer.enableCutAndPaste, "Partial finderEnhancer should fill enableCutAndPaste default")
            expect(
                decodedPartial.finderEnhancer.autoQuitDelayMs == FinderEnhancerConfig.maxAutoQuitDelayMs,
                "Out-of-range autoQuitDelayMs must clamp to \(FinderEnhancerConfig.maxAutoQuitDelayMs)"
            )
        } else {
            failures.append("Failed to decode partial FinderEnhancer JSON")
        }
    }

    private static func testFinderCutStateMachineAndKeyInterceptor() {
        var cfg = FinderEnhancerConfig()
        cfg.enabled = true
        cfg.enableCutAndPaste = true
        cfg.enableReturnToOpen = true
        cfg.enableF2ToRename = true

        var cutState = FinderCutStateMachine()
        let finder = FinderKeyInterceptor.finderBundleID
        let browserFocus = FinderFocusContext.browserItemFocused

        // 1. ⌘X in Finder browser arms cut; after pasteboard advances, ⌘V emits move & disarms; second ⌘V passes through.
        let cutDecision = FinderKeyInterceptor.decideKeyEvent(
            keyCode: UInt16(kVK_ANSI_X),
            flags: .maskCommand,
            isAutoRepeat: false,
            userData: 0,
            frontmostBundleID: finder,
            config: cfg,
            focusContext: browserFocus,
            cutState: &cutState,
            currentChangeCount: 100,
            pasteboardHasFileURLs: false
        )
        expect(cutDecision == .cutToCopy, "⌘X in Finder browser should produce .cutToCopy")

        cutState.arm(changeCount: 101, itemCount: 2)
        expect(cutState.isArmed && cutState.armedItemCount == 2, "Cut state should arm for 2 items")

        let pasteMove = FinderKeyInterceptor.decideKeyEvent(
            keyCode: UInt16(kVK_ANSI_V),
            flags: .maskCommand,
            isAutoRepeat: false,
            userData: 0,
            frontmostBundleID: finder,
            config: cfg,
            focusContext: browserFocus,
            cutState: &cutState,
            currentChangeCount: 101,
            pasteboardHasFileURLs: true
        )
        expect(pasteMove == .pasteAsMove, "Armed ⌘V with matching changeCount + file URLs must emit .pasteAsMove")
        expect(!cutState.isArmed, "Cut state must disarm immediately after move")

        let secondPaste = FinderKeyInterceptor.decideKeyEvent(
            keyCode: UInt16(kVK_ANSI_V),
            flags: .maskCommand,
            isAutoRepeat: false,
            userData: 0,
            frontmostBundleID: finder,
            config: cfg,
            focusContext: browserFocus,
            cutState: &cutState,
            currentChangeCount: 101,
            pasteboardHasFileURLs: true
        )
        expect(secondPaste == .passThrough, "Second ⌘V after move must passThrough normally")

        // 2. Cross-app copy invalidation (changeCount bumped or file URLs absent) disarms & passes through.
        cutState.arm(changeCount: 200, itemCount: 1)
        let stalePaste = FinderKeyInterceptor.decideKeyEvent(
            keyCode: UInt16(kVK_ANSI_V),
            flags: .maskCommand,
            isAutoRepeat: false,
            userData: 0,
            frontmostBundleID: finder,
            config: cfg,
            focusContext: browserFocus,
            cutState: &cutState,
            currentChangeCount: 201,
            pasteboardHasFileURLs: false
        )
        expect(stalePaste == .disarmAndPassThrough && !cutState.isArmed, "Stale pasteboard changeCount must disarm and passThrough")

        // 3. Esc and ⌘C disarm armed cut state and pass through.
        cutState.arm(changeCount: 202, itemCount: 1)
        let escDecision = FinderKeyInterceptor.decideKeyEvent(
            keyCode: UInt16(kVK_Escape),
            flags: [],
            isAutoRepeat: false,
            userData: 0,
            frontmostBundleID: finder,
            config: cfg,
            focusContext: browserFocus,
            cutState: &cutState,
            currentChangeCount: 202,
            pasteboardHasFileURLs: true
        )
        expect(escDecision == .disarmAndPassThrough && !cutState.isArmed, "Esc must disarm cut state and passThrough")

        cutState.arm(changeCount: 203, itemCount: 1)
        let copyDecision = FinderKeyInterceptor.decideKeyEvent(
            keyCode: UInt16(kVK_ANSI_C),
            flags: .maskCommand,
            isAutoRepeat: false,
            userData: 0,
            frontmostBundleID: finder,
            config: cfg,
            focusContext: browserFocus,
            cutState: &cutState,
            currentChangeCount: 203,
            pasteboardHasFileURLs: true
        )
        expect(copyDecision == .disarmAndPassThrough && !cutState.isArmed, "⌘C must disarm cut state and passThrough")

        // 4. Text-input & modal safety gates block ⌘X, Return, and F2.
        let textFieldFocus = FinderFocusContext(
            focusedRole: "AXTextField",
            focusedSubrole: nil,
            windowRole: "AXWindow",
            windowSubrole: "AXStandardWindow",
            isWindowModal: false,
            hasAttachedSheet: false,
            isInSheetHierarchy: false,
            axLookupFailed: false
        )
        let dialogButtonFocus = FinderFocusContext(
            focusedRole: "AXButton",
            focusedSubrole: nil,
            windowRole: "AXWindow",
            windowSubrole: "AXDialog",
            isWindowModal: true,
            hasAttachedSheet: false,
            isInSheetHierarchy: false,
            axLookupFailed: false
        )
        let sheetFocus = FinderFocusContext(
            focusedRole: "AXOutline",
            focusedSubrole: nil,
            windowRole: "AXWindow",
            windowSubrole: "AXStandardWindow",
            isWindowModal: false,
            hasAttachedSheet: true,
            isInSheetHierarchy: true,
            axLookupFailed: false
        )

        expect(
            FinderKeyInterceptor.decideKeyEvent(
                keyCode: UInt16(kVK_ANSI_X),
                flags: .maskCommand,
                isAutoRepeat: false,
                userData: 0,
                frontmostBundleID: finder,
                config: cfg,
                focusContext: textFieldFocus,
                cutState: &cutState,
                currentChangeCount: 203,
                pasteboardHasFileURLs: false
            ) == .passThrough,
            "⌘X inside AXTextField (inline rename / search / Go to Folder) must passThrough"
        )
        expect(
            FinderKeyInterceptor.decideKeyEvent(
                keyCode: UInt16(kVK_Return),
                flags: [],
                isAutoRepeat: false,
                userData: 0,
                frontmostBundleID: finder,
                config: cfg,
                focusContext: textFieldFocus,
                cutState: &cutState,
                currentChangeCount: 203,
                pasteboardHasFileURLs: false
            ) == .passThrough,
            "Return inside AXTextField must passThrough to commit rename/search"
        )
        expect(
            FinderKeyInterceptor.decideKeyEvent(
                keyCode: UInt16(kVK_Return),
                flags: [],
                isAutoRepeat: false,
                userData: 0,
                frontmostBundleID: finder,
                config: cfg,
                focusContext: dialogButtonFocus,
                cutState: &cutState,
                currentChangeCount: 203,
                pasteboardHasFileURLs: false
            ) == .passThrough,
            "Return inside modal dialog must passThrough"
        )
        expect(
            FinderKeyInterceptor.decideKeyEvent(
                keyCode: UInt16(kVK_F2),
                flags: .maskSecondaryFn,
                isAutoRepeat: false,
                userData: 0,
                frontmostBundleID: finder,
                config: cfg,
                focusContext: sheetFocus,
                cutState: &cutState,
                currentChangeCount: 203,
                pasteboardHasFileURLs: false
            ) == .passThrough,
            "F2 inside attached sheet must passThrough"
        )

        // 5. Return -> .openSelected, F2 (with .maskSecondaryFn) -> .renameSelected, synthetic tag & non-Finder passThrough.
        expect(
            FinderKeyInterceptor.decideKeyEvent(
                keyCode: UInt16(kVK_Return),
                flags: .maskAlphaShift,
                isAutoRepeat: false,
                userData: 0,
                frontmostBundleID: finder,
                config: cfg,
                focusContext: browserFocus,
                cutState: &cutState,
                currentChangeCount: 203,
                pasteboardHasFileURLs: false
            ) == .openSelected,
            "Return in Finder file browser must emit .openSelected"
        )
        expect(
            FinderKeyInterceptor.decideKeyEvent(
                keyCode: UInt16(kVK_F2),
                flags: .maskSecondaryFn,
                isAutoRepeat: false,
                userData: 0,
                frontmostBundleID: finder,
                config: cfg,
                focusContext: browserFocus,
                cutState: &cutState,
                currentChangeCount: 203,
                pasteboardHasFileURLs: false
            ) == .renameSelected,
            "F2 (even with secondaryFn flag) in Finder file browser must emit .renameSelected"
        )
        expect(
            FinderKeyInterceptor.decideKeyEvent(
                keyCode: UInt16(kVK_ANSI_X),
                flags: .maskCommand,
                isAutoRepeat: false,
                userData: FinderKeyInterceptor.syntheticEventTag,
                frontmostBundleID: finder,
                config: cfg,
                focusContext: browserFocus,
                cutState: &cutState,
                currentChangeCount: 203,
                pasteboardHasFileURLs: false
            ) == .passThrough,
            "Synthetic 0x544C4258-tagged events must always passThrough"
        )
        expect(
            FinderKeyInterceptor.decideKeyEvent(
                keyCode: UInt16(kVK_Return),
                flags: [],
                isAutoRepeat: false,
                userData: 0,
                frontmostBundleID: "com.apple.TextEdit",
                config: cfg,
                focusContext: browserFocus,
                cutState: &cutState,
                currentChangeCount: 203,
                pasteboardHasFileURLs: false
            ) == .passThrough,
            "Non-Finder frontmost app must always passThrough"
        )
        expect(
            FinderKeyInterceptor.decideKeyEvent(
                keyCode: UInt16(kVK_Return),
                flags: [],
                isAutoRepeat: true,
                userData: 0,
                frontmostBundleID: finder,
                config: cfg,
                focusContext: browserFocus,
                cutState: &cutState,
                currentChangeCount: 203,
                pasteboardHasFileURLs: false
            ) == .swallowOnly,
            "Key-repeat on intercepted Return must swallowOnly instead of spamming ⌘O"
        )
    }

    private static func testLastWindowQuitEligibilityAndWindowCounting() {
        let allowlist = FinderEnhancerConfig.defaultAllowlistBundleIDs

        // 1. Protected system apps & Toolbox itself are never eligible even in allExceptExcluded mode.
        let protectedCases = [
            "com.apple.finder",
            "com.apple.Finder",
            "com.apple.dock",
            "com.apple.SystemUIServer",
            "com.toolbox.app"
        ]
        for bundleID in protectedCases {
            expect(
                !LastWindowQuitPolicy.isEligible(
                    bundleID: bundleID,
                    activationPolicy: .regular,
                    isSelfProcess: false,
                    selfBundleID: "com.toolbox.app",
                    mode: .allExceptExcluded,
                    allowlistBundleIDs: allowlist,
                    excludedBundleIDs: []
                ),
                "Protected bundle ID \(bundleID) must never be eligible for auto-quit"
            )
        }

        // 2. Accessory / prohibited background apps and self process are never eligible.
        expect(
            !LastWindowQuitPolicy.isEligible(
                bundleID: "com.example.Agent",
                activationPolicy: .accessory,
                isSelfProcess: false,
                selfBundleID: "com.toolbox.app",
                mode: .allExceptExcluded,
                allowlistBundleIDs: ["com.example.Agent"],
                excludedBundleIDs: []
            ),
            "Accessory activationPolicy apps must never be eligible"
        )
        expect(
            !LastWindowQuitPolicy.isEligible(
                bundleID: "com.example.Self",
                activationPolicy: .regular,
                isSelfProcess: true,
                selfBundleID: "com.example.Self",
                mode: .allExceptExcluded,
                allowlistBundleIDs: ["com.example.Self"],
                excludedBundleIDs: []
            ),
            "Self process must never be eligible"
        )

        // 3. Allowlist vs AllExceptExcluded filtering (case-insensitive).
        expect(
            LastWindowQuitPolicy.isEligible(
                bundleID: "com.apple.preview",
                activationPolicy: .regular,
                isSelfProcess: false,
                selfBundleID: "com.toolbox.app",
                mode: .allowlistOnly,
                allowlistBundleIDs: allowlist,
                excludedBundleIDs: []
            ),
            "Allowlist match should be case-insensitive for com.apple.preview"
        )
        expect(
            !LastWindowQuitPolicy.isEligible(
                bundleID: "com.google.Chrome",
                activationPolicy: .regular,
                isSelfProcess: false,
                selfBundleID: "com.toolbox.app",
                mode: .allowlistOnly,
                allowlistBundleIDs: allowlist,
                excludedBundleIDs: []
            ),
            "Non-allowlisted app must not be eligible in allowlistOnly mode"
        )
        expect(
            !LastWindowQuitPolicy.isEligible(
                bundleID: "com.google.Chrome",
                activationPolicy: .regular,
                isSelfProcess: false,
                selfBundleID: "com.toolbox.app",
                mode: .allExceptExcluded,
                allowlistBundleIDs: allowlist,
                excludedBundleIDs: ["com.google.chrome"]
            ),
            "Excluded app must not be eligible in allExceptExcluded mode"
        )
        expect(
            LastWindowQuitPolicy.isEligible(
                bundleID: "com.apple.Notes",
                activationPolicy: .regular,
                isSelfProcess: false,
                selfBundleID: "com.toolbox.app",
                mode: .allExceptExcluded,
                allowlistBundleIDs: allowlist,
                excludedBundleIDs: ["com.google.Chrome"]
            ),
            "Non-excluded regular app should be eligible in allExceptExcluded mode"
        )

        // 4. Relevant window counting: minimized & fullscreen count as open; zero only when none remain.
        let minimizedWindow = AXWindowSnapshot(role: "AXWindow", subrole: "AXStandardWindow", isMinimized: true, isFullScreen: false)
        let fullscreenWindow = AXWindowSnapshot(role: "AXWindow", subrole: "AXUnknown", isMinimized: false, isFullScreen: true)
        let popoverWindow = AXWindowSnapshot(role: "AXWindow", subrole: "AXSystemFloatingWindow", isMinimized: false, isFullScreen: false)
        let dialogWindow = AXWindowSnapshot(role: "AXWindow", subrole: "AXDialog", isMinimized: false, isFullScreen: false)

        expect(
            LastWindowQuitPolicy.countRelevantOpenWindows([minimizedWindow]) == 1,
            "Minimized window must count as open and block auto-quit"
        )
        expect(
            LastWindowQuitPolicy.countRelevantOpenWindows([fullscreenWindow]) == 1,
            "Fullscreen window must count as open and block auto-quit"
        )
        expect(
            LastWindowQuitPolicy.countRelevantOpenWindows([popoverWindow]) == 0,
            "Floating utility/popover subrole without standard/dialog/minimized must count as 0"
        )
        expect(
            LastWindowQuitPolicy.countRelevantOpenWindows([dialogWindow]) == 1,
            "Open dialog/sheet window must count as open"
        )

        // 5. Final grace-delay safety gate
        expect(
            !LastWindowQuitPolicy.shouldTerminateAfterGraceDelay(
                isRunning: true,
                isTerminated: false,
                isHidden: true,
                isEligible: true,
                relevantWindowCount: 0
            ),
            "Hidden app must never be auto-quit"
        )
        expect(
            !LastWindowQuitPolicy.shouldTerminateAfterGraceDelay(
                isRunning: true,
                isTerminated: false,
                isHidden: false,
                isEligible: true,
                relevantWindowCount: nil
            ),
            "Unknown AX window count (nil) must fail safe and block auto-quit"
        )
        expect(
            LastWindowQuitPolicy.shouldTerminateAfterGraceDelay(
                isRunning: true,
                isTerminated: false,
                isHidden: false,
                isEligible: true,
                relevantWindowCount: 0
            ),
            "Visible eligible running app with 0 remaining windows should pass termination gate"
        )
    }

    private static func testFinderEnhancerModuleLifecycleAndRegistry() {
        let registry = ModuleRegistry.shared
        guard let registered = registry.module(withID: "finder_enhancer") as? FinderEnhancerModule else {
            failures.append("ModuleRegistry must expose FinderEnhancerModule under id 'finder_enhancer'")
            return
        }
        expect(registered.category == .system, "FinderEnhancer category must be .system")
        expect(registered.requiresAccessibility, "FinderEnhancer must require Accessibility")
        expect(registered.supportsMenuBar && registered.supportsEnableToggle, "FinderEnhancer must support menu bar and toggle")

        var cfg = ToolboxConfig()
        expect(!registered.isEnabled(in: cfg), "FinderEnhancer must start disabled in default config")
        expect(registered.statusText(in: cfg, accessibilityGranted: true) == "Disabled", "Disabled status text mismatch")

        registered.setEnabled(true, in: &cfg)
        expect(cfg.finderEnhancer.enabled, "setEnabled(true) must mutate config.finderEnhancer.enabled")
        expect(registered.statusText(in: cfg, accessibilityGranted: false) == "Needs Accessibility", "Missing AX status text mismatch")

        cfg.general.appEnabled = false
        expect(registered.statusText(in: cfg, accessibilityGranted: true) == "Paused", "Master pause status text mismatch")

        // Lifecycle start/reload/stop cleanly tears down background tap and watchers
        let testModule = FinderEnhancerModule()
        var activeCfg = ToolboxConfig()
        activeCfg.general.appEnabled = true
        activeCfg.finderEnhancer.enabled = true
        testModule.reload(with: activeCfg)
        expect(testModule.isRunning, "FinderEnhancerModule must report isRunning = true when enabled")
        if PermissionsManager.isProcessTrusted() {
            expect(testModule.isKeyTapInstalled, "Key tap must install when Accessibility is granted")
            expect(testModule.runsKeyTapOnBackgroundThreadForTesting, "FinderKeyInterceptor must run on a dedicated background thread & CFRunLoop")
        }

        // Master pause stops cleanly
        activeCfg.general.appEnabled = false
        testModule.reload(with: activeCfg)
        expect(!testModule.isRunning && !testModule.isKeyTapInstalled, "Master pause must stop FinderEnhancerModule and uninstall key tap")

        // Re-enable then disable cleanly
        activeCfg.general.appEnabled = true
        testModule.reload(with: activeCfg)
        expect(testModule.isRunning, "Master resume must restart enabled FinderEnhancerModule")
        testModule.stop()
        expect(!testModule.isRunning && !testModule.isKeyTapInstalled, "stop() must tear down FinderEnhancerModule cleanly")

        // DeveloperHealthChecks integration
        expect(
            ToolboxConfigSection.allCases.contains(.finderEnhancer),
            "ToolboxConfigSection must include .finderEnhancer"
        )
        expect(
            DeveloperEventCategory.allCases.contains(.finderEnhancer),
            "DeveloperEventCategory must include .finderEnhancer"
        )
    }
}
