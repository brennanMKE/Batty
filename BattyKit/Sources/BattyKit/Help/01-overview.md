# Overview

Batty is a native macOS terminal multiplexer built on libghostty. You get the speed and rendering of Ghostty plus a sidebar of named workspaces, splits and tabs inside each, and a bell-driven feed that pulls your attention to background activity. Think of it as the small set of tmux features you actually use, in a real Mac UI.

Batty opens in a **single window** by default. Sessions, panes, tabs, terminals, and notifications all live inside that one window — the single-window flow is the one to learn first.

## The four-level hierarchy

You navigate four nested things, from outside in:

1. **Sessions** — named workspaces listed in the left sidebar. One per project or context. See [Sessions](02-sessions.md).
2. **Panes** — rectangular regions inside a session, arranged by splits. Press `Cmd-D` to split side-by-side, `Cmd-Shift-D` to stack. See [Panes and Splits](03-panes.md).
3. **Tabs** — a strip of terminals along the top of each pane. `Cmd-T` adds one, `Cmd-W` closes. See [Tabs](04-tabs.md).
4. **Terminals** — the actual shell prompt inside each tab, where you type.

## Tour of the window

- **Sidebar** (left) — your session list. The `+` button adds a session. Right-click a row for Rename, Duplicate, Mute, or Close.
- **Tab bar** (top of each pane) — drag chips to reorder, click `×` to close, right-click for more.
- **Bell feed** — open with `Cmd-Shift-B` or the bell button in the toolbar. Recent bells from every tab; click an entry to jump to the source. See [Notifications](06-notifications.md).
- **Settings** — `Cmd-,`. Shell, font, cursor, theme, paste confirmation, per-session mute. See [Themes](07-themes.md) and the full binding list in [Keyboard Shortcuts](05-shortcuts.md). Dropping a file from Finder onto a pane pastes its quoted path — see [Drag and Drop](08-drag-and-drop.md).

## Try this

1. Type `pwd` and press Return.
2. Press `Cmd-D` to split the pane side-by-side.
3. Press `Cmd-T` to add a tab to the new pane.
4. Click `+` in the sidebar to add a second session.
5. Press `Cmd-Shift-B` to peek at the bell feed.

Five seconds in, you have the shape of the app.
