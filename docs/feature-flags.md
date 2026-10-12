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
| `AppStateStore.requestOpenProject(id:mode:contentFactory:completion:)`, `resolveStartupTrust`, `armStartupCommands(of:in:)` (`BattyKit/Sources/BattyKit/Runtime/AppStateStore+ProjectStartup.swift`) | fail with `ProjectOpenError.featureDisabled` (open), or return (arm) unless `featureFlags.projects`; no `projects.json` access | #0473 |
| `SessionDetailView.startupTrustBinding` (`BattyKit/Sources/BattyKit/Views/SessionDetailView.swift`) | the startup-command trust sheet never presents unless `featureFlags.projects` | #0473 |
| `ProjectEditorWindowController.prepare(store:selecting:newDraft:)` / `show(...)` (`BattyKit/Sources/BattyKit/Views/ProjectEditorWindowController.swift`) | return false and create no `NSWindow`, view model or `ProjectStore` unless `ProjectEditorWindowController.isAvailable(featureFlags:)`, which reads `featureFlags.projects`. The editor is an AppKit-managed window, not a SwiftUI scene, so nothing exists to list in the Window menu with the flag off | #0474 |
| File ▸ Edit Projects… (`BattyCommands`, `BattyKit/Sources/BattyKit/Commands/BattyCommands.swift`) | the item, and the divider that opens the Projects group, are built only when `ProjectEditorWindowController.isAvailable(featureFlags: store.featureFlags)` (the same condition `projectFileMenu` uses, so the group is all-or-nothing) | #0474 |
| File ▸ Open Project › (`BattyCommands.projectFileMenu`, `BattyKit/Sources/BattyKit/Commands/BattyCommands.swift`; items from `ProjectFileMenuModel` in `Model/ProjectFileMenu.swift`) | `ProjectFileMenuModel.make` returns nil, so the submenu, Choose Project… and New Project… are not built, unless `featureFlags.projects`; `store.projectStore` is read only past that gate | #0475 |
| `CommandPaletteView.allCommands` (`BattyKit/Sources/BattyKit/Views/CommandPaletteView.swift`) | the `project:<uuid>` and `extra:openProjectPicker` entries, and the `store.projectStore` read behind them, exist only when `store.featureFlags.projects` | #0475 |
| `SessionDetailView` Project picker (`projectPickerBinding`, the `.battyToggleProjectPicker` handler; `BattyKit/Sources/BattyKit/Views/SessionDetailView.swift`) | the toggle notification is ignored and the sheet never presents unless `featureFlags.projects` | #0475 |
