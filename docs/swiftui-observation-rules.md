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

**Always forbidden to write observed state from** (these run during
reconciliation/layout, unconditionally):

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
| View only reads an observable passed from a parent (`PaneView`'s `pane: PaneRuntime`, `tree: SplitTree`) | plain `let` property |
| View needs bindings into an observable, or mutates its fields directly | `@Bindable` |
| App-wide store/service (`AppStateStore`) | `@Environment` |
| Caches, delegates, closures, pending `Task`s, timers inside an `@Observable` type | `@ObservationIgnored` — implementation details must not invalidate views |
| Hot-path store mutators that callers may re-assert (`AppStateStore.focusPane(id:)`) | make the API idempotent at the store (`if x != newValue`), never rely on call-site discipline |

`@State` stays `private`. Avoid `ObservableObject` / `@Published` /
`@StateObject` / `@ObservedObject` / `@EnvironmentObject` except when
bridging legacy or third-party code.

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
every sync path must declare a direction, and the echo must be **dead-ended
structurally**:

- **Model-initiated** (keyboard command writes model → view reacts → AppKit
  follows): the AppKit side effect will echo back through the observable
  flip. The echo handler must not write the model again — it already holds
  the value. Suppress the echo with a programmatic-change token, ownership
  flag, or explicit source check. **Equality guards at the store boundary are
  required but not sufficient**: with two panes, echoes alternate between
  *different* values and an equality guard never trips (verified in `#0229`).
- **AppKit-initiated** (user clicks; `TerminalClickFocusMonitor` promotes
  first responder): the model must follow. This runs during event dispatch —
  outside any update transaction — so a synchronous model write here is
  correct and *required*; the interaction depends on winning that ordering.

Choose one authority per fact, write down the direction of each path, and
identify which mechanism kills the echo before merging.

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
   what context? Event-origin or layout/focus/geometry-origin?
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

## Case study: #0229

One bug, three lessons:

- **The crash:** Cmd-Option-arrow wrote `focusedPaneID` (model-initiated);
  the view reacted by calling `makeFirstResponder` from `onChange` — inside
  the layout pass — and the echo handler wrote the model again mid-layout.
  NSException, `_crashOnException`. The decisive evidence was
  `asiBacktraces`, naming SwiftUI's `ObservationGraphMutation` →
  `_postWindowNeedsUpdateConstraints` chain.
- **The loop:** with two panes, stale focus-retry tasks re-promoted the old
  pane, so model and first responder ping-ponged between *different* values.
  A store-level idempotence guard alone did not stop it (verified: crash
  reproduced with the guard in place) — only structural echo suppression
  kills this class.
- **The regression:** deferring the echo write into a `Task` stopped the
  crash but broke the AppKit-initiated direction — click-to-focus — because
  the deferred write lost the ordering it used to win synchronously. Timing
  fixes trade one undefined behavior for another.
