# Tabs

A **tab** is a single terminal — one running shell with its own scrollback — inside a pane. Every [pane](03-panes.md) has at least one tab. The strip along the top of the pane shows each tab as a chip, with the active one highlighted. When you type, the active tab is what you're typing into.

## Creating a tab

- `Cmd-T` adds a tab to the focused pane.
- Click the `+` button at the right end of the tab strip for the same result.

New tabs inherit the **working directory** of the tab that was active when you opened them. Add a tab while sitting in `~/Developer/Batty` and the new shell starts in `~/Developer/Batty` — no `cd` needed.

## Switching tabs

- Click a chip.
- `Cmd-1` through `Cmd-9` jump to the Nth tab in the focused pane.
- `Cmd-Shift-[` and `Cmd-Shift-]` step to the previous and next tab. Both wrap around the ends.

## Reordering tabs

Drag a chip left or right within the same strip. Dragging across panes isn't supported in this release.

## Tab titles

The chip picks a short label using the first rule that applies:

1. The name you set with **Rename**, if any.
2. The display name of a known TUI running in the tab — Claude Code, vim, htop, and friends. (Planned; lands with the writer-side signal.)
3. The shell's emitted title with any `user@host:` prefix stripped and the path prettified, so `~/Developer/Batty` becomes `Batty`.
4. The basename of the current working directory when the shell hasn't published a title.
5. A plain `Tab N` fallback.

## Renaming a tab

Right-click the chip and choose **Rename**. The placeholder shows the title the shell is currently emitting, but the input starts empty. Type a name and press Return to pin it — the chip keeps that name regardless of what the shell does later. Submit an empty value and the override clears, returning the tab to auto-titling.

Right-click and choose **Reset Title** to clear an existing override without opening the dialog.

## Closing a tab

- `Cmd-W` closes the active tab in the focused pane.
- Click the chip's `×` — visible on hover, and always visible on the active chip.
- Type `exit` (or Ctrl-D at a bare prompt). The tab closes when the shell process exits.

Closing cascades. The pane closes when its last tab closes; the [session](02-sessions.md) closes when its last pane closes; the window closes and Batty quits when its last session closes.

## Context menu

Right-click a chip for **Rename**, **Reset Title**, **Duplicate Tab**, **Close Tab**, and **Close Other Tabs**. Duplicate Tab opens a fresh tab in the same pane, starting in the same working directory as the original.

## Unseen bells

When a tab you aren't looking at emits a `\a` bell, a small accent-colored dot appears on its chip. Visit the tab and the dot clears. The bell itself still lands in the [bell feed](06-notifications.md) with a timestamp, so a flurry of background activity is recoverable even after the dot is gone.

For the full binding list, see [Keyboard Shortcuts](05-shortcuts.md). For when to reach for a tab versus a split versus a whole new session, see [Panes and Splits](03-panes.md).
