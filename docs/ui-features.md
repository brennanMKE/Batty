# UI feature reference

This document is the authoritative reference for each major UI feature area in
Batty. Read it before modifying any of the behaviors listed here: drag-and-drop,
tab and session rename, theme application, layout picker, bell feed, tab chip
rendering, settings sheet, sidebar toggle, fuzzy finders,
and modal confirmation flows. Each section describes what the feature does, the
invariants it must preserve, the regression history that established those
invariants, and the accessibility identifiers used for test assertions. Issue
numbers are written in brackets (e.g., `[0159]`) and refer to the files in
`issues/`.

The test suite that exercises all eleven areas spans issues `[0159]`–`[0169]`.
Those issues are the primary source of record for test-case rationale;
this document summarizes the behavioral intent and constraints that make those
test cases meaningful.

---

## Drag-and-drop

Batty supports two kinds of drag-and-drop: **file drops** onto the terminal
surface and **pane swaps** within or across Sessions. File drops are handled
entirely by the `NSDraggingDestination` registration on the terminal NSView
(libghostty's `AppTerminalView`). Pane swaps use Batty's own drag source
(`pane-drag-handle.<paneID>`) and drop target (`PaneSwapDropZone`), which
live in the SwiftUI tree and must co-exist with the AppKit terminal surface.

The worst regression history in the project lives here: `[0022]`, `[0023]`,
`[0102]`, `[0127]`, `[0143]`, `[0144]`, `[0145]`, `[0156]`. See
`terminal-pane-requirements.md` for a detailed treatment of the AppKit z-order
constraint that makes pane-area drag features difficult.

**Invariants:**

- File drops from Finder onto the terminal area must reach the terminal NSView's
  `NSDraggingDestination` implementation. Any SwiftUI overlay or `.onDrop`
  handler placed above the terminal NSView in AppKit z-order will intercept the
  drag session regardless of the declared UTTypes. New overlays must use
  `.allowsHitTesting(false)`.
- Pane-swap drop zones (`PaneSwapDropZone`) must only mount for Panes in the
  currently selected Session. Zones mounted on Panes in non-selected Sessions
  must not be present in the SwiftUI tree during a drag. The zone count for the
  active Session is `N - 1` (every Pane except the dragging source).
- A self-drop (dropping a Pane onto itself) is a no-op. No model change occurs.
- A pane swap must preserve focus: the Pane that was focused before the swap is
  still focused after it (now at its new position in the Split tree).
- File drops on non-terminal areas (e.g., the Sidebar) must be no-ops; no shell
  input is sent.
- The pane-swap drag must not initiate from within `SlidingTabBar`'s gesture
  recognizers. The drag handle (`pane-drag-handle.<paneID>`) must win the
  priority race over child gestures.

**Regression patterns:**

- `[0102]` — File drops stopped working after the persistent-host migration
  because `TerminalHostView` lost its `NSDraggingDestination` registration.
- `[0127]` — Pane drag never initiated because `SlidingTabBar` child gestures
  won the priority race against the container `.onDrag`.
- `[0143]` — Drop zone highlight was unreliable because `.onDrop` sat below the
  terminal NSView in AppKit z-order.
- `[0144]` — File drops were broken by an overlay introduced to fix `[0143]`.
  The fix for one regression introduced a new regression in the same area.
- `[0156]` — Cross-session drop silently no-oped because drop zones mounted on
  every Pane in every Session rather than only in the active Session.

**Accessibility identifiers:**

- `pane-drag-handle.<paneID>` — the drag source handle on each Pane.
- `pane-drop-zone.<paneID>` — on `PaneSwapDropZone`; used to assert that a
  drop zone is present (and visible as a mid-drag highlight) during a pane swap.
- `pane-terminal.<paneID>` — the terminal surface area; `accessibilityValue`
  transitions to `"drag-hover"` while a file drag hovers over the Pane and
  reverts to `"unfocused"` or `"focused"` on exit.

**Out of scope:** cross-window drag (gated on multi-window work); drag-to-detach
a Pane; image/sixel drops (handled internally by libghostty).

---

## Tab and session rename

Both Tabs and Sessions carry user-editable titles. The rename flow uses a sheet
(triggered via the context menu or a toolbar action) that commits on Return and
dismisses on Cancel or Escape. Once committed, the user-set title is the
`override` and takes precedence over all other title sources.

Title resolution follows a defined precedence chain for both Tabs and Sessions.
For a **Tab**: user override > resolver-derived name > shell-reported title
(via OSC 1/2) > cwd basename > `"~"` for `$HOME`. For a **Session**: user
override > resolver-derived name > cwd basename > `Session N`. Shell-reported
titles must not overwrite a user-set override.

The **Reset Title** command (for Tabs) and **Reset Name** command (for Sessions)
clear the override and return the title to whatever the resolver or shell
currently provides.

A name cache at `~/Library/Application Support/Batty/session-name-cache.json`
records the most recent user-chosen Session title per working directory. When a
new Session opens in a directory that matches a cached entry, the cached name is
applied automatically. Writes are atomic and debounced; the cache is capped at
100 entries with LRU eviction. Default `Session N` names are not written to the
cache.

**Invariants:**

- A user-set Tab title override survives shell title changes sent via OSC 1/2.
  Receiving a new OSC title while an override is active must not update the chip.
- A user-set Session title override survives OSC title changes from any Tab in
  that Session.
- Reset Title/Reset Name returns the title to the resolver-derived or shell
  value, not to the previous override.
- Reset Name in `$HOME` must fall back to the home directory's basename (e.g.,
  `brennan`), not to the literal `"~"`.
- An empty rename (no text entered) must be treated as a no-op or as a clear,
  per the chosen spec; the behavior must be consistent and tested.
