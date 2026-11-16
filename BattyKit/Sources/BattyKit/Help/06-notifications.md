# Notifications

Long-running commands rarely finish in the tab you're staring at. Batty turns background activity into signals you can spot at a glance — and find later if you missed the moment.

## What counts as a bell

Two things ring Batty's bell:

- **Plain `\a` BEL** — any program that writes the ASCII bell byte. Most shells ring at the prompt; many TUIs ring on completion. **Test it:** type `printf '\a'` at a prompt, switch tabs, and watch the chip light up.
- **Desktop notifications via OSC 9** — a richer escape with a title and body. When the running program supports it, you get a real macOS notification with its own message.

## Where bells appear

A bell in a tab you're not looking at lights up in up to four places at once:

1. **A dot on the tab's chip** — a small accent-colored circle in the pane's tab strip.
2. **A badge on the session** in the sidebar — the count of unseen bells across all of its panes and tabs.
3. **A desktop notification** — a macOS banner, if enabled in Settings and the session isn't muted.
4. **A row in the bell feed** — timestamped, with the path `Session > Pane N > Tab` and any message body.

A bell from a muted session appears in none of these places (see below).

A bell in the tab you're looking at while Batty is in front shows nothing: no dot, no badge, no banner and no row in the feed — you saw it. If Batty is in the background, you get the banner and a row.

## Clearing notifications

Bells clear automatically when you visit the tab they rang in. Clicking the terminal or the chip, hitting a tab or session hotkey, jumping panes with `Cmd-Option-←/→/↑/↓`, clicking a session in the sidebar, clicking a feed row, or running `batty session|pane|tab focus` removes that tab's rows from the bell feed and decrements the sidebar badge to match. When focus lands on a tab only because something else closed, its bells are marked read and their rows stay.

For a fresh slate, choose **Window > Mark All Bells Read** (or **Mark All Read** in the bell feed's header). Every unread count zeroes and every feed row is marked read in one shot; the rows stay in the feed.

To tidy the feed, choose **Window > Clear Read Bells** (or **Clear Read** in the header). It removes every read row and leaves the unread ones.

## The bell feed

Press `Cmd-Shift-B` (or click the toolbar bell button) to open the bell feed popover. It lists the bells you didn't see when they rang, newest first.

- Click a row to jump to the tab — selection and focus follow automatically.
- Entries for closed tabs, panes, or sessions disappear on their own. You won't see a stale row pointing at something that's gone.

## Muting a session

Right-click a session row in the sidebar and choose **Mute Notifications**. While muted, the session's bells add nothing: no desktop notification, no row in the bell feed, no chip dot and no sidebar badge. Rows already in the feed when you mute stay, and visiting their tab removes them as usual. Right-click again for **Unmute Notifications**; bells that rang while muted don't come back. Reminders still fire for a muted session.

The bell *sound* isn't gated by per-session mute in this release; the app-wide **Play sound** toggle in Settings is the only sound control.

## Reminders

A Reminder brings you back to a session later, with a note saying why. Press `Cmd-Shift-R`, choose **Session > Remind Me…**, right-click a session in the sidebar, or pick **Remind Me…** in the Command Palette. Each opens the Quick Reminder bar:

- Type what you want to be reminded of. If a command is running, the field starts with "Check on <command>", selected, so typing replaces it. With nothing typed, the Reminder says "Come back to <session>".
- `Up` and `Down` choose a time, and `Return` sets the Reminder. `Cmd-1` to `Cmd-5` set In 5 Minutes, In 15 Minutes, In 30 Minutes, In 1 Hour or Tomorrow at once; `Cmd-6` opens **Pick Date & Time…** for any time between a minute and seven days ahead. `Esc` closes the bar without setting anything.
- While a session has a Reminder, a clock appears next to its name in the sidebar; hover over it to see the note and the time. Press `Cmd-Shift-R` again or choose **Edit Reminder…** to change it. **Keep <time>** changes only the note, and **Remove Reminder** cancels it. Each session has one Reminder.

When it's due, the macOS notification shows the note as its title and the session underneath. **Open Session** jumps to it; **Remind Again in 15 Minutes** and **Remind Again in 1 Hour** set a new Reminder with the same note, without bringing Batty forward, and leave nothing behind. A Reminder that comes due doesn't appear in the bell feed or light the bell; the session's sidebar row shows an alarm until you visit the session. A Reminder still notifies after you quit Batty, but that notification only offers Open Session.

From a terminal: `batty session remind "check CI" --in 5m`, or `batty session remind --at 17:30 "standup"` for later today.

## Settings

Open Settings with `Cmd-,` and pick **Notifications**:

- **Play sound** — the audible bell, app-wide.
- **Show system notifications** — the macOS banner, app-wide.
- A help row reminds you that per-session mute lives on the sidebar's right-click menu.

If banners don't appear even with both toggles on, check **System Settings > Notifications > Batty**. macOS has its own permission gate, and notifications stay silent until you allow them there.

See [Sessions](02-sessions.md) for muting, [Tabs](04-tabs.md) for the chip dot, and [Keyboard Shortcuts](05-shortcuts.md) for the full binding list.
