# Batty

A native macOS terminal multiplexer built on libghostty. Single-window-by-default, session sidebar, splits and tabs, bell-driven notification feed. macOS 15+. See `PRD.md` for the product spec and `Concepts.md` for the canonical vocabulary used throughout this tracker.

This file is the local guide for managing issues in this project. The companion Mac app (Issues.app) watches the `issues/` folder and renders the current state. Markdown files (and `project.json`) are the source of truth — there is no generated artifact or index to keep in sync.

The `# Batty` heading above matches the `name` field in `issues/project.json`. `project.json` is the canonical source for the project's identity (name + repo URL); this guide is the workflow companion.

## Folder layout

```
issues/
├── project.json       # canonical project name + repo URL
├── Issues.md          # this file
├── model-pricing.json # daily-refreshed model price cache (see "Token usage and cost tracking")
├── 0001.md            # one file per issue
├── 0001/              # optional sibling folder for screenshots, crash logs, etc.
│   └── screenshot.png
├── 0002.md
└── …
```

## Project config (`project.json`)

A small JSON file naming the project and its repo. Two required fields:

```json
{
  "name": "Batty",
  "url": "https://github.com/user/repo"
}
```

- `name` — the project's human-readable name. Match the heading at the top of this file.
- `url` — the project's canonical web URL (HTTPS form, not SSH). Currently empty until the GitHub remote is set up; populate then.

When the repo moves or renames, edit `project.json` directly. Don't infer the project's name from the parent folder path — `project.json` is authoritative.

## Status values

| File value | Display name | Meaning |
|---|---|---|
| `open` | Open | Filed but not yet started |
| `in-progress` | In Progress | Actively being worked on |
| `resolved` | Resolved | Work is done; awaiting user confirmation |
| `closed` | Closed | User has confirmed the fix |
| `wontfix` | Won't Fix | Acknowledged but won't be addressed |

Use the **file value** (lowercase, hyphenated) in the issue's metadata table. The Mac app converts to the display name when rendering.

## Critical rule: never close without explicit confirmation

The most important rule of this workflow: an issue must **never** be marked `resolved`, `closed`, or `wontfix` based on inference. Only when the user has said so in plain language. Specifically, do not infer resolution from:

- a code change you (or a subagent) just made
- a commit message
- the filing of a related issue
- the user saying "thanks, that looks better"

Leave status at `open` (or `in-progress` if work has started) until the user confirms in words like "close this", "this is fixed", "mark resolved", or "won't fix". When in doubt, ask.

The deliberate exception: the **review subagent** (phase 3 of the workflow below) sets `resolved` after independently re-verifying the change on the issue branch (work-is-done-but-not-confirmed). The implementer never sets `resolved` — it leaves the issue `in-progress` for review. Nothing and nobody but the user sets `closed`. This separation is the entire reason `resolved` and `closed` are different states.

## Git tracking

This project's `issues/` folder is **tracked by git** — bug-tracking history lives alongside code history.

Check on every operation:

```bash
git rev-parse --is-inside-work-tree 2>/dev/null   # is this a git repo?
git check-ignore -q issues/                        # exit 0 = ignored, 1 = tracked
```

Issue work happens on **per-issue branches** (`issue/NNNN`) that land on `main` as a single squash commit (see "Resolving an issue" below). That splits commits into two regimes.

Commits on **`main`**:

| Event | What's committed | Commit message |
|---|---|---|
| Initial setup | `project.json` + `Issues.md` together | `Add issue tracker setup` (or bundle with the first `#NNNN` commit) |
| File a new issue | the new `NNNN.md` (and `project.json` / `Issues.md` if newly created) | `#NNNN <issue title>` |
| Edit project config | `project.json` only | `Update project config` (or e.g. `Update project URL`) |
| Resolved issue lands (squash merge of `issue/NNNN`) | everything the branch touched — code, `NNNN.md` plan and resolution sections, work-log rows | `#NNNN <verb> <title>` (single line, kept simple — the issue file carries the detail) |
| Bail with notes | markdown only | `#NNNN Notes: <brief>` |
| Daily pricing refresh | `model-pricing.json` only | `Update model pricing` |
| User-confirmed close | markdown only | `#NNNN Close` |
| Won't fix | markdown only | `#NNNN Won't fix` |

Commits on an **issue branch** (`issue/NNNN`): commit freely, messages prefixed `#NNNN` — `#NNNN Plan`, `#NNNN Claim` (the `in-progress` flip), implementation checkpoints and the code commit, `#NNNN Draft resolution`, `#NNNN Review: <reason>` (a bounce), `#NNNN Resolve: <title>` (the reviewer's approval), and `#NNNN Work log: <phase>` rows. Granularity doesn't matter: there may be five or more commits on the branch, and the squash merge collapses them all into one commit on `main`.

