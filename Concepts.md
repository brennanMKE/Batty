# Batty — Concepts

Shared vocabulary for the Batty app. The PRD and every issue should use these terms exactly. If a term is missing here, add it before using it.

---

## At a glance

```
Window
├── Sidebar  ─── lists Sessions ────────────┐
└── Detail (the selected Session)           │
    └── Split tree                          │
        └── Pane (leaf)                     │
            └── Tab bar                     │
                └── Tab                     │
                    └── Terminal Session ◄──┘ owned by exactly one Tab
```

Containment, top to bottom: **Window → Session → Pane → Tab → Terminal Session.**
Layout glue: **Split** nodes arrange Panes within a Session.
Customization: **Theme**.
Cross-cutting state: **Focus**, **Bell event**, **Bell Feed**, **Surface registry**.

---

# Containers

## Window

A standard macOS `NSWindow` rendered by SwiftUI.

- **Default count:** 1. Most users run Batty in a single window.
- **Multi-window:** supported for users with multiple displays. Open with Cmd-N. Each Window is independent — its own Sidebar list of Sessions, its own selected Session.
- **Contains:** a collapsible left **Sidebar** plus a **Detail Area** that shows the currently selected Session.
- **Lifecycle:** lives until the user closes it (Cmd-W on the window chrome) or quits the app. Closing the last window does not quit the app on macOS by default.
- **Persisted:** ordered list of Windows, the selected Session in each, and frame/zoom state.

---

## Session

A named workspace, listed as one row in the Window's Sidebar.

- **Purpose:** group Panes that belong together — typically one Session per project, context, or remote host.
- **Contains:** a recursive **Split tree** whose leaves are **Panes**. Plus a `focusedPaneID`. A new Session starts with one Pane that contains one Tab that contains one Terminal Session.
- **Identity:** stable `id: UUID`, plus a user-editable `title` (and optional icon/color).
- **Selection:** exactly one Session is selected per Window at a time. Selecting a Session swaps the Detail Area to that Session's Split tree. Surfaces in non-selected Sessions stay alive so switching is instant and processes keep running.
- **Sidebar affordances:** drag to reorder; right-click to Rename / Duplicate / Close; "+" toolbar button creates a new Session.
- **CWD inheritance:** a newly created Session's first Pane spawns its shell in the previously-focused Pane's active-Tab cwd when one is known, mirroring the way Cmd-T inherits cwd within a Pane; falls back to the shell's default (`$HOME`) when no previously-selected Session exists.
- **Name cache:** a small JSON file at `~/Library/Application Support/Batty/session-name-cache.json` remembers the most recent user-chosen Session title per working directory. Renaming a Session writes `(firstPaneFirstTabCWD, newName)` (skipping default `Session N` titles); creating a new Session looks up the inherited CWD before falling back to `Session N`, so opening a fresh Session in a known project directory auto-applies the previously-chosen name. Exact-path match, capped at 100 entries with LRU eviction, atomic writes, debounced.
- **Keybinding:** Cmd-Option-1..9 selects the Nth Session in the active Window. (Cmd-Shift-Number is reserved by macOS for screenshot hotkeys, so we use Cmd-Option-Number — same family iTerm2 uses for session/window selection.)
- **Persisted:** ordered list per Window, plus everything inside.

> "Session" is overloaded in terminal-land — to be precise, a Batty **Session** is a *workspace grouping*. The actual *running shell process* is a **Terminal Session** (below). When the doc just says "session" unqualified, it means the workspace grouping.

---

## Pane

A single visible region inside a Session — a leaf of the Split tree.

- **Purpose:** hosts the Tab bar and renders the active Tab's Terminal Session.
- **Contains:** an ordered list of **Tabs** plus an `activeTabID`. A Pane always has at least one Tab (closing the last Tab removes the Pane).
- **Layout:** Panes are arranged within a Session by the **Split tree**.
- **Splitting:**
  - `rectangle.split.2x1` toolbar button or Cmd-D — split the focused Pane horizontally; new Pane appears to the right.
  - `rectangle.split.1x2` toolbar button or Cmd-Shift-D — split the focused Pane vertically; new Pane appears below.
  - The new Pane is born with one Tab containing one fresh Terminal Session in the parent Pane's cwd.
