# View hierarchy

How Batty's UI is put together. Read this before touching anything in the
terminal / pane / tab / window path. Companion to `Concepts.md` (which
defines the vocabulary) and
[`nsviewrepresentable-state-persistence.md`](nsviewrepresentable-state-persistence.md)
(which justifies the persistent-host pattern). Issues `#0072`, `#0074`,
and `#0075` are the architecture's history.

The view hierarchy is non-trivial because Batty has two intertwined
trees:

1. A **model hierarchy** of value-and-runtime types: Workspace -> Window
   -> Session -> Pane -> Tab -> Terminal Session.
2. An **AppKit/SwiftUI hybrid** that pulls the live terminal `NSView`s
   out of SwiftUI's rebuild churn into a single persistent host.

Anyone touching terminal lifetime, pane composition, or window setup
needs to keep both trees in mind.

---

## 1. The model hierarchy

The canonical containment chain. Defined in `Concepts.md`; this is a
recap with implementation pointers.

```
Workspace                       (write-only persistence; one file)
└── Window                      (singleton NSWindow per #0063)
    └── Session                 (one sidebar entry)
        └── SplitTree           (recursive layout)
            ├── Split node      (direction + ratio; arranges children)
            └── Pane (leaf)     (one visible region)
                └── Tab (×N)    (one TabRuntime per tab chip)
                    └── Terminal Session
                                (one ghostty_surface_t + PTY)
```

Cardinality:

- One `Window`. (Multi-window deferred per `#0063`.)
- Many `Session`s per Window — ordered, persisted, one selected at a time.
- One `SplitTree` per Session, with a `focusedPaneID`.
- A `SplitTree` is a recursive `enum` of split nodes and pane leaves.
- Many `Tab`s per Pane, with an `activeTabID`.
- Exactly one Terminal Session per Tab. Tab and Terminal Session live
  and die together.

Implementation pointers:

| Model concept | Runtime type | File |
|---|---|---|
| Workspace | `WorkspaceManager` | [`../BattyKit/Sources/BattyKit/WorkspaceManager.swift`](../BattyKit/Sources/BattyKit/WorkspaceManager.swift) |
| Window | `BattyApp` `Window` scene | [`../Batty/BattyApp.swift`](../Batty/BattyApp.swift) |
| Session | `SessionRuntime` | [`../BattyKit/Sources/BattyKit/SessionRuntime.swift`](../BattyKit/Sources/BattyKit/SessionRuntime.swift) |
| Split tree | `SplitTree` / `SplitTreeNode` | [`../BattyKit/Sources/BattyKit/SplitTree.swift`](../BattyKit/Sources/BattyKit/SplitTree.swift) |
| Pane | `PaneRuntime` | [`../BattyKit/Sources/BattyKit/PaneRuntime.swift`](../BattyKit/Sources/BattyKit/PaneRuntime.swift) |
| Tab | `TabRuntime` | [`../BattyKit/Sources/BattyKit/TabRuntime.swift`](../BattyKit/Sources/BattyKit/TabRuntime.swift) |
| Terminal Session | `TerminalViewState` + `AppTerminalView` | upstream `GhosttyTerminal`; held by `TabRuntime` |

The model layer is `@Observable` reference types (so SwiftUI can react
to mutations without losing identity), wrapping value types that are
serialized to `workspace.json`. Per CLAUDE.md's architectural rule, the
serialized layout model is pure value types — view types and libghostty
handles never enter persistence.

---

## 2. The SwiftUI view tree

What SwiftUI actually renders, top down.

```
BattyApp (Scene)
└── Window (singular, NOT WindowGroup — see #0063)
    └── ContentView
        └── RootWindowView
            └── NavigationSplitView
                ├── Sidebar column
                │   └── SessionSidebarView
                │       ├── List(store.sessions) — session rows
                │       └── .safeAreaInset(.bottom): "+" button (#0065)
                └── Detail column
                    └── SessionDetailView                                ZStack:
                        ├── TerminalHostInstaller                       (NSViewRepresentable;
                        │                                                returns singleton TerminalHostView)
                        ├── ForEach(store.sessions)
                        │   └── SplitContainerView(tree: session.tree)
                        │       │   .opacity(session.id == selected ? 1 : 0)
                        │       └── SplitNodeView (recursive)
                        │           ├── .split node -> HSplit / VSplit
                        │           │   ├── child A: SplitNodeView
                        │           │   └── child B: SplitNodeView
                        │           └── .leaf  node -> PaneView
                        │               └── VStack
                        │                   ├── SlidingTabBar (chips)
                        │                   └── ZStack
                        │                       └── ForEach(pane.tabs)
                        │                           └── TerminalPlaceholderView
                        │                               .allowsHitTesting(activeTab)
                        │                               .opacity(activeTab ? 1 : 0)
                        └── ContentUnavailableView (when no Session)
```

