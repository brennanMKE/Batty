# BattyUITests

XCUITest target for end-to-end regression coverage of the SwiftUI / AppKit
shell. Tests launch the real app and drive it through the accessibility
identifiers wired into the production views.

## Running locally

```bash
xcodebuild -scheme Batty -destination 'platform=macOS' test
```

The first run pulls SwiftPM dependencies and takes longer. Subsequent
runs are fast — a single smoke test runs in well under a minute.

## What the launch flag does

Each test sets the `BATTY_UI_TEST_MODE=1` environment variable via
`XCUIApplication.launchEnvironment`. Production code reads it through
`QuitConfirmation.isInUITestMode`. When set, `shouldQuitOrPrompt`
short-circuits to `true` so the modal "Quit Batty?" alert never appears
during teardown — `xcodebuild test`'s terminate sequence can't dismiss a
modal, so without the bypass the run hangs with "Failed to terminate
co.sstools.Batty" errors.

## Accessibility identifiers

Production views carry these identifiers so XCUITest can find them
deterministically:

| Identifier pattern | View |
|---|---|
| `session-sidebar` | The List in `SessionSidebarView`. |
| `session-row.<title>` | A row in the session sidebar, keyed by the visible title. |
| `tab-bar.<paneID>` | The SlidingTabBar inside a `PaneView`. |
| `tab-chip.<title>` | A single chip inside a tab bar. |
| `pane-terminal.<paneID>` | The terminal placeholder area inside a pane. |
| `toolbar.split-horizontal` / `toolbar.split-vertical` | Toolbar split buttons. |

Add new identifiers as you write new tests; keep them stable so the
test suite doesn't break on innocuous UI shuffles.

## Sentinel-file pattern

XCUITest can't read terminal text — libghostty renders via Metal and
XCUI sees opaque pixels. The escape hatch is a sentinel file:

1. Test calls `BattyUITestHarness.sentinelPath(named: "command-finished")`.
2. Test types `echo done > <path>` into the focused terminal.
3. Test calls `BattyUITestHarness.waitForFile(at: path, timeout: 5)`.
4. Tests clean up via `BattyUITestHarness.sweepSentinels()` in `tearDown`.

Sentinels live under `NSTemporaryDirectory()` with the
`batty-ui-test-` prefix so they're easy to find and clear.

## Adding tests

`Support/BattyUITestHarness.swift` carries the shared helpers (launch,
sidebar/row/chip lookups, sentinel utilities). Reach for those before
hand-rolling a new lookup.

Tests should target stable, user-visible behavior — not internals. If a
test starts asserting against view-internal coordinates or rebuild
timings, rewrite it against an accessibility identifier.
