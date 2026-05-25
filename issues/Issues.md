# Batty

A native macOS terminal multiplexer built on libghostty. Single-window-by-default, session sidebar, splits and tabs, bell-driven notification feed. macOS 15+. See `PRD.md` for the product spec and `Concepts.md` for the canonical vocabulary used throughout this tracker.

This file is the local guide for managing issues in this project. The companion Mac app (Issues.app) watches the `issues/` folder and renders the current state. Markdown files (and `project.json`) are the source of truth — there is no generated artifact or index to keep in sync.

The `# Batty` heading above matches the `name` field in `issues/project.json`. `project.json` is the canonical source for the project's identity (name + repo URL); this guide is the workflow companion.

## Folder layout

```
issues/
├── project.json       # canonical project name + repo URL
├── Issues.md          # this file
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

The deliberate exception: a subagent that finishes a fix may set `resolved` (work-is-done-but-not-confirmed). It must not set `closed` — that's the user's call. This separation is the entire reason `resolved` and `closed` are different states.

## Git tracking

This project's `issues/` folder is **tracked by git** — bug-tracking history lives alongside code history.

Check on every operation:

```bash
git rev-parse --is-inside-work-tree 2>/dev/null   # is this a git repo?
git check-ignore -q issues/                        # exit 0 = ignored, 1 = tracked
```

When tracked, each lifecycle event produces its own commit:

| Event | What's committed | Commit message |
|---|---|---|
| Initial setup | `project.json` + `Issues.md` together | `Add issue tracker setup` (or bundle with the first `#NNNN` commit) |
| File a new issue | the new `NNNN.md` (and `project.json` / `Issues.md` if newly created) | `#NNNN <issue title>` |
| Edit project config | `project.json` only | `Update project config` (or e.g. `Update project URL`) |
| Resolve — code commit | code changes only | `#NNNN <verb> <title>` |
| Resolve — resolution commit | markdown update (status + Closed + Commit + summary) | `#NNNN Resolve: <title>` |
| Bail with notes | markdown only | `#NNNN Notes: <brief>` |
| User-confirmed close | markdown only | `#NNNN Close` |
| Won't fix | markdown only | `#NNNN Won't fix` |

**Working-copy-only changes (no commit):**

- Setting status to `in-progress` at the start of work — transient; the resolve commits supersede it. Committing every status flip would create noise.

**Why two commits to resolve, not one:** the **Commit** metadata row records the hash of the code-fix commit, and that hash isn't known until *after* the code commit lands. Splitting resolution into a code commit and a resolution commit keeps each commit single-purpose ("fix the code", "document the fix") and lets the resolution commit reference the hash cleanly.

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
- When status moves to `resolved` or `closed`, add a `**Closed**` row with today's date. When the move to `resolved` is the result of a fix commit, also add a `**Commit**` row with the short hash (`git rev-parse --short HEAD`).
- Steps / Expected / Actual / Attachments / Notes are conventional but not all required — for design-refinement or feature-gap issues, Description alone is fine.

## Filing a new issue

1. Confirm `issues/project.json` exists. If missing, create it (see schema above) before filing the first issue — `name` should match this guide's heading; `url` is the project's canonical web URL (HTTPS, not SSH).
2. Find the highest existing `NNNN.md` and increment. Start at `0001` if the folder is empty. Skip past reserved high numbers (e.g. `8888`, `9999` for test issues).
3. Create `issues/NNNN.md` from the template.
4. Set status to `open`.
5. Use today's date for First seen.
6. Phrase the title as a single declarative sentence describing the bug or the feature gap, not a question or a fix description.
7. **Commit the new file** with message `#NNNN <issue title>` so the issue enters git history with its `open` status.

## Updating an issue

Edit the file in place. The Mac app picks up changes automatically — no follow-up command. Touch only the rows or sections that changed; don't reformat the rest.

When status moves to `resolved` or `closed`, add a `**Closed**` row with the date. When the move to `resolved` was driven by a fix commit, also add a `**Commit**` row with the short hash. For any move toward `resolved`, `closed`, or `wontfix`, the "Critical rule" near the top of this file applies — those transitions require explicit user confirmation, not inference.

## Resolving an issue (the standard workflow)

Each open issue is handled by a fresh subagent. The orchestrator picks the issue; the subagent does the work in isolation and returns when done.

### Orchestrator: pick and dispatch

1. List `issues/*.md` (skip `Issues.md`). Pick the lowest-numbered file whose status is `open`.
2. Spawn a fresh subagent with the issue id and instructions to follow the resolve workflow below.
3. When the subagent returns, move on to the next open issue (or stop if only one was requested).

If the user names a specific issue ("fix 0046"), dispatch to that id directly.

