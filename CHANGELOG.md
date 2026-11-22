# Changelog

All notable changes to Toolbox, newest first.

This file is the source of each release's **"what's new"**: at release time the
Fastfile turns the **Unreleased** section into the Sparkle release notes (shown
in the auto-update dialog), then resets the section to a fresh empty bucket.
Add a bullet under **Unreleased** whenever you ship something user-visible.

## [Unreleased]

### Added
- **Window** — Toolbox can now shrink to very small spaces (`340×300 pt` minimum, fitting smoothly into thirds, quarters, and multi-column grids) with a responsive single-column Dashboard and an auto-collapsing slide-over sidebar drawer below `700 pt`
- **Window Snapper** — snap windows cleanly with magnetic edge/corner drag targets (always maximizing on the top edge and respecting Dock edges of any size), `⇧`-hold full-grid overlays, a Windows 11-style Top Edge Panel where dragging onto any template mini-cell previews and snaps straight into that position (configured via an interactive visual Template Slots strip with click-to-assign/swap cards and slot reordering around centered Maximize, plus selectable `Compact / Match Panel / Wide` top-edge trigger width) and opens frosted glass panes only in unoccupied remaining cells so you can choose any open window — including additional windows of the same app — via footprint-scaled cards (showing live window thumbnails when Screen Recording is granted or app icon + name otherwise), descriptive presets (`Flush / Tight / Cozy / Relaxed / Spacious`, `Touch Edge / Tight / Medium / Wide`, `Small / Medium / Large / Extra Large`, `Edge Only / Close / Medium / Generous`) with brief on-screen trigger-zone flashes on distance & width presets, smooth macOS-style window transition animations with adjustable speed presets (`Off` / `Snappy` / `Smooth` / `Gentle`) and an inline interactive preview strip when snapping into or pulling out of zones, hold-to-preview `⌃ ⌥ ⌘` shortcuts (cycle with repeated taps, release to snap cleanly without leaving the preview open, `⌫` / `Esc` to cancel, plus a Rectangle-style preset), live minimum window-size warnings, improved detection and live reminders when macOS Desktop & Dock window tiling options conflict, per-display templates & 1:1 divider editor with 3-second desktop previews, `Flush` (`0 pt`) spacing by default with edge-to-edge Maximize, 6 selectable outline overlay color swatches with a `0%` outline-only option and thickness presets (`Thin` / `Medium` / `Thick` / `Bold`), and visual Workspace Profiles with inline shortcut bindings and display-topology auto-apply
- **Window Snapper** — added a **Maximized (1 App)** layout template in Workspace Profiles and Display Zones, and a toggleable shortcut behavior so pressing an active profile's shortcut a second time restores your previous windows and hidden apps
- **Clipboard** — pinned items can now be reordered: drag rows in the dropdown, use ⌘ ↑ / ⌘ ↓, or the right-click menu, and the saved order drives your ⌘ 1–9 quick paste
- **Dashboard** — a **Compact / Detailed** switcher next to the Modules heading smoothly expands or collapses module descriptions in place with balanced compact card spacing and hover feedback (and remembers your choice), making all modules easier to scan at a glance
- **Window Navigation** — navigate back and forward through visited pages with your mouse's Back/Forward buttons, swipe gestures, toolbar `<` / `>` buttons, or `⌘ [` / `⌘ ]`
- **Keyboard Lock** — a new **5-minute** duration option
- **Interaction Feedback** — a subtle press animation on buttons and controls app-wide, a momentary “Copied” confirmation on copy buttons (Custom Commands, Screen OCR, Config Editor), and a clear button in the Port Killer popover search field

