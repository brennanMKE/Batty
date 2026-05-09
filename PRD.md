# Batty — Product Requirements Document

> **Working name:** Batty — a colony of terminals, navigated by echo.
> A native macOS terminal multiplexer built on libghostty. tmux-like, but simpler and tuned for one developer's workflow.

---

## 1. Vision

A native macOS app — typically used in a **single window** — that gives me multiple terminal sessions organized by a left-side **session sidebar**, with the speed and rendering quality of Ghostty but a simpler multiplexing model than tmux. No config files to learn. No prefix-key gymnastics. A bell-driven **notification feed** lets me catch background activity without constantly tab-hopping.

Batty is **not** trying to compete with tmux's full feature set. It's the 20% of tmux I actually use, with a real GUI on top.

---

## 2. Why this exists

I've been using a tmux-like app, but it's heavier than my workflow needs. Most days I want:

- A sidebar of named sessions for different projects/contexts.
- Inside each session, a few terminal panes side-by-side.
- Per-pane tabs so I can keep alternate shells (logs, REPL, scratch) within one pane.
- Quick splits without thinking about a prefix key.
- A way to know when a background terminal beeped — and click straight to it.
- My layout to come back when I reopen the app.
- Native macOS feel — Cmd-shortcuts, font rendering, copy/paste, IME.

What I don't need (at least in v1):