Key files:

- [`../BattyKit/Sources/BattyKit/RootWindowView.swift`](../BattyKit/Sources/BattyKit/RootWindowView.swift)
- [`../BattyKit/Sources/BattyKit/SessionSidebarView.swift`](../BattyKit/Sources/BattyKit/SessionSidebarView.swift)
- [`../BattyKit/Sources/BattyKit/SessionDetailView.swift`](../BattyKit/Sources/BattyKit/SessionDetailView.swift)
- [`../BattyKit/Sources/BattyKit/SplitContainerView.swift`](../BattyKit/Sources/BattyKit/SplitContainerView.swift)
  (contains both `SplitContainerView` and the private recursive `SplitNodeView`)
- [`../BattyKit/Sources/BattyKit/PaneView.swift`](../BattyKit/Sources/BattyKit/PaneView.swift)
- [`../BattyKit/Sources/BattyKit/TerminalPlaceholderView.swift`](../BattyKit/Sources/BattyKit/TerminalPlaceholderView.swift)
- [`../BattyKit/Sources/BattyKit/TerminalHostInstaller.swift`](../BattyKit/Sources/BattyKit/TerminalHostInstaller.swift)

Notes on the layout:

- Non-selected Sessions stay in the tree at `.opacity(0)` and
  `.allowsHitTesting(false)`. They keep their `SplitContainerView`
  mounted so their placeholders keep reporting frames; the host hides
  the corresponding terminals via `isHidden = true`.
- The placeholder is a `Color.clear` view inside a `GeometryReader`. It
  does **not** host the terminal. It emits geometry through a
  `PreferenceKey` so the host can place the terminal NSView over it.
- The active-tab toggle inside `PaneView` is the *only* selection
  signal SwiftUI emits; the host reads it indirectly via the
  `isVisible` flag in `TerminalPlaceholderView.body`.

---

## 3. The terminal host architecture

The load-bearing section. After `#0072` -> `#0074` -> `#0075` Phase 2,
the terminal NSViews live outside SwiftUI's rebuild path entirely.
`#0236` extended the design to support one host per content window
(see amendments in §§4–6 below and `docs/multi-window-design.md` §3).

```
              SwiftUI                                AppKit
              -------                                ------

         TerminalHostInstaller(windowID: W)
         (NSViewRepresentable)  ------\
                                       \
                                        \
                                         v
                                  TerminalHostStore.shared       (singleton, @MainActor)
                                  --------------------------
                                   .hosts :                             |
                                       [WindowID: TerminalHostView]    | one host per
                                   .terminalViews :                    | content window
                                       [UUID: AppTerminalView]         |
                                   .tabWindowMap :                     | strong ref
                                       [UUID: WindowID]                | from store
                                                                       |
        TerminalPlaceholderView                                        |
        (per-tab; geometry probe)                                      |
            onGeometryChange / onChange(of: isVisible)                 |
              -> TerminalHostStore.shared.setPlacement(_:forTabID:)    |
                                                                       |
                                                                       v
                                                   TerminalHostView (NSView, isFlipped=true)
                                                   — one per content window —
                                                   subviews (one per live TabRuntime in window):
                                                      AppTerminalView (#tab-A) frame, isHidden
                                                      AppTerminalView (#tab-B) frame, isHidden
                                                      AppTerminalView (#tab-C) frame, isHidden
                                                      ...
```

