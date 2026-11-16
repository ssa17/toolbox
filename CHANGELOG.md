# Changelog

All notable changes to Toolbox, newest first.

This file is the source of each release's **"what's new"**: at release time the
Fastfile turns the **Unreleased** section into the Sparkle release notes (shown
in the auto-update dialog), then resets the section to a fresh empty bucket.
Add a bullet under **Unreleased** whenever you ship something user-visible.

## [Unreleased]

### Added
- **First-Open Accessibility Prompt** — explains which features use Accessibility (and what works without it) on first launch, with preview and reset controls in Developer Tools

### Changed
- **Dashboard & Readability** — refreshed the Accessibility banner, increased card and text contrast across the Dashboard and settings, and renamed **Clean Lock** to **Keyboard Lock** with clearer dusting/cleaning copy

### Fixed
- **Menu Bar & Multi-Display** — presented the status bar menu in a non-activating panel so macOS 26 keeps it open reliably even when Toolbox is in the background, and opened Toolbox's window on the display where your cursor is
- **Clipboard Popover** — auto-focused the search field on open so character keys filter immediately without alert beeps, fixed arrow-key scrolling in both directions, preserved the exact selected row and scroll position when closing full-text preview with Left Arrow, and made Delete/action buttons clearly visible
- **Port Killer** — automatically focused the search box every time the popover opens so you can type to filter or press `↓` to select rows immediately
- **Call Controls (Teams Sync & Mic Detection)** — synced hardware mute with Microsoft Teams' live in-app mute state, stopped idle background chat windows from hijacking global keybinds, and tracked per-process CoreAudio input streams so output sound effects no longer trigger the floating audio pill
- **DMG Installer** — expanded the installer backdrop canvas to eliminate white borders around the Finder window

## [1.2] - 2026-11-15

### Added
- **Call Controls (`⌃ ⌥ ⌘ M` / `⌃ ⌥ ⌘ V`)** — unified global Mic and Video shortcuts that mute your system microphone and control FaceTime, Microsoft Teams, Zoom, Slack, Google Meet, Discord, or custom call apps, paired with a draggable floating Mic/Camera status pill, output device cycling, and auto-mute while typing
- **Clean Lock** — temporarily lock your keyboard (including media, volume, and brightness keys) and mouse/trackpad input for `10s`–`3m` with a center-screen countdown and `Hold ⌃ ⌥ ⌘ Esc (3s)` emergency unlock
- **Clipboard History** — keep recent unpinned clipboard items across restarts by default, with a toggle in Privacy & Cleanup
- **Developer Tools** — added live background update schedule diagnostics and a Call Controls simulation and telemetry workspace

### Changed
- Expanded the **Dashboard** module grid up to 3 columns on wider windows and standardized **HUD Toast** height across all status icons

### Fixed
- Stabilized the Call Controls floating pill position when toggling Mic or Camera and fixed a crash when closing the pill

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
