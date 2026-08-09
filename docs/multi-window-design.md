# Multi-window design

Design source for the `#0234` umbrella (multi-window support with a
Shift-Cmd-N New Window action). The implementation children `#0235`–`#0240`
are built from this document; when a child and this document disagree, fix
the disagreement here first. Companion to
[`view-hierarchy.md`](view-hierarchy.md) (terminal-host architecture and its
non-negotiable rules), [`swiftui-observation-rules.md`](swiftui-observation-rules.md)
(binding for every focus/selection change in this work), and
[`terminal-pane-requirements.md`](terminal-pane-requirements.md) (the per-pane
behavior checklist that must pass in every window).

---

## 1. Current state, and one correction to the #0234 audit

What exists today (audited against the code, 2026-06-11):

- **Scene:** `Batty/BattyApp.swift` declares a singular
  `Window(mainWindowTitle, id: "main")` scene plus a `Window("Batty Help",
  id: "help")` scene and a `Settings` scene. No second content window can
  exist.
- **State:** `AppStateStore.shared`
  (`BattyKit/Sources/BattyKit/Runtime/AppStateStore.swift`) is a singleton
  holding the one `sessions: [SessionRuntime]` list, the one
  `selectedSessionID`, the close cascade (`closeTab(id:)`,
  `removeSession(id:)`), bell routing, and `pendingCloseRequest`.
- **Terminal host:** `TerminalHostStore.shared`
  (`Runtime/TerminalHostStore.swift`) owns exactly one persistent
  `TerminalHostView` (`Views/TerminalHostView.swift`), installed into the one
  window by `TerminalHostInstaller` (`Util/TerminalHostInstaller.swift`,
  Pattern 3 from `nsviewrepresentable-state-persistence.md`).
- **Sidebar visibility:** a single app-wide `UserDefaults` key
  (`SidebarPreference.hiddenKey`, read via `@AppStorage` in
  `Views/RootWindowView.swift` and toggled by `BattyShortcuts`).
- **Shortcut routing:** `BattyShortcuts.handle(_:)`
  (`Commands/BattyShortcuts.swift`) is an app-global NSEvent monitor that
  gates on `mainWindowIsKey()` — a heuristic that matches the window whose
  identifier contains `"main"` or whose title is `"Batty"` — and then
  dispatches every action against `AppStateStore.shared`.
- **Bell feed:** `BellFeedEntry` already carries a `windowID: UUID` field,
  but `AppStateStore.recordBellTick(forTabID:surfaceID:windowID:)` defaults
  it to a throwaway `UUID()` — it is schema headroom, not live routing.
- **Lifecycle:** `BattyAppDelegate` terminates the app from
  `AppStateStore.onAllSessionsClosed` when the last session closes, and
  `applicationShouldTerminate` runs `QuitConfirmation.shouldQuitOrPrompt`.

