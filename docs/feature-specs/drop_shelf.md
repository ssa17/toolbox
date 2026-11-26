# Floating File Drop Shelf — Feature Spec

> **Status:** Planned · **Module:** `Modules/DropShelf/` · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
Dragging files, screenshots, or links across full-screen Spaces, cluttered Finder windows, or browser upload dialogs on macOS is clumsy: users often drop files onto the Desktop temporarily and forget to clean them up. **Floating File Drop Shelf** provides a Dropover-style, zero-permission floating staging tray triggered by shaking the cursor while dragging (or pressing `⌃ ⌥ ⌘ D`) so users can park items from multiple sources and drag or share them out together.

### User Flows & UX
- **Triggering the Shelf:**
  - **Shake while dragging (default ON):** Rapidly wiggling the pointer left-right while dragging a file, image, or link summons the shelf right beside the cursor.
  - **Global shortcut (`⌃ ⌥ ⌘ D`) or Menu Bar button:** Opens/toggles the shelf at the configured anchor (`Near Cursor`, `Top Right`, or `Bottom Right`).
- **Staging & Organizing Items:**
  - Users can drop multiple batches of files, folders, images, URLs, or text snippets onto the translucent `~280 × 180` pt shelf across any Space or full-screen app.
  - Shelf header displays item count and combined byte size (e.g., `"4 files · 3.2 MB"`), plus a `Clear` button and `Close` (`×` / `Esc`) button.
  - Rows/cards show file icon or image thumbnail, filename, size, and a remove (`×`) button.
- **Dragging Out & Quick Actions:**
  - Dragging any individual item or using **"Drag All"** starts an AppKit drag session (`[.copy, .generic]`) into Mail, Slack, Finder, or browser file inputs.
  - **Quick Actions bar:**
    - **Copy Files / Paths:** Copies file URLs (or paths) to `NSPasteboard.general`.
    - **Share:** Opens native `NSSharingServicePicker` (AirDrop, Mail, Messages, Notes).
    - **Compress to ZIP:** Packages staged files into a temporary `.zip` ready to drag or save.
    - **Optimize Images:** When staged items include images, sends them directly to `ImageCompressorModule` (if enabled).
  - Optional `autoCloseAfterDragOut` and `autoClearAfterDragOut` toggles reset the shelf cleanly once items are delivered.
- **Settings View (`DropShelfSettingsView.swift`):**
  - Built with `FeatureSection`, `SettingRow`, `Divider()`, `ShortcutRecorderView`, and `.pointerCursor()` on all controls.
  - **Trigger & Shortcut** section: global shortcut (`ShortcutRecorderView`), `Shake cursor while dragging to open` toggle, `Shake sensitivity` picker (`Low`, `Medium`, `High`), `Default anchor` picker (`Near Cursor`, `Top Right`, `Bottom Right`).
  - **Behavior & Capacity** section: `Auto-close after dragging out` toggle, `Auto-clear items after dragging out` toggle, `Max staged items` stepper (`10–100`).

### Files to Create
- `Sources/Toolbox/Modules/DropShelf/DropShelfModule.swift`
- `Sources/Toolbox/Modules/DropShelf/DragShakeDetector.swift`
- `Sources/Toolbox/Modules/DropShelf/ShelfItemStore.swift`
- `Sources/Toolbox/Modules/DropShelf/DropShelfPanelView.swift`
- `Sources/Toolbox/Modules/DropShelf/DropShelfSettingsView.swift`
- **Build link check:** Verify `.linkedFramework("UniformTypeIdentifiers")` in `Package.swift` if not already transitively linked.

### Module Metadata
- `id`: `"drop_shelf"`
- `name`: `"File Drop Shelf"`
- `tagline`: `"Shake while dragging or press ⌃ ⌥ ⌘ D to park files, images, and links in a floating shelf across apps and Spaces."`
- `symbolName`: `"tray.and.arrow.down"`
- `accentColor`: `Color.cyan`
- `category`: `.productivity`
- `requiresAccessibility`: `false`

### Technical Design & macOS APIs
1. **Zero-Permission Drag-Shake Detector (`DragShakeDetector`):**
   - Uses passive `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp])` (requires **zero** Accessibility or Screen Recording permissions).
   - Pure state machine tracking horizontal direction reversals (`>= 3` reversals within `450 ms`, minimum displacement per swing scaled by `ShakeSensitivity`, and `1.0 s` post-trigger cooldown).
   - **Text-Selection False-Positive Gate:** Only treat a drag as an item drag when `NSPasteboard(name: .drag).changeCount` changed since `mouseDown`/prior state or `NSPasteboard(name: .drag).pasteboardItems?.isEmpty == false`. Highlighting text in Safari or an editor never triggers the shelf.
