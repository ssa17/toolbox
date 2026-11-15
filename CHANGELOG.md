# Changelog

All notable changes to Toolbox, newest first.

This file is the source of each release's **"what's new"**: at release time the
Fastfile turns the **Unreleased** section into the Sparkle release notes (shown
in the auto-update dialog), then resets the section to a fresh empty bucket.
Add a bullet under **Unreleased** whenever you ship something user-visible.

## [Unreleased]

### Added
- **Call Controls** — set one unified Mic (`⌃ ⌥ ⌘ M` default) & Video (`⌃ ⌥ ⌘ V` default) keybind that works anywhere (`Everywhere` scope by default) to mute your macOS microphone system-wide and override FaceTime (mic), Microsoft Teams, Zoom, Slack, Google Meet, and Discord (including silent Accessibility menu-item triggering without focus loss for FaceTime), monitor live Mic and Camera status on a top-right draggable floating pill (`[≡] | Mic | Video | ✕`, shown automatically during active calls by default with an inline **Pill** toggle on the Call Controls status bar row and proper hover cursors over any app), add custom call apps via an app selector that scans menu bar controls automatically, cycle favorite outputs, and auto-mute while typing
- **Clean Lock** — temporarily lock your keyboard (including media, volume, and brightness keys) and trackpad/mouse clicks & scrolling with a large center-screen countdown (`10s`–`3m`), live blocked-input counter, and a `Hold ⌃ ⌥ ⌘ Esc (3s)` emergency kill switch
- **Clipboard History** — persist recent unpinned clipboard history across restarts by default, with a **Keep unpinned history across restarts** toggle in Privacy & Cleanup
- Developer Tools (**Updates** & **Call Controls**): added a **Background Check Schedule** section with a live auto-check countdown, a one-shot 5-second scheduled check test, and session check outcomes, plus a **Call Controls** workspace with simulated call scenarios (Zoom, FaceTime, Slack, Teams, Meet, Discord, no-app, typing auto-mute), an interactive floating pill preview stage, keybind routing dry-run & toast tester, Accessibility menu bar control probe, and live CoreAudio/CoreMediaIO telemetry

### Changed
- **Dashboard** — expand the module grid up to 3 columns on wider windows
- **HUD Toast** — keep toast height consistent across all status icons

### Fixed
- Stabilized the Call Controls floating pill's top-right position when toggling Mic or Camera, and fixed a crash when closing the pill with `✕`

## [1.1] - 2026-11-15

### Added
- **Port Killer (`⌃ ⌥ ⌘ P`)** — inspect active listening TCP ports, pin favorite dev ports, and stop or force-kill stuck servers in one click with macOS authorization when needed
- **Status Bar Menu** — choose which features, quick actions, and custom commands appear in the menu-bar popover, and reorder features in Settings
- Global toggle shortcuts for **Dock Click to Minimize** and **Scroll Direction**, plus `⌘ 1`–`⌘ 9` quick-paste in the Clipboard History popover
- **Developer Tools** — hidden PIN-gated workspace in Settings & About for simulating software updates and release notes, testing toasts and Accessibility states, monitoring live module events and window order, testing global hotkeys and config diffs, and verifying code signing and Gatekeeper health

### Changed
- Inline click-to-record shortcut controls across all modules with F-key and arrow-key support, clear/reset buttons, and one-click conflict resolution
- Streamlined **Custom Commands** layout with compact expandable rows, a collapsible builder, top-positioned output, and a menu-bar toggle

### Fixed
- Confined the **Scroll Direction** test pad to the sample list bounds so scrolling elsewhere on the settings page works normally
- Centered the software update dialog cleanly over the Toolbox window across all download and install stages

## [1.0] - 2026-11-14

### Added
- **Dock Click to Minimize** — click the active app's Dock icon to hide its windows Windows-style (without cluttering the minimized Dock tray) and click again to bring them straight back, plus send-to-back and minimize modes
- **Clipboard History (`⌘ ⌥ V`)** — searchable floating clipboard dropdown with keyboard navigation, pinning, custom labels, password-manager filtering, and optional auto-paste
- **Keep Awake (`⌘ ⌥ K`)** — reads `pmset` display sleep timing and nudges the cursor just before sleep and/or holds an IOKit power assertion for a quick timer or indefinitely
- **Scroll Direction** — flip classic wheel-mouse scroll direction without touching trackpad or high-resolution scrolling
- **Custom Commands** — bind global shortcuts to shell scripts, apps, URLs, or text snippets with optional toast feedback
- **Menu-bar quick popover & JSON Config** — toggle Toolbox or individual modules, trigger actions from the menu bar, and edit `~/.config/toolbox/config.json` with live reload
- **Inline update checker & custom update dialog** — silent inline progress bar, version badge, and last-checked timestamp in Settings, paired with a dark update dialog and persistent indicators across the sidebar, dashboard strip, and menu bar when a release is available
