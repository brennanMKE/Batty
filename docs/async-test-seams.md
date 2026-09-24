# Deterministic async test seams

`AGENTS.md` "Asynchronous tests (binding)" forbids making a unit test pass
by waiting — no `Task.sleep`/`Thread.sleep`/`usleep`/`asyncAfter`,
poll-until-deadline loops, or elapsed-time assertions. #0427 found about 84
sites in `BattyKit/Tests/` that broke that rule, spread across periodic
samplers, debounces, subprocess teardown, and app-level deferred work. #0428
built the shared pieces the #0427 children route through instead of each
inventing their own. This doc is where they live and how to use them.

## 1. Injected clock — `SchedulingClock`

`BattyKit/Sources/BattyKit/Runtime/SchedulingClock.swift` defines:

```swift
public protocol SchedulingClock: AnyObject, Sendable {
    nonisolated var now: Date { get }
    nonisolated func sleep(for duration: Duration) async
}

public final class SystemClock: SchedulingClock { ... } // the real clock
```

Route a periodic or delayed loop through it instead of `Task.sleep`/`Date()`
directly:

```swift
private let clock: SchedulingClock
// init(..., clock: SchedulingClock = SystemClock()) — see below

samplingTask = Task { [weak self] in
    while true {
        await clock.sleep(for: interval)
        guard let self, !Task.isCancelled, self.lifecyclePhase == .active else { return }
        self.performSample()
    }
}
```

**Production default.** `clock: SchedulingClock = SystemClock()` — a
defaulted init parameter whose default is the *real* clock. Production
never overrides it: `ProcessStatusPaneContent` is reached only through
`SplitTree.makePane`, which constructs it with no `clock:` argument at all
(`SplitTree.swift`), so production genuinely relies on the default — one
fresh `SystemClock()` per content instance, since Swift re-evaluates a
default argument at each call site rather than sharing one. This is not the
#0359 mistake: #0359's dangerous default (`tabLookup = { _ in nil }`) was a
value that silently *disabled* a feature if a caller forgot to override it.
`SystemClock` is the opposite — relying on the default in production still
gets correct, real-time behavior; a test that forgets to override it gets
slow, real-time waits it will notice immediately as a flake, not silent
wrongness. Every test call site still injects the fake explicitly.

**Test fake — `TestClock`** (`BattyKit/Tests/BattyKitTests/TestClock.swift`,
`nonisolated`/`@unchecked Sendable`, lock-guarded, not `@MainActor`; not
`public`, test-target-internal). Time never passes on its own:

```swift
let clock = TestClock()
// ... construct the production type with `clock:` ...
let task = Task { await clock.sleep(for: interval); ... }
#expect(await clock.waitForSleepers(1))            // real "a sleeper just registered" event
let fired = await clock.advance(by: .seconds(1))   // fires sleepers already due; returns how many
clock.pendingCount                                 // 0 once nothing is scheduled
```

`TestClock` is lock-guarded and thread-safe on its own terms rather than
actor-isolated, so registration and firing never depend on which executor
or priority a caller runs on. `advance(by:)` snapshots and removes every
currently-due sleeper in one locked step before resuming any of them, so it
only ever fires sleepers already registered at the instant it was called —
a sleeper a resumed remainder re-registers during the same call can never
also fire in it. It returns how many sleepers it actually fired, so a
caller expecting more ticks from one call gets a wrong number back, not
silence. `waitForSleepers(_ count:)` is the real registration event:
resumed synchronously, under the same lock, the instant `count` sleepers
are registered, and returns whether the threshold was actually reached (so
a test can tell a real registration apart from the hang-guard `bound`
expiring). The pattern for a periodic loop spanning several ticks is
`advance(by:)` then `await clock.waitForSleepers(1)`, once per tick — this
works regardless of priority or how much async work sits between one sleep
and the next.

`sleep(for:)` wraps its continuation in `withTaskCancellationHandler`, so
cancelling the caller removes and resumes its sleeper immediately —
matching `SystemClock`'s real `Task.sleep`, which wakes promptly on
cancellation instead of waiting out its duration — and `pendingCount`
reflects that the instant `Task.cancel()` runs, not eventually.
Registration itself also checks `Task.isCancelled` under the same lock the
cancellation handler uses, so a task that is already cancelled when it
calls `sleep(for:)` (or becomes cancelled in the narrow window between the
handler installing and registration taking the lock) still resumes
immediately instead of parking forever — both paths take the same lock, so
exactly one of them ever resumes a given sleeper.

