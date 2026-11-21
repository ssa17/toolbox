# Dev Converter & Scratchpad — Feature Spec

> **Status:** Planned · **Module:** `Modules/DevTools/` · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
Developers constantly open random browser tabs to pretty-print JSON, inspect JWT claims/expiration, Base64/URL-decode strings, convert Unix timestamps, or compute SHA-256 hashes—often pasting sensitive tokens or payloads onto third-party websites. **Dev Converter & Scratchpad** brings all of these transforms into an instant, 100% offline floating utility (`⌃ ⌥ ⌘ B`) and module workspace.

### User Flows & UX
- **Floating Scratchpad Popover (`⌃ ⌥ ⌘ B`):**
  - Opens a non-activating `NSPanel` (`~580 × 480` pt) mirroring `ClipboardModule`'s panel lifecycle.
  - Optional **"Auto-load clipboard on open"**: when enabled, seeds the input editor from `NSPasteboard.general` if it looks like a transformable payload (or always loads current clipboard text with a clear `Paste` / `Clear` toolbar).
  - **Smart Detection Banner:** Automatically analyzes input and highlights a one-click recommended action (e.g., `"Detected JWT (Expires in 2h 14m) → Decode JWT"`, `"Detected Unix Epoch (ms) → Convert Timestamp"`, `"Detected Valid JSON → Pretty Print"`).
  - **Transform Toolbar / Sidebar Chips:**
    - **JSON:** `Pretty (2sp)`, `Pretty (4sp)`, `Minify`, `Sort Keys`, `Escape`, `Unescape`
    - **JWT:** `Decode Header & Payload + Claims Check`
    - **Encode / Decode:** `Base64 Encode`, `Base64 Decode`, `Base64URL Decode`, `URL Encode`, `URL Decode`, `HTML Encode`, `HTML Decode`
    - **Time & Hashes:** `Timestamp ↔ ISO-8601`, `New UUID v4`, `SHA-256`, `SHA-512`, `MD5`
  - **Output Pane:** Monospaced viewer with error badge (exact line/column on invalid JSON), `Copy Output`, and `Use Output as Input` (swap button for chained transforms like URL-decode → JSON-format).
- **Settings View (`DevToolsSettingsView.swift`):**
  - Global shortcut (`ShortcutRecorderView`), `Auto-load clipboard on open` toggle, `JSON indent spaces` (`2` or `4`), `Sort JSON keys` default toggle, plus an embedded quick-test scratchpad preview.

### Files to Create
- `Sources/Toolbox/Modules/DevTools/DevToolsModule.swift`
- `Sources/Toolbox/Modules/DevTools/DevTransformEngine.swift`
- `Sources/Toolbox/Modules/DevTools/DevToolsSettingsView.swift`
- `Sources/Toolbox/Modules/DevTools/DevToolsPopoverView.swift`

### Module Metadata
- `id`: `"dev_tools"`
- `name`: `"Dev Converter"`
- `tagline`: `"Offline scratchpad to format JSON, inspect JWTs, encode/decode Base64 & URLs, convert timestamps, and hash."`
- `symbolName`: `"curlybraces.square"`
- `accentColor`: `Color.blue`
- `category`: `.developer`
- `requiresAccessibility`: `false`

