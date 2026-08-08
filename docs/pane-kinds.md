# Pane kinds

Design proposal for letting a Pane host content other than a Terminal
Session. This document is the deliverable of `#0302` (child of the `#0301`
umbrella) — it settles the six questions `#0302`'s "Expected behavior"
lists, so `#0303` (lifecycle), `#0304`/`#0305`/`#0313`/`#0314` (the concrete
views), and `#0315` (CLI verbs) can build on a fixed abstraction instead of
re-deriving it. **No code changes ship with this document.** Read
`docs/view-hierarchy.md`, `docs/terminal-pane-requirements.md`, and
`docs/swiftui-observation-rules.md` first — they are binding for any future
work on this path, and this proposal is written to respect them, not to
relax them.

Every source citation below was re-verified against the tree on
2026-08-07/08 while writing this document (branch `issue/0302`). Where a
citation in `#0302`'s own text turned out to still be accurate, that's
noted; the one substantive premise that needed resolving — the
`workspace.json` / `WorkspaceManager.swift` inconsistency — is resolved in
§4 and §7.

---

## 1. Where kind lives: on the Pane, not the Tab

**Decision: kind is a property of `PaneRuntime` (and, on the Codable side,
of `Pane`). A pane is either a Terminal pane (unchanged today's behavior,
with its Tab bar and N terminal Tabs) or a single-kind non-terminal pane
that has no Tab bar and no `TabRuntime`s at all.**

### Why not kind-on-Tab

The umbrella's own framing raises this as the live alternative: "a Git
Status tab could sit alongside terminal tabs in one Pane." Rejected, for
reasons that are structural, not aesthetic:

- **`TabRuntime.terminal` is `public let terminal: TerminalViewState`**
  (`BattyKit/Sources/BattyKit/Runtime/TabRuntime.swift:12`), constructed
  unconditionally inside `init` (`TabRuntime.swift:117`,
  `let state = TerminalViewState(theme: Self.activeTheme())`). Making a Tab
  optionally non-terminal means either (a) making `terminal` optional,
  which pushes an `if let` through every one of the ~15 call sites that
  read `tab.terminal.*` today (bell counters, pwd sync, focus, theme
  application, title formatting, XPC topology serialization), or (b)
  constructing a `TerminalViewState` — a live libghostty view-state object
  — for a Tab that will never render a terminal, just to satisfy the
  non-optional property. Both are worse than not having the problem.
- **The Tab bar (`SlidingTabBar`) is a fundamentally *terminal-session*
  affordance**: `hasUnseen` maps to bell state, `onReorderCommit` persists
  tab order, and `PaneView`'s chip title resolution
  (`TabTitleFormatter.chipTitle`) walks `tab.terminal.title` →
  `tab.workingDirectory` → override. None of that exists for a Git Status
  view. Kind-on-Tab would need a second, parallel chip-rendering and
  title-resolution path inside the *same* `SlidingTabBar`, conditionally
  skipping terminal-only fields per chip — more branching than kind-on-Pane
  produces, for a feature (mixing a Git Status tab next to shell tabs in
  one pane) nothing in `#0301`'s user quotes actually asks for.
- **The user's own phrasing is pane-level.** `#0301`: "create a new pane
  with the Git Status view," and `#0315`: "add and remove *panes* with the
  new views." Every user quote across both issues says "pane," never "tab."
  Reading intent into the phrasing is weak evidence on its own, but paired
  with the structural cost above it's not close.
- **CLI ergonomics favor pane-level.** `#0315`'s create/close verbs are
  pane id-scoped already (`PaneSplitReply.paneID`, `PaneCloseRequest.paneID`
  — see §5). A pane-level kind means "open a Git Status pane" and "close
  pane `<id>`" compose with the existing verb shape with no new addressing
  concept. A tab-level kind would need the verb surface to also address
  *which tab within a pane*, which today's `pane split` / `pane close`
  don't do and nothing in `#0315` asks for.

### The consequence made visible: what a non-terminal pane gives up

A terminal Pane can hold N tabs, each independently closable, each with its
own PTY, cwd, and bell state, switchable via `SlidingTabBar`. **A
non-terminal Pane holds exactly one instance of its view kind and has no
Tab bar at all.** Concretely: no Cmd-T equivalent inside a Git Status pane,
no per-view "duplicate," no per-view bell/unseen badge riding the existing
Tab-chip machinery. If a later feature wants "two Git Status panes watching
different repos side by side," the answer is two *panes* (a horizontal or
vertical split), not two tabs in one pane — which is exactly what `#0315`
question 5 anticipates when it says "two Process Status panes watching
different pids are sensible" (plural *panes*, not tabs). This is a real
capability loss relative to a hypothetical kind-on-Tab design, and it is
the deliberate trade for not touching `TabRuntime.terminal`'s non-optional
contract or `SlidingTabBar`'s terminal-shaped chip rendering. If a future
need genuinely requires multiple views-of-a-kind stacked in one region with
tab-style switching, that is new scope for a later issue to argue for
specifically — it is not assumed here.

### Model changes this implies

```swift
public enum PaneContentKind: String, Codable, Sendable, Hashable {
    case terminal
    // .gitStatus, .processStatus, etc. added by #0304/#0305/#0313/#0314
    // as each view ships — not pre-declared here (see §7's identifier
    // note: the *set* of kinds is a public contract but adding one is not
    // a wire-breaking change to the ones that already ship).
}
```

- **`PaneRuntime` gains `public let kind: PaneContentKind`**, set once at
  `init` and never mutated (a pane doesn't change kind after creation —
  there is no user-facing "convert this pane" operation in any of the
  child issues). Default `= .terminal` on the existing initializer so
  every call site that constructs a `PaneRuntime` today (there are several
  across `SplitTree.makePane`, `SessionRuntime.init`, tests) keeps
  compiling unchanged.
