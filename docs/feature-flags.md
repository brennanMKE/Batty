# Feature flags

Unfinished features land on `main` behind a flag until the release that ships them (`AGENTS.md`, "Release branches"). With the flag off a feature is invisible and inert: no menu, Command Palette, Sidebar or CLI entry points, and no reads or writes of the feature's files.

There are no flags today. This page is the recipe for the next one.

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
