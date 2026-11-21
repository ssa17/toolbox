# Localhost Port Killer — Feature Spec

> **Status:** Done · **Module:** `Modules/PortKiller/` · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
Developers constantly hit `EADDRINUSE` when a dev server (`Vite`, `Next.js`, `Node`, `Python`, `Go`, `Docker`, `Postgres`, `Redis`) stays alive in the background. Instead of dropping to a terminal to run `lsof -i :3000` and `kill -9 <pid>`, **Port Killer** surfaces active listening TCP ports in a searchable floating popover (`⌃ ⌥ ⌘ P`) and settings dashboard with process name, PID, port, bind address, and working directory—and lets you stop or force-kill them in one click.

### User Flows & UX
- **Global Popover (`⌃ ⌥ ⌘ P`):** Opens near the cursor (like `ClipboardModule`) with an auto-focused search box (`3000`, `node`, `vite`, folder name, or PID), optional filter chips (`All` / `Dev Ports` / `Hide System`), and live rows sorted with Pinned/Favorite ports first, then ascending port number.
- **Row Actions:** Each row shows process icon/badge, process name + port pill (`:5173`), working folder basename (full path in tooltip/subtitle), PID, and bind host (`127.0.0.1`, `::1`, `*`).
  - **Stop (`SIGTERM`)** button attempts graceful termination and triggers an immediate re-scan after 600 ms.
  - **Force Kill (`SIGKILL`)** button (or `⌥`-click / secondary button) sends `SIGKILL` immediately for wedged processes.
  - **Copy Port / Copy PID / Reveal CWD in Finder** in a compact context menu.
- **Settings View (`PortKillerSettingsView.swift`):**
  - **Shortcut & Behavior** section: global popover shortcut (`ShortcutRecorderView`), auto-refresh interval (`3s` / `5s` / `10s` / `Manual` when settings/popover open), default kill signal (`SIGTERM` vs `SIGKILL`), "Hide macOS system daemons" toggle.
  - **Favorite Dev Ports** section: quick preset chips (`3000`, `3001`, `4000`, `5000`, `5173`, `5432`, `6379`, `8000`, `8080`, `8888`) + custom port add/remove.
  - **Live Listening Ports** section: full-width table inside settings with Refresh button, Search bar, and Stop/Kill controls.

### Files Created
- `Sources/Toolbox/Modules/PortKiller/PortKillerModule.swift`
- `Sources/Toolbox/Modules/PortKiller/PortScanner.swift`
- `Sources/Toolbox/Modules/PortKiller/PortKillerSettingsView.swift`
- `Sources/Toolbox/Modules/PortKiller/PortKillerPopoverView.swift`

### Module Metadata
- `id`: `"port_killer"`
- `name`: `"Port Killer"`
- `tagline`: `"Inspect active listening TCP ports and kill stuck dev servers in one click."`
- `symbolName`: `"network"`
- `accentColor`: `Color.indigo`
- `category`: `.developer`
- `requiresAccessibility`: `false`

### Technical Design & macOS APIs
1. **Asynchronous Port Scanning (`PortScanner`):**
   - Run `/usr/sbin/lsof -iTCP -sTCP:LISTEN -P -n -F pcnTu` inside `Task.detached(priority: .userInitiated)` (never synchronously on `@MainActor`).
   - Parse `lsof -F` record-oriented output:
     - `p<pid>` starts a process block; `c<command>` sets process name; `u<uid>` sets owner UID; `n<addr>:<port>` records each listening socket.
     - Parse both IPv4 (`127.0.0.1:3000`, `*:8080`) and IPv6 (`[::1]:5173`, `[::]:3000`) addresses by splitting on the **last** `:` character.
   - **Path & CWD Enrichment:**
     - Use `Darwin`'s `proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))` for the full executable path (fast, in-process syscall, no extra subprocess).
     - Resolve working directory for displayed PIDs using `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, ...)` (`Darwin` / `libproc`), falling back to `lsof -a -p <pids> -d cwd -Fn` if needed.
   - **Deduplication:** A dual-stack server (listening on both `127.0.0.1:3000` and `[::1]:3000` under one PID) collapses into one entry per `(pid, port)` displaying both addresses or `localhost (IPv4 + IPv6)`.
2. **System Daemon Filtering:**
   - When `hideSystemProcesses == true`, hide entries whose UID differs from `getuid()`, whose executable lives under `/System/Library/` or `/usr/libexec/`, or whose command name matches well-known Apple background listeners (`rapportd`, `ControlCenter`, `sharingd`, `AirPlayXPCHelper`, `mDNSResponder`, `launchd`).
3. **Process Termination (`PortKillerModule`):**
   - Validate safety invariants before calling `Darwin.kill(pid, signal)`:
     - Refuse `pid <= 1`.
     - Refuse `pid == ProcessInfo.processInfo.processIdentifier` (Toolbox itself).
   - Call `kill(pid, signal.posixSignal)` (`SIGTERM` = `15`, `SIGKILL` = `9`).
   - Inspect `errno` if `kill` returns `-1`:
     - `EPERM`: show `HUDToast.shared.show(title: "Permission denied (run by another user)", symbol: "lock.fill", tint: .orange)`.
     - `ESRCH`: process already exited; refresh list silently.
   - On `SIGTERM`, schedule a 600 ms re-scan; if the same `(pid, port)` is still listening, mark the row with a `"Still running — Force Kill?"` prompt so the user can escalate with one click.

### Configuration (`PortKillerConfig`)
```swift
enum PortKillSignal: String, Codable, CaseIterable, Sendable {
    case sigterm = "sigterm"
    case sigkill = "sigkill"
}

struct PortKillerConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var shortcut: ShortcutSpec = ShortcutSpec(key: "p", modifiers: [.control, .option, .command])
    var refreshIntervalSeconds: Int = 5
    var hideSystemProcesses: Bool = true
    var favoritePorts: [Int] = [3000, 5173, 8000, 8080]
    var defaultSignal: PortKillSignal = .sigterm
}
```
- `ToolboxConfig`: add `var portKiller: PortKillerConfig = PortKillerConfig()` with lenient `decodeIfPresent`.

### Verification & Self-Tests
- **Parser unit tests (`SelfTestRunner`):** Feed synthetic `lsof -F pcnTu` output covering IPv4 (`127.0.0.1:3000`), IPv6 (`[::1]:5173`), wildcard (`*:8080`), dual-stack deduplication, and multi-port single-PID processes.
- **Live loopback listener test (`SelfTestRunner`):** Bind an in-process TCP socket (`NWListener` on port `0` or POSIX `socket`/`bind`/`listen` on `127.0.0.1:0`), inspect its assigned ephemeral port, run `PortScanner.scanListeningPorts()`, and assert that the current PID + assigned port appear.
- **Safety guard tests:** Assert termination helper refuses `pid <= 1` and self-PID.
- **Visual Snapshot (`SnapshotRunner`):** Render `module_port_killer.png`.

### Edge Cases & Pitfalls
- **Main-thread blocking:** `lsof` can take 50–300 ms under heavy load; never invoke it synchronously on `@MainActor`.
- **Single-port vs multi-port:** A process may hold multiple ports (e.g., Node app + debugger port `9229`). Always key rows by `(pid, port)` rather than `pid` alone, and warn in subtitle if killing a PID will close multiple ports.
- **Popover polling:** Only run the auto-refresh `Timer` while the popover or settings view is visible, not continuously in the background while idle.