See the type's own doc comment for the full detail, and `TestClockTests.swift`
for direct coverage: a lower-priority sleeper, real async work between
ticks, several concurrent sleepers, and cancellation — including an
already-cancelled task and cancellation racing registration, run many times
to exercise the narrow interleaving window. Virtual time is tracked as
exact integer nanoseconds rather than `Date`/`Double`, since repeated
`Double` addition can drift a deadline comparison off by a tick.

**Proving use:** `ProcessStatusPaneContent`'s sampler loop, and
`ProcessStatusPaneLifecycleWiringTests.aHiddenProcessStatusPaneDoesNotKeepSampling`
— hides the pane, asserts `pendingCount == 0` synchronously (cancellation
already ran), then advances many sampling intervals and asserts no new
sample — verified to fail (M5) when both the sampler loop's
`Task.isCancelled` check and its `lifecyclePhase == .active` guard are
removed together (removing only one is still caught by the other, so the
mutation that actually exercises this test removes both; the mutant loop is
allowed to busy-spin once cancelled, since `register` resumes an
already-cancelled task immediately).

## 2. Shared child-process readiness — `ChildProcessReadiness`

`BattyKit/Tests/BattyKitTests/ChildProcessReadiness.swift` (test-only).
Awaits a child's "ready" signal as an event instead of blocking on
`availableData` with no bound, or polling a plain file with `Thread.sleep`:

```swift
// The test owns the child's stdout:
let ready = await ChildProcessReadiness.waitForData(on: pipe, bound: 5)

// The content's own factory owns stdout (a Pipe would race its handler):
ChildProcessReadiness.makeFIFO(at: path)   // before spawning the child
let ready = await ChildProcessReadiness.waitForFIFOReady(at: path, bound: 5)
```

`bound` is a **hang guard only** — it resolves `false` on expiry, and that
is never how the wait normally succeeds. `ResumeOnce<T>`
(`BattyKit/Tests/BattyKitTests/ResumeOnce.swift`) guarantees the readability
handler and the timeout, which fire from different queues, resume the
continuation exactly once between them; `TestClock.waitForSleepers` and
`TestTeardownReapGate.waitForParkedWaiter` (§1, §3) share the same type.
`ResumeOnce.setOnResumed(_:)` must be called before the instance is
published to any second party (installed as a handler, inserted into a
waiter registry, scheduled as a timeout) — every caller here builds whatever
the cleanup closure needs to reference first, wires it via `setOnResumed`,
and only then publishes the instance, so a concurrent `resume()` can never
observe the wiring half-done.

**Proving uses:** the pipe variant in `PendingTeardownReapRegistryTests`
(replacing its local `waitForReady(_ pipe:)`); the FIFO variant in
`LMStudioSIGTERMIgnoringFixture.waitForReadyFile` (replacing a
`Thread.sleep`-polled plain ready file). Direct coverage in
`ChildProcessReadinessTests.swift`.

## 3. Reap gate — `TeardownReapGate`

`BattyKit/Sources/BattyKit/Runtime/TeardownReapGate.swift`. Proves "returns
without blocking" *structurally* instead of by timing the call:

```swift
public protocol TeardownReapGate: Sendable {
    nonisolated func waitUntilOpen() async
}
public final class OpenTeardownReapGate: TeardownReapGate { ... } // production default, always open
```

Production relies on this default the same way it relies on `SystemClock()`
(§1): `GitStatusPaneContent.init` defaults `scanner:` to
`ProcessGitStatusScanner()` with no arguments, and `SplitTree.makePane`
constructs `GitStatusPaneContent` with only `directoryPath:` — no
production call site overrides `reapGate:`.

A conformer that defers work to a `Task.detached` (e.g.
`ProcessGitStatusScanner.scheduleTeardownReap`) awaits the gate before doing
that work:

```swift
let task = Task.detached { [weak self] in
    await gate.waitUntilOpen()
    Self.reapAfterTerminate(process, bound: bound, label: label)
    ...
}
```