- **Resizing:**
  - Mouse: drag the Split divider between Panes.
  - Keyboard: Cmd-Ctrl-arrows resize the Split containing focus by ±5%.
- **Focus movement:** Cmd-Option-arrows move focus between Panes within the active Session.
- **Closing:** when the last Tab in a Pane closes (Cmd-W), the Pane is removed and its parent Split collapses — the sibling subtree takes over the parent's space.
- **Persisted:** position in the Split tree, ordered Tab list, active Tab.

---

## Tab

One entry in a Pane's Tab bar. Each Tab owns exactly one Terminal Session.

- **Purpose:** lets a single Pane host multiple shells without changing the Split layout.
- **Rendered by:** the **SlidingTabs** Swift package — Safari-style horizontal chips with drag-to-reorder and an "unseen" dot that we map to bell state.
- **Identity:** stable `id: UUID`. Each Tab references its Terminal Session by surface UUID.
- **Title resolution:** focused-surface process name → cwd basename → user-set override (first non-empty wins).
- **Operations:**
  - Cmd-T — add a new Tab to the focused Pane (with a fresh Terminal Session).
  - Cmd-W — close the focused Tab. If it was the last Tab in the Pane, the Pane is removed (see Pane).
  - Cmd-1..9 — select the Nth Tab in the focused Pane.
  - Cmd-Shift-[ / ] — cycle Tabs within the focused Pane.
  - Drag chip to reorder.
- **Background behavior:** non-active Tabs in a Pane keep their Terminal Session running (PTY/shell stay alive). Switching Tabs only swaps which surface is rendered.
- **Persisted:** id, title override, ordering, the surface's cwd at last snapshot.

---

## Terminal Session

The actual running terminal — one libghostty surface with a PTY, a shell process, and a render target.

- **One-to-one with a Tab.** A Terminal Session is born when its Tab is created and torn down when its Tab closes (PTY killed, Metal resources released).
- **Implementation:** a `ghostty_surface_t` from libghostty, wrapped in an `NSView` that owns a `CAMetalLayer` and implements `NSTextInputClient` (IME) and `NSDraggingDestination` (file drops).
- **Identity:** stable `surfaceID: UUID`. Looked up via the **Surface registry**: `[UUID: ghostty_surface_t]`. The registry decouples surface lifetime from SwiftUI view identity — SwiftUI rebuilding a `TerminalSurfaceView` does **not** kill the underlying terminal.
- **What it owns:**
  - The PTY and the shell process.
  - libghostty's IO thread and render thread for that surface.
  - Selection model, scrollback buffer, terminal state.
  - Bell counters and the OSC 9 message buffer.
- **What it does not own:** layout, focus arbitration, Tab/Pane membership — those live in the SwiftUI tree above it.
- **Persisted:** working directory and last-set title only. We do **not** restore running processes — relaunched shells start fresh in the saved cwd.

> Ghostty's own term for this is "surface." We use **Terminal Session** in user-facing copy because it's clearer to a person who hasn't read libghostty's docs. In code, `surface` and `surfaceID` are fine.

---

# Layout & UI primitives

## Split

A non-leaf node in a Session's layout tree that arranges two child subtrees side-by-side or stacked. Splits are how Panes are *arranged*; they are not themselves containers of content.

- **Shape:** `split(direction: SplitDirection, ratio: Double, left: SplitNode, right: SplitNode)`.
  - `direction`: `.horizontal` (children placed left/right, divider is vertical) or `.vertical` (children placed top/bottom, divider is horizontal).
  - `ratio`: 0.0–1.0, the proportion taken by the *left* (or *top*) child.
  - `left`, `right`: each a `SplitNode` — either another Split or a leaf `Pane`.