### Changed
- **HUD Toasts** — floating notifications are now bigger (larger text and icon in a taller pill) and sit a little lower below the top of the screen so they’re harder to miss
- **Clipboard** — reorganized the dropdown into clean **Pinned** and **Recent** sections (moving **Clear All** to Recent), gave snippets full row width with top-right `⌘ 1–9` pills and larger hover/selection-revealed action buttons, and added multiline counts + relative timestamps
- **Status Bar Menu** — added subtle hover highlights to rows and buttons (including a soft red highlight on Quit), upgraded the popover backdrop to a higher-contrast frosted surface so text stays crisp over any app background (also applied to the Port Killer popover), and removed the “Check for Updates” button (updates still check automatically in the background, and an “Update to v<version>…” button appears whenever a new release is available)
- **Settings** — upgraded Status Bar Menu row drag-reordering to a smooth lifted-card interaction with live slot shifting, haptic ticks, Escape to cancel, and zero-jump drop settling
- **Design System** — an app-wide visual refresh: brighter accent colors and status badges on dark surfaces, higher-contrast switches and destructive buttons, uppercase section headers with accent-tinted cards, and selectable option cards for multi-choice settings (Keep Awake, Keyboard Lock, Port Killer, Clipboard)
- **Keyboard Lock** — the main button now shows the chosen duration (“Lock Input (3m)” / “Unlock Now (12s)”), is disabled with a hint when Toolbox is paused or Accessibility is missing, shows a “Resume Toolbox to use Keyboard Lock” toast when the shortcut fires while paused, and uses larger, crisper countdown text in the HUD
- **Keep Awake** — the duration picker is redesigned as compact chips (15m / 30m / 1h / 2h / 4h / ∞) with the custom field tucked below, and the quick-start button shows the default duration
- **Call Controls** — Settings is reorganized into Override Scope, Floating Pill & Notifications, and Typing Guard & Fallback sections with a responsive microphone/output quick-card layout
- **Scroll Direction** — the live test panel shows a pulsing device indicator and scroll direction instead of raw delta values
- **Dock Click to Minimize** — clearer one-line descriptions for each action on the Dashboard card and detail page

### Fixed
- **Window Snapper** — highlighting text or dragging controls inside a previously snapped window no longer triggers an unsnap move on release, Electron/custom-titlebar window drags stay reliable across rapid grabs, pulling a window down from Maximize or the top edge no longer pops open the Top Edge Panel (it only opens when dragging toward the top edge), and windows maximized via macOS titlebar double-click and snapped windows across Toolbox restarts remember and animate back to their original pre-snap size when pulled away
- **Window Snapper** — applying a Workspace Profile with **Hide other apps** enabled now also hides Toolbox's window, reopens running apps with no open windows, and tracks multi-app launches until each window's target zone placement is verified
- **Window Snapper** — Delete/Backspace (and Forward Delete) now reliably cancel keyboard snap preview mode while holding shortcut modifiers without leaking the keypress or firing Restore Window Size
- **Window Snapper** — pulling a snapped window out of its zone now restores the pre-snap size with a single resize instead of rewriting window coordinates during live drags, eliminating choppy movement while dragging away
- **Appearance & Buttons** — Toolbox windows, popovers, and HUDs now use a consistent dark theme on every Mac (while keeping the menu bar icon adaptive), and prominent colored buttons like **Lock Keyboard** always keep crisp white text and icons instead of turning dark or washing out in Light Mode or unfocused windows
- **Status Bar Menu** — pausing Toolbox from the master toggle no longer causes the popover to jump in height; all sections stay visible while paused modules, quick actions, and quick commands are dimmed and disabled
- **Status Bar Menu** — opening the menu-bar popover no longer pulls the Dashboard window to the front; it stays in the background until you choose to open it
- **Dock Click to Minimize** — excluded apps now match case-insensitively, and the running-app list no longer includes Toolbox itself
- **Keyboard Lock / Keep Awake / Screen OCR** — actions no longer fail silently while Toolbox is paused; they are disabled with a “Resume Toolbox first” hint
- **Shortcut Recorder** — a shortcut being drafted resets when its window loses focus or closes, and key-only shortcuts show a clearer hint

