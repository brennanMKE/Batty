# Process Status view — design (phase 1 of `#0305`)

Design proposal for `#0305`'s design-gated phase 1: the second concrete
non-terminal Pane content kind, `process-status`. **No code ships with this
document** except the throwaway feasibility spike described in §1, which
was run in a scratch directory outside the repository and is not part of
this commit. Read `docs/pane-kinds.md` (where kind lives, how `PaneView`
branches, the terminal-host boundary) and `docs/pane-view-lifecycle.md`
(the `PaneContentLifecycle` contract this view is the second real client
of) first — this document assumes both and does not re-explain them. Also
read `docs/design/git-status-view.md` (`#0304` phase 1) — this is the
second view in the same family, follows the same visual language, and this
document calls out where it deliberately departs from that precedent
rather than re-deriving decisions already settled there.

Every source citation below was re-verified against the tree on
2026-08-08 while writing this document (branch `issue/0305`). Several line
numbers cited in `docs/design/git-status-view.md` had already shifted by
the time this document was written (the tree has moved on since `#0304`
phase 1) — a reminder to the next reader of *this* document not to trust
its own citations without a fresh grep, either, once enough time passes.

---

## 0. What's already decided upstream, and what this document adds

`#0302`/`#0303` settled the *shape* a non-terminal kind must fit into;
`#0304` phase 1 set the visual and documentation precedent this view
follows. This document is the second thing to fill that shape in:

- **Kind identifier.** Following `docs/pane-kinds.md` §5's "one string,
  three call sites" rule (already used by `#0304` for `git-status`), this
  document names the kind `process-status` — the `PaneContentKind` raw
  value, the CLI `--view` flag value, and the `TopologyPanePayload.kind`
  JSON value are all literally `"process-status"`.
- **The pane has no Tab bar and no `TabRuntime`s** (`docs/pane-kinds.md`
  §1) — everything below describes the single view that fills a
  `process-status` pane's body.
- **The conformer is model-owned**, hung off `PaneRuntime` the way
  `TabRuntime.terminal` hangs off `TabRuntime` and the way `#0304`'s
  `GitStatusPaneContent` is specified to (`docs/pane-view-lifecycle.md`
  §5). This document names the concrete conformer,
  `ProcessStatusPaneContent`, and what it holds.
- **Not built here**: the `PaneContentKind` enum case, `PaneRuntime.kind`,
  `PaneView`'s kind-switch, the CLI verb (`#0315`, still an open design
  itself). This document is scoped to the view's own design — its process
  selection, its data source, its refresh strategy, its visual content —
  so `#0305`'s phase 2 and `#0315` each have a settled thing to wire in.
- **What this document adds that `#0304` didn't need**: a feasibility
  spike (§1). `#0304` spawns `git`, an external tool whose data Batty has
  no in-process alternative to. This view's entire premise — reading
  another process's CPU/memory/thread state — runs into a real macOS
  permission boundary that had to be measured, not assumed, before any of
  §§2-4 below could be trusted. §1 is why this document exists in the
  shape it does.

---

## 1. Feasibility spike: what's actually obtainable, measured on this machine

The issue's own framing is exact: reading another process's state requires
either a Mach task port (`task_for_pid`, restricted) or the libproc/BSD
introspection calls that don't need one. This section reports what was
**observed**, not what the APIs are documented to do. Spike code ran as
throwaway Swift scripts (`swift <file>.swift`, no Xcode project) in
`/private/tmp/.../scratchpad/spike0305/` — outside the repository, not part
of this commit — on this machine: **macOS 26.5.1 (build 25F80), Swift
6.3.3 (swiftlang-6.3.3.1.3), arm64**, running as the same unsandboxed,
same-uid process class Batty itself runs as (`CLAUDE.md`: `ENABLE_APP_SANDBOX
= NO`).

### 1.1 `task_for_pid` fails — confirmed, not assumed

```swift
var task: mach_port_t = 0
let kr = task_for_pid(mach_task_self_, pid, &task)
```

| Target | uid | Result |
|---|---|---|
| self (`getpid()`) | 501 (same as caller) | `kr=0` (`KERN_SUCCESS`) |
| Finder | 501 (same as caller) | `kr=5` (`(os/kern) failure`) |
| an interactive `zsh` | 501 (same as caller) | `kr=5` (`(os/kern) failure`) |
| `launchd` (pid 1) | 0 (root) | `kr=5` (`(os/kern) failure`) |

