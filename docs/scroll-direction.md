# Scroll Direction (per device): Investigation Findings & Implementation

Feature: invert the scroll direction of **one** pointing device (mouse by default) so the
trackpad and mouse can scroll in opposite directions, even though macOS only offers one
global scroll direction. Off by default; users turn it on per their preference.

Investigated on: macOS 27.2 (build 26B123), MacBook Pro Mac16,5 (M4 Max).

---

## 1. Why the two devices always follow each other (root cause)

On macOS 27 the Mouse and Trackpad settings panes are **ExtensionKit extensions**
(`System/Library/ExtensionKit/Extensions/{Mouse,Trackpad}Extension.appex`), and **both**
bind their "Natural scrolling" toggle to the *same* underlying setting:

- Single global key: **`com.apple.swipescrolldirection`** (global domain, per user/host).
- Single change notification: `SwipeScrollDirectionDidChangeNotification`.
- Live application via the private gesture backends: `MTTGestureBackEnd` (trackpads) and
  `MTMouseGesturesBackEnd` (mice), each with `_setSwipeScrollDirection` /
  `_swipeScrollDirection`; `activateSettings` additionally uses `CGSSetSwipeScrollDirection`
  over `CGSMainConnectionID` (a private WindowServer API).

Consequences (confirmed by static analysis of the extension binaries):

1. There is **one** direction value for the whole machine: the mouse-pane and trackpad-pane
   toggles are two faces of the same setting. macOS 27 does not offer per-device natural
   scrolling in System Settings (older versions had separate mouse and trackpad settings;
   the consolidation is a 27-era change).
2. The legacy per-device keys (`com.apple.AppleMultitouchTrackpad:TrackpadScrollDirection`,
   `com.apple.driver.AppleBluetoothMultitouch.trackpad:TrackpadScrollDirection`, the old mouse
   key, …) are not referenced anywhere in the new settings code.
3. The private backend classes are not defined in any on-disk dylib a third-party app could
   load, so System Settings' own mechanism cannot be reused.

**Decision:** work at the **event layer** instead. A session-level `CGEventTap` inverts
scroll deltas for the selected device class. This is version independent (macOS has kept the
scroll event model stable), works with any mouse (Bluetooth, USB, classic wheel or
high-resolution), never touches the system setting, and needs the standard Accessibility
permission only (the same one Dock Click to Minimize uses).

### The scroll event model (verified against the SDK + live event probes)

- `kCGScrollWheelEventIsContinuous` (field 88) is the class discriminator: non-zero for
  pixel-based (high resolution) scrolling = trackpad and high-res mice (Magic Mouse);
  zero for line-based (notch-per-step) scrolling = classic mouse wheels.
- The delta representations **interlock**: the line fields (`kCGScrollWheelEventDeltaAxis1/2`,
  fields 11/12) are the *master*: writing one re-derives the fixed-point (93/94) and pixel
  (96/97) mirrors from the line count, overwriting them. Writing the fixed-point or pixel
  fields has no cross side effects. The raw/accelerated fields (175-178) cannot be written
  through `CGEventSetIntegerValueField` at all.
- Real events: line-based events carry their true value in the line fields; pixel-based
  events carry their true value in the pixel fields with only a coarse derivative in the
  line fields.

Therefore the inverter (`ScrollInversionTap`) inverts, per event class:

- **Line-based (mouse wheels):** the pixel and fixed-point mirrors first, then the line
  fields *last* so the derived mirrors settle on the negated master (8 px/line, 16.16
  fixed-point).
- **Pixel-based (trackpad / high-res mice):** the pixel and fixed-point fields only. The
  line fields are deliberately left untouched: on a high-resolution event they are only a
  coarse derivative, and writing them would re-derive the pixel mirrors from the line
  count, destroying the high-resolution value.

`ScrollInversionTap.applyInversion(to:target:)` is a pure function of the event, unit
tested in `SelfTestRunner` with synthesized line and pixel events.

---

## 2. Implementation

### Module: `Modules/ScrollDirection/`

