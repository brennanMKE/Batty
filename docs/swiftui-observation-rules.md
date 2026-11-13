# SwiftUI + Observation state-mutation rules

Binding rules for code that writes `@Observable` / `@State` properties from
SwiftUI-driven code, and for anything that synchronizes model state with
AppKit. Read this before touching focus or selection flow, before adding any
write to a view-driven callback, and before "fixing" a state-mutation warning.

These rules exist because violations produce *undefined behavior* — not a
compile error, but timing-dependent loops, dropped updates, broken input, and
AppKit NSExceptions that surface far from the offending line. Issue `#0229`
(three failures from one bug) is the case study at the bottom.

## Core invariant

**View construction is pure, and every state change has an explicit owner.**

While SwiftUI is reconciling or laying out the view graph, no code may write
observed state that feeds the same graph. Writes belong to code with a clear
owner and trigger: event handlers (button actions, menu commands, NSEvent
monitors), delegate callbacks from outside the UI (PTY events, libghostty
delegates), and genuinely asynchronous work.

The runtime warning "Modifying state during view update, this will cause
undefined behavior" is the *explicit* form of a violation. The implicit forms
have no warning: a write inside a synchronous call chain that *started* in the
update (see "AppKit interop" below), or a write whose feedback loop only
manifests under specific timing.

## What counts as SwiftUI-driven update code

**Forbidden by default to write observed state from** (these run during
reconciliation/layout, and any exception must be a documented Batty
architecture exception rather than a local workaround):

- `body`, and every computed property or helper it calls
- view `init`s (SwiftUI constructs views freely while diffing)
- `ViewModifier.body`
- `NSViewRepresentable.updateNSView` / `makeNSView` (and the controller
  variants), and their synchronous callees
- `PreferenceKey.reduce` and preference plumbing

**Requires an audit, not a ban — `onChange`, `onAppear`, `onGeometryChange`:**
these actions run inside the update transaction, and writing state from them
is supported (SwiftUI schedules another pass). Whether a write is safe depends
on **what flipped the observed value**, not on the callback's name:

- *Event-origin flips are routine.* `PaneView`'s
  `onChange(of: pane.tabs.map(\.bellCount))` calling `triggerBellFlash()` is
  fine — `TabRuntime.bellCount` is flipped by a libghostty delegate
  callback, and the write doesn't feed back into anything that re-fires it.
- *An `onChange` keyed on a Combine `@Published` property reached through a
  plain `let` on an `@Observable` model (e.g. `tab.terminal.bellCount`,
  `tab.terminal.title`)
  compares only when something else re-renders the view.* Observation
  tracks no dependency on it, so the handler fires late or never. Route
  such events from the delegate callback instead (#0227, #0260, #0561,
  #0563). Views read the `TabRuntime` mirror (`workingDirectory`,
  `terminalTitle`) instead.
- *Layout/focus/geometry-origin flips are the danger zone.* If the observed
  value was flipped synchronously by AppKit machinery — first-responder
  promotion, layout, geometry — the handler may be executing *inside that
  machinery* (mid-layout on macOS, see below), and a write there is the
  `#0229` crash. The audit: trace who flips the value, in what context, and
  what the write invalidates.

A bounded number of `onChange`-driven re-updates is tolerated by SwiftUI; the
runtime warning `"onChange(of:) action tried to update multiple times per
frame"` means an action is feeding back into its own trigger — treat it as a
loop, not noise.

## Ownership and passing rules for observed state

| Situation | Use |
|---|---|
| View owns a reference-type `@Observable` model's lifetime | `@State private var` |
| View only reads an observable passed from a parent | plain property (`let` when possible) |
| View needs projected bindings into an observable (`$model.property`) | `@Bindable` |
| App-wide store/service (`AppStateStore`) | `@Environment` |
| Caches, delegates, closures, pending `Task`s, timers inside an `@Observable` type | `@ObservationIgnored` — implementation details must not invalidate views |
| Hot-path store mutators that callers may re-assert (`AppStateStore.focusPane(id:)`) | make the API idempotent at the store (`if x != newValue`), never rely on call-site discipline |