- **`PaneRuntime.init`'s precondition changes shape, not strength.** Today:
  `precondition(!initial.isEmpty, "PaneRuntime must contain at least one
  Tab")` (`PaneRuntime.swift:31`) runs unconditionally. Under kind: for
  `.terminal` panes the precondition is unchanged (≥1 Tab, non-negotiable —
  every terminal pane still needs an `activeTabID` and a first Tab to
  render). For non-terminal kinds, `tabs` is `[]` and `activeTabID`
  becomes `UUID?` (currently non-optional, `PaneRuntime.swift:10`) — nil
  for a kind with no Tab bar. Every reader of `activeTabID` — `PaneView`'s
  `activeIDBinding`, `TabTitleFormatter`, the sidebar pane row, XPC
  topology serialization (`TopologyPanePayload.activeTabID`, currently
  non-optional too, `TopologyPayload.swift:71`) — becomes an `if kind ==
  .terminal` branch or an optional-unwrap. This is real, mechanical churn
  across a double-digit number of call sites; it is exactly the refactor
  `#0303`/`#0304` will have to do, and is out of scope for this document
  to perform, only to size and hand off precisely.
- **`SplitTreeNode` is unchanged: still `case leaf(PaneRuntime)` /
  `case split(...)`** (`SplitTree.swift:27-30`, confirmed current). Kind
  lives inside the leaf's payload, not as a new case — a split-tree leaf is
  still "one visible region," regardless of what's inside it. This is the
  cheapest point in the whole design: every tree-walking function in
  `SplitTree.swift` (`allLeafPanes`, `findPane`, `visibleLeafPanes`,
  `panePositions()`, `removingPane`, `swapping`, `rebalancingChain`, …)
  keeps working unchanged because none of them inspect what's *inside* a
  leaf — they only navigate the tree shape. Pane-swap (`tree.swapPanes`)
  and resize/rebalance logic are kind-agnostic for the same reason: they
  move/resize *panes*, not tabs, so a Git Status pane swaps and resizes
  exactly like a terminal pane does today, for free.