- Three Tabs in three different cwds must produce three distinct chip titles.
  All chips showing the same title (e.g., `user@host`) is a bug.
- The name cache must only write entries when the user explicitly chose a name;
  it must not cache `Session N` or other auto-generated titles.

**Regression patterns:**

- `[0157]` — Rename Tab sheet accepted input and dismissed, but the chip title
  stayed on the shell title. The override was not propagated to the chip.
- `[0153]` — Reset Name was disabled in the wrong context, making it impossible
  to clear a manually-set Session name.
- `[0142]` — A Tab at `$HOME` always showed `"~"`, ignoring any set override.
- `[0089]` — Auto-naming from project artifacts; introduced resolver + override
  interaction that had ordering bugs.
- `[0058]` — Per-directory name cache. Introduced the `session-name-cache.json`
  mechanism; regressions here cause sessions to lose their auto-applied names.
- `[0043]` — Session sidebar row overwrote the user-set name with the live shell
  title. An OSC title update must not overwrite a user-set Session name.
- `[0050]` — All Tab chips showed the same `user@host` string because title
  resolution used a shared state rather than per-Tab cwd.

**Accessibility identifiers:**

- `tab-chip.<title>` — the chip for each Tab; identifier contains the displayed
  (possibly truncated) title.
- `tab-chip-title-source` — `accessibilityValue` on each chip: `"override"`,
  `"resolver"`, or `"shell"`. Indicates why a particular title is shown.
- `session-row.<title>` — the sidebar row for each Session.
- `session-row-title-source` — `accessibilityValue` analogous to
  `tab-chip-title-source`.

---

## Theme application

