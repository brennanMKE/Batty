# Git Status view — design (phase 1 of `#0304`)

Design proposal for `#0304`'s design-gated phase 1: the first concrete
non-terminal Pane content kind, `git-status`. **No code ships with this
document.** It answers `#0304`'s four design-phase questions and the
umbrella's design-first gate (`#0301`) so phase 2 implements against a
settled shape instead of re-deriving one mid-build. Read
`docs/pane-kinds.md` (where kind lives, how `PaneView` branches, the
terminal-host boundary) and `docs/pane-view-lifecycle.md` (the
`PaneContentLifecycle` contract this view is the first real client of)
first — this document assumes both and does not re-explain them.

Every source citation below was re-verified against the tree on
2026-08-08 while writing this document (branch `issue/0304`).

---

## 0. What's already decided upstream, and what this document adds

`#0302`/`#0303` settled the *shape* a non-terminal kind must fit into.
This document is the first thing to actually fill that shape in:

- **Kind identifier.** Following `docs/pane-kinds.md` §5's "one string,
  three call sites" rule, this document names the kind `git-status`
  (kebab-case, matching existing CLI verb conventions like `pane split`) —
  the `PaneContentKind` raw value, the CLI `--view` flag value, and the
  `TopologyPanePayload.kind` JSON value are all literally `"git-status"`.
- **The pane has no Tab bar and no `TabRuntime`s** (`docs/pane-kinds.md`
  §1) — everything below describes the single view that fills a
  `git-status` pane's body, not a tab-hosted feature.
- **The conformer is model-owned**, hung off `PaneRuntime` the way
  `TabRuntime.terminal` hangs off `TabRuntime`
  (`docs/pane-view-lifecycle.md` §5, "The conformer is model-owned, not
  view-owned"). This document names the concrete conformer,
  `GitStatusPaneContent`, and what it holds.
- **Not built here**: the `PaneContentKind` enum case, `PaneRuntime.kind`,
  `PaneView`'s kind-switch, the CLI verb (`#0315`, still an open design
  itself). This document is scoped to the view's own design — its data
  source, its refresh strategy, its visual content, its interaction
  model — so `#0304`'s phase 2 and `#0315` each have a settled thing to
  wire in, not two open designs colliding.

---

## 1. Which directory it monitors

**Decision: resolved once at pane creation — from an explicit CLI
`--path`, falling back to the previously-focused Pane's active Tab's
working directory — and frozen thereafter. Not live-following. A
"Change Directory…" folder picker lets the user deliberately retarget.**

### Why frozen, not live-following

A `git-status` pane has no sibling terminal it's structurally attached
to — it's a Pane in its own right, addressed by its own pane id
(`docs/pane-kinds.md` §1: "two Git Status panes watching different
repos side by side" is two *panes*, not one pane tracking a moving
target). Live-following would mean picking *some* terminal Pane's cwd to
track — and, immediately after a `git-status` pane is split off an
existing terminal Pane, that relationship *is* representable: `SplitTree.
inserting` (`BattyKit/Sources/BattyKit/Model/SplitTree.swift:385-392`)
builds exactly `.split(left: .leaf(sourcePane), right: .leaf(newPane))`,
so "the pane this one was split from" is recoverable from tree shape at
the moment of creation. **The reason live-following isn't proposed here
is cost, not model impossibility:**