- **`SplitTree.makePane` (`SplitTree.swift:208-215`, confirmed current)
  is terminal-only today and stays terminal-only.** It is called from
  `splitFocusedPane`, `splitFullDimension`, and `splitPane(id:...)` — all
  three are the "split an existing pane, inheriting its cwd" family, which
  only makes sense for a terminal source (a Git Status pane has no cwd to
  inherit in the same sense — see §5's `--view` discussion). A parallel
  entry point, `SplitTree.makePane(kind:)` or a new
  `SplitTree.insertPane(_:adjacentTo:direction:)` taking an
  already-constructed non-terminal `PaneRuntime`, is the right shape for a
  future issue to add: it inserts a pre-built pane using the same
  `SplitTreeNode.inserting`/`rebalancingChain` machinery `makePane`'s
  callers already use, without threading `inheritingFrom: PaneRuntime?`
  through a codepath that doesn't apply to it. Not built here — this
  document names the extension point so `#0304`/`#0315` don't reinvent it
  differently.
- **`TabRuntime` is untouched.** No optional `terminal`, no kind field on
  `TabRuntime` (see the kind-on-Tab rejection above). This is the load-
  bearing simplification the pane-level decision buys: everything in
  `docs/view-hierarchy.md` §§3–6 (the terminal-host lifecycle, the
  `#0289` synchronous-free guarantee, the per-window placement isolation)
  continues to apply to `TabRuntime`/`TerminalViewState` exactly as
  written, because a non-terminal pane never constructs one.

---

## 2. How `PaneView` branches

**Decision: `PaneView.body` branches once, at the top, on `pane.kind`.
Everything below that branch point — the Tab bar, the `ZStack` of
`TerminalPlaceholderView`s, the terminal-specific `onChange`/`onAppear`
wiring — exists only in the `.terminal` arm.**

Today, `PaneView.body` unconditionally renders the Tab bar plus `ZStack {
ForEach(pane.tabs) { TerminalPlaceholderView(...) } }`
(`BattyKit/Sources/BattyKit/Views/PaneView.swift:78-207`, confirmed
current — the `ZStack`/`ForEach`/`TerminalPlaceholderView` block is at
lines 122-129 specifically). Mounting a `TerminalPlaceholderView` is not
passive: its `body` unconditionally calls `TerminalHostStore.shared
.terminalView(for:windowID:)` (`TerminalPlaceholderView.swift:42-43`,
confirmed current — `let _ = TerminalHostStore.shared.terminalView(for:
tab, windowID: windowID)`), which lazily creates an `AppTerminalView` and
adds it to the window's host; AppKit then walks `viewDidMoveToWindow` and
libghostty spawns the PTY (`docs/view-hierarchy.md` §5, "First mount of
`TerminalPlaceholderView`"). **A pane whose `kind != .terminal` must never
reach that call**, or opening a Git Status pane spawns a shell nobody asked
for — the exact regression `#0302`'s Description names as the central risk.

The shape:

```swift
public var body: some View {
    switch pane.kind {
    case .terminal:
        terminalBody   // today's VStack { tab bar; ZStack of placeholders }
                        // — unchanged, byte-for-byte, from the current body
    // case .gitStatus: GitStatusPaneBody(pane: pane) — added by #0304,
    //   not designed here.
    }
}
```

Two properties this split must preserve, both already true of the current
`body` and worth stating explicitly so a future implementer doesn't drop
them while doing the split:

- **The chrome that lives *outside* the kind branch stays outside it.**
  `PaneView`'s `.overlay` chain (focus border, bell flash, pane-swap drop
  zone — `PaneView.swift:234-262`) and the `.background { PaneFramePreferenceKey
  ... }` geometry reporting (`PaneView.swift:264-274`) are pane-level
  chrome, not terminal-level. `panePositions()` and the pane-swap drag
  source depend on every pane — terminal or not — reporting a frame via
  `PaneFramePreferenceKey` and participating in `PaneSwapDropZone`. Those
  modifiers stay attached to the outer `body`, wrapping the `switch`, so a
  Git Status pane swaps, resizes, and drags exactly like a terminal pane.
  The bell-flash and focus-border overlays are visually generic (an accent
  stroke) and cost nothing to keep pane-level even though a non-terminal
  pane's `.terminal`-specific triggers for them
  (`onChange(of: pane.tabs.map(\.bellCount)...)`, `PaneView.swift:201-203`)
  obviously don't apply — that `onChange` moves into the `.terminal` arm
  along with everything else that reads `pane.tabs`.
- **`isPaneFocused`, `hasSiblingPanes`, `chipMaxWidth`/`charBudget`
  (`PaneView.swift:48-72`) are a mix.** `isPaneFocused` (reads
  `tree.focusedPaneID`) and `hasSiblingPanes` (reads
  `tree.visiblePanes.count`) are kind-agnostic and stay outer-scope.
  `chipMaxWidth`/`charBudget` are Tab-chip sizing math — purely
  `.terminal`-arm concerns — and move inside `terminalBody` (or a
  follow-up can leave them as private methods gated by `pane.kind ==
  .terminal` at the call site; either is fine, this document doesn't need
  to pick between two mechanically-equivalent Swift refactors).

This is a pure `body`-level branch — no new state, no new `@Observable`
writes, so it introduces nothing `docs/swiftui-observation-rules.md`
needs to audit. The one thing to flag for whoever implements it: **the
`switch` itself must stay inside `body`, not hoisted into a computed
property that gets called from two places** — `body`, view `init`s, and
their callees are exactly the "pure, no side effects" zone that document
requires, and a plain `switch` expression satisfies that trivially. Nothing
about this branch touches focus or selection flow.

---

## 3. The terminal-host boundary

**Decision: `TerminalHostStore` (placement, host-view lifecycle, subview
management) is `.terminal`-kind-only, full stop. A non-terminal pane never
calls `terminalView(for:windowID:)`, never gets a placement, never has an
entry in `TerminalHostStore.terminalViews` or `.tabWindowMap`.** It is
plain SwiftUI, rendered in-place by `SplitNodeView`'s `.leaf` case exactly
where `PaneView` sits today, with no AppKit host indirection at all.

**One clarification the drag correction below (the "Item by item" table)
requires up front, so the two don't read as contradicting each other:**
"terminal-kind-only" describes what `TerminalHostStore` *tracks* —
placements, subviews, per-tab lifecycle. It is not a claim that the host's
AppKit *footprint* is confined to terminal panes' screen regions. The
`TerminalHostView` is a single `NSView` sized to the entire detail area
(see below), so the region belonging to a non-terminal pane still sits
inside that view's bounds even though `TerminalHostStore` has no entry for
it — the store's data model is kind-scoped; the view's geometry isn't.

Why the *data* boundary is safe to state as a clean cut: `docs/view-
hierarchy.md` §3 exists because SwiftUI's rebuild churn (`sidebar
collapse, a session selection change, a window resize that crosses a
layout threshold`) would otherwise destroy a live `ghostty_surface_t` if
the terminal `NSView` were hosted directly inside a `NSViewRepresentable`
that SwiftUI can tear down and remake. **A SwiftUI-only Git Status view has
no such live, expensive-to-recreate resource riding on AppKit view
identity** — its state (parsed `git status` output, a file-system watcher)
lives in an `@Observable` model object the same way any other SwiftUI
feature's state does, and SwiftUI rebuilding its view tree is the normal,
expected, harmless case every other SwiftUI view in the app already
tolerates. The entire reason the host-store indirection exists doesn't
apply, so it isn't needed — not "needed but simplified," genuinely not
needed.

### Which `docs/terminal-pane-requirements.md` guarantees extend to a
non-terminal pane

**Only §4's overlay rule extends unchanged. Every input-routing guarantee
in §§1–3, and the z-order constraint in §5 that makes them non-trivial, do
not extend — but §3 (drag and drop) doesn't extend for a different,
more dangerous reason than §1/§2, and an earlier draft of this section got
that reason wrong. The correction is worth reading before the table.**

#### The premise that was wrong, and what's actually there

An earlier draft of this document asserted a non-terminal pane has "no
`TerminalHostView` subview sitting above" it and that `.onDrop` is
therefore "safe to use directly." **That premise is false.**

There is exactly **one** `TerminalHostView` per content window, and it
**fills the entire detail area**, not just the screen regions where a
terminal happens to be rendered: "The long-lived terminal host fills the
entire detail area... Placed below the session chrome in the ZStack"
(`SessionDetailView.swift:183-195`), with `autoresizingMask = [.width,
.height]` (`TerminalHostView.swift:52`). Its `init` registers the whole
view for Finder file drags — `registerForDraggedTypes([.fileURL])`
(`TerminalHostView.swift:58-59`) — once, for the view's entire bounds, not
per terminal subview. A non-terminal pane's screen region is still *inside*
that bounds; the host just doesn't happen to have an `AppTerminalView`
subview positioned there today.

`docs/view-hierarchy.md` §4 (binding, cited by this document's own opening
paragraph) states the general rule this falls under: AppKit's drag
dispatch "does **not** fall through to a SwiftUI sibling underneath an
opaque AppKit subview — `hitTest` and drag dispatch use different paths."
`TerminalHostView.swift:53-57`'s own comment says the same thing from the
other direction (why drag registration lives on the host and not a SwiftUI
sibling): "AppKit dispatches drags to the deepest view at the cursor that
has registered for the type... it does not fall through an AppKit subview
to a SwiftUI drop target below" (written for `#0102`, but the mechanism is
symmetric regardless of which side — terminal or non-terminal — is being
routed around).

Two pieces of code confirm the host is asked about drags anywhere in its
bounds, not just over a terminal: `draggingEntered`/`draggingUpdated`
return `.copy` whenever the drag carries a file URL, checked *before* what's
under the cursor is examined (`TerminalHostView.swift:107-125` —
`updateHoverTab`/`terminalTab(at:)` there only drives the hover-highlight
side effect, not the returned `NSDragOperation`); and `performDragOperation`
has an explicit rejection branch, `reason=no-terminal-under-point`, for a
drop landing inside the host's bounds but outside any terminal subview's
frame (`TerminalHostView.swift:151-154`). That branch existing, with its
own log line, is evidence this exact case — a drag over host-owned
territory with nothing terminal beneath it — is real today (a click at the
edge of a resizing split, a stale placement) and only gets more common once
non-terminal panes can occupy that territory deliberately.