Why this exists. SwiftUI tears down `NSViewRepresentable` hosts on
rebuild — a sidebar collapse, a session selection change, a window
resize that crosses a layout threshold, *anything* can cause the
representable to be dismantled and re-made. Pre-`#0075`, hosting the
`AppTerminalView` directly inside a per-pane `NSViewRepresentable`
meant SwiftUI could (and did) destroy the underlying `ghostty_surface_t`
and kill the shell. The persistent-host design moves ownership of the
`AppTerminalView` from the representable to the store:

- `TerminalHostStore.shared` lives for the lifetime of the process.
- `TerminalHostStore.shared.hostView(forWindowID:)` lazily creates and
  permanently owns one `TerminalHostView` per content `WindowID`.
- `TerminalHostInstaller.makeNSView(context:)` returns that **same
  instance** for the window every call. SwiftUI is free to dismantle and
  remake the representable; the host and every terminal subview survive
  in the store. This is Pattern 3 from
  [`nsviewrepresentable-state-persistence.md`](nsviewrepresentable-state-persistence.md).
- Each `TabRuntime` gets its `AppTerminalView` created lazily in
  `TerminalHostStore.terminalView(for:windowID:)`, added to **that
  window's host** once, and **never reparented** — not even to another
  window's host (amendment 1 in §4 below).
- `TerminalPlaceholderView` reads its `windowID` from the SwiftUI
  environment (set by `SessionDetailView`) and passes it to
  `terminalView(for:windowID:)`. Geometry reporting goes directly to
  `TerminalHostStore.setPlacement(_:forTabID:)` via `onGeometryChange`
  and `onChange(of: isVisible)`.
- Placement updates are scoped per window via
  `updatePlacements(_:forWindowID:)` so one window's preference
  emissions cannot affect another window's terminals (amendment 4 in §4).

This mirrors the **Surface registry** rule in CLAUDE.md: SwiftUI only
ever stores `surfaceID: UUID`, never the C handle; view rebuilds must
not destroy surfaces. Here the same idea is one level up — SwiftUI
stores at most `tab.id`, the host store maps `tab.id` to the live
`AppTerminalView`, and view rebuilds can't touch the NSView.

Key files:

- [`../BattyKit/Sources/BattyKit/Runtime/TerminalHostStore.swift`](../BattyKit/Sources/BattyKit/Runtime/TerminalHostStore.swift)
  — the process-wide host registry; placement mutators are window-scoped.
- [`../BattyKit/Sources/BattyKit/Views/TerminalHostView.swift`](../BattyKit/Sources/BattyKit/Views/TerminalHostView.swift)
  — the persistent container `NSView` (`isFlipped = true` to match
  SwiftUI coordinates).
- [`../BattyKit/Sources/BattyKit/Util/TerminalHostInstaller.swift`](../BattyKit/Sources/BattyKit/Util/TerminalHostInstaller.swift)
  — the `NSViewRepresentable` shim. `makeNSView` returns the per-window
  host; `updateNSView` and `dismantleNSView` are no-ops by design.
- [`../BattyKit/Sources/BattyKit/Views/TerminalPlaceholderView.swift`](../BattyKit/Sources/BattyKit/Views/TerminalPlaceholderView.swift)
  — the geometry probe that drives per-tab placement.

---

## 4. Rules of the road for anyone touching the terminal path

These are non-negotiable. Violating any one of them re-introduces the
class of bugs `#0072`/`#0074`/`#0075` were filed to eliminate.
Amendments 1–4 were added in `#0236` to extend the rules to a
multi-window topology; they do not change single-window behavior.

- **Never call `removeFromSuperview()` on an `AppTerminalView` outside
  the tab-close path.** The only legitimate caller is
  `TerminalHostStore.releaseTerminalView(forTabID:)`, which is invoked
  from `AppStateStore.closeTab(id:)` (for per-tab close) and from the
  window-close cascade (routing through the same per-tab close path for
  every tab in the closing window). If you find yourself reaching for
  `removeFromSuperview()` elsewhere, you are wrong.

- **Never replace the host's `subviews` array.** Treat `host.subviews`
  as append-only-and-individually-removable. Wholesale replacement
  destroys every live PTY.

- **Never recreate a tab's `AppTerminalView` while the `TabRuntime` is
  alive.** `TerminalHostStore.terminalView(for:windowID:)` is idempotent:
  it returns the existing view on every call after the first. If you
  bypass it to build a fresh `AppTerminalView`, the old one stays in
  the host, the new one isn't tracked, and bell/title/focus events
  scatter.