- **That pairwise relationship doesn't survive later splits.** The
  eroder is `SplitTreeNode.inserting` itself — the same function that
  builds the pairwise relationship in the first place — not
  `rebalancingChain`, which only ever rewrites ratios: every reconstructed
  node in it, in both the same-direction and perpendicular branches
  (`SplitTree.swift:439-489`), preserves the same node id and the same
  `left`/`right` children it was called with, and its own doc comment says
  what it does plainly — "rebalances every ratio in that chain"
  (`SplitTree.swift:420-421`); the only thing that actually mutates
  anything, `rebalancedChain` (`SplitTree.swift:505-526`), changes just
  one field per node it touches — `ratio: Double(leftCount) /
  Double(total)` (`SplitTree.swift:521`) — while reconstructing the same
  `id`/`left`/`right` around it. Shape is untouched. What
  *does* erode the relationship is `inserting`'s own nesting: splitting an
  existing leaf replaces it with a fresh `.split(left: .leaf(existingPane),
  right: .leaf(newPane))` (`SplitTree.swift:385-392`, cited above) — so
  after an initial `split(A, B)`, a third split targeting `B` produces
  `split(A, split(B, C))` (B's immediate sibling is now `C`, not `A`),
  while a third split targeting `A` produces `split(split(A, C), B)` (A's
  immediate sibling is now `C`; B's immediate sibling is now a subtree,
  not `A` directly). Either way, "the pane I was split from" stops being
  recoverable from tree shape alone once a third pane joins — the model
  would need to remember the source pane's id explicitly (a new field,
  new invalidation logic for when that id's pane closes) rather than
  re-derive it structurally on demand. `removingPane`
  (`SplitTree.swift:357-375`) is a second eroder in the other direction —
  removing a pane collapses its parent split to the surviving sibling
  (`return r` / `return l` when the other side is `nil`), so a pane's
  position relative to its original neighbor can also shift up a level
  when something *else* in the chain closes, not just when new panes
  join.
- **The source pane can close** while the `git-status` pane it spawned
  stays open — nothing today tears down a Pane's descendants when its
  sibling closes, and inventing that behavior (does the `git-status` pane
  close too? freeze on the last-known directory? re-resolve to some other
  sibling?) is a design question of its own the user's quote doesn't ask
  to have answered.
- **A CLI-created pane may have no split source at all.** `#0315`'s
  create verb is the primary creation path (§1's Resolution order below),
  and an agent invoking it isn't necessarily splitting off any particular
  terminal Pane the way a mouse-driven "split this pane" action is.

Building the tracking relationship these three points describe (which
terminal Pane, what happens when it closes, what happens on a later
split) is real, unscoped design work the user's quote doesn't ask for
("monitor the current directory," not "follow this pane wherever it
goes"). Freezing at creation is also what the one existing precedent in
this codebase for "which directory does a new thing start in" already
does — Session creation: "a newly created Session's first Pane spawns
its shell in the previously-focused Pane's active-Tab cwd **when one is
known**" (`Concepts.md:50`) — a one-time resolution at creation, not an
ongoing binding.

### Resolution order

1. **CLI `--path <dir>`**, if `#0315`'s eventual create verb supplies
   one. This is the primary path per the umbrella's framing — the CLI is
   the only creation surface either issue actually commits to building
   (`#0301`: "creatable and closable from the `batty` CLI"; nothing in
   `#0304`/`#0301` asks for a toolbar/menu "New Git Status Pane" action).
   `--path` is resolved to an absolute path by the CLI before the XPC
   call, the same way `pane split`'s existing target-resolution chain
   (`#0281`, cited in `issues/0315.md`) already resolves ids before
   sending a request — no relative-path resolution happens app-side.
2. **Fallback: the previously-focused Pane's active Tab's working
   directory, resolved the same way `SplitTree.makePane(inheritingFrom:)`
   already resolves cwd inheritance for a new terminal Pane** —
   `sourceTab.terminal.workingDirectory ?? sourceTab.terminal.
   configuration.workingDirectory` (`BattyKit/Sources/BattyKit/Model/
   SplitTree.swift:208-215`, confirmed current), not
   `TabRuntime.workingDirectory` alone. That distinction matters: `TabRuntime
   .workingDirectory` (`BattyKit/Sources/BattyKit/Runtime/TabRuntime.swift:47`)
   is the Observation-tracked mirror the file's own doc comment
   (`TabRuntime.swift:35-46`) says *view-reachable* code must read instead
   of the live Combine value — but it's written only once the pwd delegate
   actually fires (`syncWorkingDirectoryFromTerminal()`), so it's still
   `nil` for a just-spawned Tab whose surface hasn't reported its cwd yet.
   Falling back to `TabRuntime.workingDirectory` alone would send a
   `git-status` pane created against a freshly-split terminal straight to
   `$HOME` instead of that tab's actual start directory. Resolving cwd at
   pane-creation time is model-layer, non-view code — exactly the
   category `TabRuntime.swift:43-44`'s own doc comment says may still read
   the live Combine value directly — so this reuses `makePane`'s existing
   pattern rather than inventing a new one. Used when `--path` is omitted
   or the pane is created some other way in the future.
3. **Fallback of last resort: `$HOME`.** If neither above resolves (no
   focused pane exists, e.g. a freshly launched window with no terminal
   yet), the view opens against the user's home directory rather than
   failing outright — it will almost certainly show "not a Git
   repository," which is a defined, non-error state (§1.2 below), not a
   crash.

### Retargeting: "Change Directory…"

A toolbar affordance (folder-picker glyph, matching the restrained icon
language `PaneView` already uses for `paneEyeButton`/`paneDragHandle` —
`BattyKit/Sources/BattyKit/Views/PaneView.swift:296-348`, SF Symbols at
11pt semibold, `.buttonStyle(.borderless)`, `.foregroundStyle(.secondary)`)
opens an `NSOpenPanel` (directory-only) and, on selection, tears down the
current watcher and re-runs setup against the new path — the same
"one-time resolution, explicit re-trigger" shape as creation, just
user-initiated instead of CLI-initiated. This keeps the "frozen, not
live" design honest: the *only* way the monitored directory changes is a
deliberate user action, never an implicit side effect of something
happening in an unrelated terminal.

### Not-a-repo, submodule, worktree

All three are handled by running `git` itself and reading its own signal
— no client-side repo-shape detection beyond what `git rev-parse` already
reports:

- **Not a Git repository.** `git -C <path> rev-parse --is-inside-work-tree`
  exits non-zero. The view shows a `ContentUnavailableView`-style empty
  state (matching the existing convention: `BellFeedView`'s empty state
  at `BattyKit/Sources/BattyKit/Views/BellFeedView.swift:26-32`, and
  `SessionDetailView`'s at `BattyKit/Sources/BattyKit/Views/SessionDetailView.swift:207-212`)
  — resolved path visible, "Not a Git repository," and the "Change
  Directory…" action as the way out. See mockup state 4.
- **Submodule.** A submodule's `.git` is a *file* (not a directory)
  containing `gitdir: <parent>/.git/modules/<name>`. `git rev-parse
  --git-dir` (and every other porcelain command this design runs)
  already resolves that transparently — no special-casing needed for
  `git status` itself to work correctly. The view surfaces the fact
  cosmetically: `git rev-parse --show-superproject-working-tree` prints
  the parent's working tree path when the current directory is inside a
  submodule (empty otherwise), so a non-empty result adds a small
  "Submodule of `<parent-name>`" label under the repo name in the header
  — informational only, no behavior change.
- **Linked worktree.** `git rev-parse --git-common-dir` differs from
  `git rev-parse --git-dir` exactly when the current checkout is a linked
  worktree (`--git-dir` points at `<main-repo>/.git/worktrees/<name>`;
  `--git-common-dir` points at the shared `<main-repo>/.git`). When they
  differ, the header adds a small "Worktree" badge next to the branch
  name. Status/staging/branch data all come from the same `git status`
  invocation regardless — worktrees are a first-class `git status`
  target, nothing conditional needed there either.

Both of these are single, cheap, additional `git rev-parse` calls run
once at setup (and again after a "Change Directory…" retarget) — not on
every refresh tick, since a repo doesn't change from a plain checkout to
a submodule/worktree while being watched.

---

## 2. What it shows

The user's framing is explicit: exploit what a Mac app can do that a TUI
can't, not `git status` in a nicer font. The design leans on three native
affordances a terminal can't offer: **disclosure** (conflicted/staged/
unstaged/untracked as independently collapsible groups, not one flat
list — see the Layout section below for why conflicted is a fourth,
conditional group, not a fixed three), **selection** (click a file to
see more, not just read it), and **inline diff peeks** (a click reveals
a diff without leaving the pane or opening another window).

### Layout (see the HTML mockup for the concrete visual)

1. **Header row** — repo name (basename of the toplevel), current branch
   (or "detached HEAD @ `<short-sha>`"), ahead/behind counts as small
   arrows-with-numbers (`↑2 ↓1`) when an upstream is configured, a stash
   count badge when non-zero, and the Submodule/Worktree badges from §1
   when applicable. A right-aligned "Change Directory…" button and a
   manual refresh button (for the rare case a user wants to force a
   re-scan without waiting for the watcher/debounce), **plus the same
   pane-level drag handle and hide (eye) button every terminal Pane
   already has.** `docs/pane-kinds.md` §2 keeps `PaneView`'s pane-level
   chrome — the focus/bell overlays and `PaneFramePreferenceKey` geometry
   reporting — outside the kind switch specifically so "a Git Status pane
   swaps, resizes, and drags exactly like a terminal pane"
   (`docs/pane-kinds.md:210`). But the *mouse affordances* for two of
   those pane-level actions,
   `paneDragHandle` and `paneEyeButton`, currently render **inside** the
   tab-bar `HStack` (`BattyKit/Sources/BattyKit/Views/PaneView.swift:80-119`,
   specifically the trailing `if hasSiblingPanes { paneDragHandle }` /
   `paneEyeButton` block at `PaneView.swift:114-118`) — which is exactly
   the block that only exists in the `.terminal` arm under `docs/pane-kinds.md`
   §2's design. Without a header-level substitute, a `git-status` pane
   would have no mouse-reachable way to hide itself or start a pane-swap
   drag, even though the tree-level mechanics both actions depend on
   (`hidePane`, `PaneSwapDragState`) stay pane-agnostic. This header row
   is that substitute: the same `eye.slash` / `squareshape.split.2x2.
   dotted.inside` SF Symbols, the same 22×22pt borderless-button treatment,
   the same conditional (`hasSiblingPanes`) gating the drag handle, just
   relocated from the tab-bar `HStack` to this view's own header — no new
   interaction, only a new location for an interaction every other pane
   kind already has.
2. **State banner** — appears only when the repo is mid-operation:
   rebase-in-progress, merge-in-progress (with conflict count), or
   cherry-pick-in-progress. Read from `.git/rebase-merge` /
   `.git/rebase-apply` / `.git/MERGE_HEAD` / `.git/CHERRY_PICK_HEAD`
   presence (§4 covers how the watcher notices these). Styled as a
   prominent accent-colored banner, not just another list row — this is
   the state most likely to actually need the user's attention.
3. **Grouped, disclosable file lists** — **Conflicted** (only present
   during a merge/rebase/cherry-pick with unresolved conflicts — porcelain
   v2 reports these as `u` unmerged-entry lines, a distinct record type
   from the ordinary `1`/`2` changed-entry lines **Staged Changes** and
   **Changes** read (**Untracked Files** reads a third record type again,
   `?` lines), so the Conflicted group's presence is driven directly by
   whether any `u` lines exist in that scan, not by the state banner's own
   git-state-file check), **Staged Changes**, **Changes** (unstaged),
   **Untracked Files**, each a `DisclosureGroup` (or equivalent) with a
   count in its
   header, collapsed/expanded state remembered per pane for the session.
   When present, **Conflicted** sorts first — a conflict blocks the rebase
   from completing, so it's the most actionable group in the list. Each
   row: a two-letter status badge (`M`, `A`, `D`, `R`, `U` for unmerged,
   `??`, colored per the existing terminal convention — green for
   added/staged, orange/yellow for modified, red for deleted/unmerged,
   gray for untracked — matching the semantic colors
   `ChromePalette.init`'s own comment explicitly avoids repurposing for
   chrome, `BattyKit/Sources/BattyKit/Theme/ThemeChrome.swift:88-89`,
   because "red/green/yellow... map to errors/success/warning in
   terminal-land" — exactly the vocabulary a status view should use,
   not avoid), the file's path (basename bold, containing directory
   dimmed — a new visual treatment for this view, though the underlying
   single-line, middle-truncated rendering for long paths follows the
   existing convention `BellFeedRow` already uses at
   `BattyKit/Sources/BattyKit/Views/BellFeedView.swift:146-149`), and for
   a rename, `old → new`.
4. **Selection reveals a diff peek**, inline, not a new window: clicking
   a file row expands an inset panel directly below it showing the
   file's diff hunks (`git diff` for unstaged, `git diff --cached` for
   staged), monospaced, with the same +/- line coloring a terminal user
   already expects from `git diff` — but scrollable, selectable, and
   syntax-neutral (no need for a full diff-highlighting engine in phase
   2; a monospaced text block with colored gutter markers already beats
   "read it in the TUI"). Selecting a different file replaces the peek
   rather than stacking multiple open peeks, keeping the pane from
   becoming unbounded.
5. **Non-mutating context menu** on a file row: "Reveal in Finder,"
   "Copy Path," "Open in Default Editor" (`open <path>` — a Finder-style
   default-app launch, not the terminal `$EDITOR`). All read-only with
   respect to the repo itself — no git mutation, matching §3's read-only
   decision.

### What's deliberately not shown in phase 2

Line-level blame, commit history/log, remote management, and full-file
content view are out of scope — none of it is what "shows git status
visually" asks for, and each is its own feature-sized surface. If a
future issue wants a "click a file to open its full diff/history in a
dedicated pane" flow, that's new scope for that issue to argue, not
something this design pre-builds room for.

---

## 3. Read-only or interactive

**Decision: read-only for the first ship. Selection, disclosure, and the
diff peek (§2) are interactive UI, but none of them mutate the repo.
Staging, unstaging, and discard are explicitly deferred — not designed
here, not stubbed, not half-built behind a feature flag.**

This is the conservative option the issue names as available, and it's
the right one for three concrete reasons specific to this codebase, not
just "safety in the abstract":

- **Discard is irreversible and the codebase has no precedent for
  guarding a destructive git action.** The closest existing analogue,
  paste-confirmation (`PRD.md` §6.10, "Paste 3 lines?"), guards against
  an accidental multi-line paste — a much smaller blast radius than
  `git checkout -- <file>` or `git clean`, which can destroy uncommitted
  work with no undo. Getting that confirmation flow right (what counts
  as "are you sure," whether a single-file discard needs the same
  friction as a bulk discard, whether it should ever be available
  without a confirmation) is real design work this document isn't
  scoped to do, and shipping it wrong is worse than not shipping it.
- **It keeps phase 2 small**, which is what the issue explicitly asks
  the design to optimize for ("a read-only first cut... keeps phase 2
  small"). Read-only means phase 2 is: a watcher, a `git status` parser,
  and a SwiftUI list/detail view — no mutation-path error handling, no
  XPC round-trip for a destructive action's confirmation, no interaction
  with the CLI's `#0315` create/close verbs beyond "the pane exists."
- **Nothing in the umbrella's user quotes asks for interactivity.** The
  user's own framing is "show status... in a more visual way" — every
  quote is about *seeing*, not *acting*. Staging/unstaging/discard are
  the issue's own "obvious next asks," named as a risk to settle, not a
  requirement to build.

**Explicit non-goal for this ship, not a promise about the next one:**
if staging/discard is wanted later, it's new scope for a follow-up issue
to design deliberately — including its own confirmation UX — rather
than something this document reserves space for speculatively.

---

## 4. How it stays current

**Decision: FSEvents-based watching of the working tree, software-
debounced, driving an async `git status` subprocess — never run
concurrently with itself, coalesced under load — wired into
`PaneContentLifecycle`'s four methods exactly as that contract specifies.**

### Data source: spawn `git`, not a library

Batty spawns `git status` via `Foundation.Process`, the same primitive
already used in this codebase for subprocess launching — `AppLauncher.swift`
(`BattyKit/Sources/batty/AppLauncher.swift:18-23`, `Process()` +
`executableURL` + `waitUntilExit()`) is the CLI target's own existing
pattern, though `BattyKit` itself spawns no subprocess today (verified:
no `Process()` call anywhere under `BattyKit/Sources/BattyKit`). Spawning
the user's real `git` — resolved via `$PATH`, so it picks up whatever
`git` the user has configured (custom builds, corporate wrappers,
`git-lfs` filters, credential helpers) — is consistent with the project's
existing trust model: `CLAUDE.md`'s architectural rules state the app is
**unsandboxed** specifically because "Terminal apps run arbitrary user
processes... and can't fit App Store sandbox rules." A view that shells
out to the user's own `git` is a strictly smaller trust extension than
the shells Batty already runs continuously in every terminal Pane. A
library (libgit2-backed Swift bindings) was considered and rejected:
it adds a new dependency, and — more substantively — it would compute
status using its own reimplementation of git's logic rather than the
user's actual `git`, config, and hooks, which can diverge (custom
`.gitattributes` filters, `core.fsmonitor`, LFS-tracked files) in ways
that would make the view lie about what a terminal `git status` in the
same directory would show. Consistency with the terminal the user is
already looking at matters more here than avoiding a subprocess spawn.

**Command:** `git --no-optional-locks -C <path> status --porcelain=v2
--branch --show-stash`. `--porcelain=v2` is the machine-stable format
(unlike plain `git status`, whose human-readable text is not a contract
git promises to keep byte-for-byte across versions); `--branch` adds
`# branch.oid` / `# branch.head` / `# branch.upstream` / `# branch.ab`
header lines in the same output, so branch name and ahead/behind come
from the same call as file status — no second subprocess just for the
header. `--show-stash` (git ≥ 2.35) adds a `# stash <N>` line for the
stash-count badge, same reasoning. One subprocess call produces
everything §2's header and file lists need except the rebase/merge/
cherry-pick state, which comes from reading `.git` directly (below) since
porcelain v2 doesn't report it.

`--no-optional-locks` is not optional here, and an earlier draft of this
document omitted it. Plain `git status` takes `.git/index.lock` to write
back a refreshed index as a performance optimization — a lock the user's
*own* shell, sitting in the terminal Pane right next to this one, can
collide with: any `git` command the user runs while this watcher's
refresh happens to be mid-write fails with `fatal: Unable to create
'.../index.lock': File exists`, for a reason that has nothing to do with
anything the user did. `--no-optional-locks` (and the equivalent
`GIT_OPTIONAL_LOCKS=0`) is git's own documented flag for exactly this
class of tool — a status-monitoring process that must never contend with
the user's interactive git usage — and it means this design's refresh
takes no lock the user could ever observe or collide with, on every
refresh, not just the periodic ones that happen to race a manual `git`
invocation.

### Watcher: FSEvents, not `DispatchSourceFileSystemObject`

`DispatchSourceFileSystemObject` watches a single open file descriptor —
it does not recurse into subdirectories, so watching a repo's working
tree (arbitrarily deep, arbitrarily many directories) with it would mean
manually opening and tracking a descriptor per directory, an unbounded
and constantly-changing set as directories are created/removed. FSEvents
(`FSEventStreamCreate` from `CoreServices`) is macOS's actual primitive
for "tell me about changes anywhere under this directory tree," coalesces
many rapid changes into batched callbacks at the OS level before Batty
even sees them, and is what every other macOS dev tool with this exact
requirement (Xcode's file-change detection, `fswatch`, Sourcetree) is
built on. No existing FSEvents usage exists in this codebase to follow as
precedent (verified: no `FSEventStream`/`DispatchSourceFileSystemObject`
hits anywhere under `BattyKit/Sources`) — this is new surface, named here
so phase 2 doesn't have to make the same "which primitive" decision
without justification.

**What's watched:** the resolved repository path (§1) — for a linked
worktree, both the worktree's own directory (for working-tree file
changes) and `.git/HEAD` / `.git/MERGE_HEAD` / the shared common-dir's
`rebase-merge`/`rebase-apply` markers (for git-state changes, since a
linked worktree's own `.git` is a file pointing elsewhere per §1, and
FSEvents needs a real path to watch — resolved once via the same
`git rev-parse --git-common-dir` call §1 already makes).

### Debounce: two layers, for two different noise sources

1. **A repo mid-build emitting thousands of file events** (the issue's
   own named scenario — e.g. a build writing hundreds of object files
   under a build directory that happens to be inside the watched tree,
   though typically `.gitignore`d and therefore invisible to `git status`
   itself, the *events* still fire). Software debounce: every FSEvents
   callback resets a single pending-refresh timer (e.g. 400ms); the
   actual `git status` run only fires once the timer elapses with no new
   events — a burst of thousands of writes collapses to one refresh
   after the burst quiets down, not one refresh per event. This is the
   same "coalesce, don't react per-event" shape `docs/pane-view-lifecycle.md`
   §4 already requires generically ("showing resumes... and performs one
   immediate refresh," not one per redundant call).
2. **A `git status` call still running when the debounce timer fires
   again** (a genuinely huge repo, or a slow filesystem/network mount).
   The refresh path tracks a simple "in-flight" flag: if a new refresh is
   requested while one is already running, it does **not** spawn a second
   overlapping `git status` — it sets a "run once more after this one
   finishes" flag and lets the current call complete, then immediately
   re-runs exactly once. This bounds concurrent subprocess count to 1 per
   pane regardless of how bursty the triggering events are, and
   guarantees the view eventually reflects the latest state without an
   unbounded queue of stale-by-the-time-they-run `git status` calls.

### Cost on a huge working tree

`--porcelain=v2` without `--untracked-files=all` (i.e., the git default,
`--untracked-files=normal`) does **not** recurse into an untracked
directory enumerating every file inside it — it reports the directory
itself as one untracked entry, exactly like plain `git status` does by
default. This bounds the worst case to roughly what an interactive `git
status` already costs in the same repo — the view is not doing
meaningfully more work than the user could already do by typing the
command themselves, and inherits the same environment (`.gitignore`,
any `core.fsmonitor`/Watchman integration the user's own `git` config
already has configured) rather than reimplementing traversal.

**The subprocess runs off the main thread** — `Process` launched from a
background queue (or wrapped in an async context reading stdout via a
pipe on a background thread), never blocking the SwiftUI main actor
while a slow `git status` is in flight. If a refresh is still running
past a short threshold (e.g. 1 second), the header shows a small
"Refreshing…" indicator (not a full-view loading state — stale-but-valid
data stays visible and interactive while the refresh continues in the
background) rather than blocking the view with a spinner. See mockup
state 5 ("large repo / loading").

### `.git` churn during a rebase

Two things change during a rebase that the watcher must handle correctly:

- **`.git/index.lock` is created and removed by nearly every git
  operation**, including ones triggered by the refresh's own `git
  status` call (which itself briefly takes the index lock). Watching
  `.git` naively would make the view's own refresh re-trigger itself.
  The design avoids this by **not** watching `.git/index.lock`
  specifically — FSEvents on the repo root will still report the
  create/remove, but it lands inside the same debounce window as
  everything else (§ above), so a self-triggered lock-file churn just
  collapses into the next already-scheduled refresh rather than causing
  a second one immediately after.
- **Rebase/merge/cherry-pick state is a set of marker files**
  (`.git/rebase-merge`, `.git/rebase-apply`, `.git/MERGE_HEAD`,
  `.git/CHERRY_PICK_HEAD`) that `--porcelain=v2` does not report on
  directly. The refresh path does one additional cheap check — `git
  rev-parse --git-path` for each marker, or a direct `FileManager`
  existence check against the resolved `.git`/common-dir path from §1 —
  alongside the `git status` call, populating the state banner (§2.2).
  This is existence-checking a handful of fixed paths, not a second
  subprocess.

### Lifecycle wiring — the `PaneContentLifecycle` contract, concretely

`GitStatusPaneContent` conforms to `PaneContentLifecycle`
(`BattyKit/Sources/BattyKit/Runtime/PaneContentLifecycle.swift:110-138`,
confirmed current) via a `PaneLifecycleController`
(`PaneContentLifecycle.swift:146-161`) exactly as
`docs/pane-view-lifecycle.md` §6 prescribes:

| Contract method | What it does here |
|---|---|
| `setUp(visible: Bool)` (`PaneContentLifecycle.swift:123`) | Resolves the directory (§1), runs the one-time `git rev-parse` shape checks (§1's submodule/worktree detection). If `visible == true`: creates the `FSEventStream`, runs the first `git status`. If `visible == false`: resolves the directory and does the one-time checks (so the header has something to show the instant it's revealed) but does **not** create the FSEvents stream or spawn `git status` — per `docs/pane-view-lifecycle.md` §4, "setup must not create work it would immediately have to suspend." |
| `setVisible(true)` (a `suspended → active` transition, `PaneContentLifecycle.swift:130`) | Creates the `FSEventStream` (it doesn't exist yet — suspended means fully torn down, not paused, per §4 below) and performs exactly one immediate `git status` refresh, matching the "showing resumes and refreshes" rule (`docs/pane-view-lifecycle.md` §4) — the repo may have changed while the pane was hidden and the debounce/watcher were both stopped. |
| `setVisible(false)` (an `active → suspended` transition) | `FSEventStreamStop` + `FSEventStreamInvalidate` + `FSEventStreamRelease` — the stream is fully torn down, not merely paused, so a hidden `git-status` pane costs zero FSEvents overhead and holds no open stream handle. Cancels the debounce timer. If a `git status` subprocess is in flight, sends `SIGTERM` (`Process.terminate()`) but does **not** wait for it to exit — hiding carries no synchronous-teardown requirement from `docs/pane-view-lifecycle.md` (only `tearDown()` does, per its §5), so a quick hide (a fast session switch) stays cheap. Discards whatever the subprocess produces, whether it's killed or finishes on its own, rather than updating UI for a pane that's no longer visible, and does not schedule the "run once more" follow-up from § above. |
| `tearDown()` (`PaneContentLifecycle.swift:137`) | Same release sequence as `setVisible(false)` (idempotent whether called from `.active` or `.suspended`, per the state machine's `.applied(from: _, to: .tornDown)` transitions at `PaneContentLifecycle.swift:77-80`), plus `Process.terminate()` on any in-flight `git status` subprocess **followed by a bounded wait** — see the paragraph below the table for why this can't be an unbounded `waitUntilExit()` and what "bounded" means concretely. |

**The `tearDown()` wait is bounded, deliberately, not unbounded — naming
the trade-off `docs/pane-view-lifecycle.md` §5 forces.** That document's
binding requirement is that teardown release everything "synchronously
and deterministically... before `tearDown()` returns," carrying forward
`#0289`'s lesson that a log line (or, here, a fire-and-forget `terminate()`
call) is not evidence release happened. `Process.terminate()` only sends
`SIGTERM` and returns immediately — it does not wait for the child to
actually exit, so calling it alone would repeat exactly the mistake
`#0289` fixed for terminal surfaces: claiming synchronous teardown while
the actual resource release (the OS reclaiming the process, its file
descriptors, its lock/temp-file state) is still pending on the child's
own schedule. The honest fix is `terminate()` followed by
`waitUntilExit()` — but `waitUntilExit()` **blocks the calling thread**,
and the calling thread here is the main actor (`PaneContentLifecycle`
conformers are model objects driven from `WindowRuntime.closePane`,
itself main-actor code per this project's default isolation). An
unbounded wait is not acceptable either: a `git` process blocked in a
syscall against a stalled network-mounted repository (an edge case, but
a real one — nothing about this design assumes every watched path is on
local disk) would freeze the app's main actor for as long as that syscall
stays blocked, trading a resource leak for a hang, which is a worse
failure mode. **The design's answer: `terminate()`, then wait with a
short, fixed bound** (e.g. a poll loop on `Process.isRunning` capped at a
low number of hundreds of milliseconds, not `waitUntilExit()`'s
unbounded block) — a git process normally dies within milliseconds of
`SIGTERM`, so the bound is essentially never hit on the common path, and
`tearDown()` returns having genuinely observed the process exit. On the
pathological path (the stalled network mount), the bound is hit,
`tearDown()` logs a warning and returns anyway rather than hanging the
main actor indefinitely — an explicit, documented residual gap instead of
a claimed guarantee the design can't actually keep. This also resolves
the two rows above reading as inconsistent: both `setVisible(false)` and
`tearDown()` now always attempt `terminate()` when a subprocess is in
flight (killing mid-write is no longer the hazard it would have been
without item 2's `--no-optional-locks` fix, since the refresh no longer
takes `.git/index.lock` in the first place); the two differ only in
whether they wait afterward, and only `tearDown()` does, because only
`tearDown()` carries the synchronous-teardown obligation. A conformer
must guard the `terminate()` call itself with the same in-flight flag
already tracked for §4's second debounce layer — `Process.terminate()`
raises `NSInvalidArgumentException` if called against a `Process` that
was never launched, so "is a subprocess currently running" has to be
known precisely, not assumed from "a refresh was requested."

**What "suspended" costs**, per `docs/pane-view-lifecycle.md` §4's "zero
periodic work" requirement: literally zero — no open `FSEventStream`, no
running or scheduled `git status`, no debounce timer armed. This is
exactly the freedom that document's §1 argues a non-terminal kind has
that a Terminal Session doesn't (no GPU swap chain, no PTY forcing a
"stop rendering but keep the resource" compromise) — a hidden Git Status
pane can go to true zero, not just quiet.

**Where the calls come from**, per `docs/pane-view-lifecycle.md` §5's
open item on `showPane`'s asymmetry: this design does not resolve that
open item — it's `#0303`'s/phase 2's wiring question, not this view's.
What this document commits to on the view's side: `GitStatusPaneContent`
must not assume it will only ever be told to become visible via a
`WindowRuntime.hidePane`/`showPane` style direct call — its `setVisible`
implementation is safe to call redundantly or via a remount-driven path
either way, because `docs/pane-view-lifecycle.md` §3 requires `.noOp`
idempotence at the state-machine level regardless of caller.

---

## Summary table (quick reference for phase 2)

| Question | Answer | Section |
|---|---|---|
| 1. Which directory? | CLI `--path`, else previously-focused Pane's Tab cwd, else `$HOME`. Frozen at creation; user can retarget via an explicit "Change Directory…" picker. Not-a-repo is a defined empty state; submodule/worktree are detected via `git rev-parse` flags and shown as informational badges, with no behavior change to status computation. | §1 |
| 2. What does it show? | Header (repo, branch, ahead/behind, stash count, submodule/worktree badges) + state banner (rebase/merge/cherry-pick) + four disclosable, grouped file lists (conflicted — conditional, sorts first — /staged/unstaged/untracked) with colored status badges + click-to-select inline diff peek + non-mutating context menu (Reveal in Finder, Copy Path, Open in Default Editor). | §2 |
| 3. Read-only or interactive? | Read-only for this ship. Selection/disclosure/diff-peek are interactive UI but mutate nothing. Staging/unstaging/discard explicitly deferred to a future issue, not designed or stubbed here. | §3 |
| 4. How does it stay current? | FSEvents on the resolved path (+ `.git` state markers for worktrees), two-layer debounce (event coalescing + in-flight-call coalescing), async off-main-thread `git --no-optional-locks status --porcelain=v2 --branch --show-stash` subprocess (spawned via `Process`, the user's real `git`, never contending for `.git/index.lock` with the user's own terminal). Wired into `PaneContentLifecycle`'s four methods exactly per `docs/pane-view-lifecycle.md` §6 — suspended means the FSEventStream is fully released, not paused; showing re-creates it and forces one refresh; teardown sends `SIGTERM` and waits with a bounded timeout, not an unbounded block on the main actor. | §4 |

---

## Verification for this issue

**Documentation and a static HTML mockup only — no Swift source changed,
no `PaneRuntime`/`PaneView`/`PaneContentKind` touched.** `scripts/build.sh
unit` below is a baseline check that the branch is known-green going in;
it is not evidence of anything this document proposes, because none of
it exists as code yet.

```
scripts/build.sh unit
```

`Configuration/Active.xcconfig` read `#include "Prod.xcconfig"` before
running. Observed: **969 tests in 112 suites passed**, `** TEST
SUCCEEDED **` — matching the expected baseline. `git status` after the
run showed no `Batty.xcodeproj/project.pbxproj` residue.

The companion mockup, `docs/design/git-status-view.html`, is a
self-contained (no network requests, no external resources) HTML file
covering five states: clean repo, mixed staged/unstaged/untracked
changes, mid-rebase with a conflict, not-a-git-repository, and a
large-repo/loading state. It is meant to be opened directly in a
browser for review — see that file for the actual visual design; this
document is the reasoning behind it.

### What phase 2 additionally owes, made visible before approval

Landing this design touches the shared pane path in ways that carry a
real, binding verification cost beyond this issue's own scope.
`docs/pane-kinds.md` §6 obligates **whichever issue first lands the
`PaneContentKind` field and `PaneView`'s kind-switch** — phase 2 of
`#0304` is that issue — to re-run the full manual checklist in
`docs/terminal-pane-requirements.md` §6 (pointer input, drag-select,
scroll, file-drop, text-drop, keyboard, IME) **twice**: once on
**terminal** panes generally, because `activeTabID` becoming optional and
`PaneRuntime.init`'s precondition changing shape touch code every
terminal pane's rendering path depends on; and again on a **terminal**
pane in a **mixed-kind session** (a `git-status` pane open alongside a
terminal pane), to catch a regression that's fine in isolation but wrong
in composition. Neither run can be scripted — the checklist requires GUI
access — so phase 2's implementer should budget for it explicitly rather
than discover it mid-review.

---

*Document version: 1 — 2026-08-08. Written for `#0304` phase 1. No code
changes accompany this document. Phase 2 (implementation) is gated on
user approval of this document and its companion mockup, per the `#0301`
umbrella's design-first gate.*
