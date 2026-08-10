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

The deliberate exception: an issue may be set to `resolved` (work-is-done-but-not-confirmed) when the work has passed this project's review gate — see "Resolving an issue" below. That transition is made by the orchestrator after the reviewer approves, never by the implementer subagent itself. Nothing and nobody but the user sets `closed`. This separation is the entire reason `resolved` and `closed` are different states.

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
| Approved issue lands (squash merge of `issue/NNNN`) | everything the branch touched — code, `NNNN.md` resolution sections, work-log rows | `#NNNN <verb> <title>` (single line, kept simple — the issue file carries the detail) |
| Bail with notes | markdown only | `#NNNN Notes: <brief>` |
| Daily pricing refresh | `model-pricing.json` only | `Update model pricing` |
| User-confirmed close | markdown only | `#NNNN Close` |
| Won't fix | markdown only | `#NNNN Won't fix` |

Commits on an **issue branch** (`issue/NNNN`): commit freely — implementation checkpoints, the `in-progress` status flip, review-round fixes, work-log rows, the resolution markdown. Prefix messages with `#NNNN`. Granularity doesn't matter: there may be five or more commits on the branch, and the squash merge collapses them all into one commit on `main`.

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

New issues are filed by a **filer subagent pinned to Opus 5** (`claude-opus-5`) — user directive, 2026-08-09. Do not use Fable. The orchestrator (main session) dispatches a fresh Opus 5 subagent with the report details and instructions to follow the steps below; the subagent reads `issues/Issues.md` first to absorb these conventions, then creates and commits the `NNNN.md` file on `main`. Filing is not issue work — no branch, no review gate — just recording the report. This is a standing user instruction, not a "use whatever is newest" rule — do not switch models here without the user saying so.

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

## Resolving an issue (the review-gated branch workflow)

The standard workflow: **all work for an issue happens on a branch named for the issue** (`issue/NNNN`), and **nothing reaches `main` until an independent review approves the diff** — at which point the branch lands as a single squash commit. The branch may accumulate five or more commits while the work is in flight; `main` only ever sees one. Each issue runs through a three-role loop:

- **Implementer subagent** — model pinned to **Sonnet** (`claude-sonnet-5`). Implements and verifies the change on the issue branch, committing checkpoints freely as it goes. Never touches `main`.
- **Reviewer subagent** — model pinned to **Opus** (`claude-opus-4-8`). Reviews the branch diff against the issue. Returns approve or request-changes. Does **not** edit code, commit, or change status.
- **Orchestrator** (the main session) — picks issues, creates the branch, dispatches both subagents, routes review feedback back to the implementer, records work-log rows on the branch, and — only after approval — marks the issue `resolved` and squash-merges the branch to `main`.

Issues are worked **one at a time, in ascending order**. Every branch is cut from `main`, so never run two implementers in parallel and never stack one issue branch on another — later issues often depend on decisions that land with earlier ones.

### Orchestrator: branch → dispatch → review-gate → squash-merge

1. **Refresh the pricing cache if stale.** If `issues/model-pricing.json` is missing or its `fetched` date isn't today, fetch current model prices and rewrite it on `main` (once per day, not per issue). See "Token usage and cost tracking" below.
2. List `issues/*.md` (skip `Issues.md`). Pick the lowest-numbered file whose status is `open`.
3. **Create the issue branch** from a clean `main`: `git switch -c issue/NNNN main`. If the branch already exists from a previous bailed attempt, resume it instead: `git switch issue/NNNN` (read the bail Notes on the issue first). If it exists because the issue was already merged and has been reopened, don't reuse it — the old branch predates the squash; start fresh with a suffixed name (`issue/NNNN-2`).
4. **Dispatch the implementer** — a fresh subagent with the model pinned to Sonnet, given the issue id and instructions to follow "Implementer subagent" below: read `issues/Issues.md` and `CLAUDE.md` first to absorb project conventions, then read `issues/NNNN.md` for the issue itself. It works on the issue branch and returns a summary of what changed, how it was verified, and what it committed.
5. **Record the implementer's usage** — append a `## Work log` row (see "Token usage and cost tracking") and commit it on the branch.
6. **Dispatch the reviewer** — a fresh subagent with the model pinned to Opus, given the issue id and the implementer's summary, following "Reviewer subagent" below. A fresh reviewer per round; don't reuse a reviewer across issues.
7. **Commit the review result on the branch.** The reviewer itself never commits, so the orchestrator records each round's outcome: commit message `#NNNN Review: <approve | request changes>` with the verdict's findings in the body, plus the reviewer's work-log row in the issue file. Every round leaves its own commit — the branch history shows what review asked for and what changed in response.
8. **If the reviewer requested changes**, send the findings back to the **same implementer agent** (continue it — its context is intact) to address, re-verify, and commit on the branch, then dispatch a fresh review round. If three rounds don't converge, bail per "When the implementer can't finish" — the branch keeps every attempt; nothing is discarded.
9. **On approval, wrap up the issue file on the branch**: mark it `resolved` (see "Updating the issue on resolve" below) and make sure the `## Work log` carries a row for every implementer and reviewer round with the final cost total. Commit that markdown update — it's the branch's final commit.
10. **Squash-merge to `main`, keeping the branch:**

    ```bash
    git switch main
    git merge --squash issue/NNNN
    git commit -m "#NNNN <verb> <title>"
    ```

    One commit, one simple one-line message — the issue file carries the detail (root cause, fix, review, verification, files changed, costs). **Do not delete the branch.** The retained branch preserves the commit-by-commit history — implementation checkpoints, review rounds, fixes — for later review (`git log main..issue/NNNN`). Note that git won't show a squash-merged branch as merged; that's expected. These branches are local working history: don't push them unless the user asks.