- **`updateNSView` is a no-op (or property mutation only).** The
  `TerminalHostInstaller` ships an explicitly empty `updateNSView`. Do
  not add `addSubview`/`removeFromSuperview` to it. Geometry flows
  through `TerminalHostStore.setPlacement(_:forTabID:)` and
  `updatePlacements(_:forWindowID:)`, not through representable updates.

- **The placeholder is empty by design.** Don't put SwiftUI content
  inside `TerminalPlaceholderView` expecting it to overlay the
  terminal — SwiftUI inside the placeholder draws *behind* the
  terminal because the host is `ZStack`'ed at the SwiftUI level above
  the per-session chrome. Pane overlays (bell flash, focus border)
  live in `PaneView`, not the placeholder.

- **AppKit-on-top means AppKit owns AppKit-level event registration.**
  AppKit's drag-and-drop dispatch (and any other registration-keyed
  event path) walks the deepest NSView at the cursor whose
  `registerForDraggedTypes` includes a matching type. It does **not**
  fall through to a SwiftUI sibling underneath an opaque AppKit
  subview — `hitTest` and drag dispatch use different paths. The host
  and its `AppTerminalView` subviews sit on top of the SwiftUI
  placeholder, so anything that goes through AppKit registration
  (drops, services menu, drag sources, etc.) must be registered on
  `TerminalHostView` itself, not on a SwiftUI `.onDrop` modifier on
  the placeholder. The fix for `#0102` adds `registerForDraggedTypes`
  and the `draggingEntered/performDragOperation` overrides to
  `TerminalHostView` for the file-drop path; future event paths with
  the same shape go in the same place.

**Amendment 1 (`#0236`) — cross-window reparenting is forbidden.**
An `AppTerminalView` is added to exactly one window's `TerminalHostView`
and never moves to another host. The §5 invariant is per-window: once
`view.window` is set to a content `NSWindow`, it stays that window for
the entire lifetime of the `AppTerminalView`. Moving a session between
windows would require reparenting the `AppTerminalView` across hosts,
which is forbidden; see `docs/multi-window-design.md` §10 (out of
scope for v1). `TerminalHostStore.terminalView(for:windowID:)` logs an
error and returns the existing view if called with a mismatched
`windowID` for a tab that's already registered.

**Amendment 2 (`#0236`) — window close routes through the per-tab
close path.**
`releaseTerminalView(forTabID:)` remains the **sole** `removeFromSuperview`
caller. Window close calls `closeTab(id:)` (or its cascade) for every
tab in the window, which invokes `releaseTerminalView`. After all tabs
are released, `releaseHost(forWindowID:)` drops the host entry from the
registry. A host is never torn down while it still contains terminal
subviews — `releaseHost` logs a warning and is a no-op if orphaned
tab entries remain.

**Amendment 3 (`#0236`) — per-window placement maps guard cross-window
churn.**
`updatePlacements(_:forWindowID:)` touches only the terminal views whose
`tabWindowMap[tabID] == windowID`. One window's preference emissions
(from its `TerminalPlaceholderView` subtree) can never hide or resize
another window's terminals.

**Amendment 4 (`#0236`) — window close must not disturb surviving
windows' terminal state.**
When a window closes, its SwiftUI tree unmounts, which may trigger
`onPreferenceChange` or `onGeometryChange` callbacks. These must only
emit into that window's placement scope. The per-window placement
isolation (Amendment 3) is the guard: surviving windows' terminals
are unaffected because the closing window's callbacks are scoped to its
own `windowID`.

These restate the rules from
[`nsviewrepresentable-state-persistence.md`](nsviewrepresentable-state-persistence.md)
in Batty's specific terminology.

---

## 5. Lifecycle of a terminal NSView

A timeline from `TabRuntime.init` through tab close (single window;
multi-window is identical per window, with the `windowID` scoping at
each step).

