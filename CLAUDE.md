# CLAUDE.md — Batty

A native macOS terminal multiplexer built on libghostty. Single-window default, session sidebar, splits and tabs, bell-driven notification feed. macOS 15.6+.

This file is binding guidance for Claude sessions and subagents. **If something here contradicts a downstream skill, this file wins for code/repo conventions; `issues/Issues.md` wins for issue-tracker workflow.**

## Read these first

When starting any non-trivial task, read in this order:

1. `PRD.md` — product spec, milestones, success criteria.
2. `Concepts.md` — canonical vocabulary (Window, Session, Pane, Tab, Terminal Session, Split, Theme, Bell Feed, Surface registry). Use these terms exactly; don't invent synonyms.
3. `issues/Issues.md` — issue tracker workflow, status vocabulary, module conventions.
4. `issues/NNNN.md` if working a specific issue.

For any work touching the terminal / pane / tab / window path, **also read
`docs/view-hierarchy.md` first** — it explains how the model hierarchy
maps onto the SwiftUI tree and the persistent AppKit terminal host, and
lists the non-negotiable rules for the terminal-host architecture.

For any work that adds gestures, overlays, drag handlers, or new event
routing to the pane body, **also read `docs/terminal-pane-requirements.md`**
— it lists the non-negotiable terminal behaviors (pointer input, keyboard,
file drop, text drop, IME) that every pane must preserve, the AppKit z-order
constraint that makes this hard, and a manual checklist to run before marking
the feature complete. The regressions in #0143 (file drops broken, clicks
broken) are documented there as concrete examples of what goes wrong when this
is skipped.

