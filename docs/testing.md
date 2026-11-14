# Testing & Debugging Toolbox

Follow this workflow when changing code, fixing UI bugs, or iterating on layout in Toolbox.

## 1. Pick the Fastest Verification Loop

| What you changed | Fastest useful check |
| --- | --- |
| Quick compile & test during iteration | `./scripts/build-app.sh --fast && ./build/Toolbox.app/Contents/MacOS/Toolbox --self-test` |
| UI layout, spacing, contrast, or status icon states | `./scripts/build-app.sh --fast && ./build/Toolbox.app/Contents/MacOS/Toolbox --snapshot-ui .work/snapshots` |
| AppKit / CGGeometry layout measurement script | `swift -e '...'` for quick geometry or font-metrics checks |
| Final release, Developer ID signing, & Gatekeeper verify | `pkill -x Toolbox 2>/dev/null \|\| true && ./scripts/build-app.sh --notarize && ./build/Toolbox.app/Contents/MacOS/Toolbox --self-test && spctl --assess --type execute --verbose ./build/Toolbox.app` |

**Development vs. Release**:
- Always iterate with `./scripts/build-app.sh --fast` (debug build, skips notarization) while fixing bugs and inspecting UI snapshots.
- Reserve `./scripts/build-app.sh --notarize` for the final release build after all tests and visual checks pass.

---

## 2. Config & Process Isolation

Toolbox uses a single-instance guard at startup and reads/writes `~/.config/toolbox/config.json` and `~/.config/toolbox/pinned_clipboard.json`.

Never let automated tests mutate live user configuration or focus/kill the user's running session unnecessarily during logic checks:

1. **Built-in diagnostic modes are automatically isolated**:
   - `--self-test` and `--snapshot-ui <dir>` automatically set `NSApp.setActivationPolicy(.prohibited)`, bypass the single-instance guard, disable file watching, and route `ConfigManager.shared` into a temporary directory under `NSTemporaryDirectory()`.
2. **Manual isolated launch**:
   - Pass `TOOLBOX_CONFIG_DIR=/tmp/toolbox-dev` in the environment to test full app state changes without modifying `~/.config/toolbox/config.json`.
3. **Avoid stale-binary confusion**:
   - Before inspecting a live UI change, verify which binary is actually running:
     ```bash
     pgrep -fl Toolbox
     stat -f "%Sm %N" ./build/Toolbox.app/Contents/MacOS/Toolbox
     ```
   - Kill old processes (`pkill -x Toolbox || true`) before launching a freshly built `.app` bundle.

---

## 3. Visual Inspection & Self-Debugging (`--snapshot-ui`)

When changing SwiftUI views, menu bar popover layout, status icons, or color hierarchy, do not guess how the rendered output looks:

1. Build `--fast` and generate offscreen dark-mode PNG renders of Dashboard, Module Detail, Menu Bar Popover (active + paused), and Status Bar Icons:
   ```bash
   ./scripts/build-app.sh --fast
   ./build/Toolbox.app/Contents/MacOS/Toolbox --snapshot-ui .work/snapshots
   ```
2. Open every generated PNG (`.work/snapshots/*.png`) using your file/image viewer tool and check for:
   - Card separation, alignment, text clipping, and spacing between elements
   - Clear visual distinction between **Active** (filled status bar emblem, normal badges) and **Paused** (outlined dimmed emblem, orange/muted badges)
   - Generous hit-target padding on interactive disclosure headers (e.g., `About This Feature`)
3. Remove temporary `.work/` artifacts or keep `.work/` untracked once verification finishes.

---

## 4. Regression Testing Rules

Every bug fix or behavior change must add or extend an assertion in `Sources/Toolbox/Core/SelfTestRunner.swift` (`Toolbox --self-test`):
- Config parsing / legacy migration (`testLegacyV1ConfigMigrationAndExtensions`)
- Shortcut spacing and key mapping (`testShortcutSpecTokensAndDisplaySpacing`)
- Master ON/OFF pause & resume lifecycle + instant zero-animation popover (`testMasterTogglePauseResumeAndInstantPopover`)
- Clipboard capture, deduplication, concealed types, pinning, and non-activating `NSPanel` behavior
- `pmset` parsing and `KeepAwakeModule` activation/deactivation