A test injects `TestTeardownReapGate()` (`BattyKit/Tests/BattyKitTests/TestTeardownReapGate.swift`)
held closed, triggers the deferred path, and **awaits
`gate.waitForParkedWaiter()` before asserting anything**: a closed gate only
proves something if a caller is actually parked on it, not merely that the
gate itself hasn't been opened. `waitForParkedWaiter(_:bound:)` returns
whether a waiter actually parked (hang-guard bounded, like every other seam
here), so `#expect(await gate.waitForParkedWaiter())` fails the test outright
if nothing ever parks — a closed-but-unparked gate proves nothing, and this
is what makes that distinction load-bearing rather than assumed. Once it
confirms a real waiter is parked, asserting the child is still alive is
airtight regardless of machine speed — no `elapsed < .milliseconds(50)`
guess needed. The test then calls `gate.open()` (kept in a `defer` too, so a
waiter is never leaked if an earlier assertion fails first) and awaits the
conformer's own `awaitPendingTeardownReapsForTesting()`.

**Proving use:**
`ProcessGitStatusScannerTests.terminateAndWaitBrieflyReturnsImmediatelyEvenWhenTheProcessIgnoresSIGTERM`
— verified to fail under all three mutations tried: `waitUntilOpen()` made
a no-op, the `await gate.waitUntilOpen()` call removed from
`scheduleTeardownReap` entirely, and the SIGKILL escalation in
`reapAfterTerminate` skipped. Direct coverage, including a closed gate
parking its waiter until `open()`, in `TestTeardownReapGateTests.swift`.

## 4. Completion-signal conventions

Four shapes cover every #0427 site. Pick the one that already matches how
the production code exposes its work — never invent a fifth without adding
it here first.

