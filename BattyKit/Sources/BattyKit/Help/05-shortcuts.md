# Keyboard Shortcuts

Every shortcut Batty understands, how to change the ones you don't like, and the few combos that aren't yours to remap.

## Default shortcuts

### Sessions

| Action | Default |
|---|---|
| New Session | `Cmd-N` |
| Select Session 1–9 | `Cmd-1` … `Cmd-9` |

### Panes

| Action | Default |
|---|---|
| Split Horizontally | `Cmd-D` |
| Split Vertically | `Cmd-Shift-D` |
| Focus Pane Left | `Cmd-Option-←` |
| Focus Pane Right | `Cmd-Option-→` |
| Focus Pane Above | `Cmd-Option-↑` |
| Focus Pane Below | `Cmd-Option-↓` |

### Tabs

| Action | Default |
|---|---|
| New Tab | `Cmd-T` |
| Close Tab | `Cmd-W` |
| Show Previous Tab | `Cmd-Shift-[` |
| Show Next Tab | `Cmd-Shift-]` |
| Select Tab 1–9 | `Cmd-Option-1` … `Cmd-Option-9` |

### Other

| Action | Default |
|---|---|
| Toggle Sidebar | `Cmd-B` |
| Toggle Bell Feed | `Cmd-Shift-B` |
| Settings | `Cmd-,` |
| Help | `Cmd-?` |
| Copy | `Cmd-C` |
| Paste | `Cmd-V` |
| Quit | `Cmd-Q` |

See [Sessions](02-sessions.md), [Panes and Splits](03-panes.md), [Tabs](04-tabs.md), and [Notifications](06-notifications.md) for what each action does in context.

## Customizing shortcuts

Open **Settings → Shortcuts** with `Cmd-,`. Click any recorder field, press the new combo, and it saves immediately. Press `Esc` to cancel. Each row has a **Reset** button; the pane bottom has **Reset All to Defaults**.

Two inline warnings can appear under a recorder:

- **Collision** — another action already uses that combo. Both keep the binding; pick a unique one to avoid surprises.
- **Reserved by macOS** — the combo matches a system shortcut (`Cmd-Q`, `Cmd-H`, `Cmd-M`, `Cmd-Tab`, `Cmd-,`). Batty saves it so you can decide, but the system usually wins.

Customizations persist across launches.

## Fixed shortcuts

A few combos aren't customizable because they're positional or follow system conventions, and don't appear in the Shortcuts pane:

- `Cmd-1` … `Cmd-9` — select session 1–9 in the sidebar by default; swap with `Cmd-Option-1` … `Cmd-Option-9` via **Settings → General → Keyboard → "Cmd-1…9 switches"**.
- `Cmd-Option-1` … `Cmd-Option-9` — select tab 1–9 in the focused pane by default; swapped by the same preference.
- `Cmd-C` / `Cmd-V` — copy and paste, same as everywhere else on macOS.

## Why shortcuts work everywhere

Batty's shortcuts fire regardless of which view has keyboard focus — terminal, sidebar, tab strip, popover, bell feed. The app watches key events at the application level before they reach the menu bar or any individual view.

That's why `Cmd-N` inside a busy terminal creates a new session instead of being sent to the shell, and why `Cmd-W` closes the active tab even when you're typing into `vim`. Remap an action away from its default and the original combo falls back to whatever AppKit would normally do with it.

## What macOS keeps for itself

A handful of system shortcuts can't be overridden by any app and keep working regardless of Batty's settings:

- Mission Control and Spaces (`Control-↑`, `Control-←`, `Control-→`).
- Spotlight (`Cmd-Space`) and input-source switchers.
- Screenshot and screen-recording capture (`Cmd-Shift-3`, `Cmd-Shift-4`, `Cmd-Shift-5`).
- Force Quit (`Cmd-Option-Esc`).

If a Batty binding seems to do nothing, check System Settings → Keyboard → Keyboard Shortcuts first — a system binding is the most common culprit. See [Themes](07-themes.md) and [Drag and Drop](08-drag-and-drop.md) for the rest of Settings.