Direct mutations of an observable model should normally live behind explicit
store/model methods. Use `@Bindable` in a view when SwiftUI needs the projected
binding, not just because the view has a reference to an observable.

`@State` stays `private`. Avoid `ObservableObject` / `@Published` /
`@StateObject` / `@ObservedObject` / `@EnvironmentObject` except when bridging
legacy or third-party code.

## Observation semantics and dependency granularity

- **Which equal writes notify depends on the property's type.** On this
  toolchain (Swift 6.4.2) the `@Observable` setter checks
  `shouldNotifyObservers` before `withMutation`:
  - an equal write to an `Equatable` property doesn't notify, so
    re-assigning the same `focusedPaneID` doesn't invalidate anything
    (`TabTitleMirrorTests.equalTitleDoesNotRenotifyTheMirror` also pins it);
  - re-assigning the same instance to a class-reference property doesn't
    notify (the comparison is identity, `===`);
  - a non-`Equatable` struct notifies on every write, equal or not;
  - `nil` → `nil` on an optional class-reference property notifies;
  - an in-place mutation notifies even when nothing changes: `dict[k] = v`,
    `array.removeAll { … }` matching nothing, `entries[i].x = y`, and
    `draft?.x = y` all go through the generated `_modify`, which always calls
    `withMutation`, while a whole-value equal assignment of the same
    `Equatable` collection doesn't notify.

  `ObservationEqualWriteSemanticsTests` pins all five (the in-place cases in
  `inPlaceMutationsNotifyEvenWhenNothingChanges` and
  `equalWholeCollectionAssignmentDoesNotNotify`). The store-level
  idempotence rule above still applies: it keeps a re-asserted mutator's
  *other* side effects from running, and it doesn't depend on the property's
  type.