```
  time
   |
   |  TabRuntime.init
   |    creates TerminalViewState (libghostty model)
   |    terminalNSView = nil
   |    [no AppTerminalView yet; no PTY yet]
   |
   |  First mount of TerminalPlaceholderView for this tab
   |    reads windowID from SwiftUI environment (set by SessionDetailView)
   |    body calls TerminalHostStore.shared.terminalView(for:windowID:)
   |    store lazily creates AppTerminalView
   |    store sets isHidden = true on the new view
   |    store calls hostView(forWindowID:).addSubview(view)
   |    store records terminalViews[tab.id] = view
   |    store records tabWindowMap[tab.id] = windowID
   |    tab.terminalNSView = view
   |    log: "created terminal view for tab <UUID> in window <UUID>"
   |
   |  AppKit walks viewDidMoveToWindow up the new subtree
   |    libghostty observes a non-nil window
   |    PTY spawns, IO/render threads start, display link binds
   |    log (libghostty): "io_exec: started subcommand"
   |    log: "attached host to window"  (first mount for this window only)
   |
   |  Subsequent SwiftUI activity (selection, splits, sidebar toggle,
   |  pane focus change, window resize, NSViewRepresentable churn)
   |    placeholder's onGeometryChange / onChange(of: isVisible)
   |      -> TerminalHostStore.setPlacement(_:forTabID:)
   |    store mutates view.frame and view.isHidden only
   |    viewDidMoveToWindow does NOT fire again
   |    PTY untouched, scrollback untouched, selection untouched
   |
   |  WindowRuntime.closeTab(id:)  [or PaneRuntime.closeOtherTabs /
   |  closePane / removeSession / the window-close cascade — every
   |  close path calls releaseTerminalView directly, making it the
   |  single choke point for surface teardown regardless of entry
   |  point, #0289]
   |    TerminalHostStore.releaseTerminalView(forTabID:)
   |      terminalViews.removeValue(forKey: id)
   |      placements.removeValue(forKey: id)
   |      tabWindowMap.removeValue(forKey: id)
   |      view.controller = nil   (#0289 — see note below)
   |        TerminalSurfaceCoordinator.controller's didSet fires
   |        synchronously -> rebuildIfReady(removingBridgeFrom: old) ->
   |        tearDownSurface -> surface?.free() -> ghostty_surface_free
   |        PTY killed, Metal resources released, retainedBridges balanced
   |        (guarded by TerminalSurface.hasBeenFreed — safe even if no
   |        surface existed yet)
   |      view.removeFromSuperview()
   |        viewDidMoveToWindow(nil) fires synchronously inside libghostty
   |        (stops the display link, drops focus — surface is already
   |        gone by this point)
   |      tab.terminalNSView = nil   (reference hygiene, not a free —
   |        see note below)
   |    log: "released terminal view for tab <UUID>: surface and PTY
   |    freed synchronously"   <- trustworthy: the free above already
   |    happened, synchronously, before this line runs
   |    [half a second later, purely diagnostic — nothing gates on this]
   |      IF something still references the AppTerminalView:
   |        log (debug): "AppTerminalView ... still referenced ..."
   |        (reference hygiene only; the surface is already freed)
   |      IF something still references the TabRuntime:
   |        log (notice): "TabRuntime ... still referenced ..."
   |        (expected transient — SwiftUI can hold a just-closed tab's
   |        TabRuntime for a render pass or two; only sustained/repeated
   |        notices across unrelated closes indicate a real problem)
   |        this is the one that matters for the ghostty APP, not the
   |        surface: TabRuntime.terminal.controller is a second,
   |        independent strong reference to the same TerminalController,
   |        and TerminalController.deinit -> ghostty_app_free only runs
   |        once TabRuntime itself deallocates — unaffected by anything
   |        above, same as before #0289
   |
   |  [Window close only] — after ALL tabs in the window released:
   |    TerminalHostStore.releaseHost(forWindowID:)
   |    hosts.removeValue(forKey: windowID)
   |    log: "released host for window <UUID>"
   |
   v
```

The invariant: between steps 2 and 5, `view.window` is the same
NSWindow for the entire lifetime of the `AppTerminalView`. This is a
per-window invariant: no reparenting across hosts is permitted
(Amendment 1 in §4).

