# Changelog

All notable changes to Toolbox, newest first.

This file is the source of each release's **"what's new"**: at release time the
Fastfile turns the **Unreleased** section into the Sparkle release notes (shown
in the auto-update dialog), then resets the section to a fresh empty bucket.
Add a bullet under **Unreleased** whenever you ship something user-visible.

## [Unreleased]

### Added
- **Finder Enhancer** — move files in Finder with `⌘ X` → `⌘ V`, open selected items with `Return` (or rename with `F2`) without disrupting inline editing or dialogs, and optionally auto-quit allowlisted or non-excluded apps after their last window closes
- **Clipboard Image History** — capture screenshots and copied images with thumbnails, filters, metadata previews, pinning, instant paste, Save As export, and configurable local cache limits

### Changed
- **Clipboard** — after deleting an item, the highlight moves to the item below it (or the item above it if there is none) instead of jumping back to the top of the list

### Fixed
- **Status Bar Tooltip** — the "Toolbox (Active)" tooltip could linger and appear away from the menu bar without a reliable way to dismiss it; the status bar icon and popover header now convey the Active/Paused state instead
- **Window Snapper (Lock, Sleep & Wake)** — locking the screen or letting displays sleep no longer counts as a display change, so waking the Mac keeps your layout instead of re-applying the auto profile and flashing a "Display Detected" loading toast
- **Window Snapper (Startup)** — turning Window Snapper on no longer re-applies the auto profile when the connected display setup hasn't actually changed, and duplicate reconfigure events no longer stack a second loading toast

## [1.6.3] - 2026-11-26

### Added
- **Bluetooth Headphone Stereo** — Call Controls can keep AirPods and Bluetooth headsets in rich stereo by using your Mac or USB microphone instead of the headset's, so music and video no longer drop into muffled call audio or the "hearing yourself" effect
- **Microphone To Use Instead** — choose which microphone apps capture from while your headphones stay in stereo, defaulting to Auto (USB, then built-in)
- **Allow Headset Mic** — switch to the headset's own microphone for as long as it stays connected, then Toolbox resumes protecting stereo on its own
- **Clear guidance when an app takes over** — if an app such as Teams grabs the headset microphone for itself, Call Controls names that app and the exact setting to change, instead of quietly failing

## [1.6.2] - 2026-11-25

### Added
- **Window Snapper (Multi-Display Profiles)** — design 1-, 2-, and 3-display layout variants inside one Workspace Profile, choose a profile to auto-apply when monitors connect, set an Always Extend or Always Mirror display-connect preference, identify screens on-screen, capture open windows into a view, and swap External 1 & 2 in one click
- **Window Snapper (Smooth Profile Transitions)** — choreographed entry, reposition, and exit animations across profile switches and display changes, paired with an instant display-detect and loading HUD pill

### Changed
- **Window Snapper (Profiles & Top Edge Panel)** — decluttered profile cards and a calmer Profile Editor with drag-to-assign apps, drag-to-swap zones, an auto-collapsing layout picker, Save & Apply, and a refined frosted-glass Top Edge Panel with smooth drop-down arrival
- **HUD Toasts** — upgraded floating toasts with tinted icon badges, subtitles, and smooth fade-in transitions

### Fixed
- **Window Snapper** — prevented duplicate or orphaned app rules from launching unintended apps, eliminated window flashing while connecting displays, and ensured Save & Apply always applies the profile instead of toggling restore
- **Dock Minimize** — moved Dock icon inspection to a background cache so Dock clicks stay responsive without stalling input delivery

## [1.6.1] - 2026-11-23

### Added
- **Software Updates** — link to the full release notes on GitHub from the update dialog, the pending-update card in Settings, and the About Toolbox section, so you can see what's new even when you're up to date

### Changed
- **Window Snapper** — pressing an active Workspace Profile again restores the previous workspace from every activation path — keyboard shortcut, Apply button, and status bar menu — with a **Restore** affordance (button label + status bar pill) when a restore is available

## [1.6] - 2026-11-22

### Added
- **Window Snapper** — snap windows with magnetic edges & corners, a Top Edge Panel with frosted glass panes for filling empty slots, customizable per-display grids with a 1:1 on-screen divider editor, smooth window glide animations, hold-to-preview keyboard shortcuts (plus a Rectangle-style preset), 1:1 on-screen previews on style & trigger controls, and one-click Workspace Profiles with shortcut toggle-restore and display auto-apply
- **Appearance (Text Size)** — choose **Small**, **Standard**, **Large**, or **Extra Large** text in Settings to scale typography live across windows, popovers, the JSON editor, and HUDs
- **Compact Window & Navigation** — shrink Toolbox down to `340×300 pt` with an auto-collapsing sidebar, switch between **Compact** and **Detailed** Dashboard cards, and navigate back/forward via mouse buttons, swipes, toolbar arrows, or `⌘ [` / `⌘ ]`
- **Clipboard & Keyboard Lock** — drag or press `⌘ ↑` / `⌘ ↓` to reorder pinned clipboard items (driving `⌘ 1–9` quick paste), and lock input for up to **5 minutes** in Keyboard Lock

### Changed
- **Visual & Readability Refresh** — consistent dark theme across every Mac, higher-contrast cards, switches, badges, and buttons, larger HUD toasts, subtle press feedback, and clearer minimum text sizes
- **Status Bar Menu & Popovers** — upgraded frosted popover backdrops with hover highlights, smooth section collapse/expand keeping switches anchored, Clipboard split into **Pinned** and **Recent** sections, and redesigned Keep Awake, Keyboard Lock, Call Controls, Scroll Direction, and Settings layouts

### Fixed
- **Window Snapper** — eliminated false unsnaps while selecting text, stabilized Electron/custom-titlebar drags and single-resize unsnap restoration, prevented accidental Top Edge Panel opens when dragging down from Maximize, and ensured `⌫`/`Esc` cleanly cancels keyboard snap previews
- **Status Bar Menu & Modules** — kept the menu-bar popover from pulling Dashboard forward or jumping height when paused, fixed case-insensitive Dock exclusions, disabled actions with clear hints while paused, and cleaned up Shortcut Recorder focus handling

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
