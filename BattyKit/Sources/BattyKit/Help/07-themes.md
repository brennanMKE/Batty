# Themes

A **theme** is the terminal color palette — background, foreground, and the sixteen ANSI colors your programs paint with. Pick one and every terminal in Batty repaints to match.

## Choosing a theme

Open the menu bar's **Theme** menu and click a name. A check mark marks the active theme.

The choice applies to **every open terminal immediately** — scrollback, running TUIs, the prompt you're staring at, all of it re-renders in place. No restart, no reopened tab. New tabs and new [sessions](02-sessions.md) inherit the same theme.

## Where themes come from

Batty ships with a catalog of community-curated themes — the same set Ghostty bundles. The list is baked into the app; you don't need to install or download anything.

## Switching via Settings

**Settings → Appearance** (`Cmd-,`) shows the same picker as the menu, alongside font size and cursor controls. Either path produces the same result; the Settings picker is purely a convenience.

## Persistence

Your theme choice is saved per-user. Quit Batty, relaunch, and you come back to the theme you left on.

## What's *not* a theme

A theme controls the terminal color palette only. It does **not** control:

- The **font** — set separately in **Settings → Appearance**.
- The **cursor style** (block, bar, or underline) and blink — also in **Settings → Appearance**.
- The **window chrome** — title bar and borders follow your macOS system appearance.

If you change the theme and the cursor or font stays put, that's working as intended.

## When a theme might not match what you expect

- Some TUIs — vim, neovim, htop — apply their own colors. When those colors reference ANSI palette slots, the theme is honored. When they hardcode hex values, the theme has nothing to override.
- Your shell prompt is styled by your shell config, not Batty. A theme changes which colors the prompt's escape codes resolve to; a prompt that explicitly demands "white background" still gets one.

## Adding your own themes

Custom user themes — dropping a theme file into a Batty support folder and seeing it appear in the menu — are a planned future feature, not in this release. For now, pick from the bundled catalog.

## Your theme over SSH

Connecting to a remote host doesn't disconnect your theme the way you might expect — but it depends on how the remote app draws its colors.

Programs that paint with the 16 standard ANSI colors (color slots, not fixed values) get resolved through Batty's active theme wherever they're running, local or remote — switch the theme and a remote program repaints instantly, with no reconnect. Programs that paint with 24-bit true color paint exact values instead, and your theme has nothing to override.

For example, neovim over SSH: turn `termguicolors` off and pick a colorscheme that mostly sticks to the 16 standard colors (`vim` is a good starting point) to have it follow your Batty theme. Turn `termguicolors` on for full true-color accuracy instead — but then the remote program's own palette wins, not Batty's.

`COLORTERM=truecolor` (the signal that tells a remote program true color is available) and a resolvable `TERM` are separate concerns from theme-following, and depend on your `ssh` client configuration reaching that remote host — they aren't automatic today.

For the rest of Settings, see [Keyboard Shortcuts](05-shortcuts.md) and [Notifications](06-notifications.md).