Batty uses a two-tier theme system: a **global theme** that applies app-wide,
and an optional **session-local override** that applies to one Session. The
fallback chain is: `session.localThemeName` → `ThemePreference` (global,
stored in `UserDefaults`) → `TerminalTheme.default` (libghostty's built-in).

The global theme is set from the Theme menu (`Cmd-Shift-T`) or Settings →
Appearance. The session-local override is set from `SessionThemeSelectorView`
(accessible from the sidebar context menu). Applying any theme calls
`setTheme(_:)` on each affected libghostty surface in place; no PTY restart or
NSView teardown occurs.

See `themes.md` for the complete treatment of the theme catalog, persistence
format, new-tab initialization path, the `applyThemeToAllSurfaces` walk, and
the developer workflow for adding themes.

**Invariants:**

- The global theme persists across launches (stored as a name string in
  `UserDefaults` under `ThemePreference.defaultsKey`).
- Selecting a new global theme immediately repaints all Sessions whose
  `localThemeName` is `nil`. Sessions with a local override are not touched.
- A session-local override takes precedence over the global theme for that
  Session. Changing the global theme does not affect overridden Sessions.
- A new Session or Tab inherits the global theme at construction time. It must
  not inherit the previous Session's local override.
- Clearing a local override (setting `localThemeName = nil`) causes the Session
  to immediately pick up the current global theme.
- The session-local override is not persisted. Every launch starts all Sessions
  with `localThemeName = nil`.
- `applyThemeToAllSurfaces` must not write `localThemeName` on any Session.
- Window chrome (toolbar, sidebar, pane borders, split dividers, tab bars) must
  visually reflect the active Session's effective theme. Chrome is updated via
  `applyActiveSessionTheme()` on every Session switch.

**Regression patterns:**

- `[0033]` — Initial Theme menu wiring. The resolved theme on a surface was not
  updated when the menu selection changed.
- `[0135]` — Window chrome did not change with the active theme.
- `[0137]` — Theme selector sheet filter and color grid had wiring breaks.
- `[0138]` — Pinned themes did not surface in the pinned section of the
  selector.
- `[0139]` — Per-session theme override did not apply; both Sessions showed the
  global theme.
- `[0147]` — New Sessions did not auto-apply the persisted global theme.
- `[0149]` — The global/local fallback chain was not implemented correctly;
  global theme changes affected overridden Sessions.

**Accessibility identifiers:**

- `accessibilityValue("theme=<name>")` on: toolbar root, sidebar root, each
  Pane border, each split divider, each Tab bar. Used to assert which theme is
  currently applied to each chrome surface.
- `theme-selector.root` — the selector sheet root view.
- `theme-selector.filter` — the search field inside the sheet.
- `theme-row.<name>` — each row in the selector list.
- `theme-row-pin.<name>` — the pin button on each row.
- `theme-selector.pinned-section` — the pinned-themes subgroup.

---

## Layout picker

The layout picker creates multi-pane Sessions in one action from a set of
predefined presets (e.g., `twoByTwoGrid`, `mainLeftTwoRight`,
`mainTopTwoBottom`, `threeColumn`, `twoColumn`, `twoRow`). It is exposed as a
toolbar button and as an entry in the Session menu. Applying a preset replaces
the current Session's Split tree with the preset's structure; all new Panes
inherit the cwd of the focused Pane at picker time.

The picker is gated: it is enabled only for Sessions with a single Pane. When
the Session already has more than one Pane, the picker element must be disabled
(or hidden, per the implementation choice). The Session menu entry must always
be present regardless of gating state.

**Invariants:**

- Each preset produces a deterministic Pane count and Split tree structure.
  The tree shape can be expressed as an S-expression string (e.g.,
  `H(V(L,L),L)`) via the `dumpSplitTree` driver intent.
- All Panes created by a layout preset inherit the cwd of the focused Pane at
  the moment the picker was invoked, not `$HOME`.
- After applying a layout, exactly one Pane has `accessibilityValue == "focused"`.
- The picker is disabled (or absent) when the active Session has more than one
  Pane.
- The Session menu item with identifier `menu.session.layout-picker` is always
  present.

**Regression patterns:**

- `[0148]` — All Panes created by the picker opened at `$HOME` instead of the
  focused Pane's cwd. The cwd was not propagated from the focused Pane through
  the preset instantiation path.
- `[0152]` — The picker was not disabled for multi-pane Sessions and was not
  surfaced in the Session menu.
- `[0136]` — Initial picker wiring; the chosen layout was not applied.

**Accessibility identifiers:**

- `layout-picker.button` — the toolbar button that opens the picker popover.
- `layout-picker.row.<layoutName>` — each preset row inside the popover.
- `menu.session.layout-picker` — the Session menu item.

---

## Bell feed

The Bell Feed is the app-wide, ordered list of recent bell events across every
Terminal Session. It is presented as a popover (fixed size `360 × 420`) anchored
on the toolbar bell button or invoked via the `Cmd-Shift-B` shortcut (per
`[0134]`). The bell button displays the `bell.badge` SF Symbol when there are
unseen entries and `bell` when the feed is clean.

A bell event originates in one of two forms: an ASCII BEL byte (`\a`) or an
OSC 9 / OSC 777 desktop notification escape. Either kind flows through
libghostty's delegate callbacks into `TabRuntime`, then into `AppStateStore`,
which records a `BellFeedEntry`, propagates unseen counters up the
Session → Pane → Tab hierarchy, and optionally posts a macOS desktop
notification.

See `notifications.md` for the full bell capture pipeline, the `isFocused` gate
on unseen counts, the auto-clear-on-focus mechanism, cleanup-on-tab-close, per-
session mute behavior, and the app-wide notification settings.

**Invariants:**

- A BEL from a Tab that is not currently focused (selected Session, focused
  Pane, active Tab — all three) increments unseen counters at every level:
  `tab.unseenBellCount`, `pane.unseenBellCount`, `session.unseenBellCount`.
- A BEL from the currently focused Tab is recorded to the feed but does not
  increment any unseen counter.
- The chip dot (`hasUnseen`) on a Tab chip, the Pane border dot, and the sidebar
  Session badge must all reflect the aggregate unseen bell count at their
  respective levels.
- Per-session mute suppresses macOS desktop notifications for that Session only.
  The Bell Feed entry, chip dot, Pane badge, and sidebar badge all continue to
  update regardless of mute state.
- Clicking a Bell Feed entry (or tapping its macOS notification) invokes the
  click-to-jump flow: make the source Window key, select the source Session,
  focus the source Pane, activate the source Tab, mark the entry seen.
- Navigating to a Tab (via sidebar selection, pane focus change, or tab
  activation) must clear unseen bells for that Tab. `markActiveTabSeen()` runs
  on every focus-changing path.
- Closing a Tab must remove all Bell Feed entries that reference it and
  decrement the corresponding aggregate counters.
- Closing a Session must remove all Bell Feed entries referencing any Tab in
  that Session.
- The feed is capped at 200 entries (oldest evicted first). Aggregate counters
  are zeroed via residual sweep when evicted entries were still unseen.
- The `toggleBellFeed` shortcut (default `Cmd-Shift-B`, per `[0134]`) must open
  the Bell Feed popover. The shortcut is customizable in Settings → Shortcuts.

**Regression patterns:**

- `[0024]` / `[0025]` — Initial bell capture and propagation were not wired.
- `[0026]` — Bell Feed popover UI was not wired.
- `[0027]` — Click-to-jump did not navigate to the correct Session/Pane/Tab.
- `[0028]` — Visual indicators (chip dot, sidebar badge) were not updated.
- `[0068]` — Per-session mute was documented to exist in the sidebar context
  menu but was not implemented there.
- `[0069]` — Navigating to a bell's Pane did not clear its unseen badge.
- `[0071]` — Closing a Pane did not remove Bell Feed entries referencing it;
  aggregate counts drifted.

**Accessibility identifiers:**

- `bell-feed.popover` — the popover root.
- `bell-feed.entry.<id>` — each entry row; `accessibilityValue` contains the
  message text.
- `accessibilityValue("bell-pending" / "clear")` on `tab-chip.<title>`,
  `pane-terminal.<id>`, and `session-row.<title>`.
- `menu.sidebar.mute-session.<title>` — the mute/unmute item in the Session
  sidebar context menu.

---

## Tab chip rendering

Each Tab is represented in its Pane's tab bar by a chip rendered by the
`SlidingTabs` Swift package. Chips must fit inside the Pane's bounds, truncate
their titles to fit available width, and always leave the `+` button
hit-testable. The tab bar width must not overflow into an adjacent Pane.

Title resolution for the chip display follows the same precedence as the Tab
rename system: user override > resolver-derived name > shell-reported title
(OSC 1/2) > cwd basename > `"~"` for `$HOME`. The chip's accessibility
identifier uses the displayed (possibly truncated) title, and the full
untruncated title is exposed via `accessibilityLabel` for assertions.

**Invariants:**

- The `tab-bar.<paneID>` frame width must never exceed the `pane-terminal.<paneID>`
  frame width. Chips must not cross the Pane's trailing edge into the adjacent
  Pane.
- No `tab-chip.<title>` element may have a frame whose right edge crosses the
  split divider's x-coordinate.
- The `add-tab-button.<paneID>` element must remain hit-testable (clickable via
  XCUITest `click()`) regardless of how many chips are in the bar.
- When the chip width drops below the truncation threshold, chip titles must
  truncate with an ellipsis. The `accessibilityLabel` still carries the full
  title.
- Three Tabs with three different cwds must produce three distinct chip
  identifiers. Chips that all show the same string (e.g., `user@host`) are a
  bug.
- A Tab at `$HOME` without a user override must show `"~"` as its chip title.
- A Tab at `$HOME` with a user override must show the override. The override
  must beat the home-dir `"~"` formatter.

**Regression patterns:**

- `[0047]` — Chip content rendered past the Pane's trailing edge, overlapping
  the adjacent Pane.
- `[0048]` — Titles did not truncate, pushing the `+` button out of narrow
  Panes. Clicking the `+` button failed or hit a chip instead.
- `[0050]` — All chips showed `user@host` because title resolution used a shared
  state rather than per-Tab cwd tracking.
- `[0142]` — A Tab at `$HOME` always showed `"~"` even after a rename. The
  home-dir formatter ran after the override, winning the priority race.

**Accessibility identifiers:**

- `tab-chip.<title>` — one element per Tab; identifier is the displayed
  (possibly truncated) title; `accessibilityLabel` is the full untruncated
  title.
- `add-tab-button.<paneID>` — the `+` button inside `SlidingTabBar`.
- `tab-bar.<paneID>` — the tab bar container used to assert frame width bounds.

---

## Settings sheet

The Settings window (`Cmd-,`) exposes user preferences that are not layout
state. Preferences are stored in `UserDefaults`. The window has multiple panes
(General, Notifications, Shortcuts, Appearance) accessible via toolbar tabs.

The Shortcuts pane (`[0070]`) contains one `ShortcutRow` per customizable
action. Each row has a `KeyboardShortcutRecorder` field, a per-row Reset button,
and a global "Reset All to Defaults" at the bottom. The recorder accepts
modifier+character combos and special keys; it rejects plain characters and
Shift-only combos to avoid shadowing terminal input. Reserved system combos
(`Cmd-Q`, `Cmd-H`, `Cmd-M`, `Cmd-Tab`, `Cmd-,`) trigger a warning row but are
still saved.

See `shortcuts.md` for the full routing architecture, persistence format,
recorder behavior, reserved combos, and the rationale for the NSEvent monitor
approach.

**Invariants:**

- `Cmd-,` opens the Settings window.
- Every toolbar pane tab in the Settings window must be reachable and must
  display a distinct content view.
- Every toggle in the Settings UI must map to a `UserDefaults` key that actually
  gates the documented behavior. A toggle that claims a feature but is not
  connected to the implementation is a bug.
- Toggle states must persist across relaunches. A toggle that resets on every
  launch is a bug.
- Default values for all toggles must match the documented user-expected
  defaults. A wrong default is a regression.
- Rebinding a shortcut must take effect immediately (no restart required) and
  must persist across relaunches.
- Resetting a shortcut must restore the documented default.
- Every row in Settings → Shortcuts must reference an action that is actually
  implemented and reachable via the current keyboard shortcut routing.

**Regression patterns:**

- `[0034]` — Initial Settings wiring; window did not open or pane tabs were
  not reachable.
- `[0068]` — Settings documented per-session mute in the sidebar context menu
  but it was not implemented there. A settings entry that claims behavior is
  worse than no entry.
- `[0070]` — Customizable hotkeys. Introduced `ShortcutsStore`, the recorder
  UI, and the JSON persistence format.
- `[0105]` — Multi-line paste confirmation was on by default when users expected
  it to be off. The wrong default was shipped.

**Accessibility identifiers:**

- `settings.window` — the Settings window root.
- `settings.tab.<name>` — each toolbar pane tab (e.g., `settings.tab.general`,
  `settings.tab.shortcuts`).
- `settings.content.<name>` — each content pane view.
- `settings.toggle.<key>` — each `Toggle`; `accessibilityValue` is `"on"` or
  `"off"`.
- `settings.shortcut-row.<action>` — each row in the Shortcuts pane.
- `settings.shortcut-recorder.<action>` — the recorder field in each row.

---

## Sidebar toggle and window chrome

The Sidebar (the `NavigationSplitView` leading column) is collapsible. The
default shortcut is `Cmd-B` (per `[0129]`); there is also a View menu entry
and the standard `NavigationSplitView` chevron button in the toolbar. Collapsed
state is per-window `@SceneStorage` (the legacy `SidebarPreference.hiddenKey`
only seeds it once) and lasts for the life of the process; window restoration
is disabled (#0444), so it does not survive relaunches.

The `+` button for creating a new Session lives in the Sidebar header. Its
visibility and hit-testability when the sidebar is collapsed must be explicitly
specified and tested — `[0065]` called this out as bug-prone.

**Invariants:**

- `Cmd-B` must toggle the sidebar between collapsed and expanded states.
- Toggling twice (collapse, expand) must return the sidebar to its prior width
  within a reasonable tolerance.
- The sidebar's collapsed state is per-window and in-process only; it is not restored across relaunches (window restoration is disabled, #0444).
- The `session-sidebar.chevron` must remain at a consistent position across
  toggle cycles. A large positional shift is a visual regression.
- Whether the `+` button is visible in the collapsed state is an explicit design
  decision that must be documented and tested. `[0065]` identified its
  disappearance as a bug; the current spec must define the correct behavior.
- Selecting a Session row must not change the sidebar width.
- The sidebar right-click context menu must open on `session-row.<title>`.
- `Cmd-B` must appear in Settings → Shortcuts as the binding for
  `toggleSidebar`. The shortcut is customizable.

**Regression patterns:**

- `[0065]` — The sidebar toggle had no animation, the `+` button disappeared
  on collapse, and the chevron shifted position noticeably.
- `[0129]` — Added `Cmd-B` as the sidebar toggle shortcut and a Settings entry.
  Before this, there was no keyboard shortcut for the sidebar.

**Accessibility identifiers:**

- `session-sidebar` — the sidebar root; frame width used to assert
  collapsed/expanded state.
- `session-sidebar.add-session-button` — the `+` button in the sidebar header.
- `session-sidebar.chevron` — the disclosure chevron; frame used to assert
  positional stability across toggle.

---

## Fuzzy finders

Batty provides two fuzzy-find surfaces: the **Command Palette** (`Cmd-Shift-P`,
per `[0126]`) for triggering app actions by name, and **Open Quickly**
(`Cmd-Shift-O`, per `[0128]`) for navigating to a Session or Tab by name.
Both follow the same interaction pattern: invoke shortcut → list appears → type
to filter → arrow keys move selection → Return commits the highlighted item →
Escape dismisses without action.

Both surfaces have menu item entries. The absence of a menu entry for Open
Quickly was caught as `[0150]`.

**Invariants:**

- `Cmd-Shift-P` must open the Command Palette (`command-palette.root`).
- `Cmd-Shift-O` must open Open Quickly (`open-quickly.root`).
- Both palettes must be dismissible via Escape without firing any action and
  without causing side effects.
- Typing in the filter field must narrow the visible rows to only those matching
  the query.
- Arrow keys must move the selection through the visible rows.
- Return on the selected row must commit that row's action and dismiss the
  palette.
- Escape on any row must dismiss without committing.
- Applying a Command Palette action that creates or destroys UI elements (e.g.,
  "split horizontally") must produce the expected structural result.
- Selecting an Open Quickly Session target must make that Session the active
  selection in the sidebar.
- Selecting an Open Quickly Tab target must activate that Tab in its Pane and
  focus the Pane.
- The File menu must contain an "Open Quickly…" item (`menu.file.open-quickly`).
- Each menu item's displayed shortcut must match the documented binding
  (`Cmd-Shift-O` / `Cmd-Shift-P`).
- The visible row count after filtering must be a subset of the total row count
  (not a floor violation). Assertions on row counts use floors, not exact
  counts, because the action set grows as features land.

**Regression patterns:**

- `[0126]` — Command Palette wiring; initial invocation and action dispatch.
- `[0128]` — Open Quickly wiring; initial invocation and Session/Tab navigation.
- `[0150]` — File menu was missing the "Open Quickly…" item.

**Accessibility identifiers:**

- `command-palette.root`, `command-palette.filter-field`,
  `command-palette.row.<action>`.
- `open-quickly.root`, `open-quickly.filter-field`,
  `open-quickly.row.<target>`.
- `menu.file.open-quickly` — the File menu item for Open Quickly.
- `accessibilityValue("selected" / "unselected")` on `session-row.<title>`.
- `accessibilityValue("active" / "inactive")` on `tab-chip.<title>`.

---

## Modal confirmation flows

Three modals protect users from irreversible or dangerous actions:

1. **Multi-line paste sheet** — shown when the user pastes text containing
   newlines while the confirmation preference is enabled (Settings → Behavior).
   Lets the user confirm or cancel before multi-line content is sent to the
   shell. Single-line pastes must not trigger the sheet.
2. **Close-with-process-running confirmation** — shown when `Cmd-W` closes a
   Tab that has a non-idle process running (e.g., `sleep 1000`). Closing a Tab
   at a clean prompt must not trigger the sheet.
3. **Quit confirmation** — shown when `Cmd-Q` is sent while any Pane has a
   non-idle process running.

The existing `BATTY_UI_TEST_MODE=1` environment variable short-circuits all
three modals so that the `xcodebuild test` runner's termination path does not
hang. This bypass is incompatible with testing the modals themselves. Testing
each modal requires a second harness mode using per-modal environment variables
(`BATTY_UI_TEST_ALLOW_PASTE_PROMPT=1`, `BATTY_UI_TEST_ALLOW_CLOSE_PROMPT=1`,
`BATTY_UI_TEST_ALLOW_QUIT_PROMPT=1`) that allow the modal to appear while the
test asserts on its presence, then auto-dismiss with the chosen outcome.

**Invariants:**

- A single-line paste via `Cmd-V` must not show `multi-line-paste-sheet`,
  regardless of the confirmation preference.
- A multi-line paste via `Cmd-V` must show `multi-line-paste-sheet` when the
  preference is enabled.
- Confirming the paste sheet must send all lines to the terminal.
- Cancelling the paste sheet must send no text to the terminal.
- `Cmd-W` on a Tab with a running process must show `close-confirmation.sheet`.
- `Cmd-W` on a Tab at a clean prompt must close the Tab immediately with no sheet.
- Confirming the close sheet must remove the Tab chip.
- Cancelling the close sheet must leave the Tab intact.
- `Cmd-Q` with no running processes must terminate the app silently (no sheet).
- `Cmd-Q` with a running process must show `quit-confirmation.sheet`.
- The `BATTY_UI_TEST_MODE=1` bypass must remain respected for the main test run.
  A test that confirms the bypass is active must run before the modal tests so
  that a regression disabling the bypass fails at the bypass-check test rather
  than by hanging the runner.

**Regression patterns:**

- `[0035]` — Multi-line paste confirmation initial wiring. Sheet did not appear,
  or appeared for single-line pastes.
- `[0036]` — Close-confirmation and quit-confirmation wiring.
- `[0054]` — `Cmd-W` was supposed to confirm before closing when a process was
  running but did not.
- `[0105]` — Multi-line paste prompt was on by default when the expected default
  was off. (The default-value side is covered in the Settings sheet section;
  the behavior side is covered here.)

**Accessibility identifiers:**

- `multi-line-paste-sheet` — the sheet root; `.paste-button` and
  `.cancel-button` inside.
- `close-confirmation.sheet` — the sheet root; `.close-button` and
  `.cancel-button` inside.
- `quit-confirmation.sheet` — the sheet root; `.quit-button` and
  `.cancel-button` inside.

---

## Project Editor

The Project Editor (#0474) is where a user defines Projects. It is one
process-global AppKit window titled "Projects", created on demand by
`ProjectEditorWindowController` from File ▸ **Edit Projects…**, and absent
entirely when `FeatureFlags.projects` is off. It is not a content window: it is
never registered with `AppStateStore.registerNSWindow`, so content-window
shortcuts are off while it is key (`BattyShortcuts` declines the chord, and
the menu items that act on a Session, Pane or Tab resolve no target, see
below), and the Save & Open target is `defaultTargetWindow()`. Layout, left to right: the Projects list, the settings
column (Name, Root folder, Session color, Layout strip, Pane preview), and the
Pane inspector, with a footer.

**Invariants:**

- Edits are a draft. Nothing is written to `ProjectStore` until Save or
  Save & Open. Cancel writes nothing and closes the window.
- Switching Projects, choosing New Project, or closing the window with unsaved
  changes asks Save, Discard Changes or Cancel.
- Save is enabled only for a valid, changed draft. Save & Open is enabled for a
  valid draft. Invalid fields show an inline message under the field.
- Save & Open saves, closes the editor, then opens through
  `requestOpenProject`, so the startup-command trust sheet appears when the
  command set is new or changed.
- The Layout strip shows all ten presets, plus a "Custom" thumbnail when the
  Project's topology has no preset.
- Changing the Layout keeps slot N's configuration where slot N still exists. A
  confirmation names the Panes that would be removed when they carry
  configuration.
- Switching a Pane from Terminal to another kind and back keeps its Tabs until
  Save.
- While the Project Editor is key (a sheet over it counts as the editor),
  menu actions that act on the content window behind it do nothing: New Tab,
  splits, pane focus and resize, Exit Shell, Paste into a Terminal (Paste
  still pastes into the editor's own text fields), session and tab selection,
  and the toggles for Open Quickly, Sidebar, Layout picker, Theme selector
  and Bell Feed. Close Tab (⌘W) closes the editor window instead.
  `AppStateStore.menuTargetWindow()` and `focusedTerminalTab` carry the rule,
  and it applies at action time only: menu enablement still reads
  `defaultTargetWindow()`. The rule matches only the editor's window, so it
  does nothing with the Projects flag off. XPC and CLI resolution keep using
  `defaultTargetWindow()`.
- A draft handed to the editor (Save as Project, #0476) counts as unsaved:
  closing or switching away from it asks first.
- Saving never overwrites the approval hash or last-opened date with the values
  loaded when the Project was selected; it takes the stored ones.
- With the flag off there is no Edit Projects… item, no Window-menu entry and
  no way to create the window.

**Accessibility identifiers:**

- Window identifier `project-editor`.
- Projects list: `project-editor.list`, rows `project-editor.list.row.<name>`
  (`project-editor.list.row.new` for the unsaved Project),
  `project-editor.new-project`, `project-editor.empty.new-project`.
- Header: `project-editor.name`, `project-editor.root`,
  `project-editor.root.choose`, swatches `project-editor.color.<case>` (`blue`,
  `orange`, `green`, `pink`, `teal`, `red`, `violet`, `amber`, `cyan`,
  `brown`). Field errors append `.error` and warnings `.warning` to the field's
  identifier (for example `project-editor.name.error`).
- Layout: `project-editor.layout.<PaneLayout rawValue>`,
  `project-editor.layout.custom`; Pane preview `project-editor.preview`, cards
  `project-editor.pane.<n>` (one-based).
- Inspector: `project-editor.inspector`, kind buttons
  `project-editor.kind.<PaneContentKind rawValue>`, `project-editor.add-tab`,
  per Tab (one-based `<n>`) `project-editor.tab.<n>.title`,
  `.directory`, `.directory.choose`, `.command`, `.remove`, and for Git Status
  `project-editor.repository` and `project-editor.repository.choose`.
- Footer: `project-editor.run-commands`, `project-editor.cancel`,
  `project-editor.save`, `project-editor.save-open`, `project-editor.save-error`.

**Not covered by unit tests (for the Tart VM suite, #0478):**

- File ▸ Edit Projects… is present with the flag on and absent with
  `BATTY_UI_TEST_FORCE_PROJECTS_OFF=1`, and the Window menu has no Projects
  entry with the flag off.
- The editor window opens and comes forward when already open. With it key,
  ⌘T adds no Tab, ⇧⌘X sends no exit and ⌘V pastes nothing into the background
  window's Terminal (⌘V still pastes into a focused editor field), while ⌘W
  closes the editor (asking first when there are unsaved changes).
- Typing in the fields, clicking Pane cards, arrow-key movement between cards,
  swatch selection, the layout confirmation dialog, and the unsaved-changes
  dialog.
- Choose… (`NSOpenPanel`) and the Tab folder chooser.
- Save & Open end to end: the Session appears in a content window, and the
  trust sheet appears for an unapproved command set.

---

## Open Project picker, File menu and Command Palette entries

The Open Project picker (#0475) is a sheet on `SessionDetailView`, like the
Layout picker, toggled by `.battyToggleProjectPicker` and guarded on
`isKeyWindow` (#0242). Its logic lives in `ProjectPickerModel`; the File menu's
Open Project submenu is `ProjectFileMenuModel` rendered by `BattyCommands`; the
Command Palette entries are built in `CommandPaletteView.allCommands`. All of
them are absent with `FeatureFlags.projects` off.

**Invariants:**

- The picker only reports a choice. `SessionDetailView` dismisses the sheet and
  acts in the sheet's `onDismiss`, so the startup-command trust sheet (which
  presents from the same view) is never competing with a closing sheet. The
  palette's Project commands do the same through `afterDismiss`.
- Return opens with `.focusExistingOrOpen` (the Project's open Session is
  selected if there is one). Option-Return opens with `.openNew`. Double-click
  opens like Return. A single click only selects.
- Arrow keys move the selection over three columns, row-major, without
  wrapping. Left and right therefore do not move the caret in the filter field.
  Down from a column a short last row lacks lands on the last card.
- Typing a filter selects its best match. Names match fuzzily; paths match as a
  case-insensitive substring (the full path or its `~` form). Name matches rank
  ahead of path matches; ties keep store order.
- Cmd-E (Edit) and Cmd-N (New Project) are hidden buttons with key
  equivalents inside the sheet. Cmd-N is also File > New Session, and Cmd-E is
  the default for Pane > Open View > System Metrics
  (`ShortcutAction.splitHorizontalSystemMetrics`). Two layers
  are meant to keep either from acting on the content window: the sheet's key equivalent
  runs before the main menu, and `AppStateStore.menuTargetWindow()` resolves no
  target while the picker's window (tagged `project-picker`) is key.
- The cards and OPEN badges are read live from the store, so they follow edits
  made in the Project Editor or by the CLI while the sheet is up; the selection
  stays on its Project by id.
- The palette's "Open Project..." row presents the picker from the palette's
  `onDismiss`, which relies on the content window being key again by then.
- The File menu items have no key equivalents and there is no new
  `ShortcutAction`. The submenu is disabled when no window is registered. Its
  Choose Project... does nothing while the Project Editor is key
  (`postToContentWindow`), like the other toggles.
- With the flag off there is no Open Project submenu, no Choose Project... or
  New Project..., no `project:` or `extra:openProjectPicker` palette ids, the
  toggle notification is ignored, the sheet does not present, and
  `ProjectStore` is never constructed from these paths.

**Accessibility identifiers:**

- Sheet root `project-picker.root`; filter field `project-picker.filter`; hint
  line `project-picker.hint`.
- Cards `project-picker.card.<Project name>`; OPEN badge
  `project-picker.open-badge.<Project name>` (present only for a Project with
  an open Session).
- Empty state `project-picker.empty`, with `project-picker.new-project` when no
  Projects exist.
- File menu: submenu title "Open Project", items titled by Project name (a
  check mark marks an open Project), "Choose Project...", "New Project...".
- Command Palette: rows titled "Open Project: <name>" and "Open Project...".

**Not covered by unit tests (for the Tart VM suite, #0478, plus the manual
check below):**

- With the flag on, File > Open Project shows each seeded Project, checks the
  open one, and Choose Project... presents the sheet; with
  `BATTY_UI_TEST_FORCE_PROJECTS_OFF=1` the submenu is absent and the palette
  has no Project rows.
- Typing narrows the cards; arrows move the selection; Return opens and
  Option-Return opens another copy; Escape dismisses; clicking a card selects
  it and double-clicking opens it.
- A Project whose commands are unapproved shows the trust sheet after the
  picker (or palette) has closed.
- Cmd-E opens the Project Editor on the selection; Cmd-N opens it on a new
  Project. **Manual check:** with the picker up, press Cmd-N and confirm the
  Sidebar gains no Session and the editor opens on a new Project. Likewise
  press Cmd-E and confirm no System Metrics Pane is added and the editor opens
  on the selected Project.
- The empty state's New Project... button.
- Opening a Project that was deleted while the picker was up shows an alert.
- Option-Return in the filter field opens another copy and does not insert a
  newline.
- The palette's "Open Project..." row presents the picker.

---

## Save Session as Project

Save as Project (#0476) captures a live Session into a draft Project and opens
the Project Editor on it. `SessionProjectCapture` (pure, in `Model/`) reads the
Session and writes nothing; the Project is stored only when the user clicks
Save in the editor. It never runs on quit or on a timer, which is what
separates it from the workspace persistence #0172 removed.

**Captured:** the split topology (direction and nesting; a same-direction split
nested in a split is one n-ary split), every Pane's kind (hidden Panes
included, as ordinary slots), each Terminal Tab's working directory relative to
the root, a Tab's title only when the user set one (`titleOverride`), a Git
Status Pane's folder relative to the root, and the Session's color. The root is
the first leaf Pane's first Tab's folder, else the first Terminal Tab that has
one, else `$HOME` (then the editor reports the root as an error until one is
chosen). The preset marker is set when the topology equals a `PaneLayout`
preset's, otherwise the editor shows Custom.

**Not captured:** split ratios and every other size (a reopened Project opens at
equal sizes, #0255), startup commands, automatic Tab titles, Process Status
pids, and a non-Terminal Pane's placeholder Tab. A Tab or repository outside
the root is stored as the root and flagged with a warning on its field.

**Entry points** (all behind `featureFlags.projects`; none has a shortcut or a
`ShortcutAction`):

- Sidebar row context menu: "Save as Project..." (after Mute Notifications,
  before Close). Captures that row's Session.
- File > "Save Session as Project..." between Open Project and Edit Projects.
  Captures the key Window's selected Session; disabled with none.
- Command Palette `extra:saveSessionAsProject` "Save Session as Project...".
- Project Editor "Copy from current Session" beside the Layout title
  (`project-editor.copy-from-session`). Captures `defaultTargetWindow()`'s
  selected Session relative to the draft's root, keeps the draft's name, root,
  color and run toggle, and asks first when Tabs, commands or views would be
  replaced.
- A Session opened from a stored Project (`projectID` set, Project still
  exists) shows two items instead: `Update "<name>"...` (layout and Tabs
  replaced, commands kept where the slot and Tab line up) and "Save as New
  Project..." (File menu: "Save Session as New Project..."). The palette adds
  `extra:updateSessionProject` "Update Project: <name>".

**Not covered by unit tests (for the Tart VM suite, #0478):**

- The Sidebar context menu item is present with the flag on and absent with
  `BATTY_UI_TEST_FORCE_PROJECTS_OFF=1`; same for the File item and the palette
  row. Choosing it opens the editor on a draft with the Session's Panes, Tabs
  and color, and nothing is stored until Save.
- Right-clicking a row that is not selected captures that row's Session and
  leaves the selection, drag-reorder and row identifiers alone.
- File > Save Session as Project... is disabled with no Window, and does
  nothing while the editor or picker is key.
- "Copy from current Session" in the editor, with and without configured Tabs
  (the confirmation dialog), with the editor open over a different Window.
- A Project-backed Session offers Update and Save as New; Update then Save
  changes the stored Project and Cancel does not.
- Opening the saved Project gives the same shape at equal sizes.

---

## Projects UI tests (#0478)

The Projects UI tests live in `BattyUITests/Projects*Tests.swift` and run only in the
Tart VM (`docs/ui-testing-vm.md`). `ProjectsUITestCase` (in `Support/ProjectsHarness.swift`)
gives each test its own `projects.json`: the app reads `BATTY_UI_TEST_PROJECTS_FILE`
(an absolute path) only when `BATTY_UI_TEST_SCRIPT` is also set, so no test touches the
guest's real `~/Library/Application Support/Batty Beta/projects.json`. Tests write the
store before launch, open Projects through the real picker, menu and palette (the
driver's `openProject` intent bypasses the trust flow), and read the topology back
through the embedded CLI.

**Identifiers the tests rely on** (the Project Editor, picker and menu lists above are
unchanged; these are the ones they do not cover):

- `project-startup-trust` -- the startup-command trust sheet; `project-startup-trust.remember`
  (checked by default), `project-startup-trust.open-without-running`, `project-startup-trust.run`.
  Each listed command is a static text `$ <command>`.
- `command-palette.root`. Palette rows have no identifiers; the tests find them by their
  title text ("Open Project: <name>", "Open Project...", "Save Session as Project...").
- `tab-chip.<title>`, `session-row.<title>`, `pane-terminal.<pane id>`, `git-status.snapshot`.
- Menu items have no identifiers; the File items "Open Project" (submenu: Project names,
  "Choose Project...", "New Project..."), "Save Session as Project...", "Edit Projects...", the
  Sidebar item "Save as Project...", and the Window item "Projects" are found by title.

**Coverage map** (the checklists above and in the #0474-#0477 sections):

| Flow | Test |
|---|---|
| Open from the picker; glyph, Panes, Tab titles | `ProjectsOpenTests.testPickerOpensProjectWithGlyphLayoutAndTabTitles` |
| Return finds, Option-Return opens another | `ProjectsOpenTests.testReturnFocusesTheOpenSessionAndOptionReturnOpensAnother` |
| OPEN badge, File check mark, Escape, Choose/New items | `ProjectsOpenTests.testOpenBadgeAndFileMenuCheckMarkFollowTheOpenProject` |
| Palette "Open Project: <name>" and "Open Project..." | `ProjectsOpenTests.testCommandPaletteOpensAProject`, `...OpenProjectRowPresentsThePicker` and `...WithReturn` (both wrapped in a strict `XCTExpectFailure` for #0483: the row never presents the picker; remove the wrapper when #0483 lands) |
| Trust sheet, Open Without Running, Run Commands, remembered approval, edited command | `ProjectsStartupTests.testTrustSheetGatesStartupCommandsAndRemembersApproval` |
| Edit Projects..., Window menu entry | `ProjectsEditorTests.testEditProjectsMenuOpensTheEditorOnTheStoredProjects` |
| Create, Save & Open, Tab directory | `ProjectsEditorTests.testEditorCreatesAProjectAndSaveAndOpenOpensIt` |
| Cancel leaves the store unchanged | `ProjectsEditorTests.testCancelLeavesTheStoredProjectUnchanged` |
| Sidebar Save as Project, round trip, equal sizes | `ProjectsEditorTests.testSidebarSaveAsProjectRoundTripsTheSessionShape` |
| Palette Save Session as Project... | `ProjectsEditorTests.testCommandPaletteSaveSessionAsProjectOpensTheEditor` |
| `batty project list` / `open` | `ProjectsCLITests.testProjectListShowsSeededProjectsAndOpenMarker` |
| Flag off: File, Window, Sidebar, palette, no `projects.json` | `ProjectsFlagOffTests` |

**Identifiers the accessibility tree does not honor** (tracked by #0484; the pixel-check helpers `iconInk`/`assertCheckMarks` in `ProjectsHarness.swift` go away with it; the tests work around each; fixing the
view would let them use the documented identifier):

- `project-picker.filter`, `project-picker.hint` and the other un-buttoned children of the picker
  sheet surface as `project-picker.root`, because the root's identifier is applied to a container
  that does not contain its children. The tests find the filter as the text field with either
  identifier. The cards (`project-picker.card.<name>`) are buttons and keep their own.
- `project-editor.pane.<n>` surfaces as `project-editor.preview` on every card; the tests match
  `project-editor.preview` plus the label "Pane <n>: <kind>". Pane 1's card reports the whole
  preview as its frame, so cards are clicked near their top-left.
- `session-row.project-glyph` is not an element at all: the Sidebar `Label` merges the icon into
  `session-row.<title>`. The tests tell the folder from the plain symbol by the icon's pixels.
- A File menu check mark is exposed neither as `value` nor as selection; the tests read it from
  the item's pixels.
- The trust sheet root's identifier can likewise replace its controls' identifiers; the tests
  also match its buttons and toggle by title.

**Not automated, kept as manual checks:** Cmd-N and Cmd-E inside the picker (the key
equivalents compete with File > New Session and Pane > Open View; see the picker section's
manual check), the layout-change and unsaved-changes dialogs, the editor's Choose...
(`NSOpenPanel`) buttons, and the editor-key menu-suppression chords (Cmd-T, Shift-Cmd-X,
Cmd-V, Cmd-W with the editor key).

---

*Document version: 1 — 2026-05-20.*
