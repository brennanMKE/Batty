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
Saved definitions: **Project** (what a Session can be opened *from*; not part of the containment chain).
Cross-cutting state: **Focus**, **Bell event**, **Bell Feed**, **Surface registry**.

---

# Containers

## Window

A standard macOS `NSWindow` rendered by SwiftUI.

- **Default count:** 1. Most users run Batty in a single window.
- **Multi-window:** planned, not yet implemented (#0234; design in `docs/multi-window-design.md`) — for users with multiple displays. Will open with Shift-Cmd-N (Cmd-N creates a new Session, per #0063). Each Window is independent — its own Sidebar list of Sessions, its own selected Session.
- **Contains:** a collapsible left **Sidebar** plus a **Detail Area** that shows the currently selected Session.
- **Lifecycle:** lives until the user closes it (Cmd-W on the window chrome) or quits the app. Closing the last window does not quit the app on macOS by default.
- **Persisted:** no layout — no ordered Window list, no per-Window selected Session, no frame/zoom state is saved by Batty. Batty opts out of window restoration (`.restorationBehavior(.disabled)`, #0444), so every launch opens one Window with a fresh Session 1, and the Sidebar's collapsed state (per-Window `@SceneStorage`, see Sidebar) lasts only for the life of the process. Whether the Window's frame is remembered across relaunches is unverified: Batty sets no frame autosave name of its own, and AppKit's `NSWindow Frame ...` defaults entry may or may not be read back.

---

## Project

A saved, user-authored record of how to start a Session: what a Session is opened *from*.

- **Contains:** a name, a root folder, a Session color, a symbol (one of the curated SF Symbols, `ProjectSymbol`; the folder when none is chosen), a Layout (a `PaneLayout` preset or a captured topology), a kind for each Pane, Terminal Tabs (each with an optional title, a working directory relative to the root, and an optional startup command), the Git Status repository folder, a "run startup commands on open" toggle, an optional terminal background (#0540), and an optional Dark Theme and Light Theme (#0584). No background means the Session follows Settings; one with no image hides any app-wide image.
- **Opening:** opening a Project creates a new Session with its title and color pinned. A Session opened from a Project is **Project-backed** for its lifetime. The association is in-memory only, shown in the Sidebar by the Project's symbol (the folder by default), and does not constrain the shell, which can `cd` anywhere.
- **Storage:** `~/Library/Application Support/<Batty|Batty Beta>/projects.json`. Records are written only on explicit user action. Opening a Project records its last-opened time (`lastOpenedAt`) in the same file, and every Projects list except the Project Editor's shows the most recently opened first, with open Projects last (the Open Project picker shows them in their own Open now strip instead). Nothing is auto-saved, nothing is captured on quit or on a timer, and nothing is restored at launch. That is why Projects are not a revival of the Workspace persistence removed in #0172: a Project is a definition the user authored, not a snapshot of live state.
- **Pane sizes:** not stored. Splits open as equal splits (#0255).
- **Tab backgrounds:** each Terminal Tab can carry its own background, set on its card in the Project Editor (#0585). A Tab with none follows the Project's background, which follows Settings when it has none. Opening the Project seeds each Tab's own value; Save as Project and Update Project capture each Tab's own value, else its Pane's.
- **Startup commands:** literal lines typed into the Tab's shell. They run only after a trust confirmation, and are re-confirmed when they change (the approval hash covers the Project root, and each command's Pane, Tab, directory and text). Each line is pasted and then followed by a real Return key press, so a multi-line command runs line by line; control characters and Unicode format characters are dropped. A command runs once, on the next main-queue turn after the Tab's shell first reports its working directory (OSC 7), or after arming if that report already arrived. The integration libghostty actually loads is the one bundled in the `libghostty-spm` package, and it covers zsh and bash only. The fish, elvish and nushell integrations in the app bundle's `ghostty/shell-integration/` are not sourced at runtime (#0400), so a shell other than zsh or bash reports OSC 7 only natively or through the user's own configuration. Batty never types a command blindly into a shell that has not reported: the shell may be at a password or login prompt. If the first report has not arrived 10 seconds after the Tab's surface attached, the Tab chip shows a warning indicator, and its menu (also in the Tab's context menu) shows the pending command with **Run Now** and **Dismiss**. The command stays armed, so a late report still runs it once and clears the indicator; Run Now types it once and a later report does not repeat it; Dismiss discards it. If the shell exits before reporting, the command is discarded and no indicator appears. Input goes through the Tab's terminal state, so an IME composition the user has open stays as preedit and is not committed onto the command line.
- **Shared or local:** each Project is **local** (the default) or **Shared**, set by a checkbox on every picker card and in the Project Editor. Shared means the user chose to sync it through iCloud to their other Macs. Every record splits into a *definition* (name, root, color, symbol, Layout, the run toggle, the background's fit, position and opacities, the Theme, `modifiedAt`), which sync, and *device state* (`lastOpenedAt`, the startup-command trust approval, neither of which stamps `modifiedAt`, and the background's image path), which never leaves the Mac: an approval is consent given for commands that run on this Mac. A Tab's own background follows the same split: its fit, position, opacities and image identity (the Background Sets URL for a hosted image, the digest for any other) are definition, and its image path is device state. Another Mac finds the image by identity, or downloads it into the downloaded image cache when the user opens the Project or the Project Editor shows it (#0585); a custom Tab image travels only where `sharedProjectImages` is on. A shared Project's root is carried as a `~`-relative path and decoded against each Mac's home. A Project whose root folder does not exist on this Mac is still listed, with a "Folder not found" caption; opening it fails as before. Conflicts resolve last-writer-wins per Project on `modifiedAt`. A shared Project syncs through iCloud key-value storage, one key per Project, to the user's other Macs signed into the same Apple ID, in a build signed with the iCloud entitlement; a build without it (the routine Apple Development build from `./build.sh` and Xcode, an unsigned or ad-hoc build) keeps the flag but syncs nothing. A test process builds no backend even when its host is signed with the entitlement, because of the test-process check. The folder must exist on each Mac. A share iCloud's limits would refuse is refused, with the reason shown, and the Project stays local (`docs/design/projects-sharing.md`). The one sanctioned exception to "written only on explicit user action" is merging the sync backend's changes into `projects.json`, which cannot happen without a backend. Behind the `sharedProjectImages` flag (on in Beta, #0551), a Shared Project's record also carries its image's digest and name, never a path, and the image travels through a per-variant iCloud Drive folder used only as transport; `imagePath` still names a verified local copy.
- **Persisted:** the Project record itself, as above. A Session's membership in a Project is not.

---

## Session

A named workspace, listed as one row in the Window's Sidebar.

- **Purpose:** group Panes that belong together — typically one Session per project, context, or remote host.
- **Contains:** a recursive **Split tree** whose leaves are **Panes**. Plus a `focusedPaneID`. A new Session starts with one Pane that contains one Tab that contains one Terminal Session.
- **Identity:** stable `id: UUID`, plus a user-editable `title` and a **Session color** — one of a fixed 10-color palette (`SessionColor`), assigned automatically at creation by a least-used round-robin scoped to the Window; that assignment is stable for the Session's lifetime unless the user pins a different one. Shown by tinting the Sidebar row's icon: a solid circle, or the Project's symbol for a Project-backed Session. The user can override the assignment via the Sidebar row's context menu (`Set Color…`, a swatch-grid picker; `Reset Color` returns the Session to automatic control without changing its current color, #0336). An explicit choice is sticky — no later automatic assignment reclaims it — and duplicate colors across Sessions are allowed. Not persisted: a Session's color, chosen or automatic, resets on relaunch (see Persisted, below).
- **Selection:** exactly one Session is selected per Window at a time. Selecting a Session swaps the Detail Area to that Session's Split tree. Surfaces in non-selected Sessions stay alive so switching is instant and processes keep running.
- **Sidebar affordances:** drag to reorder; right-click to Rename / Duplicate / Set Color / Set Session Theme / Set Session Background / Close; the "+" button in the Sidebar footer creates a new Session.
- **Background override:** a Session can carry its own terminal background, set from the Sidebar row's context menu (`Set Session Background…`, `Clear Session Background`, #0376). It reaches every Tab in every terminal Pane of the Session, including later Tabs and Splits, except a Pane with its own override. No override means the Session follows the app-wide default; an override is complete and ignores later app-wide changes. In-memory only, and Duplicate doesn't copy it. Opening a Project with a background seeds this override, leaving out an image that fails its check; clearing it then follows the app-wide default, not the Project.
- **Theme override:** a Session can carry its own Theme, a Dark/Light pair, set from the Sidebar row's context menu (`Set Session Theme…`, which sets both slots, and `Clear Session Theme`, #0139). An unset or unknown slot follows the app-wide Theme for that appearance. In-memory only. Opening a Project with a Theme seeds this override; Update Project writes it back only if it changed after the open (#0584).
- **CWD inheritance:** a newly created Session's first Pane spawns its shell in the previously-focused Pane's active-Tab cwd when one is known, mirroring the way Cmd-T inherits cwd within a Pane; falls back to the shell's default (`$HOME`) when no previously-selected Session exists.
- **Name cache:** a small JSON file at `~/Library/Application Support/Batty/session-name-cache.json` remembers the most recent user-chosen Session title per working directory. Renaming a Session writes `(firstPaneFirstTabCWD, newName)` (skipping default `Session N` titles); creating a new Session looks up the inherited CWD before falling back to `Session N`, so opening a fresh Session in a known project directory auto-applies the previously-chosen name. Exact-path match, capped at 100 entries with LRU eviction, atomic writes, debounced. The home folder, `/`, any top-level folder and the temp roots are never recorded and never get a derived name (`NonProjectDirectory`); entries for them are dropped on load. To name home durably, create a Project rooted at `~`.
- **Keybinding:** Cmd-1..9 selects the Nth Session in the active Window by default. Swappable with Cmd-Option-1..9 (which then selects Tabs instead, and is the chord iTerm2 uses for session/window selection) via the `co.sstools.Batty.cmdNumberTarget` preference.
- **Reminder:** a Session can carry at most one pending **Reminder** (below), set from the Session menu, the Sidebar row's context menu, the Command Palette or `batty session remind`. Closing the Session cancels it silently.
- **Persisted:** nothing — the ordered Session list, each Session's Split tree, and everything inside are in-memory only; none of it survives a relaunch. (The Name cache above is a separate mechanism: it remembers a chosen title per working directory, not layout.)

> "Session" is overloaded in terminal-land — to be precise, a Batty **Session** is a *workspace grouping*. The actual *running shell process* is a **Terminal Session** (below). When the doc just says "session" unqualified, it means the workspace grouping.

---

## Pane

A single visible region inside a Session — a leaf of the Split tree.

- **Purpose:** hosts either a Tab bar rendering the active Tab's Terminal Session (a `.terminal`-kind Pane, still the default) or a single non-terminal view (any other `PaneContentKind`, #0315 — `git-status`, `process-status`, `lm-studio-dashboard`, `system-metrics`). `git-status` (#0304) renders its real, approved Git Status view (`docs/design/git-status-view.md`); the remaining kinds still render a provisional placeholder pending their own design approval, see `docs/pane-kinds.md`/`docs/design/`.
- **Contains:** an ordered list of **Tabs** plus an `activeTabID`. A Pane always has at least one Tab (closing the last Tab removes the Pane) — including a non-terminal-kind Pane, whose one Tab is never rendered or given a live Terminal Session (`docs/pane-kinds.md` §1 names the fuller `tabs: []` design; #0315 deliberately keeps this simpler shape for its scope).
- **Layout:** Panes are arranged within a Session by the **Split tree**.
- **Splitting:**
  - `rectangle.split.2x1` toolbar button or Cmd-D — split the focused Pane horizontally; new Pane appears to the right.
  - `rectangle.split.1x2` toolbar button or Cmd-Shift-D — split the focused Pane vertically; new Pane appears below.
  - The new Pane is born with one Tab containing one fresh Terminal Session in the parent Pane's cwd.
  - A split from a non-terminal Pane starts in that Pane's directory (Git Status: the repository directory shown; Process Status: the followed Tab's directory), else in the most recently focused terminal Pane's directory in the same Session.
- **Resizing:**
  - Mouse: drag the Split divider between Panes.
  - Keyboard: Cmd-Ctrl-arrows resize the Split containing focus by ±5%.
- **Focus movement:** Cmd-Option-arrows move focus between Panes within the active Session.
- **Closing:** when the last Tab in a Pane closes (Cmd-W), the Pane is removed and its parent Split collapses — the sibling subtree takes over the parent's space.
- **Background override:** a terminal Pane can carry its own terminal background (image, fit, position, image opacity, terminal opacity), set from the gear beside the eye toggle on its Sidebar row (#0374). It applies to every Tab in the Pane, including later ones, and every write from the gear replaces the Tabs' own values (#0585). No override means the Pane follows its Session's override, then the app-wide default; an override is complete and ignores later changes to either. The chain is Tab, Pane, Session, app-wide. A new Split follows rather than inherits. In-memory only.
- **See-through window:** while any terminal Pane in any Session of a window is below 100% terminal opacity, that window lets the desktop and other apps show through those terminals (#0539). A Pane at 100% still paints itself solid, the Sidebar, title bar, tab bars and dividers stay solid, and native full screen is always opaque.
- **App-wide Background default:** Settings → Appearance sets the terminal background every Pane and Session without an override follows (#0375). Batty stores a path to its own copy of the image, in Application Support, never the user's file. A copy that is missing or has changed since import is left out, so the Tab still opens with a shell and no picture, and Settings says to choose it again.
- **Persisted:** nothing; in-memory only. A Pane's position in the Split tree, its ordered Tab list, and its active Tab do not survive a relaunch.

---

## Tab

One entry in a Pane's Tab bar. Each Tab owns exactly one Terminal Session — true for a `.terminal`-kind Pane, which is every Pane a user can create today and the only kind that renders a Tab bar at all.

- **Exception (#0315):** a non-terminal-kind Pane (`git-status`, `process-status`, `lm-studio-dashboard`, `system-metrics` — see Pane, above) holds exactly one Tab structurally (`PaneRuntime.init`'s precondition is unchanged for every kind), but that Tab has **no live Terminal Session** and is never rendered in a Tab bar or anywhere else. It is deliberately excluded from every Tab-counting/listing surface found to read it (`batty status`'s `tabCount`, `batty list`'s `tabs` array, Open Quickly, the sidebar pane row, the quit-confirmation count) and from every Tab-scoped command dispatch path found to act on it (Cmd-T/Cmd-W/Tab-switching/Exit Shell from the menu bar, the global keyboard-shortcut monitor, *and* the Command Palette — the last of these missed in the first review round precisely because it was a third, independently hand-copied dispatch switch). It exists only because #0315 deliberately deferred the fuller `tabs: []` pane-kind migration `docs/pane-kinds.md` §1 designs, to keep that issue's diff surgical — see `PaneRuntime.kind`'s and `SessionRuntime.focusedTerminalPane`'s doc comments for the full rationale and `docs/pane-kinds.md`'s "Implementation note (2026-08-09, `#0315`)" addendum for the enumerated list of places this exception had to be kind-gated. That list, and this bullet, describe every consumer found across three review rounds — not a provable exhaustive set; a future consumer that walks "every Pane" without checking `kind` would reproduce the same class of bug.
- **Purpose:** lets a single Pane host multiple shells without changing the Split layout.
- **Rendered by:** the **SlidingTabs** Swift package — Safari-style horizontal chips with drag-to-reorder and an "unseen" dot that we map to bell state.
- **Identity:** stable `id: UUID`. Each Tab references its Terminal Session by surface UUID.
- **Title resolution:** focused-surface process name → cwd basename → user-set override (first non-empty wins).
- **Operations:**
  - Cmd-T — add a new Tab to the focused Pane (with a fresh Terminal Session).
  - Cmd-W — close the focused Tab. If it was the last Tab in the Pane, the Pane is removed (see Pane).
  - Cmd-Option-1..9 — select the Nth Tab in the focused Pane (default; swaps with Cmd-1..9 via the `cmdNumberTarget` preference).
  - Cmd-Shift-[ / ] — cycle Tabs within the focused Pane.
  - Drag chip to reorder.
- **Background:** a terminal Tab can carry its own terminal background, set from its chip's context menu (`Background…`, `Clear Background`, #0585). The chain is Tab, then Pane, then Session, then the app-wide default; a value is complete. A write from the Pane's gear replaces every Tab's own value in that Pane, so the most recent action wins, and Cancel in the Pane sheet puts them back. `Set Session Background…` leaves Tab values alone. New Tabs, Duplicate Tab and Splits don't copy it. In-memory only, apart from a Project seeding it.
- **Background behavior:** non-active Tabs in a Pane keep their Terminal Session running (PTY/shell stay alive). Switching Tabs only swaps which surface is rendered.
- **Persisted:** nothing; in-memory only. A Tab's id, title override, and ordering do not survive a relaunch.

---

## Terminal Session

The actual running terminal — one libghostty surface with a PTY, a shell process, and a render target.

- **One-to-one with a Tab in a `.terminal`-kind Pane.** A Terminal Session is born when its Tab is created and torn down when its Tab closes (PTY killed, Metal resources released). A non-terminal-kind Pane's one Tab (#0315, see Tab, above) is the exception: it never gets a Terminal Session at all — no PTY is ever spawned for it.
- **Implementation:** a `ghostty_surface_t` from libghostty, wrapped in an `NSView` that owns a `CAMetalLayer` and implements `NSTextInputClient` (IME) and `NSDraggingDestination` (file drops).
- **Identity:** stable `surfaceID: UUID`. Looked up via the **Surface registry**: `[UUID: ghostty_surface_t]`. The registry decouples surface lifetime from SwiftUI view identity — SwiftUI rebuilding a `TerminalSurfaceView` does **not** kill the underlying terminal.
- **What it owns:**
  - The PTY and the shell process.
  - libghostty's IO thread and render thread for that surface.
  - Selection model, scrollback buffer, terminal state.
  - Bell counters and the OSC 9 message buffer.
- **What it does not own:** layout, focus arbitration, Tab/Pane membership — those live in the SwiftUI tree above it.
- **Persisted:** nothing; in-memory only. We do **not** restore running processes, and no working directory or title is saved — a relaunched shell starts wherever the shell's own default takes it (typically `$HOME`), not in the Terminal Session's prior cwd.

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
- **Resized by:** dragging the divider, or Cmd-Ctrl-arrows. Updates to `ratio` are in-memory only; they do not survive a relaunch.
- **Collapsed:** when one of a Split's children becomes empty (the last Tab in a Pane closed), the Split is replaced by its remaining child in the parent's slot.
- **Note on terminology:** the SF Symbol `rectangle.split.2x1` shows a rectangle divided into two columns (left/right) — this is the visual for a horizontal Split. `rectangle.split.1x2` shows two rows stacked — the visual for a vertical Split. Verbally we say "split horizontally" to mean side-by-side and "split vertically" to mean stacked, matching the SF Symbol intuition.

---

## Sidebar

The left-side region of a Window that lists the Window's Sessions.

- **Implementation:** the leading column of `NavigationSplitView`.
- **Contents:**
  - A footer with a "+" button to create a Session and an Open Project button that presents the Open Project picker.
  - A `List` of Session rows, each showing title, total live Tab count, and an unseen-bell badge if any descendant has unseen bells. A row can also show a **Reminder** badge: a clock while a Reminder is pending, an accent alarm from the moment it fires until the user acknowledges it.
  - Drag-to-reorder.
- **Collapsibility:** the user can hide and show the Sidebar (View → Hide Sidebar, Cmd-B, or the standard NavigationSplitView toggle button in the toolbar). Collapsed state is kept per Window for the life of the process (`@SceneStorage`); it is not restored across relaunches because window restoration is disabled (#0444).
- **Selection:** exactly one Session is selected at a time per Window; clicking a row selects it.

---

# Customization

## Background Images

The window (File → Background Images…) and the library behind it: every background image Batty holds, each with a thumbnail, what uses it and its size. Choose… in a background control opens the same content as a sheet to pick from.

- **Where images live:** `BackgroundImages/` beside `projects.json`, per variant, one folder per image digest. Only the user's Remove deletes from it. Opening the window or the picker copies images saved in the app-wide, Project and this process's Pane folders into it.
- **Each use keeps its own copy** in its own folder: the app-wide default, a Project, or a Session or Pane. Picking copies from the library into that folder, so no stored path names the library.
- **Remove** clears every use on this Mac, listing them first, then deletes the image from the library and every other folder. A use's fit, position and opacities stay. A Shared Project changes on this Mac only. It refuses, removing nothing, while a saved Project it can't see might use the image.
- **What syncs:** behind the `sharedProjectImages` flag (on in Beta, #0551), only an image selected for a Project set to Shared is copied to iCloud Drive. Being in the library, or used by a Pane, a Session, the app-wide default or a local Project, never copies it. Remove leaves the shared copy alone.
- **Background Catalog** (1.4.0, #0576): a JSON file listing Background Sets, each with a name and images, each with a title, given as full-size and thumbnail URLs (format in #0574, decisions 12 and 13). The **built-in catalog** is `https://batty.sstools.co/backgrounds/catalog.json`; code is keyed by catalog URL so user catalogs (#0577) add to the list.
- **Background Set**: a named group of hosted images in a catalog, shown in the window's Background Sets tab with thumbnails only. No request is made before Background Sets is first shown.
- **Downloaded image cache** (#0585): `BackgroundImages/Downloaded/`, images fetched because a synced Project Tab named them. At most 20 images and 500 MB, least recently used evicted first; an image something on this Mac shows or waits for is never evicted. An evicted image keeps its Tab's identity and is downloaded again on the next open. Never joins My Images; Remove deletes from it too.
- **Hosted image store**: `BackgroundImages/Hosted/`, Batty's re-encoded copies of hosted images. A hosted image is identified by its full-size URL and downloaded only when it is selected as a background (select-to-download), stays in its set, and never joins My Images; a scan never promotes a digest held there. A use's copy keeps working after the catalog drops the image.

## Theme

A named visual style applied to every Terminal Session in the app: foreground / background / cursor / selection colors and the 16 ANSI palette colors.

- **File format:** Ghostty-format `.ghostty` theme files. We do not invent a new format — being a drop-in consumer of the existing 200+ Ghostty themes is the point.
- **Sources** (searched in this order, deduplicated by name):
  1. The app bundle (`Batty.app/Contents/Resources/Themes/`) — a small set of defaults shipped with the app.
  2. `~/.config/ghostty/themes/` — the user's existing Ghostty themes if present.
- **Selection:** app-wide, set via the View → Theme submenu. Persisted in `UserDefaults`.
- **Scope:**
  - the app-wide Dark/Light pair (#0241), which every Session follows by default;
  - an in-memory **Session Theme** override, itself a Dark/Light pair (#0139). **Set Session Theme…** sets both slots to one Theme; an unset or unknown slot follows the app-wide Theme for that appearance;
  - a **Project Theme** (#0584), an optional Dark and Light Theme stored on the Project, which seeds the Session Theme when the Project opens.
  Per-Pane Theme overrides are out of scope.
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
  - Bell events from the focused Tab, while Batty is the active app, add no **Bell Feed** entry and don't increment unseen counters. While Batty is in the background they add a seen entry and post the banner.
  - A user gesture that lands on a Tab (Sidebar click, Cmd-1..9, terminal or chip click, Pane/Tab navigation, a Feed jump, `batty … focus`) is a **visit** and removes that Tab's **Bell Feed** rows. Focus that falls back onto a Tab because something closed only marks its rows seen (#0556).
- **Movement:**
  - Within a Session: Cmd-Option-arrows move focus between Panes; clicking a Pane focuses it; Cmd-Option-1..9 selects a Tab in the focused Pane.
  - Across Sessions: clicking a Session in the Sidebar or Cmd-1..9 moves focus to that Session's `focusedPaneID`'s active Tab.
  - Across Windows: standard macOS Cmd-` / window picker.

---

## Bell event

A signal from a Terminal Session that something happened.

- **Sources (v1):**
  - **ASCII BEL** (`\a`, 0x07) — the classic terminal bell, captured via libghostty's per-surface bell callback.
  - **OSC 9** — `ESC ] 9 ; <message> BEL`, the iTerm-style notification escape sequence. If libghostty exposes the message body, we capture it; otherwise we record the bell with no message.
- **Recorded against the originating Terminal Session:** `bellCount`, `lastBellAt`, `lastBellMessage`.
- **Unseen propagation:** a Bell event from a Tab that is not the focused Tab increments unseen counters at every level above it: Tab → Pane → Session. A Bell event from the focused Tab does **not** increment unseen counters; while Batty is the active app it adds no Bell Feed entry either, and in the background it adds a seen entry and posts the banner. A Bell event from a muted Session adds no Bell Feed entry and increments no unseen counter (#0558).
- **Side effects (configurable in Settings):**
  - Append an entry to the **Bell Feed**, unless it is seen at creation while Batty is active. A Bell event from a muted Session adds no Bell Feed entry and increments no unseen counter.
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
  - Keybinding: Cmd-Shift-B (customizable in Settings → Keyboard).
  - Renders as a popover (or sheet) attached to the bell button.
- **Contents:** newest-first, scrollable, capped at 200 entries. The Feed holds two kinds of entry: bell entries (everything below unless noted) and **Reminder** entries, which are styled differently and are described under Reminder.
- **Each entry shows:**
  - Timestamp (relative: "2m ago", absolute on hover).
  - Path: `<Session> › <Pane> › <Tab>`.
  - Message body (OSC 9) or a short preview line if available.
  - An unseen indicator until "Clear all" is invoked. The entry is removed when its Tab is visited (#0556).
- **Click-to-jump (the canonical "bring forward" flow):**
  1. Make the source Window key (`makeKeyAndOrderFront`).
  2. Select the source Session in the Sidebar.
  3. Focus the source Pane in the Session's Split tree.
  4. Activate the source Tab inside that Pane.
  5. Remove the rows of the source Tab (#0556); unseen counters decrement for those still unread.
- **Same flow** is invoked when the user taps a System notification posted by Batty.
- **Lifetime:** in-memory only; does not survive a relaunch.
- **Capture log (opt-in):** Settings → Advanced → Diagnostics → "Capture Bell Feed data" appends each Bell event's raw input and the text shown for it to a local JSON Lines file. Off by default; see `docs/bell-feed-capture.md`.

---

## Reminder

A one-shot timer the user sets on one Session to be brought back to it later. Formally a *Session Reminder*; "Remind Me" is the verb in menus.

- **Setting:** Session menu → Remind Me, the same submenu in the Sidebar row's context menu, the Command Palette, or `batty session remind` (`--in`, or `--tomorrow` at an `--at` time or, without one, the same remembered Tomorrow time; the CLI never changes it). In 5 / 15 / 30 Minutes, In 1 Hour and Tomorrow (at the last time chosen in the sheet, 9:00 AM until one is chosen) set it in one click, with no note. Custom… opens a sheet with a duration (hours and minutes, 1 minute to 7 days), Tomorrow with an editable time that starts at that same remembered time, and an optional note of up to 500 characters. There is no Settings row for the remembered time.
- **One per Session:** setting a Reminder on a Session that has one replaces it. Editing is the same as replacing.
- **Presets are instants, Tomorrow is wall-clock:** a duration resolves once, when set, to an absolute time. Tomorrow keeps the next calendar day's hour and minute and is resolved in the current calendar and time zone each time the scheduler evaluates.
- **Firing:** records an unseen Reminder entry in the Bell Feed and posts a System notification, whether or not the Session is selected or muted. The entry carries the note, or reads "Time to come back to <Session>". It bumps no unseen-bell counter and is never collapsed into another entry. The "Show system notifications" setting still applies to the notification.
- **Acknowledging:** visiting the Session (selecting it, clicking the entry or its notification, or any other visit) removes the entry from the Bell Feed (#0556). Selection that lands on the Session as a fallback, and Clear All, only mark it seen. Clicking selects the Session and leaves its focused Pane and active Tab alone.
- **Sleep and wake:** a Reminder whose time passed while the Mac slept fires once on wake, labelled with the time it was due.
- **Persisted:** the system notification only: a pending Reminder is scheduled with macOS when set, so it still notifies after a quit, relaunch or crash. The Session does not come back; clicking a notification whose Session is gone brings Batty forward and reopens the Project when the Session was Project-backed.

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

*Document version: 0.29 — 2026-11-12. A Project Tab and a runtime Tab can carry their own background, and a Tab's image downloads into a bounded cache on another Mac (#0585). Previously 0.28 — 2026-11-09: a pending Reminder's notification is scheduled with macOS and survives a quit (#0566). Previously 0.27 — 2026-11-05: a muted Session's bells add no Bell Feed entry and no unseen count (#0558). Previously 0.26 — 2026-11-05: visiting a Tab removes its Bell Feed rows, and visiting a Session removes its Reminder rows (#0556). Previously 0.25 — 2026-11-05: adds Reminder (#0514). Previously 0.24 — 2026-11-05: a bell seen at creation while Batty is active adds no Bell Feed entry (#0555). Previously 0.23 — 2026-11-04: a Shared Project's image travels through iCloud Drive, behind a flag (#0551). Previously 0.22 — 2026-11-04: adds Background Images (#0552). Previously 0.21 — 2026-11-03: terminal backgrounds and see-through ship in 1.3.5 with the feature flag removed (#0544). Previously 0.20 — 2026-11-03: a Project can store a terminal background (#0540). Previously 0.19 — 2026-11-03: a Session can carry a background override (#0376). Previously 0.18 — 2026-11-03: adds the see-through window (#0539). Previously 0.17 — 2026-11-03: adds the app-wide Background default (#0375). Previously 0.16 — 2026-11-03: a Pane can carry a background override (#0374). Previously 0.15 — 2026-10-14: Shared Projects sync through iCloud key-value storage (#0503). Previously 0.14 — 2026-10-14: Projects ship in 1.3.0 with the feature flag removed (#0504). Previously 0.13 — 2026-10-13: Projects are shared or local, with a definition / device-state split (#0501). Previously 0.12 — 2026-10-13: the Open Project picker shows open Projects in an Open now strip (#0500). Previously 0.11 — 2026-10-13: a split from a non-terminal Pane inherits a working directory (#0495, port of #0487). Previously 0.10 — 2026-10-13: corrects the Sidebar's "+" button from header/toolbar to footer and adds the footer's Open Project button (#0490). Previously 0.9 — 2026-10-12. Records a Project's last-opened time when it is opened (#0492). Previously 0.8 — 2026-10-12: adds the Project symbol and the Sidebar row's solid circle (#0482). Previously 0.7 — 2026-10-12: documents which shells report OSC 7 and the waiting indicator for startup commands that never run (#0479). Previously 0.6 — 2026-10-12: spells out how Project startup commands are delivered (#0473). Previously 0.5 — 2026-10-12: adds Project (#0470, umbrella #0469). Previously 0.4 — 2026-08-08: corrects five `**Persisted:**` bullets (Window, Session, Pane, Tab, Terminal Session) left over from #0172's Workspace-persistence removal; they described layout persistence that no longer exists. Update whenever a new term gets introduced in the PRD or in issues.*