**Why a branch per issue, squashed on merge:** stalled work is never discarded — a bailed attempt stays on its branch for the next try to resume; the implementer can checkpoint without polluting `main`; the reviewer examines exactly the diff that will land (`git diff main...issue/NNNN`); and `main` stays readable — one `#NNNN` commit per issue, greppable with `git log --grep='#NNNN'`.

**Branches are kept after the merge.** The squash carries the content to `main`, but the retained branch preserves the commit-by-commit history (checkpoints, review rounds, fixes) for later review via `git log main..issue/NNNN`. Issue branches are local working history — they normally aren't pushed to the remote, and they're never deleted.

Note: the Mac app renders the checked-out working copy, so while `issue/NNNN` is checked out it shows that branch's state of the issue (e.g. `in-progress`). After the merge, `main` shows it `resolved`.

## Issue file format

Each issue is `NNNN.md` (4-digit zero-padded) with this structure:

```markdown
# NNNN — Title

| | |
|---|---|
| **Status** | open |
| **Module** | <module name(s)> |
| **Platform** | macOS |
| **First seen** | YYYY-MM-DD |

## Description

What is wrong (or what's missing, for feature work). Lead with the punchline — the first paragraph shows in the Mac app summary.

## Steps to reproduce

1. …
2. …

## Expected behavior

What should happen.

## Actual behavior

What actually happens.

## Attachments

![caption](NNNN/screenshot.png)

## Notes

Any additional context, guesses at root cause, related code locations.
```

### Format details that matter

- **Title separator** is an em-dash (U+2014, `—`), not a hyphen.
- **Metadata field rows** must keep the field name in `**bold**` exactly.
- **Dates** are `YYYY-MM-DD`.
- **Module** can list multiple modules separated by ` / ` (e.g. `Pane / Tabs`).
- **Platform** is `macOS` for almost every issue in this project. Use `All` only if it genuinely spans build/CI/docs concerns.
- When status moves to `resolved` or `closed`, add a `**Closed**` row with today's date. When the move to `resolved` comes from a review-approved issue branch, also add a `**Branch**` row (`issue/NNNN`). There is no `**Commit**` row: the squash-merge hash doesn't exist until after the issue file's content is final, so the landing commit is identified by its `#NNNN` message instead (`git log --oneline --grep='#NNNN'`).
- Steps / Expected / Actual / Attachments / Notes are conventional but not all required — for design-refinement or feature-gap issues, Description alone is fine.

## Filing a new issue

New issues are filed by a **filer subagent on Opus** (`model: "opus"`, `effort: "medium"`) — user directive "Use Opus, not Fable", restated 2026-10-14. The orchestrator dispatches a fresh filer with the report details; the filer reads `issues/Issues.md` first, checks the report's premises against the code, then creates and commits the `NNNN.md` file on `main`. Filing is not issue work — no branch, no review gate. Planning is a separate phase that runs on the day the issue is worked (see "Resolving an issue"), so the filer writes no `## Plan`. Don't switch models here without the user saying so.

1. Confirm `issues/project.json` exists. If missing, create it (see schema above) before filing the first issue — `name` should match this guide's heading; `url` is the project's canonical web URL (HTTPS, not SSH).
2. Find the highest existing `NNNN.md` and increment. Start at `0001` if the folder is empty. Skip past reserved high numbers (e.g. `8888`, `9999` for test issues).
3. Create `issues/NNNN.md` from the template.
4. Set status to `open`.
5. Use today's date for First seen.
6. Phrase the title as a single declarative sentence describing the bug or the feature gap, not a question or a fix description.
7. **Commit the new file** with message `#NNNN <issue title>` so the issue enters git history with its `open` status. Filing happens on `main` — it's not issue work, just recording the report.

## Updating an issue

Edit the file in place. The Mac app picks up changes automatically — no follow-up command. Touch only the rows or sections that changed; don't reformat the rest.

