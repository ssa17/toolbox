# Local Image Compressor & Cropper — Feature Spec

> **Status:** Planned · **Module:** `Modules/ImageCompressor/` · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
Students, writers, and developers frequently need to shrink oversized screenshots or photos for assignments, GitHub issues, Notion, or web uploads, crop out sensitive edges, and strip EXIF/GPS location metadata—without uploading private images to random web compressors. **Local Image Compressor & Cropper** (`⌃ ⌥ ⌘ I`) provides a 100% offline, zero-permission floating drop-zone and cropper powered by native `ImageIO` and `CoreImage`.

### User Flows & UX
- **Floating Compressor & Cropper Popover (`⌃ ⌥ ⌘ I` or Menu Bar / Settings):**
  - Opens a non-activating `NSPanel` (`~520 × 520` pt, hosted in `PointerCursorHostingView`) with a drag-and-drop / `⌘ V` paste / file-picker drop zone.
  - **Mode 1 — Batch Compress:**
    - Drop one or multiple images (`PNG`, `JPEG`, `HEIC`, `WebP`, `TIFF`, `GIF`, `BMP`) to see live `Before → After` file sizes and `% saved` per item.
    - Controls: Output format (`Keep Original`, `JPEG`, `PNG`, `HEIC`), Quality slider (`10%–100%` with `Light / Balanced / Max` presets), Max dimension cap (`Original`, `2048 px`, `1600 px`, `1280 px`, `800 px`), and **Strip EXIF / GPS Metadata** toggle (ON by default).
  - **Mode 2 — Quick Crop & Rotate:**
    - Selecting a single image opens a live crop canvas with draggable handles, aspect-ratio presets (`Free`, `1:1`, `16:9`, `4:3`, `3:2`), live pixel dimension readout, and `Rotate 90°` / `Flip` buttons.
  - **Outputs:** `Copy to Clipboard (⌘ C)`, `Save Alongside (-compressed)`, `Save to Folder…`, or explicit `Overwrite Originals` (atomic write with Trash backup option).
  - **Cross-Module Integration:** Can be opened directly with pre-loaded files from `DropShelf` quick actions.
- **Settings View (`ImageCompressorSettingsView.swift`):**
  - Built with `FeatureSection`, `SettingRow`, `Divider()`, `ShortcutRecorderView`, and `.pointerCursor()` on all controls.
  - **Shortcut & Defaults** section: global shortcut (`ShortcutRecorderView`), `Default output format` picker, `Default quality` slider, `Strip EXIF & GPS metadata` toggle, `Max dimension` picker.
  - **Save Behavior** section: `Save action` picker (`Save alongside with suffix`, `Copy to clipboard`, `Save to folder`), `Filename suffix` field (`-compressed`), `Default save folder` picker, `Show toast` toggle.

### Files to Create
- `Sources/Toolbox/Modules/ImageCompressor/ImageCompressorModule.swift`
- `Sources/Toolbox/Modules/ImageCompressor/ImageProcessingEngine.swift`
- `Sources/Toolbox/Modules/ImageCompressor/ImageCompressorPopoverView.swift`
- `Sources/Toolbox/Modules/ImageCompressor/ImageCompressorSettingsView.swift`
- **Build link check:** Verify `.linkedFramework("CoreImage")` and `.linkedFramework("UniformTypeIdentifiers")` in `Package.swift` if not already transitively linked.

### Module Metadata
- `id`: `"image_compressor"`
- `name`: `"Image Compressor"`
- `tagline`: `"Compress, strip EXIF/GPS metadata, resize, and crop images 100% offline with zero permissions."`
- `symbolName`: `"photo.badge.arrow.down"`
- `accentColor`: `Color.teal`
- `category`: `.productivity`
- `requiresAccessibility`: `false`