**#0289 correction.** Earlier versions of this document (and of
`releaseTerminalView` itself) treated "released terminal view" as
evidence the surface was freed. It wasn't: that log used to fire as
soon as Batty's own references were dropped, before `AppTerminalView`
necessarily deallocated — and `TerminalSurfaceCoordinator`, which owns
`ghostty_surface_free`, is `internal` to `GhosttyTerminal`, so it looked
like Batty had no way to force that call directly. It does, though:
`AppTerminalView.controller` — the property this store already uses to
attach a view to its tab's `TerminalController` — is `open`, and its
setter forwards to the coordinator's `controller`, whose `didSet` tears
the surface down *before* checking whether the new value is non-nil.
`releaseTerminalView` now sets it to `nil` as part of the close path,
which makes the free genuinely synchronous and deterministic — the
issue's actual ask — rather than a proxy or a wait-and-see log one turn
later. "released terminal view" is now trustworthy for the surface and
PTY specifically, because the free it reports already happened by the
time it's logged.

**What this still doesn't cover: the ghostty app.** `TabRuntime.terminal`
(a `TerminalViewState`) holds its own independent strong reference to
the same `TerminalController` — a second retainer alongside the view's,
not removed by anything above. `TerminalController.deinit` is what
calls `ghostty_app_free`, gated on `TabRuntime` itself deallocating.
Batty creates one `ghostty_app_t` per Tab, owning its own glyph-atlas
cache (`issues/0285/investigation-source.md` — the leading explanation
for the umbrella's IOAccelerator figure), so a SwiftUI reference that
outlives a tab's close (`TerminalPlaceholderView.tab`, a stuck rename
sheet) still defers that free exactly as it always has — #0289 doesn't
change this, and doesn't claim to; #0287 is where a shared-controller
design would close the gap. `tab.terminalNSView = nil` is reference
hygiene (no stale reads of a torn-down view through `TabRuntime`), not
what frees anything — the surface free above happens through the
view's own `controller` property regardless of whether `TabRuntime` is
still around.

---

## 6. Common debugging signals

When something looks wrong, check the log stream in Console.app with
`subsystem == co.sstools.Batty` and these categories. Each line below
is what *normal* looks like.

