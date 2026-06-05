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
  `onChange(of: tab.terminal.bellCount)` writing a bell tick is fine — the
  flip comes from a libghostty event, the write doesn't feed back into
  anything that re-fires it.
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

- **Every write notifies — equal-value writes included.** `@Observable` has
  no equality dedupe; re-assigning the same `focusedPaneID` still fires
  `withMutation` and re-invalidates every dependent view. Hence the
  store-level idempotence rule above.
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
2. **AppKit side effects flip `@Observable` properties synchronously.**
   `makeFirstResponder` → `becomeFirstResponder` → libghostty focus delegate
   → `TerminalViewState.isFocused = true`. A handler observing that flip runs
   inside the promoter's context — the implicit core-invariant violation.

**Debugging:** the crash's faulting-thread stack shows only generic AppKit
display-cycle frames. The real chain lives in the *thrown exception's*
backtrace — `asiBacktraces` / `lastExceptionBacktrace` in the `.ips`. Read
that first.

**Sanctioned exceptions** (documented in `view-hierarchy.md`; do not add new
ones): `TerminalPlaceholderView.body`'s lazy `terminalView(for:)` performs a
one-time `addSubview` into the persistent host on first mount, and terminal
placement flows as plain frame writes on the frame-based (not Auto Layout)
`TerminalHostView` via `TerminalHostStore.updatePlacements(_:)`. Both are
bounded by design — first-mount-only and frame-only respectively. Anything
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
  (`TerminalSurfaceFocuser`).
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
   (`scripts/run-ui-tests.sh BattyUITests/<Class>/<test>` — seconds of
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
