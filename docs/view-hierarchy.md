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

```
              SwiftUI                                AppKit
              -------                                ------

         TerminalHostInstaller
         (NSViewRepresentable)  ------\
                                       \
                                        \
                                         v
                                  TerminalHostStore.shared       (singleton, @MainActor)
                                  --------------------------
                                   .hostView : TerminalHostView   <----+
                                   .terminalViews :                    |
                                       [UUID: AppTerminalView]         | strong ref
                                                                       | from store
                                                                       |
        TerminalPlaceholderView                                        |
        (per-tab; geometry probe)                                      |
            preference(TerminalPlacementPreferenceKey)                 |
              [TabID: Placement(frame, isVisible)]                     |
                |                                                      |
                v                                                      |
        SessionDetailView.onPreferenceChange                           |
              -> TerminalHostStore.shared.updatePlacements(_:)         |
                                                                       |
                                                                       v
                                                       TerminalHostView (NSView, isFlipped=true)
                                                       --------------------------------------
                                                       subviews (one per live TabRuntime):
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
`AppTerminalView` from the representable to the singleton:

- `TerminalHostStore.shared` lives for the lifetime of the process.
- `TerminalHostStore.shared.hostView` is a single `TerminalHostView`
  `NSView`, created once.
- `TerminalHostInstaller.makeNSView(context:)` returns that **same
  instance** every call. SwiftUI is free to dismantle and remake the
  representable; the host and every terminal subview survive in the
  store. This is Pattern 3 from
  [`nsviewrepresentable-state-persistence.md`](nsviewrepresentable-state-persistence.md).
- Each `TabRuntime` gets its `AppTerminalView` created lazily in
  `TerminalHostStore.terminalView(for:)`, added to the host **once**,
  and **never reparented**.
- SwiftUI's per-pane `TerminalPlaceholderView` reports its frame in a
  named coordinate space via `TerminalPlacementPreferenceKey`.
  `SessionDetailView` aggregates those frames and forwards them to
  `TerminalHostStore.updatePlacements(_:)`, which translates them into
  `frame` updates and `isHidden` toggles on the matching subviews.

This mirrors the **Surface registry** rule in CLAUDE.md: SwiftUI only
ever stores `surfaceID: UUID`, never the C handle; view rebuilds must
not destroy surfaces. Here the same idea is one level up — SwiftUI
stores at most `tab.id`, the host store maps `tab.id` to the live
`AppTerminalView`, and view rebuilds can't touch the NSView.

Key files:

- [`../BattyKit/Sources/BattyKit/TerminalHostStore.swift`](../BattyKit/Sources/BattyKit/TerminalHostStore.swift)
  — the singleton; the only mutator is `updatePlacements(_:)`.
- [`../BattyKit/Sources/BattyKit/TerminalHostView.swift`](../BattyKit/Sources/BattyKit/TerminalHostView.swift)
  — the persistent container `NSView` (`isFlipped = true` to match
  SwiftUI coordinates).
- [`../BattyKit/Sources/BattyKit/TerminalHostInstaller.swift`](../BattyKit/Sources/BattyKit/TerminalHostInstaller.swift)
  — the `NSViewRepresentable` shim. `makeNSView` returns the singleton;
  `updateNSView` and `dismantleNSView` are no-ops by design.
- [`../BattyKit/Sources/BattyKit/TerminalPlaceholderView.swift`](../BattyKit/Sources/BattyKit/TerminalPlaceholderView.swift)
  — the geometry probe + `PreferenceKey` that drives placement.

---

## 4. Rules of the road for anyone touching the terminal path

These are non-negotiable. Violating any one of them re-introduces the
class of bugs `#0072`/`#0074`/`#0075` were filed to eliminate.

- **Never call `removeFromSuperview()` on an `AppTerminalView` outside
  the tab-close path.** The only legitimate caller is
  `TerminalHostStore.releaseTerminalView(forTabID:)`, which itself is
  only invoked from `AppStateStore.closeTab(id:)`. If you find yourself
  reaching for `removeFromSuperview()` elsewhere, you are wrong.

- **Never replace the host's `subviews` array.** Treat `host.subviews`
  as append-only-and-individually-removable. Wholesale replacement
  destroys every live PTY.

- **Never recreate a tab's `AppTerminalView` while the `TabRuntime` is
  alive.** `TerminalHostStore.terminalView(for:)` is idempotent: it
  returns the existing view on every call after the first. If you
  bypass it to build a fresh `AppTerminalView`, the old one stays in
  the host, the new one isn't tracked, and bell/title/focus events
  scatter.

- **`updateNSView` is a no-op (or property mutation only).** The
  `TerminalHostInstaller` ships an explicitly empty `updateNSView`. Do
  not add `addSubview`/`removeFromSuperview` to it. Geometry flows
  through `TerminalHostStore.updatePlacements(_:)`, not through
  representable updates.

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

These restate the rules from
[`nsviewrepresentable-state-persistence.md`](nsviewrepresentable-state-persistence.md)
in Batty's specific terminology.

---

## 5. Lifecycle of a terminal NSView

A timeline from `TabRuntime.init` through tab close.

