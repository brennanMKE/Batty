# Non-terminal Pane content lifecycle

Design and contract for `#0303`, a child of the `#0301` umbrella
(non-terminal view kinds). This document defines the lifecycle every
non-terminal Pane content kind (Git Status — `#0304`, Process Status —
`#0305`, LM Studio dashboard — `#0313`, system metrics — `#0314`) must
adopt: setup, show/hide, teardown, and how a conformer proves it complied.
Read `docs/pane-kinds.md` first — it settles where pane *kind* lives
(`PaneRuntime`/`Pane`, not `TabRuntime`/`Tab`) and how `PaneView` will
branch on it; this document is the lifecycle that attaches to whatever
identity that design defines, once a concrete kind exists to attach it to.

**No code ships against `PaneView`, `PaneRuntime`, or the terminal path in
this issue.** No non-terminal view kind exists yet — `#0302` designed the
abstraction but shipped no code, and this issue's own scope explicitly
excludes wiring anything into the live pane render path (see "Why no
`PaneContentKind` yet" below). What ships here is the contract — a
protocol, a pure state machine, and executable tests against a recording
test double — so `#0304`/`#0305`/`#0313`/`#0314` implement against a fixed
shape instead of inventing their own discipline per view.

---

## 1. Why this exists — the precedent, not re-derived

Terminal Sessions already went through this the hard way, under the
`#0285` resource-growth umbrella (peak measured footprint: 8.4 GB across
111 open Terminal Sessions, 84% graphics memory). Two resolved children
are the precedents this lifecycle generalises, and the lesson each one
gets from is carried forward *verbatim*, not paraphrased into something
weaker:

- **`#0288` — occlusion signalling is the show/hide precedent.**
  Non-visible Terminal Sessions rendered a full frame on every PTY
  wakeup regardless of visibility — `AppTerminalView.setSurfaceVisible(_:)`
  had zero callers in either repository. The fix wired occlusion from the
  same visibility facts already computed for placement (§2 below) into
  `setSurfaceVisible(_:)`, stopping the render loop for hidden Tabs,
  hidden Panes, and occluded windows. **The libghostty C API offered no
  way to release a surface's GPU resources short of destroying the
  surface and its PTY** (tracked upstream as `#0293`) — so "stop
  rendering" was the only lever available, and even that required four
  implementation rounds because suppressing wakeups also silences bells,
  titles, and child-exit events, which needed a separate poll-driven
  ticker to keep flowing. **A non-terminal view kind has no equivalent
  external constraint.** It is plain SwiftUI plus Batty-owned watchers,
  timers, and subprocesses — Batty can stop *and fully release* them on
  hide, not just stop rendering them. That total freedom is the argument
  for demanding real teardown discipline from day one, not "it's hidden,
  it's probably fine."
- **`#0289` — deterministic teardown is the teardown precedent, and its
  lesson is the load-bearing one for this document's "Observability"
  section.** `releaseTerminalView(forTabID:)` logged "released terminal
  view" at a point where the actual `ghostty_surface_free` was still
  deferred to ARC dropping the last reference to `TabRuntime` — which
  SwiftUI could hold past the nominal close (a stuck rename sheet, a
  lingering placeholder reference). The fix made the free run
  synchronously inside the close call, by setting `AppTerminalView
  .controller = nil` (an `open` property whose `didSet` reaches
  `tearDownSurface` before the surface's own internals are `internal`
  and unreachable) — see `docs/view-hierarchy.md` §5 for the full trace.
  **The verbatim lesson this document carries forward: a log line
  claiming teardown is not evidence teardown happened.** `#0289`'s own
  unit suite proved this the hard way — in the test harness the
  `AppTerminalView` never enters an `NSWindow`, so no surface is ever
  created, and the tests exercise the *assignment*, not the C free; the
  synchronicity claim rests on the pinned wrapper's `didSet` ordering,
  re-verifiable by re-reading that ordering, not by re-reading the log
  string. §5 below states plainly what this document's own tests do and
  do not prove, for the same reason.

`#0285` as a whole is the cautionary context: resource discipline
retrofitted after a footprint reached 8.4 GB cost an umbrella's worth of
issues, four implementation rounds and four review rounds on `#0288`
alone, and (per `#0288`'s Gotchas) a memory census that was *never
actually run* across the whole umbrella because the machine's screen
stayed locked for every session that needed it. New view kinds start with
the discipline built in, verified by a test that doesn't depend on GUI
access to run.

---

## 2. What drives visibility — reused, not reinvented

`#0303`'s Expected behavior requires show/hide to be "driven by the same
visibility facts that drive terminal occlusion (Pane in a non-selected
Session, inactive Tab, hidden Pane)." Those facts are computed today at
three call sites, verified against the current tree:

| Fact | Where it's computed | Citation |
|---|---|---|
| **Pane in a non-selected Session** | `SessionDetailView` sets an environment value comparing the session's id to the window's selected session id; `PaneView` reads it as `isSessionSelected` — this is the *view-layer* copy of the fact, for rendering. The *model-level* delivery to a `PaneContentLifecycle` conformer (`#0349`) is separate: `WindowRuntime.selectedSessionID`'s `didSet` calls `applySelectionVisibility(deselecting:selecting:)`, which sweeps the deselected Session's unhidden Panes with `setVisible(false)` and the newly selected Session's with `setVisible(true)` — see §5's "Where the calls come from" for the full account, now updated. | `BattyKit/Sources/BattyKit/Views/SessionDetailView.swift:203` (`.environment(\.isSelectedSession, session.id == windowRuntime.selectedSessionID)`); env key declared at `BattyKit/Sources/BattyKit/Commands/FocusedValues.swift:32`; read at `BattyKit/Sources/BattyKit/Views/PaneView.swift:15`; model-level delivery at `BattyKit/Sources/BattyKit/Runtime/WindowRuntime.swift` (`selectedSessionID`'s `didSet` and `applySelectionVisibility(deselecting:selecting:)`) |
| **Inactive Tab (within a Pane)** | `PaneView.body` compares each tab's id to `pane.activeTabID` when constructing its `TerminalPlaceholderView`. | `BattyKit/Sources/BattyKit/Views/PaneView.swift:126` — `isVisible: tab.id == pane.activeTabID && isSessionSelected` |
| **Hidden Pane** | `WindowRuntime.hidePane(id:)` is the single trigger for **both** halves of hiding, in the same function. It flips `pane.isHidden`, which is what makes `SplitContainerView`'s `SplitNodeView` stop constructing `PaneView` for that leaf (the SwiftUI unmount) — but that unmount is not what hides the terminal. In the same call, `hidePane` also drives `TerminalHostStore.setPlacement(_:forTabID:)` directly, once per tab, with an explicit `isVisible: false` placement. The in-code comment at the call site says why: the placeholder is about to unmount, so its own `onGeometryChange` will never fire to report a hidden placement itself — driving the store directly is how `#0256` fixed exactly this gap (that issue's round-1 blocker: the terminal stayed floating on screen because nothing but the unmount had been wired; `TerminalHostStore.updatePlacements(_:forWindowID:)` — a full-window sweep that *would* have caught this — has no production caller at all, then or now, only test callers). **A non-terminal conformer already has the identical shape provided for it, not something to invent** — see §5's "Where the calls come from" for the direct consequence: `hidePane` is where a conformer's `setVisible(false)` belongs, called the same explicit way. | `BattyKit/Sources/BattyKit/Runtime/WindowRuntime.swift:405-431` (the per-tab `setPlacement` loop at `:427-431`); `TerminalHostStore.setPlacement(_:forTabID:)` at `BattyKit/Sources/BattyKit/Runtime/TerminalHostStore.swift:419-434`; `SplitContainerView`'s unmount check at `BattyKit/Sources/BattyKit/Views/SplitContainerView.swift:59-62` |
| **(Terminal-only today) Window occlusion** | `TerminalHostStore.effectiveSurfaceVisible(placementVisible:windowVisible:)` folds a fourth fact — whether the *window* is occluded/minimized — into the terminal path's effective visibility. | `BattyKit/Sources/BattyKit/Runtime/TerminalHostStore.swift:370-371` |

**What this table means for a non-terminal view kind, concretely:** the
non-selected-Session fact and the hidden-Pane fact are the two that
matter (the inactive-Tab fact does not apply — see below). Their *value*
is easy to compute the same way `isVisible` is computed for
`TerminalPlaceholderView` today: `isSessionSelected` and `!pane.isHidden`.
Their *delivery* to a conformer is not automatically solved by that
computation, and this is exactly where the terminal precedent above stops
being reusable off the shelf. A non-terminal Pane's content, if it were
naively made view-owned (a `@State` inside a future `GitStatusPaneBody`,
say), would only exist while its view is mounted — the same unmount that
stops `PaneView` from being constructed for a hidden Pane would, for a
view-owned conformer, just deallocate it via ARC with no `setVisible(false)`
/`tearDown()` call ever made, silently skipping past both the show/hide
contract (§4) and the teardown contract (§5). SwiftUI's `onDisappear` is
not an acceptable substitute delivery mechanism either — it is not
guaranteed to fire synchronously, or on every path a view can stop
rendering, which is exactly the shape of gap `#0256`'s own first cut hit
for terminals: hiding a Pane unmounted the SwiftUI subtree but nothing
told `TerminalHostStore` to hide anything, so the terminal stayed
floating on screen until the fix made `hidePane` call `setPlacement`
explicitly (the Hidden-Pane row above). **§5's "Where the calls come from" names the actual call
sites and settles conformer ownership so this is a concrete answer, not
an implicit assumption left for `#0304` to discover the hard way.**

The **inactive-Tab fact does not apply** — `docs/pane-kinds.md` §1 is
explicit that a non-terminal Pane has no Tab bar and no `TabRuntime`s at
all (`tabs: []`), so there is no per-Tab activity to compare against; a
non-terminal Pane's content is visible whenever its Pane is reachable
(unhidden) and its Session is selected — full stop. Window occlusion is
not folded in by this document; whether a future implementation should add
it is a design call for whichever child first wires this in, informed by
`#0288`'s own hard lesson that a naive fold silenced bells — a
non-terminal view kind has no bell-equivalent event stream today, but a
future one might, and that call should be made by someone who can name the
specific event stream, not preemptively here.

### Why no `PaneContentKind` field ships in this issue

`docs/pane-kinds.md` speculates that `#0303` — "since it's the first
child to touch the model" — is the most likely issue to land the
`PaneRuntime.kind` / `Pane.kind` field and `PaneView`'s kind-switch
(`docs/pane-kinds.md` §6, "Regression evidence plan"). **This document
does not do that.** `issues/0303.md` itself does not spell out a narrower
scope than that in so many words — the sentence below is a scope
constraint set for *this implementation round*, not a quotation from the
issue file's own Expected behavior, and it is worth being explicit about
that distinction so a reader who opens `issues/0303.md` looking for it
doesn't come away thinking this document misquoted its source: *"Do not
wire this into `PaneView` or the terminal path. No non-terminal view kind
exists yet; this issue ships the contract and its tests ahead of
`#0304`/`#0305`."* The decision holds regardless of which document states
it — touching `PaneRuntime`'s precondition or `PaneView.body`'s control
flow, even in a way `docs/pane-kinds.md` argues is structurally safe,
obligates the full manual checklist in `docs/terminal-pane-requirements.md`
§6 (pointer input, drag-select, scroll, file-drop, text-drop, keyboard,
IME) on **terminal** panes, which cannot be run headlessly and is exactly
the cost this round's scope is written to avoid incurring before there is
a concrete non-terminal view to justify it. The lifecycle contract
below is deliberately independent of `PaneContentKind`: `PaneContentLifecycle`
conformers don't reference `PaneRuntime`, `Pane`, or `PaneContentKind` at
all. Whichever of `#0304`/`#0305` lands the first concrete kind is the one
that pays that structural cost and runs that checklist — this document
just makes sure the lifecycle it wires in has already been decided and
tested.

---

## 3. The state machine

Four phases, matching `#0303`'s four Expected-behavior points one to one:

```
                  setUp(visible: true)
        ┌──────────────────────────────────┐
        │                                   ▼
   notSetUp                              active ──┐
        │                                   ▲     │ hide
        │ setUp(visible: false)             │     │
        │                              show │     ▼
        └──────────────────────────────►  suspended
        │                                   │
        │ tearDown                          │ tearDown
        ▼                                   ▼
                    tornDown  ◄──────────────┘
```

- **`notSetUp`** — initial phase. No watcher, poller, or subprocess exists
  yet.
- **`active`** — content is visible; periodic work (watchers, pollers) is
  running.
- **`suspended`** — content exists but is not visible; periodic work is
  stopped and any resources it would need are released, not merely
  paused-with-memory-held (§4).
- **`tornDown`** — terminal. Entered exactly once, by `tearDown`, from any
  of the other three phases (including directly from `notSetUp` — a Pane
  can be created and closed before ever being shown, e.g. the containing
  Session is removed immediately). Never left.

Implementation: `PaneLifecyclePhase` (the four cases above),
`PaneLifecycleEvent` (`setUp(visible:)`, `show`, `hide`, `tearDown`), and
`PaneLifecycleStateMachine` — a plain `Sendable` value type with one
method, `apply(_:) -> PaneLifecycleTransitionResult`, that encodes exactly
the diagram above and nothing else (`BattyKit/Sources/BattyKit/Runtime/
PaneContentLifecycle.swift`). It has no dependency on any view, watcher,
or AppKit type, so the full transition table is unit-testable without
constructing anything resource-bearing — see
`PaneLifecycleStateMachineTests` in
`BattyKit/Tests/BattyKitTests/PaneContentLifecycleTests.swift`.

`PaneLifecycleTransitionResult` distinguishes three outcomes, deliberately
not collapsed into "phase changed / didn't":

- **`.applied(from:to:)`** — a real transition happened.
- **`.noOp(at:)`** — the event was legal but changed nothing (showing an
  already-visible pane, hiding an already-hidden one, tearing down an
  already-torn-down one). Idempotent by design — a conformer's caller
  should never have to track whether it already called `setVisible(true)`
  before calling it again.
- **`.rejected(at:event:)`** — the event is illegal in the current phase
  (anything after `tornDown` except another `tearDown`; `show`/`hide`
  before `setUp`; a second `setUp`). This is a programmer error in the
  caller, not a normal runtime state — `PaneLifecycleController` (the
  small wrapper class conformers are expected to hold instead of a bare
  `PaneLifecycleStateMachine`) logs it at `.error` via the file's
  `Logger`, so a wiring bug surfaces in Console.app rather than silently
  doing nothing.

Why three outcomes and not just a `Bool`: a test (or a conformer) that
only checked "did phase change" could not distinguish "this
`setVisible(true)` was a harmless redundant call" from "this call landed
on a phase where it should never have been reachable at all" — the first
is normal SwiftUI churn, the second is exactly the kind of bug this
contract exists to catch instead of silently tolerate.

---

## 4. What "suspended" is allowed to cost

Zero periodic work, by contract. `PaneContentLifecycle.setVisible(false)`
(landing the state machine on `.suspended`) must stop every watcher,
timer, and poller a conformer owns — not merely mark them "paused" while
leaving the underlying resource allocated. This is the direct opposite of
what `#0288` found Terminal Sessions doing (a hidden Tab kept a full-size
GPU swap chain at its last visible size indefinitely, because the C API
gave Batty no cheaper option) and exactly the freedom §1 argues a
non-terminal kind actually has: a suspended Git Status watcher can
literally stop watching the filesystem, not just stop redrawing.

**Setup must not create work it would immediately have to suspend.**
`PaneContentLifecycle.setUp(visible: Bool)` takes the pane's *initial*
effective visibility as a parameter specifically so a Pane created hidden
(e.g. a session restored non-selected, once persistence exists again —
`docs/pane-kinds.md` §4) goes directly from `notSetUp` to `suspended`
without ever passing through `active` — see the diagram in §3: there is
no `notSetUp → active → suspended` path in the state machine, only a
direct `notSetUp → suspended` edge. A conformer's `setUp` implementation
must honor this by branching on `visible` before acquiring anything, the
same way `PaneContentLifecycleTests.createdHiddenNeverAcquiresAWatcherOrTicks`
asserts of the test double (§6).

**Showing resumes and refreshes.** The state machine's `suspended →
active` edge (a `.show` event) is where a conformer should both restart
its periodic work *and* perform one immediate refresh — the content may
be stale after however long it was suspended, and resuming a poller alone
would leave it showing the last-known state until the next tick. This
document does not prescribe *how* a concrete kind refreshes (a Git Status
view re-runs `git status` once; a process monitor re-samples once) — only
that the transition is the place to do it, exactly once per
`suspended → active` transition, not on every redundant `setVisible(true)`
call (`PaneContentLifecycleTests.redundantShowDoesNotDoubleAcquireOrDoubleRefresh`
pins this).

**Accepted deviation: a bounded, uncancellable off-actor unit of work
whose result is discarded is not "periodic work" this section forbids.**
`#0350` moved `SystemMetricsPaneContent`'s per-tick sampling sweep onto
its own `actor` so it stops blocking the main actor; the tradeoff is that
`setVisible(false)`/`tearDown()`'s `Task.cancel()` cannot interrupt a
sweep already in flight on that actor — every `performTick()` call that
already holds a sampler reference when the pane is nominally suspended or
torn down keeps running to completion, each bounded by up to one sweep's
duration. This is not limited to one outstanding call: calls sharing a
single sampler actor (e.g. refresh-button taps queued in quick
succession) serialize on that actor's executor and each still finishes,
and a quick hide→show→hide cycle leaves a stale sampler's in-flight sweep
running concurrently with the fresh sampler the next `startActive()`
builds. This is acceptable specifically because each sweep holds nothing
across the boundary (its own resources, if any, are opened and closed
within that one sweep) and a `generation` counter guarantees every one of
their results is never applied once stale — "suspended costs zero
*periodic* work" is preserved (nothing new starts), even though "zero
work in flight at the instant `setVisible(false)` returns" is not. A
future conformer that adopts this pattern needs both halves: a
same-generation-or-discard guard, and self-contained (open-and-close-
within-one-call) resource use inside the unit of work itself.

---

## 5. What teardown must guarantee

Synchronous and deterministic, on the calling thread, before `tearDown()`
returns — not deferred to `deinit`, not deferred to a `Task`, not
deferred to any future turn of the run loop. This is `#0289`'s lesson
applied one layer up: that issue made `ghostty_surface_free` run inside
`releaseTerminalView(forTabID:)` itself rather than waiting on ARC to
drop the last `TabRuntime` reference, specifically because SwiftUI could
(and did, per `docs/view-hierarchy.md` §5's diagnostic notes) hold a
reference past the nominal close. A `PaneContentLifecycle` conformer
faces the identical risk — SwiftUI can hold a reference to a closed
Pane's content model for a render pass or two — so `tearDown()` cannot
assume its own object is about to deallocate promptly; it must release
everything itself, explicitly, in the method body.

**What "release everything" covers**, per `#0303`'s Expected behavior:
watchers (e.g. an `FSEventStream`/`DispatchSource` for a file watcher),
caches (parsed output buffers), and subprocesses (anything spawned to
gather status). None of these exist in Batty's tree yet — `#0304`/`#0305`
are what will actually hold them — so this document's job is to fix the
*shape* of the guarantee (§3's `.applied` transition into `.tornDown`
must be the point every such resource gets released) rather than name
concrete resource types that don't exist yet.

**`tearDown()` must be idempotent.** A second call after teardown already
happened is a `.noOp` at the state-machine level (§3) and must not
attempt to release anything a second time — `PaneContentLifecycleTests
.tearDownIsIdempotent` exercises this against the test double by calling
`tearDown()` twice and asserting `WatcherLedger.releaseCount == 1` (§6).
`releaseCount` is deliberately unclamped, unlike a plain "is it back to
zero" check on `liveCount` alone would be — a `liveCount` that clamps at
zero cannot distinguish one correct release from an erroneous second one
that happened to land on an already-empty ledger, which is precisely the
bug this test exists to catch.

**Exception, bounded and specific to subprocess teardown (#0354).** The
*signal* and the *state-machine transition* stay synchronous — `tearDown()`
still sends `SIGTERM` (or equivalent) to any owned subprocess and lands the
state machine on `.tornDown` before returning, exactly like every other
resource above. What may run after `tearDown()` returns is only the
*bounded wait for that signal to actually take effect* and the *`SIGKILL`
escalation* if it doesn't — moved off the calling thread specifically
because `LMStudioDashboardPaneContent`'s version of that wait was found
blocking the main actor for up to a second on an ordinary pane close (the
former synchronous poll, #0354's filing). This is not a general license to defer
release to a `Task`: a conformer's other resources (watchers, caches) still
release synchronously in `tearDown()`'s own body, unconditionally. It is
scoped to the one case where the release step is itself a wait for an
external process's cooperation, bounded by a fixed timeout, with the wait's
eventual completion independently verifiable — not by a log line (this
section's standing rule, unchanged), but by an internal test seam
(`LMStudioDashboardPaneContentTests` awaits it via
`awaitPendingTeardownReapsForTesting()`). Quitting the whole app is the one
path where even this deferred wait isn't safe to rely on: the process can
exit before the detached task ever runs. `WindowRuntime`'s quit-path caller
(`tearDownAllPaneContentSynchronouslyForQuit()`) does the same wait
synchronously instead, via a small opt-in protocol
(`DeferredTeardownWaiting`) a conformer adopts only if it has this kind of
deferred work — accepting a brief block there because the app is about to
exit anyway, which is not true of any other `tearDown()` caller. Every
`SIGTERM` is sent before any wait begins, so a cooperative child costs
nothing extra at quit; the worst case is bounded per `SIGTERM`-ignoring
subprocess (`bound + min(bound, 0.5)`, ≈1.0s at `LMStudioDashboardPaneContent`'s
0.5s default), waited sequentially per subprocess a conformer owns (≈2.0s
worst case across its two log-stream subprocesses) — not a shared deadline
across the whole quit path.

**A second, distinct exception, bounded and specific to off-actor sampling
sweeps (#0350).** Same shape as #0354's above — the *state-machine
transition* stays synchronous, and what may run after `tearDown()` returns
is bounded and independently verifiable-as-inert, not a general license to
defer release — but a different resource class and a different mechanism.
`SystemMetricsPaneContent`'s per-tick sampling sweep runs on its own
`actor` (see §4's "accepted deviation" note) so it stops blocking the main
actor; `tearDown()` still returns immediately, having released every
resource *it* holds (the `Task` reference, the sampler, the delta state),
but any sweep already running on a sampler actor keeps executing for up to
one sweep's duration afterward — serially with any other call sharing that
same sampler actor, or concurrently with a fresh sampler's own sweep when
a quick hide→show→hide cycle left a stale sampler mid-sweep. Unlike
#0354's subprocess wait, there
is nothing here to reap or escalate: the sweep is self-contained (any
kernel handle it opens, it closes within that same sweep) and a
`generation` counter guarantees its result is discarded rather than
applied once stale, so the independent verification this section requires
is a discard proof, not a completion proof (`SystemMetricsPaneContentTests
.sampleCompletingAfterTearDownIsDiscarded`, `...AfterHideIsDiscarded`).
Quitting the app needs no equivalent to `DeferredTeardownWaiting` here —
there is no subprocess to guarantee-reap before exit, only a sweep whose
result is already guaranteed inert.

### Where the calls come from, and who owns the conformer

This document fixes the *shape* of setup/show-hide/teardown; naming the
exact call sites and settling who owns the conformer is `docs/pane-kinds.md`
§5's explicit hand-off to this issue: *"whatever teardown a non-terminal
pane's own resources need … [is] added as an explicit kind-gated step in
the same function. That per-kind teardown step is `#0303`'s job."* Two
answers, both consequences of tracing the actual terminal precedent
rather than assuming SwiftUI view lifecycle already covers it:

**Teardown's call sites are `WindowRuntime.closePane(id:refuseIfAppsLastPane:)`,
`removeSession(id:)`, `closeTab(id:)`, `RootWindowView.windowWillClose`,
and `BattyAppDelegate.applicationWillTerminate` — not a view's
`onDisappear`, and not one single choke point.** The terminal path's own
teardown is not driven by any SwiftUI view disappearing — `TerminalHostStore
.releaseTerminalView(forTabID:)` is called directly from a tab-id loop —
but **this document's earlier claim that `closePane` is "the single choke
point every close path ... already funnels through" is corrected here,
not repeated: it is false in this tree.** #0314's phase-2 review round 1
caught the first two gaps as a live bug, not a documentation nit;
a sibling issue's review round independently found the remaining two
gaps and folded them into the same fix, since the wiring is shared across
every non-terminal kind, not per-kind.
`WindowRuntime.removeSession(id:)` (the sidebar's "close session" control)
runs its own `releaseTerminalView` sweep over every pane in the session
and never calls `closePane`; `WindowRuntime.closeTab(id:)` calls
`SplitTree.removePane(id:)` directly when a pane's last Tab closes, again
without going through `closePane`; `RootWindowView.windowWillClose` and
`BattyAppDelegate.applicationWillTerminate` remove whole windows (and,
for the latter, every window in the app) without going through any
pane- or Session-scoped path at all. All five are ordinary,
production-reachable paths — a user closing a Session from the sidebar,
closing the one Tab a non-terminal pane structurally holds
(`docs/pane-kinds.md` §1's phantom-tab shape), closing a window, or
quitting the app — not edge cases.

A non-terminal conformer's `tearDown()` must therefore be called from
**all five** pane-removal paths, before (or as) the pane leaves its
Session's tree, or as the window/app it belongs to goes away — not a
`View.onDisappear`, which SwiftUI does not guarantee to fire
synchronously, or at all, on every path a Pane can stop being rendered (a
hidden Pane's `PaneView` already stops being constructed at all without
the Pane closing, per the Hidden-Pane row above). #0314's implementation
(`WindowRuntime.swift`) funnels all five through one private helper,
`tearDownNonTerminalContent(in:)` — the pane-scoped three call it
directly; the window/app-scoped two call the public
`tearDownAllPaneContent()`, which sweeps every Session's every pane and
calls the same private helper — rather than re-deriving the release step
at each site. Idempotent per pane (`tearDown()`'s own contract, §5
below), so a pane torn down explicitly by `closeTab` and then swept again
by a `removeSession` call it triggers (when closing the pane's last Tab
also empties the Session), or by a `tearDownAllPaneContent()` call that
happens to race a pane-level close, is harmless either way. Any future
kind's conformer inherits this wiring for free; it does not need its own
kind-gated call at any of the five sites.

**Visibility's call sites are `WindowRuntime.hidePane(id:)` and
`showPane(id:)` — but the two are not symmetric today, and this document
says so rather than smoothing it over.** `hidePane` already drives the
terminal path with an explicit, direct call: its per-tab loop
(`WindowRuntime.swift:427-431`) calls `TerminalHostStore
.setPlacement(_:forTabID:)` itself, precisely because the pane's unmount
alone is silent (§2's Hidden-Pane row; the `#0256` gap that call exists to
close). `showPane` (`WindowRuntime.swift:438-445`) has no equivalent: it
flips `pane.isHidden = false` and returns — nothing else. The un-hide is
delivered by the *remount*: the pane's `PaneView` (and its
`TerminalPlaceholderView`) gets constructed again, and the placeholder's
own `onGeometryChange`/`onChange(of: isVisible)` calls `setPlacement`
once it remounts (`TerminalPlaceholderView.swift:44-60`). That works for
the terminal path because the placeholder is deliberately lightweight and
remounting it is cheap and side-effect-free — it doesn't restart a PTY,
only re-reports geometry for a surface that never stopped existing.

**Resolved by #0314, adopted as the shape every non-terminal kind
wires: `showPane` gets an explicit `pane.content?.setVisible(true)` call,
matching `hidePane`'s more robust shape rather than the terminal path's
own asymmetric one.** The two candidates this document originally left
open were an explicit call (this one) versus riding a future
non-terminal pane body's own `onAppear`/remount, mirroring
`TerminalPlaceholderView`'s pattern. The remount-based option is
rejected, not left open any longer: it would make a non-terminal pane's
resumed sampling/watching depend on that specific kind's own view being
cheap and side-effect-free to remount — true of the terminal placeholder
by design, not something every future kind can be assumed to inherit —
and it would need re-deriving per kind, the same duplication problem the
teardown correction above exists to avoid. `hidePane`'s call has no such
gate — hiding always suspends, regardless of which Session is selected,
and `setVisible(false)` is idempotent when the Pane's content is already
suspended. Both call sites read `pane.content?.setVisible(...)`, a no-op
for `.terminal` panes (`content == nil`) and for any non-terminal kind
without a conformer yet, so a future kind inherits both halves of
show/hide for free rather than adding its own kind-gated branch to
either function.

**Correction (`#0349`): `showPane`'s call is not unconditional — it is
gated on the Pane's owning Session being the currently selected one.**
The paragraph above, in earlier versions of this document, described
`showPane`'s `setVisible(true)` call as unconditional, matching
`hidePane`'s shape exactly. That was already wrong when written, not
merely outdated by a later addition: the Sidebar's per-pane eye-icon
toggle (`SessionSidebarView.swift`'s `toggleVisibility()`, `#0256`,
predating `#0314`) calls `windowRuntime.showPane(id: pane.id)` for any
Session's Pane row — including a background Session's, since the
Sidebar's pane lists are not scoped to the selected Session — without
selecting that Session first, and `#0382`'s CLI `pane show` verb
(`AppStateStore.showPaneForXPC(id:)`) reaches the identical unconditional
call. `#0349` found the resulting gap directly: un-hiding a Pane whose
Session is not selected must not resume its content — only
`applySelectionVisibility` (below) resumes it, once the Session is
actually selected — so `showPane` now reads
`if session.id == selectedSessionID { pane.content?.setVisible(true) }`.

**The non-selected-Session fact (§2) now has a model-level function:
`WindowRuntime.selectedSessionID`'s `didSet` (`#0349`).** Every write to
`selectedSessionID` — `setSelectedSession(id:)` (the sidebar's selection
entry point, and the CLI focus verbs' shared entry point:
`focusSessionForXPC`/`focusPaneForXPC`/`focusTabForXPC` all call it),
`selectSession(at:)` (Cmd-1..9), `addSession`/`removeSession`/
`duplicateSession`, and `jumpToTab`/`jumpToBellEntry` — funnels through
this one property, so its `didSet` is a single choke point rather than a
call at each site. It calls a private `applySelectionVisibility
(deselecting:selecting:)`, which sweeps the deselected Session's
`!isHidden` Panes with `setVisible(false)` and the newly selected
Session's `!isHidden` Panes with `setVisible(true)` — a Pane already
hidden via `hidePane` is excluded from both sweeps, so it stays
suspended regardless of which Session is selected, exactly the
composition §4's "what suspended is allowed to cost" and this section's
`hidePane`/`showPane` contract require. `SessionDetailView`'s environment
write (`SessionDetailView.swift:203`) is unchanged and still the
view-layer copy of the same fact, used for rendering, not for lifecycle
delivery — the two are deliberately kept separate (see §2's updated
"Pane in a non-selected Session" row).

A related gap `#0349` also closed, not merely flagged: **a Pane created
directly into a background Session needs its *initial* effective
visibility threaded through explicitly**, since `selectedSessionID`
doesn't change when a Pane is created (only when a Session is selected)
— `applySelectionVisibility` never fires for a brand-new Pane in an
already-non-selected Session, so `PaneRuntime.init`'s prior code —
`content?.setUp(visible: !isHidden)` — would still start a background
Session's freshly-created Pane `.active`. `PaneRuntime.init` gained an
`isSessionSelected: Bool = true` parameter for exactly this, threaded
from `AppStateStore.splitPane(id:...)` (the
XPC `pane split` verb — the one production path that can create a Pane
in a Session other than the caller's own selected one, per this
function's own "never touches `selectedSessionID`" contract above;
computed there as `window.selectedSessionID == session.id`) through
`SplitTree.splitPane`'s own `isSessionSelected` parameter to
`SplitTree.makePane` to `PaneRuntime.init`'s `content?.setUp(visible:
!isHidden && isSessionSelected)`. `WindowRuntime.createPane` (the
GUI/menu path) always splits `selectedSession`'s own tree, so it passes
`isSessionSelected: true` unconditionally rather than computing it.
`SplitTree.makePane` (private, three callers) and the public
`SplitTree.splitPane(id:...)` both take `isSessionSelected` with **no
default** — both production callers already compute and pass a real
value, so a defaulted `true` at every other call site (including any
future one) could silently paper over a caller that should have computed
the real fact and didn't. `splitPane(id:)` never had a `tabLookup`
parameter; `#0359` removed the `{ _ in nil }` default from the private
`makePane`'s `tabLookup` parameter instead, for a related but different
reason: a silent default for that required dependency was a trap, since a
nil-returning lookup tombstoned every `.followingTab` target.
`splitFocusedPane`/`splitFullDimension` (terminal-only — neither takes a
`kind` parameter) pass `true` explicitly at their own two call sites into
`makePane`, since a `.terminal` Pane's `content` is always `nil` and the
flag has no effect either way. `PaneRuntime.init` keeps its own
`isSessionSelected: Bool = true` default, since production non-terminal
construction goes only through `makePane` (which has none), and the
large majority of test construction has no notion of Session selection
to supply.

**The conformer is model-owned, not view-owned — hung off `PaneRuntime`,
addressable by pane id, the same relationship `TabRuntime.terminal:
TerminalViewState` already has to its Tab** (`docs/view-hierarchy.md` §1's
model-hierarchy table). This is not a new pattern being introduced here;
it is the existing one, for two reasons that make it a conclusion rather
than a preference:

1. **`WindowRuntime.closePane` needs to call `tearDown()` directly**, and
   it already has the `PaneRuntime` in hand
   (`session.tree.allPanes.first(where: { $0.id == paneID })`) to call it
   on. A conformer reachable only from a SwiftUI view's `@State` would be
   unreachable from that function entirely — the same "the code that needs
   to call this can't reach it" problem `docs/pane-kinds.md` traces for
   `core.freeSurface()` in its account of `#0289`'s history (that method
   turned out to be `internal`; the reachable fix lived on a property the
   store already had a handle to).
2. **A view-owned conformer would reproduce the exact churn problem
   `docs/view-hierarchy.md` §3 exists to prevent for terminals.** SwiftUI
   is free to rebuild a `PaneView` (or its future non-terminal
   equivalent) on sidebar collapse, session switch, or a layout threshold
   crossing, and a conformer stored in that view's `@State` would be
   destroyed and recreated along with it — re-running `setUp` on every
   rebuild, which directly violates the idempotence this document
   requires (§3) and reintroduces the "SwiftUI tears down something that
   looks disposable but isn't" bug class `#0072`/`#0074`/`#0075` were
   filed to eliminate for terminals.

This also answers the question of whether `.tornDown`'s strictness (a
`.rejected` re-`setUp`, §3) is safe under ordinary SwiftUI remount
churn: **yes, because model ownership means the conformer is never
recreated by view churn in the first place.** `setUp` runs exactly once,
at Pane creation, the same way `TabRuntime.init` constructs its
`TerminalViewState` exactly once regardless of how many times
`TerminalPlaceholderView` gets rebuilt around it
(`docs/view-hierarchy.md` §5's timeline). A `.rejected` re-`setUp` would
only ever fire from an actual implementation bug — calling `setUp` from
inside a view's `body` or `init` instead of at model-construction time —
not from routine SwiftUI behavior, which is precisely the failure mode
`.rejected`'s logging exists to surface loudly rather than silently
tolerate.

**`setUp` staying in `PaneRuntime.init` created a real test-side-effect
problem once a concrete conformer existed, resolved by making *who
constructs the conformer* injectable rather than moving `setUp` out of
`init`.** A sibling issue's reviewer raised exactly the failure mode this
paragraph predicts is the only legitimate reason to deviate: unit-test
code that constructs a `PaneRuntime(kind: .someNonTerminalKind)` for
unrelated reasons (a split-tree test, a topology test) was, before this
fix, also starting that kind's real background work — a live subprocess,
an HTTP poll, or (`#0314`'s own case) a real 1 Hz sampling `Task` making
real host/IOKit calls — as an unavoidable side effect of construction.
Moving `setUp` into a view's `.task`/`onAppear` (one sibling branch's
original fix) is the wrong lever: it is exactly the "calling `setUp` from
inside a view" bug class named above. **The right lever is
`PaneRuntime.init`'s new `contentFactory` parameter**
(`(PaneContentKind) -> (any PaneContentLifecycle)?`, defaulting to
`PaneRuntime.makeContent`, an exhaustive switch with no `default:` so a
future kind forces a compile-time decision instead of silently resolving
to `nil`): production call sites are unaffected (the default factory
behaves exactly as before), and test code that doesn't want a real
conformer's real side effects injects an inert test double instead.
`setUp` still runs synchronously inside `init`, unconditionally, exactly
as this section already required — only *what `contentFactory` returns*
is now a caller's choice, never *when or whether `setUp` is called*.

### What this document's tests do and do not prove

**Per `#0303`'s explicit constraint, a log line is not acceptable evidence
of teardown, and this document does not offer one as evidence.** What the
tests in `PaneContentLifecycleTests` actually check is a plain integer
counter (`WatcherLedger.liveCount`) that a test double increments on
acquire and decrements *inside `tearDown()`*, read back **on the same line
of execution**, immediately after `tearDown()` returns — no `await`, no
`Task`, no run-loop spin. That proves the *shape* of the guarantee (a
conformer that follows the pattern the test double follows will release
synchronously) and proves the *test infrastructure* can detect a
regression (deleting the `release()` call from the test double's
`tearDown()` makes the corresponding test fail deterministically — verify
this the same way `#0288`/`#0289` did, by temporarily deleting the call
and re-running `./build.sh unit` before trusting the test).

**What it does not and cannot prove**, because no concrete non-terminal
view kind exists yet to prove it about: that a *real* watcher (an actual
`DispatchSourceFileSystemObject`, an actual subprocess) gets released the
same way. That verification is `#0304`/`#0305`'s job, against real
resource types, the same way `#0289`'s own acceptance criteria named a
live open/close census (`issues/0285/investigation-live.md`) that its
unit suite alone could not perform (`#0289`'s Gotchas: "the unit suite
does not prove the C free... the tests exercise the assignment, not
`ghostty_surface_free`"). This document's tests prove the *contract* is
mechanically checkable; they do not and cannot stand in for measuring a
real resource's release once one exists.

---

## 6. How a view kind proves it complied

A conformer implements `PaneContentLifecycle`
(`BattyKit/Sources/BattyKit/Runtime/PaneContentLifecycle.swift`):

```swift
public protocol PaneContentLifecycle: AnyObject {
    var lifecyclePhase: PaneLifecyclePhase { get }
    func setUp(visible: Bool)
    func setVisible(_ visible: Bool)
    func tearDown()
}
```

Typically by owning a `PaneLifecycleController` (a small class pairing a
`PaneLifecycleStateMachine` with `.rejected`-event logging) and driving
its own watcher/poller/subprocess lifetime from the `PaneLifecycleTransitionResult`
each call returns — start work on a transition landing in `.active`,
stop and release on a transition landing in `.suspended` or `.tornDown`.

**The proof pattern**, demonstrated end to end by the test double
`RecordingPaneContent` in `BattyKit/Tests/BattyKitTests/
PaneContentLifecycleTests.swift` (there is no real conformer yet — this
*is* how the contract is verified ahead of one existing, per `#0303`'s
Expected behavior):

1. A resource ledger independent of the conformer's own lifetime (here,
   `WatcherLedger`, a plain counter — a real conformer's equivalent might
   be a process-table entry count, an open file-descriptor count, or a
   `DispatchSource` liveness flag) that acquire/release calls mutate.
2. A "periodic work" counter (`tickCountWhileActive`) that a simulated
   tick only increments while `lifecyclePhase == .active` — proving a
   hidden/suspended/torn-down conformer does zero periodic work, by
   *counting* attempted work and observing the count doesn't move, not by
   inspecting logs.
3. Assertions immediately following each transition, in the same test
   function, with no intervening delay — `createdHiddenNeverAcquiresAWatcherOrTicks`,
   `hidingAnActivePaneStopsTicksAndReleasesTheWatcher`,
   `tearDownFromActiveReleasesTheWatcherSynchronously`, and
   `fullCycleRecordsExactlyTheExpectedTransitionSequence` (the last one
   asserts the *exact* ordered sequence of `PaneLifecycleTransitionResult`
   values a full setup → show → hide → teardown cycle produces, not just
   the final phase).

A future concrete kind (`#0304`'s Git Status watcher, say) should follow
the identical pattern: replace `WatcherLedger` with something that
actually observes the real resource (an `FSEventStream` handle count, a
subprocess PID no longer appearing in `ps`), and replace `simulateTick()`
with the real poll/watch callback, gated the same way — `guard
lifecyclePhase == .active else { return }` before doing any work.

---

## 7. Verification for this issue

```
./build.sh unit
```

Run against branch `issue/0303`. Baseline going in (per `#0302`'s own
`docs/pane-kinds.md` §7, most recently observed on this branch's parent):
**933 tests in 107 suites**. This issue adds `PaneContentLifecycleTests.swift`
— three suites (`PaneLifecycleStateMachineTests`, `PaneLifecycleControllerTests`,
`PaneContentLifecycleTests`) covering state-machine transitions, the
controller wrapper, and the end-to-end recording-double behavior described
in §6. Most recently observed on this branch: **958 tests in 110 suites
passed**, `** TEST SUCCEEDED **` — the expected +25 tests / +3 suites over
baseline, with every new suite and test name present in the run output.
The issue file's own `## Verification` section, written on resolve, is
the durable record of this; treat the count here as this document's own
snapshot, not the sole source.

No terminal-pane manual checklist run: per §2's "Why no `PaneContentKind`
yet," this issue touches no `Pane`/`PaneRuntime`/`PaneView` source, so
`docs/terminal-pane-requirements.md` §6 does not apply here — it applies
to whichever child (`#0304` most likely) first wires a conformer into the
render path.

---

*Document version: 3 — 2026-08-08. Written for `#0303`, a child of the
`#0301` umbrella. No `PaneRuntime`/`Pane`/`PaneView` source changes ship
with this document — see §2's "Why no `PaneContentKind` yet." The next
child to touch the model or `PaneView.body` (most likely `#0304`) is the
one that pays the manual-checklist cost `docs/pane-kinds.md` §6 names and
should re-read this document's §2 and §6 before wiring a conformer in.
Version 2 (review round 1): corrected the misattributed quotation in §2
(it is this implementation round's scope constraint, not text from
`issues/0303.md`); corrected §2's Hidden-Pane row and added §5's "Where
the calls come from, and who owns the conformer" — the terminal path's
hide/teardown delivery is a direct call from `WindowRuntime`, not SwiftUI
unmount, and the conformer is model-owned (hung off `PaneRuntime`) for
the same reasons `TerminalViewState` is; fixed `WatcherLedger`'s clamp so
the idempotence test can actually detect a double-release instead of
silently tolerating it. Version 3 (review round 2): version 2's own
Hidden-Pane framing was itself wrong about the delivery mechanism — it
named `TerminalHostStore.updatePlacements(_:forWindowID:)`'s window-wide
sweep as what hides the terminal; that function has **no production
caller** (`TerminalHostInstaller.swift`'s doc comment claims a
`TerminalPlacementPreferenceKey` that `#0141` deleted; only
`BattyKitTests` calls it today). The actual mechanism, corrected in this
version: `WindowRuntime.hidePane` drives `TerminalHostStore.setPlacement`
directly, per tab, in the same function that flips `pane.isHidden` — the
exact fix `#0256`'s round-1 blocker required after its own first cut
shipped with the terminal floating on screen. Also corrected: `showPane`
has no equivalent direct call — the un-hide is delivered by the
placeholder's remount, an asymmetry the document previously glossed over
by describing both functions as driving the store "for the same reason."*

*Version 4 (`#0314` phase-2 review round 1, escalated by a sibling
issue's review): corrected the "`closePane` is the single choke point
every close path funnels through" claim — false in this tree.
`removeSession` and `closeTab` both remove panes without ever calling
`closePane`, and `RootWindowView.windowWillClose`/
`BattyAppDelegate.applicationWillTerminate` remove whole windows/the
whole app without going through any of the three. All five now funnel
through `WindowRuntime`'s `tearDownNonTerminalContent(in:)`/
`tearDownAllPaneContent()`. Resolved the `showPane` asymmetry this
document previously left open: an explicit, unconditional
`pane.content?.setVisible(true)` call, matching `hidePane`'s shape, not a
remount-dependent one. Resolved the setUp-in-`init` vs. test-side-effect
tension a sibling issue's reviewer raised: `PaneRuntime.init` gained an
injectable `contentFactory` parameter (default: an exhaustive,
no-`default:` `PaneRuntime.makeContent(for:)`) so test code can supply an
inert conformer instead of triggering a real one's real side effects —
`setUp` itself still runs synchronously inside `init`, unchanged.*

*Version 5 (`#0349`): closed the open wiring question §5 (then §2's
"Pane in a non-selected Session" row) left unanswered — the
non-selected-Session fact now has a model-level delivery,
`WindowRuntime.selectedSessionID`'s `didSet` calling
`applySelectionVisibility(deselecting:selecting:)`. Also corrected
Version 4's own "`showPane` gets an explicit, unconditional
`setVisible(true)` call" claim: `#0349` found that unconditional call
resumed a Pane's content even when its Session was not the selected one,
so `showPane` now gates the call on `session.id == selectedSessionID`.
Added `PaneRuntime.init`'s `isSessionSelected` parameter (threaded from
`AppStateStore.splitPane(id:...)` through `SplitTree.splitPane`/
`makePane`) so a Pane created directly into a background Session — the
one case `applySelectionVisibility` can't reach, since selection doesn't
change on pane creation — also starts suspended rather than active.*