- **Tracking is per property *read*.** A view depends on exactly what its
  body (and body's callees) read. Computed helpers broaden dependencies
  silently: `PaneView.isPaneFocused` reads `tree.focusedPaneID`, so every
  `PaneView` re-evaluates on every focus write. Pass narrow values down
  instead of whole observables when a child needs one fact.
- **Keep body-adjacent helpers pure and cheap.** No writes hidden inside
  formatters, accessors, or computed properties views call
  (`TabTitleFormatter.chipTitle` runs once per chip per body evaluation —
  its log line is the canary, see Symptoms).
- **Loops form across layers, not inside one function.** The dangerous shape:
  model write → view update → AppKit side effect → observable flip → callback
  writes model. Each hop looks locally reasonable. Before adding a write to
  such a path, draw the full cycle and name what dead-ends it.

## AppKit interop hazards in Batty

On macOS, `NSHostingView` processes SwiftUI updates inside `-[NSView layout]`.
An `onChange` action can therefore be executing **inside AppKit's constraint
layout pass** (`_NSViewLayout`). Two hard rules follow:

1. **Never synchronously call constraint-dirtying or responder-changing
   AppKit APIs from SwiftUI-driven callbacks**: `makeFirstResponder`,
   `addSubview`, window operations, frame writes on Auto-Layout-managed
   views. Mid-pass, AppKit answers with an NSException
   (`_postWindowNeedsUpdateConstraints` inside `_NSViewLayout`) that
   `+[NSApplication _crashOnException:]` turns into `EXC_BREAKPOINT`.
   The exception is AppKit's convergence guard: "The window has been
   marked as needing another Update Constraints in Window pass, but it has
   already had more Update Constraints in Window passes than there are
   views in the window" (a twin exists for Layout Window passes). Marking
   a window dirty mid-pass is legal; AppKit runs another pass, and raises
   only when some participant keeps re-dirtying it. So the frame that
   throws is the first requester after the loop hit the cap, not
   necessarily the loop's source. Look in the app's log for the preceding
   "Future marking … might be ignored" line, then find the participant
   that re-dirties every pass (#0601).
2. **AppKit side effects flip `@Observable` properties synchronously.**
   `makeFirstResponder` → `becomeFirstResponder` → libghostty focus delegate
   → `TerminalViewState.isFocused = true`. A handler observing that flip runs
   inside the promoter's context — the implicit core-invariant violation.

**Debugging:** the crash's faulting-thread stack shows only generic AppKit
display-cycle frames. The real chain lives in the *thrown exception's*
backtrace — `asiBacktraces` / `lastExceptionBacktrace` in the `.ips`. Read
that first. To check that a new hosting composition settles, host it in
`LayoutConvergenceProbe` (`BattyKit/Tests/BattyKitTests/LayoutConvergenceProbe.swift`),
as `SessionDetailLayoutConvergenceTests` and `StatusPaneLayoutConvergenceTests`
do. It counts the window's update-constraints and layout requests per
settle, and AppKit's own pass cap fires in that harness, so a real loop
fails the run.

**Give scrolling one owner inside a hosting tree.** A `List` or `Table`
nested in a SwiftUI `ScrollView` brings its own `NSScrollView` and
`NSTableView`, and posts window update-constraints requests for its visible
rows on every content change. System Metrics' 1 s refresh made hundreds per
tick that way until its process list became a `LazyVStack` in the Pane's
one `ScrollView` (#0606, guarded by
`StatusPaneLayoutConvergenceTests.systemMetricsTickStaysUnderRequestCeiling`).

**Sanctioned exceptions** (documented in `view-hierarchy.md`; do not add new
ones): `TerminalPlaceholderView.body`'s lazy `terminalView(for:)` performs a
one-time `addSubview` into the persistent host on first mount, and the
placeholder's `onGeometryChange` calls `TerminalHostStore.reportFrame(_:forTabID:)`,
which writes plain frames on the terminal views inside `TerminalHostView`
and may **reveal** (`isHidden = false`) the view of a Tab the actions
already marked shown. Both are bounded by design — first-mount-only and
frame-plus-reveal respectively. The placeholder path never hides a view and
never decides visibility: hiding the window's first responder makes AppKit
change the first responder, which must not happen inside layout (#0605).
Every hide, and the first-responder resignation that comes with it, happens
in the action that changed Tab, Session or Pane visibility, through
`TerminalHostStore.setTabShown(_:forTabID:)` (`PaneRuntime.activeTabID`'s
observer, `WindowRuntime.selectedSessionID`'s `didSet`, `hidePane`/`showPane`,
`SplitTree`'s new-Pane adoption). A reveal is responder-neutral: AppKit only
reassigns the first responder when it, or an ancestor, is hidden.
Frame writes and reveals are constraint-free because each `AppTerminalView` has
`translatesAutoresizingMaskIntoConstraints = false` and no constraints, so it
is outside the window's constraint engine. With autoresizing-mask
constraints (the setting before #0601), every placement write marked the
detail column's `NSHostingView` as needing update constraints from inside
SwiftUI's layout pass. `SessionDetailLayoutConvergenceTests.terminalPlacementWriteMarksNoViewAsNeedingUpdateConstraints`
guards that, and `tabSwitchDoesNotChangeFirstResponderDuringLayout` /
`sessionSwitchDoesNotChangeFirstResponderDuringLayout` guard the responder
side. The
first-mount bound is enforced by the store: it refuses to create a view or
record a frame or shown state for a released tab id, because SwiftUI can evaluate a
closing Pane's placeholder after the close (#0535). Anything
beyond that shape goes through an event handler or the store, not the update.

## Two-way model ↔ AppKit sync

When one fact lives in two places — *which pane is focused* is both
`SplitTree.focusedPaneID` (model) and `NSWindow.firstResponder` (AppKit) —
every sync path must declare a direction, and each direction gets exactly
**one declared writer**:

- **Model-initiated** (keyboard command writes model → view reacts → AppKit
  follows): the follow-up into AppKit runs on a fresh main-actor turn, never
  inside the update transaction, and carries a staleness guard (generation
  token) so a superseded follow-up can never fire late
  (`TerminalSurfaceFocuser`). The single writer is
  `WindowRuntime.requestTerminalFocus`, reached from the model setters
  (`SplitTree.focusedPaneID`, `PaneRuntime.activeTabID`), the
  `selectedSessionID` write, and a content window's first registration
  (`AppStateStore.registerNSWindow`); no view infers focus from an observed
  flip. Requests are keyed per window, and a Session that is not selected in
  its window issues none (#0611).
- **AppKit-initiated** (user clicks): the code that *embodies the intent* —
  `TerminalClickFocusMonitor`, during event dispatch — writes the model
  itself, synchronously. The interaction depends on winning that ordering.

**An observed property is evidence that something changed, not evidence of
intent.** Never reconstruct user intent from downstream observable effects —
libghostty flips `isFocused` on *existing* surfaces when a new surface is
created (`#0230` trace), so a model write keyed on that flip cannot tell a
click from churn. No context audit fixes a handler whose trigger doesn't
mean what it assumes. Route intent from its source as an explicit command;
Observation is for rendering, not for round-tripping authority between two
state holders.

The strongest dead end is therefore **no echo handler at all** — `#0230`
deleted the `isFocused → focusedPaneID` write rather than guarding it. Where
an echo handler must exist, a store-level equality guard handles same-value
echoes, and a programmatic-change token / source check / staleness predicate
handles different-value ones — but guards damp the loop; removing the
inference removes it (`#0229` proved equality-only and re-timing both fail).

Choose one authority per fact, write down the direction and single writer of
each path, and delete inferred echoes before reaching for guards.

## `Task` and async work

- A `Task` may write observed state when it represents **real asynchronous
  work** with clear ownership, cancellation, and stale-result checks (e.g.
  "is this tab still the focus target?" before acting).
- **`Task { @MainActor }` is not a safety device.** Hopping a write "later"
  moves it out of the current transaction but reorders it against every other
  queued main-actor job — retry ladders, echoes, user input. In `#0229`
  exactly such a hop silently broke click-to-focus.
- If a write is illegal where it happens, restructure **which code owns the
  write** (direction + echo suppression), not *when* it runs.

  Worked example (#0602): a Session switch's side effects (focus the
  selected Session's terminal, mark its active Tab seen, apply its Session
  Theme, deny the previous Session's pending clipboard request) used to run
  in `SessionDetailView`'s `onChange(of: selectedSessionID)`, which SwiftUI
  flushes inside `NSHostingView.layout`. They now run in
  `WindowRuntime.selectedSessionID`'s `didSet`, which every selection path
  writes from its own event handler, so they run in the action that changed
  the selection, synchronously, and the view only reacts. The cost of a
  `didSet` is ordering: a path that also moves focus inside the target
  Session must arrange the focus first and write the selection last.

- **Work that must follow a sheet's dismissal waits for the sheet's
  `onDismiss`.** It is the completion signal, delivered by SwiftUI when the
  sheet has finished closing, so it is event-origin and not a `Task` hop. The
  sheet only records what was chosen and sets its `isPresented` to false; the
  host acts in `onDismiss`. Example (#0475): the Open Project picker and the
  Command Palette hand a Project open to `SessionDetailView`, which runs it in
  `.sheet(onDismiss:)` so the startup-command trust sheet is not presented
  over a sheet that is still closing.

## Checklist before touching a state-flow path

1. List every property the change writes, and the exact context each write
   runs in (event handler? `onChange`? synchronous callee of an AppKit call?).
2. For each `onChange`/`onAppear` write: who flips the observed value, and in
   what context? Event-origin or layout/focus/geometry-origin? And does the
   flip *mean* what the handler assumes — can the library flip it as a side
   effect (surface-creation churn, `#0230`) rather than as user intent?
3. List who observes each written property and what they do on invalidation.
   If any observer's reaction can write state, name the dead end.
4. For crashes, read `asiBacktraces` in the `.ips` before trusting the
   faulting-thread stack.
5. Verify with the *minimal* targeted UI tests
   (`./build.sh ui BattyUITests/<Class>/<test>` — seconds of
   machine lock when green) plus a manual pass of the pointer behaviors in
   `terminal-pane-requirements.md` for anything in the pane path. Focus and
   click behavior cannot be signed off by compilation or unit tests.

## Symptom → cause table

| Symptom | Likely cause |
|---|---|
| Warning: "Modifying state during view update" | Direct write from `body` / view init / representable update / preference reduction |
| Warning: "onChange(of:) action tried to update multiple times per frame" | An `onChange` write feeds back into its own trigger (or another value in the same cycle) |
| Log spam: a body-adjacent helper's line cycling across all instances (e.g. `chipTitle` over every tab UUID) | Feedback loop, or a write invalidating far too broad a dependency graph |
| `EXC_BREAKPOINT` via `+[NSApplication _crashOnException:]`, all-AppKit stack with `_NSViewLayout` | Observable write or constraint-dirtying/responder AppKit call landed inside the layout pass — read `asiBacktraces` |
| `_postWindowNeedsUpdateConstraints` raised under a hit test or `setCursorForMouseLocation:` in `displayCycleUpdateStructuralRegions` | A non-converging update loop earlier in the same display cycle hit AppKit's pass cap; the hit test is only the last requester. Look for "Future marking … might be ignored" in the log (#0601) |
| First responder changes inside layout on a Tab or Session switch (a `makeFirstResponder` from `NSHostingView.layout`, often to a `SwiftUI.KeyViewProxy`) | A SwiftUI callback hid the first-responder terminal (`isHidden = true`), so AppKit moved the first responder mid-layout. Hide in the action that changed visibility, never from `onChange`/`onGeometryChange` (#0605) |
| Beachball / "app not idle" timeouts in UI tests | Same loop, pre-crash phase |
| A fix silences the warning but clicks / focus / keyboard input break | The write moved to the wrong owner or lost a race it used to win — restructure direction, don't re-time |
| Selection / focus reverts right after a split or new-surface creation | Library churn flipped an observed flag on an untouched object and a handler treated it as intent — look for intent reconstructed from observable effects (`#0230`) |

## Case study: #0229 / #0230

One bug, four lessons:

- **The crash (#0229):** Cmd-Option-arrow wrote `focusedPaneID`
  (model-initiated); the view reacted by calling `makeFirstResponder` from
  `onChange` — inside the layout pass — and the echo handler wrote the model
  again mid-layout. NSException, `_crashOnException`. The decisive evidence
  was `asiBacktraces`, naming SwiftUI's `ObservationGraphMutation` →
  `_postWindowNeedsUpdateConstraints` chain.
- **The loop (#0229):** with two panes, stale focus-retry tasks re-promoted
  the old pane, so model and first responder ping-ponged between *different*
  values. A store-level idempotence guard alone did not stop it (verified:
  crash reproduced with the guard in place).
- **The regression (#0229):** deferring the echo write into a `Task` stopped
  the crash but broke the AppKit-initiated direction — click-to-focus —
  because the deferred write lost the ordering it used to win synchronously.
  Timing fixes trade one undefined behavior for another.
- **The resolution (#0230):** a live trace showed the echo's trigger was
  never trustworthy — libghostty flips `isFocused` on existing surfaces at
  surface creation, so the handler reverted focus after *every* split, and
  the baseline only looked correct because a second echo healed it. The fix
  deleted the inference entirely (intent routed from the click monitor;
  promotion deferred + generation-guarded), and the four click UI tests that
  had been failing for a week — dismissed as "environmental" — went green:
  they had been detecting this bug all along. Three analysis passes argued
  about write *context*; only tracing the trigger's *meaning* found the bug.
