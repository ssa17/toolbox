# Window Snapper — Feature Spec

> **Status:** Done · **Module:** `Modules/WindowSnapper/` · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

---

## 1. Purpose, Vision & Core Pillars

macOS Sequoia introduced basic edge-drag tiling (halves, corners, maximize), yet power users and multi-monitor workflows still hit immediate walls: no thirds or asymmetric splits, no custom per-display layouts, no spanning across grid cells, no visual 1:1 on-screen preview when configuring layouts, no automatic pre-snap size restore, and—most importantly—no way to switch an entire workspace into a predefined multi-app arrangement with one click or when plugging into an external display.

**Window Snapper** delivers a complete, cohesive window-tiling and workspace-automation system in one unified feature built around **two tightly linked pillars** that share a single zone, display, and on-screen preview engine:

1. **Pillar 1 — Interactive Zone Snapping (Drag & Keyboard):** Snap windows effortlessly by dragging to screen edges or corners, holding a modifier (`⇧`) to reveal full custom grid overlays with multi-zone spanning, dropping onto an optional top-edge layout bar, or firing conflict-free keyboard shortcuts—backed by smooth rectangle outline previews and automatic size restoration as soon as you drag a snapped window away.
2. **Pillar 2 — Predefined Workspace Profiles (One-Click Auto-Setup):** Define named workspace profiles (e.g., *Coding — Desk*, *Writing — Laptop*, *Review & Docs*) that bundle per-display zone layouts with ordered app-to-zone assignments. Activating a profile—from the Menu Bar, Dashboard, a global hotkey, or automatically when monitors dock/undock—positions running apps and optionally launches closed apps straight into their target zones.

Both pillars share the same normalized zone geometry, display identity registry, `AXUIElement` window controller, and 1:1 on-screen rectangle outline renderer, and both ship together as **one complete feature** (with independent toggles inside Settings so users can turn Drag Snapping or Keyboard Shortcuts on or off independently).

### Toolbox Architecture Alignment

- **Module Identity:** `id = "window_snapper"`, `name = "Window Snapper"`, `category = .windowAndDock` (alongside `DockMinimizeModule`), `symbolName = "rectangle.3.group"`, `accentColor = Color.indigo`, `requiresAccessibility = true` via `PermissionsManager.shared`.
- **Clean Module Isolation:** All runtime and UI code lives under `Sources/Toolbox/Modules/WindowSnapper/`.
- **Zero Coupling to Scroll Direction:** Scroll Direction (`ScrollInversionTap`) intercepts `.scrollWheel` events and classifies mice vs. trackpads via `kCGScrollWheelEventIsContinuous`—a field that does not exist on mouse drag events. Window Snapper must **not** depend on Scroll Direction; it uses `PermissionsManager.shared` directly for Accessibility and mirrors `ScrollInversionTap`'s dedicated background-thread `CGEventTap` pattern and `DockMinimizeModule`'s `CGWindowListCopyWindowInfo` + `AXUIElement` timeout patterns (sharing a small internal AX/window-stack helper where appropriate).
- **Apple CommandLineTools Compatibility:** Views and observable state strictly use `ObservableObject` / `@Published` / `@ObservedObject` (never `@Observable`), and all automated tests live in `SelfTestRunner.swift` (never `XCTest`).

---

## 2. Zones, Display Divisions & Layout Geometry (Shared Foundation)

### 2.1 Normalized Fractional Coordinates
Every zone in Toolbox is stored as a `NormalizedRect` (`x, y, width, height` in `[0.0, 1.0]`) relative to a display's **usable rect**, using a top-left logical origin (`x = 0` left, `y = 0` top). Because zones are resolution-independent:
- Layouts automatically survive HiDPI scaling changes, resolution switches, and monitor rotation (portrait vs. landscape).
- Moving a window to another display or applying a profile on a differently sized monitor preserves proportional placement.

### 2.2 Usable Display Rect (Menu Bar, Dock, Notch & Stage Manager)
A zone is never computed directly against `NSScreen.frame`. For each `NSScreen`, Toolbox computes its usable rect in AppKit screen coordinates before converting to AX top-left coordinates:
1. Start from `screen.visibleFrame` (automatically excludes the macOS menu bar and the Dock regardless of Dock edge or auto-hide state).
2. Subtract hardware camera-housing safe areas via `screen.safeAreaInsets` (`top`, `left`, `right`, `bottom`) so maximized or top-edge windows never clip under a MacBook Pro/Air notch.
3. **Stage Manager Strip Awareness (Optional, enabled by default):** Check `com.apple.WindowManager` defaults (`GloballyEnabled` and `AutoHide`). When Stage Manager is active and its recent-app strip is visible, reserve an inset strip on the strip side (`~78 pt` configurable) so snapped windows do not cover Stage Manager thumbnails.

### 2.3 Outer Screen Margin & Inner Tile Gap Math
Users configure:
- **Outer Margin ($P_{\text{out}}$):** Space between the screen usable rect boundary and outer window edges (`0–32 pt`, default `8 pt`; set to `0` for flush tiling).
- **Inner Gap ($G_{\text{in}}$):** Space strictly between neighboring tiles (`0–32 pt`, default `8 pt`).

**Exact non-overflowing math:**
- **For an $N$-cell division** along an axis with total usable span $S$ and positive relative weights $w_1, \dots, w_N$ (sum $W = \sum_{i=1}^{N} w_i$):
  $$\text{Available Span} = S - 2 P_{\text{out}} - (N - 1) G_{\text{in}}$$
  $$\text{Cell } i \text{ span} = \text{Available Span} \times \frac{w_i}{W}, \qquad \text{Cell } i \text{ offset} = P_{\text{out}} + \sum_{k=1}^{i-1} (\text{span}_k + G_{\text{in}})$$
  Rounding distributes any fractional sub-point remainder cleanly so adjacent tiles align pixel-exact without overflowing `Available Span`.
- **For arbitrary custom `NormalizedRect` zones:** Edges touching the outer boundary (`0.0` or `1.0` within epsilon `0.001`) inset by $P_{\text{out}}$; interior edges inset by $G_{\text{in}} / 2$ so any two adjacent custom zones still maintain an exact $G_{\text{in}}$ gap between them.

