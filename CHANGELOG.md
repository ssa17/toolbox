# Changelog

All notable changes to Toolbox, newest first.

This file is the source of each release's **"what's new"**: at release time the
Fastfile turns the **Unreleased** section into the Sparkle release notes (shown
in the auto-update dialog), then resets the section to a fresh empty bucket.
Add a bullet under **Unreleased** whenever you ship something user-visible.

## [Unreleased]

### Added
- **Port Killer (`⌃ ⌥ ⌘ P`)** — inspect all active listening TCP ports (including root and other-user services via `netstat` + `lsof`), pin favorite dev ports, and stop or force-kill stuck servers in one click with macOS administrator authorization when needed
- Status Bar Menu: choose which features, quick-action buttons, and quick commands appear in the menu-bar popover, and reorder features via drag-and-drop or up/down controls in Settings
- Global toggle shortcuts for **Dock Click to Minimize** and **Scroll Direction**, plus `⌘ 1`–`⌘ 9` quick-paste in the Clipboard History popover
- Hidden PIN-gated **Developer Tools** (unlocked from Settings & About) with sidebar pages for simulating software updates and custom release notes, testing HUD toasts and Accessibility banners, inspecting live module events and window stacking, probing global hotkeys and config checkpoints/diffs, and running preflight signing and Gatekeeper health checks

### Changed
- Inline click-to-record shortcut controls across all modules with F-key and arrow-key support, clear/reset buttons, and one-click conflict resolution
- Streamlined **Custom Commands** layout with compact expandable rows, a collapsible New Command builder, top-positioned run output, and a menu-bar visibility toggle

### Fixed
- **Scroll Direction**: confine the interactive scroll test pad to the sample list bounds so scrolling elsewhere on the settings page works normally
- **Software Updates**: center the update dialog cleanly over the Toolbox window (or screen center when closed) and keep it centered across download and install transitions

## [1.0] - 2026-11-14

### Added
- **Dock Click to Minimize** — click the active app's Dock icon to hide its windows Windows-style (without cluttering the minimized Dock tray) and click again to bring them straight back, plus send-to-back and minimize modes
- **Clipboard History (`⌘ ⌥ V`)** — searchable floating clipboard dropdown with keyboard navigation, pinning, custom labels, password-manager filtering, and optional auto-paste
- **Keep Awake (`⌘ ⌥ K`)** — reads `pmset` display sleep timing and nudges the cursor just before sleep and/or holds an IOKit power assertion for a quick timer or indefinitely
- **Scroll Direction** — flip classic wheel-mouse scroll direction without touching trackpad or high-resolution scrolling
- **Custom Commands** — bind global shortcuts to shell scripts, apps, URLs, or text snippets with optional toast feedback
- **Menu-bar quick popover & JSON Config** — toggle Toolbox or individual modules, trigger actions from the menu bar, and edit `~/.config/toolbox/config.json` with live reload
- **Inline update checker & custom update dialog** — silent inline progress bar, version badge, and last-checked timestamp in Settings, paired with a dark update dialog and persistent indicators across the sidebar, dashboard strip, and menu bar when a release is available