**Consequence:** a non-terminal pane's own `.onDrop(of: [.fileURL])` most
likely **never fires** for a Finder file drag over its region — the host is
the nearest ancestor registered for `.fileURL`, spans that region, and (per
the dispatch rule above) AppKit does not retry a declined drag against a
SwiftUI sibling. The user-visible failure mode: a copy cursor appears (the
host's `draggingEntered` already returns `.copy` before it knows nothing is
under the point), then the drop silently does nothing
(`performDragOperation` returns `false`) — the `#0143` failure class this
issue's Description names as the operative risk, inverted: `#0143` was a
SwiftUI overlay *above* the terminal stealing a drag headed for Ghostty;
this is the terminal host, spanning territory it no longer exclusively
owns once non-terminal panes exist, stealing a drag headed for a
non-terminal pane's own SwiftUI `.onDrop`.

**This conclusion is extrapolated from the documented AppKit
registration/dispatch mechanism and the code above, not from an empirical
test** — no non-terminal pane exists yet to actually drag a file onto.
Flagging that gap explicitly, rather than asserting confidence this
document doesn't have: **whichever child issue first gives a non-terminal
pane its own file-drop affordance (most likely `#0304` or `#0305`) must
verify this empirically before shipping**, and if the prediction holds,
must not rely on SwiftUI `.onDrop` for that pane.

