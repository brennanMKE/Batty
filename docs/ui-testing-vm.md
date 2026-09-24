# UI testing in a Tart VM

Batty's UI tests (`BattyUITests`) run only inside a disposable macOS VM on this host. They
never run on the Mac the user is using. This doc covers why, what runs where, the guards,
the golden image, how to run it, and the first verification run's results and gotchas.

Background and the shared host setup (Tart, the two-guest budget, memory coordination):
`~/Developer/Homelab/cameron/tart-ui-test-vm.md`. The working precedent this runner is
adapted from: `~/Developer/brennanMKE/Curator/docs/ui-testing-vm.md` and
`~/Developer/brennanMKE/Changeover/run-ui-tests-vm.sh`.

## Why a VM

XCUITest's `testmanagerd` bootstraps `XCTAutomationSupport` into **every running GUI app**
it can see through Accessibility, not just the app under test. On 2026-09-12 a UI test run
from an unrelated project (`Changeover`) did exactly that to the user's running **Prod**
Batty and crashed it — `EXC_BAD_ACCESS` in
`-[XCTAutomationSession initWithAccessibilityFramework:dataSource:]` — killing all 38 live
Terminal Sessions (#0409). A Batty UI test run on this same host is the identical hazard
aimed at the user's own terminals, whether or not the crash mechanism is Batty's fault: the
faulting frame is entirely inside Apple's private framework.

A Tart guest is a separate macOS instance with its own WindowServer, its own apps, and its
own TCC database. `XCTAutomationSupport` loads into processes in the *guest's* GUI session
only — on the host, the only new processes are `tart` and Virtualization.framework's VM
service, neither of which is an app a test runner can attach to. Each run uses a fresh
clone that is deleted afterward, so the guest can never accumulate stray permission grants
either.

## What runs where

| On the host (fine) | Only in the guest |
|---|---|
| `./build.sh` (build only) | `./build.sh ui` (delegates here) |
| `./build.sh unit` (`BattyKitTests`) | Anything that drives Batty's UI automatically |
| Running Batty yourself | `xcodebuild ... test` against `BattyUITests` |

**No UI scripting on the host either.** `osascript` / System Events keystrokes go to
whatever app is frontmost, not necessarily the one you meant to drive — never send
synthetic input to the host to test Batty.

## Guards

1. **Host-refusing build phase.** `BattyUITests`' first build phase, *Refuse to build on a
   host Mac* (`Batty.xcodeproj/project.pbxproj`), fails unless
   `sysctl -n kern.hv_vmm_present` is `1`, which is true only inside a virtual machine:

   ```
   error: BattyUITests only builds inside a VM. Run tools/run-ui-tests-vm.sh (see docs/ui-testing-vm.md).
   ```

   The error fires before any test code compiles. Verified two ways: `xcodebuild -workspace
   Batty.xcworkspace -scheme "Batty UI Tests" -destination "platform=macOS" build-for-testing`
   on this host stops at exactly this phase (`kern.hv_vmm_present` reads `0` here); inside
   the guest, the same check reads `1` and the build proceeds — see "First run" below for the
   full run this unblocked.

   **`BattyUITests` was removed from the `Batty (Beta)` and `Batty (Prod)` schemes' Test
   actions** (design choice from #0412's scope item 3): `xcodebuild test` builds every
   Testable listed in a scheme's Test action regardless of `-only-testing` filters — passing
   `-only-testing:BattyKitTests` to `./build.sh unit` still tried to build `BattyUITests` and
   failed at this guard, verified on this host before the split. `BattyUITests` now lives
   only in its own scheme, **`Batty UI Tests`** (Curator's pattern), whose Test action holds
   just that one Testable; `tools/run-ui-tests-vm.sh` is the only thing that invokes it.

2. **`./build.sh ui` routes to the VM runner**, not `xcodebuild` directly. It delegates to
   `tools/run-ui-tests-vm.sh`, which runs the `Batty UI Tests` scheme, and forwards any
   positional test-spec arguments as `-only-testing:<spec>`, matching
   `./build.sh ui BattyUITests/TabRenameTests[/testMethod]`.

3. **`scripts/run-ui-tests.sh` is untouched.** It is restricted (`AGENTS.md`, `scripts/` needs
   explicit user sign-off to change) and `./build.sh ui` no longer calls it. It does **not**
   reach the host guard: it builds with `SCHEME="Batty (Beta)"`, which no longer lists
   `BattyUITests` in its Test action (the scheme split above moved it out), so its
   `build-for-testing` builds only the app plus `BattyKitTests`/`BattyTests` and never touches
   the guarded target. The script instead dies on its own next step — the re-sign of
   `BattyUITests-Runner.app`, which this build never produces — with a "Runner not found"
   style failure. Still safe (nothing under `BattyUITests` builds and nothing launches), but
   the reason is "it fails before it gets that far," not "the guard caught it." It is stale
   and unused. Retiring it — and fixing `scripts/RELEASE.md` step 2, which still tells release
   preflight to run it — is a separate restricted-area issue: **#0421** (filed by the
   orchestrator).

## The golden image

| | |
|---|---|
| Name | `batty-uitest-golden`, stopped, only ever cloned |
| Made | `tart clone changeover-uitest-golden batty-uitest-golden` |
| Created | 2026-09-23 18:27:59 local (`stat -f %SB ~/.tart/vms/batty-uitest-golden`) |
| Guest | macOS 26.6.2 (25G83), Xcode 27.0 (27A266a) at `/Applications/Xcode_27.app` |
| CPU / memory | 6 / 12288 MB (inherited from Changeover's golden) |
| Disk | 140 GB allocated, 73 GB actual per `tart list` (`du -sh` on the VM's directory: 68G — the two differ by rounding, GB vs GiB, plus filesystem overhead) |
| Hardening | Inherited from Changeover's golden: Automation Mode needs no authentication, developer mode on, no screen lock or sleep, SSH refuses every user (`com.apple.access_ssh` empty) |
| Access | `tart exec` only |
| Batty-specific installs | None — the build needs only Xcode and network access for SwiftPM |

Free disk on the host container (`df -h /`, `/` and `/System/Volumes/Data` share one APFS
container so both report the same free space): **69 GiB free as of 2026-09-23**, after the
clone (and after the first full run recorded below). The free space *immediately before* the
clone was not captured when it was made — that happened in an earlier session than this
record — so it's unknown here; a future rebuild of this golden should capture `df -h /`
immediately before `tart clone` to close that gap.

Don't run or modify this image directly, and never touch another project's golden
(`changeover-uitest-golden`, `curator-uitest-golden`, `quartermaster-uitest-golden`,
`switchyard-uitest-golden`). Batty's is its own APFS clone and can diverge if it ever needs
to.

**Rebuilding**, when Changeover's golden is rebuilt (e.g. for a new Xcode):

```sh
tart delete batty-uitest-golden
tart clone changeover-uitest-golden batty-uitest-golden
```

## Running the tests

```sh
./build.sh ui                                          # full BattyUITests suite
./build.sh ui BattyUITests/TabRenameTests               # one class
tools/run-ui-tests-vm.sh                                # same thing, called directly
```

Run it in the foreground of a terminal — a dropped session costs a clone, not a work
session. Results land in `build/ui-tests/<run-id>/`: `xcodebuild.log`, `UITests.xcresult`,
`app-warnings.log`, `crashes/` (any Batty crash reports from the guest), and `tart-run.log`
(the host-side `tart run` output).

### What the runner does, step by step

1. **Preflight.** Tart and the golden image exist. **Stale `batty-uitest-<run-id>` clones
   from killed runs are swept first**, before waiting for a slot below — an orphaned clone
   from a SIGKILLed previous run keeps its `tart run` alive, so Tart still shows it as
   `running`; sweeping it here is what lets that slot ever open, instead of the wait seeing
   a phantom "another VM running" indefinitely. The sweep matches only its own run-id shape
   (`batty-uitest-<YYYYMMDD>-<HHMMSS>-<pid>`), which structurally excludes the golden image
   (the 2026-09-13 Changeover incident this pattern guards against is recorded in the shared
   host doc). A clone whose run-id `<pid>` is still alive is skipped rather than swept — it
   belongs to a concurrent run of this same script, not a stale one (best-effort: a dead
   script's pid can in principle be reused before the sweep runs). Then, **no other VM is
   running** (Apple allows two macOS guests, and every project on this host shares them and
   the RAM — this is the same constraint Changeover/Curator/Switchyard/Quartermaster share).
   If one is running, the runner waits rather than failing immediately: it polls every
   `WAIT_POLL_SECS` (default 30s) for up to `WAIT_FOR_SLOT_SECS` (default 1200s/20min), both
   overridable by environment variable, and fails only if no slot opens within that window
   (`WAIT_FOR_SLOT_SECS=0` keeps the old fail-immediately behavior). Finally, at least 20 GiB
   of disk is free, and enough memory is available, requested through the memory-signal
   protocol (`~/Developer/Homelab/cameron/lm-studio-memory.md`) if the host is short.
2. **Export a clean snapshot of *two* repos, as tar files.** `BattyKit/Package.swift` has
   `.package(path: "../../SlidingTabs")`, a local path dependency that resolves to
   `~/Developer/brennanMKE/SlidingTabs`, a separate git repo outside Batty. `git archive
   HEAD` of Batty alone doesn't include it, so the runner also runs `git archive HEAD` of
   `../SlidingTabs`. Both go into the export as tar files (`batty.tar`, `slidingtabs.tar`),
   **not extracted on the host** — this repo commits a real symlink
   (`.cursor/skills/quest`), and Tart's virtio-fs read-only share cannot pass a symlink
   through it (the same limitation the shared host doc records for copying `Xcode.app` in:
   `ditto`/`cp` through the share fails with "Too many levels of symbolic links"). The first
   run hit exactly this, verified against a real clone — see "First run" below. Extraction
   now happens locally on the guest's own disk, where a local symlink is unremarkable.
   **SlidingTabs is exported at its own `HEAD`, not a pinned revision** — there is no
   `Package.resolved` pin for a local path dependency, so a guest run can build against a
   different SlidingTabs commit than a previous run if that sibling repo has moved. This is
   a known limitation; pinning it (e.g. to a tag, or vendoring a snapshot) is left to a
   follow-up if it ever causes a hard-to-reproduce guest-only failure.
3. **Clone and boot** headless, `--dir=run:"$EXPORT":ro` (read-only).
4. **Confirm the guest is actually virtualized** (`kern.hv_vmm_present == 1`) before trusting
   the host guard's logic inside it.
5. **Extract both tar files locally in the guest**, then select Beta by writing
   `Configuration/Active.xcconfig` directly (`#include "Beta.xcconfig"`) — it's gitignored,
   so `git archive` never carries it, and the scheme's own pre-action only takes effect on
   the *next* `xcodebuild` invocation (#0280), too late for the guest's one build. Confirmed
   working: the guest's log shows `co.sstools.Batty.beta` and `Batty Beta` throughout (open
   question 3, answered — see "First run").
6. **Run `xcodebuild -workspace Batty.xcworkspace -scheme "Batty UI Tests"
   -only-testing:BattyUITests test CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
   DEVELOPMENT_TEAM=`.** The guest has no certificates, so the build is ad hoc signed — per
   #0412's open question 5, this was tried *without* `scripts/run-ui-tests.sh`'s Gatekeeper
   re-sign dance first, and it wasn't needed (open question 5, answered).
7. **Results back.** `tart exec ... tar` streams `xcodebuild.log`, `UITests.xcresult`, an
   `app-warnings.log` (errors/faults/SwiftUI/AttributeGraph messages from the guest's unified
   log), and any `Batty*.ips` crash reports into `build/ui-tests/<run-id>/`, which already
   holds `tart-run.log` (the host-side `tart run` output, written there directly since boot,
   not under the temp export that cleanup deletes).
8. **Cleanup** on `EXIT`, and on `INT`/`TERM`/`HUP` too — zsh does not run an `EXIT` trap when
   killed by an uncaught fatal signal, so each of those three is trapped explicitly and turned
   into `exit <code>`, which does trigger it. Order: bounded-kill the local `tart exec` test
   process if it's still running (kill, then poll `kill -0` for up to ~30s before escalating to
   `KILL` — never an unbounded `wait`), `tart stop --timeout 30` the clone (tart's own bound on
   graceful-then-forceful shutdown, confirmed via `tart stop --help`), bounded-kill the
   backgrounded `tart run` process the same way, release any memory-signal request, `tart
   delete` the clone, then remove the export. `tart run`'s backgrounded status means the shell
   set its `SIGINT` disposition to *ignored* when launching it. Ctrl-C can't be relied on to
   stop it either way — tart handles signals itself, and a background job starts with SIGINT
   ignored regardless of that — so it is killed explicitly rather than left to Ctrl-C. While
   cleanup itself is running, a second `INT`/`TERM`/`HUP` is *ignored*, not left at the default
   disposition, so it can't kill the script mid-`tart stop` and skip `tart delete`. The long
   test step (above) runs backgrounded and `wait`ed rather than as the script's direct
   foreground command, so that a signal during the ~10-minute test phase is handled promptly
   rather than deferred until that command finishes on its own (a zsh quirk when another
   background job — `tart run` — is also alive).

## First run — 2026-09-23

Two blockers surfaced and were fixed before the first clean full run; both are recorded here
because they'll bite again on another host/project doing the same thing.

**Blocker 1 — a pre-existing, unrelated build break on `main`.** Before any #0412 work
landed, `./build.sh` already failed on this host: `BattyKit/Sources/batty/AppServiceClient.swift`
and `SessionInfoCommand.swift` read a `@MainActor` property (`TopologySessionPayload.allPanes`)
from a nonisolated context, which a newer Xcode (27.0, 27A266a) infers strictly enough to
reject. Verified pre-existing (not caused by #0412) with a byte-identical fresh clone of
`main` in `/tmp` with its own clean `DerivedData`. Fixed on `main` separately as #0365
(`TopologySessionPayload`'s extensions made explicitly `nonisolated`, matching the type's own
declaration) — `issue/0412` was rebased onto the fix before re-running.

**Blocker 2 — Tart's virtio-fs share can't pass a symlink through.** This repo commits a
real symlink, `.cursor/skills/quest`. The first attempt extracted the `git archive` export on
the host and `cp -R`'d the resulting tree into the guest over the read-only share; that
failed with `cp: ... could not copy extended attributes ...: Too many levels of symbolic
links` — the exact limitation the shared host doc records for copying `Xcode.app` in.
Fixed the same way: `git archive` now writes a tar file directly (never extracted on the
host), and the guest extracts both tar files locally onto its own disk, where a local
symlink is unremarkable.

### First full run — 2026-09-24 02:11–02:25 UTC (run id `20260923-191103-94702`)

With both blockers fixed, `tools/run-ui-tests-vm.sh` ran the full `BattyUITests` suite
end to end for the first time.

| Metric | Result |
|---|---|
| Tests executed | **73**, 1 skipped, **7 failed** (1 unexpected) |
| Test-phase wall clock | 617.5 s (~10.3 min) — matches AGENTS.md's "~10 min" estimate |
| Total wall clock, clone-to-finish | ~14 min (boot 31 s + fresh SwiftPM resolution + full app build with no package cache + the 10.3 min test phase + result pull/cleanup) |
| Guest reachable after boot | 31 s — measured from script start, not from when `tart run` began booting; this run predates the boot-start-timestamp fix, so the figure includes the earlier preflight-and-clone time too and likely overstates true boot latency by a small, unmeasured amount. Later runs report elapsed since the boot timer starts. |
| SwiftPM resolution over the guest's NAT | Succeeded — `libghostty-spm`, Sparkle, `textual`, `swift-argument-parser`, `swiftui-math`, `swift-concurrency-extras`, `MSDisplayLink` all fetched fresh (no cache in a new clone) |
| `PRODUCT_NAME` / bundle id in the guest | Confirmed Beta throughout the log (`co.sstools.Batty.beta`, `Batty Beta`) — open question 3, answered |
| Gatekeeper re-sign step | Not needed — `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=` alone was sufficient — open question 5, answered |
| Prompts in the guest | **Unconfirmed — inferred, not directly observed.** The run completed unattended in 14 min, which a *blocking* (modal, input-required) prompt would have prevented, but a non-blocking one (e.g. a banner notification) would not necessarily show up as a hang. Nothing in this run captured a guest screenshot to check directly; the `.xcresult` under `build/ui-tests/20260923-191103-94702/` was not inspected for attachment screenshots. Treat as "no prompt stopped the run," not as "no prompt appeared." |
| Crash reports in the guest | **None** (`~/Library/Logs/DiagnosticReports/Batty*.ips` — empty) |
| SwiftUI/AppKit warnings in the app's log | 93, all `[com.apple.SwiftUI:Invalid Configuration] Geometry action is cycling between duplicate values` — see "Findings for follow-up" |
| Host: new crash reports | **None** — newest entry predates the run |
| Host: `lsappinfo` ASN for the user's running Batty | Unchanged (`0x58058`) before and after — it did not restart |
| Host: leftover clones | **None** — `tart list` showed only golden images afterward |

### Failing tests — classification

| Test | Cause | Classification |
|---|---|---|
| `SessionCwdRenameTests.testSessionNameTracksCdIntoAndOutOfProjectDir` | `NSCocoaErrorDomain Code=513`: "You don't have permission to save the file … in the folder "tmp"" creating `/tmp/batty-uitest-proj-*` — `NSPOSIXErrorDomain Code=1 Operation not permitted` | **Environmental.** The guest denies this write outright (no prompt), unlike the host. Filed as **#0416**. |
| `PaneSidebarTests.testChevronExpandsAndCollapsesPaneList` | `XCTAssertTrue failed - Expanding must reveal one row per pane` | Unclear — real assertion failure. Filed with the rest of this class as **#0417**. |
| `PaneSidebarTests.testChevronPresentForSinglePaneSession` | `XCTAssertTrue failed - Expanding a single-pane session must show its one pane row` | Unclear — real assertion failure. Filed with the rest of this class as **#0417**. |
| `PaneSidebarTests.testClickingPaneRowDoesNotBlankSession` | `XCTAssertTrue failed` | Unclear — real assertion failure. Filed with the rest of this class as **#0417**. |
| `PaneSidebarTests.testEyeDisabledForLastVisiblePane` | `XCTAssertTrue failed` | Unclear — real assertion failure. Filed with the rest of this class as **#0417**. |
| `PaneSidebarTests.testHidingPaneAutoExpandsPaneList` | `XCTAssertTrue failed - Hiding a pane must auto-expand the sidebar pane list` | Unclear — real assertion failure. Filed with the rest of this class as **#0417**. |
| `WindowRestorationTests.testToggleSidebarAffectsOnlyKeyWindow` | `XCTAssertTrue failed - Key window's sidebar must collapse after Cmd-B` | Unclear — real assertion failure, unrelated to the `PaneSidebarTests` cluster. Filed separately as **#0418**. |

All five `PaneSidebarTests` failures cluster in one class, which is worth investigating as a
group rather than five separate reports — either a real regression in that view, or something
systematic about the guest (headless, paravirtualized GPU, no display) that this class's
setup depends on and the rest of the suite doesn't. Neither this run nor #0412's scope
includes chasing that down; **not fixed here. Filed together as #0417** by the orchestrator.

### Findings for follow-up (not fixed here)

- **The embedded broker never connects in the guest.** `app-warnings.log` shows 624
  occurrences of `[co.sstools.Batty.beta:AppXPCCoordinator] broker connection invalidated`
  and `broker unreachable: Couldn't communicate with a helper application`, in a constant
  reconnect-backoff loop for the whole run. This matches #0401's finding that an
  unsigned/ad-hoc-signed broker fails `SMAppService` registration — answers #0412's open
  question 4 for the ad hoc-signed case, and is a real limit on what #0413's CLI-driven UI
  tests can exercise in this VM until it's addressed. Filed as **#0419**.
- **`[com.apple.SwiftUI:Invalid Configuration] Geometry action is cycling between duplicate
  values`** fired 93 times over the run — once per app launch, roughly. This is a real,
  recurring SwiftUI Fault-level log line, not VM noise; whether it's new or has always been
  there (nothing in the routine `./build.sh unit` loop would have shown it — it only appears
  in the app's own unified log, not in `xcodebuild`'s test output) is unknown. Filed as
  **#0420** to investigate against `docs/swiftui-observation-rules.md`.
- **No TCC/permission prompt blocked the run**, but the guest silently *denies* at least one
  filesystem write (`/tmp`, see `SessionCwdRenameTests` above) that the host allows. Answers
  #0412's open question 6 partially: no prompt, but not identical filesystem permissions
  either — a test that writes outside the exported source tree needs to account for this in
  a guest.

## Round 2 verification — 2026-09-24

Four separate VM runs verified the round-2 fixes (bounded cleanup kills, ignore-a-second-signal,
the stale-sweep pid check, and the wait-for-a-slot preflight) against a real clone, not just the
scratch-script proof in the commit. The host was unusually busy the whole time — Changeover,
Curator, Switchyard, System1, and Quartermaster were all cycling VMs concurrently — which
exercised the wait-for-a-slot preflight for real: two attempts timed out (`WAIT_FOR_SLOT_SECS`
1200s and 2700s, respectively, both against a host that never went idle in that window) before a
run finally got a slot after 690s of waiting, and another after 840s with `WAIT_FOR_SLOT_SECS`
raised to 3600s. That's a real data point on how long "no other VM running" can take to become
true on a contested day — the 1200s default is not always enough; a caller in a hurry on a busy
day should raise `WAIT_FOR_SLOT_SECS` itself. Free disk on the host dropped to 22 GiB during the
busiest stretch (comfortably above the 20 GiB floor, but worth knowing it moves).

**(a) A passing class.** `BattyUITests/SidebarTests` (passed in the first full run) — run id
`20260923-204200-44278`: exit 0, `RESULT: TEST SUCCEEDED`, 3/3 tests passed, live output streamed
to the terminal throughout (confirmed by watching the runner's own stdout, not just the final
log).

**(b) A failing class.** `BattyUITests/PaneSidebarTests` — run id `20260923-214147-51327`: exit 65,
`RESULT: TEST FAILED (exit 65)`, the same 5 tests failing as in the first full run (same
assertions, same line numbers) — reproducible, not a one-off.

**(c) Results dirs.** Both `build/ui-tests/20260923-204200-44278/` and
`build/ui-tests/20260923-214147-51327/` contain `xcodebuild.log`, `UITests.xcresult`,
`app-warnings.log`, and `tart-run.log`.

**(d) Mid-test-phase signals.** A driver script launched the runner, watched its live stdout for
the target class's `Test Suite '<Class>' started` line, then signaled the runner's own pid
(simulating Ctrl-C) once that line appeared — so the signal reliably lands during the actual test
phase, not during boot or build.

| Run | Class | Signal | Exit | Signal → runner-exited | Host checks |
|---|---|---|---|---|---|
| `20260923-220945-75823` | `TabRenameTests` | `INT`, then a second `INT` 2s later | 130 | 2s | clean (below) |
| `20260923-222654-87170` | `LayoutTests` | `TERM` | 143 | 2s | clean (below) |

Both aborted runs left only `tart-run.log` (containing `Stopping VM...`) in their results dir —
expected, since the abort interrupts execution before the "Results back" step that pulls the
guest's `xcodebuild.log`/`UITests.xcresult`/`app-warnings.log` ever runs.

After each: `tart list` showed no `batty-uitest-<runid>` and no VM of ours running (only golden
images and, at various points, another project's own fresh clone); `pgrep -fl tart` showed no
leftover `tart run`/`tart exec` of ours (only another project's, when one was mid-run); the export
dir (`/var/folders/.../batty-uitest-export.*`) was gone; `tart-run.log` was kept; no
memory-signal request was ever made in these two runs (the host had enough free memory at both
moments, so there's nothing to check a release for here — the release-write path itself is
exercised by the general `bounded_kill`/cleanup logic, not something these two runs happened to
trigger); the user's Batty kept the same `lsappinfo` ASN (`0x58058`) throughout all four runs; no
new `Batty*.ips` crash report appeared (a few unrelated crash reports from other host activity —
`osascript`, `neopager` — did appear during this window, from processes that aren't Batty).

**(e) A second signal during cleanup is ignored.** The `TabRenameTests` run above sent a second
`INT` 2s after the first specifically to exercise this, but this VM's `tart stop` happened to
complete in well under 2s both times (much faster than the ~30s the bounded-kill design budgets
for), so the second signal arrived at or after the runner had already fully exited rather than
mid-`tart stop` — it landed as a no-op, which is a fine outcome but doesn't exercise the ignore
path against a *live* `tart stop`. The mechanism itself — `trap '' INT TERM HUP` during cleanup,
verified against a deliberately slow (3s) stand-in for `tart stop` with a signal timed to land
inside that window — is proven in the commit's scratch-script test, not by these two live runs;
a future run against a VM whose `tart stop` happens to take longer would exercise it live too.

## Round 3 verification — 2026-09-24

Round 2 review found a real bug in `bounded_kill`'s wait loop, plus two documentation
inaccuracies. No VM run was needed to fix or verify these (the bug is a pure zsh
`set -e`/arithmetic interaction and the doc changes are wording), so this round's evidence is
a scratch-script reproduction plus a static reorder, not a fresh VM run.

**Bug: `(( waited++ ))` under `set -euo pipefail`.** Post-increment's *result* is the value
*before* incrementing, so on the loop's first pass `(( waited++ ))` evaluates to `0`. A bare
`(( expr ))` used as a standalone command (not inside `if`/`while`/`&&`/`||`, all of which are
exempt from `set -e`) reports exit status 1 when `expr` is `0` — indistinguishable, to `set -e`,
from any other failing command. Since `bounded_kill` runs inside the `cleanup()` `EXIT`-trap
handler with `set -e` still in effect, this aborted `cleanup()` mid-kill on the very first
`sleep 1` iteration for any target that outlived one second — skipping `tart stop`,
`tart delete`, the memory-signal release, and the export removal for the rest of that run.
Fixed with pre-increment, `(( ++waited ))`, whose result is the *new* (nonzero after the first
pass) value.

An audit of every other `(( ... ))` in the script (`grep -n '((' tools/run-ui-tests-vm.sh`)
found no other bare arithmetic command that can evaluate to `0`: every other occurrence is
either an assignment (`x=$(( ... ))`, which always reports its own exit status, not the
expression's value), inside an `if`/`while` test, or already followed by `||`/`&&` (which
POSIX/zsh's `set -e` exempts by design — e.g. `(( ${#crashes} )) && log ...`, whose `&&`-guarded
left side is allowed to be falsy). **This audit covered only `((...))` arithmetic — it did not
rule out `set -e` hazards from other command forms, and round 4 found one:** `bounded_kill`'s
early-return branch, `kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 0; }`,
has the same failure shape when the target already exited nonzero before `bounded_kill` runs —
`wait` then reports that nonzero status, which aborted `cleanup()` the same way. See "Round 4
verification" below. **The round 2 live mid-test-phase signal runs (case (d) above) did not
exercise either hazard**, and should not be read as having cleared this class of bug: both
signals landed while the script's test-phase `wait "$TEST_PID"` was executing inside its own
`set +e ... set -e` bracket (added so a nonzero test exit code doesn't itself trip `set -e`),
so `cleanup()` ran that round with errexit already off for unrelated reasons — coincidentally
masking both the arithmetic bug (fixed above) and the early-return bug (see below), neither of
which a live run with errexit engaged during cleanup would have masked.

**Scratch verification**, reusing a copy of `bounded_kill` + `cleanup` verbatim
(`t1orig.zsh`/`t1fixed.zsh`/`drive.zsh` in the review round's scratchpad), against two cases:

| Case | Child behavior | Buggy (`waited++`) | Fixed (`++waited`) |
|---|---|---|---|
| (a) dies after TERM | `TART_RUN_PID` exits 3s after TERM, `TEST_PID` 2s after TERM | `cleanup rc=143` logged, then **nothing else** — both children leaked, no `wait`/kill/cleanup completion. Confirmed via `pgrep`: both child pids still running after the script exited. | `cleanup rc=143` → `after test kill` → `cleanup done`, exit `143` preserved, both children reaped, `pgrep` shows none left. |
| (b) ignores TERM | `TART_RUN_PID`'s child traps `TERM` to a no-op and never exits on its own | not re-tested (already proven broken by (a)) | `cleanup rc=143` → `after test kill` → `run pid <pid> still alive after 30s, sending KILL` → `cleanup done`, exit `143` preserved at `~33s` total, `pgrep` shows none left. |

Case (a)'s buggy run left two orphaned `zsh` child processes running after the driver script
exited; they were killed by hand (`pkill`/`kill -9`) immediately after observing the failure,
before any other verification step. No scratch process was left running at the end of this
round — every spawned child was confirmed reaped or explicitly killed after each test.

**Sweep-before-wait reorder.** This is a straight code reorder (the sweep loop moved verbatim
to just after the golden/SlidingTabs existence checks, before the wait-for-a-slot block) with
no new logic to exercise in isolation — `zsh -n tools/run-ui-tests-vm.sh` confirms the script
still parses, and the existing own-run-id-regex-plus-pid-liveness safety property (never
matches the golden, skips a live concurrent run's clone) is unchanged by the move. Exercising
the actual race it fixes (an orphaned running clone blocking the wait-for-slot preflight
forever) needs a real killed-mid-run VM, which is deferred to the next live VM run rather than
reproduced in a scratch harness here.

## Round 4 verification — 2026-09-24

Round 3's fix left one more `set -e` hazard in the same function, plus a matching one in the
results-pull step. Both are pure zsh interactions, so again no VM run was needed — this
round's evidence is a scratch-script reproduction and a static read of the pipefail step.

**Bug: `bounded_kill`'s early-return `wait` under `set -euo pipefail`.** The branch taken when
the target is already gone by the time `bounded_kill` is called —
`kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 0; }` — ran `wait "$pid"` bare.
`wait` reports the already-exited process's own exit status, and when that status is nonzero
(the realistic case: `tart run` exiting early because it lost the slot race, followed by this
script's boot-timeout `fail`), the bare `wait` is a failing command on the right-hand side of
`||`, which `set -e` does **not** exempt (the exemption is for the command *before* `||`/`&&`,
not after) — so it aborted `cleanup()` right there, before `tart delete`, the memory-signal
release, or the export removal ran. Fixed two ways: the `wait` itself now has its own `|| true`
(`wait "$pid" 2>/dev/null || true; return 0`), and — closing the whole class rather than
relying on every individual command inside `cleanup()` being separately guarded — `cleanup()`
now runs `set +e` as its first statement (right after `local rc=$?`, which must still capture
the incoming status before anything else touches `$?`). A trap that doesn't call `exit` itself
still exits the process with the status active when the trap fired, not whatever a later
command inside it sets `$?` to — confirmed with a scratch check (`local rc=$?` capturing 5,
then `set +e; false` inside the trap, still exits the process with 5).

**Scratch verification**, a new script (`t2_early_exit.zsh`, alongside `t1fixed.zsh` in the
same scratchpad) with a stand-in `TART_RUN_PID` that exits `1` on its own well before cleanup
runs, followed by a stand-in `fail` (exit `1`) playing the boot-timeout failure, and cleanup
extended with logged stand-ins for the steps after the bounded-kill call (`tart delete`,
memory-signal release, `rm -rf` the export) so their being reached or skipped is directly
observable:

| Variant | Output | Exit code |
|---|---|---|
| Pre-round-4 (bare `wait`, no `set +e`) | `cleanup rc=1` → `after test kill` → **stops** — `after run kill`, both stand-in deletes, and `cleanup done` never print | `1` (a shell guarantee for EXIT traps regardless of where cleanup aborts — see above; the exit code was never the part that broke, the skipped cleanup steps were) |
| Fixed (`wait ... \|\| true` + `set +e`) | `cleanup rc=1` → `after test kill` → `after run kill` → `STAND-IN: tart delete` → `STAND-IN: memory-signal release` → `STAND-IN: rm -rf export` → `cleanup done` | `1` |

Confirmed via `pgrep` that the stand-in `TART_RUN_PID` child (`zsh -c 'exit 1'`) left nothing
running after either variant — it exits on its own well before the script even reaches
`cleanup()`, so there was never anything to leak in this particular scenario; the bug was
purely about which cleanup steps ran, not about leaked processes. The buggy variant file was
deleted immediately after this comparison; only the fixed `t2_early_exit.zsh` remains in the
scratchpad.

**Results-pull pipefail (optional item, applied).** `tart exec "$CLONE" ... | tar -x -C
"$RESULTS_DIR"` runs under `pipefail`, so a failure on either side is this standalone
pipeline's own nonzero status — which, same as above, would exit the script right there via
`set -e` with tar's status instead of the test's, skipping the pass/fail summary and reporting
the wrong exit code for a test run that actually finished. Guarded with
`|| log "Failed to pull some results back from the guest (see above)"` so the script always
falls through to `exit "$test_rc"`, the test's own already-known result, regardless of whether
the result bundle made it back intact. Not separately scratch-tested — it is the same
`command | command || fallback` shape already proven safe by every other guarded step in this
script (e.g. `tart stop ... || true`).

## Known limits

- One UI test run at a time on this host, across every project sharing it (Changeover,
  Curator, Switchyard, Quartermaster, System1, Batty). The preflight refuses to start a clone
  while `tart list` shows anything running, and never stops another project's VM. **Observed
  in practice on 2026-09-23** (before the wait-for-a-slot preflight step existed): with
  several other projects' agents cycling VMs concurrently, this runner's preflight refused
  dozens of times over roughly 14 minutes before a free slot appeared — the guard did its job
  (no VM was force-started or another project's clone touched), but a busy host means "no
  other VM running" can take a while to become true. The preflight now waits for that itself
  (polling every `WAIT_POLL_SECS`, up to `WAIT_FOR_SLOT_SECS`, both overridable — see
  "Preflight" above), so a caller no longer needs to poll-and-re-invoke by hand; it only needs
  to handle the case where no slot opens within the window.
- A run takes 6 CPUs and 12 GB of memory from the host while it runs.
- SlidingTabs is exported at its sibling repo's current `HEAD`, not a pinned commit — see
  step 2 above.
- Every guest clone starts with no SwiftPM package cache, so dependency resolution happens
  on every run (`libghostty-spm`, Sparkle, `textual`, `swift-argument-parser`, and their
  transitive dependencies, all from GitHub over the guest's NAT).