2. **AppKit Drag-In & Drag-Out Host (`DropShelfDragHostView: NSView`):**
   - Implements `NSDraggingDestination` registering `[.fileURL, .URL, .png, .tiff, .string]` plus `NSFilePromiseReceiver.readableDraggedTypes`.
   - Materializes `NSFilePromiseReceiver` drops (e.g., photos dragged from Photos.app or Safari) asynchronously into `FileManager.default.temporaryDirectory/toolbox-drop-shelf/<sessionUUID>/`, sanitizing incoming filenames (stripping `/` and `..` path components) before writing.
   - For the **Compress to ZIP** quick action, invoke `/usr/bin/ditto -c -k --sequesterRsrc --keepParent` off the main thread for Finder-compatible, Unicode-safe archives.
   - Implements `NSDraggingSource` (`beginDraggingSession(with:event:source:)`) returning `[.copy, .generic]` (never `.delete` / `.move` by default so source files are never unexpectedly deleted).
   - Register the global shortcut via `HotKeyManager.shared` using key `"drop_shelf.toggle"` (wired into `inAppConflictDescription` and `clearConflictingShortcuts`).
3. **Floating Shelf Panel:**
   - Non-activating `NSPanel` (`styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView]`, `hidesOnDeactivate = false`, `acceptsMouseMovedEvents = true`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]`) hosted in `PointerCursorHostingView`, with hover tooltips in a separate `ignoresMouseEvents = true` child `NSPanel`.
   - **Dismissal rule:** Unlike `ClipboardModule`, do **not** auto-dismiss on outside click while items are staged (users must be able to click Finder/Mail/browsers to switch targets before dragging out). Dismiss via `Esc` (when focused), `Close`, or `autoCloseAfterDragOut`.
4. **Temp File Lifecycle (`ShelfItemStore`):**
   - Sweep stale `toolbox-drop-shelf-*` temp directories on launch (`sweepStaleTempFiles()`), when the shelf is cleared, in `stop()`, and in `AppDelegate.applicationWillTerminate(_:)`.

### Configuration (`DropShelfConfig`)
```swift
enum ShakeSensitivity: String, Codable, CaseIterable, Sendable {
    case low, medium, high
}

enum ShelfAnchor: String, Codable, CaseIterable, Sendable {
    case nearCursor = "near_cursor"
    case topRight = "top_right"
    case bottomRight = "bottom_right"
}

struct DropShelfConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var shortcut: ShortcutSpec = ShortcutSpec(key: "d", modifiers: [.control, .option, .command])
    var enableShakeToTrigger: Bool = true
    var shakeSensitivity: ShakeSensitivity = .medium
    var autoCloseAfterDragOut: Bool = true
    var autoClearAfterDragOut: Bool = true
    var defaultAnchor: ShelfAnchor = .nearCursor
    var maxItems: Int = 50
}
```
- `ToolboxConfig`: add `var dropShelf: DropShelfConfig = DropShelfConfig()` with lenient `decodeIfPresent` defaults, bump `schemaVersion`, and append `"drop_shelf"` to `GeneralConfig.defaultMenuBarModuleOrder`.

### Verification & Self-Tests
- **`DragShakeDetector` (`SelfTestRunner`):** Verify linear drag never triggers, 3 rapid horizontal reversals with active drag pasteboard trigger, slow sway below velocity threshold never triggers, `1.0 s` cooldown suppresses immediate re-trigger, `leftMouseUp` resets state, and `.low` / `.medium` / `.high` sensitivity thresholds behave monotonically.
- **`ShelfItemStore` (`SelfTestRunner`):** Verify add, URL/content deduplication, `maxItems` enforcement, byte-size aggregation, missing-file pruning, and temp directory cleanup.
- **Config (`SelfTestRunner`):** Verify `DropShelfConfig` `Codable` round-trip and partial JSON migration defaults.
- **Visual Snapshots (`SnapshotRunner`):** Render `module_drop_shelf.png` and `popover_drop_shelf.png`.

### Edge Cases & Pitfalls
- **Highlighting text vs dragging files:** Gating on `NSPasteboard(name: .drag)` prevents false triggers during text selection or window resizing.
- **Source file deleted while staged:** Re-validate `FileManager.default.fileExists` before drag-out/ZIP/share and surface a clean missing-file badge rather than failing silently.
- **Slow file promises:** Show an inline progress spinner while `NSFilePromiseReceiver` writes large images or mail attachments to the temp folder.
- **Multi-monitor bounds:** Clamp `nearCursor` panel origin to `NSScreen.visibleFrame` so the shelf never spawns half off-screen.