**Recommended fix direction**, so that child issue doesn't have to invent
one from scratch: centralize non-terminal drop routing in the AppKit layer
the same way terminal drops already are, rather than fighting the
dispatch rule. Concretely, extend `TerminalHostView` (or a sibling
`NSDraggingDestination` covering the same bounds) with a lookup parallel to
`terminalTab(at:)` that answers "which non-terminal pane, if any, is at
this point," and forward the drop to that pane's own handler the same way
`performDragOperation` already forwards to `tab.terminal.send(joined)` for
a terminal tab. The point → pane-id lookup this needs isn't built from
nothing: `PaneFrameTracker`/`PaneFramePreferenceKey`
(`BattyKit/Sources/BattyKit/Commands/PaneFocus.swift:13-24`) already
collects a `[UUID: CGRect]` of every pane's frame, populated by `PaneView`'s
own geometry reporting and consumed today by `focusPane(adjacent:)`
(`SessionDetailView.swift:200-202`, `session.paneFrames.frames`). That's
the right *kind* of machinery, but not yet the right *coordinate space*:
`PaneView`'s reporting uses the `"session"` named coordinate space
(`PaneView.swift`'s `.background` block), while `TerminalHostStore`
placements — and thus any point a drag delivers to the host — are in the
`"terminal-host"` space (`TerminalHostInstaller.coordinateSpaceName`).
Bridging those two spaces (or having non-terminal panes additionally report
into the terminal-host space) is real, unresolved implementation work for
whichever child issue builds this — naming the extension point here is not
the same as having solved it.

#### Item by item

| Requirement | Extends to non-terminal panes? | Why |
|---|---|---|
| §1 Pointer input (click focuses + routes to terminal, drag selects, scroll scrolls buffer) | No — replaced by ordinary SwiftUI gesture handling, and *this one really is* safe as stated | `TerminalHostView.hitTest` returns `nil` when no terminal subview is under the point (`TerminalHostView.swift:102-105`, overriding the default `NSView.hitTest`'s "return self" for an empty area) — that override is exactly what lets a click over a non-terminal pane's region fall through to the SwiftUI view underneath. Pointer dispatch and drag dispatch are genuinely different AppKit paths (`docs/view-hierarchy.md` §4), and only pointer dispatch has this fall-through override; drag dispatch, per the correction above, does not. A non-terminal pane's click-to-focus is a plain SwiftUI `.onTapGesture`/button action. |
| §2 Keyboard input (forward to terminal, Cmd-C/V via Ghostty, IME) | No | No `NSTextInputClient` surface exists to protect, and keyboard dispatch follows the normal first-responder chain rather than the AppKit-registration path drags use — a non-terminal pane's SwiftUI content participates in that chain normally, the same as any other SwiftUI view in the app. |
| §3 Drag and drop onto the terminal (files, text, images → Ghostty) | **No — and not safely so.** A non-terminal pane's own `.onDrop` is at real risk of silently never firing for a file drag; see the correction above. | The host's `.fileURL` registration spans the whole detail area, not just terminal regions, and AppKit's ancestor-registration drag dispatch does not retry a declined drag against a SwiftUI sibling underneath. This needs empirical verification and very possibly an AppKit-level fix (see the recommendation above) before any non-terminal view ships file-drop support. |
| §4 Pane chrome overlays (`.allowsHitTesting(false)` rule for focus border, bell flash, drop-target) | **Yes, unchanged** | These overlays are pane-level chrome (see §2 above) — they render over *any* pane, terminal or not, and the `.allowsHitTesting(false)` rule that keeps them from stealing input applies exactly the same way regardless of what's underneath. |
| §5 AppKit z-order constraint | **No — but not vacuously.** This is the section that explains *why* §3 above is a real hazard rather than a non-issue. | The terminal host sits above the *entire* detail area in AppKit's z-order, not just above terminal-shaped regions within it. The same structural fact that makes drag routing *to* the terminal correct (§3 of that doc) makes drag routing *away from* a non-terminal pane a live risk — both are consequences of one host view spanning territory that no longer belongs exclusively to terminal content once non-terminal panes exist. |
| §6 Manual checklist (pointer, drag, keyboard, IME on the terminal) | No — this checklist stays scoped to `.terminal` panes specifically | See §6 below: it must still be re-run on **terminal** panes after any change that touches the shared pane-body/`PaneView` code path. It is not a checklist a non-terminal view needs to pass for its *own* input — but see the drag caveat above for what a non-terminal view *does* need verified, which this checklist as written does not capture. |

The one item that stays a clean, unqualified "yes": **§4's
`.allowsHitTesting(false)` rule extends unchanged**, because those overlays
(focus border, bell flash, pane-swap drop zone) are attached outside the
`switch` in §2's design and render for every pane regardless of kind — the
rule that governs them doesn't depend on anything the drag correction above
changes.

---

## 4. The Codable `Pane` field and the `workspace.json` inconsistency — resolved

### What's actually true, verified against source and git history

`#0302`'s Description could not settle from the docs alone whether
workspace persistence exists. It doesn't, and the reason the docs
disagreed is now clear from `git log`:

- **Workspace persistence was built** (`#0030`/`#0031`, "Wire workspace
  persistence end-to-end," 2026-05-11-ish) — four source files
  (`Workspace.swift`, `WorkspaceConversion.swift`, `WorkspaceManager.swift`,
  `WorkspaceStore.swift`) implementing a Codable snapshot + file I/O +
  save/load orchestrator, writing `~/Library/Application Support/Batty/
  workspace.json`.
- **Reading it on launch was turned off** (`#0055`, "Workspace restoration
  on launch is not normal terminal-app behavior," 2026-05-11) — the write
  path stayed live as a "write-only diagnostic snapshot."
- **The whole thing was deleted** (`#0172`, "Remove workspace persistence:
  source, docs, and spec," 2026-05-20, resolved) — all four source files
  removed, `LayoutModel.swift` "trimmed... to `SplitDirection` only" (the
  issue's own words), `Concepts.md`'s `## Workspace` section removed,
  `PRD.md`'s M7 milestone removed. `#0172`'s root cause note says
  "Workspace persistence was never a planned feature" — that line, taken
  literally, is itself imprecise (it demonstrably *was* built and shipped
  as write-only for a stretch), but the *operative* fact — no code
  anywhere serializes layout state today — is correct and independently
  verified below.
- **Verified independently against the current tree (not just history):**
  `grep -rn "WorkspaceManager\|workspace\.json" BattyKit/Sources/
  Batty/` returns nothing. `LayoutModel.swift` today
  (`BattyKit/Sources/BattyKit/Model/LayoutModel.swift`) contains exactly
  `SplitDirection` and `Pane { id, isHidden }` — the latter is a **dead
  Codable type**: `grep -rn "JSONEncoder\|Codable"
  BattyKit/Sources` shows `Pane` conforms to `Codable` but nothing
  constructs a `JSONEncoder`/`JSONDecoder` for it anywhere in the tree.
  `PaneRuntime.snapshot()` (`PaneRuntime.swift:39-41`) still produces a
  `Pane` value, but nothing calls `snapshot()` outside `BattyKitTests`
  (verified by grep) — it is public API with no production caller today.

**Conclusion: `#0302`'s premise was correctly skeptical. `Concepts.md` is
directionally right (no persistence exists) even though its "never
planned" framing overstates the historical record. `CLAUDE.md` and
`docs/view-hierarchy.md` are wrong** — both describe `workspace.json`
serialization and a `WorkspaceManager.swift` that `#0172` deleted three
months before `docs/view-hierarchy.md`'s own "Document version: 4 —
2026-08-01" revision date, meaning the stale reference postdates the
deletion it contradicts; it wasn't simply missed at the time, it was
reintroduced or never scrubbed across a later doc revision.

### Doc fix applied by this issue

`docs/view-hierarchy.md` is fixed as part of this issue's commit (see
`git diff` on this branch): the model-hierarchy diagram's `Workspace
(write-only persistence; one file)` root node and the `Workspace |
WorkspaceManager | .../WorkspaceManager.swift` table row are removed, and
the "serialized to `workspace.json`" sentence in the paragraph below the
table is corrected to describe what's actually true — `Pane` is a Codable
value type with no current serialization call site, kept ready for the
day persistence is re-added.
`CLAUDE.md`'s architectural-rules line ("This is what Workspace
persistence serializes") is corrected the same way, in the same commit,
since it is the other doc `#0302` names as contradicting the code. Neither
edit touches `Concepts.md` (already correct post-`#0172`; the "never
planned" framing is a historical-accuracy quibble, not a code-vs-doc
contradiction, and `#0172`'s own resolved issue file is the right place
for that nuance, not a live doc a subagent reads for current-state truth).

**One further doc debt this document identifies but does not pay down:**
`Concepts.md:63`'s Pane entry — "**Purpose:** hosts the Tab bar and renders
the active Tab's Terminal Session" — is falsified the moment any child of
this design ships a non-terminal pane. `#0301`'s own scope note and this
issue's Description both already commit a later child to updating
`Concepts.md`/`PRD.md`'s vocabulary once the design proceeds; this
document isn't that child (no pane kind ships here — `.terminal` is still
the only one that exists), so `Concepts.md` stays untouched by this commit.
Naming the exact line now, rather than leaving the next implementer to
re-find it: whichever issue lands the first non-terminal `PaneRuntime`
(most likely `#0303` or `#0304`) should rewrite `Concepts.md:63` to
something kind-conditioned, e.g. "hosts either a Tab bar rendering the
active Tab's Terminal Session (`.terminal` panes) or a single non-terminal
view (all other kinds)" — matching whatever `PaneContentKind` cases exist
by then.

### The `Pane` field itself, designed as if persistence lands

```swift
public struct Pane: Codable, Sendable, Hashable {
    public var id: UUID
    public var isHidden: Bool
    public var kind: PaneContentKind = .terminal

    private enum CodingKeys: String, CodingKey {
        case id, isHidden, kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        isHidden = try c.decode(Bool.self, forKey: .isHidden)
        kind = try c.decodeIfPresent(PaneContentKind.self, forKey: .kind) ?? .terminal
    }
    // synthesized encode(to:) is fine — Codable's default memberwise
    // encoding always writes `kind`, so only *decoding* an old/absent
    // field needs the custom initializer above.
}
```

Backward-compatible decode: an absent `kind` key (any snapshot written
before this field existed, or by a future producer that doesn't know about
non-terminal kinds yet) decodes as `.terminal` — the only kind that existed
when `Pane` had no `kind` field, so this is not just a safe default, it's
the *correct* reconstruction of what an old snapshot actually meant.
`PaneContentKind` itself should almost certainly *not* get a lenient
"unknown case → some fallback" decode the way a network-facing enum might:
if persistence lands and a future kind is removed or renamed, decoding an
unknown raw value should fail loudly (the default `Codable` behavior for a
`String`-backed `RawRepresentable` enum) rather than silently
misrepresenting a Git Status pane as a terminal pane on restore — a design
call for whichever issue actually wires persistence back up, not something
to soften here.

`PaneRuntime.snapshot()` gains one line: `Pane(id: id, isHidden: isHidden,
kind: kind)`.

---

## 5. Composing with the `#0257`-umbrella CLI deltas (`#0315`)

`#0315` is explicit that its verb-shape questions are open and gated on
this document (`#0302`) for the kind identifiers and the close answer.
This section settles what `#0302` owes `#0315`, without pre-empting the
things `#0315` says must be settled with the user directly.

### What this document settles for `#0315`

- **Kind-aware close: `pane close` needs a kind-aware branch, not a new
  verb — confirmed, and now precisely locatable.** `#0315`'s question 2
  asks whether `pane close`'s implementation generalizes; the answer
  depends on where the terminal-host boundary sits, which §3 above just
  fixed. `AppStateStore.closePane(id:)` → `WindowRuntime.closePane(id:
  refuseIfAppsLastPane:)` (confirmed current at
  `WindowRuntime.swift:314`, matching `#0315`'s citation) walks
  `pane.tabs`, checks `terminal.needsConfirmClose` per tab, and calls
  `TerminalHostStore.shared.releaseTerminalView(forTabID:)` per tab
  (`WindowRuntime.swift:326-330`, confirmed). Under this design, a
  non-terminal pane's `tabs` array is empty (§1), so `pane.tabs.contains
  (where: { $0.terminal.needsConfirmClose })` is vacuously `false` and the
  `for tabID in tabIDs { TerminalHostStore... }` loop is a no-op over an
  empty set — **the existing cascade already degrades correctly for an
  empty-tabs pane with zero changes**, as long as whatever teardown a
  non-terminal pane's *own* resources need (stopping a file watcher, e.g.)
  is added as an explicit `kind`-gated step in the same function. That
  per-kind teardown step is `#0303`'s job (the lifecycle contract), not
  this document's — `#0303` is correctly ordered before `#0304`/`#0305` in
  the umbrella's children table for exactly this reason. `pane close`'s
  *verb* needs no change; its *implementation* needs one small,
  kind-gated addition, confined to the same function, once `#0303` defines
  what that addition tears down.
- **Kind-aware `list`: the wire shape needs two changes to
  `TopologyPanePayload`, and the `activeTabID` one is not "additive" —
  it needs an explicit encoding decision.** `TopologyPanePayload`
  (`TopologyPayload.swift:66-81`, confirmed current, no kind field) needs
  a `kind: PaneContentKind` field mirroring `Pane`'s (§4), plus `tabs:
  [TopologyTabPayload]` becoming possibly-empty (no type change — arrays
  don't have the problem below) and `activeTabID` becoming optional to
  mirror §1's model change.

  **The `activeTabID` change is not additive, and an earlier draft of this
  document said it was.** `TopologyPayload.swift:89-93` describes the
  `list`/`sessionInfo` JSON shape as a contract `#0274` froze for
  `#0257`/`#0266`, and `TopologyPayloadTests
  .listJSONTopLevelKeysAreStableNotCompilerSynthesized`
  (`BattyKitTests/TopologyPayloadTests.swift:183`) pins it by *exact* set
  equality: `Set(paneBody.keys) == ["id", "isHidden", "isFocused",
  "activeTabID", "tabs"]`. Swift's synthesized `Codable` conformance
  encodes an `Optional` property via `encodeIfPresent` — a `nil`
  `activeTabID` would **omit the key from the JSON entirely**, silently
  shrinking that set for every non-terminal pane, which is exactly the
  regression the pinned test exists to catch (correctly — an agent parsing
  `list` output that expects `activeTabID` to always be present would hit
  a missing key on precisely the panes it's most likely probing next).
  Adding `kind` to the same struct changes the pinned set too, but
  deliberately: that's an intentional, visible wire-shape addition the
  frozen-contract test must be updated to expect, which is a different
  thing from `activeTabID` silently vanishing.

  **The fix this document specifies:** give `TopologyPanePayload` a
  hand-written `encode(to:)` that calls `container.encode(activeTabID,
  forKey: .activeTabID)` — the non-`IfPresent` overload — so
  `Optional<UUID>`'s own `Encodable` conformance runs and the key is
  always present, holding explicit JSON `null` for a non-terminal pane
  rather than disappearing. This keeps the *shape* (which keys exist)
  stable while changing what `null` at that key *means* (no active tab,
  because there's no tab bar) — a decision `#0315` should carry into its
  own wire-contract writeup rather than re-derive. The pinned test needs
  updating for both changes: the `kind` key added to the expected set, and
  a new fixture asserting `activeTabID` stays present-with-`null` for a
  non-terminal pane. One open question this document does not resolve and
  flags for `#0315` to settle with the user: whether every consumer of
  `list`/`sessionInfo` (agent scripts outside this repo, not just
  `BattyKitTests`) can tolerate "key present, value `null`" the same way
  it would tolerate "key absent" — a strict JSON-schema-validating client
  could treat those as distinguishable states. This document picks the
  always-present-key encoding because it's the one that doesn't silently
  shrink the pinned contract's key *set*, not because it's proven safe for
  every possible external consumer.
- **Kind identifiers are a *value set*, not a wire *shape* — decide the
  set once, here, so `#0315` doesn't invent one per view.** `#0315`
  question 3 asks that the Codable spelling, the topology-payload
  spelling, and the CLI spelling be decided together (not necessarily
  identical strings). This document's position: the Codable
  `PaneContentKind` raw value **is** the CLI-visible spelling too —
  `PaneContentKind.gitStatus.rawValue` should literally be `"git-status"`,
  used unchanged in `--view git-status` and in the JSON `kind` field
  `list` emits. One string, three call sites, zero translation table to
  keep in sync. The only reason to diverge would be if the CLI needed a
  friendlier name than JSON wants — nothing in `#0315`'s user quotes
  suggests that's true here, so this document picks the simpler option:
  same string everywhere, kebab-case (matching existing CLI verb
  conventions like `pane split`/`pane close`), decided per-kind at the
  moment that kind's view ships, not pre-declared for kinds that don't
  exist yet (`#0313`/`#0314` will name their own).
- **Singleton-per-scope: yes, `PaneContentKind` carries the flag; the
  *enforcement* is `#0315`'s to build.** `#0315` question 5 (also
  `issues/0315.md:47`) asks this directly of `#0302`, and the earlier draft
  of this document silently routed the whole question to `#0315` as CLI
  policy — that was a miss; the *model* half belongs here. This document's
  answer: `PaneContentKind` gains a computed property, e.g. `var
  isSingletonPerSession: Bool`, that each kind sets when it's declared
  (§1's `PaneContentKind` enum is exactly where — `.terminal` is
  `false`, obviously; `#0315`'s own examples suggest `.thermals` and
  `.lmStudioDashboard` are plausible `true` cases, `.processStatus` a
  plausible `false` one, matching `#0315`'s "two Process Status panes
  watching different pids are sensible; two thermals panes are not"). What
  this document does **not** do: implement the check. Enforcing
  singleton-ness means querying every existing pane across a scope (a
  session? a window? the whole app? — `#0315` doesn't pin the scope word
  either, and this document isn't extending itself to do so) at
  pane-creation time and deciding what happens on conflict — return the
  existing pane's id, error, or (explicitly ruled out already by `#0315`'s
  no-focus-steal rule) focus the existing one. That's mutation-time policy
  living in whichever function ends up handling "create a pane of kind X"
  (`#0315`'s create verb, and/or `AppStateStore`), not a fact the
  `PaneContentKind` model type can decide on its own — the flag says
  *whether* to check; the create path says *what counts as the same scope*
  and *what to do about it*. `#0315` inherits a settled flag instead of
  having to invent one per kind from scratch.

### What this document deliberately leaves to `#0315`

Per `#0315`'s own framing ("the verb-shape and naming decisions below are
their own one-way doors... settled with the user before implementation"),
this document does not pick: the create-verb shape (new `pane new --view`
vs. extending `pane split --view`), the discoverability verb
(`pane views`), duplicate/idempotency policy per kind, or the exact
error-contract mapping to exit codes. Those are `#0315`'s to settle with
the user. What this document *does* guarantee to `#0315`: whichever shape
is chosen, the payload's new field is exactly `kind: PaneContentKind`
(string enum, same spelling as the CLI flag), and the reply carries a pane
id the same way `PaneSplitReply` does today — because §1's model puts kind
on the pane, an "open a pane with kind X" request only ever needs to carry
one new field beyond what `PaneSplitRequest` already carries (`paneID`,
`direction`) for the "which existing pane to split next to" part; kind
itself doesn't require any change to *how* the new pane gets positioned in
the tree (§1's `SplitTree.insertPane` extension point handles that,
generically, for any kind).

**No collision with in-flight `#0257`-umbrella payload changes**: this
document proposes no change to `PaneSplitRequest`, `PaneSplitReply`,
`PaneCloseRequest`, `PaneCloseReply`, or `XPCVerb` — all four confirmed
unchanged by this design. `#0315`'s eventual create-verb payload is new
surface, not a modification of anything this document touches. `Pane` and
`TopologyPanePayload` do each gain a `kind` field, and (per the correction
above) `TopologyPanePayload.activeTabID`'s encoding needs to change
specifically so its JSON key stays present — that's a real, visible
wire-shape change to the `list`/`sessionInfo` contract, not something to
call additive-and-therefore-safe; it is exactly the kind of change the
pinned `TopologyPayloadTests` case must be updated for, deliberately, as
part of whichever issue implements it.

---

## 6. Regression evidence plan

**This issue ships no code — the manual terminal-pane checklist in
`docs/terminal-pane-requirements.md` §6 does not need to be re-run for
`#0302` itself.** Nothing in this document's deliverable (a markdown file
plus a two-line correction to `docs/view-hierarchy.md` and `CLAUDE.md`)
changes any Swift source, so there is no runtime behavior to regress. The
"evidence" for this issue is the citation-by-citation verification
recorded inline above (§§1-4) and the build/test run in §7 below,
confirming the branch is green — a baseline check that the branch compiles
and existing tests pass, not proof of any new behavior, because there is
none.

**What a later implementing issue must do, because this document commits
it to specific structural changes:**

- **Any issue that implements §1's `PaneRuntime`/`Pane` field changes**
  (most directly `#0303`, since it's the first child to touch the model)
  must re-run the full manual checklist from
  `docs/terminal-pane-requirements.md` §6 on **terminal** panes — pointer
  input (click focus + mouse-report routing), drag-select, scroll,
  file-drop-to-path-insertion, text-drop-to-paste, keyboard forwarding, and
  IME composition — because `activeTabID` becoming optional and
  `PaneRuntime.init`'s precondition changing shape touch code every
  terminal pane's rendering path depends on (`PaneView.activeIDBinding`,
  `TabTitleFormatter`, the sidebar pane row, XPC topology serialization).
  This is precisely the class of change `#0143`'s two failed fix attempts
  are the standing warning about: a structural change to shared pane
  machinery that *looks* additive can silently break terminal input
  routing if a branch is missed.
- **Any issue that implements §2's `PaneView.body` kind-switch** (again,
  first landed by whichever of `#0303`/`#0304` actually writes the
  `switch`) must re-run the same checklist for the same reason — `body`
  is the single most load-bearing function in the terminal pane's
  contract, and splitting it changes control flow even when the `.terminal`
  arm is meant to be byte-for-byte preserved.
- **Any issue that implements §3's non-terminal rendering path** (first
  concrete non-terminal view, most likely `#0304`) does **not** need the
  terminal checklist for the *new* view kind's own input behavior — that
  view was never claiming Ghostty-level guarantees (§3's table above says
  so explicitly) — but **does** need to verify, manually, that opening and
  closing a non-terminal pane alongside an existing terminal pane in the
  same session doesn't regress the terminal pane's behavior (the checklist
  again, run against the *terminal* pane, in a mixed-kind session this
  time). This is the scenario `#0301`'s scope note and `#0303`'s framing
  around "#0285 is the cautionary context" both worry about: a new feature
  that's fine in isolation but wrong in composition.
- **`#0315`'s CLI verb work** does not itself touch `PaneView` or the
  terminal-host boundary — it's a new XPC payload plus dispatch — so it
  does not need the manual checklist unless its implementation ends up
  touching `AppStateStore.closePane`/`splitPane` in a way that changes
  terminal-pane behavior (§5 above argues it shouldn't have to).

---

## 7. Verification for this issue

**No Swift source changed.** This issue's deliverable is `docs/pane-kinds.md`
(this file), a correction to `docs/view-hierarchy.md`, a correction to
`CLAUDE.md`, and an entry in `docs/README.md`'s index. The build/test run
below is a baseline check that the branch is known-green going in — it is
not evidence of any new behavior, because none was added.

```
scripts/build.sh unit
```

Observed (2026-08-08, branch `issue/0302`, round 1): **933 tests in 107
suites passed** (`Test run with 933 tests in 107 suites passed after 8.039
seconds`), `** TEST SUCCEEDED **`. Re-observed after review round 1's
doc-only revisions (2026-08-08, same branch): **933 tests in 107 suites
passed** again (`... after 7.559 seconds`), `** TEST SUCCEEDED **`.
`Configuration/Active.xcconfig` read `#include "Prod.xcconfig"` before and
after both runs — Prod, not Beta — and `git status` showed no
`Batty.xcodeproj/project.pbxproj` residue afterward. Both runs are baseline
checks only, since this issue changes no Swift source at any point.

---

## Summary table (quick reference for later issues)

| Question (`#0302`'s Expected behavior, items 1-6) | Answer | Section |
|---|---|---|
| 1. Where does kind live? | `PaneRuntime`/`Pane`, not `TabRuntime`/`Tab`. Non-terminal panes have `tabs: []`, no Tab bar. | §1 |
| 2. How does `PaneView` avoid mounting `TerminalPlaceholderView` for non-terminal panes? | Single `switch pane.kind` at the top of `body`; `TerminalPlaceholderView` only exists in the `.terminal` arm. | §2 |
| 3. Terminal-host boundary — what extends to non-terminal panes? | `TerminalHostStore`'s *tracked data* (placements, subviews, lifecycle): terminal-only, full stop. The host *view*'s AppKit footprint spans the whole detail area regardless — pointer fall-through is safe (`hitTest` returns `nil` off-terminal) but Finder-file drag fall-through is **not** safe (`.fileURL` registration is host-wide; AppKit doesn't retry a declined drag against a SwiftUI sibling) and needs empirical verification + likely an AppKit-level fix before any non-terminal view ships file-drop. Only §4's overlay `.allowsHitTesting(false)` rule extends unconditionally. | §3 |
| 4. Codable `Pane` field + `workspace.json` doc inconsistency | `kind: PaneContentKind = .terminal`, backward-compatible decode. No persistence exists today (`#0172` deleted it); `docs/view-hierarchy.md` and `CLAUDE.md` were stale and are corrected by this issue; `Concepts.md` was already accurate on persistence but its Pane definition (`Concepts.md:63`) is falsified by this design and needs a later child's rewrite. | §4 |
| 5. Composing with `#0257`/`#0315` CLI deltas | `pane close` needs one small kind-gated addition inside the existing cascade, not a new verb (confirmed by tracing the actual close path). `pane split`/`PaneSplitRequest`/`PaneCloseRequest`/`XPCVerb` unchanged by this design. Kind identifier = single string used identically in Codable, topology JSON, and CLI flag. `TopologyPanePayload.activeTabID` needs a hand-written always-present-key encoding, not a plain `Optional` — a real, visible wire-shape change, not an additive one. `PaneContentKind` carries a per-kind `isSingletonPerSession`-style flag; enforcing it is `#0315`'s. | §5 |
| 6. Regression evidence plan | This issue: none needed (no code changed). Whoever lands §1/§2's structural changes: full manual checklist on terminal panes. Whoever lands the first non-terminal view: checklist on terminal panes in a *mixed-kind* session. | §6 |

---

*Document version: 2 — 2026-08-08. Written for `#0302`. No code changes
accompany this document; see §7 for the baseline build/test verification.
Version 2 (review round 1): corrected §3's drag/z-order analysis — the
terminal host spans the entire detail area and is registered for
`.fileURL` host-wide, so a non-terminal pane's `.onDrop` is at real risk of
never firing, not "safe by construction" as version 1 claimed; corrected
§5's `TopologyPanePayload.activeTabID` framing from "additive" to a
real wire-shape change requiring an explicit always-present-key encoding;
answered the model-level half of the singleton-per-scope question
`#0315`/`issues/0315.md:47` asks of this issue; named `Concepts.md:63` as
the specific line a later child must update; corrected `CLAUDE.md`'s
remaining stale `Session`/`Tab`/`SplitNode` type list.*
