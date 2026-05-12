# Overview

Batty is a native macOS terminal multiplexer built on libghostty. It runs in
a single window by default and pairs the speed of Ghostty's renderer with a
session sidebar, splits, tabs, and a bell-driven notification feed.

## Concepts at a glance

Batty's UI is organized around a small vocabulary. Each term has a precise
meaning that's used consistently throughout the menus and this Help system.

- **Window** — the top-level macOS window hosting the app. Batty is a
  single-window app by default; multiple windows are supported but the
  sidebar and bell feed live in each window independently.
- **Session** — a named workspace listed in the sidebar. A Session contains
  one or more Panes arranged in a split layout. Switch sessions with
  Cmd-Option-1 through Cmd-Option-9.
- **Pane** — a rectangular region within a Session that hosts one or more
  Tabs. Panes are created by splitting horizontally or vertically. A Pane
  collapses automatically when its last Tab is closed.
- **Tab** — a single terminal inside a Pane. Each Tab wraps a live
  **Terminal Session** (a running shell). Tabs are switched with Cmd-1
  through Cmd-9 and managed with Cmd-T (new), Cmd-W (close), and the
  standard previous/next shortcuts.
- **Split** — the divider between two Panes inside a Session. Splits can
  be resized with the mouse or keyboard, and focus moves between adjacent
  Panes with the configured shortcuts.
- **Theme** — a Ghostty `.ghostty` color scheme. Themes are applied live
  via the **View → Theme** menu and persist across launches.
- **Bell Feed** — a popover that captures terminal bells (BEL + OSC 9)
  from every Tab. Click an entry to jump to the Tab that raised it.
- **Workspace** — the on-disk layout (Sessions, Panes, Tabs) that Batty
  serializes to `workspace.json` and restores on launch.

## Where to go next

The other sections in this Help describe each concept in more detail:

- **Sessions** — managing the sidebar list.
- **Panes and Splits** — creating, resizing, and navigating splits.
- **Tabs** — tab lifecycle and per-Pane tab bars.
- **Keyboard Shortcuts** — the full list of bindings.
- **Notifications** — the Bell Feed and system notification routing.
- **Themes** — installing and switching themes.
- **Drag and Drop** — dropping files onto a Pane.

Preferences and font/cursor settings live under **Batty → Settings…**.
