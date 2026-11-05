# Feature flags

Unfinished features land on `main` behind a flag until the release that ships them (`AGENTS.md`, "Release branches"). With the flag off a feature is invisible and inert: no menu, Command Palette, Sidebar or CLI entry points, and no reads or writes of the feature's files.

One flag exists today, listed under "Current flags". This page is also the recipe for the next one.

## Policy

**On in Batty Beta, off in Prod**, derived from the variant alone. There is no `UserDefaults` switch and no way to enable a flag in Prod.

## How to add a flag

Add a `FeatureFlags` struct (one `Bool` per flag) in `BattyKit/Sources/BattyXPCCore/`, because both `BattyKit` and the `batty` CLI link that target. Give it two resolution paths:

- **App and BattyKit (runtime).** A `resolved(bundleIdentifier:environment:)` that maps `Bundle.main.bundleIdentifier` through `ServiceNames.Variant`. A nil or unknown identifier fails closed to off and logs an error. `AppStateStore.init` takes a `featureFlags:` parameter (default `.resolved()`) and stores it as `store.featureFlags`. Views, commands, the palette and XPC handlers read `store.featureFlags`. Unit tests pass an explicit value.
- **CLI (compile time).** The `batty` binary has no `Info.plist`, so a `current` property derives the value from `ServiceNames.current` (set by `-DBATTY_VARIANT_BETA` in the "Embed CLI" build phase). Under `swift test` it is always off, so code that branches on it takes the flag as a parameter and tests exercise both branches.

UI tests run against the Beta bundle, so a flag is on there. To prove flag-off inertness, add an environment override that is read only when the UI-test driver variable `BATTY_UI_TEST_SCRIPT` is present and that can only force a flag off, never on.

Record each gate site (file, symbol, what the flag changes) as you add it, so removing the flag is "delete the property, fix the compile errors, check the list". Delete the flag in the release that ships the feature, along with its flag-off tests.

## Current flags

`FeatureFlags` is in `BattyKit/Sources/BattyXPCCore/FeatureFlags.swift`.

- `sharedProjectImages` (#0551): a Shared Project's background image is copied through an iCloud Drive folder. It has no CLI `current` because the CLI doesn't read it, and no UI-test override because a UI-test build has no entitlement and so has no transport. Remove it in the release that ships the feature, after the user has run U1 to U8 in `issues/0551.md`. Gate sites:
  - `AppStateStore.defaultSharedImageTransport`: no transport, so no shared folder is read or written, unless the flag is on.
  - `ProjectStore.sharedImagesEnabled`: true only with a transport. False keeps records, merges and `projects.json` as they were.
  - `BattyKit/Sources/BattyKit/Help/10-projects.md` keeps "choose the image on each Mac" until the flag goes, because Help ships in Prod. Update that sentence when removing the flag.

## Retired flags

- `projects`: added in #0470, removed in 1.3.0 by #0504. Projects is always on in Prod and Beta.
- `terminalBackgrounds`: added in #0374, removed in 1.3.5 by #0544. Terminal backgrounds and see-through are always on in Prod and Beta.