11. Move on to the next open issue (or stop if only one was requested, or the user wants to review before continuing).

If the user names a specific issue ("fix 0046"), dispatch to that id directly.

### Implementer subagent (Sonnet): claim → fix → verify → checkpoint

The implementer starts with fresh context, so its first job is loading the project's conventions before touching anything. You are already on the issue branch (`issue/NNNN`) — confirm with `git branch --show-current` before committing anything, and stay there: never switch branches, never touch `main`, never merge.

1. **Orient in the project.** Read these in order, every time:
   - **`issues/Issues.md`** (this file) — status vocabulary, module conventions, build/verify command, commit conventions, project-specific rules. **Authoritative for issue-tracking workflow.**
   - **`CLAUDE.md`** at the repo root, if it exists — project-wide guidance, code conventions, restricted areas, build/test commands. **Treat its instructions as binding.**
   - **`PRD.md`** — the product requirements doc; the source of truth for what Batty is and isn't.
   - **`Concepts.md`** — canonical vocabulary (Window, Session, Pane, Tab, Terminal Session, Split, Theme, Bell Feed, Workspace, Surface registry, etc.). Use these terms exactly when describing fixes; don't invent synonyms.
   - **`issues/NNNN.md`** — the issue you're working on, in full, including attachments in `issues/NNNN/`.

   If two project guides disagree, prefer `CLAUDE.md` for code/repo conventions and this file for issue-tracking specifics.

2. **Set status to `in-progress`** in the markdown and commit it on the branch (`#NNNN Claim`). The Mac app picks it up immediately, signaling the issue is claimed.
3. **Make the code changes** required by the issue, committing checkpoints on the branch as you go — messages prefixed `#NNNN`, granularity at your discretion (it all squashes into one commit on `main`).
4. **Build *and* run the project's verification command, and confirm tests actually executed and passed.** This step is mandatory and cannot be shortcutted.

   - **Compilation is not verification.** "It builds" / "it compiles" / "no type errors" does not count. Tests must actually run — unit tests execute, UI tests run, the app launches, whatever the project defines as proof. A green build with zero tests run is a failure of this step.
   - **If you wrote or modified tests as part of the fix, you MUST execute those specific tests and observe them pass.** Confirm the test names you added appear in the run output, the counts increased, and the result was success. A test that compiles but never ran proves nothing.
   - **Read the output, don't just check the exit code.** "0 tests run", "skipped", "no tests found", or a "build succeeded" line with no test summary are red flags even when the exit code is 0.
   - **If verification cannot be run in your environment** (hardware required, sandbox, missing credentials, machine locked by the UI suite), you have not verified the change. Do not hand it to review as verified — bail per "When the implementer can't finish" below, naming the verification step you couldn't run.
   - **If the build was already failing before you started**, note it on the issue and bail — don't fix unrelated breakage.

5. **Commit your final state on the branch, but do not touch the issue markdown beyond the `in-progress` flip** — the resolution sections are the orchestrator's job, after review. Commit messages start with `#NNNN` and a short, declarative title — pick the verb that actually fits (`Fix`, `Add`, `Refactor`, `Update`, `Remove`, etc.); not every issue is a bug fix. If `CLAUDE.md` or recent `git log` defines a different convention, follow that instead.

6. **Return to the orchestrator** with: what changed and why, the files touched, the exact verification command(s) run and what was observed, and anything the reviewer should scrutinize (trade-offs, workarounds, choices that constrain later issues).

When the orchestrator sends back review findings, address every item (or push back with a concrete reason), re-run verification, commit on the branch, and return an updated summary the same way.

### Reviewer subagent (Opus): review the branch before it lands

The reviewer also starts fresh: read `issues/Issues.md`, `CLAUDE.md`, `PRD.md`/`Concepts.md` as needed, and `issues/NNNN.md` with its attachments, then examine the branch with `git diff main...HEAD` — that is exactly the diff the squash merge will land on `main`. (`git log main..HEAD --oneline` shows the checkpoint history if the path the implementer took matters.)