`kr=5` is `KERN_FAILURE`, decimal 5 = hex `0x5` — the exact failure code
Batty's own log line names (`Unable to obtain a task name port right for
pid 607: (os/kern) failure (0x5)`, quoted in `issues/0305.md`). **Same-uid
does not help**: Finder and the zsh shell are both owned by the same user
as the caller, and `task_for_pid` fails identically for them and for root's
`launchd`. This settles the issue's central open question: `task_for_pid`
is not a viable path for this feature under any ownership relationship
tested, on this OS version, from an unsandboxed same-user caller.

### 1.2 libproc succeeds instantly for same-uid processes — and the numbers check out

`proc_pidinfo(pid, PROC_PIDTASKINFO, ...)`, `proc_pid_rusage(pid,
RUSAGE_INFO_V4, ...)`, and `proc_pidinfo(pid, PROC_PIDLISTFDS, ...)` all
succeed for a same-uid target, in well under a millisecond each:

| Target (uid 501, same as caller) | `PROC_PIDTASKINFO` | `proc_pid_rusage` (`ri_phys_footprint`) | Time |
|---|---|---|---|
| self | threads=1, resident=143.25 MB | 54.17 MB | 0.003–0.006 ms |
| Finder | threads=9, resident=166.45 MB | **758.35 MB** | 0.004–0.005 ms |
| zsh | threads=1, resident=3.23 MB | 2.31 MB | 0.001–0.002 ms |

**Cross-checked against two independent tools, not just self-consistent:**
Apple's own `footprint` CLI (`/usr/bin/footprint`, ships with macOS)
reported Finder's footprint as **"758 MB"** — matching the libproc read of
758.35 MB. `ps -o rss -p 1246` reported **170448 KB = 166.45 MB** — matching
the libproc `resident_size` read of 166.45 MB exactly. This is the
`#0290`/`FootprintReader` cross-check pattern (never trust a self-reported
number without an independent second source) applied to *another*
process's memory for the first time in this codebase.

Root's `launchd` (pid 1) fails cleanly on every one of these calls:
`PROC_PIDTASKINFO` → `errno=1` (`EPERM`, "Operation not permitted");
`PROC_PIDLISTFDS` → same; `proc_pid_rusage` → same. This is the expected,
documented libproc behavior (same-uid or root only) — and it is *not*
vacuous for Batty specifically, per §1.5 below.

### 1.3 Cost — every call in scope is negligible; the shell-out fallback is not needed

