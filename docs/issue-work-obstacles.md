# Obstacles that stop issue work

A record of what has actually halted or reversed work on issues in this
project, written from the 2026-08-21/22 sessions that landed `#0301`'s four
non-terminal Pane kinds (`#0304`, `#0305`, `#0313`, `#0314`), the GUI
affordance `#0331`, and the CLI relaunch fix `#0361`.

This is not a list of bugs. It is a list of **things that made work stop,
stall, or have to be redone** — and, where the cause is structural, what
would remove it. Each entry cites the issue that demonstrates it.

---

## 1. Approval gates with no one assigned to ask

**Cost: ~2 weeks of four issues sitting `in-progress`.**

`#0304`, `#0305`, `#0313`, and `#0314` each completed phase 1 (design) on
2026-08-08 and then stopped dead. Every one of them recorded the same
sentence: *"Phase 2 has not started and must not start until the user
approves."* The gate worked exactly as designed. What was missing was any
mechanism that surfaced "four issues are waiting on you" to the person
holding the approval.

The design-first gate is correct and should stay. The failure mode is that a
blocking gate **with no owner for the ask** is indistinguishable from
abandoned work.

**Remedy:** when an issue's status depends on a human decision, the issue
must name who owes the decision and the orchestrating session must surface
the queue. `resolved`-blocked-on-approval and `in-progress` should not look
the same from outside.

---

## 2. Scope drawn so each issue is individually complete and collectively unusable

**Cost: four view kinds shipped that the user could not reach.**

`#0301` scoped its children as *"creatable and closable from the `batty`
CLI."* None of the four approved design docs mentioned menu placement. So
all four issues shipped correct, reviewed, and tested — and the feature was
unreachable from the app. The user's report was blunt: *"I do not see any new
actions added to the file menu or anywhere else."*

The GUI gap had already been filed as `#0331` on 2026-08-09, from the user
noticing the same asymmetry. It was left open while its four dependencies
were worked, because it was nobody's issue.

**Remedy:** when an umbrella's children each disclaim a shared surface,
that surface is not out of scope — it is unassigned. Check for it before
declaring the umbrella's children done, and pull the affordance issue into
the same batch.

---

## 3. A tooling bug that blocks diagnosis of other bugs

**Cost: `#0362` could not be investigated at all.**

`#0361` made every `batty` invocation launch a duplicate app instance. The
one command that would have answered `#0362` in a second —
`batty list panes --json` — routes through the exact failing path. Both the
investigating agent and the orchestrator had to decline to run it, because
running the diagnostic would corrupt the state being diagnosed and spawn
processes on the machine the user was working in.

`#0362` is now formally blocked on `#0361` and says so.

**Remedy:** treat "the tool used to inspect state" as tier-zero
infrastructure. When it breaks, it preempts the queue — not because it is
the worst bug, but because it is the bug that hides the others.

---

## 4. Documentation that is confidently wrong

**Cost: the same defect implemented four times in parallel.**

`docs/pane-view-lifecycle.md` §5 asserted that `closePane` was *"the single
choke point every close path already funnels through."* It was not.
`removeSession`, `closeTab`'s pane-removal branch, `RootWindowView.windowWillClose`,
and `applicationWillTerminate` all bypassed it.

Four branches, developed independently, each read that sentence and each
wired teardown only to `closePane`. For `#0314` that leaked a 1 Hz sampler.
For `#0313` it orphaned two `lms log stream` subprocesses onto launchd on
every window close.

A false premise in a binding doc does not fail once. It fails once per
reader, and parallel work multiplies it.

**Remedy:** correct the doc **in the same commit** as the code fix — which
`#0314` did. A doc asserting an invariant should cite the enumeration that
proves it, so the claim can be re-checked rather than trusted.

---

## 5. Green test suites that conceal the failure they were written for

**Cost: two leaks shipped past review; one bug survived three rounds.**

Three separate instances, all found only because a reviewer mutated the code
instead of reading it:

- **`#0313` teardown.** Commenting out both `process.terminate()` calls left
  **all 1092 tests passing** and 12 orphan processes on the machine. The
  tests asserted `lifecyclePhase == .tornDown` — a state flag, not the
  resource.
- **`#0313` post-rebase.** Stripping the injected inert factory from three
  test sites orphaned **exactly six `lms log stream` processes** while the
  suite still reported 1148 passing.
- **`#0305` argv parser.** Two hand-built `KERN_PROCARGS2` fixtures both
  placed the zero-length argument at index ≥ 1 — never at index 0, the one
  position the parser was blind to. The fixtures encoded the author's own
  misreading of the format, so they passed while the bug was live. It took
  **three rounds** and a reviewer spawning a real process with a secret in
  its environment to close.

The `#0305` case is the sharpest: a fixture is only evidence if it was
derived from the real thing. Hand-built fixtures test the author's mental
model.

**Remedy, now standing practice here:** prove a test bites by breaking the
invariant and confirming failure. For resource lifecycle, assert on the
**resource** (`process.isRunning`, a counter, `pgrep`) and never on a state
enum. Derive fixtures from real captured data.

---

## 6. One behavior dispatched from several hand-copied switches

**Cost: the same omission found in three consecutive review rounds (`#0315`),
and a standing trap for every new action since.**

