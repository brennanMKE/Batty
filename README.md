# Batty

See **[Batty](https://batty.sstools.co)** website for the free download.

Batty is a native macOS terminal multiplexer built on [libghostty](https://github.com/ghostty-org/ghostty). Sessions in a sidebar, splits and tabs, a bell-driven notification feed, and Ghostty-quality rendering — without tmux's complexity.

## What it is

Batty gives you multiple terminal sessions organized in a left-side sidebar, each with panes (splits) and per-pane tabs. It's the 20% of tmux most developers actually use, with a real native GUI on top.

- **Sessions sidebar** — named workspaces for different projects or contexts
- **Splits and tabs** — Cmd-D / Cmd-Shift-D to split; Cmd-T / Cmd-W / Cmd-1–9 for tabs
- **Bell feed** — catch background activity and jump straight to the source terminal
- **Layout selector** — apply a preset pane layout with Cmd-Shift-L
- **Theme selector** — switch Ghostty themes live with Cmd-Shift-T
- **Persistence** — sessions, splits, and tabs come back on relaunch
- **Keyboard-first** — every action has a shortcut; fully customizable in Settings

## Requirements

- macOS 15.6 or later
- Apple Silicon or Intel Mac

## Building

```bash
xcodebuild -scheme Batty -destination 'platform=macOS' build
open Batty.xcodeproj
```

## License

See [LICENSE](LICENSE).
