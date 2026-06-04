# SwiftUI + Observation state-mutation rules

Binding rules for any change that writes `@Observable` / `@State` properties
or calls AppKit from SwiftUI-driven code. These exist because violating them
produces *undefined behavior* — not a compile error, not a reliable crash,
but timing-dependent loops, dropped updates, and AppKit NSExceptions that
surface far from the offending line. Issue `#0229` is the canonical case
study; it is summarized at the bottom so the failure modes stay concrete.

If a change touches focus, selection, or any model property that both views
*read* and view-driven callbacks *write*, read this whole document first.

## The core invariant

**View update must be pure.** While SwiftUI is evaluating bodies, diffing,
or laying out, no code may mutate observed state. Mutation belongs to event
handlers (button actions, menu commands, NSEvent monitors), `Task` bodies,
and other code that runs *between* update transactions — never to code that
runs *as part of* one.

What counts as "part of the update" is broader than `body`:

- `body` itself and every computed property it calls
- view `init`s (SwiftUI creates views during diffing)
- `onChange(of:)`, `onAppear`, `onGeometryChange` actions — these run inside
  the current transaction, before the next render
- anything those callbacks call **synchronously** — including AppKit calls
  whose side effects flip `@Observable` properties (see next section)

The runtime warning "Modifying state during view update, this will cause
undefined behavior" is the explicit form of this violation. The implicit
forms are worse because there is no warning: the mutation happens inside a
synchronous call chain that *started* in the update, and nothing flags it.

## Why AppKit interop makes this hard in Batty

On macOS, `NSHostingView` processes SwiftUI updates inside `-[NSView layout]`.
That means an `onChange` action can be executing **inside AppKit's constraint
layout pass** (`_NSViewLayout`). Two consequences:

1. **Never call layout-re-entrant AppKit APIs synchronously from
   SwiftUI-driven callbacks.** `makeFirstResponder`, `NSView.frame` writes,
   `addSubview`, window operations — each can re-enter layout or dirty
   constraints mid-pass. AppKit raises an `NSException`
   (`_postWindowNeedsUpdateConstraints` mid-`_NSViewLayout`), and
   `+[NSApplication _crashOnException:]` turns it into `EXC_BREAKPOINT`.
   The crash stack shows only AppKit frames; the *thrown exception's*
   backtrace (`asiBacktraces` / `lastExceptionBacktrace` in the `.ips`)
   is where the SwiftUI → constraints chain is visible. Look there first.

2. **AppKit side effects can flip `@Observable` properties synchronously.**
   `makeFirstResponder` → `becomeFirstResponder` → libghostty focus delegate
   → `TerminalViewState.isFocused = true`. If a SwiftUI callback observes
   that flip and writes more model state, the write lands mid-layout — the
   implicit form of the core-invariant violation.

## Observation semantics you must design around

- **Every write notifies, including equal-value writes.** `@Observable` has
  no equality dedupe; re-assigning the same value to `focusedPaneID` still
  fires `withMutation` and re-invalidates every dependent view. Writes that
  can re-assert an unchanged value must be guarded (`if x != newValue`) at
  the *store* level, not left to call-site discipline.
- **Every dependent view re-evaluates on every write.** A hot write path
  multiplies across all observers. The diagnostic signature of a feedback
  loop is log spam from body-adjacent code cycling through all instances
  (in `#0229`: `TabTitleFormatter.chipTitle` cycling over every tab UUID,
  forever).
- **Loops form across layers, not within one function.** The dangerous shape
  is a cycle: model write → view update → AppKit side effect → observable
  flip → callback writes model. Each individual hop looks reasonable. Before
  adding any write to such a path, draw the full cycle and identify what
  breaks it deterministically.

## Two-way model ↔ AppKit sync needs a single authority

When the same fact lives in two places — e.g. *which pane is focused* exists
as `SplitTree.focusedPaneID` (model) and `NSWindow.firstResponder` (AppKit)
— every sync path must declare its direction, and the round trip must be
**dead-ended**, not damped:

- **Model-initiated** (keyboard command writes model, view reacts, AppKit
  follows): the AppKit side effect will echo back through the observable
  flip. The echo handler must *not* write the model again — the model
  already holds the value. Suppress the echo structurally (reentrancy
  token / "programmatic change in flight" flag), don't rely on value
  equality alone: with two panes the echoes alternate between *different*
  values and an equality guard never trips.
- **AppKit-initiated** (user clicks, NSEvent monitor promotes first
  responder): the model must be brought in line. This runs during event
  dispatch — *outside* any update transaction — so a synchronous model
  write here is correct and required for the interaction to feel direct.

**`Task { @MainActor }` is not a safety device.** Hopping a write to "later"
moves it out of the current transaction but also reorders it against every
other queued main-actor job — retry ladders, other echoes, user input. In
`#0229` exactly such a hop silently broke click-to-focus. If a write is
illegal where it happens, restructure *which code writes* (direction +
suppression), don't change *when* it writes.

## Checklist before touching a state-flow path

1. List every property the change writes, and the exact callback context
   each write runs in (event handler? `onChange`? inside a synchronous
   AppKit call chain?).
2. List who observes each written property, and what *they* do on
   invalidation. If any observer's reaction can write state, you have a
   potential cycle — name the dead end.
3. Grep the `.ips` of any related crash for `asiBacktraces` before trusting
   the faulting-thread stack.
4. Verify with the *minimal* targeted UI tests
   (`scripts/run-ui-tests.sh BattyUITests/<Class>/<test>` — seconds of
   machine lock when green), plus a manual pass of the pointer behaviors in
   `terminal-pane-requirements.md` for anything in the pane path. Focus and
   click behavior cannot be signed off by compilation or unit tests.

## Symptom → cause table

| Symptom | Likely cause |
|---|---|
| Runtime warning "Modifying state during view update" | Direct write from `body` / view init / computed property |
| Log spam: body-adjacent logging cycling through all instances | Observable feedback loop (equal-value writes or cross-layer cycle) |
| `EXC_BREAKPOINT` via `+[NSApplication _crashOnException:]`, all-AppKit stack with `_NSViewLayout` | `@Observable` write or layout-re-entrant AppKit call landed inside the layout pass; read `asiBacktraces` in the `.ips` |
| Beachball / event loop saturated, app "not idle" in UI tests | Same loop, pre-crash phase |
| Interaction (click, key) stops changing selection after a "safe" refactor | A write was deferred or suppressed on the path that interaction depends on |

## Case study: #0229

One bug, three lessons:

- **The crash:** Cmd-Option-arrow wrote `focusedPaneID` (model-initiated),
  the view reacted by calling `makeFirstResponder` from `onChange` — inside
  the layout pass — and the echo handler wrote the model again mid-layout.
  NSException, `_crashOnException`.
- **The loop:** the echo write re-asserted values; with two panes, stale
  focus-retry tasks re-promoted the old pane, so model and first responder
  ping-ponged between *different* values. An idempotence guard alone did
  not stop it (verified: crash reproduced with the guard in place).
- **The regression:** deferring the echo write to a `Task` stopped the crash
  but broke the AppKit-initiated direction — click-to-focus — because the
  deferred write lost a race it used to win synchronously. Timing fixes
  trade one undefined behavior for another; only structural direction +
  suppression fixes the class.
