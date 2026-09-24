# AGENTS.md — Batty

A native macOS terminal multiplexer built on libghostty. Single-window default, session sidebar, splits and tabs, bell-driven notification feed. macOS 15.6+.

This file is binding guidance for every agent session and subagent (Claude Code, Codex, and others). `CLAUDE.md` only imports this file; edit guidance here, not there. **If something here contradicts a downstream skill, this file wins for code/repo conventions; `issues/Issues.md` wins for issue-tracker workflow.**

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

**`./build.sh` in the repo root is the single entry point.** Everything
defaults to the `Batty (Beta)` scheme — Beta is the variant you develop and
test against, building `Batty Beta.app` under `co.sstools.Batty.beta`, so it
never collides with the Prod app running from `/Applications`. Prod is for
release builds only.

```bash
# Build only (the canonical "did I break the build?" check) — Beta
./build.sh

# Run BattyKit unit tests — fast, no UI, runs before every commit
./build.sh unit

# Run UI tests -- ONLY inside the Tart VM, never on a host Mac (see below)
./build.sh ui                                     # all UI tests
./build.sh ui BattyUITests/TabRenameTests         # one class
./build.sh ui BattyUITests/TabRenameTests/testRenameActiveTabUpdatesChipTitle

# Package a Batty Beta.app to install alongside Prod
./build.sh package [--sign]

# Release builds — the only path that uses the Prod scheme
./build.sh release [archive|build|...]

# Open in Xcode for live development, breakpoints, SwiftUI previews
# (use the workspace, not the .xcodeproj, so BattyKitTests appears in
# the Test Navigator alongside the project's own test targets)
open Batty.xcworkspace
```

Any other action passes through to `xcodebuild` under the Beta scheme, so
`./build.sh archive`, `./build.sh analyze`, and friends still work.

**Test strategy:**

