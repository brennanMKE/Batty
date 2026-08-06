# Themes

How Batty loads, selects, and applies color themes. Read this before
touching anything in the theme path. Companion to `Concepts.md`
(vocabulary) and [`view-hierarchy.md`](view-hierarchy.md) (where the
live surfaces actually live). Issue `#0078` is the history.

Batty's theme system is mostly a thin shim over libghostty, plus a
small Batty-owned catalog of original themes layered on top. Anyone
touching theme behavior needs to keep three things in mind:

1. **The catalog is upstream PLUS Batty-original.** Most theme
   definitions ship inside the upstream `Lakr233/libghostty-spm`
   package as `GhosttyThemeCatalog.allThemes` (~485 entries). Batty
   also owns a small original set (`#0310`) constructed directly in
   `BattyKit` — `GhosttyThemeDefinition` has a public memberwise init,
   so no fork and no package dependency is needed to add one. Batty
   code reads `BattyThemeCatalog.allThemes` / `.theme(named:)`, which
   merges both sources — never `GhosttyThemeCatalog` directly. See
   section 2 below.
2. **The selection is just a name in `UserDefaults`.** A single string
   key (`ThemePreference.defaultsKey`) is the entire persisted state.
   Both the Theme menu and the Settings → Appearance picker bind to it
   via `@AppStorage`.
3. **Applying a theme never tears down surfaces.** `setTheme(_:)` on
   the libghostty controller swaps colors in place — no PTY restart,
   no NSView teardown, no rebuild of the SwiftUI tree.

---

## 1. User-facing summary

Where to change a theme: **menu bar → Theme**. Every theme in the
catalog appears as a menu item, sorted in catalog order. The active
theme is marked with a `checkmark` system image; non-active themes
render as plain text.

A duplicate of the same control lives at **Settings → Appearance →
Theme** as a `Picker`. It includes a `"Default"` entry that maps to the
empty string — picking it falls back to `TerminalTheme.default`.

Selecting a theme:

- Writes the theme's display name to `UserDefaults` under
  `co.sstools.Batty.themeName`.
- Calls `AppStateStore.applyThemeToAllSurfaces(_:)` so every live
  terminal repaints with the new palette immediately. Scrollback,
  running TUIs (vim, htop, fzf), and the active prompt all re-render
  in-place. No need to reopen tabs.
- Sticks across launches. The next `TabRuntime` reads the same
  `UserDefaults` key when it constructs its `TerminalViewState`, so new
  tabs inherit the active theme on creation.

Settings → Appearance also exposes font size and cursor settings (style
+ blink). These are **not** theme-related; see section 7.

---

## 2. Theme catalog source

Two catalogs exist, and Batty code should only ever read the merged
one:

| Catalog | Where | Role |
|---|---|---|
| `GhosttyThemeCatalog.allThemes` | upstream `Lakr233/libghostty-spm` package, `GhosttyTheme` target | ~485 entries, generated from `mbadolato/iTerm2-Color-Schemes`. Batty does not own this data and never hand-edits it. |
| `BattyThemeCatalog.allThemes` | `BattyKit/Sources/BattyKit/Theme/BattyThemeCatalog.swift` | **The one Batty code reads.** `merge(batty: battyThemes, upstream: GhosttyThemeCatalog.allThemes)`, sorted case-insensitively by name, so Batty-original themes take their alphabetical place instead of trailing the list. Also exposes `theme(named:)`. |

The Batty-original themes themselves (`#0310`) live in
`BattyKit/Sources/BattyKit/Theme/BattyThemes.swift`, as a `public
extension GhosttyThemeDefinition { static let ... }` — ordinary values
constructed on Batty's side of the package boundary. This works
because `GhosttyThemeDefinition` has a **public memberwise init**
(`Sources/GhosttyTheme/GhosttyThemeDefinition.swift` in the upstream
package) — Batty can construct catalog entries without needing to
land anything in a fork or bump `BattyKit/Package.swift`. Adding a
theme means adding a `static let` in `BattyThemes.swift` and listing
it in `BattyThemeCatalog.battyThemes` — that second edit is silent if
skipped. See section 10.

