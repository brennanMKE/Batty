# Batty docs

Topical guides for engineers working on Batty. Read these alongside the
top-level project documents at the repo root (`PRD.md`, `Concepts.md`,
`CLAUDE.md`, `batty-getting-started.md`).

## Available

- [`view-hierarchy.md`](view-hierarchy.md) — how the model hierarchy
  (Workspace -> Window -> Session -> Pane -> Tab -> Terminal Session) maps
  onto the SwiftUI tree and the persistent AppKit terminal host. Read this
  first before touching anything in the terminal / pane / window path.
- [`terminal-pane-requirements.md`](terminal-pane-requirements.md) — the
  non-negotiable behaviors every pane must preserve: pointer input, keyboard
  input, file/text drop onto the terminal, overlay rules, and the AppKit
  z-order constraint that makes pane-area feature work tricky. Read this
  before adding any gesture, overlay, or drag handler to the pane body.
- [`shortcuts.md`](shortcuts.md) — keyboard shortcut routing,
  persistence, the recorder UI, reserved combos, and why menu
  shortcuts aren't the load-bearing path. Read this before touching
  `BattyShortcuts`, the NSEvent monitor in `BattyAppDelegate`, or the
  Settings → Shortcuts pane.
- [`themes.md`](themes.md) — where themes come from (the
  `brennanMKE/libghostty-spm` catalog), how the active theme is
  persisted in `UserDefaults`, how new tabs pick it up, and how
  selection propagates live to every surface without a PTY restart.
  Read this before touching the Theme menu, `ThemePreference`,
  `TabRuntime.activeTheme()`, or `applyThemeToAllSurfaces`.
- [`nsviewrepresentable-state-persistence.md`](nsviewrepresentable-state-persistence.md)
  — patterns for keeping `NSView` state alive across SwiftUI rebuilds. The
  load-bearing reference for the terminal host architecture.
- [`delegate-plumbing.md`](delegate-plumbing.md) — historical decision doc
  for unblocking the `TerminalSurfaceViewDelegate` gap in
  `Lakr233/libghostty-spm`. Records Path C (fork the package) as the chosen
  unblock; relevant when re-evaluating the `brennanMKE/libghostty-spm`
  fork relationship.
- [`notifications.md`](notifications.md) — bell capture pipeline, the
  bell feed, system notifications, per-session mute, focus/auto-clear,
  and tab-close cleanup. Read this before touching `BellFeedStore`,
  `BellNotifier`, the bell routing in `AppStateStore`, or the
  Settings → Notifications pane.
- [`source-layout.md`](source-layout.md) — how `BattyKit/Sources/BattyKit/`
  is grouped into folders by concern (`Views/`, `Runtime/`, `Model/`,
  `Commands/`, `Theme/`, `Settings/`, `Updater/`, `Util/`). Read this
  before adding a new Swift file to BattyKit so it lands in the right
  folder.
- [`localization.md`](localization.md) — where user-facing strings live
  (`Batty/Localizable.xcstrings`), how SwiftUI auto-extraction works for
  this project, the `Text(verbatim:)` rule for the product name, and the
  `xcodebuild -exportLocalizations` / `-importLocalizations` workflow for
  translators. Read this before touching any user-facing literal or
  filing a per-language localization issue.
- [`VisualDebugging.md`](VisualDebugging.md) — how to use `build.sh` and
  `screenshot.sh` to build, launch, and capture screenshots of the Beta
  build from the command line without opening Xcode.
- [`ui-features.md`](ui-features.md) — the authoritative behavioral reference
  for all major UI feature areas: drag-and-drop, tab and session rename, theme
  application, layout picker, bell feed, tab chip rendering, workspace
  persistence, settings sheet, sidebar toggle, fuzzy finders, and modal
  confirmation flows. Covers invariants, regression history, and accessibility
  identifiers for each area. Read this before modifying any of those features
  or their UI tests.