- **Unit tests** (`./build.sh unit`) — run `BattyKitTests` only (skips UI tests). Fast (<30 s), no UI, no machine lock. Run before every `git commit` after any code change. Tests live in the `BattyKit` Swift package (`BattyKit/Tests/BattyKitTests/`) so the package can stand on its own (`cd BattyKit && swift test` works). In Xcode, open `Batty.xcworkspace` (not `Batty.xcodeproj`) — the workspace includes the BattyKit package, so BattyKitTests appear in the Test Navigator. Use the `Batty (Beta)` scheme there; `Batty (Prod)` also lists them, but Prod is for release builds only.
- **UI tests** — run the full `BattyUITests` suite (60+ tests, ~10 min). **Only inside a disposable Tart VM** (see "UI test automation" below), never on a host Mac. Use for release preflight and when adding or fixing a UI-level feature. New UI features should be covered by new UI tests. Any regression found by UI tests must be fixed and tracked as a new issue.
- **Release build** (`./build.sh release archive -archivePath dist/Batty.xcarchive -configuration Release`) — the only path that compiles at `-O`, and the only one that exercises the universal (arm64 + x86_64) slices. **Run it before cutting any release, and after any change to a type with non-trivial generics or deinit.** Debug and Beta builds do not cover it: `-O` reaches optimizer paths Debug never runs, and a Release-only compiler crash went undetected for months because nothing in the routine loop built at `-O` (#0391 — swift-frontend 6.3.3 crashed in the SIL `EarlyPerfInliner` on a generic class's implicit `deinit`, blocking the entire release pipeline).

Always confirm the headless `./build.sh` invocation passes before committing — Xcode previews are not a build pass.

**Never invoke `xcodebuild` directly for a build you intend to trust, and never override the scheme by hand.** Prod vs Beta is selected by `Configuration/Active.xcconfig`, a gitignored file that `#include`s either `Prod.xcconfig` or `Beta.xcconfig`. The `Batty (Beta)` scheme has a pre-action that points it at Beta via `scripts/set-environment.sh`, but that pre-action runs **after** `xcodebuild` has already resolved build settings — so it only takes effect on the *next* invocation (#0280). That lag is why a hand-rolled `xcodebuild` invocation can silently build the other variant while reporting the scheme you asked for.

`./build.sh`, `./build.sh package`, and `scripts/run-ui-tests.sh` each snapshot `Active.xcconfig` on entry, select the variant they need *before* invoking `xcodebuild`, and restore what they found on every exit path — including Ctrl-C and failures. Use them and the problem does not arise.

If a build ever looks wrong, check the environment first:

```bash
cat Configuration/Active.xcconfig                        # what is selected right now
./scripts/set-environment.sh Beta                        # or Prod
xcodebuild -project Batty.xcodeproj -scheme "Batty (Beta)" \
    -showBuildSettings | grep PRODUCT_NAME               # expect: Batty Beta
```

Related: Prod and Beta share one target, so whichever scheme resolved last caches its product name into the tracked `Batty.xcodeproj/project.pbxproj` (`Batty.app` ↔ `Batty Beta.app`), and Xcode also rewrites `BuildableName` in the tracked `.xcscheme` files the same way. **A dirty `project.pbxproj` or `.xcscheme` after a build is expected residue — discard it (`git checkout --`), never commit it.**

## Asynchronous tests (binding)

**Never make a unit test pass by waiting.** No `Task.sleep`, `Thread.sleep`, `usleep`,
`DispatchQueue.asyncAfter`, or poll-until-deadline loops to "give async work time to finish",
and no assertions on elapsed wall-clock time. They make tests slow and unreliable under load
(#0423 is the record of what that costs).

- Assert only once the code under test has **signalled** completion: `await` the async API
  itself, await a `Task`/handle the code returns or exposes for testing, use a
  continuation, `AsyncStream`, callback or event the production code emits, or
  `confirmation(...)` in Swift Testing.
- If the production code offers no completion signal, add one (a returned `Task`, a
  completion callback, an event stream, an injected clock/scheduler) rather than waiting in
  the test. A test-only seam must not change production behaviour.
- Periodic work (samplers, pollers, backoff) is driven through an injected clock or
  scheduler the test advances explicitly, not by letting real time pass.
- External processes signal readiness through a pipe or file the test awaits as an event
  (e.g. a `FileHandle` readability handler), not by sleeping until they're probably ready.
- "Returns without blocking" is proven structurally — the work runs on a task or scheduler
  the test controls — not by timing the call.
- Every await in a test still has an upper bound so a regression fails instead of hanging,
  but that bound is a failure guard, never the mechanism the test relies on.

See `docs/isolate-userdefaults-in-tests.md` for the companion rule on `UserDefaults`.
See `docs/async-test-seams.md` for the shared injected clock, child-readiness helper, reap gate, and completion-signal conventions (`#0428`) that BattyKit's async tests route through instead of each inventing their own.

## UI test automation (binding)

**UI tests never run on a host Mac — only inside a disposable Tart VM.** XCUITest's
`testmanagerd` bootstraps `XCTAutomationSupport` into *every* running GUI app it
enumerates through Accessibility, not just the app under test. On 2026-09-12 a UI test
run from another project did exactly that to the user's running Prod Batty and crashed
it (`EXC_BAD_ACCESS` in `-[XCTAutomationSession initWithAccessibilityFramework:dataSource:]`),
killing every live Terminal Session (#0409). A Batty UI test run on the host is the same
hazard aimed at the user's own terminals.

- The VM setup, runner, and guards are documented in **`docs/ui-testing-vm.md`** (#0412);
  the shared host-side setup (Tart, the golden images, memory coordination) is in
  `~/Developer/Homelab/cameron/tart-ui-test-vm.md`.
- Run UI tests only through the VM runner it describes. It exports a clean `git archive HEAD`
  snapshot, so **commit first** — uncommitted edits are not tested.
- Never run `xcodebuild ... test` against `BattyUITests`, `scripts/run-ui-tests.sh`, or any
  `osascript`/System Events UI scripting on the host. Synthetic input goes to whatever app is
  frontmost, which is usually the user's Batty.
- Only one VM runs at a time on this host. Parallel subagents must not each start a VM run;
  the orchestrator serializes them.
- Unit tests (`./build.sh unit`) and builds stay on the host; they load nothing into other apps.

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