When status moves to `resolved` or `closed`, add a `**Closed**` row with the date. When the move to `resolved` was driven by a review-approved issue branch, also add a `**Branch**` row. For any move toward `resolved`, `closed`, or `wontfix`, the "Critical rule" near the top of this file applies — those transitions require explicit user confirmation, not inference.

Ad-hoc edits (a note, a screenshot, a manual field change) happen on `main`. Edits that belong to active issue work — the `in-progress` flip, work-log rows, resolution sections — happen on the issue's branch and reach `main` through the squash merge (see "Resolving an issue").

## Resolving an issue (plan → implement → review)

**All work for an issue happens on a branch named for the issue** (`issue/NNNN`), and **nothing reaches `main` until an independent review has re-verified the change** — at which point the branch lands as a single squash commit. Each issue goes through three phases, each in a **fresh subagent** dispatched by the orchestrator:

| Phase | Model · effort | Does | Status after |
|---|---|---|---|
| **1. Plan** | Opus · medium | Reads the issue and the code as it stands, writes `## Plan`: files, approach, tests by name, which verification tier, a user checklist. No code. | `open` |
| **2. Implement** | **Opus · low** (medium after a bounce or bail) | Follows the plan, builds, runs the fast tier, commits on the branch, drafts Root cause / Fix / Verification / Files changed / Gotchas. | `in-progress` |
| **3. Review** | Opus · medium | Reads the diff, **re-runs the verification itself**, then resolves or bounces. Only the reviewer sets `resolved`. | `resolved` or `open` |

- **Pass `model` and `effort` explicitly on every dispatch** (Agent tool `model: "opus"`, `effort: "low" | "medium"`), and record both in the work log. Use Fable only when the user asks. Sonnet is no longer used for issue work.
- **Plans are written the same day the issue is worked**, against the code as it stands, and name the tests to add. A low-effort implementer does well with a concrete plan and poorly when it has to explore. If a `## Plan` predates changes to the code it names, re-plan before implementing.
- **Fresh context per phase is deliberate:** each subagent reloads this guide and `AGENTS.md`, so edits to them take effect on the next dispatch, and the orchestrator's large context never carries phase work.
- **Orchestrator** (the main session) — picks issues, creates the branch, dispatches the three phases, records work-log rows, squash-merges after the reviewer resolves. It never does phase work itself, even for small follow-ups.

Issues are worked **one at a time, in ascending order**. Every branch is cut from `main`; never run two implementers in parallel and never stack one issue branch on another — later issues often depend on decisions that land with earlier ones. Only one VM runs at a time on this host (`AGENTS.md`).

### Orchestrator: branch → plan → implement → review → squash-merge

1. **Refresh the pricing cache if stale.** If `issues/model-pricing.json` is missing or its `fetched` date isn't today, fetch current model prices and rewrite it on `main` (once per day, not per issue). See "Token usage and cost tracking" below.
2. List `issues/*.md` (skip `Issues.md`). Pick the lowest-numbered file whose status is `open`. If the user names a specific issue ("fix 0046"), take that one.
3. **Create the issue branch** in its own worktree from a clean `main`: `git worktree add .claude/worktrees/issue-NNNN -b issue/NNNN main`, and copy `Configuration/Active.xcconfig` (gitignored) into it. If the branch already exists from a bailed attempt, resume it (read the bail Notes on the issue first). If it exists because the issue was already merged and has been reopened, don't reuse it — start fresh with a suffixed name (`issue/NNNN-2`).
4. **Plan (phase 1).** Unless the issue already has a same-day `## Plan`, dispatch a fresh Opus subagent at **medium** effort following "Phase 1 — Plan" below. Record its work-log row.
5. **Implement (phase 2).** Dispatch a fresh Opus subagent at **low** effort following "Phase 2 — Implement" below — **medium** if the issue was bounced or bailed before. Record its work-log row.
6. **Review (phase 3).** Dispatch a fresh Opus subagent at **medium** effort following "Phase 3 — Review" below. A fresh reviewer every round. Record its work-log row.
7. **If the reviewer bounced it** (status back to `open`, `## Review notes` committed on the branch), go back to step 5 with a fresh implementer at medium effort. If three rounds don't converge, bail per "When a phase can't finish" — the branch keeps every attempt.
8. **After the reviewer resolves it**, make sure the `## Work log` has a row for every phase and round with the final total, then **squash-merge to `main`, keeping the branch:**

    ```bash
    git switch main
    git merge --squash issue/NNNN
    git commit -m "#NNNN <verb> <title>"
    ```

    One commit, one simple one-line message — the issue file carries the detail. **Do not delete the branch** (`git log main..issue/NNNN` keeps the round-by-round history). Don't push branches unless the user asks.

    Then **remove the issue's worktree** (user directive, 2026-10-27): `git worktree remove .claude/worktrees/issue-NNNN`, plus any `vm-NNNN` worktree made for the issue. The branch stays. If the worktree has uncommitted changes, confirm they already landed on `main` before `git worktree remove --force`; if not, stop and ask. For a patch release, cherry-pick from the branch or the squash commit first if needed — both survive the removal.