**Correction to the #0234 Long Description.** The audit describes a live
`WorkspaceManager` / `WindowState` persistence schema ("`windows:
[WindowState]` exists; only `windows[0]` is used"). That schema existed
historically (#0029 defined it, #0030 wired it) but **`#0172` deleted
workspace persistence entirely** — `Workspace.swift`,
`WorkspaceConversion.swift`, `WorkspaceManager.swift`, and
`WorkspaceStore.swift` are gone, and #0172 records the decision as
"never a planned feature and will never be one." Today nothing persists
sessions, panes, or tabs: every launch constructs a fresh `Session 1` in
`AppStateStore.init`, and window frame restoration is whatever the system
provides for the `Window` scene. Phase 5 (`#0238`) is therefore scoped to
**window-set restoration** (how many windows, where, with what per-window UI
state), not workspace files. There are no single-window workspace files in
the field to migrate.

---

## 2. Decision: session ownership is partitioned

**A Session lives in exactly one window.** Windows do not share session
lists; the sidebar of window A never shows a session owned by window B.

Rationale:

- `Concepts.md` (Window): "Each Window is independent — its own Sidebar list
  of Sessions, its own selected Session." PRD §6.6: "windows do not share
  session lists." Both documents have always specified partitioned.
- The historical persistence schema (#0029) nested `sessions` *under*
  `WindowState` — the same partitioned shape — and the runtime conversion
  in #0030 mapped one `WindowState` to one `AppStateStore`.
- Terminal multiplexer convention (iTerm2, Terminal.app, tmux clients):
  a window owns its tabs/sessions; nothing renders in two windows at once.
- The terminal-host architecture makes shared ownership actively dangerous:
  an `AppTerminalView` is an `NSView` and can live in only one window. A
  "shared" session selected in two windows would require either reparenting
  terminals between hosts on every selection change (forbidden — see
  [`view-hierarchy.md`](view-hierarchy.md) §4, "never reparented") or two
  views per surface (libghostty has one render target per surface).

Trade-offs accepted: a session cannot appear in two windows, and moving a
session between windows is **not** in v1 scope (see §10) — it would require
reparenting an `AppTerminalView` across hosts, which violates the standing
host rules and needs its own design if ever wanted. Cmd-1..9 selects
among the *key window's* sessions only.

Consequences for naming: `Session N` default numbering and the
`AppStateStore.addSession` index math become per-window. The
`SessionNameCache` stays global (it is keyed by cwd, not by window).

---

## 3. Decision: one `TerminalHostView` per window

`TerminalHostStore` stays a process-wide singleton but becomes a registry of
**one host view per content window**, exactly as anticipated by its own
doc comment ("if multi-window lands later, this becomes one store per window
keyed by the window identifier" — `Runtime/TerminalHostStore.swift`).

Shape:

- `TerminalHostStore.shared.hostView(forWindowID:)` lazily creates and
  permanently owns one `TerminalHostView` per window ID. The existing
  single `hostView` property is replaced by this map in `#0236`.
- `TerminalHostInstaller` gains a `windowID` parameter; `makeNSView` returns
  the host for *that* window. `updateNSView` / `dismantleNSView` stay
  no-ops — the per-window host survives representable churn exactly as the
  singleton host does today.
- `terminalViews: [UUID: AppTerminalView]` (tab ID → view) stays a single
  map: sessions are partitioned, so each tab belongs to exactly one window
  and its view is added once to that window's host. The store records which
  window each tab's view was installed into; placement updates
  (`updatePlacements(_:)` / `setPlacement(_:forTabID:)`) flow per window so
  one window's preference emissions cannot hide another window's terminals.
- The `TerminalPlaceholderView` → `PaneFramePreferenceKey` →
  `SessionDetailView.onPreferenceChange` → `updatePlacements` pipeline is
  unchanged in shape; it is simply instantiated once per window (every
  window has its own `RootWindowView` / `SessionDetailView`).

Host lifecycle mapped to window lifecycle:

- **Create:** lazily, the first time the window's `TerminalHostInstaller`
  asks for it (mirrors today's lazy `AppTerminalView` creation).
- **Window closes:** the close flow first resolves the window's live
  sessions (below), calls `releaseTerminalView(forTabID:)` for every tab in
  the window — the only sanctioned teardown path, unchanged — and then drops
  the host view from the registry. A host is never torn down while it still
  contains terminal subviews.
- **Surfaces on window close: confirm, then tear down.** Recommended over
  *block* (hostile: the red close button must work) and over *migrate*
  (requires cross-window reparenting, forbidden by the host rules). Closing
  a window is closing its sessions — the same semantics as quitting, scoped
  to one window. The confirmation reuses the existing pattern: prompt iff
  any tab in the window reports `terminal.needsConfirmClose`, honoring the
  same "Confirm on close with running processes" setting that
  `QuitConfirmation.shouldQuitOrPrompt` honors. Implementation hangs off
  `NSWindowDelegate.windowShouldClose` (an event-origin AppKit callback —
  a legitimate writer per the observation rules).

How the `view-hierarchy.md` §4 rules extend to multiple hosts (these
amendments land in that doc during `#0236`):

1. *"Never reparented"* gains a cross-window clause: an `AppTerminalView`
   is added to exactly one window's host and **never moves to another
   host**. The §5 invariant becomes "`view.window` is the same `NSWindow`
   for the entire lifetime of the `AppTerminalView`" — per window, which is
   the invariant already written there; multi-window does not weaken it.
2. *"`attached host to window` fires once at app launch"* (§6 debugging
   table) becomes "fires once **per content window**, when that window's
   host first lands in the window." More than once per window still means
   the persistence is broken.
3. `releaseTerminalView(forTabID:)` remains the only `removeFromSuperview`
   caller, now also invoked by the window-close cascade (which routes
   through the same per-tab close path `AppStateStore.closeTab(id:)` uses).
4. Window close is a new rebuild trigger for the *other* windows' SwiftUI
   trees (menus, focused values). It must not produce placement updates
   that hide or destroy surviving windows' terminals — per-window placement
   maps (above) are the guard.

---

## 4. Decision: `WindowGroup(for: WindowID.self)` scene

The content scene becomes a **data-driven `WindowGroup`** presenting a
stable per-window identity value; the singular `Window(id: "main")` scene
(deliberate in the single-window era, #0063) is retired in `#0237`.

Why `WindowGroup` and not programmatic `Window` scenes: SwiftUI `Window`
scenes are static — one declared scene is one window, and N windows would
need N declarations known at compile time. Only `WindowGroup` instantiates
an open-ended number of windows, gives each its own scene storage, and
participates in macOS state restoration for the whole set.

Binding scene identity to state:

- `WindowGroup(for: WindowID.self) { $windowID in ContentView(windowID:) }`
  where `WindowID` is a small `Codable & Hashable` wrapper around a `UUID`
  (a distinct type so the presented-value namespace can never collide with
  another `openWindow(value:)` call site).
- The presented value **is** the stable window ID: it links the scene to
  its `WindowRuntime` (§5), to the per-window host (§3), and to scene
  restoration (§6). `AppStateStore.windowRuntime(for:)` creates the runtime
  lazily on first sight of an ID, so launch, New Window, and restoration
  all converge on one code path.
- The default (first-launch) window uses the `defaultValue:` variant so a
  cold start presents exactly one window — preserving today's behavior.
- New Window mints a fresh `UUID` and calls `openWindow(value:)`; reusing
  an existing value would surface the existing window instead (this is the
  `WindowGroup(for:)` contract, and it is the behavior we want for
  bell-feed jumps, §8).
- `Window("Batty Help", id: "help")` and the `Settings` scene are
  unchanged.

Restoration of N windows on multiple displays: `WindowGroup` encodes each
window's presented value and frame into the system's window-restoration
state. On relaunch macOS reopens every window, on its original display
when that display is present, re-presenting each `WindowID` — which
re-materializes per-window state through the same lazy
`windowRuntime(for:)` path. See §6 for what that state contains.

Knock-on change: `BattyShortcuts.mainWindowIsKey()`'s heuristic
(`identifier contains "main"`) breaks under `WindowGroup`, whose scene
identifiers differ per window. It is replaced by a positive registry check:
a content window is one registered in the NSWindow ↔ `WindowID` map (§5).
This is *more* robust than the current title fallback and removes the
`key.title == "Batty"` string match.

---

## 5. The per-window state model

A new `@Observable` runtime type, **`WindowRuntime`**
(`BattyKit/Sources/BattyKit/Runtime/WindowRuntime.swift`), following the
`SessionRuntime` / `PaneRuntime` / `TabRuntime` naming family. Introduced in
`#0235` with exactly one instance and zero behavior change.

Moves from `AppStateStore` into `WindowRuntime` (per-window):

| State / behavior | Today | Becomes |
|---|---|---|
| `sessions: [SessionRuntime]` | one global list | owned per window |
| `selectedSessionID` / `selectedSession` | global | per window |
| Session CRUD: `addSession`, `removeSession`, `renameSession`, `duplicateSession`, `moveSessions`, `selectSession(at:)` | global | per window (operate on the window's list) |
| `closeTab(id:)` cascade, `closeFocusedTab`, `pendingCloseRequest` + confirm/cancel | global | per window |
| `focusPane(id:)` / `focusPane(containingTabID:)` | global | per window |
| Sidebar visibility | one `UserDefaults` key (`SidebarPreference.hiddenKey`) | per-window observed property (persisted per scene, §6) |
| `onAllSessionsClosed` | terminates the app | closes the window (§8) |

Stays global on `AppStateStore` (now an app-level registry +
cross-cutting services):

- `windows: [WindowRuntime]` and `windowRuntime(for: WindowID)`.
- The NSWindow ↔ `WindowID` map and the derived "key content window"
  accessor. The map itself is `@ObservationIgnored` bookkeeping (it is
  populated from AppKit window callbacks; making it observed state written
  from window machinery is exactly the #0229 hazard class).
- Bell routing: `recordBellTick`, `recordDesktopNotification`,
  `markBellSeen`, `markAllBellsSeen`, `jumpToBellEntry` — these search
  across windows (`locate(tabID:)` iterates `windows × sessions`, and its
  `isFocused` test additionally requires the owning window to be the key
  content window).
- `bellFeed: BellFeedStore`, `nameCache: SessionNameCache`,
  `themeChrome` / theme selection, the AI-naming machinery
  (`nameSuggester`, memo, in-flight tasks — keyed by session/path, not
  window), and `notifier`.
- Process-wide infrastructure unchanged: `SurfaceRegistry`,
  `TerminalHostStore` (as the multi-host registry, §3),
  `ShortcutsStore.shared`, `SettingsPreference`.

Window identification: one `WindowID` (UUID) per window is the single
identity linking **scene** (the `WindowGroup` presented value, §4) ↔
**state** (`WindowRuntime.id`) ↔ **restoration** (the value the system
re-presents, §6) ↔ **host** (`TerminalHostStore` key, §3) ↔ **bell feed**
(`BellFeedEntry.windowID`, §8). The NSWindow ↔ `WindowID` association is
established by a window-accessor representable in `RootWindowView` (the
`WindowChromeApplier` in `Views/RootWindowView.swift` is the existing
precedent for reaching the hosting `NSWindow`), deferred out of the update
pass and stored as `@ObservationIgnored` bookkeeping.

Focus routing: `BattyShortcuts.run(_:store:)` re-targets from
`AppStateStore.shared` to *the key window's* `WindowRuntime`; the
`Cmd-1..9` / `Cmd-Option-1..9` positional dispatch does the same. Menu
commands in `Commands/BattyCommands.swift` resolve their target the same
way. **Every change in this area re-reads
[`swiftui-observation-rules.md`](swiftui-observation-rules.md) first**:
window key/main transitions run inside AppKit responder machinery; writes
to observed selection/focus state triggered by *window-origin* flips must
have a designed owner (event handler or delegate callback), never a
layout-path hop, and never a `Task` "fix."

---

## 6. Persistence and restoration (`#0238` scope)

There is no workspace file (§1), and this design does not reintroduce one.
"Persistence" for multi-window means restoring the **window set**, matching
what a fresh launch would build per window:

- **Window count, frames, displays, zoom:** delegated entirely to macOS
  window restoration via the `WindowGroup` scene (§4). No Batty code stores
  frames. When a restored window's display is gone, macOS places the window
  on a remaining display — system behavior, deliberately not overridden.
- **Per-window UI state that survives relaunch:** sidebar visibility moves
  from the single `SidebarPreference.hiddenKey` default to per-scene
  storage (`@SceneStorage`, which the system saves and restores with the
  window). Migration: the first window seeds its initial value from the
  legacy global key, so an existing user who hid the sidebar still gets a
  hidden sidebar after updating; the legacy key remains as the seed/default
  and the `toggleSidebar` shortcut flips the key window's state instead of
  the global default.
- **Window contents:** each restored window builds the same thing a new
  window builds — one fresh session (cwd = `$HOME`; the `SessionNameCache`
  may still auto-name it once a shell reports a known cwd). Sessions,
  panes, tabs, and shells are *not* restored; that is the standing #0172
  decision, unchanged by multi-window.
- **Single-window users:** behavior is identical to today — one window
  reopens at its old frame with a fresh `Session 1`. There are no
  single-window workspace files to migrate (none exist; #0172).

Termination interplay: quitting saves nothing beyond what the system
captures for restoration plus `nameCache.save()` (already in
`BattyAppDelegate.applicationShouldTerminate`).

---

## 7. The New Window action (`#0237`)

- **`ShortcutAction.newWindow`** is appended to the enum in
  `Shortcuts/ShortcutAction.swift` (the rawValue namespace is append-only —
  see the header comment there), with
  `defaultBinding = ShortcutBinding(key: "n", modifiers: [.command, .shift])`.
  **Shift-Cmd-N is verified free:** the only `n` binding today is Cmd-N →
  `.newSession`'s `defaultBinding`, and `toggleBellFeed`'s `defaultBinding`
  is Shift-Cmd-B. The #0063 Gotchas note claiming
  Shift-Cmd-N was taken is stale. Adding the case makes the chord
  automatically rebindable in Settings → Keyboard via `ShortcutsStore`.
- **Menu placement:** File menu, in the existing
  `CommandGroup(replacing: .newItem)` in `Commands/BattyCommands.swift` —
  "New Window" (Shift-Cmd-N) listed above "New Session" (Cmd-N), matching
  the macOS File-menu convention of window-creation first.
- **Dispatch path:** menu items can call
  `@Environment(\.openWindow)` directly. The NSEvent-monitor path
  (`BattyShortcuts`) has no environment; the scene layer hands
  `AppStateStore` an `@ObservationIgnored` open-window hook (captured
  `OpenWindowAction`), the same wiring style as
  `onAllSessionsClosed` / `nameSuggester` in `BattyAppDelegate`. Unlike the
  `NotificationCenter` toggles (`.battyToggleBellFeed` etc., which are
  observed per-window), opening a window must have exactly one executor.
- **What a new window contains:** one fresh session — `Session 1` *in that
  window's numbering* — with its shell in `$HOME`. Cross-window cwd
  inheritance is deliberately *not* attempted: `Concepts.md`'s CWD
  inheritance rule keys off the previously-focused pane *in the same
  sidebar*, and a brand-new window has none ("falls back to the shell's
  default (`$HOME`) when no previously-selected Session exists").
- The new window becomes key; focus lands in its single tab through the
  normal first-mount focus path.

---

## 8. App lifecycle and cross-window behaviors (`#0239`)

**Termination: the app terminates when the last content window closes.**
This is today's "terminate when the last session closes" generalized one
level up the containment chain:

- Closing the last session *in a window* closes that window
  (`WindowRuntime.onAllSessionsClosed` → close the window; today's
  `AppStateStore.onAllSessionsClosed` → `NSApp.terminate` becomes this).
- Closing the last *content window* terminates the app (Help, Settings,
  and panels do not count; the registry from §5 defines "content window").
  With one window this composes to exactly the current behavior, so the
  single-window UI tests around quit (#0217 lineage) stay green.
- `QuitConfirmation.shouldQuitOrPrompt` (Cmd-Q path) already walks
  `store.sessions` for busy tabs; it widens to all windows' sessions.

**Window close with live sessions:** confirm-then-teardown per §3, gated by
the same "Confirm on close with running processes" setting. Cancel leaves
the window untouched.

**Bell-feed click-to-jump across windows:** `BellFeedEntry.windowID` starts
carrying the real owning window's ID (today's throwaway `UUID()` default in
`recordBellTick` / `recordDesktopNotification` is retired).
`AppStateStore.jumpToBellEntry(_:)` resolves the entry's window first, makes
that window key and front, then performs today's selection flow
(`selectedSessionID` → `focusedPaneID` → `activeTabID`) on *that* window's
runtime — this is precisely the canonical flow `Concepts.md` § Bell Feed
already specifies ("Make the source Window key (`makeKeyAndOrderFront`)…").
Two constraints, both binding:

- `makeKeyAndOrderFront` is a responder-changing AppKit call. It is legal
  from the bell-feed click / notification-tap handlers (event origin) and
  **must never** run synchronously from view-update code
  (`swiftui-observation-rules.md`, AppKit-interop section).
- The dead-window case (entry's window closed since the bell) falls back to
  no-op plus marking the entry seen — bell-state cleanup on window close
  reuses `cleanUpBellState(forTabIDs:)` exactly as `removeSession` does.

System notification taps route through the same jump, unchanged
(`Views/RootWindowView.swift` `setUpNotifier`).

`markActiveTabSeen` and `locate(tabID:)`'s `isFocused` computation gain the
key-window term (§5) so a bell in window B while window A is key correctly
counts as unseen.

---

## 9. Regression-risk register

Each child must respect these — they exist because this work crosses the
riskiest paths in the app (#0072/#0074/#0075 terminal lifetime,
#0227/#0229/#0230 observation, #0143 pane input).

| Phase / child | Primary risks | Binding docs / tests it must respect |
|---|---|---|
| `#0235` per-window state container | Moving `selectedSessionID` / focus flow re-plumbs every selection write; equal-value `@Observable` writes re-invalidate (#0229 lineage); silent behavior drift | [`swiftui-observation-rules.md`](swiftui-observation-rules.md) (binding, re-read first); zero-behavior-change gate: full `BattyKitTests` + full UI suite green with **no test edits** |
| `#0236` window-aware terminal host | Surface destruction on host churn; placement cross-talk between windows; `attached host to window` firing more than once per window | [`view-hierarchy.md`](view-hierarchy.md) §§3–6 (extend the doc in the same change); [`nsviewrepresentable-state-persistence.md`](nsviewrepresentable-state-persistence.md); [`terminal-pane-requirements.md`](terminal-pane-requirements.md) checklist |
| `#0237` New Window action + scene | `WindowGroup` migration breaks `mainWindowIsKey()` and window-restoration identity; shortcut collisions; menu routing | [`shortcuts.md`](shortcuts.md); `ShortcutAction` rawValue append-only rule; UI tests for the new action + existing shortcut suite |
| `#0238` restoration | Restored windows must rebuild state through the same lazy path as New Window; legacy sidebar key migration; missing-display fallback | §6 of this doc; [`ui-features.md`](ui-features.md) (sidebar toggle section); relaunch-shaped UI tests |
| `#0239` cross-window behaviors | `makeKeyAndOrderFront` from a wrong context (observation rules); termination regressions (#0217 lineage); bell `isFocused` mis-keyed | [`swiftui-observation-rules.md`](swiftui-observation-rules.md); [`notifications.md`](notifications.md); quit/close UI tests |
| `#0240` regression pass | Anything the per-phase runs missed; cross-window focus/IME/drop interactions | Full `BattyUITests` on the Mac mini; the manual [`terminal-pane-requirements.md`](terminal-pane-requirements.md) §6 checklist executed **in every window**; `docs/view-hierarchy.md` §6 log-signal audit per window |

Standing global rules for every phase: CLAUDE.md's surface-registry rule
(view rebuilds — now including window open/close/restore — must never
destroy surfaces), and the two-commit issue workflow from
`issues/Issues.md`.

---

## 10. Out of scope (v1 multi-window)

- **Moving sessions between windows.** Requires reparenting an
  `AppTerminalView` across hosts, which the host rules forbid; if ever
  wanted, it is a separate design + child (the #0234 umbrella marks it
  optional).
- **Session/layout persistence across launches.** Removed by #0172;
  multi-window does not reopen that decision.
- **Per-window themes.** Theme stays app-wide (`Concepts.md` § Theme).
- **Per-window settings or shortcut bindings.** `ShortcutsStore` and
  Settings remain global.

---

*Document version: 1 — 2026-06-11. Written as Phase 1 of #0234.*