### 2.4 Built-In Division Presets, Custom Divisions & Universal Zones
Each display has an active layout built from a **DisplayDivision** (columns/rows with relative ratio weights) plus optional custom zones:
- **Built-In Division Presets:**
  - *Halves (1+1):* 2 equal columns (`50% / 50%`)
  - *Asymmetric (2+1):* 2 columns (`66.7% / 33.3%`)
  - *Thirds (1+1+1):* 3 equal columns (`33.3% / 33.3% / 33.3%`)
  - *Ultrawide Focus (1+2+1):* 3 columns (`25% / 50% / 25%`)
  - *Quarters (2×2):* 2 columns × 2 rows (`50% / 50%` × `50% / 50%`)
  - *Sixths (3×2):* 3 columns × 2 rows
  - *Vertical Stack (1×2 / 1×3):* Stacked horizontal bands tailored for rotated portrait monitors
- **Custom Divisions & Arbitrary Zones:** Users can adjust column/row counts and ratio sliders or draw/split custom rectangles directly at 1:1 scale on screen (§3.3) or inside Settings.
- **Universal Non-Cell Zones:** Available on every display regardless of its grid division:
  - **Maximize:** Full usable rect minus $P_{\text{out}}$.
  - **Center:** Centered fraction of usable rect (configurable default `70% × 80%`).
- **Per-Display Storage & Copy:** Each physical display (matched by `DisplaySignature`) stores its own active zone layout. A one-click **Copy Layout to Display…** action duplicates any monitor's layout onto another.

### 2.5 Multi-Zone Spanning
Instead of cluttering a 3-column layout with separate overlapping definitions for *Left 1/3*, *Center 1/3*, *Right 1/3*, *Left 2/3*, and *Right 2/3*, any contiguous group of cells in a division can be **spanned dynamically**:
- The spanned target rect is the bounding box of the selected cells' normalized rects (which naturally preserves outer $P_{\text{out}}$ margins and collapses interior $G_{\text{in}}$ seams between the merged cells).
- Works both interactively during `⇧`-drag (§4.2) and declaratively inside Workspace Profile rules (§6.1) by referencing a cell span (`zoneIDs` or `GridSpan`).

---

## 3. On-Screen Rectangle Outline Previews (First-Class Visual System)