| Signal | Category | What "good" looks like |
|---|---|---|
| `created terminal view for tab <UUID> in window <UUID>` | `TerminalHostStore` | Fires **exactly once per tab**, at first appearance. |
| `released terminal view for tab <UUID>: surface and PTY freed synchronously` | `TerminalHostStore` | Fires **exactly once per closed tab**, from `releaseTerminalView(forTabID:)` — the single choke point every close path funnels through. **This is now trustworthy for the surface and PTY** (#0289): by the time this logs, `view.controller = nil` has already run `ghostty_surface_free` synchronously. It does **not** confirm the ghostty app was freed — that's a separate, independent chain; see the two diagnostic signals below. |
| `AppTerminalView for tab <UUID> still referenced 0.5s after release` (debug) | `TerminalHostStore` | Diagnostic only, not a teardown problem — the surface and PTY are already gone by the time this could fire. Persistent occurrences across many tabs might be worth a look at reference hygiene, but nothing depends on this clearing. |
| `TabRuntime for tab <UUID> still referenced 0.5s after release` (notice) | `TerminalHostStore` | **A transient, occasional hit is expected**, not a bug — SwiftUI can hold a just-closed tab's `TabRuntime` alive for a render pass or two. This is the signal for the ghostty app (`ghostty_app_t` + its glyph atlas, #0285), which frees only when `TabRuntime` deallocates — independent of the surface, which is already gone. **Repeated notices across multiple, unrelated tab closes** — not one — is the actual leak signal: something is holding a `TabRuntime` reference past its tab's close. |
| `created host for window <UUID>` | `TerminalHostStore` | Fires **once per content window**, when that window's host is first requested. |
| `released host for window <UUID>` | `TerminalHostStore` | Fires **once per content window close**, after all the window's tabs have been released. |
| `attached host to window` | `TerminalHostView` | Fires **once per content window**, when that window's host first lands in the window. More than once **for the same window** means the host is being recreated — the persistence is broken. |
| libghostty `io_exec: started subcommand` | (libghostty internal) | Fires **only on tab create**. Firing during navigation, selection, or resize means a PTY is being respawned — the persistence is broken. |
| `focus skipped: no AppTerminalView matched the requested terminal state` | various | **A brief one at cold launch is expected** (focus runs before the first placeholder mount). Persistent or repeated ones during navigation mean the host attach is broken. |

Quick diagnostic playbook:

- **Terminal is blank after switching session.** The placeholder is
  reporting frames but the host isn't applying them. Check
  `TerminalHostStore.setPlacement(_:forTabID:)` is being called from
  `TerminalPlaceholderView.onGeometryChange`. Check the placement's
  `isVisible` for the active tab.
- **Terminal reappears empty after the sidebar collapse.** The
  representable was torn down and `makeNSView` built a *new* host
  instead of returning the window's existing one. Verify
  `TerminalHostInstaller.makeNSView` returns
  `TerminalHostStore.shared.hostView(forWindowID: windowID)` (not a
  freshly constructed `TerminalHostView(frame: .zero)`).
- **Multiple shell prompts appear when opening a tab.** `terminalView(for:windowID:)`
  was bypassed and a fresh `AppTerminalView` was constructed. The new view
  spawns a new PTY; the old one is still attached. Always go through the
  store.
- **Click in a terminal doesn't focus it / clicks pass through the
  terminal area.** Hit-testing on `TerminalHostView` is custom (see the
  file); a `frame` mismatch between the placeholder and the host's
  subview makes the click miss. Log the `setPlacement` calls and the
  host subview's `frame` for the same tab id and compare.
- **PTY survives after the tab chip is gone.** The PTY belongs to the
  *surface*, not the ghostty app — `ghostty_surface_free` is what kills
  it, and since #0289 that happens synchronously inside
  `releaseTerminalView(forTabID:)` (via `view.controller = nil`), before
  the "released terminal view" log even fires. So first check whether
  `releaseTerminalView(forTabID:)` ran at all (the close path in
  `WindowRuntime` should call it, directly or via `PaneRuntime
  .removeTab` / `.closeOtherTabs`) — if that log is missing, the close
  path didn't reach the store. If it *is* present, the PTY should
  already be dead; a still-running process at that point points
  somewhere other than this teardown path (a second surface for the
  same shell, a process the PTY spawned that outlived it, etc.), not at
  a lingering `TabRuntime` — that only defers the ghostty *app* and its
  glyph atlas, not the PTY.
- **`releaseHost` logs a warning and the host stays.** A tab's
  `releaseTerminalView` wasn't called before `releaseHost`. The window-
  close path must iterate all tabs in the window's sessions and close
  each one before calling `releaseHost`.

---

## Quick answer key for new contributors

- *Where does a tab's NSView live?* — Inside the `TerminalHostView` for
  its window (`TerminalHostStore.shared.hostView(forWindowID: tab's window)`),
  as one of its `subviews`. Created lazily via
  `TerminalHostStore.terminalView(for:windowID:)`. Released by
  `TerminalHostStore.releaseTerminalView(forTabID:)` on `closeTab`.
- *What happens when SwiftUI tears down a `PaneView`?* — Nothing
  destructive to the terminal. The placeholder stops reporting frames;
  the host hides the affected subviews on the next placement update;
  the `AppTerminalView` remains in the host, attached to the window,
  with its PTY running. If the pane re-appears, the placeholder mounts
  again and the host re-shows the view at the new frame.
- *Where do I look if the terminal is blank?* — Three places, in order:
  (1) is `TerminalHostInstaller` returning the same host for this window
  (not a fresh one)? (2) is the placeholder reporting a frame with
  `isVisible == true`? (3) is the host's matching subview unhidden and
  at the reported frame?

---

*Document version: 4 — 2026-08-01. §§3–6 amended in #0236 for
per-window host topology (one TerminalHostView per content window).
§§5–6 corrected in #0289: `releaseTerminalView(forTabID:)` now forces
`ghostty_surface_free` synchronously via `view.controller = nil`
(`AppTerminalView.controller` is `open`, even though the coordinator
that owns the C call is not), so "released terminal view" is
trustworthy evidence the surface and PTY are gone by the time it logs.
The ghostty app is a separate, still-ARC-deferred chain — gated on
`TabRuntime` deallocating, since `TabRuntime.terminal.controller` holds
its own independent reference to the same `TerminalController` — with
its own diagnostic-only, transient-expected notice.*
