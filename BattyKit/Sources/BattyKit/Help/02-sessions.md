# Sessions

A **session** is a named workspace in the left sidebar. Each one has its own pane tree and its own tabs, fully independent — running `vim` in one session leaves the rest untouched. Most people keep one session per project, host, or task.

## Creating a session

- Click `+` at the bottom of the sidebar.
- Or press `Cmd-N` from anywhere.

New sessions inherit the **working directory** of the currently focused tab. If your active terminal is at `~/Developer/Batty`, the new session's first shell starts there too. With no focused session — for example on first launch — the new session opens at your shell's default (usually `$HOME`).

## Renaming a session

Right-click a session and choose **Rename**, then type a new name and press Return.

Batty also renames sessions automatically. Once you've named a session in a particular directory — say you called one "Batty" while it sat at `~/Developer/Batty` — Batty remembers that pairing. Next time a session's first shell lands in `~/Developer/Batty`, whether by creation, `cd`-ing in, or duplicating, the name "Batty" re-applies. The cache survives quit and relaunch.

## Reordering sessions

Drag a session up or down in the sidebar.

## Duplicating a session

Right-click and choose **Duplicate**. You get a fresh session with the same name suffixed `Copy`. The new session starts with a single empty shell — tabs and scrollback aren't carried over.

## Muting notifications

Right-click and choose **Mute Notifications** to silence desktop notifications for bells fired inside that session. The sidebar badge and the [bell feed](06-notifications.md) still update — you just won't get a Notification Center popup. Right-click again for **Unmute Notifications**.

## Closing a session

- Right-click and choose **Close**.
- Or press `Cmd-W` with a tab focused. `Cmd-W` cascades: it closes the active tab, then the pane when that was the last tab, then the session when that was the last pane.

When the last session in the window closes, Batty quits. After a session closes, focus jumps to the session immediately above it in the sidebar — not back to the top — so closing several in a row walks you up the list.

## Selecting a session

- Click a session row in the sidebar.
- Or press `Cmd-1` through `Cmd-9` to jump to the Nth session by position (default; swaps with `Cmd-Option-1`…`Cmd-Option-9` via Settings → General → Keyboard).

Sessions you aren't looking at stay alive: shells keep running, output keeps streaming, and bells keep firing into the [bell feed](06-notifications.md). Switching is instant.

## What's saved across launches

By default, Batty starts fresh every time — one session, one pane, one tab, one shell. The list of sessions from your last run is written to disk but isn't read back on launch, matching Terminal.app and Ghostty. The session-name cache (your directory-to-name pairings) does persist, so opening a session in a familiar directory still picks up the name you chose before.

For more on what lives inside a session, see [Panes and Splits](03-panes.md) and [Tabs](04-tabs.md). The full binding list is in [Keyboard Shortcuts](05-shortcuts.md).