- **Created by:** splitting a Pane via the toolbar buttons or Cmd-D / Cmd-Shift-D.
- **Resized by:** dragging the divider, or Cmd-Ctrl-arrows. Updates to `ratio` are persisted.
- **Collapsed:** when one of a Split's children becomes empty (the last Tab in a Pane closed), the Split is replaced by its remaining child in the parent's slot.
- **Note on terminology:** the SF Symbol `rectangle.split.2x1` shows a rectangle divided into two columns (left/right) — this is the visual for a horizontal Split. `rectangle.split.1x2` shows two rows stacked — the visual for a vertical Split. Verbally we say "split horizontally" to mean side-by-side and "split vertically" to mean stacked, matching the SF Symbol intuition.

---

## Sidebar

The left-side region of a Window that lists the Window's Sessions.

- **Implementation:** the leading column of `NavigationSplitView`.
- **Contents:**
  - Header / toolbar with a "+" button to create a Session.
  - A `List` of Session rows, each showing title, total live Tab count, and an unseen-bell badge if any descendant has unseen bells.
  - Drag-to-reorder.
- **Collapsibility:** the user can hide and show the Sidebar (View → Hide Sidebar, Cmd-Ctrl-S, or the standard NavigationSplitView toggle button in the toolbar). Collapsed state is persisted per Window.
- **Selection:** exactly one Session is selected at a time per Window; clicking a row selects it.

---

# Customization

## Theme

A named visual style applied to every Terminal Session in the app: foreground / background / cursor / selection colors and the 16 ANSI palette colors.

- **File format:** Ghostty-format `.ghostty` theme files. We do not invent a new format — being a drop-in consumer of the existing 200+ Ghostty themes is the point.
- **Sources** (searched in this order, deduplicated by name):
  1. The app bundle (`Batty.app/Contents/Resources/Themes/`) — a small set of defaults shipped with the app.
  2. `~/.config/ghostty/themes/` — the user's existing Ghostty themes if present.
- **Selection:** app-wide, set via the View → Theme submenu. Persisted in `UserDefaults`.
- **Scope (v1):** one Theme applies to all Terminal Sessions in all Sessions in all Windows. Per-Session or per-Pane Theme overrides are out of scope (see PRD §10).
- **Application:** Theme values are pushed into libghostty via the surface config. Live theme changes update existing surfaces without restarting them.

---

# Events & feedback

## Focus

The single keyboard-active leaf in the app at any time.

- **Granularity:** focus is on a **Tab** (and therefore a Terminal Session, since each Tab owns one). Selecting a different Session, Pane, or Tab moves focus.
- **Bubble-up chain:** focused Terminal Session → focused Tab → focused Pane → focused Session → key Window.
- **Effects:**
  - Keyboard input goes to the focused Terminal Session.
  - Cmd-D, Cmd-T, Cmd-W, split buttons, and similar all use the focused Pane / Tab as the implicit target.
  - Bell events from the focused Tab record to the **Bell Feed** but do not increment unseen counters.