A single reusable **`ZoneOverlayController`** renders one borderless, non-activating `NSPanel` per active `NSScreen`:
- `styleMask: [.nonactivatingPanel, .borderless]`
- `hidesOnDeactivate = false`, `hasShadow = false`, `backgroundColor = .clear`
- `level = .floating` (above normal application windows, below system alerts)
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`
- `ignoresMouseEvents = true` in all passive preview modes so overlays **never** steal focus or block pointer events; flipped to `false` only while the user explicitly enters **1:1 On-Screen Layout Editing** (§3.3).

This unified renderer powers **four visual preview modes**:

1. **Single-Zone Drag Preview:**
   - When a dragged window's pointer enters an edge, corner, or drop-bar target, the active display's overlay smoothly interpolates (using CoreAnimation on Toolbox's own panel—**never** animating the third-party app window via AX) a translucent indigo-tinted rounded rectangle with a crisp outline showing the exact post-gap frame the window will snap into.
   - Moving out of the target fades the outline out cleanly without moving the window.

2. **Full-Grid Drag Overlay (`⇧`-Drag):**
   - Holding the configurable Grid Modifier (default `⇧`) while dragging a window illuminates **every zone outline** on the pointer's current display simultaneously—subtle translucent fills, crisp dashed/solid borders, and clean zone badges/numbers.
   - Moving the pointer highlights the hovered cell; hovering within `12 pt` of a shared divider seam smoothly expands the highlighted outline across the **merged span of adjacent cells** (e.g., spanning columns 1 + 2 on a 3-column monitor). Releasing snaps straight into the highlighted rect.

3. **3-Second On-Screen Preview & Interactive On-Screen Layout Editor:**
   - **3-Second "Preview (3s)" Action:** Clicking **Preview (3s)** in *Display Zones* renders real-scale rectangle outlines directly onto connected monitor(s) for 3 seconds (auto-dismissing without needing a manual Hide action). Each on-screen outline displays its zone badge (`1`, `2`, `3`), name, and live point dimensions.
   - **"Adjust Dividers on Screen" Mode:** Clicking *Adjust Dividers on Screen* turns the selected display's overlay interactive (`PointerCursorHostingView` inside the `NSPanel`) styled with the user's active `OverlayStyleConfig`, letting the user choose a built-in template from the floating toolbar and drag its divider handles at 1:1 scale right on their actual desktop while viewing live percentage ratios and pixel dimensions (`Done` button saves and `Esc` or `Cancel` discards and returns to normal click-through mode).

4. **Workspace Profile Dry-Run Preview:**
   - Clicking **Preview (3s)** on any Workspace Profile in Settings or inside the Profile Draft Editor (or clicking the preview eye button in the Menu Bar) projects that profile's target rectangle outlines across **all connected displays** simultaneously for 3 seconds.
   - Inside each outlined rectangle, Toolbox renders the assigned app's **icon + name**, target zone label, and clear status badges:
     - *Ready* (app running on current Space)
     - *Will launch* (app closed, `launchIfNotRunning = true`)
     - *Main display fallback* (assigned external monitor is currently unplugged)
     - *Already placed* (window already sits inside the target frame)
   - Users see the exact multi-monitor arrangement before clicking **Apply**.

**Configurable Overlay Appearance & Tile Spacing (`OverlayStyleConfig` & `GapConfig`):** On *General* under *Overlay Appearance & Animation*, selecting any **Outline color**, **fill opacity**, **Outline thickness**, or **Zone labels** setting triggers a brief 1:1 on-screen flash preview (`zoneStyleFlash`) across connected monitors (`tintColor`, `0–32%` opacity, `1–7 pt` border width, zone badges & dimensions), alongside window animation speed. On *Display Zones*, **Drag Controls** configures the single canonical *Reveal grid while dragging* modifier, **Tile Spacing** adjusts uniform outer margins and inner gaps (`0–16 pt`) with an immediate 1:1 on-screen flash preview, and a quick **Reset** button restores customized divider ratios back to the selected template's defaults. On *Shortcuts*, choosing a **Center window size** preset (`Compact`, `Balanced`, `Large`) also triggers a 1:1 on-screen flash preview.

---

## 4. Interactive Drag-to-Zone Snapping

### 4.1 Pointer-Based Targeting & Confirmed Drag Detection
- **Always use Pointer Location (Never Window Edge):** §4 triggers off the **mouse cursor coordinates**, not the dragged window's edges. Dragging a wide browser window by the center of its title bar no longer fires false left-edge previews when the cursor is still `400 pt` away from the monitor border, and corners/middle columns remain unambiguous.
- **Confirmed Window-Drag Gate:** Passive monitoring (`CGEventTap` `.listenOnly`) watches `leftMouseDown` → `leftMouseDragged` → `leftMouseUp`:
  1. On `leftMouseDown`: capture the top-most standard window beneath the cursor (via `CGWindowListCopyWindowInfo` z-order + `AXUIElement` lookup on a serial AX queue—so dragging background/inactive windows works cleanly without activating them first), along with its **pre-drag `initialFrame`** and grab offset.
  2. Ignore windows belonging to ignored bundle IDs, fullscreen windows, non-standard sheets/popovers, or Toolbox's own overlays.
  3. On `leftMouseDragged`: verify the window's `kAXPositionAttribute` actually moved while `kAXSizeAttribute` remained unchanged. This cleanly filters out window-edge resizing, text selection inside editors, canvas drawing, scrollbar drags, and Dock icon drags.

### 4.2 Three Complementary Drag Entry Points
1. **Edge & Corner Magnetic Pull:**
   - Moving the cursor within `edgeProximityPoints` (default `12 pt`; `0` requires touching the screen edge) of a display edge or corner shows the Single-Zone Drag Preview:
     - Left / Right edges → Left Half / Right Half (or leftmost / rightmost column of the display's active layout).
     - Top edge → Maximize (edge-to-edge usable area).
     - Bottom edge → Left free for the Dock.
     - Top-Left / Top-Right / Bottom-Left / Bottom-Right corners (configurable corner band `default 48 pt`) → Quadrants.
2. **Modifier-Hold Full-Grid Overlay (`⇧` + Drag):**
   - Press and hold the Grid Modifier (`⇧` by default; `flagsChanged` updates the overlay immediately even mid-drag) to illuminate all zones on the cursor's display with multi-zone spanning.
3. **Optional Top-Edge Layout Drop Bar:**
   - Enabled via Settings (`showTopEdgeDropBar`, default `true`). When dragging a window near the top-center strip of any display (clear of the notch/menu bar center target), a compact non-activating floating tray slides down showing Left Half, Maximize, and Right Half (or custom display zones). Dragging over any mini-cell highlights its full-scale rectangle outline across the display behind it; releasing drops the window straight into that cell with zero modifiers to memorize.

### 4.3 Multi-Display Pass-Through Suppression & Restore on Drag-Away
- **Inter-Display Boundary Pass-Through Suppression:** When the cursor crosses an interior seam shared with another connected display (e.g., dragging from Laptop Left to External Right), Toolbox inspects recent pointer velocity and crossing direction. Fast outward transit across a shared display seam suppresses the outgoing display's edge zone so moving windows between monitors never feels sticky; pausing or reversing near the edge intentionally engages it.
- **Always-On Restore Size on Drag-Away:** Grabbing a window whose current frame matches a Toolbox snap immediately restores its pre-snap width and height as soon as drag movement crosses the threshold, re-anchored proportionally at the cursor's horizontal grab ratio along the title bar so the window stays naturally attached under the pointer.

### 4.4 Minimum-Size Pre-Flight Warning & Overflow Handling
- **Never refuse a snap just because the window is currently larger than the zone:** Shrinking a `1400 pt` window into a `700 pt` half or third is the primary job of a window snapper.
- Before committing, drag and keyboard previews read `kAXMinSizeAttribute` (or `NSWindow.minSize`). Whenever an app's minimum width or height exceeds the target zone (`+2 pt` tolerance), Toolbox highlights the preview outline in amber/orange with the exact minimum dimensions (`App min width 820 pt · won't shrink narrower`), draws a dashed actual-footprint box, and shows a warning `HUDToast` if clamping occurred on snap.

