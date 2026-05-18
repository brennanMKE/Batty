# Panes and Splits

A **pane** is a rectangular region inside a session that holds a tab bar and a terminal area. Every session starts with a single pane. Split it once and you have two side-by-side; split either of those again and you have three. The arrangement is a tree of left/right and top/bottom regions, as deep as you care to go.

## Creating a split

- `Cmd-D` — split the focused pane horizontally; a new pane appears to the right.
- `Cmd-Shift-D` — split the focused pane vertically; a new pane appears below.
- The pane toolbar has split-horizontal and split-vertical buttons that do the same thing for the mouse.

The new pane inherits the focused pane's working directory. If you split while sitting in `~/Developer/Batty`, the new pane's shell also starts in `~/Developer/Batty` — no `cd` needed.

## The focused pane

Only one pane in a session is focused at a time. Keyboard input goes there, and so do split, new-tab, and close-tab actions. The focused pane is marked with an accent-colored border; the others dim slightly so the active region is unmistakable at a glance.

## Moving focus between panes

- `Cmd-Option-←`, `Cmd-Option-→`, `Cmd-Option-↑`, `Cmd-Option-↓` — focus the pane in that geometric direction. If two panes are stacked vertically, `Cmd-Option-↓` jumps down; if they're side-by-side, `Cmd-Option-→` jumps right.
- Click anywhere inside a pane — the tab chip, the terminal body, even empty padding — to focus it. No need to aim for a specific target.

## Resizing splits

Drag the divider between two panes. The cursor switches to a resize handle as you hover. Drag past the divider's natural travel and one side shrinks toward a minimum size — useful when you want to temporarily give a pane most of the window without closing its neighbor.

## Closing a pane

`Cmd-W` closes the active tab in the focused pane. The close cascades: when a pane's last tab closes, the pane itself closes and its sibling absorbs the freed space. When the shell exits naturally — you type `exit` or press Ctrl-D — the tab closes the same way, and the pane follows if that was the last tab.

## Pane vs tab vs session

- **Tab** when you want a parallel context in the same view — one shell and one `vim`, switched with `Cmd-1`, `Cmd-2`.
- **Pane** when you want both contexts visible at once — tests streaming on the left, editor on the right.
- **Session** when you want a fully separate workspace — a different project, a different toolchain. See [Sessions](02-sessions.md).

More on tabs in [Tabs](04-tabs.md); the full binding list lives in [Keyboard Shortcuts](05-shortcuts.md).