`ShortcutAction` is dispatched by three independently maintained switches:
`BattyCommands`, `BattyShortcuts` (an `NSEvent` monitor that bypasses
SwiftUI's `.disabled`), and `CommandPaletteView.dispatch`. `#0315`'s review
found an ungated path in round 1, another in round 2, and a third in round 3.

`#0331` had to add eight actions across all three. It came out clean only
because the trap was written into the brief up front — and because two of
the three switches have no `default:` arm, so the compiler enforces them.
The **menu's** kind list is hand-written and uncovered, so a ninth
`PaneContentKind` would fail loudly in two places and silently in one.

**Remedy:** exhaustive switches with no `default:` wherever a list must stay
in sync, and drive hand-written UI lists from `allCases`.

---

## 7. Persistent machine state that silently changes what you build

**Cost: repeated; caught three times in one session.**

`Configuration/Active.xcconfig` selects Prod vs Beta and is gitignored. The
Beta scheme's pre-action rewrites it **after** `xcodebuild` has resolved
settings, so it only takes effect on the *next* invocation. Anything that
builds Beta without restoring it leaves the environment switched, and the
next `./build.sh` builds the Beta product **while reporting Prod**.

Found flipped mid-session with no build having been intentionally run
against Beta. Related: `Batty.xcodeproj/project.pbxproj` and the shared
schemes drift dirty as residue and must be discarded, never committed.

**Remedy (already in `AGENTS.md`, restated because it kept happening):**
check `Active.xcconfig` before and after every build; treat a dirty
`project.pbxproj` as residue.

---

## 8. Identity that is ambiguous on a developer machine

**Cost: the `#0361` outage, and it got worse the harder we worked.**

Ten bundles claim `co.sstools.Batty` on this machine: six Xcode DerivedData
Debug builds, `/Applications/Batty.app`, a local release build, and two
stale `/Volumes` registrations for unmounted DMGs. `open -b <id>` and
`runningApplications(withBundleIdentifier:)` cannot tell them apart.

**Every `./build.sh` run adds another claimant.** The orchestration
that landed these issues ran builds across six worktrees, so the debugging
session actively worsened the bug it was debugging.

A third mechanism compounds it: libghostty puts the app bundle's
`Contents/MacOS` on the `PATH` of every shell Batty spawns, and on a
case-insensitive volume `batty` there **is** the app's main executable
(`#0364`). Typing `batty` in a Batty terminal can exec a fresh
`NSApplication` with no LaunchServices, no dedupe, and no CLI code involved.

**Remedy:** resolve by absolute bundle path, never by identifier
(`#0361`, done). Give Debug builds a distinct bundle id so they cannot
compete (open, needs a `Configuration/` decision). Fix the `PATH`
collision (`#0364`).

---

## 9. Parallel work that converges on the same shared code

**Cost: four independent implementations of one piece of wiring.**

Running `#0304`, `#0305`, `#0313`, and `#0314` concurrently in separate
worktrees was the right call for wall-clock. But all four independently
wired `WindowRuntime`'s show/hide/close lifecycle, three added their own
per-kind `PaneRuntime` property, and three invented a CLI flag with its own
wire field.

Reconciling took a full extra round: reviewers arbitrated each dimension on
merit (`#0314`'s property name and unconditional calls, `#0313`'s exhaustive
construction switch, `#0305`'s corrected `allPids()`), one branch landed the
composite, and the other three rebased onto it.

It also produced a **silent** trap: `#0304` hardcoded a factory for
`.gitStatus`, and merged naively alongside `#0313`'s injectable factory it
would have ignored an explicit inert factory and constructed a real
FSEventStream — with the compiler and the tests both silent.

Two genuine wins came out of the same collision, though: each branch had the
correct version of something another got wrong. `#0305` found `#0314`'s
`listAllPIDs` enumerating **62 of 716** processes; `#0314` had the correct
mach-tick conversion `#0305` was missing by a factor of 42.

**Remedy:** identify the shared seam **before** fanning out and land it
first, or accept a reconciliation round as part of the plan. Cross-review
between parallel branches is worth its cost.

---

## 10. Wire formats that accrete one field per feature

**Cost: nearly locked in, caught one issue before it was expensive.**

`#0304` added `PaneSplitRequest.path`; `#0305` added `processStatusPid`.
Two more kinds were queued behind them. Two reviewers independently flagged
that a flat field per kind was the wrong endgame, and consolidation landed
as a single `viewOptions: [String: String]?` while only one had merged.

Wire additions are hard to walk back. This one was cheap only because it was
caught while a single consumer existed.

---

## 11. Code that is untestable by structure

`AppConnectDance`, `AppBundleLocator`, `RunningAppChecker`, and
`SessionCommand` all live in the `batty` executable target. `BattyKitTests`
depends only on `BattyKit`. The injection seams added during `#0361` are
therefore not untested by oversight — they are **unreachable from any test**
(`#0365`).

This is a target-layout decision masquerading as a test-coverage gap, and it
is worth naming as such so it is fixed once rather than worked around per
issue.

---

## 12. Guidance that contradicts itself

`AGENTS.md` summarises the filer subagent as pinned to "the top available
model." `issues/Issues.md:150` pins it to Opus 5 with an explicit standing
user directive dated 2026-08-09: *"Do not use Fable."* `AGENTS.md` states
that `Issues.md` wins for issue-tracker workflow, so the summary is simply
stale — but the summary is what gets read first.

Several issues this session were filed with the wrong model before a filer
subagent flagged the conflict itself rather than silently complying.

**Remedy:** a summary that can drift from its source should say *"see
`issues/Issues.md`"* rather than restate the rule.

---

## 13. Bookkeeping deferred until it is archaeology

Six issues were resolved and squash-merged without their required
`## Work log` cost rows, and five without a `**Closed**` row.
`issues/Issues.md` puts that on the orchestrating session **after each
round**. Deferred to the end, it becomes transcript forensics — matching
agent JSONL files to issues, deduping by `requestId`, attributing resumed
agents to rounds.

Recorded per round it is one line. The cost data is the only thing that
makes the review-gated workflow's expense visible to the person paying for
it, which is precisely why it should not be the step that gets skipped.

---

## What generalises

1. **A blocking gate needs a named owner**, or it reads as abandonment.
2. **Ask what the user will be able to do** when every child issue closes.
   Correct-and-unreachable is not done.
3. **Tools that inspect state preempt the queue** when they break.
4. **A wrong doc fails once per reader**, and parallel work multiplies it.
5. **Green is not evidence.** Mutate the code, assert on the resource,
   derive fixtures from reality.
6. **Duplication of a list is a defect**, not a style question.
7. **Ambiguous identity gets worse the more you build.**
8. **Parallelism trades reconciliation for wall-clock** — plan the trade.
9. **Record cost while you have it**, not when it becomes archaeology.