For any work that writes `@Observable` / `@State` properties from view-driven
code (`body`, `onChange`, `onAppear`, `onGeometryChange`) — and for *any*
change to focus or selection flow — **also read
`docs/swiftui-observation-rules.md` first; it is binding.** Core invariant:
view construction is pure (`body`, view inits, representable updates,
preference reductions never write observed state); `onChange`/`onAppear`
writes are audited by *what flipped the observed value* — event-origin flips
are routine, layout/focus/geometry-origin flips run inside AppKit machinery
and must not write. `NSHostingView` runs SwiftUI updates inside AppKit's
layout pass, so SwiftUI callbacks must never synchronously call
constraint-dirtying or responder-changing AppKit APIs (`makeFirstResponder`,
`addSubview`). `@Observable` notifies on every write, including equal-value
writes. Never "fix" a mutate-during-update violation by hopping the write
into a `Task` — that trades a crash for a race (the #0229 click regression).
Restructure *which code owns the write* instead.

The `docs/` folder has additional topical guides (see `docs/README.md`).

## Build / verify commands

```bash
# Build only (the canonical "did I break the build?" check)
scripts/build.sh

# Run BattyKit unit tests — fast, no UI, runs before every commit
scripts/build.sh unit

# Run UI tests (slow; blocks the machine; run on the Mac mini for preflight/release)
scripts/run-ui-tests.sh                              # all UI tests
scripts/run-ui-tests.sh BattyUITests/TabRenameTests  # one class
scripts/run-ui-tests.sh BattyUITests/TabRenameTests/testRenameActiveTabUpdatesChipTitle  # one test

# Open in Xcode for live development, breakpoints, SwiftUI previews
# (use the workspace, not the .xcodeproj, so BattyKitTests appears in
# the Test Navigator alongside the project's own test targets)
open Batty.xcworkspace
```

**Test strategy:**

- **Unit tests** (`scripts/build.sh unit`) — run `BattyKitTests` only (skips UI tests). Fast (<30 s), no UI, no machine lock. Run before every `git commit` after any code change. Tests live in the `BattyKit` Swift package (`BattyKit/Tests/BattyKitTests/`) so the package can stand on its own (`cd BattyKit && swift test` works). In Xcode, open `Batty.xcworkspace` (not `Batty.xcodeproj`) — the workspace includes the BattyKit package so BattyKitTests appear in the Test Navigator under the `Batty (Prod)` and `Batty (Beta)` schemes.
- **UI tests** (`scripts/run-ui-tests.sh`) — run the full `BattyUITests` suite (60 tests, ~10 min, locks the machine). Use only for release preflight and when explicitly adding or fixing a UI-level feature. Run on the Mac mini so the MacBook stays free. New UI features should be covered by new UI tests. Any regression found by UI tests must be fixed and tracked as a new issue.

`scripts/build.sh` is a thin wrapper that invokes `xcodebuild` with the correct scheme (`Batty (Prod)`) and destination. Direct `xcodebuild` calls work too; the wrapper is a convenience. The actual scheme is `Batty (Prod)`, not `Batty`.

Always confirm the headless `scripts/build.sh` invocation passes before committing — Xcode previews are not a build pass.

**Build Beta only via `scripts/build-beta.sh`. Never `SCHEME="Batty (Beta)" scripts/build.sh`.**

This project selects Prod vs Beta through `Configuration/Active.xcconfig`, a gitignored file that `#include`s either `Prod.xcconfig` or `Beta.xcconfig`. The `Batty (Beta)` scheme's pre-action points it at Beta via `scripts/set-environment.sh`; otherwise it stays on Prod. That is the design, and it works — but it is *persistent machine state*, and the scheme pre-action runs **after** `xcodebuild` has already resolved build settings, so it only takes effect on the *next* invocation.

The consequence: anything that builds Beta and does not put the file back leaves the environment switched, and the **next `scripts/build.sh` silently builds the Beta product while reporting Prod** (`PRODUCT_NAME = Batty Beta`, `PRODUCT_BUNDLE_IDENTIFIER = co.sstools.Batty.beta`). The pre-commit gate then verifies the wrong artifact and says nothing. `scripts/build-beta.sh` exists precisely to snapshot `Active.xcconfig` on entry and restore it on exit; reaching around it with the `SCHEME` override defeats that.

If a build ever looks wrong, check the environment first:

```bash
cat Configuration/Active.xcconfig                        # expect: #include "Prod.xcconfig"
./scripts/set-environment.sh Prod                        # restore it
xcodebuild -project Batty.xcodeproj -scheme "Batty (Prod)" \
    -showBuildSettings | grep PRODUCT_NAME               # expect: Batty
```

Related: Prod and Beta share one target, so whichever scheme resolved last caches its product name into the tracked `Batty.xcodeproj/project.pbxproj` (`Batty.app` ↔ `Batty Beta.app`). **A dirty `project.pbxproj` after a Beta build is expected residue — discard it (`git checkout --`), never commit it.** Committing it just makes the next Prod build flip it back.

**Run UI tests via `scripts/run-ui-tests.sh`, not raw `xcodebuild test`.** Xcode builds `BattyUITests-Runner.app` by dropping our xctest bundle into Apple's signed XCTRunner template without re-signing the outer app. Ad-hoc local builds end up with a broken signature ("code has no resources but signature indicates they must be present"), which AppleSystemPolicy treats as a tampered Apple binary — macOS Gatekeeper translocates the runner to `~/.Trash` and kills it before `xcodebuild test` can bootstrap. The script re-signs the runner + host app ad-hoc after `build-for-testing` and then invokes `test-without-building`, sidestepping the trash-prompt loop.

## Release / distribution

Release scripts live in `scripts/`:

- `scripts/release.sh` — full pipeline: archive → sign → notarize → DMG → staple → verify. Output: `dist/Batty-<sha>.dmg`.
- `scripts/verify-dmg.sh <path/to/file.dmg>` — verifies signing, notarization, stapling, and Gatekeeper acceptance under quarantine.
- `scripts/setup-keys.sh` — one-time setup of the `Batty-notary` keychain profile.

**Do not run `scripts/release.sh` autonomously.** Notarization submits the binary to Apple, which counts as modifying a shared system. Get explicit go-ahead each time.

## Project layout

```
Batty/
├── Batty.xcodeproj/          # Xcode app project
├── Batty/                    # main app target sources (file-system synchronized group)
│   ├── BattyApp.swift
│   ├── ContentView.swift
│   └── Assets.xcassets/
├── BattyTests/               # unit tests (Swift Testing — `import Testing`)
├── BattyUITests/             # UI tests (XCTest)
├── Configuration/
│   └── Build.xcconfig        # all build settings (deployment target, swift version, etc.)
├── Artwork/                  # source artwork; not in the app bundle
├── scripts/                  # release / verification scripts
├── issues/                   # markdown issue tracker (one file per issue)
├── PRD.md                    # product requirements
├── Concepts.md               # canonical vocabulary
└── batty-getting-started.md  # external getting-started reference (libghostty, integration paths)
```

The `Batty/` source folder uses Xcode's **`PBXFileSystemSynchronizedRootGroup`** — files added to the folder are picked up automatically; you don't need to edit `project.pbxproj` to add new Swift files.

## Code conventions

- **Swift 6.0**, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — main-actor is the default. Mark types `Sendable` or actor-isolated only when they truly need to cross actor boundaries.
- **No comments unless the *why* is non-obvious** — the *what* is in the code. Don't write `// Set up the view` or document obvious behavior. Comments belong on hidden constraints, subtle invariants, workarounds for specific bugs, or libghostty quirks.
- **Don't reference current task / fix / callers** in comments — those rot. Use the issue or PR description for that context.
- **Headers are minimal**: `// FileName.swift` and a blank line. No author, date, project name. Xcode templates are configured via `Batty.xcodeproj/xcshareddata/IDETemplateMacros.plist` to generate this.
- **No emojis in code or commits** unless explicitly requested.

## Logging

Each `.swift` file that needs to emit logs declares a file-scoped logger at the top:

```swift
nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "<Filename>")
```

`Logging.subsystem` lives in `BattyKit/Sources/BattyKit/Logging.swift` and is sourced from `Bundle.main.bundleIdentifier`. Use `nonisolated` so the logger doesn't inherit `@MainActor` from the package's default isolation. Use `private` to scope the logger to the file. Use the matching filename as the category so Console.app filters work cleanly.

Do **not** use `print()` or `NSLog()` for diagnostics — they disappear in release.

## Architectural rules

- **Surface registry is the single source of truth for live Terminal Sessions.** SwiftUI views only ever store `surfaceID: UUID`, never a `ghostty_surface_t` directly. View rebuilds must not destroy surfaces.
- **Layout model is pure value types** (currently `SplitDirection` and `Pane` in `LayoutModel.swift` — the Codable `Session`/`Tab`/`SplitNode` snapshot types were deleted along with workspace persistence in #0172, not merely renamed) — Codable, Sendable, no view or libghostty types embedded. Workspace persistence (`workspace.json`) was built, then removed (#0172); `Pane` stays Codable and persistence-ready even though nothing serializes it today.
- **App is unsandboxed.** Terminal apps run arbitrary user processes (shells, compilers, etc.) and can't fit App Store sandbox rules. `ENABLE_APP_SANDBOX = NO` in the `Batty` target. Hardened Runtime stays on for notarization.

## Restricted areas

Don't modify these without explicit user confirmation:

- **`Configuration/Build.xcconfig`** — bundle id, signing team, deployment target, Swift settings. Changing these affects code signing and CI.
- **`scripts/`** — release pipeline. Authored deliberately; small mistakes break notarization.
- **`Artwork/`** and `Batty/Assets.xcassets/AppIcon.appiconset/` — app icon assets are user-curated.

## Issue tracker workflow

See `issues/Issues.md` for the full workflow — **read it before touching any issue; it is authoritative and more detailed than this summary.** Short version:

- Each issue is `issues/NNNN.md` with a metadata table at the top.
- Status: `open` → `in-progress` → `resolved` → `closed`. **Never set `closed`** — that's the user's transition after they verify.
- **Resolving an issue is review-gated and role-split (binding, for cost and quality):**
  - All work happens on a branch `issue/NNNN`; `main` receives one squash commit after review approval. The branch is kept, never pushed or deleted.
  - A **filer subagent pinned to the top available model** (currently Fable, `claude-fable-5`) creates new `NNNN.md` files on `main` — no branch, no review gate.
  - An **implementer subagent pinned to Sonnet** (`claude-sonnet-5`) does the code work and verification on the branch.
  - A **reviewer subagent pinned to Opus** (`claude-opus-4-8`) reviews `git diff main...HEAD`; approve or request-changes. Findings route back to the *same* implementer agent.
  - The **main session orchestrates only** — it dispatches the filer for new issues, creates branches, dispatches the implementer/reviewer subagents, records review/work-log commits, and squash-merges after approval. It does **not** file, implement, or review inline, even for small follow-ups; those go to the respective subagent.
  - `resolved` is set only after the reviewer approves. Metadata gets a `**Branch**` row (no `**Commit**` row); the issue file carries per-round `## Work log` cost rows.
- Module names are listed in `issues/Issues.md` under "Module conventions for this project". Don't invent new ones ad-hoc.

## Authoring rules

- **Never close issues based on inference.** Only when the user has said so in plain language.
- **Never auto-run shared-state actions:** `release.sh`, `git push`, GitHub releases, notarization. Always confirm.
- **For UI work, mark `resolved` not `closed`** — visual sign-off is the user's. Note in `## Gotchas` exactly what you couldn't verify.