### Technical Design & macOS APIs
1. **Pure Transform Engine (`DevTransformEngine`):**
   - Stateless `enum DevTransformEngine` returning a structured `TransformResult` (`output: String`, `statusBadge: String?`, `isError: Bool`, `errorDetail: String?`).
   - **Auto-Detection Heuristics (`detectKind(for input: String) -> DetectedInputKind?`):**
     1. Trim whitespace/newlines.
     2. **JWT:** Three `.`-separated segments matching Base64URL charset (`[A-Za-z0-9_-]`), first segment decodes to JSON containing `"alg"` or starts with `eyJ`.
     3. **JSON:** Starts with `{` or `[` and parses via `JSONSerialization`.
     4. **Unix Timestamp:** Matches `^-?\d{10}$` (seconds) or `^-?\d{13}$` (milliseconds).
     5. **URL-encoded:** Contains `%[0-9A-Fa-f]{2}` sequences or `http(s)://` query strings.
     6. **Base64:** Length multiple of 4 (or valid unpadded Base64URL) decoding cleanly to UTF-8 text.
   - **JSON Formatter & Diagnostics:**
     - Parse with `JSONSerialization.jsonObject(with:options: [.fragmentsAllowed])` and serialize with `.prettyPrinted`, `.withoutEscapingSlashes`, and optional `.sortedKeys`.
     - Post-process indentation if `indentSpaces == 2` (Apple's `JSONSerialization` emits 2 spaces by default on macOS; scale leading indentation cleanly when 4 spaces requested).
     - On `NSError` (`NSCocoaErrorDomain` `NSPropertyListReadCorruptError` / `NSDebugDescription`), extract line/column/character index from `userInfo` when available and compute fallback `(line, column)` scanner if missing.
   - **JWT Inspector:**
     - Pad each Base64URL segment (`-` → `+`, `_` → `/`, pad `=` to multiple of 4), decode Header & Payload JSON.
     - Inspect standard numeric date claims (`exp`, `iat`, `nbf`): convert epoch seconds to UTC ISO-8601 + local readable date and compare `exp` against `Date()` to report `"Valid (expires in …)"` or `"Expired … ago"`.
     - Never transmit JWTs over the network or verify HMAC/RSA secrets silently—explicitly note `"Signature not verified (offline decode)"`.
   - **Timestamps:**
     - Support 10-digit seconds, 13-digit milliseconds, 16-digit microseconds, and ISO-8601 input (`ISO8601DateFormatter` with fractional seconds fallback), displaying UTC, Local, and relative offset.
   - **Cryptography (`CryptoKit`):**
     - `SHA256.hash(data:)`, `SHA512.hash(data:)`, and `Insecure.MD5.hash(data:)` formatted as lowercase hex strings.
2. **Code Editor Input Ergonomics:**
   - Wrap an `NSTextView` (or configure SwiftUI `TextEditor`) with `isAutomaticQuoteSubstitutionEnabled = false`, `isAutomaticDashSubstitutionEnabled = false`, `isAutomaticTextReplacementEnabled = false`, and `isAutomaticSpellingCorrectionEnabled = false` so macOS never mangles straight JSON quotes `"` into smart quotes `“”`.

### Configuration (`DevToolsConfig`)
```swift
struct DevToolsConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var shortcut: ShortcutSpec = ShortcutSpec(key: "b", modifiers: [.control, .option, .command])
    var autoLoadClipboardOnOpen: Bool = true
    var jsonIndentSpaces: Int = 2
    var sortJsonKeys: Bool = false
}
```
- `ToolboxConfig`: add `var devTools: DevToolsConfig = DevToolsConfig()`.

### Verification & Self-Tests
- **Transform suite (`SelfTestRunner`):**
  - JSON pretty-print (2 spaces & 4 spaces), sorted keys, minify, escape/unescape, and invalid-JSON error diagnostic.
  - JWT decode with synthetic header + payload containing future `exp` and past `exp` claims, asserting formatted JSON and expiry status.
  - Base64 & Base64URL encode/decode, URL encode/decode, HTML entity encode/decode.
  - Epoch seconds/ms ↔ ISO-8601 round-trip, UUID v4 format validation, and known-vector `SHA-256` (`"abc"` → `"ba7816bf..."`), `SHA-512`, `MD5`.
  - Auto-detection tests for all 5 input kinds.
- **Visual Snapshot (`SnapshotRunner`):** Render `module_dev_tools.png`.

### Edge Cases & Pitfalls
- **Smart quotes in macOS text views:** Default macOS `NSTextView` replaces `"` with `“`; disabling smart substitutions is mandatory for a JSON scratchpad.
- **Non-UTF-8 Base64 output:** When decoding Base64 yields raw binary bytes rather than valid UTF-8, return a clean hex dump (`xxd`-style or spaced hex) with an explanatory badge instead of failing silently.
- **Large payloads:** Cap auto-load from clipboard or display truncation warning for multi-megabyte strings so opening the popover stays instantaneous (`< 50 ms`).

---

## Appendix: Earlier Planning Draft (superseded)

> ⚠️ **Superseded — do not implement from this draft.** The notes below were written independently of the canonical spec above and in places contradict it (e.g., they assume permissions and feature scope the canonical spec does not have, and list different files). Where the two disagree, **the spec above wins** (and, for shipped features, the running code). The draft is retained here so no planning notes are lost.

### Purpose & User Value

Developers constantly need to convert between different data formats (base64, hex, decimal, binary, URL encoding, etc.) or do quick calculations without leaving their IDE.

**Dev Converter & Scratchpad** provides a fast, accessible calculator and format converter that's always available:
1. **Quick Format Conversion**: Convert between base64, hex, decimal, URL encoding, and other common formats
2. **Calculator**: Basic and advanced calculations (arithmetic, boolean, date math)
3. **Data Manipulation**: JSON prettify/minify, query parameters, string manipulation
4. **Quick Reference**: Regex syntax, keyboard shortcuts, or other developer cheatsheets

**User Value**:
- No need to jump to an external website or app
- Always available with a keyboard shortcut
- Reduces context switching while coding
- Pre-built templates for common developer tasks

### User Flows & UX

#### Quick Launch
- **Global Shortcut**: Launch with a memorable shortcut (e.g., `⌃ ⌥ ⌘ B`)
- **Floating Panel**: Opens as a small floating panel that can be dragged or resized
- **Focus Restoration**: When done, focus returns to the previously active app

#### Converter Input
- **Multiple Input Areas**: Separate fields for input and output
- **Auto-Detect**: Automatically detect input format from the paste or typed input
- **Format Presets**: Quick-select common conversions (HEX→DEC, BASE64→JSON, etc.)
- **Custom Format**: Optional text input to specify custom conversion rules

#### Converter Results
- **Multiple Output Formats**: Show the same value in multiple formats (e.g., hex, decimal, binary)
- **Copy Result**: One-click copy of results
- **Error Display**: Clear error messages if conversion fails (e.g., invalid hex, malformed base64)
- **Example**: Show example inputs for the selected conversion type

#### Calculator
- **Basic Operations**: +, -, ×, ÷, %, power, sqrt
- **Advanced Functions**: sin, cos, tan, log, natural log, absolute value, max, min
- **Constants**: π, e, φ, etc.
- **History**: View previous calculations and tap to reuse numbers
- **Expression Mode**: Type full expressions like `15 + 25 * 2`
- **Units**: Optional unit conversion (temperature, length, data, etc.)

#### Scratchpad Sections
- **Multiple Sections**: Create separate scratchpad sections (e.g., "Current Project", "Random Ideas")
- **Auto-Save**: Automatically save scratchpad content when minimized or closed
- **Persistent Data**: Store arrays, objects, or code snippets for later use
- **Code Editors**: Mini code editors for quick snippets (auto-complete for common languages)

#### Search & Lookups
- **Quick Search**: Search installed apps, commands, or URLs from scratchpad
- **Command Lookup**: Search man pages or command aliases
- **URL Builder**: Build URLs with query parameters visually

#### Settings & Presets
- **Keyboard Shortcuts**: Configure launch shortcut, section keybinds, etc.
- **Default Formats**: Set default output formats
- **Saved Conversions**: Save frequently-used conversion pairs for one-click access
- **Theme**: Toggle light/dark mode or color schemes

### Key Capabilities

- **Real-time Conversion**: Convert as you type or paste
- **Multiple Output**: Show one value in multiple formats simultaneously
- **Calculation History**: Tap to reuse previous results
- **Persistent Scratchpad**: Auto-save and restore scratchpad content
- **Quick Search**: Built-in search for apps, commands, URLs
- **Developer Presets**: Pre-loaded templates for common dev tasks
- **Drag & Drop**: Drag code snippets between sections
- **One Window**: Everything in one integrated panel (saves space)

### Technical Constraints & Considerations

- **No Network Required**: All conversions are local, no external APIs
- **Privacy**: No data is sent anywhere, everything stays local
- **Performance**: Should handle large inputs (10K+ characters) without freezing
- **Locale Awareness**: Handle different number formats (1,000 vs 1000, etc.)
- **Localization**: Support for multiple languages in UI
- **Regex Engine**: If including regex testing, choose the right regex flavor (POSIX vs. PCRE)
- **JSON Schema**: If including JSON validation, handle nested objects and arrays
- **Date Parsing**: Handle multiple date formats (ISO, local, epoch, etc.)
- **Clipboard Integration**: Copy results to system clipboard when requested

### Files to Create

- `Sources/Toolbox/Modules/DevTools/DevToolsModule.swift` — Main module orchestrator, lifecycle management, global shortcut handling, panel management
- `Sources/Toolbox/Modules/DevTools/FormatConverter.swift` — Conversion logic for various formats (base64, hex, decimal, URL, etc.)
- `Sources/Toolbox/Modules/DevTools/Calculator.swift` — Calculator engine (expression parsing, evaluation, history)
- `Sources/Toolbox/Modules/DevTools/ScratchpadManager.swift` — Manages scratchpad sections, persistence, auto-save
- `Sources/Toolbox/Modules/DevTools/QuickSearch.swift` — Search functionality for apps, commands, URLs
- `Sources/Toolbox/Modules/DevTools/DevToolsPanelView.swift` — Main panel UI (converter, calculator, scratchpad tabs)
- `Sources/Toolbox/Modules/DevTools/DevToolsSettingsView.swift` — Settings UI for shortcuts, preferences, presets

---

### Additional Notes for Implementation

When you start implementing this feature, consider:

1. **Input Validation**: For conversions, validate input before converting (e.g., hex must be 6-8 chars, base64 must be divisible by 4). Show helpful error messages.

2. **Expression Parsing**: If you implement an expression-based calculator, you'll need a safe expression parser (avoid shell injection vulnerabilities). Consider using a proven library like SwiftCalc or NSExpression.

3. **Unit Conversions**: If you want to include unit conversion (temperature, length, data, time), you'll need conversion tables and logic. This can be complex for things like currencies (which require live API).

4. **Persistence Format**: Decide on a storage format for scratchpads. JSON is simple but verbose. Consider a binary format for compactness or a hybrid approach.

5. **Auto-Save Strategy**: How do you detect "minimized"? Is it when the user clicks away? After a timeout? You'll want to be non-intrusive.

6. **Search Performance**: If users can search through hundreds of installed apps, you'll need to index them for fast search. Consider updating the index incrementally as apps are installed/uninstalled.

7. **Regex Engine**: If including regex testing, macOS doesn't have a native regex engine. You'll need to integrate a library (PyRegex, ONiguruma, or write your own minimal one).

8. **Clipboard API**: To copy results, you'll use `NSPasteboard.general.string(for:)` to write to clipboard. For complex objects (JSON, structs), you might need to stringify first.

9. **Localization**: macOS has `Locale.current` which you can use for number formatting, date formatting, etc. But you'll also want to support user-selected languages in the UI.

10. **Privacy & Permissions**: Since this doesn't need Accessibility or Screen Recording permissions, it's a "safe" feature. But still, don't read user files or clipboard contents without explicit user action.