| Operation | Measured cost |
|---|---|
| `proc_pid_rusage` × 1000 (same pid) | 6.016 ms total, **0.006 ms/call** average |
| `PROC_PIDLISTFDS`, count + full fetch (353 fds, Batty's own process) | 0.015 ms |
| `PROC_PIDFDVNODEPATHINFO` resolving all 353 fds to paths | 0.179 ms total (0.0005 ms/fd) |
| `PROC_PIDFDVNODEPATHINFO` resolving 155 fds (VS Code) | 0.179 ms total |
| Full-system child-process discovery (`proc_listallpids` + `PROC_PIDTBSDINFO` per pid, ~820 processes, filtering by `pbi_ppid`) | 0.3–1.5 ms |
| `sysctl(KERN_PROCARGS2)` — full command line/argv, same-uid | 0.012–0.025 ms |
| `proc_name` / `proc_pidpath` | sub-millisecond, not separately timed (dominated by process noise) |
| Shell out: `ps -o pid,pcpu,rss,vsz,etime,comm -p <pid>` | **65.67 ms** (single call), **66.65 ms** average over 10 calls |
| Shell out: `top -l 1 -pid <pid> -stats pid,cpu,mem,threads` | **399.98 ms** |

The libproc path is **three to five orders of magnitude** cheaper than
shelling out to `ps` or `top` for the same single-pid data. **No gap was
found in this spike that requires the shell-out fallback** — every metric
§2 proposes showing was obtainable directly via libproc for a same-uid
process. This is the single biggest way this design departs from
`#0304`'s: that view spawns `git` because no in-process equivalent to `git
status` exists; this view spawns nothing, because an in-process equivalent
to `ps`/`top` (libproc) exists and is dramatically cheaper.

**Child-tree discovery is a real, if modest, exception to "negligible."**
There is no direct "list children of pid X" libproc call — discovering
children means enumerating *every* pid on the system and checking each
one's `pbi_ppid`. Measured cost (~1 ms for ~820 processes on this machine)
is still far below any plausible refresh interval, but it is **O(total
system process count), not O(target's children)** — unlike every other
call in this table, which is O(1) against the target pid directly. The
issue's own claim that child-tree enumeration is comparatively expensive
is directionally correct for this reason, even though the absolute number
measured here is small. §4 treats this cost class differently from the
others (on-demand, not per-tick) for exactly this reason.

### 1.4 Exited vs. permission-denied — two distinguishable, clean failure signals

Spawned `/bin/sleep 0.2` via `Process`, waited for it to exit, then queried
the stale pid:

```
PROC_PIDTASKINFO on exited pid -> rc=0 errno=3 (No such process)
proc_pid_rusage on exited pid  -> rc=-1 errno=3 (No such process)
```

A never-allocated pid (`999999`) produces the identical `errno=3` (`ESRCH`).
This is a clean, reliable "the process is gone" signal, **distinct** from
the `errno=1` (`EPERM`) "the process exists but I can't read it" signal in
§1.2/§1.5. §2's tombstone state keys off `ESRCH`; §2's permission-unavailable
state keys off `EPERM`. Neither is inferred or guessed — both are the
kernel's own, distinguishable error codes, observed directly.

### 1.5 Scope honesty — same-uid only, and this is not a hypothetical for Batty

Every successful metrics read above targeted a **same-uid** process. Every
metrics call against a different-uid process failed with `EPERM`,
including one case specific to Batty's own architecture, worth naming
explicitly because it will otherwise surprise whoever implements phase 2:

**Batty's own pty session leader is root-owned.** `ps -o uid,pid,ppid,comm`
on a live Batty terminal Tab shows:

```
UID   PID  PPID COMM
501  9870     1  /Applications/Batty.app/Contents/MacOS/Batty   (Batty itself)
  0  9876  9870  /usr/bin/login                                  (session leader, ROOT)
501  9877  9876  -/bin/zsh                                       (the actual shell)
```

`proc_pidinfo(9876, PROC_PIDTBSDINFO, ...)` on that `/usr/bin/login`
process returns `errno=1` (`EPERM`) even though it is a direct child of the
user-owned Batty process — ownership, not process-tree position, is what
libproc gates on. This means "a process reachable by walking Batty's own
child tree" is not the same set as "a process this feature can read."

**This does not invalidate `foregroundPid` as a selection source**, but it
does name a real edge case §2 must handle. `TerminalView.foregroundPid`
(`tcgetpgrp` on the pty) does not return the session leader — it returns
whatever is currently in the pty's foreground process group, confirmed
directly: `ps -o tty,tpgid,pgid` on the same live pty showed `tpgid=10582`,
and `ps -o uid,pid,comm -p 10582` showed that pid was **uid 501** (a
user-run command in that shell), not the root `login` wrapper. In ordinary
use, `foregroundPid` resolves to a same-uid target because the shell (or
whatever the user runs) is what claims the foreground process group, not
`login`. **The edge case that does hit `EPERM`**: the user runs `sudo
<command>` interactively — the foreground process group becomes root-owned
for as long as that command runs, and a `process-status` pane following
that tty will get `EPERM` on that tick, exactly like the `login`-wrapper
case above. §2 defines this as a first-class, non-error UI state (a
permission-unavailable banner, not a blank or a crash) precisely because
this spike found a concrete, reachable path to it.

**No entitlement route was tested.** The issue names the `task_for_pid`-allow
route as "effectively private/dev-only" — that specific claim is carried
from the issue text as asserted, not independently re-verified here:
testing it would require a provisioning-profile/entitlement change and a
real notarization-relevant signing decision, out of scope for a throwaway
spike. (An earlier draft of this section misnamed this as
`com.apple.security.get-task-allow` — that entitlement is granted to the
*debuggee* so a debugger may obtain *its* task port; it is not what an
inspecting app like Batty would need, and is not the route the issue's own
"`task_for_pid`-allow" phrasing refers to. Corrected here so the paragraph
whose job is flagging an unverified claim doesn't undercut itself by
misnaming the claim.) Everything else in this section **was** run and its
output observed on this machine.

### 1.6 Bonus finding: identity data has a looser permission tier than metrics data

`proc_pidpath` (full executable path) succeeded even for **root-owned**
`launchd` (pid 1) — a call that returned `/sbin/launchd` when every metrics
call against the same pid returned `EPERM`. `proc_name` (short name)
failed for the same root target. This means "what is this process" (path)
and "is it running well" (CPU/memory/threads) sit behind different
permission tiers on this OS — worth carrying into §2's permission-denied
state, which can still show a resolved path even when it can't show
metrics.

`sysctl(CTL_KERN, KERN_PROCARGS2, pid)` (full command line / argv) also
succeeded for same-uid processes (0.012–0.025 ms) and failed cleanly
(`errno=22`, `EINVAL`) for root's `launchd`. This refines, rather than
contradicts, `#0297`'s finding that "the full command line of what rang
the bell" is not reliably available — that finding was about libghostty
not surfacing a *terminal's own* running command; here, a *different*
process is being inspected directly by pid, and `KERN_PROCARGS2` gives the
same-uid case its full argv cheaply. §2 uses this as a bonus "Command Line"
disclosure the issue didn't ask for but the spike found essentially free.

### 1.7 What this rules in and out for §2

**Ruled in, at negligible cost, every refresh tick, for a same-uid
target:** CPU % (delta-computed), memory footprint + resident size, thread
count, open-file count, process name, executable path.

**Ruled in, but on-demand only (not every tick), because the *kind* of
cost is different — O(system size) or O(fd count) rather than O(1)
against the target pid:** full open-file path listing, child-process list,
full command line.

**Ruled out entirely:** anything requiring `task_for_pid` (there is
nothing left in this design that needs it — every metric routes through
libproc); per-thread detail (`PROC_PIDTHREADINFO` needs a thread id from a
separate `PROC_PIDLISTTHREADS` call and returns per-thread priority/state —
more depth than a pane-sized view needs when `PROC_PIDTASKINFO`'s aggregate
thread count already answers "how many"); the shell-out fallback (§1.3 —
no gap found that requires it); anything about a process this user does
not own, beyond its name and path (§1.5/§1.6) — that boundary is shown
honestly, not worked around.

---

## 2. Which process, selected how

**Decision: two explicit, mutually exclusive selection modes — a pinned
pid (tombstones on exit) and a followed terminal's foreground process
(re-resolves every tick, no successor bookkeeping needed) — chosen at
creation and switchable later via an explicit retarget action. Never an
implicit, silent rebind.**

### Mode A — Pinned pid

The CLI's create verb (`#0315`, still an open design) supplies a literal
`--pid <pid>`. This document names the payload content the same way
`docs/design/git-status-view.md` §1 named `--path` for the Git Status
view — the exact verb shape is `#0315`'s to settle, not this document's.
The pane is frozen to that one pid for its life: `ProcessStatusPaneContent`
samples that literal pid every tick (§4) until it disappears.

**On exit: tombstone, not a guessed successor.** §1.4 gives a clean
`ESRCH` signal the moment the pid is gone. The view freezes on the
last-known sample, shows a "Process exited" banner with the timestamp of
the last successful sample, and stops sampling (there is nothing left to
sample). This is the literal reading of "a selected app or process" — the
user asked to watch *this* pid specifically; silently substituting a
different pid because it happens to share a parent or a tty would
misrepresent what's being shown, the same reasoning `docs/design/
git-status-view.md` §1 used to reject implicit directory-following for the
Git Status view ("frozen, not live... the answer the user's own quote
asks for, not a moving target").

### Mode B — Following a terminal's foreground process

Default when no `--pid` is supplied. Resolved from the previously-focused
Pane's active Tab — `SplitTree.focusedPaneID`
(`BattyKit/Sources/BattyKit/Model/SplitTree.swift:99`) and the computed
`focusedPane` property that resolves it to a `PaneRuntime`
(`SplitTree.swift:128`, body at `:129`; confirmed current — there is no
`currentPane` property, an earlier draft of this document misnamed it) —
reading `TabRuntime.terminalNSView?.foregroundPid`
(`BattyKit/Sources/BattyKit/Runtime/AppStateStore.swift:1486`, the exact
call `#0297` already made reachable and load-bearing for
`BellDecisionRecord`; `TerminalView.foregroundPid` itself is
`tcgetpgrp` on the pty, `TerminalView+Process.swift:18` in the
`libghostty-spm` checkout, confirmed current — "PID of the pty's foreground
process group... Nil until the surface has a process").

**Re-resolved every refresh tick, not frozen at creation — a deliberate
departure from the Git Status view's "frozen, not live" precedent, for a
reason specific to what's being tracked.** A directory is stable for a
pane's whole life in ordinary use; a pty's foreground process is, by
definition, whatever the user is currently running — freezing it once
would show a single already-finished command within seconds of the pane
being created (e.g. the pane is opened while `npm install` is running; that
finishes in 30 seconds; a frozen-at-creation pid is now permanently a
tombstone for a build step nobody cares about anymore). Re-reading
`foregroundPid` every tick means the view always reflects whatever the
followed terminal is actually doing right now — the shell when idle,
whatever command is running when one is.

**This directly answers "follow the successor, or show a tombstone"
without needing a successor-tracking mechanism at all.** There is no
notion of "the primary pid" in mode B to compute a successor for — each
tick just re-reads `tcgetpgrp` on the followed pty, which already always
reports whatever is currently in the foreground. When a running command
exits and the shell resumes the foreground process group, the next tick
shows the shell. When a new command starts, the next tick shows that
command. The *tombstone* trigger for mode B is different and narrower:
the followed **tty itself** going away — its Tab's Terminal Session
closing, or its Pane closing — not any single command within it exiting.
`ProcessStatusPaneContent` holds the source Tab's **id**, not a strong
reference to the `TabRuntime` itself, and re-looks it up each tick —
`pane.tabs.first(where: { $0.id == tabID })`, the same by-id lookup
pattern `WindowRuntime` already uses elsewhere
(`BattyKit/Sources/BattyKit/Runtime/WindowRuntime.swift:486`, `:509`) —
rather than holding the object directly. A strong reference to a
`TabRuntime` would keep that object (and whatever it in turn holds) alive
past its owning Tab's actual close, exactly the lingering-reference class
`docs/view-hierarchy.md` §5 documents for the terminal path (SwiftUI or a
sibling model object holding a reference past the nominal close is why
`#0289` had to make teardown synchronous rather than trust ARC timing).
Holding an id sidesteps that risk entirely: when the lookup fails on a
later tick (the id no longer resolves to any Tab in the Session), that
*is* mode B's tombstone signal, distinct from the ordinary "back to shell"
tick where the lookup still succeeds and simply reports a different
`foregroundPid`.

**Why mode B doesn't inherit the Git Status view's sibling-erosion
problem.** `docs/design/git-status-view.md` §1 spends real space on why a
`git-status` pane can't durably track "the pane it was split from" — later
splits and closes reshape `SplitTree`'s adjacency, so a tree-position-based
relationship erodes. Mode B sidesteps this the same way: tree adjacency
only matters **once**, at creation, to pick which sibling Tab's id to bind
to when none was specified via the retarget action below. After that, the
binding is an id lookup, not a tree-position lookup re-evaluated later — a
later split elsewhere in the tree, or the source Tab's sibling Panes
rearranging, does not affect an already-resolved mode B binding; only the
source Tab itself disappearing (the id no longer resolving) does, which is
exactly the tombstone case above. This is a materially simpler answer than
the Git Status view needed, not an oversight relative to it.

### No process selected

When none of the above resolves — no `--pid`, and either no focused
terminal Pane exists in the Session (a freshly launched window with no
terminal yet) or the focused Pane's active Tab's `foregroundPid` is `nil`
(a just-spawned shell whose surface hasn't reported a foreground process
yet — `TerminalView+Process.swift:18`'s own doc comment: "Nil until the
surface has a process") — the view opens in a defined **"No process
selected"** empty state, mirroring `docs/design/git-status-view.md`'s
not-a-repo state: not an error, a starting point with a retarget action.
See mockup state 5.

### Retargeting: "Choose Process…"

A toolbar affordance, matching Git Status's single "Change Directory…" in
placement and icon language, but process selection genuinely has two
useful, different targets where a directory only had one — so this opens
a small menu with two actions rather than a single picker:

- **"Follow a Terminal Pane…"** — lists the terminal Panes in the current
  Session by their tab titles/cwd, picks one, switches to mode B bound to
  that Pane's active Tab.
- **"Pick a Running Process…"** — a searchable list built from
  `proc_listallpids` + `proc_name`/`proc_pidpath` (§1.3's ~1 ms
  whole-system enumeration, well within what a picker opening on click can
  afford once, not per tick), filtered to same-uid processes only (§1.5 —
  there is nothing else this feature could usefully show for a process it
  can't read metrics from). Picking one switches to mode A pinned to that
  pid.

Both actions tear down whatever sampling was running (§4's `tearDown`-style
release, without actually tearing down the whole `PaneContentLifecycle` —
just the mode-specific binding) and re-run `setUp`'s one-time identity
resolution against the new target, the same "one-time resolution, explicit
re-trigger" shape `docs/design/git-status-view.md` §1 uses for its own
retarget action.

---

## 3. What it shows

Bounded by §1.7. Layout (see the HTML mockup for the concrete visual):

1. **Header row** — process name and pid, a mode indicator ("Pinned" with
   a pin glyph, or "Following <Tab title>" with a link glyph), and a state
   chip (Running / Exited / Permission Unavailable). Right-aligned "Choose
   Process…" button, **plus the same pane-level drag handle and hide (eye)
   button every terminal Pane and the Git Status pane already have** — the
   identical relocation `docs/design/git-status-view.md` §2 already
   justified (those two mouse affordances live inside the tab-bar `HStack`
   that only exists in `PaneView`'s `.terminal` arm per `docs/pane-kinds.md`
   §2, so any non-terminal pane needs its own header-level substitute; this
   is the second view to need it, not a new justification).
2. **Core metrics row** — four figures, always sampled every tick (§1.7):
   **CPU %** (delta-computed over the refresh interval, not a
   cumulative total-since-launch number — a monotonically growing number
   is not what "CPU usage" means to someone watching a live view), **Memory**
   (`ri_phys_footprint` as the primary figure, `resident_size` as a
   secondary/tooltip value — the same "never lead with RSS" convention
   `#0290`'s `FootprintReader` established for Batty's own process,
   applied here to another process's memory for the first time in this
   codebase), **Threads** (`pti_threadnum`), **Open Files** (count only,
   from `PROC_PIDLISTFDS` — full listing is a disclosure below, not because
   it's expensive at measured scale but because it has no tested ceiling
   and a live header doesn't need it continuously).
3. **Command Line** — one line, the full argv from `KERN_PROCARGS2` (§1.6),
   monospaced, copyable via a context menu — a bonus the issue's own
   metric list didn't ask for but the spike found essentially free
   (0.012–0.025 ms) and directly useful for "what is this process."
4. **Disclosure groups** (`DisclosureGroup` or equivalent, matching Git
   Status's convention — collapsed by default, computed only when
   expanded, not every tick, per §1.7's O(system size)/O(fd count)
   distinction):
   - **Open Files** — full path list via `PROC_PIDFDVNODEPATHINFO`
     (§1.3/§1.6), one row per fd: type (file/socket/pipe), resolved path
     or a synthetic label for non-vnode fds.
   - **Child Processes** — immediate children only (not a recursive tree —
     nothing in the issue's framing asks for one, and each additional
     depth level would multiply the O(system pid count) scan by that
     depth), name + pid + a "Watch this instead" action that switches this
     same pane to mode A pinned to the child (a process tree is
     out of scope, but pivoting the view to a specific child is a small,
     high-value affordance the flat list already supports for free).
5. **Permission-unavailable banner** — replaces the metrics row (not the
   whole pane) when a sample returns `EPERM` (§1.5): "Permission
   unavailable — not owned by you," styled like Git Status's state banner
   (accent/warning-tinted, not just another line). The header still shows
   the **executable path** `proc_pidpath` resolved before the metrics call
   failed (§1.6's looser permission tier) — and only the path: `proc_pidpath`
   returns a path, never a command line, so this banner never shows
   arguments for a process this feature can't read `KERN_PROCARGS2` for
   (§1.6 — `KERN_PROCARGS2` fails `EINVAL` for a different-uid target,
   same permission boundary as the metrics calls). The process **name**
   shown alongside the path falls back to the path's basename
   (`(proc_pidpath as NSString).lastPathComponent`, e.g. `sudo` from
   `/usr/bin/sudo`) specifically because `proc_name` itself is *not* in
   the looser tier — §1.6 measured `proc_name` failing `EPERM` for the
   same root-owned target that `proc_pidpath` succeeded against, so the
   name isn't independently available either; the basename is a derived
   display convenience, not a second successful call. Neither the header
   nor the banner shows a blank view. See mockup state 4.
6. **Exited banner** — replaces the metrics row with "Process exited at
   `<timestamp>`" plus the last-known values shown dimmed/frozen beneath
   it, matching the general shape of a tombstone: what it was, not a blank
   space. See mockup state 3.
7. **Non-mutating context menu** on the process name/pid: "Copy PID," "Copy
   Command Line," "Reveal Executable in Finder" (`proc_pidpath`-resolved).
   No process-mutating actions (no "Kill," no "Renice") — nothing in the
   umbrella's user quotes asks for control, only status, and killing
   another process is a materially different risk class than anything
   Git Status's own read-only decision had to weigh (a wrong `git`
   read-only call costs nothing; a wrong `kill` is irreversible and can
   take down something the user cares about). Deferred exactly the way
   Git Status deferred staging/discard: not designed here, not stubbed.

### What's deliberately not shown in phase 1

Per-thread detail, network connections/sockets, a recursive process tree,
and historical/graphed CPU-over-time are all out of scope (§1.7's "ruled
out" list, plus — for the graph specifically — the same "keep phase 1
small" reasoning `docs/design/git-status-view.md` §2 used to defer a
diff-highlighting engine). If a future issue wants any of these, that's
new scope for that issue to argue, not something this design pre-builds
room for.

---

## 4. Refresh cadence and lifecycle wiring

**Decision: 1-second refresh cadence for the always-sampled core metrics
(§3.2); disclosure groups (§3.4) compute only when expanded, never on a
timer. No subprocess is spawned anywhere in this design.**

### Why 1 second, and why cost didn't have to decide it

§1.3 measured the core per-tick sample (`PROC_PIDTASKINFO` +
`proc_pid_rusage` + `PROC_PIDLISTFDS` count) at roughly 0.03 ms combined —
negligible at any plausible interval. Refresh cadence is therefore a UX
choice, not a cost constraint: **1 second**, matching Activity Monitor's
own default, because a Process Status pane is, by construction, something
the user has open and is looking at — contrast with `#0290`'s
`FootprintMonitor`, which samples Batty's *own* footprint every 60 seconds
specifically because that's a background health check nobody is watching
live. A live dashboard and a background monitor have different honest
answers to "how often," and this document picks the one that matches what
the feature actually is.

### Lifecycle wiring — the `PaneContentLifecycle` contract, concretely

`ProcessStatusPaneContent` conforms to `PaneContentLifecycle`
(`BattyKit/Sources/BattyKit/Runtime/PaneContentLifecycle.swift:110-138`,
confirmed current) via a `PaneLifecycleController`
(`PaneContentLifecycle.swift:146-161`), exactly as
`docs/pane-view-lifecycle.md` §6 prescribes:

| Contract method | What it does here |
|---|---|
| `setUp(visible: Bool)` (`PaneContentLifecycle.swift:123`) | Resolves selection (§2: CLI `--pid`, or the focused Pane's Tab, or neither). If resolvable, runs the one-time identity lookup (`proc_name`/`proc_pidpath`/`KERN_PROCARGS2` — §1.3, sub-millisecond) so the header has something to show the instant it's revealed. If `visible == true`: starts the 1s periodic sampling `Task` and performs the first sample immediately. If `visible == false`: resolves identity only, does **not** start the loop — per `docs/pane-view-lifecycle.md` §4, "setup must not create work it would immediately have to suspend." |
| `setVisible(true)` (`PaneContentLifecycle.swift:130`, a `suspended → active` transition) | (Re)starts the 1s periodic sampling `Task` and performs one immediate sample, matching "showing resumes and refreshes" (`docs/pane-view-lifecycle.md` §4) — the process's state may have changed materially while suspended (it may have exited entirely), so waiting for the next natural tick would show stale data for up to a full interval right when the user just revealed the pane. |
| `setVisible(false)` (an `active → suspended` transition) | Cancels the periodic sampling `Task` (`Task.cancel()`) and drops the reference. **No bounded-wait, no `terminate()`, nothing to interrupt** — see the paragraph below. |
| `tearDown()` (`PaneContentLifecycle.swift:137`) | Same cancellation as `setVisible(false)`, plus clearing the mode-B source Tab id (§2 — an id, not a strong `TabRuntime` reference, so there is nothing else to release), so the conformer retains nothing after this call returns. |

**Why this table is simpler than `#0304`'s, and why that's not an
oversight.** `docs/design/git-status-view.md` §4's lifecycle table needs a
bounded-wait `tearDown()` because `GitStatusPaneContent` owns a real,
external OS resource — a spawned `git` subprocess that only responds to
`SIGTERM` on its own schedule, plus an `FSEventStream` handle. §1.3's
central finding — no subprocess is needed anywhere in this design, because
libproc/sysctl calls are synchronous, in-process, and sub-millisecond —
means `ProcessStatusPaneContent` owns no comparable external resource.

**A precise statement of what `Task.cancel()` does and doesn't guarantee,
since an earlier draft of this paragraph overstated it.** `Task.cancel()`
itself is synchronous — the call returns immediately, having set the
task's cancellation flag — but the sampling loop's *body* only observes
that flag and unwinds the next time it resumes (e.g. after its next
`Task.sleep`), which is a later turn of the run loop, not something
`tearDown()` can observe having already happened before it returns. That
is exactly the kind of gap `docs/pane-view-lifecycle.md` §5 exists to
catch ("a log line claiming teardown happened is not evidence it
happened"), so it is worth being precise rather than asserting a
guarantee `Task.cancel()` doesn't make. In substance, §5's requirement is
still satisfied here, for a different reason than exact synchronicity of
the cancellation itself: **there is no file descriptor, subprocess, or
kernel-level handle that survives between one sampling call and the
next** — every libproc/`sysctl` call in this design is a single
synchronous round-trip that opens nothing and holds nothing open across
calls, so even if the loop's body takes one more turn to notice
cancellation, there is no resource leaking during that turn, only a
sampling `Task` object that finishes unwinding shortly after. The
sampling loop itself must check `Task.isCancelled` (or catch the
`CancellationError` a cancelled `Task.sleep` throws) **before performing
each sample**, not only between ticks, so a cancellation that lands
mid-loop doesn't run one extra libproc call after `tearDown()` was asked
to stop it. This is a direct, load-bearing consequence of §1's spike (no
subprocess, no kernel handle to invalidate, no `waitUntilExit()` needed) —
it is not a claim that Swift `Task` cancellation is itself synchronous,
which it is not.

**What "suspended" costs**, per `docs/pane-view-lifecycle.md` §4's "zero
periodic work" requirement: literally zero — no running or scheduled
`Task`, no open resource of any kind. A hidden `process-status` pane costs
nothing beyond the few bytes its model object occupies, same as a hidden
Git Status pane, for the same reason `docs/pane-view-lifecycle.md` §1
argues a non-terminal kind has that a Terminal Session doesn't.

**Where the calls come from**, per `docs/pane-view-lifecycle.md` §5's open
item on `showPane`'s asymmetry (`WindowRuntime.hidePane` at
`BattyKit/Sources/BattyKit/Runtime/WindowRuntime.swift:405-433` drives the
terminal path directly; `showPane` at `WindowRuntime.swift:438-445` does
not, relying on remount instead — confirmed current, matching `docs/pane-
view-lifecycle.md`'s own citations): this design does not resolve that
open item either — it is phase 2's wiring question, shared with `#0304`.
What this document commits to on the view's side, identically to Git
Status's own commitment: `ProcessStatusPaneContent.setVisible` is safe to
call redundantly or via a remount-driven path, because
`docs/pane-view-lifecycle.md` §3 requires `.noOp` idempotence at the
state-machine level regardless of caller.

---

## Summary table (quick reference for phase 2)

| Question | Answer | Section |
|---|---|---|
| Feasibility — is reading another process's stats actually possible? | `task_for_pid` fails for every target tested, same-uid or root, matching Batty's own logged failure exactly. libproc (`proc_pidinfo`, `proc_pid_rusage`, `sysctl(KERN_PROCARGS2)`) succeeds instantly for same-uid processes, cross-checked against `footprint`/`ps` and exact-matching. Same-uid only — an EPERM edge case is concretely reachable via Batty's own root-owned pty session leader and via `sudo`. No subprocess fallback needed; libproc beats `ps`/`top` by 3–5 orders of magnitude. | §1 |
| 1. Which process, selected how? | Two modes: pinned pid (CLI `--pid`, tombstones on exit — the literal reading of "a selected process") or following a terminal's foreground process (default, re-resolved every tick via `foregroundPid`, no successor logic needed because there's no single pid to track a successor *for*). Retarget via "Choose Process…" → "Follow a Terminal Pane…" or "Pick a Running Process…". No selection resolves → "No process selected" empty state. | §2 |
| 2. What does it show? | Header (name, pid, mode, state) + always-on core metrics (CPU %, memory footprint, threads, open-file count) bounded to what §1's spike proved obtainable + command line (bonus, cheap) + on-demand disclosures (open files, child processes — computed only when expanded, not every tick, because their cost is O(system size)/O(fd count) rather than O(1)) + permission-unavailable and exited banners as first-class states, not errors. | §3 |
| 3. Refresh cadence? | 1 second for core metrics — a UX choice, not a cost constraint, since §1 measured the per-tick cost at ~0.03 ms. Wired into `PaneContentLifecycle`'s four methods; `setUp`/`setVisible(true)` start/resume a plain `Task`, `setVisible(false)`/`tearDown()` cancel it — no bounded-wait, no subprocess, unlike `#0304`, because this design spawns nothing external. | §4 |

---

## Verification for this issue

**Documentation and a static HTML mockup only — no Swift source changed,
no `PaneRuntime`/`PaneView`/`PaneContentKind` touched.** The feasibility
spike (§1) ran as standalone Swift scripts outside the repository and is
not part of this commit. `scripts/build.sh unit` below is a baseline check
that the branch is known-green going in; it is not evidence of anything
this document proposes, because none of it exists as code yet.

```
scripts/build.sh unit
```

`Configuration/Active.xcconfig` read `#include "Prod.xcconfig"` before
running.

The companion mockup, `docs/design/process-status-view.html`, is a
self-contained (no network requests, no external resources) HTML file
covering six states: a healthy pinned process, a healthy followed
terminal, a process that has exited (tombstone), a metric unavailable due
to permissions, no process selected (no sibling terminal to inherit
from), and a high-churn process mid-sample with the disclosure groups
expanded. It is meant to be opened directly in a browser for review — see
that file for the actual visual design; this document is the reasoning
behind it.

### What phase 2 additionally owes, made visible before approval

Identical obligation to the one `docs/design/git-status-view.md` already
names for `#0304` phase 2, because both views land in the same shared
`PaneView`/`PaneRuntime` path: **whichever issue first lands the
`PaneContentKind` field and `PaneView`'s kind-switch** must re-run the full
manual checklist in `docs/terminal-pane-requirements.md` §6 (pointer
input, drag-select, scroll, file-drop, text-drop, keyboard, IME) on
**terminal** panes generally, and again on a **terminal** pane in a
**mixed-kind session**. If `#0304` phase 2 lands first, `#0305` phase 2
inherits an already-paid cost for the *first* run (the kind-switch
mechanism itself doesn't change per additional kind) but should still
verify a terminal pane alongside a `process-status` pane specifically,
since "fine in isolation, wrong in composition" is a per-combination risk,
not a per-mechanism one.

---

*Document version: 1 — 2026-08-08. Written for `#0305` phase 1. No code
changes accompany this document except the throwaway feasibility spike
(§1), which was run outside the repository and is not part of this
commit. Phase 2 (implementation) is gated on user approval of this
document and its companion mockup, per the `#0301` umbrella's
design-first gate.*
