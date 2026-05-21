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
on the toolbar bell button or invoked via the `Cmd-Shift-N` shortcut. The bell
button displays the `bell.badge` SF Symbol when there are unseen entries and
`bell` when the feed is clean.

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
- The `Cmd-Shift-N` shortcut must open the Bell Feed popover. The shortcut is
  customizable in Settings → Shortcuts.

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
state is persisted in `UserDefaults` (`SidebarPreference.hiddenKey`) and
survives relaunches.

The `+` button for creating a new Session lives in the Sidebar header. Its
visibility and hit-testability when the sidebar is collapsed must be explicitly
specified and tested — `[0065]` called this out as bug-prone.

**Invariants:**

- `Cmd-B` must toggle the sidebar between collapsed and expanded states.
- Toggling twice (collapse, expand) must return the sidebar to its prior width
  within a reasonable tolerance.
- The sidebar's collapsed state must persist across relaunches.
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

*Document version: 1 — 2026-05-20.*