9. UI tests are not run per issue; the daily UI run covers the merged change (see "Daily UI run").
10. Move on to the next open issue, or stop if only one was requested.

### Phase 1 — Plan (Opus, medium)

1. **Orient:** read `issues/Issues.md` (this file), `AGENTS.md` (binding), `Concepts.md`, the issue in full with its attachments, and the binding docs `AGENTS.md` names for the area the issue touches (`docs/view-hierarchy.md`, `docs/terminal-pane-requirements.md`, `docs/swiftui-observation-rules.md`).
2. **Read the code the change will touch**, and verify every premise the issue states — issue text is a report, not a fact.
3. **Write `## Plan`** into `issues/NNNN.md`, after `## Description`:
   - **Files** to change or add, and the approach in each.
   - **Tests** to add or change, by suite and test name, and which existing tests guard the area.
   - **Verification:** the tier (fast or UI confirmation, with the reason). For a UI confirmation issue, the exact failing `BattyUITests/<Class>/<test>` filters from the daily run. For a UI-visible change, which existing or new UI tests the daily run will exercise.
   - **User checklist:** what the user should check by hand before closing.
   - Open questions that need a user decision. If one blocks the work, say so and stop — the orchestrator asks the user.
4. Write no code. Leave status `open`. Commit the plan on the branch: `#NNNN Plan`.

### Phase 2 — Implement (Opus, low effort): claim → fix → build → verify → commit

You start with fresh context on the issue branch (`issue/NNNN`, in its worktree) — confirm with `git branch --show-current` before committing, and stay there: never switch branches, never touch `main`, never merge.

1. **Orient.** Read `issues/Issues.md` (this file — authoritative for the issue workflow), `AGENTS.md` (binding for code and repo conventions), and `issues/NNNN.md` in full, **including its `## Plan`**. Read `PRD.md` / `Concepts.md` only as the plan requires; use the `Concepts.md` vocabulary exactly.
2. **Set status to `in-progress`** and commit it on the branch (`#NNNN Claim`).
3. **Make the changes the plan describes.** If you deviate, say why in `## Fix`. Commit checkpoints freely, messages prefixed `#NNNN`.
4. **Build first:** `./build.sh`. Fix compile errors before any test run. If you changed `BattyUITests`, also run `./build.sh ui-typecheck`, which type-checks the UI tests on the host in seconds; a UI-test compile error must never reach the daily run. Both print only a short tail: act on the exit code and the final `CHECK …` line, and on FAILED fix from the printed summary or digest.
5. **Run the fast tier** (see "Verification tiers"). Mandatory; cannot be shortcutted. `./build.sh unit` captures the log and prints a short tail; that tail is the output contract:
   - Exit **0** and `CHECK UNIT: PASSED (N tests)`; exit **1** and `CHECK UNIT: FAILED (…)`; exit **2** and `CHECK UNIT: ERROR (…)` (could not run).
   - **Never `cat`, `grep` or `tail` the full log under `build/checks/`.** On failure read the printed Haiku summary or raw digest, or `<log>.failures.txt` when the printed digest was cut off.
   - **Compilation is not verification.** Zero tests run is exit 2 and `CHECK UNIT: ERROR (no tests ran)`, enforced by the script.
   - **Confirm tests you added or changed by name** with a filtered run, `./build.sh unit <Suite>` or `./build.sh unit <Suite>/<test>()`, which must print `PASSED (k tests)` with the expected `k`; then the full `./build.sh unit` for the count, which must have gone up.
   - **If verification can't run** (a VM precondition fails on a UI confirmation issue, hardware, the user's Mac), you have not verified the change — bail per "When a phase can't finish", naming the step.
   - **If the build was already failing before you started**, note it and bail — don't fix unrelated breakage.
