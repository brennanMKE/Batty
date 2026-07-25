# Batty docs

Topical guides for engineers working on Batty. Read these alongside the
top-level project documents at the repo root (`PRD.md`, `Concepts.md`,
`CLAUDE.md`, `batty-getting-started.md`).

## Available

- [`swiftui-observation-rules.md`](swiftui-observation-rules.md) — binding
  rules for state mutation with SwiftUI + Observation: view construction is
  pure, `onChange`/`onAppear` writes audited by trigger origin, observed-state
  ownership rules (`@State` / plain property / `@Bindable` / `@Environment` /
  `@ObservationIgnored`), notify-on-every-write semantics and dependency
  granularity, AppKit interop hazards (`NSHostingView` runs updates inside
  `-[NSView layout]`), and the single-authority pattern for two-way
  model ↔ AppKit sync. Read this before writing to any `@Observable`
  property from view-driven code, and before any change to focus or
  selection flow. `#0229` is the case study.
- [`multi-window-design.md`](multi-window-design.md) — the design source
  for multi-window support (#0234 umbrella): partitioned session ownership,
  one `TerminalHostView` per window, the `WindowGroup(for: WindowID.self)`
  scene, the `WindowRuntime` per-window state container, window-set
  restoration, the Shift-Cmd-N New Window action, termination semantics,
  and the per-phase regression-risk register. Read this before working any
  of the #0235–#0240 children.
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
- [`batty-cli-install.md`](batty-cli-install.md) — the as-built record of
  the `batty` CLI: the `BattyCLICore`/`BattyKit`/`batty` package target
  split, the exact argument surface and `batty://` URL it constructs today,
  the app-side `BattyURLHandler` routing, the "Embed CLI" Xcode build
  phase, `/usr/local/bin` installation via `CLIInstaller`, signing/
  notarization status, and current test coverage — traced end to end from
  a `batty <path>` invocation to a new Session. **Differs from
  [`cli-tool-install.md`](cli-tool-install.md)**, which is a prescriptive
  design survey of *supacode*'s installer plus a "replicate this for
  batty" plan written before (and only partially updated during)
  implementation — it still shows the CLI depending on the full `BattyKit`
  library and treats CLI↔app IPC as an open question, both of which the
  shipped code superseded (`BattyCLICore` split per `#0252`; `batty://`
  URL scheme per `#0250`/`#0257`). Read `batty-cli-install.md` for current
  behavior; read `cli-tool-install.md` only for supacode-comparison
  history.
- [`xpc/`](xpc/README.md) — vendored reference docs from the RemoteControl
  XPC prototype (`xpc-cli-architecture.md`, `cli-embedding-and-install.md`,
  `swift-concurrency-and-xpc.md`, `build-and-release.md`, `README.md`,
  `FINDINGS.md`), copied 2026-07-24 for the **#0265** umbrella (hybrid
  `batty://` + XPC transport). The four architecture/install/concurrency/
  release docs and their `README.md` are written for "a different app" —
  they mark what to rename and what to copy verbatim. `FINDINGS.md` is the
  exception: it's the experiment's own decision record, written *for*
  Batty, and its "Batty" references are genuine (`#0249`, the 372-test
  build-graph gate, `BattyKit`). Each file carries its own provenance
  header with the specifics; bare `#NNNN` references are RemoteControl's
  own issue numbers unless the header says otherwise. Read before starting
  any of #0265's XPC-track children (#0269–#0273) — the experiment's own
  hardest-won lesson was reading a sibling project's docs before
  implementing, not after.