### Technical Design & macOS APIs
1. **Native `ImageIO` / `CoreImage` Pipeline (`ImageProcessingEngine`):**
   - **Decoding:** Use `CGImageSourceCreateWithURL` / `CGImageSourceCreateWithData` (supports PNG, JPEG, HEIC, WebP, TIFF, GIF, BMP natively on macOS 14+).
   - **Encoding:** Use `CGImageDestinationCreateWithData` for `UTType.png`, `UTType.jpeg`, and `UTType.heic`. *(Important: macOS `ImageIO` decodes WebP natively, but `CGImageDestination` does not ship a built-in WebP encoder—when `keepOriginal` receives a `.webp` input, encode to `.png` or `.jpeg` based on alpha presence and label the output extension clearly.)*
   - **EXIF Orientation Baking (Critical):** Read `kCGImagePropertyOrientation` from source properties and apply the corresponding `CIImage.oriented(forExifOrientation:)` / `CGContext` transform **before** stripping metadata, then write orientation `1` (or omit) so portrait iPhone photos never rotate sideways.
   - **Metadata Stripping:** When `stripMetadata == true`, copy only safe color-profile properties (`kCGImagePropertyColorModel` / ICC profile via `CGColorSpace`) and omit `{Exif}`, `{GPS}`, `{TIFF}`, `{IPTC}` dictionaries from `CGImageDestinationAddImage`.
   - **Crop & Downscale:** Apply normalized crop rect in pixel space, downscale proportionally only when `maxDimensionPixels > 0` and `max(width, height) > maxDimensionPixels` (never upscale), and drop unused alpha (`noneSkipLast`) when encoding opaque PNGs.
   - **Regression Guard:** If `outputFormat == .keepOriginal` with no crop, resize, or metadata strip and compressed bytes `>= originalBytes`, report `"Already optimized"` rather than writing a larger file.
   - **Safety Limits & Atomic Overwrite:** Reject corrupted or oversized (`> 100 MP`) images gracefully without crashing `CGImageSource`; when overwriting in place, write the temp file inside the **destination's parent directory** so `FileManager.default.replaceItemAt` stays atomic on the same APFS volume.
2. **Async Processing & Popover Lifecycle:**
   - Run batch compression inside `Task.detached(priority: .userInitiated)` with cooperative cancellation if the popover closes or the module stops.
   - Register the global shortcut via `HotKeyManager.shared` using key `"image_compressor.toggle"` (wired into `inAppConflictDescription` and `clearConflictingShortcuts`).
   - Host popover in a `.nonactivatingPanel` (`PointerCursorHostingView`, `hidesOnDeactivate = false`, `acceptsMouseMovedEvents = true`, paired global/local outside-click monitors + `Esc` to close).

### Configuration (`ImageCompressorConfig`)
```swift
enum ImageOutputFormat: String, Codable, CaseIterable, Sendable {
    case keepOriginal = "keep_original"
    case jpeg, png, heic
}

enum ImageSaveBehavior: String, Codable, CaseIterable, Sendable {
    case saveAlongsideWithSuffix = "save_alongside"
    case copyToClipboard = "copy_to_clipboard"
    case saveToFolder = "save_to_folder"
}

struct ImageCompressorConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var shortcut: ShortcutSpec = ShortcutSpec(key: "i", modifiers: [.control, .option, .command])
    var defaultOutputFormat: ImageOutputFormat = .keepOriginal
    var compressionQuality: Double = 0.78
    var stripMetadata: Bool = true
    var maxDimensionPixels: Int = 0
    var saveBehavior: ImageSaveBehavior = .saveAlongsideWithSuffix
    var filenameSuffix: String = "-compressed"
    var defaultSaveDirectory: String = "~/Desktop"
    var showToast: Bool = true
}
```
- `ToolboxConfig`: add `var imageCompressor: ImageCompressorConfig = ImageCompressorConfig()` with lenient `decodeIfPresent` defaults, bump `schemaVersion`, and append `"image_compressor"` to `GeneralConfig.defaultMenuBarModuleOrder`.

### Verification & Self-Tests
- **Metadata stripping (`SelfTestRunner`):** Create a synthetic `800 × 600` JPEG with embedded `{GPS}` and `{Exif}` dictionaries, process with `stripMetadata: true`, re-read via `CGImageSourceCopyPropertiesAtIndex`, and assert `{GPS}` and `{Exif}` are `nil`.
- **Crop, resize & EXIF orientation (`SelfTestRunner`):** Verify exact crop pixel dimensions, aspect-preserving downscale (and no-upscale when smaller than `maxDimensionPixels`), and portrait EXIF orientation `6` baking from `800 × 600` to upright `600 × 800`.
- **Compression & config (`SelfTestRunner`):** Verify JPEG/HEIC quality reduction lowers byte size on noisy synthetic image data, plus `ImageCompressorConfig` `Codable` round-trip.
- **Visual Snapshot (`SnapshotRunner`):** Render `module_image_compressor.png`.

### Edge Cases & Pitfalls
- **Color space washout:** Preserve Display P3 / ICC `CGColorSpace` rather than forcing generic RGB when encoding.
- **Animated GIF / multi-frame HEIC:** Warn clearly that compressing/cropping exports a single still frame.
- **Huge images (`> 100 MP`):** Downsample preview thumbnails with `CGImageSourceCreateThumbnailAtIndex` so the popover UI stays responsive without blowing memory.
- **Safe overwrite:** Always write to a temp file and use `FileManager.default.replaceItemAt` so a failed write never corrupts the original.