- **`ScrollDirectionModule.swift`** (`ScrollDirectionModule: ToolboxModule`)
  - id `scroll_direction`, category `.system`, icon `arrow.up.and.down`, accent `.pink`.
  - `requiresAccessibility = true` (it modifies events); the standard permission banner in
    `ModuleDetailViews` handles prompting/granting.
  - Off by default. `reload(with:)` starts/stops per `config.scrollDirection.enabled` and
    re-syncs the tap on every config or permission change
    (`PermissionsManager.onAccessibilityChanged` → registry reload in `AppDelegate`).
  - Status text: `Disabled` / `Paused` / `Needs Accessibility` / `Standby` /
    `Inverting Mouse` / `Inverting Trackpad`.
  - Exposes live stats (`eventsInverted`, `lastInvertedClass`, `isTapInstalled`) polled on
    a 2 s timer for the settings UI.
- **`ScrollInversionTap.swift`**: the event tap:
  - `CGEvent.tapCreate` at `.cgSessionEventTap` / `.headInsertEventTap` / `.defaultTap`
    (same placement style as DockMinimize), listening to `scrollWheel` only.
  - Runs on a **dedicated background `Thread` + `CFRunLoopRun()`** (`app.toolbox.scroll-inversion-tap`,
    never on the main thread's run loop) so scroll latency stays isolated from UI rendering.
  - Re-arms on `tapDisabledByTimeout` / `tapDisabledByUserInput`, and invalidates its `CFMachPort`
    + stops the background run loop cleanly on uninstall.
  - Tracks both `lastObservedClass` (for all incoming scroll events) and `eventsInverted` under lock (`@unchecked Sendable`).
  - Graceful without permission: `install()` returns false, the module reports
    `Needs Accessibility`, and the tap is created automatically once permission is
    granted (or removed again if it is revoked).
- **`ScrollDirectionSettingsView.swift`**: Inversion section (master switch +
  `Mouse | Trackpad` segmented target), an interactive **Preview** section (side-by-side device
  comparison tiles + hoverable scroll test pad showing live direction and line vs pixel class),
  and Live Status section (inverted-event count, last observed device class, permission badge).

### Plumbing

- `ConfigManager`: new `ScrollTarget` enum (`mouse`/`trackpad`) + `ScrollDirectionConfig`
  (`enabled: Bool = false`, `target: ScrollTarget = .mouse`, lenient decoding like the
  other module configs) + `ToolboxConfig.scrollDirection` field; schema bumped to 3.
  Older configs without the key decode to the safe defaults (covered by self-tests).
- `ModuleRegistry`: registers the module.
- `PermissionsManager`: `onAccessibilityChanged((Bool) -> Void)` fires on grant **and**
  revoke (replaces the grant-only callback); `AppDelegate` reloads all modules on change so
  permission-gated event taps start/stop correctly in both directions.
- `DashboardView`: the Accessibility banner copy now mentions Scroll Direction inversion.
- `SnapshotRunner`: renders `module_scroll.png` alongside the other key views.
- `SelfTestRunner`: three new suites (config + legacy migration; classification and
  inversion over synthesized line/pixel events, including the master/derived semantics;
  module lifecycle + registry + status text) → 15 suites total.

### Classification edge cases

- Classic mouse wheel (any vendor, Bluetooth or USB): line-based → inverted when target
  is `Mouse` (the default).
- Trackpad: pixel-based → untouched when target is `Mouse`; inverted when target is
  `Trackpad`.
- Magic Mouse / other high-resolution mice: pixel-based, i.e. classed like the trackpad.
  To invert one of those, pick `Trackpad` as the target. Live Status tracks `lastObservedClass`
  on every incoming scroll event (not only inverted ones), so if a mouse emits pixel-based events
  while `Mouse` is selected, Live Status surfaces `Trackpad` cleanly and prompts switching targets.

---

## 3. Verification (done)

- `./scripts/build-app.sh --fast` → clean build (CLT, no XCTest/SwiftUI-macros needed).
- `Toolbox --self-test` → all 15 suites pass, including the new scroll ones.
- `Toolbox --snapshot-ui .work/snapshots` → `dashboard_active.png` shows the module card
  (off by default, gray state dot) and `module_scroll.png` shows the settings view with
  the accessibility banner.
- Field interlock behavior verified with CoreGraphics event probes (see section 1); the
  inverter logic is exercised by self-tests with synthesized events.
- Manual check for the user: turn the module on, grant Accessibility, connect the mouse,
  scroll; the mouse should scroll opposite to the trackpad, and the Live Status count
  should tick up.