- Session detach/attach across SSH. (I'm running Batty locally.)
- Scriptable layouts via a config language.
- Plugin ecosystems.
- Remote pair programming.

The "Bat / Ghost / tty" naming theme is a wink at Ghostty — Batty is Ghostty's smaller, scrappier cousin focused on multiplexing rather than being a full terminal emulator.

---

## 3. Goals & non-goals

### Goals

1. **Hello-world fast.** Open the app, get a working shell prompt in under a second.
2. **Sessions in a sidebar.** Each session is a named workspace containing one or more panes. The sidebar is collapsible.
3. **Splits and tabs that just work.** Toolbar buttons (`rectangle.split.2x1`, `rectangle.split.1x2`) and Cmd-D / Cmd-Shift-D split the focused pane. Each pane has its own SlidingTabs bar; Cmd-T / Cmd-W / Cmd-1..9 navigate within the focused pane.
4. **Notification feed.** Capture terminal-bell events from every surface, surface them in a unified feed, click an entry to bring the source forward (right session → right pane → right tab).
5. **Persistence.** Quit and relaunch — same sessions, panes, tabs, splits, and working directories. (Shells re-launch fresh; we don't try to restore process state.)
6. **Native rendering.** Use libghostty for the actual terminal — fonts, ligatures, GPU rendering, escape sequences all come for free.
7. **Keyboard-first.** Every action that matters has a keybinding. Mouse is supported but not required.
8. **Theme support.** Read Ghostty `.ghostty` theme files so I can use the existing 200+ themes without re-creating them.

### Non-goals (for v1)

- A scripting/config language à la tmux's `.tmux.conf`.
- Session sharing or remote attach.
- A plugin system.
- Custom shell integrations beyond what Ghostty already provides.
- iPad/iPhone companion app. (See §10 — possible future work.)
- Linux or Windows support.

---

## 4. Target user

Me, primarily. Generalizing: a senior developer on macOS who:

- Lives in the terminal but isn't a tmux power-user.
- Wants splits and tabs without learning a meta-key DSL.
- Values native macOS behavior (real Cmd shortcuts, real menus, real services).
- Already knows and likes Ghostty.
- Typically works in a single window, but occasionally spans multiple displays.

---

## 5. User stories (v1)

| # | As a user, I want to… | So that… |
|---|---|---|
| 1 | Open Batty and get a shell prompt | I can start working immediately |
| 2 | Create named sessions in a left sidebar | I can group panes by project or context |
| 3 | Click a session in the sidebar | I can jump between project contexts without losing state |
| 4 | Collapse/expand the sidebar | I can reclaim screen space when I'm heads-down |
| 5 | Click a `rectangle.split.2x1` toolbar button to split the focused pane horizontally | I can run two commands side by side without a keybinding lookup |
| 6 | Click a `rectangle.split.1x2` toolbar button to split vertically | Same, but stacked |
| 7 | Press Cmd-D / Cmd-Shift-D for the same actions via keyboard | Keyboard-first work stays keyboard-first |
| 8 | Drag a split divider to resize panes | I can give one pane more screen real estate with the mouse |
| 9 | Have a tab bar inside each pane (SlidingTabs) | I can keep multiple terminals within one pane and switch between them |
| 10 | Press Cmd-T to add a tab in the focused pane | I can spin up another terminal without breaking my split layout |
| 11 | Press Cmd-1..9 to select the Nth tab in the focused pane | I can navigate tabs without the mouse |
| 12 | Move focus between split panes with Cmd-Option-arrows | I can drive everything from the keyboard |
| 13 | Resize splits with Cmd-Ctrl-arrows | I can give one pane more screen real estate without the mouse |
| 14 | Close a tab with Cmd-W (and the pane collapses if it was the last tab) | Closing doesn't leave dead UI behind |
| 15 | See a notification feed of every terminal bell | I notice when a background build finishes or a long task fails |
| 16 | Click a notification to jump to the originating terminal | I don't waste time hunting for the right pane |
| 17 | Quit and relaunch and have my full layout back | I don't lose context between sessions |
| 18 | Drag a screenshot from Finder onto a terminal and have its path inserted | I can share files with Claude Code without typing paths |
| 19 | Pick a theme from a menu | My terminal looks the way I like |
| 20 | Copy/paste with Cmd-C / Cmd-V like every other Mac app | I don't need to learn special keys |
| 21 | Use CJK input, dead keys, and emoji input | My input methods just work |

---

## 6. Functional requirements

### 6.1 Surfaces (the libghostty terminals)

- A "surface" is one libghostty terminal session: one PTY, one shell process, one render target.
- Each surface has a stable UUID for the lifetime of the app.
- One **tab** owns exactly one surface. Surfaces are created when a tab is created and torn down when the tab closes (kill PTY, free Metal resources).
- The surface registry maps `UUID → ghostty_surface_t*` so SwiftUI re-renders never recreate live surfaces.

### 6.2 Layout model

The data model is a **three-level hierarchy** plus the surface registry:

```
App
└── Window(s)                    [usually 1; multi-window supported]
    ├── SessionSidebar           [left side, collapsible]
    │   └── [Session, Session, Session, ...]
    └── DetailArea               [the selected Session's content]
        └── SplitNode            [recursive binary tree of Panes]
            ├── leaf(Pane)
            └── split(direction, ratio, left, right)

Pane:                            [a leaf of the split tree — one visible region]
├── SlidingTabBar                [the per-pane tab strip]
└── tabs: [Tab]                  [each tab is one terminal]

Tab:
└── surfaceID: UUID              [→ a libghostty surface]
```

- **Window** — the macOS window. Single window is the default; users with multiple displays can open more (Cmd-N). Each window is independent.
- **Session** — a named workspace in the sidebar. Owns a `SplitNode` root and a `focusedPaneID`.
- **SplitNode** — recursive `enum`: `leaf(Pane)` or `split(direction, ratio, left, right)`. Splits can nest arbitrarily.
- **Pane** — a leaf of the split tree. One visible region. Has its own SlidingTabs bar with `tabs: [Tab]` and `activeTabID`. A new pane is born with one tab containing one fresh surface.
- **Tab** — one terminal inside a pane. Has `id`, `title` (auto from focused surface, user-overridable), `surfaceID`, and `unseenBellCount`.

> Plain English: **Window → Sidebar of Sessions → Selected Session is a split tree of Panes → Each Pane has tabs → Each Tab is a libghostty terminal.**

### 6.3 Sessions (sidebar)

- Left sidebar lists all sessions in the active window in user-defined order. Drag to reorder.
- Each row shows: session title, total live tab count across its panes, an unseen-bell badge (if any tab in any of its panes has unseen bells).
- Sidebar toolbar:
  - "+" button: create a new session (prompts for a name; new session starts with one pane, one tab, one fresh surface).
  - Context menu on each session: Rename, Duplicate, Close.
- Selecting a session swaps the detail area to that session's split tree.
- Surfaces in non-active sessions stay alive in the background so switching is instant and processes keep running.
- Cmd-Shift-1..9 selects the Nth session.
- The sidebar is collapsible: View → Hide Sidebar (Cmd-Ctrl-S), or the standard NavigationSplitView toggle button in the toolbar.

### 6.4 Panes & splits (within a session)

- Each session contains a recursive binary split tree whose leaves are **panes**. The simplest session has one pane.
- Two toolbar buttons (in the window/session toolbar, with optional per-pane hover overlay — TBD during M3):
  - `rectangle.split.2x1` (SF Symbol) — split focused pane horizontally, new pane to the right.
  - `rectangle.split.1x2` (SF Symbol) — split focused pane vertically, new pane below.
  - The new pane is born with one tab containing one fresh surface in the parent's cwd.
- Equivalent keybindings: Cmd-D (horizontal, side-by-side) and Cmd-Shift-D (vertical, stacked).
- **Mouse resize:** drag the split divider to resize. Live preview while dragging; the ratio is persisted.
- **Keyboard resize:** Cmd-Ctrl-arrows resize the split containing focus by ±5%.
- **Focus:** Cmd-Option-arrows move focus between panes.
- **Closing the last tab in a pane** removes the pane and collapses its parent split (the sibling takes over the parent's space).

### 6.5 Tabs (per pane, via SlidingTabs)

- Tabs render inside each pane using the **SlidingTabs** Swift package (local: `/Users/brennan/Developer/brennanMKE/SlidingTabs`; also available on GitHub).
  - Drag-to-reorder is built in.
  - The `hasUnseen` chip dot maps to per-tab unseen-bell state.
  - The optional "+" button adds a new tab to that pane.
- Each tab owns one libghostty surface. Switching tabs swaps which surface is rendered in the pane; non-active tabs keep their PTY/shell running in the background.
- Tab title resolution: focused-surface process name → cwd basename → user-set title (first non-empty wins).
- **Cmd-T** adds a tab to the focused pane.
- **Cmd-W** closes the focused tab. If it was the last tab in the pane, the pane is removed and its parent split collapses (see §6.4).
- **Cmd-1..9** selects the Nth tab in the focused pane. Cmd-Shift-[ / ] cycles tabs within the focused pane.
- `onReorderCommit` from SlidingTabs persists the new order.

### 6.6 Windows

- **Single window is the default** and the primary supported workflow.
- Cmd-N opens an additional window. Each window has its own sidebar of sessions and its own selected session — windows do not share session lists.
- Standard macOS window behavior (zoom, minimize, full-screen).

### 6.7 Persistence

- On quit (and every 30 seconds while running), serialize:
  - All open windows and which session is selected in each.
  - For each window: the ordered session list.
  - For each session: the split tree, the focused pane, and for each pane the ordered tab list, active tab, and per-tab title overrides.
  - For each surface: working directory at last known moment, last-set title.
  - Notification feed history (capped, see §6.13).
- Stored at `~/Library/Application Support/Batty/workspace.json`.
- On launch, replay into new windows. **Shells start fresh** in the saved cwd — we don't try to restore running processes.

### 6.8 Themes

- Read Ghostty-format theme files from:
  - The app bundle (a few defaults shipped).
  - `~/.config/ghostty/themes/` (if present).
- A "Theme" submenu in the View menu lists all available themes; selection is per-app and persisted.
- Per-surface theme override is **out of scope for v1**.

### 6.9 Configuration

- v1 has **no config file**. All settings live in a Settings window (SwiftUI):
  - Default shell (auto-detected, overridable).
  - Font family + size.
  - Theme.
  - Cursor style.
  - Whether to confirm on close with running processes.
  - Notification preferences (see §6.13).
- Settings persist via `UserDefaults`.

### 6.10 Copy/paste & selection

- Cmd-C copies the selection (libghostty handles selection model).
- Cmd-V pastes; if the paste contains newlines, show a confirmation sheet ("Paste 3 lines?") to avoid the classic "rm -rf paste" footgun.
- Standard mouse selection: drag, double-click word, triple-click line.

### 6.11 IME / international input

- `NSTextInputClient` fully implemented on the surface NSView.
- CJK, dead keys (e.g. `é` on US-International), and emoji picker (Ctrl-Cmd-Space) all work.

### 6.12 Drag-and-drop of files onto a surface

- The terminal NSView is a drag destination for file URLs (`NSPasteboard.PasteboardType.fileURL`).
- Dropping one or more files inserts their POSIX-quoted paths at the cursor, space-separated, with a trailing space. Example: dropping `~/Desktop/Screenshot 2026-05-08.png` inserts `'/Users/brennan/Desktop/Screenshot 2026-05-08.png' `.
- Implementation: convert the dropped URLs to shell-quoted paths and push the resulting string into the surface via libghostty's `ghostty_surface_text(...)` — the same entry point used for paste and IME commits. libghostty itself has no concept of drag-and-drop; this is entirely an AppKit-layer feature.
- Visual feedback during drag-over (highlight border on the target pane) is in scope for v1.
- Browser-dragged URLs (e.g. dragging a link from Safari) are **out of scope for v1** — this matches Ghostty's current behavior. File URLs from Finder, screenshot tools, and other native apps are the supported case.

> Why this matters: this is the primary way I share screenshots and videos with Claude Code. Without it, the app is a non-starter for my workflow.

### 6.13 Notifications & bell feed

A "feed" of bell events across every surface, plus per-tab, per-pane, and per-session unseen badges, plus optional system notifications.

#### Sources of bell events

- **ASCII BEL (`\a`, 0x07)** — the classic terminal bell. libghostty exposes a callback / surface action when a surface fires the bell. We hook it.
- **OSC 9** (iTerm-style notifications) — `ESC ] 9 ; <message> BEL` sends a notification with a message body. If libghostty surfaces this we capture it.
- We do **not** invent custom escape sequences. If libghostty doesn't expose a hook for a given source, we skip it for v1 and revisit.

#### Per-surface state

- Each surface tracks: `bellCount`, `lastBellAt`, `lastBellMessage` (if OSC 9 supplied one).
- A bell event from a non-focused surface increments unseen counters all the way up: surface → tab → pane → session.
- A bell event in the focused surface still records to the feed but does **not** increment unseen counters.

#### The feed

- Accessed via a toolbar button (bell SF Symbol: `bell.badge` when unseen, `bell` when clean) and Cmd-Shift-N.
- Renders as a popover or sheet listing recent events newest-first, scrollable, persisted across launches up to a cap (e.g. 200 entries).
- Each entry shows:
  - Timestamp (relative: "2m ago").
  - Path: `<Session> › <Pane> › <Tab>`.
  - Message (OSC 9 body) or a short preview if available.
  - An "unseen" indicator until clicked.
- Clicking an entry **brings the source forward**:
  1. Focuses the window containing the surface (`NSWindow.makeKeyAndOrderFront`).
  2. Selects the right session in the sidebar.
  3. Focuses the right pane in the session's split tree.
  4. Activates the right tab inside that pane.
  5. Marks the entry seen and decrements unseen counters at every level.
- A "Clear all" button marks every entry seen.

#### System notifications (UserNotifications)

- When the app is **not** the frontmost app, OR when a surface that fires a bell is in a non-active session/pane/tab, post a `UNNotificationRequest`:
  - Title: `Batty — <Session> › <Pane> › <Tab>`.
  - Body: OSC 9 message if present, else "Bell".
  - Tapping the notification triggers the same "bring source forward" flow as clicking a feed entry.
- Settings let me toggle: bell sound, system notifications, and per-session mute.

#### Visual indicators

- **Sidebar session row** — small dot or count badge when the session has unseen bells anywhere within it.
- **SlidingTabs chip** — `hasUnseen: true` (already supported by the package) when the tab has unseen bells.
- **Pane border** — subtle accent flash on bell, fading over ~1s; sustained dot when an inactive tab in the pane has unseen bells.

---

## 7. Non-functional requirements

| Area | Requirement |
|---|---|
| **Performance** | Cold launch to first prompt: <1s on M-series Macs. Keystroke-to-render latency: comparable to Ghostty (libghostty handles this). Session switch: instant (surfaces stay alive in background). |
| **Memory** | <50MB per idle surface. |
| **Stability** | A crashing shell must not crash the app. A crashing surface must not crash other surfaces, panes, or sessions. |
| **Compatibility** | macOS 15+ (Sequoia and later — required by the SlidingTabs package). Universal binary (arm64 + x86_64). |
| **Accessibility** | VoiceOver can read session, pane, and tab titles. Keyboard-only operation is fully supported. The notification feed is keyboard-navigable. |
| **Privacy** | No telemetry. No network calls except what the user types into the shell. System notifications are local. |

---

## 8. Architecture (summary)

See `batty-getting-started.md` for the deep dive. Short version:

- **SwiftUI app shell** (`BattyApp`) — windows, menus, settings.
- **Window structure** — `NavigationSplitView` with the session sidebar on the left (collapsible) and the session detail view on the right.
- **`SessionSidebarView`** — a `List` of sessions with reorder, "+" toolbar button, and unseen-bell badges.
- **`SessionDetailView`** — toolbar (split SF Symbols, theme, bell) plus a recursive `SplitContainerView` that renders the session's split tree.
- **`SplitContainerView`** — switches on `SplitNode` cases; renders `PaneView` at leaves and an `HSplitView` / `VSplitView` (or custom equivalent) for splits with draggable dividers.
- **`PaneView`** — owns a `SlidingTabBar` plus the active tab's terminal surface.
- **Terminal surface** — provided by **`GhosttyTerminal`**'s `TerminalSurfaceView` (SwiftUI) / `TerminalView` (NSView typealias). The wrapper handles Metal layer sizing, key/mouse forwarding, IME (`NSTextInputClient`), and the libghostty IO/render thread plumbing — we do not re-implement these. Drag-and-drop (`NSDraggingDestination`) is layered on top via either a SwiftUI `.onDrop` overlay or a thin `AppTerminalView` subclass in `BattyKit`.
- **Bell + surface events** — `GhosttyTerminal`'s split delegate protocols (`TerminalSurfaceBellDelegate`, `TerminalSurfaceDesktopNotificationDelegate`, `TerminalSurfaceTitleDelegate`, `TerminalSurfacePwdDelegate`, `TerminalSurfaceFocusDelegate`, `TerminalSurfaceCloseDelegate`) feed our `BellFeedStore` and per-tab title/cwd state. No raw libghostty callback wiring needed.
- **`BellFeedStore`** — `@Observable` actor-backed store collecting bell events, exposing aggregated unseen counts to sidebar/pane/tab views.
- **Persistence layer** — Codable structs serialize the full session/split/pane/tab tree.

The lower-level libghostty C surface (`GhosttyKit`) is still re-exported by `BattyKit` for cases where we need direct access (e.g. `ghostty_surface_text` for drag-drop injection if `GhosttyTerminal` doesn't expose a high-level send-text API).

### Module structure

The repo is split into two Swift modules:

- **`BattyKit`** (Swift Package, `BattyKit/Package.swift`) — holds the bulk of the code: data models, persistence, theme adapters, layout views, bell-feed store, and integration with the `GhosttyTerminal` SwiftUI surface. Owns the SPM dependencies: `libghostty-spm` (re-exporting `GhosttyKit`, `GhosttyTerminal`, and `GhosttyTheme`) and `SlidingTabs`. Re-exports them via `@_exported import` so consumers just `import BattyKit` to get everything.
- **`Batty`** (Xcode app target) — kept deliberately lightweight: `@main BattyApp`, top-level `Scene` and `WindowGroup` wiring, app-level menus, and any glue code that has to live in the app target (Sparkle integration, app-lifecycle delegates). Consumes `BattyKit` as a local SPM dependency.

This keeps the app target thin, makes the bulk of the code unit-testable in `BattyKitTests` (which has full access to `import BattyKit`), and gives each piece of code direct access to the libghostty Swift wrappers without having to round-trip through the app target. New Swift files for layout, models, persistence, theming, and views should land in `BattyKit/Sources/BattyKit/`; reserve `Batty/` for code that genuinely has to be in the app bundle.

### Dependencies

| Dependency | Source | Purpose |
|---|---|---|
| `GhosttyKit` | `libghostty-spm` (https://github.com/Lakr233/libghostty-spm) | Raw libghostty C API — used for direct calls when the higher-level wrappers don't suffice (e.g. `ghostty_surface_text`) |
| `GhosttyTerminal` | `libghostty-spm` | Swift wrapper providing `TerminalSurfaceView` (SwiftUI), `TerminalView` (NSView), `TerminalViewState` (`@Observable`), the split delegate protocols (bell, OSC 9, title, pwd, focus, close), and `TerminalKeyEventHandler`. Replaces what we'd otherwise build from scratch for M1 |
| `GhosttyTheme` | `libghostty-spm` | 485 prebuilt themes via `GhosttyThemeCatalog` plus `GhosttyThemeDefinition` types and a `+TerminalConfiguration` adapter that produces a config applicable to `TerminalViewState.theme` |
| `SlidingTabs` | Local SPM at `/Users/brennan/Developer/brennanMKE/SlidingTabs` (or its GitHub URL) | Per-pane tab bar with drag-reorder and unseen-dot |
| `Sparkle` | SPM | Auto-update for non-App-Store distribution (M10) |

`GhosttyKit`, `GhosttyTerminal`, `GhosttyTheme`, and `SlidingTabs` are declared as dependencies of **`BattyKit`**, not the app target. `Sparkle` will likely live in the app target since it integrates with `NSApplication`.

**Use existing dependencies before writing new code.** Where `libghostty-spm`'s wrappers, delegate protocols, or theme catalog already cover a requirement, use them. Implement custom code only where there's a real gap (e.g. drag-drop, our specific multi-session/multi-pane UI, persistence model, bell aggregation). This rule supersedes the original "build our own NSView" plan implied by earlier drafts of this PRD.

### Integration path

Start with **Path A** (`libghostty-spm` prebuilt xcframework) for the fastest "hello surface." Move to **Path B** (build libghostty from source) once we need to pin to a specific commit or patch the C API.

---

## 9. Milestones

| Milestone | Definition of done |
|---|---|
| **M0 — Project skeleton** | Xcode project created, `GhosttyKit` linked, `SlidingTabs` linked, terminfo + shell-integration resources copied into the bundle. App launches to an empty window with a (stub) sidebar and detail area. |
| **M1 — Hello, surface** | A single libghostty surface renders inside a single pane in a single session. Working shell prompt. Typing works. Fonts look right. |
| **M2 — Sessions sidebar** | Left sidebar lists sessions; "+" creates a new session; selecting a session swaps the detail area. Sidebar collapses/expands. Cmd-Shift-1..9 selects sessions. |
| **M3 — Tabs in a pane (SlidingTabs)** | Each pane shows a SlidingTabs bar. Cmd-T / Cmd-W / Cmd-1..9 work. Drag-to-reorder works. Tab title auto-updates from focused surface. |
| **M4 — Splits** | `SplitNode` tree replaces the single-pane layout. SF Symbol split buttons + Cmd-D / Cmd-Shift-D split the focused pane. Drag-to-resize dividers, focus movement, and resize keybindings all work. Closing the last tab in a pane collapses the split. |
| **M5 — Drag & drop files** | Dropping files from Finder onto a pane inserts shell-quoted paths via `ghostty_surface_text`. Drag-over highlight on the target pane. |
| **M6 — Notifications & bell feed** | Bell hook captures BEL + OSC 9 events. Feed popover lists events. Clicking an entry brings the source forward (window → session → pane → tab). Per-tab unseen dot via SlidingTabs. System notifications when not frontmost. |
| **M7 — Persistence** | Quit and relaunch restores sessions, split trees, panes, tabs, cwds, and feed history. |
| **M8 — Themes** | Theme picker in the View menu. Ghostty `.ghostty` theme files load. |
| **M9 — Polish** | Settings window. Paste-confirmation sheet. Close-confirmation when processes are running. App icon. About panel. |
| **M10 — Ship v1** | Code-signed, notarized, distributed via direct download (not App Store; sandbox doesn't fit a terminal). Sparkle for auto-updates. |

**Stop point for v1: end of M10.** Anything beyond is v2 territory.

---

## 10. Future / v2 ideas (not committed)

- **SSH connection manager.** A "create session from saved host" dialog that opens a new session preconfigured with `ssh user@host`.
- **Mosh integration.** Roaming + reconnection for spotty networks.
- **Echolocation (the remote feature).** A companion iOS app over the local network that exposes Batty's running terminals to a phone client. The "colony of bats away from the roost, communicating by echo" framing. Modeled on Muxy's mobile companion. Bell feed sync would be a natural extension.
- **Command palette.** Cmd-Shift-P to fuzzy-search actions, sessions, panes, tabs, and themes.
- **Session presets.** Save named layouts (e.g. "frontend dev" = three panes with specific cwds) and launch them from a menu.
- **Per-surface theme overrides.**
- **Bell-event filtering.** Per-session "ignore quiet bells" or pattern matchers for noisy programs.
- **Background-session freeze.** If memory becomes an issue, snapshot scrollback and kill PTYs for sessions not visited in N minutes; rehydrate on selection.

---

## 11. Risks & open questions

- **libghostty C API instability.** Pre-1.0 and explicitly in flux. Mitigation: pin to a specific commit; budget time for breakage when bumping.
- **Bell hook availability.** I'm assuming libghostty exposes a per-surface bell callback (and ideally an OSC 9 message hook). Need to confirm against the current Doxygen / `libghostty.tip.ghostty.org` API. If only BEL is exposed and not OSC 9, the feed loses message bodies but still works.
- **Background-surface cost.** Keeping all surfaces in non-active sessions and non-active tabs alive means N tabs × M panes × K sessions, which can balloon. Mitigation: monitor real-world memory; consider lazy "freeze" as a v2 optimization (see §10).
- **Split divider implementation.** SwiftUI's `HSplitView` / `VSplitView` work but are limited; we may need a custom divider for live ratio updates and persistence. Decide during M4.
- **Resource bundle correctness.** terminfo + shell-integration must land in `.app/Contents/Resources/` exactly right or shell integration silently degrades. Mitigation: build phase script; smoke test on every build.
- **Code signing & notarization.** Required for distribution outside the App Store. Mitigation: set up Developer ID + notary workflow before M10.
- **SwiftUI ↔ NSView lifecycle bugs.** SwiftUI loves to rebuild views; we must not let that recreate live surfaces. Mitigation: surface registry indirection, plus careful `dismantleNSView`.
- **Metal layer sizing on resize.** Get `drawableSize` wrong and text blurs or clips. Mitigation: follow Kytos' notes; test resize aggressively.
- **macOS 15 floor.** SlidingTabs requires macOS 15. Acceptable for me; flag if a wider audience is targeted later.
- **Open question:** how strict should paste confirmation be? Confirm on any newline, or only on multi-line + suspicious commands? (Decide during M9.)

---

## 12. Success criteria

Batty v1 ships when:

1. I've replaced my current tmux-like app with Batty for at least two weeks of daily work without falling back.
2. Layout persistence has survived 10+ relaunches without data loss or crashes.
3. The bell feed has caught at least one background event I would have otherwise missed.
4. No reproducible crash for a week of daily use.
5. The keybindings in §5 all work without conflict against system shortcuts.

If those five hold, ship it.

---

*Document version: 0.3 — 2026-05-08. Corrects layout model: tabs live inside panes (not above them), splits operate on panes within a session.*
