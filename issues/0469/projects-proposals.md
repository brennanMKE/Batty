# Projects — design proposals for 1.3.0

Decision document for the "Projects" feature that `AGENTS.md` names as the
first feature-flagged work on `main` ("Projects is the first such feature,
for 1.3.0, while `release/1.2` carries 1.2.x fixes"). There is no written
spec for Projects anywhere in the repo — not in `PRD.md`, `Concepts.md`,
`issues/`, or `website/` — so this document infers the plausible scopes
from what the codebase already does and asks the user to pick one.

Nothing here is implemented. No issue is filed. Read-only research as of
`main` at `dfd7d39a` (2026-10-11).

---

## 1. What exists today that Projects would build on

Everything below is in the tree now. File references are
`path:line` on `main`.

### 1.1 Sessions already behave like "one per project"

- `PRD.md:20` — "A sidebar of named sessions for different
  projects/contexts." `Concepts.md:45` — a Session's purpose is "typically
  one Session per project, context, or remote host." The *word* project is
  already the informal unit; it just has no model.
- `SessionRuntime` (`BattyKit/Sources/BattyKit/Runtime/SessionRuntime.swift:9-43`)
  carries `title`, `titleOverride` (user pin, #0089), `localThemeName`
  (per-Session theme, #0147), `colorIndex` + `colorOverride` (10-color
  palette, #0335/#0336, `Runtime/SessionColor.swift:13-24`). None of it is
  persisted; every launch starts with a fresh `Session 1`
  (`Runtime/WindowRuntime.swift:106-118`).
- `WindowRuntime.addSession(title:workingDirectory:)`
  (`Runtime/WindowRuntime.swift:185-214`) is the one creation path: it
  inherits the focused Pane's cwd, consults `SessionNameCache`, and sets
  `titleOverride = true` when a title is passed explicitly (`:209-211`).
  `AppStateStore.addSession` (`Runtime/AppStateStore.swift:1082-1100`) wraps
  it with key-window targeting and emits the `session_created` XPC watch
  event.

### 1.2 Project *detection* already exists, three layers deep

The cwd → name chain in `AppStateStore.applySessionAutoNaming`
(`Runtime/AppStateStore.swift:1966-2010`) and the pure
`resolveAutoTitle(forCWD:sessionIndex:cache:resolver:nameFromFiles:)`
(`:2079-2093`):

1. `SessionNameCache` hit — the user's previous rename at this exact path
   (#0058). Persisted at
   `~/Library/Application Support/<Batty|Batty Beta>/session-name-cache.json`
   (`Model/SessionNameCache.swift:93-113`), 100-entry LRU, atomic writes
   (`:213-215`), per-variant directory (#0279).
2. `ProjectNameResolver` — manifest-based name extraction
   (`ProjectName/ProjectNameResolver.swift:5-20`, rules in
   `Resources/project-name-rules.json`, catalog in
   `docs/project-name-extraction.md`) (#0089).
3. Foundation Models suggestion for markerless folders (#0231, #0232),
   gated by Settings toggles (#0233, `Settings/SettingsPreferences.swift:16-17`).

The chain is **single-Pane only** (`:1975`, #0213) because a multi-Pane
Session has no canonical cwd. It fires from the libghostty pwd delegate via
`applyReportedWorkingDirectory` (#0436) — event-origin, so writing
`session.title` there is sanctioned by `docs/swiftui-observation-rules.md`.

What it does **not** do: find a project *root*. It matches the exact cwd
against a cache or a manifest in that directory. `cd src/` inside a
project loses the name (`docs/project-name-extraction.md:438` even calls
this out for monorepos).

### 1.3 A project-local config file is already proposed, and open

`issues/0247.md` (open): `.batty/config` (TOML) with a `title` field, read
only when a Settings toggle is on, never written by Batty, strictly
declarative (no shell, env, or commands — `:47-51`). It slots into the
chain above cache, below user rename (`:33-41`). Its security posture is
the one any per-project settings file must copy.

### 1.4 Layout presets exist; a saved multi-kind "Workspace" is specified and open

- `PaneLayout` (`Model/PaneLayout.swift:9-19`) — ten fixed all-terminal
  presets; `apply(to:)` (`:132-209`) replays ordinary splits with no stored
  geometry, gated on a single Pane (`:133`). Entry points: Session menu
  (`Commands/BattyCommands.swift:111-117`), Pane menu, the NSEvent monitor
  (`Commands/BattyShortcuts.swift:190-191`), and the Command Palette
  (`Views/CommandPaletteView.swift:280`).
- `issues/0371.md` (open, **user-decided name: "Workspace"**, 2026-08-27): a
  saved, named split topology with a `PaneContentKind` per leaf — no
  ratios, no cwds, no Tabs — applied by replaying splits via
  `SplitTree.splitPane(id:direction:ratio:command:kind:processStatusPid:path:contentFactory:isSessionSelected:)`
  (`Model/SplitTree.swift:418-430`). It already settles where such a file
  lives (per-variant App Support, `SessionNameCache` shape, `:188`) and
  argues at length that this is *not* a revival of #0172 (`:88-97`).
  `Concepts.md` has no "Workspace" or "Layout" entry yet; #0371 commits to
  adding one.

### 1.5 Persistence: what was removed in #0172 and why it matters here

`issues/0172.md`: `Workspace.swift`, `WorkspaceConversion.swift`,
`WorkspaceManager.swift`, `WorkspaceStore.swift` and `workspace.json` were
deleted outright. The objection (`issues/0055.md`) was to *automatic
whole-app session restore* — relaunching into a window of dead shells is
"not normal terminal-app behavior." #0444 later also disabled window
restoration (`Batty/BattyApp.swift:49`).

What #0172 explicitly left alone: `SessionNameCache` (`issues/0172.md:88`)
— a small, user-authored, per-directory file. That is the precedent every
proposal below follows: **user-authored records keyed by directory, read on
explicit action or on a cwd event, never auto-snapshotting live layout.**
The Codable value types `SplitDirection` and `Pane` (`Model/LayoutModel.swift:5-44`)
survived as "persistence-ready" but nothing serializes them
(`docs/view-hierarchy.md:39-45`).

### 1.6 Entry-point surfaces a Project feature would plug into

| Surface | Where | Pattern to copy |
|---|---|---|
| File menu | `Commands/BattyCommands.swift:66-88` (`CommandGroup(replacing: .newItem)`: New Window, New Session, Open Quickly) | Add a submenu; `.disabled(keyWindow == nil)` guard |
| Session menu | `BattyCommands.swift:101-133` | "Choose Layout…" gating |
| Sidebar row context menu | `Views/SessionSidebarView.swift:274-308` (Rename / Reset Name / Set Color… / Set Session Theme… / mute / Close) | Insert a `Divider()` + items |
| Command Palette | `Views/CommandPaletteView.swift:52-110`; conditional entries already exist — `UpdaterController.shared.isConfigured` (`:86`) and the `theme:` loop (`:100`) | Add `project:<id>` entries only when flagged on |
| Settings | `Views/SettingsView.swift:82-85` "Session Naming" section; keys/accessors in `Settings/SettingsPreferences.swift:7-19`, `:123-128` | `resolvedX(defaults:)` injectable accessor |
| CLI | `BattyKit/Sources/batty/BattyCLI.swift:14` subcommand list; `batty new [path]` → `batty://session?path=` (`BattyCLICore/SessionURLBuilder.swift:33-40`, `Runtime/BattyURLHandler.swift:20-30`); XPC verbs in `BattyXPCCore/XPCVerb.swift` | `capabilities` is derived from `BattyCLI.configuration.subcommands` (`batty/CapabilitiesCommand.swift:100`), so an omitted subcommand is also absent from `capabilities` for free |
| Shortcuts | `Shortcuts/ShortcutAction.swift:15-55`; **three hand-copied dispatch switches** (`BattyCommands`, `BattyShortcuts`, `CommandPaletteView.dispatch`) plus `ShortcutsSettingsView.swift:16` and `ShortcutDocsSyncTests.swift:166-179`, all driven by `ShortcutAction.allCases` | See §4.3 — `ShortcutAction` is the hardest thing to keep "invisible" |
| UI test driver | `Testing/UITestDriver.swift:236-260` intents (`createSession`, `applyLayout`, `createPane(kind)`) | Add `openProject(name:)` |

### 1.7 How Beta and Prod are told apart (the flag must hang off this)

Two mechanisms, deliberately different:

- **App target and BattyKit — runtime, by bundle identifier.**
  `Configuration/Beta.xcconfig` sets `PRODUCT_BUNDLE_IDENTIFIER =
  co.sstools.Batty.beta` and `APP_PRODUCT_NAME = Batty Beta`;
  `App.xcconfig` is Prod (`co.sstools.Batty`). `Active.xcconfig` selects
  one via `#include` (`scripts/set-environment.sh`). In code,
  `ServiceNames.Variant(bundleIdentifier: Bundle.main.bundleIdentifier)`
  (`BattyXPCCore/ServiceNames.swift:93-100`) is the canonical runtime
  resolver, already used by `SessionNameCache.resolvedDirectoryName`
  (`:93-102`), `CLIInstaller.resolvedInstallPath`, and
  `BrokerAgentController.resolvedPlistName`. Each fails closed to Prod with
  a logged error when the identifier matches neither variant.
- **Bare Mach-Os (`batty` CLI, `BattyBroker`) — compile-time.** The "Embed
  CLI" / "Embed Broker" build phases pass `-Xswiftc -DBATTY_VARIANT_BETA`
  to `swift build` when the bundle identifier is Beta's;
  `ServiceNames.current` (`ServiceNames.swift:152-156`) reads it. There is
  **no** `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for Beta in the app target
  (only `DEBUG` on the Debug configuration, `project.pbxproj:452`), and
  xcconfig compilation conditions would not propagate into the SPM package
  anyway — so a `#if BETA` inside BattyKit is not an option. Runtime
  bundle-id it is.

Precedents for "present in Beta, absent in Prod": Sparkle is disabled in
Beta by blanking `SU_FEED_URL` (`Beta.xcconfig`) and the palette hides
"Check for Updates…" on `isConfigured` (`CommandPaletteView.swift:86`);
`UITestDriver` is env-gated at runtime, not `#if DEBUG`, "because UI tests
run against the Beta build" (`Testing/UITestDriver.swift:14`).

### 1.8 Guardrails from existing decisions

- `PRD.md:51-58` non-goals: no scripting/config language, no plugin
  system, no custom shell integrations.
- `docs/supacode-feature-review.md:177-193` declines: git-worktree sidebar,
  repository-grouped sidebar ("Batty's flat session list is simpler by
  design"), per-repo script system ("automation/config-as-data"), zmx-style
  shell persistence. It *recommends* (Tier 2) per-session color tint —
  since shipped as Session color — and `batty new [path]` — shipped.
- `docs/batty-cli-design.md:38` — the CLI noun set is `session`, `pane`,
  `tab`, `window`; "no `workspace`, no `worktree`." A `project` noun is a
  deliberate extension of that decision.
- User memory: terminal-multiplexer features only; no new toolbar buttons.

---

## 2. Proposals

Three distinct meanings of "Project," ordered from smallest to largest.
Each is self-contained, but they compose (see §3). Two further readings
were considered and rejected up front (§2.4).

Shared across all three:

- **Vocabulary.** `Concepts.md` gains a `## Project` entry under
  "Containers" (between Window and Session, since a Project is what a
  Session is typically *for*). The word "project" (lowercase) already
  appears in `Concepts.md:45` and `PRD.md:20`; the new entry must
  distinguish *Project* (the saved record) from the informal usage, the
  same way #0371 must re-gloss Session's "workspace" wording.
- **Storage.** `~/Library/Application Support/<Batty|Batty Beta>/projects.json`,
  resolved through `SessionNameCache.resolvedDirectoryName(bundleIdentifier:)`
  (per-variant, #0279), atomic temp-then-`replaceItemAt` writes, a
  `version` field, bounded size. A `ProjectStore` (`@MainActor @Observable`)
  in `Model/` mirrors `SessionNameCache`'s shape, injectable `fileURL` for
  tests (`docs/isolate-userdefaults-in-tests.md` spirit).
- **#0172 squaring.** All three store *user-authored records keyed by a
  directory*, written on explicit user action, never on quit or on a
  timer, never capturing live layout, Tabs, cwds-per-pane, or processes.
  That is `SessionNameCache`'s category, which #0172 kept. The document
  must say so in the `Concepts.md` entry so the next `grep workspace`
  reader does not conflate them (as #0371 already does for Workspace).
- **PRD non-goal squaring.** No field in `projects.json` (or in #0247's
  `.batty/config`) may run anything: no shell, no env, no startup command.
  Declarative identity and appearance only. This is the line #0247 drew
  and `docs/supacode-feature-review.md:187` reinforces.
- **Multi-window.** Projects are process-global like `SessionNameCache`
  (`docs/multi-window-design.md:94-95`), not per-Window. "Open Project"
  targets the key window via `AppStateStore.addSession`'s
  `defaultTargetWindow()`.

### 2.1 Proposal A — Project Launcher: a Project is a named root directory you can open

**Concept.** A Project is a *bookmark*: `{ id, name, rootPath, colorIndex?, lastOpenedAt }`.
Opening a Project creates a Session rooted at `rootPath`, titled `name`
(pinned), colored `colorIndex` if set (pinned). That is all. It is the
"File → Open Recent" of a terminal multiplexer, and it answers the one
friction the naming chain cannot: *starting* in a project without
`cd`-ing there first (today `batty <path>` is the only way, and it is a
shell command).

**Vocabulary (Concepts.md).** *Project* — a saved, named root directory.
Opening it creates a Session rooted there. A Session may be *associated*
with a Project (`SessionRuntime.projectID: UUID?`, in-memory only) for as
long as it lives; the association is informational (Sidebar glyph, CLI
`batty id`), never enforced — the shell can `cd` anywhere.

**UX.**

- File menu: **Open Project ▸** submenu listing saved Projects (most
  recently opened first), then `Divider`, **Add Project…** (an
  `NSOpenPanel` for a folder; name pre-filled by `ProjectNameResolver`,
  else basename), **Manage Projects…** (a sheet: rename, recolor, remove,
  reorder). No new `ShortcutAction` cases in phase 1 (see §4.3 for why).
- Sidebar: a Session associated with a Project shows a folder-style glyph
  tint (reuses `session.sessionColor`); context menu gains
  **Save as Project…** (captures anchor-Tab cwd + current title + color,
  single-Pane rule not required — it reads the *anchor* cwd like naming
  does) and, for an associated Session, **Reveal Project in Finder**.
- Command Palette: `Project: <name>` entries (one per saved Project),
  plus `Add Project…`. Gated like the `theme:` loop.
- Session menu: nothing new (Open Project lives in File, matching macOS
  "Open…" conventions and #0371's "File menu" request for new-Session
  creation).
- CLI: `batty project list [--json]`, `batty project open <name|id> [--json]`
  (returns session/pane ids like `batty new`), `batty project add <path> [--name]`,
  `batty project remove <name|id>`. `batty new <path>` unchanged. `batty id`
  gains `project` when the Tab's Session is associated. This adds a fifth
  noun to the CLI; alternative that avoids it: `batty new --project <name>`
  only. See open question 7.
- Settings: none required. Optionally General → "Projects" with
  "Open a Project's Session in a new Window" (off).

**Data model.**

```swift
// Model/Project.swift
public struct Project: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var rootPath: String        // absolute, standardized (SessionURLBuilder.resolve)
    public var colorIndex: Int?        // nil = let the Window's assigner choose
    public var lastOpenedAt: Date?
}
struct ProjectsFile: Codable { var version: Int; var projects: [Project] }
```

`ProjectStore` owns the array, the file, and `open(_:)` which calls
`AppStateStore.addSession(title: project.name, workingDirectory: project.rootPath)`
then `WindowRuntime.setSessionColor(id:to:)` and sets
`session.projectID`. Title passed explicitly → `titleOverride = true`
(`WindowRuntime.swift:209-211`), so the naming chain stays out of it, and
`SessionNameCache` is **not** written (a Project is not a rename).

**Interaction with the naming chain.** None, by design. A Session opened
from a Project is pinned; a Session the user `cd`s into a Project's root
is *not* retroactively associated (that is Proposal C's job).

**Feature-flag plan.** See §4. Gate sites: File submenu, Sidebar context
items + glyph, palette entries, CLI subcommand + XPC verb handling,
`ProjectStore` construction (nil when off → no file I/O), `batty id`
field, `UITestDriver` intent.

**Risks.**

- Terminal host: none. It calls the existing `addSession` path; no Pane
  or surface code changes.
- Observation: `projectID`/`colorIndex` writes happen in `open(_:)`
  (menu/palette/XPC origin) — event-origin, sanctioned.
- `rootPath` rot: a removed directory must fail the open with a clear
  alert, not a `$HOME` Session with the wrong name (`SessionURLBuilder.resolve`
  returns nil for a missing directory — reuse it).
- CLI noun expansion is a design-doc change (`docs/batty-cli-design.md`),
  and `docs/batty-cli-install.md`, `docs/batty-cli-agent-workflows.md`,
  the `batty-cli` skill, and `capabilities` schema tests
  (`CapabilitiesInputSchemaTests`) all need updating in step.

**Issue breakdown (milestones).**

| # | Issue | Size |
|---|---|---|
| A1 | `FeatureFlags` + variant plumbing + inertness tests (shared by every proposal; §4) | S |
| A2 | `Project` model + `ProjectStore` (file, atomic save, LRU/ordering, tests) | S |
| A3 | `AppStateStore.openProject` + `SessionRuntime.projectID` + Sidebar glyph | S |
| A4 | File ▸ Open Project submenu, Add Project… panel, Manage Projects… sheet | M (visual sign-off) |
| A5 | Sidebar "Save as Project…" / "Reveal Project in Finder" | S |
| A6 | Command Palette entries | S |
| A7 | CLI `batty project …` + XPC verbs + capabilities + docs/skill | M |
| A8 | `Concepts.md`, Help (`Help/02-sessions.md`), `docs/ui-features.md`, UI tests | S |

**Effort.** ~8 issues, mostly S; one M with visual sign-off (A4), one M
across the CLI stack (A7). Roughly 1–2 weeks of the review-gated workflow.
No dependency on open issues.

### 2.2 Proposal B — Project = root directory + Workspace: an openable, pre-arranged Session

**Concept.** Proposal A's record gains one field: `workspaceID: String?`
referencing a #0371 Workspace (built-in or user-saved). Opening the
Project creates the Session at `rootPath` *and* applies the Workspace —
e.g. Terminal on top, Git Status + Process Status below — with the Git
Status slot's `path` resolving to `rootPath`. This is "a saved,
relaunchable Session layout per directory," scoped to what #0172 allows:
topology + kinds, no ratios, no Tabs, no per-pane cwds, applied only on
explicit open.

**Vocabulary.** *Project* as in A, plus: "A Project may name a Workspace
to apply when it opens." *Workspace* is #0371's term (already user-decided).
Both go into `Concepts.md`; #0371 owns the Workspace entry.

**UX.** Everything in A, plus:

- Manage Projects… sheet: a Workspace picker column (built-ins + saved),
  reusing #0371's selector/thumbnails.
- "Save as Project…" from a multi-Pane Session offers "also save the
  current arrangement as a Workspace" (lossy: equal sizing on re-apply,
  #0371 behavior spec 6 — the one-line warning #0371 asks about).
- CLI: `batty project open` gains nothing; `batty project add --workspace <name>`.
- New Session with Workspace (File menu + hotkeys, #0371 spec 8) is
  #0371's deliverable, not this one's.

**Data model.** `Project.workspaceID: String?`. Resolution at open:
Workspace missing → open as A (plain Session) and log; never block the
open. `viewOptions` (`path`, `pid`) are never stored on the Workspace
(#0371 design question 2); Git Status re-resolves to the new Session's
cwd, which is `rootPath`, "for free" (`SplitTree.swift:274-281`,
`docs/design/git-status-view.md:120-146`).

**Feature-flag plan.** As A, plus: the Workspace column in the sheet and
the `--workspace` flag are gated by the same flag. #0371 itself ships
**unflagged** (it is a 1.3.0 feature with its own issue), or behind the
same flag if the user wants Workspaces held back too — open question 3.

**Risks.**

- **Depends on #0371 landing first** — Workspace type, selector, the
  `PaneLayout` enum → catalog refactor, the three-switch gating fix, and
  `Concepts.md` entry. That is the larger half of the work and is not
  Projects-specific.
- Terminal host / lifecycle: applying a multi-kind Workspace instantiates
  several non-terminal `PaneRuntime`s in one action — real FSEvents,
  sampling Tasks, subprocesses (`issues/0371.md:236`), with #0285's
  footprint history behind it; and it creates Panes into a possibly
  already-hidden state, the untested occlusion path #0388 identified
  (`issues/0371.md:250-259`). Both are #0371's to solve; B inherits them.
- Observation: Workspace application is a burst of `SplitTree` mutations
  from menu/XPC origin — the same category as `PaneLayout.apply` today.
  Fine, but the Session must be created *and selected* before the
  splits so placeholders mount with the right `isSessionSelected`.
- Duplicate-kind policy (`isSingletonPerSession`, deliberately unbuilt,
  `PaneContentKind.swift:43-60`) becomes user-visible once a Project can
  open two of the same view.

**Issue breakdown.**

| # | Issue | Size |
|---|---|---|
| B0 | **#0371 Workspaces** (prerequisite; ~6–8 issues on its own: Codable topology, catalog refactor, converter, selector, save sheet, three-switch gating, docs) | L |
| B1–B8 | Proposal A's A1–A8 | as A |
| B9 | `Project.workspaceID` + apply-on-open + missing-Workspace fallback + tests with inert `contentFactory` | M |
| B10 | Manage Projects… Workspace column; "Save as Project…" arrangement capture | M (visual sign-off) |
| B11 | CLI `--workspace`, capabilities, docs/skill | S |

**Effort.** A + #0371 + ~3 issues: roughly 3–5 weeks. The flagged part
(B9–B11) is small; the calendar is dominated by #0371.

### 2.3 Proposal C — Project detection + per-project settings (passive)

**Concept.** A Project is whatever directory the shell is *in*: Batty
finds the project root (nearest ancestor with `.git` or a manifest the
`ProjectNameResolver` rules recognize) and applies that root's saved
settings — name, Session color, Session theme — to the Session
automatically, the way auto-naming already applies a name. The user never
"opens" a Project; they edit a Project's settings from a Session that is
in it. Think of it as "`SessionNameCache`, generalized from
`path → name` to `root → {name, color, theme}`, with root detection."

**Vocabulary.** *Project* — a detected root directory with optional saved
settings. *Project root* — the nearest ancestor of a Terminal Session's
cwd that contains `.git` or a recognized manifest. (Adds a second concept
to Concepts.md.)

**UX.**

- Sidebar context menu: **Project Settings…** (sheet: name, color, theme,
  root shown read-only, "Forget Project") — enabled when the anchor Tab's
  cwd is inside a detected root.
- Sidebar: nothing new visually beyond the color/theme the settings
  already drive. Optional small root-relative subtitle ("~/Developer/Batty
  › src") — new UI, needs sign-off.
- Command Palette: `Project Settings…` only.
- File menu: nothing.
- CLI: `batty id` gains `projectRoot`; optionally `batty project info [--json]`.
- Settings → General → Session Naming: "Apply saved Project settings"
  toggle (default on in Beta) alongside the existing two naming toggles;
  and, if #0247 is folded in, "Read `.batty/config` from project folders"
  (default **off**, per #0247).

**Data model.** `projects.json` keyed by root path:

```swift
public struct ProjectSettings: Codable, Sendable, Hashable {
    public var rootPath: String
    public var name: String?
    public var colorIndex: Int?
    public var themeName: String?
    public var lastSeenAt: Date
}
```

Plus `ProjectRootLocator` (pure, injectable `FileManager`, walks up to a
bounded depth, stops at `$HOME` and `/`). #0247's `.batty/config` becomes
a second, repo-committed source for `name` (and nothing executable) —
precedence: user's Project Settings (local, explicit) → `.batty/config`
(repo author) → `ProjectNameResolver` → AI → `Session N`, i.e. #0247's
order with "Project Settings" replacing "`SessionNameCache`" at the top.
`SessionNameCache` would then be either migrated into `projects.json` or
left as the exact-path fallback — open question 5.

**Feature-flag plan.** Gate: root detection call inside
`applySessionAutoNaming` (flag off → chain is byte-identical to today),
Project Settings… menu item + sheet, Settings toggles, `batty id` field,
`ProjectStore` construction. The "no reads or writes of the feature's
files" rule is satisfied by never constructing the store when off.

**Risks.**

- **Observation rules, directly.** Applying color and theme from the pwd
  delegate path is still event-origin (same as the title write at
  `AppStateStore.swift:2008`), *but* theme application touches every
  surface in the Session (`applyActiveSessionTheme`, `docs/themes.md:346-416`)
  and runs inside `terminalRunOnMainNextTurn`. Today theme changes are
  menu-driven; making them cwd-driven means a `cd` can retint a whole
  Session mid-keystroke. It needs a debounce and the same stale-result
  guards as AI naming (`applySuggestedName`, `:2054-2068`).
- **Single-Pane rule (#0213).** The naming chain deliberately freezes on
  multi-Pane Sessions. Per-project *color/theme* would have the same
  ambiguity (two Panes in two projects) — so C either inherits the
  single-Pane freeze (then most real Sessions, which are split, never
  pick up settings) or picks the anchor Tab (then a split Session can
  carry a misleading color). Neither is obviously right.
- **Root detection changes naming behavior for everyone** once unflagged:
  `cd src/` would keep the project name instead of reverting to `Session N`
  (#0213's current contract). That is probably desirable but is a
  behavior change to a shipped feature with UI tests
  (`SessionCwdRenameTests`, #0416/#0436) — it must be its own issue.
- Interacts with four open/closed naming issues (#0089, #0213, #0214
  "unify create-time and live-update naming," #0247) and the AI memo.
  Highest coupling of the three proposals.
- Terminal host: none.

**Issue breakdown.**

| # | Issue | Size |
|---|---|---|
| C1 | `FeatureFlags` (shared, §4) | S |
| C2 | `ProjectRootLocator` + tests (bounded walk, `.git` file vs dir, submodules/worktrees) | S |
| C3 | `ProjectSettings` + `ProjectStore` (file, tests) | S |
| C4 | Hook root + settings into `applySessionAutoNaming`; color/theme apply with debounce and staleness guards; decide multi-Pane rule | M (observation review) |
| C5 | Project Settings… sheet + Sidebar/palette entry | M (visual sign-off) |
| C6 | Settings toggles; `#0247` `.batty/config` reader (if folded in) | M |
| C7 | Resolve #0214 (unify create-time chain) — becomes a prerequisite | S |
| C8 | `Concepts.md`, Help, `docs/foundation-models.md`, UI tests; later: root-aware naming change to #0213 contract | M |

**Effort.** ~8 issues, three M with review-heavy observation/naming
changes; 2–3 weeks. No hard dependency on #0371; soft dependency on #0214
and #0247.

### 2.4 Considered and not proposed

- **Sidebar grouped by Project (Sessions nested under Project headers).**
  Explicitly declined in `docs/supacode-feature-review.md:191` ("Batty's
  flat session list is simpler by design"), and the Sidebar already nests
  Pane rows under Sessions via `DisclosureGroup` (`SessionSidebarView.swift:45`);
  a second nesting level makes `pane-row`/`session-row` accessibility and
  drag-reorder (#0410) materially harder. Any proposal above can add a
  *badge* without regrouping.
- **Git-worktree Projects.** Declined (`supacode-feature-review.md:186`);
  worktree lifecycle is supacode's identity.
- **Per-project shell / env / startup commands.** PRD non-goal
  (`PRD.md:53`), #0247's security line, supacode review's "config-as-data"
  decline. If ever wanted it needs a direnv-style trust prompt and its own
  issue.
- **Project = restore my last Session layout for this directory.** This
  is #0172's deleted feature with a directory key. Proposal B's
  explicit-open-with-named-Workspace is the allowed shape; silent
  capture-on-quit is not.

---

## 3. Comparison and recommendation

| | A — Launcher | B — Launcher + Workspace | C — Detection + settings |
|---|---|---|---|
| One-sentence concept | Named root you can open as a Session | A, and it opens pre-arranged | Root is detected; its settings follow you |
| User-visible value | Start in a project without `cd`; stable name/color | A + the full "dev workspace" in one action | Color/theme/name without ever setting them up per Session |
| Fits PRD / supacode review | Yes (bookmarks, `batty new` evolution) | Yes, via #0371's own argument | Mostly; root-grouping avoided, but touches the naming contract |
| #0172 compatibility | Clean (user-authored, explicit) | Clean given #0371's scope (no ratios/cwds/Tabs) | Clean (settings, not layout) |
| New Concepts.md terms | Project | Project (+ Workspace from #0371) | Project, Project root |
| New UI surfaces | File submenu, 1 sheet, 2 context items, palette | A + Workspace column | 1 sheet, 1 context item, Settings toggles |
| Terminal-host risk | None | Inherits #0371's multi-view spawn + occlusion-at-creation | None |
| Observation-rules risk | Low | Low (bursty tree mutation, menu-origin) | **Medium** — cwd-driven theme/color writes, multi-Pane ambiguity |
| Coupling to open issues | None | **#0371 prerequisite** | #0213, #0214, #0247, #0436 |
| CLI change | New `project` noun (or `new --project`) | A + `--workspace` | `batty id` field only |
| Flag surface (sites to gate) | ~8 | ~10 | ~7, one of them inside the hot naming path |
| Effort | ~8 issues, 1–2 wk | #0371 + ~3 issues, 3–5 wk | ~8 issues, 2–3 wk |
| Visual sign-off items | 1 (Manage sheet) | 2 | 1–2 |

**Recommendation: ship A in 1.3.0, with B as its documented second phase,
and take the `colorIndex` idea from C into A's record now.** Reasons:

1. A is the only one whose concept needs no second term and no new
   behavior in an existing feature. It is additive, flag-gating is
   mechanical, and the terminal path is untouched — a good first exercise
   of the new flag policy.
2. B is where the feature becomes compelling, but its calendar is #0371's,
   which has its own user-decided vocabulary and open design questions.
   Designing A's `Project` record with a reserved `workspaceID` keeps B a
   two-issue follow-on instead of a rewrite, and lets #0371 proceed
   unflagged in parallel.
3. C's best idea — settings that *follow* you — collides with the
   single-Pane naming contract and would put theme writes on the pwd
   callback path. That is exactly the kind of focus/observation change
   `AGENTS.md` flags as needing extra care, and it changes shipped
   behavior under UI test. It is worth doing, but as its own line of
   issues after A, not as the definition of "Projects."
4. A's "Save as Project…" from the Sidebar is the bridge: the first time
   a user has a Session named and colored the way they like, one click
   makes it reopenable. That captures most of C's value with none of its
   ambiguity.

Suggested 1.3.0 definition if A is chosen: *"Projects: save a directory
as a named Project and reopen it as a Session from File ▸ Open Project,
the Command Palette, or `batty project open`."* Flag removed in the 1.3.0
release issue.

---

## 4. Feature-flag design (applies to whichever proposal is chosen)

### 4.1 Mechanism

```swift
// BattyKit/Sources/BattyKit/Settings/FeatureFlags.swift
public struct FeatureFlags: Sendable, Equatable {
    public var projects: Bool
    public static func resolved(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> FeatureFlags {
        FeatureFlags(projects: ServiceNames.Variant(bundleIdentifier: bundleIdentifier) == .beta)
    }
}
```

- Injected into `AppStateStore.init` as `featureFlags: FeatureFlags = .resolved()`
  next to `preferences:` (`AppStateStore.swift:970-975`), stored
  `@ObservationIgnored public let`. Views and commands read
  `store.featureFlags.projects`. Unit tests pass an explicit value; nothing
  reads `UserDefaults` for the flag (no hidden "enable in Prod" switch —
  the policy says Prod is *off*, not *off by default*).
- Resolution fails closed: an unknown bundle identifier is Prod
  (`ServiceNames.Variant.init?` returns nil → `false`), matching the three
  existing callers' fail-closed convention.
- CLI and broker use `ServiceNames.current == .beta` (compile-time
  `BATTY_VARIANT_BETA`, already wired in both Embed phases). `BattyCLI.configuration.subcommands`
  includes `ProjectNounCommand` only when true; `capabilities` therefore
  omits it automatically (`CapabilitiesCommand.swift:100`).
- App-side XPC: `AppXPCService` returns the existing unknown-verb failure
  for `project*` verbs when `featureFlags.projects` is false, so a Beta
  CLI talking to a Prod app degrades cleanly.

### 4.2 Inertness checklist (what "invisible and inert" means per site)

| Surface | Off behavior | Test |
|---|---|---|
| `ProjectStore` | Not constructed (`AppStateStore.projectStore == nil`); `projects.json` never opened | Unit: Prod flags → no file created after a full app-state exercise |
| File ▸ Open Project | Submenu absent (not disabled) | UI test (VM): menu bar has no "Open Project" in Prod-flag launch — needs a `BATTY_UI_TEST_FEATURE_FLAGS` override in `UITestDriver` since UI tests run the Beta bundle |
| Sidebar glyph / context items | Absent | Unit on row view model; UI test |
| Command Palette | No `project:` ids | Unit: `CommandPaletteView.allCommands` (already tested pattern, `CommandPaletteViewActionTests`) |
| CLI | No `project` subcommand; `capabilities` omits it | Unit: `CapabilitiesCommandTests` with/without the condition is not possible at runtime (compile-time) — assert on `ServiceNames.current` in each build's own test run instead |
| XPC | Unknown verb | Unit: `AppXPCService` with Prod flags |
| `batty id` / `status --json` | No `project` key | Unit on payload builders |
| Help (`Help/0N-*.md`) | A Projects page is **user-visible in Prod** if added; keep Help changes until flag removal, or gate the Help index | Decide (open question 10) |

Every gate site reads one symbol (`featureFlags.projects`), so "remove the
flag in the release that ships the feature" is `grep -rn
'featureFlags.projects'` plus deleting `FeatureFlags.projects` and the CLI
condition. Record the list in the implementing issue.

### 4.3 The `ShortcutAction` problem

`ShortcutAction.allCases` drives the Settings → Shortcuts list
(`ShortcutsSettingsView.swift:16`), the palette (`CommandPaletteView.swift:55`),
the NSEvent monitor (`BattyShortcuts.swift:41`), `ShortcutsStore`
persistence, and `ShortcutDocsSyncTests` (`:166-179`), which fails the
pre-commit gate if `docs/shortcuts.md` and `Help/05-shortcuts.md` do not
list every case (#0329). A flagged case would therefore either leak into
Prod's Settings and Help or require an `available(flags:)` filter in five
places plus a docs-sync exemption — the hand-copied-switch hazard
`docs/issue-work-obstacles.md:131-148` warns about.

Recommendation for phase 1: **no new `ShortcutAction` cases.** Project
actions are menu items (with no `keyboardShortcut`), palette "extra:"
entries, and CLI verbs. Shortcuts are added in the flag-removal issue, when
they can be documented normally. If the user wants a hotkey in Beta before
then, the menu item can carry a `.keyboardShortcut` that is not rebindable
— `docs/shortcuts.md:374-391` explains why menu shortcuts are not the
load-bearing path, and that is acceptable for a Beta-only affordance.

### 4.4 Rules the implementing issues must carry

- `docs/swiftui-observation-rules.md`: every Project write (`projectID`,
  `colorIndex`, `title`) originates from a menu, palette, sheet button,
  XPC request, or (C only) the pwd delegate — never from `body`,
  `onAppear`, or geometry callbacks.
- `docs/view-hierarchy.md` §4: Projects never touch `TerminalHostStore`
  or `AppTerminalView`; B's Workspace application goes through
  `SplitTree.splitPane` only.
- `docs/isolate-userdefaults-in-tests.md`: `ProjectStore` takes a
  `fileURL` and `FileManager`; tests never write the real App Support dir.
- `AGENTS.md` async tests: `ProjectStore.save()` is debounced like
  `SessionNameCache` — expose the pending `Task` for tests to await.

---

## 5. Open questions for the user

Decisions that change the proposal, not implementation details.

1. **Which proposal?** A (launcher), B (launcher + Workspace), C
   (detection + settings), or A now with B as phase 2 (recommended).
2. **Explicit or passive?** Is a Project something the user *creates*
   (A/B) or something Batty *detects* (C)? The two can coexist later, but
   the `Concepts.md` entry and the CLI shape differ.
3. **#0371 sequencing.** Should Workspaces (already user-named) ship in
   1.3.0 unflagged alongside Projects, be folded under the Projects flag,
   or wait? B is impossible without it; A is unaffected.
4. **Open semantics.** Does "Open Project" always create a new Session, or
   find-and-focus an existing Session already associated with (or rooted
   at) that Project? `batty pane split --unique` set a find-or-create
   precedent for views (#0383).
5. **Relationship to `SessionNameCache`.** Keep it as-is (A), or fold it
   into `projects.json` as the per-directory record (C)? Migration of
   `session-name-cache.json` is implied by the latter.
6. **Relationship to #0247 `.batty/config`.** Fold it into Projects as
   the repo-authored source of `name` (and only `name`), keep it a
   separate issue, or close it in favor of App-Support-only settings?
7. **CLI grammar.** Add a `project` noun (`batty project open|list|add|remove`),
   or keep the four-noun rule from `docs/batty-cli-design.md:38` and
   extend `batty new --project <name>` / `batty list --projects`?
8. **Pinning.** Does opening a Project pin the Session's title and color
   (`titleOverride`/`colorOverride = true`, so `cd` elsewhere never
   renames it), or leave them automatic so the Session keeps tracking
   cwd? Recommended: pin — a Project is an explicit choice.
9. **Project identity.** Exact path only, or should two paths inside the
   same git repository count as one Project (worktrees, monorepo
   subdirectories)? Affects C heavily, A barely.
10. **Help content.** May a "Projects" Help page ship in Prod ahead of the
    feature (it would describe something invisible), or is Help gated too?
11. **Sidebar presentation.** Is a tinted glyph on an associated Session
    row enough, or do you want a visible Project badge/subtitle (new UI,
    visual sign-off)? Flat list stays flat either way.
12. **Theme per Project.** Should a Project remember a Session theme
    (`localThemeName`) and apply it on open? Cheap in A; it is the
    riskiest part of C.