### 4.5 Snap-on-Release, Cancel & macOS Sequoia Native Tiling Coexistence
- **Snap-on-Release:** The target app window does not resize until `leftMouseUp` inside a previewed zone. Dragging away or pressing `Esc` dismisses the overlay without modifying the window.
- **macOS Sequoia Coexistence Banner:** On startup and when Settings opens, Toolbox reads `UserDefaults(suiteName: "com.apple.WindowManager")` (`EnableTilingByEdgeDrag`, `EnableTopTilingByEdgeDrag`, `EnableTilingOptionAccelerator`). If macOS native drag-to-edge tiling is enabled *without* its Option-key accelerator while Toolbox edge snapping is active, Settings displays a clear inline warning banner with a button to open *System Settings → Desktop & Dock* (advising the user either to disable native edge tiling or enable macOS's *"Hold Option key while dragging windows to tile"* so the two preview overlays never fight).

---

## 5. Keyboard Placement & Pre-Snap Restore

### 5.1 Conflict-Free Default Hotkeys & Preset Switcher
Following [Toolbox Feature Roadmap](../feature-roadmap.md) Checklist #4, default global shortcuts use Toolbox's **3-modifier chord family (`⌃⌥⌘`)** so enabling Window Snapper never breaks `⌃⌘D` (macOS Dictionary lookup), `⌃⌘←/→` (Xcode/IDE navigation), or `⌥⌘` browser/Finder shortcuts:

| Action | Default (`Toolbox Safe`) | `Rectangle Style` Preset | Notes |
|---|---|---|---|
| Left Half *(repeat cycles 1/2 → 2/3 → 1/3)* | `⌃ ⌥ ⌘ ←` | `⌃ ⌥ ←` | Configurable cycle toggle |
| Right Half *(repeat cycles 1/2 → 2/3 → 1/3)* | `⌃ ⌥ ⌘ →` | `⌃ ⌥ →` | Configurable cycle toggle |
| Top Half *(repeat cycles 1/2 → 2/3 → 1/3)* | `⌃ ⌥ ⌘ ↑` | `⌃ ⌥ ↑` | — |
| Bottom Half *(repeat cycles 1/2 → 2/3 → 1/3)* | `⌃ ⌥ ⌘ ↓` | `⌃ ⌥ ↓` | — |
| Top-Left / Top-Right / Bottom-Left / Bottom-Right | `⌃ ⌥ ⌘ 1–4` | `⌃ ⌥ U / I / J / K` | Quadrants |
| Maximize (Fill Usable Area) | `⌃ ⌥ ⌘ ↩` (`"return"`) | `⌃ ⌥ ↩` | Fills usable area edge-to-edge |
| Center | `⌃ ⌥ ⌘ C` | `⌃ ⌥ C` | Configurable fraction |
| Move to Previous / Next Display | `⌃ ⌥ ⌘ [` / `⌃ ⌥ ⌘ ]` | `⌃ ⌥ ⌘ ←` / `⌃ ⌥ ⌘ →` | Preserves normalized zone |
| Restore Pre-Snap Size (Un-snap) | `⌃ ⌥ ⌘ ⌫` (`"delete"`) | `⌃ ⌥ ⌫` | Also cancels active keyboard preview |

- **Hold-to-Preview, Release-to-Snap Flow:** Pressing any zone placement shortcut projects its zone outline preview across the active display (including repeated arrow taps while still holding the modifier chord to cycle `1/2 → 2/3 → 1/3`), commits the snap as soon as the shortcut modifiers are released, and cancels cleanly without moving the window if `⌫` (Backspace), `⌦`, or `Esc` is pressed before release.
- **One-Click Shortcut Preset Switcher:** In *Shortcuts*, users can switch between **Toolbox Safe (`⌃⌥⌘`)** (default), **Rectangle Style (`⌃⌥`)**, or **Manual (Unbind All)**, and bind shortcuts directly for every saved **Workspace Profile**.
- **Collision Detection & Cleanup:** Every non-empty shortcut in `WindowSnapperHotKeys` plus every per-profile hotkey and custom-zone hotkey is registered via `HotKeyManager.shared` under `"window_snapper.<action>"`, wired into `HotKeyManager.inAppConflictDescription(for:excludingSourceID:in:)` and `HotKeyManager.clearConflictingShortcuts(matching:excludingSourceID:in:)`, and cleanly unregistered in `stop()`.

### 5.2 Keyboard Target Resolution & Feedback
- Resolves the frontmost application's main standard window (`kAXMainWindowAttribute` fallback `kAXFocusedWindowAttribute`).
- If the focused window is in native macOS green-button fullscreen, skips placement cleanly and flashes a subtle `HUDToast` (`"Exit fullscreen to snap window"`).
- **Brief Post-Snap Visual Feedback (Configurable):** Shows a compact `HUDToast` (`"Safari → Left Half"`, or an orange warning toast when clamped for minimum size) and an optional `180 ms` outline flash of the landed zone, plus `NSAccessibility.post(element:notification:)` announcement for VoiceOver users.

---

## 6. Predefined Workspace Profiles (Auto-Setup Mode)

Workspace Profiles unify per-app placement rules and multi-monitor layout templates into **one clear, concrete concept**: a named profile describes both *how your displays are sliced* and *where your apps belong*, and activates everything in one action.

### 6.1 Profile Data Model
Each `WorkspaceProfile` contains:
1. **Identity & Trigger:** `id`, `name`, `symbolName` (SF Symbol), `accentHex`, optional global `shortcut: ShortcutSpec` (e.g., `⌃⌥⌘ 1` or `.none`).
2. **Per-Display Layout Overrides:** Optional mapping `[DisplaySignatureKey: DisplayLayoutConfig]` so activating *Coding — Desk* can switch an ultrawide to `1+2+1` while *Writing* switches it to `1+1`. (If unspecified for a display, keeps that display's default layout.)
3. **Ordered App Placement Rules (`[ProfileAppRule]`):**
   - **Application:** `bundleIdentifier` + cached `appName` (picked from installed/running apps or captured automatically).
   - **Target Display:** `.main`, `.anyExternal`, or `.specific(DisplaySignature)`.
   - **Target Zone:** `zoneID` / `cellSpan` (in the target display's layout) or an explicit fallback `NormalizedRect`.
   - **Multi-Window Policy (`ProfileWindowPolicy`):**
     - `frontmost`: Place the app's main/frontmost standard window (default).
     - `largest`: Place its largest standard window.
     - `titleContains(String)`: Match a specific window by case-insensitive title substring (e.g., `"Inbox"` vs `"Calendar"`).
     - `allTiledInZone`: Collect all visible standard windows of that app on the active Space and tile them evenly side-by-side or stacked inside the target zone.
   - **Launch If Not Running (`Bool`, default `true`):** If the app is closed when the profile activates, launch it via `NSWorkspace.shared.openApplication`, watch for its initial standard window via `AXObserver` (`kAXWindowCreatedNotification`) + debounced retry, and place it automatically into its assigned zone once created!
   - **Auto-Place New Windows While Active (`Bool`, default `false`):** Opt-in rule-level toggle: while this profile is marked active, automatically snap newly created standard windows of that app into its assigned zone. *(Deliberately **not** triggered on every app activation/focus switch so manually moving a window temporarily never fights the user.)*
4. **Profile Behavior Options:**
   - **Disconnected Display Fallback:** `moveToMainDisplay` (default), `moveToNextAvailableDisplay`, or `skipRule`.
   - **Un-minimize & Unhide Profiled Apps (`Bool`, default `true`):** Restores hidden apps (`NSRunningApplication.unhide()`) or Dock-minimized windows (`kAXMinimizedAttribute = false`) belonging to the profile before placing them.
   - **Hide Unlisted Apps (`Bool`, default `false`):** Optional focus-mode toggle that hides running regular apps not included in the profile.
   - **Display-Topology Auto-Trigger (`DisplayTopologyTriggerMode`):** Bind a profile to a connected-display signature set (e.g., *Built-in Only* vs *MacBook + Dell 32"*). On monitor connect/disconnect/wake (debounced `500 ms`):
     - `off` (default — manual apply only)
     - `askViaHUD`: Shows an actionable `HUDToast` / prompt (`"Desk monitors detected — Apply ‘Coding’?"`) — safe and non-disruptive.
     - `autoApply`: Applies the matching profile immediately.

### 6.2 Creating & Customizing Profiles
- Users create a blank profile via **New Profile** or choose a starter from **Starter…**, preview an unsaved draft directly with **Preview (3s)**, and customize the profile's display layout via template cards, **Copy from Display Zones**, or **Adjust Dividers on Screen** inside the Profile Editor.
- Inside each profile card (and the **Shortcuts → Workspace Profile Shortcuts** section), users can assign an instant global hotkey right alongside **Edit**, **Preview (3s)**, **Apply**, and **Delete**.

### 6.3 Profile Activation Flow & Feedback
Users can preview or apply any profile from:
- **Menu Bar Submenu:** Quick list of Workspace Profiles with **Preview (3s)** (dry-run outlines) and **Apply** actions directly under Window Snapper.
- **Dashboard / Settings:** Profile cards with active badge, inline shortcut recorder, **Preview (3s)**, **Apply**, and **Edit**.
- **Global Hotkey:** Instant apply via `HotKeyManager`.

When applied:
1. Record pre-apply frames of all targeted running windows in the pre-snap size store.
2. Bring hidden/minimized target windows back if configured, and optionally hide unlisted apps.
3. Place every currently running target window in parallel per PID (serialized per app so AX IPC never races within one app).
4. Launch any closed `launchIfNotRunning` apps asynchronously and place their initial standard windows within an `8 s` launch window (showing progress in `HUDToast`, e.g., `"Applied ‘Coding’ — 4 windows placed, launching Slack…"`).

---

## 7. Multi-Display & macOS Platform Engineering (`Technical Design & macOS APIs`)

### 7.1 File Structure (`Sources/Toolbox/Modules/WindowSnapper/`)
| File | Responsibility |
|---|---|
| `WindowSnapperModule.swift` | `ToolboxModule` conformance, lifecycle (`start`/`stop`/`reload`), `HotKeyManager` registration, workspace/display observers, coordinates engines. |
| `SnapGeometry.swift` | Pure math & value types: `NormalizedRect`, `DisplayDivision`, `ZoneDefinition`, multi-cell span union, `visibleFrame` + `safeAreaInsets` + Stage Manager usable rect, outer/inner gap math, AppKit bottom-left ↔ AX top-left coordinate conversion. Zero UI/AX dependencies; 100% unit-testable. |
| `DisplayRegistry.swift` | Enumerates `NSScreen` + `CGDirectDisplayID`, maintains live `[CGDirectDisplayID: DisplaySignature]` cache, resolves stable display identity across replugs/reboots, and handles identical-monitor collisions. |
| `AXWindowController.swift` | Dedicated serial background queue for AX IPC with `AXUIElementSetMessagingTimeout(..., 0.25)`, `kAXStandardWindowSubrole` & `AXFullScreen` filtering, clamping-safe `Size → Position → Size` / `Position → Size → Position` move sequence, min-size readback & clamping, live z-ordered window discovery (`CGWindowListCopyWindowInfo`), and pre-snap frame restoration store. |
| `WindowDragMonitor.swift` | Dedicated background `Thread` + `CFRunLoop` running a passive `.listenOnly` `CGEventTap` (`leftMouseDown`, `leftMouseDragged`, `leftMouseUp`, `flagsChanged`), re-armed via `PermissionsManager.shouldRearmEventTap`, confirmed-move detection, pass-through suppression, edge/corner + `⇧`-grid + spanning + top-edge bar hit-testing, and immediate restore-size-on-drag-away. |
| `ZoneOverlayController.swift` | Per-display `NSPanel` overlay renderer powering drag previews, 3-second Display Zone previews, Profile dry-run previews, and the optional Top-Edge Layout Drop Bar. |
| `ZoneOnScreenEditorView.swift` | Interactive 1:1 on-screen layout canvas (`PointerCursorHostingView`) for switching templates and dragging divider handles directly on any monitor. |
| `ProfileEngine.swift` | Profile activation, pre-snap frame capture, `NSWorkspace.openApplication` auto-launch + `AXObserver` (`kAXWindowCreatedNotification`) debounced retry placement, active-profile new-window watcher, Capture Current Workspace builder, and display-topology matcher. |
| `WindowSnapperSettingsView.swift` | Calm `FeatureSection` / `SettingRow` Settings UI (`ObservableObject` + `@Published`, `.pointerCursor()` on all interactive controls) split into 5 focused sub-tabs: *General* (Drag behaviors, Edge/Corner pull & Overlay Appearance/Animation), *Top Edge Panel*, *Display Zones* (per-display grid, Drag Controls, Tile Spacing & templates), *Profiles*, and *Shortcuts*. |

### 7.2 Critical macOS Implementation Details (Solved Up Front)
1. **AppKit ↔ AX Coordinate Inversion (Primary Screen Height Invariant):**
   - `NSScreen.frame` and `NSScreen.visibleFrame` use a **bottom-left** global origin where `(0, 0)` is the primary screen's bottom-left corner and $Y$ increases upward.
   - `AXUIElement` (`kAXPositionAttribute`) and `CGWindowListCopyWindowInfo` (`kCGWindowBounds`) use a **top-left** global origin where `(0, 0)` is the primary screen's top-left corner and $Y$ increases downward.
   - Always flip using the **primary screen's full height** ($H_{\text{primary}}$, the screen whose `frame.origin == .zero`, i.e., `NSScreen.screens.first?.frame.height`), **never** the target screen's height:
     $$Y_{\text{AX}} = H_{\text{primary}} - (Y_{\text{AppKit}} + \text{Height}_{\text{rect}})$$
2. **Cross-Display Clamping Dance (`Size → Position → Size`):**
   - macOS WindowServer clamps intermediate AX writes against the screen a window is *currently* on. Moving a large window onto a smaller external monitor by writing position before size causes WindowServer to reject or clip the coordinates.
   - `AXWindowController` performs an adaptive sequence on a background serial queue:
     - If shrinking on either axis or moving across displays: apply target **Size → Position → Size** (and re-read `kAXPositionAttribute` / `kAXSizeAttribute` to clamp origin inside usable rect if `kAXMinSizeAttribute` prevented shrinking).
     - If growing on the same display: apply **Position → Size → Position** so growth isn't clipped against the old origin.
   - Wrap AX calls with `AXUIElementSetMessagingTimeout(element, 0.25)` so hung apps can never stall Toolbox.
3. **Electron / Chromium `AXEnhancedUserInterface` Care:**
   - Chromium/Electron apps (VS Code, Chrome, Slack, Discord) stall heavily when `AXEnhancedUserInterface` is toggled rapidly on and off or hammered from the main thread. Toolbox **never** executes AX frame mutations on `@MainActor` or inside the `CGEventTap` callback, batches writes cleanly once on release/hotkey, and only checks/handles `AXEnhancedUserInterface` conservatively off the main thread.
4. **Electron / Chrome Launch Timing (`kAXWindowCreatedNotification` Race):**
   - Chromium and Electron apps often allocate hidden `0×0` helper windows or fire `kAXWindowCreatedNotification` before their renderer attaches or accepts `kAXPositionAttribute`/`kAXSizeAttribute`.
   - `ProfileEngine` verifies `kAXSubroleAttribute == kAXStandardWindowSubrole` and non-trivial minimum bounds (`width >= 100 && height >= 80`), then executes placement with a debounced retry/backoff schedule (`50 ms`, `150 ms`, `350 ms`, `750 ms`) up to an `8 s` per-app launch timeout.
5. **Stable Display Identity (`DisplayRegistry`):**
   - `CGDirectDisplayID` is transient across reboots/ports; `CGDisplayCreateUUIDFromDisplayID` provides a persistent UUID for distinct monitors, **but** fails during `kCGDisplayBeginConfigurationFlag` unplug callbacks, and **Apple Silicon Macs with two identical monitors** (same EDID, blank/zero serial) can swap or collide UUIDs on wake.
   - `DisplayRegistry` maintains a live in-memory `[CGDirectDisplayID: DisplaySignature]` cache updated on every `CGDisplayReconfigurationCallBack` completion, and builds a composite `DisplaySignature` (`uuidString`, `vendorNumber`, `modelNumber`, `serialNumber`, `localizedName`, `arrangementIndex` sorted left-to-right). Matching checks exact UUID first, then hardware tuple + arrangement slot when identical monitors collide, plus a manual **Reassign Display** button in Profile/Display settings.
6. **macOS Spaces Boundary (Zero Private APIs):**
   - macOS exposes no public, notarization-safe API to inspect or silently move windows sitting on *other* inactive macOS Spaces without triggering private `CGS*` calls. Toolbox keeps all `AXUIElement` placement cleanly on the **active Space** (consistent with `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`), while launched profile apps open naturally on the active Space.

### 7.3 Frameworks & `Package.swift`
All required Apple frameworks (`AppKit`, `SwiftUI`, `ApplicationServices`, `Carbon`, `IOKit`) are **already linked** in [Package.swift](../../Package.swift)—zero new third-party dependencies or Xcode entitlements are needed.

---

## 8. Configuration Schema (`WindowSnapperConfig`)

Add `var windowSnapper: WindowSnapperConfig = WindowSnapperConfig()` to `ToolboxConfig` (bumping `schemaVersion` from `10` to `11`, with backwards-compatible decoding for legacy `windowSnapping` / `"window_snapping"`), append `"window_snapper"` to `GeneralConfig.defaultMenuBarModuleOrder`, and decode every field with `decodeIfPresent(...) ?? default` for seamless backward-compatible migration:

```swift
import Foundation

struct NormalizedRect: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct ZoneDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var normalizedRect: NormalizedRect
    var shortcut: ShortcutSpec = .none
    var isCustom: Bool = false
}

struct DisplayDivision: Codable, Equatable, Sendable {
    var columnWeights: [Double] = [1.0, 1.0]
    var rowWeights: [Double] = [1.0]
}

struct DisplaySignature: Codable, Equatable, Hashable, Sendable {
    var uuidString: String
    var vendorNumber: UInt32
    var modelNumber: UInt32
    var serialNumber: UInt32
    var localizedName: String
    var arrangementIndex: Int
}

struct DisplayLayoutConfig: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var display: DisplaySignature
    var presetID: String = "halves"
    var division: DisplayDivision = DisplayDivision()
    var customZones: [ZoneDefinition] = []
    var outerMarginPoints: Double? = nil
    var innerGapPoints: Double? = nil
}

struct GapConfig: Codable, Equatable, Sendable {
    var outerMarginPoints: Double = 8
    var innerGapPoints: Double = 8
    var respectStageManagerStrip: Bool = true
    var stageManagerReservePoints: Double = 78
}

struct OverlayStyleConfig: Codable, Equatable, Sendable {
    var useAccentTint: Bool = true
    var fillOpacity: Double = 0.16
    var borderWidthPoints: Double = 2.0
    var cornerRadiusPoints: Double = 10.0
    var showZoneLabelsAndDimensions: Bool = true
    var flashOnKeyboardSnap: Bool = true
}

enum DragModifierChoice: String, Codable, CaseIterable, Sendable {
    case none = "none"
    case shift = "shift"
    case option = "option"
    case controlOption = "control_option"
    case optionCommand = "option_command"
}

struct DragSnapConfig: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var edgeProximityPoints: Double = 12
    var cornerBandPoints: Double = 48
    var snapOnTopEdgeMaximize: Bool = true
    var gridModifier: DragModifierChoice = .shift
    var spanModifier: DragModifierChoice = .controlOption
    var showTopEdgeDropBar: Bool = true
    var restoreSizeOnDragAway: Bool = true
}

struct WindowSnapperHotKeys: Codable, Equatable, Sendable {
    var leftHalf: ShortcutSpec = ShortcutSpec(key: "left", modifiers: [.control, .option, .command])
    var rightHalf: ShortcutSpec = ShortcutSpec(key: "right", modifiers: [.control, .option, .command])
    var topHalf: ShortcutSpec = ShortcutSpec(key: "up", modifiers: [.control, .option, .command])
    var bottomHalf: ShortcutSpec = ShortcutSpec(key: "down", modifiers: [.control, .option, .command])
    var topLeft: ShortcutSpec = ShortcutSpec(key: "1", modifiers: [.control, .option, .command])
    var topRight: ShortcutSpec = ShortcutSpec(key: "2", modifiers: [.control, .option, .command])
    var bottomLeft: ShortcutSpec = ShortcutSpec(key: "3", modifiers: [.control, .option, .command])
    var bottomRight: ShortcutSpec = ShortcutSpec(key: "4", modifiers: [.control, .option, .command])
    var maximize: ShortcutSpec = ShortcutSpec(key: "return", modifiers: [.control, .option, .command])
    var center: ShortcutSpec = ShortcutSpec(key: "c", modifiers: [.control, .option, .command])
    var previousDisplay: ShortcutSpec = ShortcutSpec(key: "[", modifiers: [.control, .option, .command])
    var nextDisplay: ShortcutSpec = ShortcutSpec(key: "]", modifiers: [.control, .option, .command])
    var restorePreSnap: ShortcutSpec = ShortcutSpec(key: "delete", modifiers: [.control, .option, .command])
}

enum ProfileTargetDisplay: Codable, Equatable, Hashable, Sendable {
    case main
    case anyExternal
    case specific(DisplaySignature)
}

enum ProfileWindowPolicy: Codable, Equatable, Hashable, Sendable {
    case frontmost
    case largest
    case titleContains(String)
    case allTiledInZone
}

enum ProfileDisconnectedFallback: String, Codable, CaseIterable, Sendable {
    case moveToMainDisplay = "move_to_main"
    case moveToNextAvailableDisplay = "move_to_next"
    case skipRule = "skip"
}

enum DisplayTopologyTriggerMode: String, Codable, CaseIterable, Sendable {
    case off = "off"
    case askViaHUD = "ask_via_hud"
    case autoApply = "auto_apply"
}

struct ProfileAppRule: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var bundleIdentifier: String
    var appName: String
    var enabled: Bool = true
    var targetDisplay: ProfileTargetDisplay = .main
    var targetZoneID: String
    var fallbackRect: NormalizedRect? = nil
    var windowPolicy: ProfileWindowPolicy = .frontmost
    var launchIfNotRunning: Bool = true
    var autoPlaceNewWindowsWhileActive: Bool = false
}

struct WorkspaceProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var symbolName: String = "rectangle.3.group"
    var shortcut: ShortcutSpec = .none
    var displayLayoutOverrides: [DisplayLayoutConfig] = []
    var appRules: [ProfileAppRule] = []
    var disconnectedFallback: ProfileDisconnectedFallback = .moveToMainDisplay
    var unminimizeAndUnhideApps: Bool = true
    var hideUnlistedApps: Bool = false
    var boundDisplaySignatures: [DisplaySignature] = []
    var topologyTriggerMode: DisplayTopologyTriggerMode = .off
}

struct WindowSnapperConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var keyboardSnappingEnabled: Bool = true
    var cycleRepeatedDirectionShortcuts: Bool = true
    var showSnapHUDToasts: Bool = true
    var ignoredBundleIDs: [String] = []
    var gaps: GapConfig = GapConfig()
    var overlayStyle: OverlayStyleConfig = OverlayStyleConfig()
    var drag: DragSnapConfig = DragSnapConfig()
    var hotKeys: WindowSnapperHotKeys = WindowSnapperHotKeys()
    var displayLayouts: [DisplayLayoutConfig] = []
    var profiles: [WorkspaceProfile] = []
    var activeProfileID: String? = nil

    init() {}
    // Implement lenient init(from decoder:) using decodeIfPresent(...) ?? default
}
```

---

## 9. Internal Implementation Plan (Build Chunks — Shipped as One Complete Feature)

All chunks below implement **one complete Window Snapper feature** and are verified together before shipping:

- **Chunk 1 — Core Geometry, Config & Display Registry:**
  Implement `SnapGeometry.swift`, `DisplayRegistry.swift`, `WindowSnapperConfig` + `ToolboxConfig` (`schemaVersion = 11`, menu bar order), and deterministic unit assertions in `SelfTestRunner`.
- **Chunk 2 — Reliable AX Window Controller & Pre-Snap Size Restore:**
  Implement `AXWindowController.swift` (serial AX queue, primary-height coordinate conversion, `Size → Position → Size` / `Position → Size → Position` move sequence, min-size clamping, standard-window/fullscreen filters, live z-ordered window list) and `PreSnapFrameStore`.
- **Chunk 3 — Unified On-Screen Rectangle Outline Renderer:**
  Implement `ZoneOverlayController.swift` with per-display click-through `NSPanel`s supporting Single-Zone Drag Preview, Full-Grid `⇧`-Drag Overlay with multi-zone spanning, 3-second Display Zone Preview, and Profile Dry-Run Preview with app icons.
- **Chunk 4 — Interactive Drag & Keyboard Engine:**
  Implement `WindowDragMonitor.swift` (dedicated background `.listenOnly` tap, confirmed-move detection, pointer edge/corner + `⇧`-grid + spanning + Top-Edge Drop Bar, inter-display pass-through suppression, immediate restore-size-on-drag-away) plus `HotKeyManager` registration, conflict wiring, repeat-press cycling, and Sequoia native-tiling conflict banner.
- **Chunk 5 — Workspace Profiles & Auto-Setup Engine:**
  Implement `ProfileEngine.swift` (multi-display profile application, pre-snap frame capture, `NSWorkspace.openApplication` auto-launch + `AXObserver` debounced retry placement, Capture Screen builder, and debounced display-topology trigger).
- **Chunk 6 — Settings UI, 1:1 On-Screen Editor, Menu Bar & Full Verification:**
  Implement `WindowSnapperSettingsView.swift` (using `FeatureSection`, `SettingRow`, `ShortcutRecorderView`, `.pointerCursor()`), `ZoneOnScreenEditorView.swift` (1:1 interactive desktop divider/custom-zone editor), Menu Bar quick Profile Apply/Preview menu items, `ModuleRegistry` registration, `SnapshotRunner` UI snapshots, complete `SelfTestRunner` suite, `CHANGELOG.md` entry, and full build/notarization verification.

---

## 10. Verification & Self-Tests (`SelfTestRunner` & `SnapshotRunner`)

All automated checks live in `Sources/Toolbox/Core/SelfTestRunner.swift` and `Sources/Toolbox/Core/SnapshotRunner.swift` (zero `XCTest`):

1. **Coordinate Conversion & Multi-Display Math (`SnapGeometry`):**
   - Round-trip AppKit bottom-left ↔ AX top-left coordinates across asymmetric multi-display geometries (including secondary displays above/below primary with negative $Y$ coordinates).
   - Usable rect computation incorporating `visibleFrame`, MacBook notch `safeAreaInsets`, and Stage Manager strip inset.
   - Outer margin ($P_{\text{out}}$) and inner gap ($G_{\text{in}}$) formulas across `1+1`, `2+1`, `1+1+1`, `1+2+1`, `2×2`, and `3×2` divisions, asserting zero overflow and exact interior gap symmetry.
   - Multi-cell span union geometry collapsing internal seams cleanly.
2. **Minimum-Size Clamping Logic:**
   - Assert normal shrink snaps (`1400 → 700`) are always permitted, and when a simulated `kAXMinSizeAttribute` exceeds zone bounds, the post-write origin clamps inside the display usable rect without overflowing into the Dock or menu bar.
3. **Display Registry Matching:**
   - Assert `DisplaySignature` matches exact UUID first, falls back to hardware tuple + arrangement index when identical monitors share/swap UUIDs, and resolves unplugged displays cleanly from the in-memory disconnect cache.
4. **Pre-Snap Frame Store:**
   - Assert initial frames are recorded per window, restored accurately when dragged away, and cleared after restoration.
5. **Config Migration, Conflicts & Sequoia Tiling Detection:**
   - `WindowSnapperConfig` JSON round-trip, legacy `"windowSnapping"` / `"window_snapping"` decode migration, and lenient decoding with missing/partial keys (`ToolboxConfig` migration from schema `10` to `11`).
   - `HotKeyManager.inAppConflictDescription` / `clearConflictingShortcuts` and clean unregister on `WindowSnapperModule.stop()`.
   - Pure Sequoia `com.apple.WindowManager` preference parser test (`EnableTilingByEdgeDrag` + `EnableTilingOptionAccelerator`).
6. **Visual Snapshots (`SnapshotRunner`):**
   - Render `module_window_snapper.png`, `module_window_snapper_minwidth.png`, `module_window_snapper_zones.png`, `module_window_snapper_profiles.png`, `module_window_snapper_shortcuts.png`, and `window_snapper_overlay_preview.png`.

---

## 11. Edge Cases, Pitfalls & Future Ideas

### Edge Cases & Pitfalls to Guard Against
- **Coordinate Flip Bug:** Always subtract from the **primary** screen's full height (`NSScreen.screens.first?.frame.height`), never the target screen's height—otherwise windows placed on secondary displays jump off-screen.
- **Clamping Order Bug:** Moving across differently sized displays in one wrong `Position`-before-`Size` step clips dimensions against the source screen; always run the adaptive `Size → Position → Size` / `Position → Size → Position` sequence with origin clamping.
- **Blocking `@MainActor` or `CGEventTap`:** Never perform `AXUIElement` IPC inside the `CGEventTap` callback or synchronously on `@MainActor`. Run the drag tap on a dedicated background `Thread` + `CFRunLoop` (`.listenOnly`) and dispatch AX mutations on a serial worker queue with `0.25 s` AX messaging timeouts.
- **Resizing / Text Selection False Positives:** Only engage drag-snapping after confirming the window's `kAXPositionAttribute` changed while `kAXSizeAttribute` stayed constant—never while resizing a window border or selecting text inside an app.
- **Electron / Chromium Startup Timing:** Apps like Chrome, VS Code, Slack, and Discord emit `kAXWindowCreatedNotification` for hidden `0×0` helper windows before their main window accepts AX frames; filter strictly for `kAXStandardWindowSubrole` + non-trivial bounds and retry with exponential backoff.
- **Identical Monitors on Apple Silicon:** Monitors with duplicate/blank EDID serials can collide on `CGDisplayCreateUUIDFromDisplayID` on wake; rely on `DisplayRegistry`'s composite `DisplaySignature` + manual display reassignment.
- **Sequoia Native Edge Tiling Conflict:** Two overlapping preview overlays confuse users; detect active macOS native drag tiling without the Option-key guard and guide the user directly in Settings.
- **macOS Spaces Boundary:** Never rely on undocumented private `CGS*` APIs to move windows across inactive Spaces; operate cleanly on the active Space so Toolbox stays Gatekeeper-notarized and macOS-upgrade resilient.

### Future Enhancements (Out of Scope for Initial Delivery)
- *Loop-style* single-modifier radial gesture wheel for trackpad flick snapping.
- Partner-window auto-tiling (snapping one window to Left Half automatically offers/places the previous window in Right Half).
- Habit promotion (suggesting saving a Profile rule after repeatedly snapping an app to the same zone).
- Window-relative snapping (hover over another window's edge to split relative to its frame).
- Aspect-ratio-preserving fit for media players and standalone *Snap Pad* menu-bar window picker.
