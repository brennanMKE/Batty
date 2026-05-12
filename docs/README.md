# Batty docs

Topical guides for engineers working on Batty. Read these alongside the
top-level project documents at the repo root (`PRD.md`, `Concepts.md`,
`CLAUDE.md`, `batty-getting-started.md`).

## Available

- [`view-hierarchy.md`](view-hierarchy.md) — how the model hierarchy
  (Workspace -> Window -> Session -> Pane -> Tab -> Terminal Session) maps
  onto the SwiftUI tree and the persistent AppKit terminal host. Read this
  first before touching anything in the terminal / pane / window path.
- [`shortcuts.md`](shortcuts.md) — keyboard shortcut routing,
  persistence, the recorder UI, reserved combos, and why menu
  shortcuts aren't the load-bearing path. Read this before touching
  `BattyShortcuts`, the NSEvent monitor in `BattyAppDelegate`, or the
  Settings → Shortcuts pane.
- [`nsviewrepresentable-state-persistence.md`](nsviewrepresentable-state-persistence.md)
  — patterns for keeping `NSView` state alive across SwiftUI rebuilds. The
  load-bearing reference for the terminal host architecture.
- [`delegate-plumbing.md`](delegate-plumbing.md) — historical decision doc
  for unblocking the `TerminalSurfaceViewDelegate` gap in
  `Lakr233/libghostty-spm`. Records Path C (fork the package) as the chosen
  unblock; relevant when re-evaluating the `brennanMKE/libghostty-spm`
  fork relationship.

## Upcoming

- `themes.md` — theme loading, search paths, applying live changes (`#0078`).
- `notifications.md` — bell capture pipeline, feed, system notifications (`#0079`).