6. **Commit the code** on the branch: `#NNNN <verb> <title>` — the verb that fits (`Fix`, `Add`, `Refactor`, `Update`, `Remove`, …). Discard expected `project.pbxproj` / `.xcscheme` residue (`git checkout --`); never commit it.
7. **Draft the resolution sections** in `issues/NNNN.md`, after `## Description`, and commit them on the branch (`#NNNN Draft resolution`). Leave Status `in-progress`; don't set `resolved`.
   - **`## Root cause`** — what was actually wrong (for feature work, the starting state). Say plainly if it's a hypothesis you didn't confirm.
   - **`## Fix`** — the approach, and any divergence from the plan.
   - **`## Verification`** — the exact commands, the run ids, and quoted summary lines (test counts, `==> RESULT:` lines). Name the new tests and confirm they ran.
   - **`## Files changed`** — one bullet per file.
   - **`## Gotchas`** *(optional)* — surprises, dead ends, what you couldn't verify. For UI work, say exactly what needs the user's visual sign-off.
8. **Return** a short summary: what changed, the verification run and result, anything the reviewer should scrutinize.

### Phase 3 — Review (Opus, medium): re-verify → resolve or bounce

The reviewer is the gate between "code on the branch" and "issue resolved". It owns the `resolved` transition.

1. **Orient** the same way (this file, `AGENTS.md`, `issues/NNNN.md` with its `## Plan` and drafted resolution sections), then read `git diff main...HEAD` in the issue's worktree — exactly the diff the squash will land.
2. **Judge the diff** against the issue's expected behavior (and its umbrella's acceptance criteria), the plan, the project's conventions and binding docs (`docs/view-hierarchy.md`, `docs/terminal-pane-requirements.md`, `docs/swiftui-observation-rules.md` where the diff touches those paths), and downstream impact. Grep every factual claim in new comments.
3. **Re-run the verification yourself** — the same tier (and, for a UI confirmation issue, the same failing-test filters) the plan names — and act on the exit code, the final `CHECK …` line and any printed digest, as in Phase 2 step 5. Never read the full log under `build/checks/`. Don't trust the drafted `## Verification`. This independent run is the core of the review.
4. **Decide, and commit on the branch:**
   - **Resolve** (correct, verified): set Status `resolved`; add `**Closed**` (today) and `**Branch**` (`issue/NNNN`) rows — no `**Commit**` row; the landing commit is found with `git log --oneline --grep='#NNNN'`. Add `## Resolution notes` (`> 🟢 Resolved YYYY-MM-DD — <one sentence>.`) and `## Review` (rounds, what review changed or "approved first pass"); correct the drafted sections where your run differs, and add your run to `## Verification`. If the issue is a child of an umbrella, update its row in the umbrella's Children table. Commit: `#NNNN Resolve: <title>`.
   - **Bounce** (verification failed, fix wrong, scope off): set Status back to `open`; add `## Review notes` stating exactly what failed and what the next implementation must change (file, problem, what would satisfy it). Commit: `#NNNN Review: <reason>`.
5. Never edit code. Return the verdict and a one-line summary.

**No dangling follow-ups.** If the resolution carves out scope that won't be addressed, the reviewer says so and the orchestrator has it filed as its own issue before the merge, linked both ways.

Status flow: `open` (with `## Plan`) → `in-progress` → `resolved`, or bounced back to `open`. **Never set `closed`** — the user does that after checking.

### Verification tiers

Builds and unit tests run on the host; **UI tests run only in the Tart VM** (`AGENTS.md`, `docs/ui-testing-vm.md`). A VM run costs minutes of fixed overhead before the first test and the whole suite takes over half an hour, so **UI tests are not part of per-issue verification.** They run once a day against `main` (below), failures become issues, and those issues are confirmed by re-running only the tests that failed.

| Stage | When | What runs |
|---|---|---|
| **Build** | Implementer, after editing, before any test run | `./build.sh` → `CHECK BUILD: PASSED`. Stops early on compile errors. Never counts as verification. |
| **UI type-check** | Implementer and reviewer, whenever `BattyUITests` changed | `./build.sh ui-typecheck` → `CHECK UI-TYPECHECK: PASSED` — type-checks `BattyUITests` on the host in seconds without building or running it. Never counts as verification. |
| **Fast tier** (every issue) | Every implementation and every review | `./build.sh unit` → `CHECK UNIT: PASSED (N tests)`. No VM run. |
| **UI confirmation** | Issues filed from a daily UI run failure | The fast tier, plus `tools/run-ui-tests-vm.sh` with only the failing `BattyUITests/<Class>/<test>` filters recorded in the issue. The issue isn't resolved until those tests pass in the VM. |
| **Release** | Before any release (`AGENTS.md`), from the branch being released | All tests: the unit tests including slow ones, the **whole** `BattyUITests` suite in the VM in sequential shards each under the guest's 40-minute bound (#0518), and the Release archive check (`./build.sh release archive …`). |