```
  time
   |
   |  TabRuntime.init
   |    creates TerminalViewState (libghostty model)
   |    terminalNSView = nil
   |    [no AppTerminalView yet; no PTY yet]
   |
   |  First mount of TerminalPlaceholderView for this tab
   |    body calls TerminalHostStore.shared.terminalView(for:)
   |    store lazily creates AppTerminalView
   |    store sets isHidden = true on the new view
   |    store calls host.addSubview(view)
   |    store records terminalViews[tab.id] = view
   |    tab.terminalNSView = view
   |    log: "created terminal view for tab <UUID>"
   |
   |  AppKit walks viewDidMoveToWindow up the new subtree
   |    libghostty observes a non-nil window
   |    PTY spawns, IO/render threads start, display link binds
   |    log (libghostty): "io_exec: started subcommand"
   |    log: "attached host to window"  (first mount only)
   |
   |  Subsequent SwiftUI activity (selection, splits, sidebar toggle,
   |  pane focus change, window resize, NSViewRepresentable churn)
   |    placeholder reports a new frame via PreferenceKey
   |    SessionDetailView.onPreferenceChange
   |      -> TerminalHostStore.updatePlacements(_:)
   |    store mutates view.frame and view.isHidden only
   |    viewDidMoveToWindow does NOT fire again
   |    PTY untouched, scrollback untouched, selection untouched
   |
   |  AppStateStore.closeTab(id:)
   |    TerminalHostStore.releaseTerminalView(forTabID:)
   |      terminalViews.removeValue(forKey: id)
   |      placements.removeValue(forKey: id)
   |      view.removeFromSuperview()
   |    viewDidMoveToWindow(nil) fires inside libghostty
   |    surface coordinator deinit -> ghostty_surface_free
   |    PTY killed, Metal resources released
   |    log: "released terminal view for tab <UUID>"
   |
   v
```

The invariant: between steps 2 and 5, `view.window` is the same
NSWindow for the entire lifetime of the `AppTerminalView`. Any other
behavior is a bug.

---

## 6. Common debugging signals

When something looks wrong, check the log stream in Console.app with
`subsystem == co.sstools.Batty` and these categories. Each line below
is what *normal* looks like.

| Signal | Category | What "good" looks like |
|---|---|---|
| `created terminal view for tab <UUID>` | `TerminalHostStore` | Fires **exactly once per tab**, at first appearance. |
| `released terminal view for tab <UUID>` | `TerminalHostStore` | Fires **exactly once per closed tab**, at `closeTab(id:)`. |
| `attached host to window` | `TerminalHostView` | Fires **once at app launch**. More than once means the singleton is being recreated — the persistence is broken. |
| libghostty `io_exec: started subcommand` | (libghostty internal) | Fires **only on tab create**. Firing during navigation, selection, or resize means a PTY is being respawned — the persistence is broken. |
| `focus skipped: no AppTerminalView matched the requested terminal state` | various | **A brief one at cold launch is expected** (focus runs before the first placeholder mount). Persistent or repeated ones during navigation mean the host attach is broken. |

Quick diagnostic playbook:

- **Terminal is blank after switching session.** The placeholder is
  reporting frames but the host isn't applying them. Check
  `TerminalHostStore.updatePlacements(_:)` is being called from
  `SessionDetailView.onPreferenceChange`. Check the placement's
  `isVisible` for the active tab.
- **Terminal reappears empty after the sidebar collapse.** The
  representable was torn down and `makeNSView` built a *new* host
  instead of returning the singleton. Verify
  `TerminalHostInstaller.makeNSView` returns
  `TerminalHostStore.shared.hostView` (not `TerminalHostView(frame: .zero)`).
- **Multiple shell prompts appear when opening a tab.** `terminalView(for:)`
  was bypassed and a fresh `AppTerminalView` was constructed. The new view
  spawns a new PTY; the old one is still attached. Always go through the
  store.
- **Click in a terminal doesn't focus it / clicks pass through the
  terminal area.** Hit-testing on `TerminalHostView` is custom (see the
  file); a `frame` mismatch between the placeholder and the host's
  subview makes the click miss. Log the preference-key payload and the
  host subview's `frame` for the same tab id and compare.
- **PTY survives after the tab chip is gone.** The `closeTab` path
  didn't call `releaseTerminalView(forTabID:)`. Check the close path
  in `AppStateStore`.

---

## Quick answer key for new contributors

- *Where does a tab's NSView live?* — Inside `TerminalHostStore.shared.hostView`,
  as one of its `subviews`. Created lazily in
  `TerminalHostStore.terminalView(for:)`. Released by
  `TerminalHostStore.releaseTerminalView(forTabID:)` on `closeTab`.
- *What happens when SwiftUI tears down a `PaneView`?* — Nothing
  destructive to the terminal. The placeholder stops reporting frames;
  the host hides the affected subviews on the next placement update;
  the `AppTerminalView` remains in the host, attached to the window,
  with its PTY running. If the pane re-appears, the placeholder mounts
  again and the host re-shows the view at the new frame.
- *Where do I look if the terminal is blank?* — Three places, in order:
  (1) is `TerminalHostInstaller` returning the singleton? (2) is the
  placeholder reporting a frame with `isVisible == true`? (3) is the
  host's matching subview unhidden and at the reported frame?

---

*Document version: 1 — 2026-05-12.*