| Shape | Use when | Example |
|---|---|---|
| Returned/exposed `Task` | Production starts a one-shot unit of async work | `AppStateStore.scheduleSummarization`'s summarization `Task` (#0433) |
| Callback / continuation | Production already has a callback, or a plain optional closure is the cheapest new seam | `AppStateStore.terminateHandler`, `Process.terminationHandler`, `GitStatusPaneContent.onScanResultHandledForTesting` (#0430) — fired once per `handleScanResult` call; the bounded wait for a specific count lives entirely in the test target (`ResumeOnce` + a cancellable `DispatchWorkItem`, matching `ChildProcessReadiness`), never in production |
| `AsyncStream` of events | A test awaits a *count* of repeated events and no single-closure slot is enough (more than one concurrent subscriber, or the events must be replayed) | LM Studio line-applied/poll-applied (#0429) |
| Injected clock/scheduler | The wait is purely time-based (a poll interval, a debounce, a sampling cadence) | §1 above |

For every shape:

- **Who creates it.** The production type itself, at the point it starts
  the work — never the test reaching in and fabricating one. A test-only
  accessor (`…ForTesting`, `internal` not `private`) exposes it to
  `BattyKitTests` via `@testable import`.
- **Test-only vs. always-on.** Exposing a `Task` or wiring a callback that
  already exists in production (`terminateHandler`) is fine to leave
  always-on — it changes nothing about when or whether the work runs, only
  who else can observe it finishing. Reach for a `…ForTesting` seam instead
  when *no* completion signal exists at all in production and adding one
  isn't free (e.g. an `AsyncStream` nobody would otherwise subscribe to).
- **The hang-guard bound.** Every awaited completion still needs an upper
  bound so a genuine regression fails fast instead of hanging the suite —
  see `CrossWindowBehaviorTests.removeWindowOnLastWindowEventuallyTerminates`
  for the callback-shape pattern: a `CheckedContinuation` resumed from the
  real callback, raced against a `Task.sleep`-based timeout that also
  resumes it (a `resumeOnce()` guard makes exactly one of the two count),
  so a regression that drops the callback entirely fails with a clear
  message after the bound instead of hanging forever. `ChildProcessReadiness`'s
  `bound` and `TestClock.waitForSleepers`'/`TestTeardownReapGate
  .waitForParkedWaiter`'s `bound` follow the same rule: the bound is
  failure-only, never the success path.
- **Never continue past a failed readiness wait as if it had succeeded.**
  `#expect(await clock.waitForSleepers(1))` *records* a `false` result but
  still lets the test carry on — and the rest of the test was written
  assuming the sleeper is there: `advance` fires nothing (nothing was
  registered yet to fire), a sleeper that then registers late parks
  instead, and a later `await task.value` blocks on a sleeper nothing will
  ever release. Use `guard` instead of a bare `#expect`, and make the
  failure branch actually release whatever the rest of the test would
  otherwise wait on:
  ```swift
  guard await clock.waitForSleepers(1) else {
      Issue.record("waitForSleepers(1) never reached its threshold")
      task.cancel()   // TestClock.sleep(for:) resumes on cancellation either way
      return
  }
  ```
  `TestClock`'s sleepers can always be released by cancelling the task that
  registered them, whether or not they'd actually registered yet.
  `TestTeardownReapGate`'s waiters cannot — `waitUntilOpen()` installs no
  cancellation handler, so the failure branch there must call `gate.open()`
  (and await the parked task) instead of `task.cancel()`. Pick whichever
  release actually applies to the type being waited on; never leave the
  branch as a bare `Issue.record` with nothing released, or the very
  `await` two lines later can still hang.
- **No production behavior change.** A `…ForTesting` accessor reads state;
  it must never gate *whether* production work happens. An injected
  seam's production default must be the real implementation (§1), not a
  test stand-in.

**Proving use (callback shape):**
`CrossWindowBehaviorTests.removeWindowOnLastWindowEventuallyTerminates`
(verified to fail — after its hang-guard bound, with a clear message, not a
hang — if the deferred terminate check's actuation is removed).

## 5. #0427's three "verify" questions

Answered here with evidence so #0429–#0432 can apply them without
re-deriving them.

1. **`posix_spawn` and argv readability.** Does XNU's `posix_spawn` return
   only after the new image's argv/env is set up, so `KERN_PROCARGS2` is
   immediately queryable? **Yes.** Structurally: XNU's exec path
   (`bsd/kern/kern_exec.c`) runs `exec_activate_image()` — which calls
   `exec_copyout_strings()` to lay out argv/envp on the new image's stack,
   the same data `KERN_PROCARGS2` reads back — synchronously as part of
   bringing up the new image, before the spawning thread returns to
   userspace with `posix_spawn`'s result. Verified empirically too, on
   this arm64 host
   (`ProcessInspectorTests.commandLineHandlesARealProcessWithAZeroLengthArgvZeroWithoutLeakingItsEnvironment`,
   its `usleep(50_000)` removed): 4/4 runs passed with zero delay. Owner
   #0431 can delete the sleep (or keep the finding on record if it wants a
   wider sample, including x86_64).
2. **`CLOCK_UPTIME_RAW`.** Is `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`
   exactly `mach_absolute_time()` converted to nanoseconds? **Yes** — this
   is documented, not just observed: `clock_gettime(3)`'s `CLOCK_UPTIME_RAW`
   entry states "the returned value is identical to the result of
   `mach_absolute_time()` after the appropriate `mach_timebase` conversion
   is applied." Verified empirically
   too: taking one `mach_absolute_time()` reading and one
   `CLOCK_UPTIME_RAW` reading back-to-back and comparing
   `Double(mach_absolute_time()) * MachTimebase.nanosecondsPerTick` against
   the raw `CLOCK_UPTIME_RAW` value, 5 such paired reads on this arm64 host
   all agreed to within a single tick's rounding (0-166ns). Owner #0431 can
   compare two `CLOCK_UPTIME_RAW` reads directly with no interval needed.
3. **When `Process.isRunning` flips after a reap.** Once a
   `Process.isRunning`-polling reap loop (`reapAfterTerminate`,
   `drainSynchronously`) returns, has the child already been `waitpid`-ed,
   so `kill(pid, 0)` fails immediately with no extra wait? **Yes**: a
   standalone experiment mirroring `PendingTeardownReapRegistry.reapAfterTerminate`
   exactly (SIGTERM a trap-installing child, run the same poll-then-SIGKILL
   loop, then check `kill(pid, 0)` once with no wait) agreed 10/10 —
   `isRunning == false` and `kill(pid, 0) == -1, errno == ESRCH` held
   together every time. Owners #0430 (`ProcessGitStatusScannerTests
   .terminateAndWaitBrieflyReturnsImmediatelyEvenWhenTheProcessIgnoresSIGTERM`'s
   remaining kill-poll, lines 425-431 at `ba5171d5`) and #0432
   (`PendingTeardownReapRegistryTests`'s `:105-111` kill-poll) can replace
   their polls with a single check. #0428 already did this for
   `PendingTeardownReapRegistryTests.drainSynchronouslyKillsAndReapsARegisteredSigtermIgnoringProcess`'s
   own kill-poll — a forced, minimal side effect of that test becoming
   `async` for the readiness-helper migration (§2), which made its
   `Thread.sleep`-based retry loop illegal to keep as written.
