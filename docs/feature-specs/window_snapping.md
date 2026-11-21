# Window Snapping Templates

> **Status:** Backlog (planning draft — not yet in the rollout order) · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

## Purpose & User Value

Window management can be tedious, especially on multi-monitor setups or when you need precise layouts that macOS's native snapping can't provide (beyond simple quadrants and halves).

**Window Snapping Templates** gives power users complete control over window arrangements across all screens:

1. **Define Custom Layouts**: Create flexible templates per screen — not limited to macOS's quadrant-based snapping
2. **Multi-Screen Coordination**: Synchronize window placement across multiple displays with a single command
3. **Workflow Profiles**: Save different layouts for different contexts (Coding, Research, Meeting, Gaming)
4. **Automated Window Placement**: When an app launches, position its window according to the active template
5. **Presets**: Pre-bundled popular layouts to get users started quickly

**User Value**: One-click layout restoration, eliminates manual window dragging, consistent workspace across sessions, reduces cognitive load when switching between work modes.

## User Flows & UX

### Screen Management
- **Automatic Screen Enumeration**: On startup, detect all active displays and number them sequentially (Screen 1, Screen 2, etc.)
- **Screen Identification**: Each screen displays its number along with helpful metadata (resolution, primary status, connection type)
- **Visual Screen Grid**: Users see all screens in a configurable view (list, grid, or map) with clickable/tappable cards
- **Screen Reordering**: Users can manually reorder screen assignments via drag-and-drop or context menu
- **Placeholder Support**: For monitors not yet connected, allow users to reserve screen slots

### Template Editor
- **Visual Canvas**: For each screen, users edit a visual representation where they can draw or place layout sections
- **Section Creation**: Click-to-add sections with configurable:
  - **Position**: Where the section goes on the screen
  - **Size**: How large the section is (relative to screen or absolute pixels)
  - **Geometry**: Shape (rectangle, square, L-shaped, custom)
- **Visual Feedback**: Sections show as ghost rectangles with adjustable borders
- **Section Management**: Users can drag to reorder, resize, or delete sections
- **Template Persistence**: Each screen has its own independent template; changes to one don't affect others

### App-to-Section Assignment
- **App Selection**: For each section, users specify which app(s) should go there:
  - **Search by App**: Searchable list of all installed apps
  - **Search by Window**: Match existing windows by title, icon, or process name
  - **Quick Add**: Open app now and assign it
  - **Preset Categories**: Developer tools, Browser, Chat, Media, etc.
- **Multiple Apps Per Section**: Support for grouping related apps together (e.g., "Browser with sidebar")
- **Window Rules**: Optional rules for specific app behaviors (always match this exact app, or match all windows of this type)
- **Drag-and-Drop**: Users can drag app icons or windows directly onto template sections for intuitive assignment
- **Conflict Detection**: Warn when the same app is assigned to multiple sections or when sections overlap

### Profile System
- **Profile Concept**: A profile is a collection of screen templates that can be loaded/activated together
- **Profile List**: Users can create, edit, and toggle multiple profiles
- **Profile Creation**: 
  - Choose name and icon
  - Select which screens to include
  - Assign existing templates to each screen
  - Or build from scratch
- **Profile Loading**: Activate a profile to instantly arrange all windows across selected screens
- **Profile Persistence**: Profiles are saved and restored on Toolbox restart
- **Import/Export**: Users can share profiles via file exchange or cloud sync
- **Default Presets**: Include useful starter profiles ("Developer Setup", "Research Mode", "Meeting Mode", "Full Screen")

### Snap Activation & Execution
- **Single Command**: Users trigger a snap (via global shortcut, menu item, or dock icon) to apply active profile
- **Smart Matching**: When snapping, the system intelligently matches open windows to template sections based on app identity, window title, or user interaction
- **Flexible Triggers**:
  - **Explicit**: Shortcut or button press
  - **Passive**: Automatically snap windows of apps that match the template patterns
  - **Incremental**: Snap one window at a time as apps launch
- **Conflict Handling**: Respect user manual window dragging during snap (pause/resume intelligently)
- **Partial Success**: If some windows can't be snapped, notify user and let them retry

### Real-Time Snap Preview
- **Visual Preview**: Before confirming, show users what the snap will look like
- **Hover Preview**: Hover over a template section to see which apps are currently assigned there
- **Preview Mode**: Toggleable preview that shows potential layout without moving windows
- **Undo Support**: Option to undo snap if preview looks good but user changes their mind

## Key Capabilities

- **Unlimited Sections**: Layouts aren't restricted to quadrants; users create their own section divisions
- **Arbitrary Geometry**: Support for L-shaped, U-shaped, or custom-shaped sections
- **Aspect Ratio Enforcement**: Optional constraint to maintain app window aspect ratios
- **Multi-Screen Coordination**: Snap actions coordinate across all screens simultaneously
- **Smart App Matching**: Intelligent algorithms to match windows to apps when multiple windows exist
- **Profile Swapping**: Quick-switch between pre-saved layouts
- **Background Monitoring**: Optional background process that auto-snaps newly launched windows
- **Non-Intrusive**: Works alongside macOS native snapping; doesn't interfere with system behavior

## Technical Constraints & Considerations

- **Accessibility Permission Required**: To query window states and programmatically position windows
- **App Limitations**: Some apps resist programmatic window manipulation (Slack, Teams, etc.); fallback strategies needed
- **Performance**: Must be efficient when monitoring many windows across multiple screens
- **Multi-Monitor Changes**: Handle cases where monitors are added/removed while active
- **macOS Snap Zones**: Coexist intelligently with system-level snapping areas

## Files to Create

- `Sources/Toolbox/Modules/WindowSnapping/` — Main module directory
- `Sources/Toolbox/Modules/WindowSnapping/WindowSnappingModule.swift` — Main module orchestrator, lifecycle management, global shortcut handling, profile save/load
- `Sources/Toolbox/Modules/WindowSnapping/ScreenManager.swift` — Enumerate, identify, and manage displays; handle screen numbering/reordering
- `Sources/Toolbox/Modules/WindowSnapping/TemplateEditor.swift` — SwiftUI view for creating/editing screen templates (visual canvas, section add/edit, app assignment)
- `Sources/Toolbox/Modules/WindowSnapping/ProfileManager.swift` — CRUD operations for profiles (create, load, save, import/export), JSON serialization
- `Sources/Toolbox/Modules/WindowSnapping/Snapper.swift` — Window detection, matching algorithm, snapping logic (move/resize/center), conflict resolution
- `Sources/Toolbox/Modules/WindowSnapping/WindowSnappingSettingsView.swift` — Settings UI: profile list, screen grid, template editor, snap behavior options

---

## Additional Notes for Implementation

When you start implementing this feature, consider:

1. **What's Feasible**: Some apps won't allow programmatic window moves (Slack, Discord, Teams, etc.). You'll need fallback strategies (CGEventTap to simulate drag-and-drop, or require user to manually position those windows).

2. **Window Property Limitations**: macOS window APIs have limits on what you can control. Features like "Zoom", "Tabbed view", and "Content filter" are either limited to specific apps or not supported at all by macOS APIs.

3. **Section Geometry**: You'll need to handle section overlap detection and ensure sections don't overlap in ways that cause conflicts.

4. **State Management**: Think about what's the "source of truth" - is it the profile JSON, the in-memory state, or the Settings UI? How do you keep them in sync?

5. **Error Handling**: What happens if Accessibility is denied mid-session? What if a required app wasn't opened? What if a window can't be snapped?

6. **Performance**: Window matching and animation should run on a background queue to avoid blocking the UI.
