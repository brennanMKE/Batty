# Feature flags

Unfinished features land on `main` behind a flag until the release that ships them (`AGENTS.md`, "Release branches"). With the flag off a feature is invisible and inert: no menu, Command Palette, Sidebar or CLI entry points, and no reads or writes of the feature's files.

The policy is **on in Batty Beta, off in Prod**. It is derived from the variant alone. There is no `UserDefaults` switch and no way to enable a flag in Prod.

`FeatureFlags` lives in `BattyKit/Sources/BattyXPCCore/FeatureFlags.swift` because both `BattyKit` and the `batty` CLI link that target. Today it has one flag, `projects`.

## Resolution paths

- **App and BattyKit (runtime).** `FeatureFlags.resolved(bundleIdentifier:environment:)` maps `Bundle.main.bundleIdentifier` through `ServiceNames.Variant`. A nil or unknown identifier fails closed to off and logs an error. `AppStateStore.init` takes `featureFlags:` (default `.resolved()`) and stores it as `store.featureFlags`. Views, commands, the palette and XPC handlers read `store.featureFlags.projects`. Unit tests pass an explicit value.
- **CLI (compile time).** The `batty` binary has no `Info.plist`, so it uses `FeatureFlags.current`, derived from `ServiceNames.current` (set by `-DBATTY_VARIANT_BETA` in the "Embed CLI" build phase). Under `swift test` it is always off. Code that branches on it takes the flag as a parameter so tests can exercise both branches.

## UI-test override

UI tests run against the Beta bundle, so the flag is on. To prove flag-off inertness, set `BATTY_UI_TEST_FORCE_PROJECTS_OFF=1` together with the UI-test driver variable `BATTY_UI_TEST_SCRIPT`. The override is read only when `BATTY_UI_TEST_SCRIPT` is present, and it can only force a flag off, never on.

## Gate sites

Each Projects child appends the files and symbols it gates here. Removing the flag means deleting `FeatureFlags.projects`, fixing the compile errors, and checking this list.

| Site | Gate | Issue |
|---|---|---|
| `AppStateStore.projectStore` (`BattyKit/Sources/BattyKit/Runtime/AppStateStore.swift`) | nil, and `projects.json` never opened, read or created, unless `featureFlags.projects` | #0471 |
| `AppStateStore.openProject(id:mode:)` (`BattyKit/Sources/BattyKit/Runtime/AppStateStore.swift`) | logs and throws `ProjectOpenError.featureDisabled`; creates nothing | #0472 |
| `UITestDriver` intents `seedProject`, `openProject` (`BattyKit/Sources/BattyKit/Testing/UITestDriver.swift`) | log and return unless `featureFlags.projects` | #0472 |
| `SessionRow` folder glyph (`BattyKit/Sources/BattyKit/Views/SessionSidebarView.swift`) | shown only when `featureFlags.projects` and `session.projectID != nil` | #0472 |