- **Movement:**
  - Within a Session: Cmd-Option-arrows move focus between Panes; clicking a Pane focuses it; Cmd-1..9 selects a Tab in the focused Pane.
  - Across Sessions: clicking a Session in the Sidebar or Cmd-Option-1..9 moves focus to that Session's `focusedPaneID`'s active Tab.
  - Across Windows: standard macOS Cmd-` / window picker.

---

## Bell event

A signal from a Terminal Session that something happened.

- **Sources (v1):**
  - **ASCII BEL** (`\a`, 0x07) — the classic terminal bell, captured via libghostty's per-surface bell callback.
  - **OSC 9** — `ESC ] 9 ; <message> BEL`, the iTerm-style notification escape sequence. If libghostty exposes the message body, we capture it; otherwise we record the bell with no message.
- **Recorded against the originating Terminal Session:** `bellCount`, `lastBellAt`, `lastBellMessage`.
- **Unseen propagation:** a Bell event from a Tab that is not the focused Tab increments unseen counters at every level above it: Tab → Pane → Session. A Bell event from the focused Tab is recorded to the feed but does **not** increment unseen counters.
- **Side effects (configurable in Settings):**
  - Append an entry to the **Bell Feed**.
  - Optionally play a system sound.
  - If the app is not frontmost, post a **System notification**.
- **Visual feedback:**
  - SlidingTabs chip: `hasUnseen` dot.
  - Pane border: subtle accent flash for ~1s on bell; sustained dot when an inactive Tab in the Pane has unseen bells.
  - Sidebar Session row: small dot or count badge when any descendant has unseen bells.

---

## Bell Feed

The unified, app-wide list of recent **Bell events** across every Terminal Session.

- **Access:**
  - Toolbar button using the SF Symbol `bell.badge` when there are unseen events, `bell` when clean.
  - Keybinding: Cmd-Shift-N.
  - Renders as a popover (or sheet) attached to the bell button.
- **Contents:** newest-first, scrollable, capped (e.g. 200 entries) and persisted across launches.
- **Each entry shows:**
  - Timestamp (relative: "2m ago", absolute on hover).
  - Path: `<Session> › <Pane> › <Tab>`.
  - Message body (OSC 9) or a short preview line if available.
  - An unseen indicator until the entry is clicked or "Clear all" is invoked.
- **Click-to-jump (the canonical "bring forward" flow):**
  1. Make the source Window key (`makeKeyAndOrderFront`).
  2. Select the source Session in the Sidebar.
  3. Focus the source Pane in the Session's Split tree.
  4. Activate the source Tab inside that Pane.
  5. Mark the entry seen and decrement unseen counters at every level.
- **Same flow** is invoked when the user taps a System notification posted by Batty.
- **Lifetime:** in-memory only; does not survive a relaunch.

---

## System notification

A `UNNotificationRequest` posted via Apple's `UserNotifications` framework — the things that show up in Notification Center.

- **When posted:** on a Bell event whose source is *not* visible — i.e. the app is not frontmost, *or* the source is in a non-active Session/Pane/Tab.
- **Content:**
  - Title: `Batty — <Session> › <Pane> › <Tab>`.
  - Body: OSC 9 message if present, else `"Bell"`.
- **Tap behavior:** invokes the same click-to-jump flow as a Bell Feed entry.
- **User control:** Settings toggles for system notifications globally and per-Session mute.

---

# State & infrastructure

## Surface registry

Process-wide map `[UUID: ghostty_surface_t]`. The single source of truth for live Terminal Sessions.

- **Why it exists:** the SwiftUI tree only ever stores `surfaceID: UUID` — never the C handle directly. SwiftUI is free to rebuild views; the Terminal Session is unaffected.
- **Lifecycle:**
  - Insert when a Tab creates a new Terminal Session.
  - Lookup when rendering, when forwarding input, when posting a bell event, when a feed entry is clicked.
  - Remove and tear down when the Tab is closed (kill PTY, free Metal resources).
- **Threading:** the registry is accessed from the main actor; libghostty's IO/render threads call back into us via callbacks that we marshal to the main actor.

---

## Settings

User-controlled preferences that are *not* layout. Stored in `UserDefaults`.

- **Default shell** (auto-detected, overridable).
- **Font family + size.**
- **Theme** (the selected Theme name; see Theme).
- **Cursor style** (block / bar / underline; static / blinking).
- **Bell behavior:** play sound on bell, post system notifications on bell, per-Session mute list.
- **Paste confirmation strictness** (see PRD §11).
- **Confirm on close with running processes** (yes/no).

---

*Document version: 0.3 — 2026-05-20. Removes Workspace persistence (never a planned feature). Update whenever a new term gets introduced in the PRD or in issues.*