## [1.5] - 2026-11-19

### Changed
- **Software Update** — the update dialog is wider and shows release notes with proper formatting (group headings, bullets, and bold lead-ins) instead of raw Markdown, and the Dashboard banner and status-bar menu now show the download size when a new release is detected
- **Main Window** — increased the default Dashboard window size so the 3-column module grid and detail pages fit comfortably on open
- **Support Toolbox** — moved support links to a dedicated **Support Toolbox** sidebar page with prominent **Sponsor on GitHub** and **Support on Ko-fi** cards, a **Free Ways to Help** card grid, a high-five confetti button, and an honor-system **Supporter ♥** badge (shown in the sidebar, Settings, window titlebar, and a custom gold-accented Dock icon)

### Fixed
- **Dock Click to Minimize** — Dock icons can be dragged to reorganise again; the click action now waits for the release and yields to the Dock whenever you drag, instead of firing on press and swallowing the gesture
- **Accessibility & Permission Flow** — fixed a crash when closing the Accessibility explanation sheet, a Mac-wide input freeze when revoking Accessibility in System Settings, and a duplicate Accessibility prompt at startup; permission state no longer goes stale after changes in System Settings, and the Dashboard setup banner walks through Accessibility → Screen Recording step by step and returns you to Toolbox

## [1.4] - 2026-11-17

### Added
- **Screen OCR (`⇧ ⌘ 0`)** — drag-select any area of the screen to copy unselectable text or decode QR/barcodes with on-device Apple Vision OCR, with fast/accurate modes, line-break and toast options, and a recent-captures list in Settings
- **Developer Tools** — a dedicated Screen OCR section with a stage-by-stage live capture test that pinpoints exactly where a capture fails, permission and environment inspection, an offline recognition self-check, and OCR event history
- **Support Links** — GitHub Sponsors and Ko-fi links under Settings → About Toolbox

### Changed
- **Call Controls** — camera on/off is now tracked alongside mic mute so the floating pill and the call session stay consistent when video toggles, all mapped call apps are monitored at once, and the pill shows a short app name for the video target
- **Screen OCR** — recognizes more of the screen and keeps its structure: small text in large captures is no longer silently dropped, and multi-line selections come out as real lines and paragraphs instead of one merged line

### Fixed
- **Screen OCR** — a capture that finishes after the module is disabled or the app is paused no longer writes to the clipboard, and empty results no longer false-positive on dark-themed UIs (terminals) as "screen might be blank"; failed captures are kept on disk for Reveal / Re-analyze in Developer Tools
- **Call Controls** — browser-hosted web calls (Google Meet, Zoom web, etc.) no longer press the browser's own menu items by mistake, and the floating pill lands on the correct screen when pinned near a shared monitor boundary

## [1.3] - 2026-11-16

### Added
- **First-Open Accessibility Prompt** — explains on first launch which features use Accessibility (and what still works without it), with preview and reset controls in Developer Tools

### Changed
- **Dashboard & Readability** — refreshed the Accessibility banner, increased card and text contrast across the Dashboard and settings, and renamed **Clean Lock** to **Keyboard Lock** with clearer copy

### Fixed
- **Menu Bar & Multi-Display** — the status bar menu now stays open reliably when Toolbox is in the background, and the window opens on the display where your cursor is
- **Clipboard Popover** — the search field auto-focuses on open so keys filter immediately (no alert beeps), arrow-key scrolling works in both directions, and closing the full-text preview with Left Arrow keeps your exact row and scroll position
- **Port Killer** — the search box auto-focuses on open so you can type to filter or press `↓` to select rows immediately
- **Call Controls** — in-app mute status syncs cleanly when joining calls, the **Also Mute macOS Hardware Mic** toggle works in all scopes, idle background chat windows no longer hijack mic/video toggles during an active Slack call, and the floating pill only appears during real calls
- **DMG Installer** — removed white borders around the Finder window in the installer backdrop

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