Judge the diff against:

- **The issue itself** — does the change deliver the Expected behavior (and the parent umbrella's acceptance criteria, if there is one)?
- **Correctness and idiom** — sensible design, project conventions respected, code that reads like the surrounding code. For Batty this includes the binding architecture docs: `docs/view-hierarchy.md`, `docs/terminal-pane-requirements.md`, and `docs/swiftui-observation-rules.md` when the diff touches the terminal/pane/tab/window path, gestures/overlays, or focus/selection/observed-state writes.
- **Verification credibility** — did the implementer's verification actually demonstrate the behavior, or just compile? Re-run the build/verify command if in doubt.
- **Downstream impact** — does the change box in a later issue (see the issue's Relation section)?

Return a verdict: **Approve**, or **Request changes** with a specific, actionable list — file, problem, what would satisfy the objection. Review only; never edit code, never commit, never change issue status.

### Updating the issue on resolve (orchestrator, after approval, on the branch)

This is the branch's final commit before the squash merge. Edit the metadata table:

- Change Status to `resolved`.
- Add a `**Closed**` row with today's date.
- Add a `**Branch**` row with the branch name (`issue/NNNN`). No `**Commit**` row — the squash commit's hash doesn't exist yet when this file is written; the landing commit is found by its message: `git log --oneline --grep='#NNNN'`.

Then add a structured summary in this order so the issue becomes a primary-source record of why the change happened. **All resolution sections go AFTER `## Description`** — never between the metadata table and Description, where the Mac app's frontmatter parser will eat them.

- **`## Resolution notes`** *(optional but recommended)* — a one-line blockquote summary `> 🟢 Resolved YYYY-MM-DD — <one sentence>.` plus 1–2 follow-up sentences if useful. This is what the user reads first on the Mac app's detail view; keep it terse.
- **`## Root cause`** — what was actually wrong (often different from the original report). For feature/prototype issues, describe the starting state instead.
- **`## Fix`** — the approach taken.
- **`## Review`** — who reviewed (model), how many rounds, and a one-line note of what the review changed (or "approved first pass").
- **`## Verification`** — the exact command(s) run and what was observed (e.g. "`scripts/build.sh unit` — 277 tests in 36 suites passed including the 3 new tests in `SessionNameToolTests`"). If new tests were added, name them and confirm they ran. Mandatory — this is the audit trail that distinguishes "verified" from "compiled and hoped". For UI work the implementer can't run locally, say so here and in Gotchas, and mark `resolved` (the user's visual sign-off is what moves it to `closed`).
- **`## Files changed`** — a bulleted list, one bullet per file touched, with a short note describing what changed in each.
- **`## Gotchas`** *(optional)* — surprises, dead ends, non-obvious behavior, or anything a future engineer working on similar code should know. Skip if nothing is notable. libghostty quirks, SwiftUI ↔ NSView lifecycle gotchas, Metal layer sizing surprises, and IME edge cases are exactly the kind of thing that belongs here.

**No dangling follow-ups.** If the resolution carved out scope that won't be addressed, file that follow-up as its own ticket before marking this one resolved, and link it bidirectionally (parent's Resolution notes → child; child's Relation → parent). A "follow-up" sentence with no ticket behind it disappears the moment the issue gets closed.

If the issue is a child of an umbrella, update its row in the umbrella's Children table to `resolved` in the same commit, so the umbrella's state lands with the merge.

Status flow: `open` → `in-progress` → `resolved`. **Never set `closed`** — the user does that after verifying the fix in the Mac app.

### Build / verify command for this project

The canonical "did I break the build?" check is:

```bash
scripts/build.sh
```

To run the fast `BattyKit` unit tests (the pre-commit gate — <30s, no UI, no machine lock):

```bash
scripts/build.sh unit
```

The UI suite is slow (~10 min), locks the machine, and runs only for release preflight or when adding/fixing a UI-level feature — on the Mac mini, not the MacBook:

```bash
scripts/run-ui-tests.sh                              # all UI tests
scripts/run-ui-tests.sh BattyUITests/TabRenameTests  # one class
```

`scripts/build.sh` wraps `xcodebuild` with the correct scheme (`Batty (Prod)`, not `Batty`) and destination. Run UI tests via `scripts/run-ui-tests.sh`, not raw `xcodebuild test` — it re-signs the runner so Gatekeeper doesn't translocate it. Always confirm the headless `scripts/build.sh` invocation passes before committing; Xcode previews are not a build pass. See `CLAUDE.md` for the full test strategy.

### When the implementer can't finish

If the issue is unreproducible, out of scope, the build won't pass after reasonable effort, or three review rounds don't converge, the work is parked on the branch — never discarded:

1. **Commit everything in flight on the branch**, including half-done work (`#NNNN WIP: <state>`). The branch is the parking spot; the next attempt resumes from it.
2. **Switch back to `main`** and leave the branch in place — branches are never deleted in this workflow; a parked branch is the next attempt's starting point.
3. **On `main`, add a `## Notes` section** to the issue describing what was tried, why work stopped, what you'd try next, and naming the branch (`Work parked on issue/NNNN`). For a review-deadlock bail, include the unresolved review findings verbatim. Append the work-log rows for the failed sessions here too — they're real costs, and the branch's copy of the file won't reach `main`. Status on `main` is still `open` (the `in-progress` flip only ever existed on the branch).
4. Commit the markdown change on `main` with message `#NNNN Notes: <one-line bail summary>` (the orchestrator does this).
5. Return with a one-line summary of why work stalled.

Never use `wontfix` or `closed` to escape a stuck issue.

## Token usage and cost tracking

Every subagent dispatch gets a usage record on the issue it worked: which model did the work, exactly how many tokens it consumed, and an estimated cost. The **orchestrator** records this after the subagent returns — a subagent can't measure its own totals. In the review-gated workflow that means one row per session: each implementer round **and** each reviewer round gets its own row, so an issue's true cost includes its reviews. Rows are appended and committed on the issue branch as each round finishes, so they land on `main` inside the squash commit; rows for a bailed attempt go into the `## Notes` added on `main` instead, since the branch's copy of the file never merges.

### Pricing cache (`issues/model-pricing.json`)

Anthropic publishes prices on the docs site (no API endpoint). Fetch once per day, cache to:

```json
{
  "fetched": "YYYY-MM-DD",
  "source": "https://platform.claude.com/docs/en/about-claude/pricing",
  "currency": "USD per MTok",
  "models": {
    "claude-fable-5": { "input": 5.00, "output": 25.00, "cache_write_5m": 6.25, "cache_read": 0.50 },
    "claude-sonnet-5": { "input": 3.00, "output": 15.00, "cache_write_5m": 3.75, "cache_read": 0.30 },
    "claude-opus-4-8": { "input": 5.00, "output": 25.00, "cache_write_5m": 6.25, "cache_read": 0.50 }
  }
}
```

Include at least the filer model (Opus 5), the implementer model (Sonnet), and the reviewer model (Opus), since all three bill against issue work. The ids above reflect the current tiers (`claude-opus-5`, `claude-sonnet-5`); the rates are illustrative placeholders until a fresh fetch confirms them. If `fetched` is today, use as-is. If the fetch fails, use the stale cache and note the staleness next to the cost; with no cache at all, record tokens and model with `—` for cost. Never trust example numbers over a fresh fetch.

### Getting exact token counts

Claude Code writes each subagent's transcript to `~/.claude/projects/<project-slug>/<session-id>/subagents/agent-<id>.jsonl`, where `<project-slug>` is the working directory with `/`, `.`, and `_` replaced by `-`. Assistant lines carry `message.usage` (exact `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`) and `message.model`.

**Dedupe by `requestId`** — one API response can span several JSONL lines repeating the same usage object; summing every line over-counts. Find the newest agent file mentioning the issue id, keep one usage entry per `requestId`, and sum.

```
cost = (input × input_rate + output × output_rate
      + cache_read × cache_read_rate + cache_write × cache_write_5m_rate) / 1,000,000
```

If no transcript is available (different harness), record whatever total the harness reported, or `—`. Never fabricate counts.

### The `## Work log` section

One row per work session, conventionally the last section of the issue file (always after `## Description`). Note the Model column — implementer rows show the Sonnet id, reviewer rows the Opus id:

```markdown
## Work log

| Date | Model | Input | Output | Cache read | Cache write | Cost |
|---|---|---|---|---|---|---|
| 2026-06-15 | claude-sonnet-5 | 5,300 | 18,000 | 1,200,000 | 70,000 | $1.02 |
| 2026-06-15 | claude-opus-4-8 | 4,800 | 6,000 | 480,000 | 30,000 | $0.58 |

**Total: $1.60**
```

Update the `**Total**` line whenever a row is appended. Bails get a row too. Don't reformat existing rows.

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
| `Settings` | Settings window, `UserDefaults`, font/cursor/notification preferences |
| `Build` | Xcode project, signing, notarization, Sparkle, terminfo / shell-integration resource bundling |
| `Localization` | User-facing string extraction, `.xcstrings` / `Localizable.strings` catalogs, per-locale resources, locale switching |
| `Docs` | `PRD.md`, `Concepts.md`, README, this file |
| `Website` | `website/` — marketing pages, demo page, changelog, CSS, assets |

If a new area emerges, add it here before using it in an issue. Don't invent module names ad-hoc.
