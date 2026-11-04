# Feature flags

Unfinished features land on `main` behind a flag until the release that ships them (`AGENTS.md`, "Release branches"). With the flag off a feature is invisible and inert: no menu, Command Palette, Sidebar or CLI entry points, and no reads or writes of the feature's files.

This page is also the recipe for the next flag.

## Current flags

- `terminalBackgrounds` (`BattyKit/Sources/BattyXPCCore/FeatureFlags.swift`, #0374): terminal backgrounds, per-Pane, per-Session and app-wide, while umbrella #0372 is unfinished. Flag-off override: `BATTY_UI_TEST_FORCE_BACKGROUNDS_OFF`. There is no `current`, because the CLI has no entry point. Gate sites:
  - `SessionSidebarView.body` passes `store.featureFlags.terminalBackgrounds` to `PaneRow.showsBackgroundSettings`, which shows the gear.
  - `SessionSidebarView.backgroundSettingsBinding` returns `nil` when off, so the sheet can't present.
  - `SessionSidebarView.body` passes `store.featureFlags.terminalBackgrounds` to `SessionRow.showsBackgroundSettings`, which shows the Set and Clear Session Background menu items (#0376).
  - `SessionSidebarView.sessionBackgroundBinding` returns `nil` when off, so the Session's sheet can't present (#0376).
  - `AppearanceSettingsView.body` in `SettingsView.swift` omits `TerminalBackgroundSettingsSection` when off.
  - `AppStateStore.isWindowSeeThrough` returns `false` when off, so the window stays opaque (#0539).
  - `AppStateStore.openProject` neither inspects a Project's image nor seeds the Session when off (#0540). `Project`, `ProjectDraft`, `ProjectStore` and the sync types never read the flag, so a saved background survives.
  - `AppStateStore.projectEditorDidClose` doesn't reclaim Project image copies when off (#0540).
  - `ProjectEditorWindowController.prepare` passes no `ProjectBackgroundLibrary` when off, so the editor has no Background row and reads no image (#0540).
  - `SaveSessionAsProject.draft` (`captureBackground`) captures nothing and copies nothing when off (#0540).
  - `AppWideBackgroundGate.live` is built from `FeatureFlags.resolved()`. Disabled, it returns `.off` before touching `UserDefaults` or the disk, and it is the only route from the persisted background keys to a config builder.

  The sheet, the Settings section and `ProjectBackgroundLibrary` are the only users of `TerminalBackgroundImageImporter`; `SaveSessionAsProject` only calls `ProjectBackgroundLibrary.adopt`. In production, `PaneRuntime.setBackgroundOverride` and `SessionRuntime.setBackgroundOverride` are called only by `BackgroundOverrideEditor`, the Clear Session Background item and `WindowRuntime.addProjectSession`, and `SplitTree` mirrors the Session's value to its Panes, which is a no-op for `nil`. So with the flag off no override exists, no background key is read, and no image file is read or written. `Help/10-projects.md` doesn't mention a Project's background, because it ships in Prod: when this flag is removed, add that section.

## Policy

**On in Batty Beta, off in Prod**, derived from the variant alone. There is no `UserDefaults` switch and no way to enable a flag in Prod.

## How to add a flag

Add a `FeatureFlags` struct (one `Bool` per flag) in `BattyKit/Sources/BattyXPCCore/`, because both `BattyKit` and the `batty` CLI link that target. Give it two resolution paths:

- **App and BattyKit (runtime).** A `resolved(bundleIdentifier:environment:)` that maps `Bundle.main.bundleIdentifier` through `ServiceNames.Variant`. A nil or unknown identifier fails closed to off and logs an error. `AppStateStore.init` takes a `featureFlags:` parameter (default `.resolved()`) and stores it as `store.featureFlags`. Views, commands, the palette and XPC handlers read `store.featureFlags`. Unit tests pass an explicit value.
- **CLI (compile time).** The `batty` binary has no `Info.plist`, so a `current` property derives the value from `ServiceNames.current` (set by `-DBATTY_VARIANT_BETA` in the "Embed CLI" build phase). Under `swift test` it is always off, so code that branches on it takes the flag as a parameter and tests exercise both branches.

UI tests run against the Beta bundle, so a flag is on there. To prove flag-off inertness, add an environment override that is read only when the UI-test driver variable `BATTY_UI_TEST_SCRIPT` is present and that can only force a flag off, never on.

Record each gate site (file, symbol, what the flag changes) as you add it, so removing the flag is "delete the property, fix the compile errors, check the list". Delete the flag in the release that ships the feature, along with its flag-off tests.

## Retired flags

- `projects`: added in #0470, removed in 1.3.0 by #0504. Projects is always on in Prod and Beta.