### Subagent: claim → fix → build → commit → resolve

A subagent starts with fresh context, so its first job is loading the project's conventions before touching anything.

1. **Orient in the project.** Read these in order, every time:
   - **`issues/Issues.md`** (this file) — status vocabulary, module conventions, build/verify command, commit conventions, project-specific rules. **Authoritative for issue-tracking workflow.**
   - **`CLAUDE.md`** at the repo root, if it exists — project-wide guidance, code conventions, restricted areas, build/test commands. **Treat its instructions as binding.**
   - **`PRD.md`** — the product requirements doc; the source of truth for what Batty is and isn't.
   - **`Concepts.md`** — canonical vocabulary (Window, Session, Pane, Tab, Terminal Session, Split, Theme, Bell Feed, Workspace, Surface registry, etc.). Use these terms exactly when describing fixes; don't invent synonyms.
   - **`issues/NNNN.md`** — the issue you're working on, in full, including attachments in `issues/NNNN/`.

   If two project guides disagree, prefer `CLAUDE.md` for code/repo conventions and this file for issue-tracking specifics.

2. **Set status to `in-progress`** in the markdown — working copy only, no commit. The Mac app picks it up immediately.
3. **Make the code changes** required to fix the bug.
4. **Run the project build / verification command** (see below) and confirm it passes. Fix failures caused by your changes. If the build was already failing before you started, note it on the issue and bail — don't fix unrelated breakage.

5. **Make the code commit.** Stage *only the code changes* (not the issue markdown yet). The message starts with `#NNNN` and a short, declarative title — pick the verb that actually fits (`Fix`, `Add`, `Refactor`, `Update`, `Remove`, etc.); not every issue is a bug fix. Leave a blank line after the title, then add a paragraph of details.

6. **Capture the commit hash** with `git rev-parse --short HEAD`.

7. **Update the issue markdown** to mark it resolved:
   - Change Status to `resolved`.
   - Add a `**Closed**` row with today's date.
   - Add a `**Commit**` row with the short hash from step 6.

   Then add a structured summary in this order so the issue becomes a primary-source record:

   - **`## Root cause`** — what was actually wrong (often different from the original report).
   - **`## Fix`** — the approach taken.
   - **`## Files changed`** — bulleted list, one bullet per file, with a short note describing what changed in each.
   - **`## Gotchas`** *(optional)* — surprises, dead ends, non-obvious behavior, or anything a future engineer working on similar code should know. Skip if nothing is notable. libghostty quirks, SwiftUI ↔ NSView lifecycle gotchas, Metal layer sizing surprises, and IME edge cases are exactly the kind of thing that belongs here.

8. **Make the resolution commit.** Stage `issues/NNNN.md` and commit with message `#NNNN Resolve: <title>`. Body briefly notes which code commit it pairs with (the hash from step 6).

Status flow: `open` → `in-progress` → `resolved`. **Never set `closed`** — the user does that after verifying the fix.

### Build / verify command for this project

The canonical "did I break the build?" check is:

```bash
scripts/build.sh
```

To also run unit and UI tests:

```bash
scripts/build.sh test
```

`scripts/build.sh` is a wrapper that resolves SPM packages, applies a workaround for the upstream `libghostty.framework` macOS-slice packaging bug (see [[0212]]), then invokes `xcodebuild`. Raw `xcodebuild -scheme "Batty (Prod)" -destination 'platform=macOS' build` will fail at the embed-frameworks validation step — always go through the wrapper. The actual scheme is `Batty (Prod)`, not `Batty`.

Open the project in Xcode (`open Batty.xcodeproj`) for live development, breakpoints, and SwiftUI previews — but always confirm the headless `scripts/build.sh` invocation passes before committing.

### When the subagent can't finish

If the bug is unreproducible, out of scope, or the build won't pass after reasonable effort:

1. **Discard or stash any partial code changes** so the bail doesn't accidentally include half-done work.
2. **Revert status to `open`** in the issue markdown so the issue goes back into the queue.
3. **Add a `## Notes` section** describing what was tried, why work stopped, and what you'd try next. Be specific.
4. Commit the markdown change with message `#NNNN Notes: <one-line bail summary>`.
5. Return with a one-line summary of why work stalled.

Never use `wontfix` or `closed` to escape a stuck issue.

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
| `Session` | Session model, session detail view, Cmd-Option-1..9 selection |
| `Split` | Split tree, dividers, drag-resize, keyboard resize, focus movement |
| `Pane` | Pane view, per-pane toolbar, pane lifecycle (collapse on last-tab-close) |
| `Tabs` | SlidingTabs integration, tab lifecycle, Cmd-T/Cmd-W/Cmd-1..9 |
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