- **UI-visible changes** still add or update UI tests, type-checked with `./build.sh ui-typecheck`. Their first VM run is the next daily run; the plan names them and `## Gotchas` says they haven't run in the VM yet. Visual sign-off stays with the user.
- **Quote evidence from the tail:** `## Verification` quotes the ALL-CAPS `CHECK …` line, the `==> unit:` counts line and the log path; for each VM run, its run id, the `==> RESULT:` line and the `CHECK UI:` line.
- **Switches:** `--verbose` or `BATTY_CHECK_VERBOSE=1` streams the full log as well (for humans only); `BATTY_CHECK_SUMMARY=0` prints the raw digest instead of the Haiku summary; `BATTY_CHECK_SUMMARY_TIMEOUT` (seconds, default 90) bounds the Haiku call. Exit codes and the `CHECK` line never depend on Haiku.
- **Run the VM runner in the foreground or with the Bash tool's `run_in_background`** — not with `&`, `nohup` or a redirect to a file — so its time is measurable for the work log. One VM at a time.
- **Known flaky tests** may fail on unrelated changes. Add a test here only with the run ids that show it flaking, and file an issue to fix it.
  - `ProcessFollowByNameTests/theRealEnumeratorPrefersTheLongestRunningProcessOfAName()` (unit): failed at `:675` in `build/checks/unit-20261105-163643-95788.log` (`issue/0561`; passed alone and on a full re-run), and earlier in `Test-Batty (Beta)-2026.10.14_17-52-06--0700.xcresult` (#0516). Fix: [#0565](0565.md).
- Unit tests follow `AGENTS.md` "Asynchronous tests" — never pass by waiting.

### Daily UI run

Once a day, the orchestrator (or a scheduled session) runs the whole `BattyUITests` suite in the VM against the current `main`, in shards as in the Release tier. It is the only routine UI-test run.

1. Record each shard's run id, the `Executed N tests, with M failures` line, the `==> RESULT:` line and the `CHECK UI:` line.
2. **Re-run each failing test once** with its own `BattyUITests/<Class>/<test>` filter to separate real failures from flakes. A test that passes on the re-run goes under "Known flaky tests" with both run ids, and gets an issue to fix the flakiness.
3. **File an issue for each real failure** through a filer subagent, one per root cause. Several tests failing on the same cause share one issue. Before filing, check for an open issue that already covers the test. The issue records the run id, the failure message, the exact `BattyUITests/<Class>/<test>` filters, and the commits that landed on `main` since the last green daily run, which are the likely cause.
4. Those issues go through plan → implement → review like any other, with the **UI confirmation** tier: the implementer and the reviewer each re-run only the failing tests.
5. If the run can't start (a VM precondition fails), report it to the user rather than working around it.

### When a phase can't finish

If the issue is unreproducible, out of scope, blocked on a user decision, the build won't pass after reasonable effort, or three review rounds don't converge, the work is parked on the branch — never discarded:

1. **Commit everything in flight on the branch**, including half-done work (`#NNNN WIP: <state>`).
2. Leave the branch and its worktree in place — branches are never deleted; a parked branch is the next attempt's starting point.
3. **On `main`, add a `## Notes` section** to the issue: what was tried, why work stopped, what to try next, and `Work parked on issue/NNNN`. For a review deadlock, include the unresolved `## Review notes` verbatim. Append the work-log rows for the failed sessions here too — the branch's copy won't reach `main`. Status on `main` stays `open`.
4. The orchestrator commits that on `main`: `#NNNN Notes: <one-line bail summary>`.
5. Return a one-line summary of why work stalled.

Never use `wontfix` or `closed` to escape a stuck issue.

## Token usage and cost tracking

Every subagent dispatch gets a usage record on the issue it worked. The **orchestrator** records it after the subagent returns — a subagent can't measure its own totals. Each issue accumulates a row per phase and round — plan, implement, review — plus a row for every bounce or bail, and for the filer when the filing was part of the same work. Rows are committed on the issue branch as each phase returns, so they land on `main` in the squash commit; rows for a bailed attempt go into the `## Notes` on `main`.

### Pricing cache (`issues/model-pricing.json`)

Anthropic publishes prices on the docs site (no API endpoint). Fetch once per day and rewrite `issues/model-pricing.json`:

```json
{
  "fetched": "YYYY-MM-DD",
  "source": "https://platform.claude.com/docs/en/about-claude/pricing",
  "currency": "USD per MTok",
  "models": {
    "claude-opus-5-5": { "input": 0.00, "output": 0.00, "cache_write_5m": 0.00, "cache_read": 0.00 }
  }
}
```

Include every model that bills against issue work (today Opus for all phases; Fable or Sonnet only if the user asks for them). The rates above are placeholders — never trust example numbers over a fresh fetch. If the fetch fails, use the stale cache and note the staleness next to the cost; with no cache at all, record tokens with `—` for cost.

### Measuring a phase: `tools/worklog.py`

Claude Code writes each subagent's transcript to `~/.claude/projects/<project-slug>/<session-id>/subagents/agent-<id>.jsonl` (`<project-slug>` is the working directory with `/`, `.` and `_` replaced by `-`). Run:

```bash
tools/worklog.py <agent.jsonl> --phase implement --outcome reviewed
```

It prints a ready work-log row. What it measures:

- **Cache read / cache write** — exact, from `message.usage`, deduped by `requestId` (one response can span several JSONL lines).
- **Output** — *estimated* as assistant characters ÷ 4 and marked `~`: the transcript's `usage` is the stream-start snapshot, so `output_tokens` is near zero on every line.
- **Effort** — the `effort` field on assistant lines. **Turns** — API requests.
- **Wall** — first to last timestamp. **UI** — count and total minutes of `tools/run-ui-tests-vm.sh` / `./build.sh ui` runs (foreground, or `run_in_background` timed to the task notification). **Build** and **Unit** — the same for `./build.sh` / `./build.sh ui-typecheck` and `./build.sh unit`; a foreground run counts when its result has a `CHECK …` line. Heredoc bodies (commit messages, files written with `cat <<EOF`) are ignored when classifying runs, and a bare `./build.sh` followed by a pipe or redirection counts as Build; `python3 tools/worklog-selftest.py` checks the classifier. Model time is Wall − Build − Unit − UI.
- **Haiku** — count and cost of the failure summaries: records in the main checkout's `build/checks/haiku-usage.jsonl` whose log path the transcript printed.
- **Cost** — model cost from `issues/model-pricing.json`, plus the Haiku cost.

`tools/worklog.py --scan` measures every transcript in the project, which is how baselines are built. If no transcript is available, record what the harness reported, or `—`. Never fabricate counts.

### The `## Work log` section

One row per phase and round, conventionally the last section of the issue file (always after `## Description`):

```markdown
## Work log

| Date | Phase | Model | Effort | Wall | Build | Unit | UI | Turns | Output | Cache read | Cache write | Haiku | Cost | Outcome |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-10-20 | plan | claude-opus-5-5 | medium | 9m | — | — | — | 20 | ~29,400 | 2,088,496 | 157,531 | — | $1.80 | planned |
| 2026-10-20 | implement | claude-opus-5-5 | low | 18m | 2 (0.4m) | 3 (2.1m) | — | 41 | ~46,000 | 4,100,000 | 190,000 | 1 ($0.003) | $2.10 | reviewed |
| 2026-10-20 | review | claude-opus-5-5 | medium | 7m | 1 (0.2m) | 1 (0.7m) | — | 27 | ~4,800 | 2,431,182 | 117,810 | — | $0.95 | resolved |

**Total: $4.85**
```

Phase is `file`, `plan`, `implement` or `review`. Outcome is one of `filed`, `planned`, `reviewed` (handed to review), `resolved`, `bounced`, `bailed`, `stopped`. Update the `**Total**` line whenever a row is appended. Older tables keep their columns; when an older issue gets a new row, extend its header to these columns and pad earlier rows with `—` — the one exception to "don't reformat existing rows".

## Attachments

Screenshots, crash logs, console output, sample data, etc. live in a sibling folder `issues/NNNN/`. Reference them with paths *relative to the issue's `.md` file* — that means the folder prefix `NNNN/` is part of the link target. The bytes that ship are `1335/screenshot.png`, not `screenshot.png` and not `issues/1335/screenshot.png`.

```
issues/1335.md           ← the markdown that contains the link
issues/1335/screenshot.png   ← the file being linked

# inside 1335.md the link reads:
![caption](1335/screenshot.png)
```

Concrete example with both image and video attachments:

```markdown
## Attachments

![Reply button does nothing when tapped](1335/screenshot.png)
![Crash log](1335/crash.log)
[![Sidebar resize jitter](1335/sidebar-resize-jitter.poster.png)](1335/sidebar-resize-jitter.mov)
```

### Videos (`.mov`, `.mp4`, etc.)

Videos can't be embedded as `![…](…)` — markdown renderers treat that as an `<img>` and a `.mov` won't load. Instead, generate a poster frame with `qlmanage` and emit an image-inside-a-link (shown above). Quick recipe:

```bash
qlmanage -t -s 1280 -o issues/NNNN issues/NNNN/<basename>.<ext>
mv issues/NNNN/<basename>.<ext>.png issues/NNNN/<basename>.poster.png
```

`qlmanage` ships with macOS — no install. It reliably produces posters for AVFoundation-supported formats (`.mov`, `.mp4`, `.m4v`, `.qt`). For `.mkv`/`.webm`, fall back to a plain `![alt](NNNN/file.mov)` form with a `<!-- poster generation failed -->` HTML comment.

### macOS screenshot / screen recording filename gotcha

macOS Screenshot and Screen Recording filenames use a **narrow no-break space** (U+202F) before AM/PM, visually identical to a regular space. A literal `cp` of the quoted filename will fail. Glob past it:

```bash
mkdir -p issues/NNNN
cp ~/Desktop/Screenshot\ YYYY-MM-DD\ at\ H.MM.SS*PM.png issues/NNNN/screenshot.png
cp ~/Desktop/Screen\ Recording\ YYYY-MM-DD\ at\ H.MM.SS*PM.mov issues/NNNN/recording.mov
```

The `*` matches the U+202F.

## Module conventions for this project

Use these canonical module names so issues stay consistent and groupable in the Mac app. They mirror the structure described in `Concepts.md` and the milestones in `PRD.md`. Multiple modules can be listed separated by ` / `.

| Module | Covers |
|---|---|
| `App` | Top-level shell (`BattyApp`), menus, app lifecycle, Settings window |
| `Window` | NSWindow management, multi-window behavior, frame restoration |
| `Sidebar` | Session sidebar list, reorder, "+" button, collapse/expand |
| `Session` | Session model, session detail view, Cmd-1..9 selection |
| `Split` | Split tree, dividers, drag-resize, keyboard resize, focus movement |
| `Pane` | Pane view, per-pane toolbar, pane lifecycle (collapse on last-tab-close) |
| `Tabs` | SlidingTabs integration, tab lifecycle, Cmd-T/Cmd-W/Cmd-Option-1..9 |
| `TerminalSurface` | `TerminalSurfaceView` NSViewRepresentable, NSView wrapper, Metal layer, key/mouse events |
| `GhosttyKit` | libghostty integration, xcframework wiring, surface registry, terminfo bundle |
| `IME` | `NSTextInputClient`, CJK, dead keys, emoji input |
| `DragDrop` | File-URL drops onto panes, shell-quoting, drag-over highlight |
| `BellFeed` | Bell event capture (BEL + OSC 9), feed popover, click-to-jump, system notifications |
| `Theme` | Ghostty `.ghostty` theme loading, View → Theme menu, live theme application |
| `Persistence` | Workspace serialization, `workspace.json`, restore on launch |
| `Projects` | Projects (1.3.0): `Project` model, `projects.json` store, opening a Project as a Session, startup commands and their trust prompt, Project Editor, Open Project picker, Save Session as Project, `batty project` CLI |
| `Settings` | Settings window, `UserDefaults`, font/cursor/notification preferences |
| `Build` | Xcode project, signing, notarization, Sparkle, terminfo / shell-integration resource bundling |
| `Localization` | User-facing string extraction, `.xcstrings` / `Localizable.strings` catalogs, per-locale resources, locale switching |
| `Testing` | Unit and UI test suites, test infrastructure, the Tart VM UI-test runner (`Tests` is an accepted older spelling) |
| `Docs` | `PRD.md`, `Concepts.md`, README, this file |
| `Website` | `website/` — marketing pages, demo page, changelog, CSS, assets |

If a new area emerges, add it here before using it in an issue. Don't invent module names ad-hoc.