**Collision policy:** if a Batty-original name ever collided with an
upstream name, Batty wins — `BattyThemeCatalog.merge(_:_:)`
deduplicates the Batty bucket into the merge first, so a same-named
upstream entry is dropped. Pinned by
`BattyKit/Tests/BattyKitTests/BattyThemeCatalogTests.swift`.

**A previous round of `#0310` got this wrong**: it landed the eight
Batty-original themes inside the `brennanMKE/libghostty-spm` fork
(`Themes_Batty.swift` + a generator-survival mechanism) on the theory
that "the catalog is read-only at runtime; there is no API to
register a theme on the fly." That premise was false —
`GhosttyThemeDefinition`'s public init means Batty can always
construct entries on its own side — and the fork route also implied a
dependency change Batty didn't want (`BattyKit/Package.swift` is
pinned to the upstream `Lakr233` package, not the `brennanMKE` fork,
so shipping fork-only themes would have required repointing the
dependency and rolling back 96 unrelated upstream commits). That work
was reverted; this section now describes the corrected, fork-free
approach.

`GhosttyThemeDefinition` itself is a value-type record of `String` hex
colors:

```swift
public struct GhosttyThemeDefinition: Sendable, Hashable, Identifiable {
    public let name: String
    public let background: String
    public let foreground: String
    public let cursorColor: String?
    public let cursorText: String?
    public let selectionBackground: String?
    public let selectionForeground: String?
    public let palette: [Int: String]   // 0..15
}
```

The `isDark` computed property (luminance < 128) is used by the
catalog viewer in Settings to bucket light vs dark; the runtime path
ignores it.

---

## 3. User selection and persistence

The complete persistence state is one string in `UserDefaults`:

| Symbol | Value |
|---|---|
| Key | `co.sstools.Batty.themeName` |
| Defined at | `ThemePreference.defaultsKey` (`BattyKit/Sources/BattyKit/ThemePreference.swift`) |
| Type | `String` (the theme's `name`) |
| Empty / unset | Fall back to `TerminalTheme.default` (libghostty's built-in default) |

`BattyCommands` declares the binding once for the Theme menu:

```swift
@AppStorage(ThemePreference.defaultsKey) private var activeThemeName: String = ""
```

`SettingsView`'s `AppearanceSettingsView` declares the same binding
for the picker. Because `@AppStorage` is backed by `UserDefaults`,
writes from either control update the value seen by the other —
selecting in the menu re-renders the Settings picker and vice versa.

The Theme menu's selection handler does two things, in this order:

```swift
private func selectTheme(_ theme: GhosttyThemeDefinition) {
    activeThemeName = theme.name
    store.applyThemeToAllSurfaces(theme)
}
```

First persists the name (so a relaunch picks up the new theme), then
pushes it to every live surface. The Settings picker's `onChange`
handler runs the same two steps. **Order matters only weakly** — the
two operations are independent — but persisting first matches the
"durable state changes before transient state changes" convention used
elsewhere in the codebase.

There is no separate "applied" state. The single source of truth is
the `UserDefaults` value plus whatever each live surface currently
has. If the two ever disagree (e.g. a surface that was created before
the user changed the theme but somehow missed the propagation), the
fix is to re-select the theme from the menu.

---

## 4. How a new tab picks up the theme

`TabRuntime.init` constructs each new `TerminalViewState` with a
theme baked in:

```swift
self.terminal = TerminalViewState(theme: Self.activeTheme())
```

`activeTheme()` is a private static method on `TabRuntime` that runs
on every tab creation. There is no warm cache and no shared
`@Observable` theme object — each tab independently resolves the
active theme at construction time by delegating to
`ThemePreference.activeTheme()`, which reads the per-appearance
`UserDefaults` key and resolves it through `BattyThemeCatalog`:

```swift
private static func activeTheme() -> TerminalTheme {
    guard let definition = ThemePreference.activeTheme() else { return .default }
    return definition.toTerminalTheme()
}
```

Three failure modes all collapse to `TerminalTheme.default`:

- The key is unset (first launch before any theme has been chosen).
- The key is set to the empty string (the Settings picker's
  `"Default"` tag).
- The key is set to a name the catalog no longer knows about (e.g.
  the user upgraded Batty and the theme was renamed or removed
  upstream).

The third case is silent — Batty does **not** clear the
`UserDefaults` value when lookup fails. Re-selecting any theme from
the menu overwrites it.

---

## 5. Live theme application

`AppStateStore.applyThemeToAllSurfaces(_:)` (defined as an extension
in `ThemePreference.swift`) walks every session, every pane, every
tab, and calls the libghostty controller's `setTheme(_:)`:

```swift
public func applyThemeToAllSurfaces(_ theme: GhosttyThemeDefinition) {
    let terminalTheme = theme.toTerminalTheme()
    for session in sessions {
        for pane in session.tree.allPanes {
            for tab in pane.tabs {
                tab.terminal.controller.setTheme(terminalTheme)
            }
        }
    }
}
```

The libghostty controller repaints the surface in place. Key
properties of this path:

- **No PTY restart.** The shell, the running TUI, the scrollback
  buffer, and the cursor position are untouched.
- **No NSView teardown.** The `AppTerminalView` held by
  `TerminalHostStore.shared` keeps its identity. View rebuilds upstream
  in SwiftUI are unaffected.
- **No selection signaling.** The store doesn't notify SwiftUI of any
  change. The Theme menu re-renders because `@AppStorage` already
  observes the underlying key; nothing else needs to react.

`GhosttyThemeDefinition.toTerminalTheme()` packs the same palette into
both the light and dark slots of `TerminalTheme`:

```swift
func toTerminalTheme() -> TerminalTheme {
    let config = toTerminalConfiguration()
    return TerminalTheme(light: config, dark: config)
}
```

Batty does not currently honour macOS appearance changes for theme
swapping — a single theme applies regardless of system light/dark
mode. (Per-appearance theme pairs are out of scope; see section 9.)

---

## 6. Theme structure

Two related types live at slightly different abstraction levels:

| Type | Module | Purpose |
|---|---|---|
| `GhosttyThemeDefinition` | `GhosttyTheme` (libghostty-spm) | Catalog record. Plain hex strings for each colour slot plus a `[Int: String]` palette dictionary. |
| `TerminalConfiguration` | `GhosttyTerminal` (libghostty-spm) | The libghostty configuration builder. Theme colors are one slice; font, keybinds, custom keys live alongside. |
| `TerminalTheme` | `GhosttyTerminal` (libghostty-spm) | A light/dark pair of `TerminalConfiguration`s. What `setTheme(_:)` actually accepts. |

`GhosttyThemeDefinition.toTerminalConfiguration()` does the hex-string
plumbing — it calls each `builder.with*` method only when the
corresponding optional is present, and emits palette entries in sorted
key order so the libghostty side sees a deterministic sequence.

Palette indices are the 16 ANSI colors (0–15). Bright variants are
8–15. Extended 256-color and 24-bit truecolor fall out of libghostty's
internal renderer; the theme catalog does not enumerate them.

`Theme.swift` in BattyKit contains a separate `Theme` / `ThemeParser`
/ `ThemeStore` set of types that parse Ghostty's `key = value`
`.ghostty` config format from disk. **This is dead code on the active
path** — the runtime selection and propagation route through
`BattyThemeCatalog`, not `ThemeStore`. The parser is still exercised
by `BattyKit/Tests/BattyKitTests/ThemeTests.swift` against a hand-rolled
fixture; treat it as a placeholder for a future user-themes-on-disk
feature.

Theme display names come straight from the upstream Ghostty
catalog — `"Solarized Dark"`, `"Gruvbox"`, `"3024 Day"`,
`"Apple System Colors"`, etc. Sort order in the menu mirrors
`allThemes` order, which is alphabetical-with-symbol-prefixes-first.

---

## 7. Settings → Appearance overlap

The Settings → Appearance pane bundles three orthogonal preferences:

| Pane control | Bound to | Drives |
|---|---|---|
| Font size stepper | `SettingsPreference.fontSizeKey` | `applyAppearanceToAllSurfaces()` per-surface font size |
| Cursor style segmented picker | `SettingsPreference.cursorStyleKey` | `TerminalCursorStyle` on every surface |
| Cursor blink toggle | `SettingsPreference.cursorBlinkKey` | per-surface cursor blink flag |
| Theme picker | `ThemePreference.defaultsKey` | `applyThemeToAllSurfaces(_:)` palette swap |

Font size, cursor style, and cursor blink are **not** theme state.
They live in their own `SettingsPreference` keys, propagate through
`applyAppearanceToAllSurfaces()` (a different method on
`AppStateStore`), and apply uniformly to every surface regardless of
the active theme. Selecting a new theme does not reset them; resetting
them does not change the theme.

The reason for the same-pane grouping is purely UI affinity ("things
that change how the terminal looks"). Don't conflate them in code —
the theme path stops at `setTheme(_:)`, while the cursor/font path
goes through `setTerminalConfiguration(_:)`.

---

## 8. Where to look in the code

| File | Role |
|---|---|
| [`../BattyKit/Sources/BattyKit/Theme.swift`](../BattyKit/Sources/BattyKit/Theme.swift) | Standalone `Theme` / `ThemeParser` / `ThemeStore` for `.ghostty` files. Not on the active selection path; placeholder for future user themes. |
| [`../BattyKit/Sources/BattyKit/ThemePreference.swift`](../BattyKit/Sources/BattyKit/ThemePreference.swift) | `ThemePreference.defaultsKey` + the `AppStateStore.applyThemeToAllSurfaces(_:)` extension. The whole live-application path is here. |
| [`../BattyKit/Sources/BattyKit/TabRuntime.swift`](../BattyKit/Sources/BattyKit/TabRuntime.swift) | `TabRuntime.activeTheme()` reads the preference at tab construction. |
| [`../BattyKit/Sources/BattyKit/BattyCommands.swift`](../BattyKit/Sources/BattyKit/BattyCommands.swift) | The Theme menu (`CommandMenu("Theme")`) and the `selectTheme(_:)` handler. |
| [`../BattyKit/Sources/BattyKit/AppStateStore.swift`](../BattyKit/Sources/BattyKit/AppStateStore.swift) | Owner of `sessions`. The walk in `applyThemeToAllSurfaces` is over its state. |
| [`../BattyKit/Sources/BattyKit/SettingsView.swift`](../BattyKit/Sources/BattyKit/SettingsView.swift) | `AppearanceSettingsView` — the Settings picker for theme + the adjacent font/cursor controls. |
| [`../BattyKit/Sources/BattyKit/Theme/BattyThemeCatalog.swift`](../BattyKit/Sources/BattyKit/Theme/BattyThemeCatalog.swift) | The merged catalog Batty code actually reads: `allThemes`, `theme(named:)`, `merge(batty:upstream:)`, `battyThemes`. |
| [`../BattyKit/Sources/BattyKit/Theme/BattyThemes.swift`](../BattyKit/Sources/BattyKit/Theme/BattyThemes.swift) | The Batty-original `GhosttyThemeDefinition` values themselves (`#0310`). |
| `Sources/GhosttyTheme/GhosttyThemeCatalog.swift` (upstream `libghostty-spm`) | Upstream-only `allThemes`, `theme(named:)`, `search(_:)`. Not read directly by Batty code — go through `BattyThemeCatalog` instead. |
| `Sources/GhosttyTheme/GhosttyThemeDefinition.swift` (upstream `libghostty-spm`) | The record type. Public memberwise init — this is what lets Batty construct original themes without a fork. |
| `Sources/GhosttyTheme/GhosttyThemeDefinition+TerminalConfiguration.swift` (upstream `libghostty-spm`) | `toTerminalConfiguration()` / `toTerminalTheme()` / `isDark`. |
| `Sources/GhosttyTerminal/Controller/TerminalController.swift` (upstream `libghostty-spm`) | `setTheme(_:)` — the in-place repaint hook. |

`BattyKit/Package.swift` pins `libghostty-spm` to the **upstream**
`Lakr233/libghostty-spm` package (not a Batty fork) via a `revision:`
on the dependency. Batty-original themes (`#0310`) do not require
bumping this pin — see section 2. The pin still matters for picking up
new upstream catalog entries or other libghostty changes.

---

## 9. Global theme and session-local overrides

Batty has a two-tier theme system: a **global theme** that applies
app-wide and a **session-local override** that applies to one session.
The two tiers form a simple fallback chain:

```
session.localThemeName  →  ThemePreference (UserDefaults)  →  system default
       (per-session)              (global)                      (nil palette)
```

### Global theme

`ThemePreference.defaultsKey` in `UserDefaults.standard` is the
global theme. It persists across launches. All sessions whose
`localThemeName` is `nil` inherit it. This is the same key described
in section 3.

### Session-local override

`SessionRuntime.localThemeName: String?` holds a per-session override.
It is `nil` by default and is **not persisted** — every session starts
`nil` on every launch.

- `nil` → this session follows the global theme. Changing the global
  theme immediately reflects on this session.
- non-nil → this session uses its own theme, regardless of the global.
  Changing the global theme does **not** affect this session.

The session-local picker (`SessionThemeSelectorView`) is the only
thing that sets `localThemeName`. It sets the override AND calls
`applyTheme(_:to:)` to apply it immediately.

### Switching sessions

`applyActiveSessionTheme()` fires on every session switch. It
resolves the effective theme for the newly-selected session using the
fallback chain:

1. If `session.localThemeName` is set → use that theme.
2. Else if the global `UserDefaults` key is set → use that theme.
3. Else → call `themeChrome.update(from: nil)` to revert to the
   system default chrome.

The chrome always reflects the selected session's **effective theme**.
Terminal surfaces in the selected session are re-themed via
`setTheme()` on each switch (in case the effective theme changed while
the session was not selected).

### Changing the global theme

When the user picks a theme from the global selector (Cmd-Shift-T),
Theme menu, or Settings:

- The name is written to `UserDefaults` (persists).
- `applyThemeToAllSurfaces(_:)` applies the new theme to **every
  session whose `localThemeName` is `nil`**. Sessions with a
  local override keep their local theme and are not touched.
- `themeChrome.update(from:)` is called only if the currently-selected
  session has no local override (i.e., it follows global).

`applyThemeToAllSurfaces` must **not** write `localThemeName` on any
session — the sessions remain "following global" so that the next
global-theme change still propagates to them.

### New-tab initialization

`TabRuntime.init()` calls `Self.activeTheme()` which reads the global
`UserDefaults` key. This bakes the current global theme into the
libghostty config before the surface is created. The tab therefore
displays the correct background immediately, before
`applyActiveSessionTheme()` fires. Sessions with `localThemeName`
set will have their terminal re-themed via `setTheme()` when the
session is next selected (after surface connect).

### Clearing a local override

Set `session.localThemeName = nil` and call
`applyActiveSessionTheme()`. The session immediately picks up the
current global theme.

### Invariants

- `localThemeName` is never persisted. Every launch starts all
  sessions with `nil` (global fallback).
- `applyThemeToAllSurfaces` is for changing the global theme visually
  on all unoverridden sessions. It must not touch `localThemeName`.
- `applyTheme(_:to:)` applies visually to one session but does **not**
  set `localThemeName`. That is `SessionThemeSelectorView`'s job.
- The chrome always matches the selected session's effective theme.

---

## 10. Adding a new theme (developer workflow)

Two different paths, depending on where the theme comes from:

**To add a Batty-original theme (`#0310`) — no fork, no package bump:**

1. Add a `static let` on `GhosttyThemeDefinition` in
   [`../BattyKit/Sources/BattyKit/Theme/BattyThemes.swift`](../BattyKit/Sources/BattyKit/Theme/BattyThemes.swift),
   using the public memberwise init directly.
2. List it in `BattyThemeCatalog.battyThemes` in
   [`../BattyKit/Sources/BattyKit/Theme/BattyThemeCatalog.swift`](../BattyKit/Sources/BattyKit/Theme/BattyThemeCatalog.swift)
   — adding the `static let` alone is not enough; skipping this step
   means the theme silently never reaches `allThemes`.
3. If the theme is meant to be selectable in both appearances, ship a
   light companion following the light-palette conversion convention
   (see `issues/0310.md` for the worked example: slot 0 a
   near-background tint, slot 15 byte-equal to the foreground, slots
   9–14 repeating 1–6 rather than brightening). The companion is
   usually named `<Name> Day`, but that suffix isn't mandatory —
   `BattyThemes.swift` ships `Weird Science` / `Weird Science Night`,
   where the *light* variant is the primary form and keeps the plain
   name while the dark companion takes the modifier. Preserve whatever
   naming was authored; don't force every pair into `<Name> Day`.
4. Add or extend tests in
   `BattyKit/Tests/BattyKitTests/BattyThemeCatalogTests.swift`.
5. `scripts/build.sh unit` — the new theme name appears in the Theme
   menu, Settings picker, Command Palette, and Theme Selector
   immediately; no package change, no revision bump, no
   `Package.resolved` update.

**To pick up new themes from upstream Ghostty:**

1. In the upstream `Lakr233/libghostty-spm` checkout, run
   `Script/generate-themes.sh` against the updated Ghostty theme dump.
   This regenerates `Themes_<Letter>.swift` and
   `Themes/ThemeCatalog_Generated.swift` wholesale — do not hand-edit
   either.
2. Bump the `revision:` field for `libghostty-spm` in
   `BattyKit/Package.swift` to the new upstream commit SHA.
3. Resolve `BattyKit/Package.resolved` by running an Xcode build (or
   `swift package resolve` inside `BattyKit/`).
4. New upstream theme names appear in the catalog on next launch. No
   further Batty code change is needed.

**Out of scope (file a separate issue if you want any of these):**

- User-supplied `.toml` / `.ghostty` themes from
  `~/Library/Application Support/Batty/themes/` or `~/.config/ghostty/themes/`.
  The `ThemeStore.userThemeURLs` code in `Theme.swift` already
  contemplates the second path but is not wired into the active
  selection flow.
- Per-session or per-tab theme overrides. The current model is a
  single app-wide theme; the per-tab data flow assumes that.
- Theme editing UI inside Batty.
- Light/dark-mode-aware theme pairs that swap with system appearance.
  `TerminalTheme` already has the slots; the current
  `toTerminalTheme()` puts the same `TerminalConfiguration` into
  both. Honouring `NSApp.effectiveAppearance` here is a future
  enhancement.

---

## Quick answer key for new contributors

- *Where is the active theme stored?* — In `UserDefaults` under
  `co.sstools.Batty.themeName` (`ThemePreference.defaultsKey`). The
  value is the theme's display name.
- *What happens if I delete a theme that's currently selected?* —
  Catalog lookup returns `nil`, `TabRuntime.activeTheme()` falls back
  to `TerminalTheme.default`, and the next new tab uses the default.
  Existing surfaces keep whatever they had last applied — Batty does
  not actively reconcile them when the catalog changes. Re-selecting
  any theme from the menu fixes both.
- *How do I add a theme?* — If it's a Batty-original theme, add it
  directly in `BattyKit/Sources/BattyKit/Theme/BattyThemes.swift` and
  list it in `BattyThemeCatalog.battyThemes` — no fork, no package
  revision bump. If it's from upstream Ghostty's set, regenerate the
  upstream package and bump the `revision:` in `BattyKit/Package.swift`.
  See section 10.

---

*Document version: 3 — 2026-08-05. Corrected section 2/8/10 and this
answer key: the "catalog is read-only at runtime" premise from the
first `#0310` attempt was false — `GhosttyThemeDefinition`'s public
memberwise init lets Batty construct original themes on its own side
via `BattyThemeCatalog`, with no fork and no dependency change. Also
added section 9 (global theme and session-local overrides) in the
prior revision.*
