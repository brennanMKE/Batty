# Where Reminders live: design spec

Date: 2026-11-15. Follow-up to #0631 (Quick Reminder bar, squash `cafbae32`). Code read at `main` = `6b8dfde7` (#0633 and #0634 have landed; #0635 is still open). Paths are under `BattyKit/Sources/BattyKit/` unless they start with another folder.

Mockups: `index.html` and `option-A.html` to `option-F.html` in this folder. They are static HTML approximations with no scripts, spot-checked by a Quick Look render of the top of each page; they are not screenshots of Batty.

This spec has two parts. Options A to C put Reminders in the Bell Feed (the first request). Options D to F give Reminders their own toolbar button and keep them out of the Bell Feed (the follow-up request); they are in "Part 2" at the end, with the comparison and the overall recommendation.

## The request

User, verbatim: "Reminders is causing layout problems. And I don't think we should be shoving new content where the session title is anyway. Kick off a subagent with Fable to prepare a better design. I feel like the Bell Feed would be a better place to show upcoming or past reminders."

What the screenshots showed:

1. A Session row with a pending Reminder grew to three lines (title, text, "in 15 min") with a clock glyph at the trailing edge.
2. After the Reminder went away the row shrank, and a disclosure chevron was left drawn over the next row.

## Part 1 recommendation (among A to C): Option A

See Part 2 for the overall recommendation, which is Option D if a second toolbar button is acceptable.

Pending Reminders are pinned in an **Upcoming Reminders** section at the top of the Bell Feed. A fired Reminder stays an ordinary Bell Feed row, now with the text first and Remind Again / Done actions. The Sidebar Session row keeps one fixed 16 pt glyph in the trailing badge area and never changes height. The Quick Reminder bar is unchanged.

Why A over B and C:

- It does what the user asked with no extra click: opening the Bell Feed shows upcoming and fired Reminders at once.
- It needs no new store state. Pending Reminders are already on `SessionRuntime.reminder`; fired ones are already `.reminder` entries.
- B hides a pending Reminder behind two steps and adds a history list that works against the declutter goal. C hides the text of a pending Reminder behind a disclosure.

## Things that hold in every option

- **The Session row is a fixed height in every state.** Nothing is drawn under or beside the title. The `heightOfRowByItem` / `noteHeightOfRows` mechanism is deleted (removal list below).
- **The Quick Reminder bar stays as shipped**, including edit mode (Keep <time>, Remove Reminder).
- **Entry points that stay:** ⇧⌘R, Session ▸ Remind Me… / Edit Reminder… / Cancel Reminder, the same items in the Sidebar row's context menu, the Command Palette, `batty session remind`.
- **Entry point that goes:** a click on the Sidebar row's Reminder lines.
- **Fired Reminder lifetime is unchanged where it already works:** a visit to the Session removes its Reminder rows (`Runtime/WindowRuntime.swift:1346-1348`, #0556).
- **No new toolbar button.** The existing bell button is the only toolbar affordance.
- **Semantic colours only:** `.primary`, `.secondary`, `Color.accentColor` or the Theme accent the row already receives, `.red` for the destructive Cancel only where a label is shown. The popover uses the system popover material, so it is correct in light and dark with no extra work. The Sidebar glyph uses `.secondary` (pending) and the row's `accent ?? Color.accentColor` (fired), the same values `ReminderBadge` and `DueReminderAlarm` use today (`Views/SessionSidebarView.swift:456-466`, `:525-534`), so see-through and themed Sidebars are already covered.

## Option A in detail

### Bell Feed layout (popover stays 360 x 420, `Views/BellFeedView.swift:87`)

```
Bell Feed                                   Clear All
-----------------------------------------------------
Upcoming Reminders                                  2
 (clock) Check on ./build.sh unit           in 12 min
         Session 1 · 3:45 PM
 (clock) Review the release notes…           tomorrow
         Batty · tomorrow at 9:00 AM
Recent
 ● (alarm) Check the deploy finished…       2 min ago
           api · due 3:31 PM
           [Remind Again in 15 Minutes] [In 1 Hour] [Done]
 ● api › Pane 1 › claude ×3                     5 min
   Claude is waiting for your input
```

**Upcoming Reminders section**

- Shown only while at least one Session has a pending Reminder. Section header "Upcoming Reminders" with the count at the trailing edge. The "Recent" header over the normal list appears only when the Upcoming section does.
- Source: every `SessionRuntime.reminder` across `store.windows`, with its Session. No new stored state; a computed list on the store is enough.
- Order: soonest due first (`SessionReminder.fireDate(calendar:)`, `Model/SessionReminder.swift:53`).
- Row, text first:
  - Leading `clock` glyph, `.secondary`.
  - Line 1: the Reminder's text (`displayText(sessionTitle:)`, `Model/SessionReminder.swift:42`), callout weight medium, one line, tail-truncated. Trailing: relative time, caption, `.secondary`.
  - Line 2: `<Session title> · <clock phrase>`, caption, `.secondary`.
  - Tooltip: the full text and absolute time.
- Relative time: reuse `ReminderFormat.relativeLine(due:now:)` (`Model/SessionReminder.swift:205`): "in N min" up to an hour, then the clock phrase. Draw it inside `TimelineView(.everyMinute)` as the Sidebar lines do today (`Views/SessionSidebarView.swift:506-511`), so nothing writes observed state per minute. When the relative label is already a clock phrase, shorten the trailing label to "tomorrow" or the weekday and leave the full phrase on line 2.
- At most 3 rows; a "Show N More" row expands the rest for as long as the popover is open. One Reminder per Session keeps this short in practice.
- Never has an unseen dot and never counts toward `unseenCount`. A pending Reminder is not something the user missed.
- Clear All does not touch this section.

**Fired ("past") Reminder rows**

- Still a `.reminder` `BellFeedEntry` in the normal newest-first list, never collapsed (`Runtime/AppStateStore+Reminders.swift:313-348`).
- Row change from today (`Views/BellFeedView.swift:198-236`): lead with the text instead of the word "Reminder" plus the Session title.
  - Unseen dot, `alarm` glyph in the accent colour.
  - Line 1: text, up to 3 lines. Trailing: "N min ago" (`ReminderFormat.dueLine` wording without the "due" prefix, or the existing `Text(timestamp, style: .relative)`).
  - Line 2: `<Session title> · due <time>`.
  - Line 3, on hover or when the row is selected: `Remind Again in 15 Minutes`, `In 1 Hour`, `Done` as small bordered buttons.
- When it leaves the Feed:
  - The Session is visited (click the row, Return, the notification, selecting the Session). Unchanged.
  - **Remind Again** is chosen: a new pending Reminder is set with the same text and the fired row is removed. It reappears in Upcoming. Today the notification's Remind Again marks the entry seen and keeps it (`Runtime/AppStateStore+Reminders.swift:71-86`); with an Upcoming section a kept row would show the same Reminder twice, so both paths should remove it.
  - **Done** is chosen: the row is removed without visiting the Session.
  - The Session closes. Unchanged.
- Clear All keeps today's meaning: marks it seen, the row stays until one of the above (`Runtime/AppStateStore.swift:2424`, `Concepts.md:281`).

**Row actions**

| Action | Upcoming row | Fired row |
|---|---|---|
| Open Session | click, Return | click, Return (also acknowledges, as today) |
| Edit Reminder… | pencil button on hover, context menu, `E` | not offered (nothing pending) |
| Cancel Reminder | x button on hover, context menu, Delete | not offered |
| Remind Again in 15 Minutes / 1 Hour | not offered | inline buttons, context menu, `R` = 15 minutes |
| Done | not offered | inline button, context menu, Delete |

- **Edit** closes the popover, makes the Session's Window key, then calls `ReminderActions.openBar(for:in:)` (`Views/ReminderMenu.swift:31`). It does not change the selected Session; the bar already names its Session. The write to `reminderBarSessionID` is event-origin (a click or key press), which the observation rules allow. The popover must be dismissed before the sheet is presented; #0635 (the bar opening while another sheet is up) is the neighbouring bug and should land first or with this.
- **Cancel** calls `store.cancelReminder(forSessionID:)` (`Runtime/AppStateStore+Reminders.swift:116`), with no confirmation, the same as the menu item.
- **Open Session** on an upcoming row selects the Session and leaves its focused Pane and active Tab alone, the same rule a fired Reminder row follows (`Concepts.md:281`).
- **Remind Again** from a row follows the rule #0633 set for the notification action: it does nothing when the Session has a newer pending Reminder (`Runtime/AppStateStore+Reminders.swift:81-84`). The row's buttons should be disabled in that case rather than silently ignored.

**Empty states**

- No bells, some pending: the Upcoming section, a separator, and a one-line "No bell events" in `.secondary`. The full-height `ContentUnavailableView` (`Views/BellFeedView.swift:41-47`) shows only when both are empty.
- The header's Clear All shows only when there are Feed entries, as today (`Views/BellFeedView.swift:142`).

### Sidebar

Keep exactly one fixed-size glyph in the row's trailing badge area, next to the unseen-bell count:

- Pending: `clock`, `.secondary`.
- Fired and unacknowledged: `alarm.fill`, accent.
- Otherwise nothing, and no reserved space.

Rules:

- The glyph sits in a fixed 16 x 16 frame inside the existing `HStack` (`Views/SessionSidebarView.swift:349-366`). It can shorten a long title by 20 pt, as the unseen count already does; it can never change the row's height.
- It is a plain image with a tooltip, not a button. Today the clock is a borderless `Button` that opens the bar (`:457-464`). A second click target inside a row that is itself a selection target is easy to hit by accident, and Edit is one right-click or ⇧⌘R away.
- Tooltip unchanged: "Reminder at 3:45 PM — <text>" (`ReminderActions.detail`, `Views/ReminderMenu.swift:53`; due form at `Views/SessionSidebarView.swift:539-546`).
- The row's accessibility value keeps its `, reminder pending: …` / `, reminder due` suffix (`:331-340`, `:393`). The UI tests read it and it does not depend on what is drawn.

Why keep anything: a Reminder belongs to a Session, and the Sidebar is where the user picks Sessions. Without a mark the only way to learn which Session has one is to open the Feed. The fired glyph is the Reminder's version of the unseen-bell badge. The cost is a 16 pt image in a slot that already exists.

### Toolbar bell

- Glyph logic unchanged: `bell.badge` when `unseenCount > 0`, else `bell` (`Views/SessionDetailView.swift:416`). A fired Reminder is an unseen entry, so it already turns the badge on. A pending Reminder does not change the glyph: the badge means "you missed something".
- Tooltip gains the pending summary: "Bell Feed (⌘⇧B) · 2 Reminders, next at 3:45 PM". The accessibility value gets the same words.
- The tooltip today reads "Bell Feed (⌘⇧N)" (`Views/SessionDetailView.swift:420`), but the default binding is ⌘⇧B (`Shortcuts/ShortcutAction.swift:157-158`); ⌘⇧N is New Window (`:167-168`). Fix it while editing this line, ideally from the live binding.

### Keyboard (popover has focus)

- Up / Down move through one selection that spans Upcoming then Recent. Today `moveSelection` walks `store.bellFeed.entries` only (`Views/BellFeedView.swift:129-135`); it needs one combined ordered list of row ids.
- Return: Open Session. Escape: close.
- `E`: Edit Reminder… (upcoming row). Delete: Cancel Reminder (upcoming) or Done (fired). `R`: Remind Again in 15 Minutes (fired).
- Unmodified keys are proposed because ⌘-chords are claimed by the main menu before `onKeyPress` sees them. The List's type-select must not swallow `E` and `R`; verify in the VM.
- Initial selection: the first unseen Feed entry if there is one, else the first row. Opening the Feed should land on what was missed, not on a pending Reminder.

### Accessibility identifiers for UI tests

| Identifier | Element |
|---|---|
| `bell-feed.upcoming` | the Upcoming Reminders section header; value = count |
| `bell-feed-upcoming.<Session title>` | an upcoming row; value = `reminder pending: <phrase> — <text>` from `ReminderActions.detail` (scheduler clock, so the manual-clock UI tests can assert on it) |
| `bell-feed-upcoming.edit.<Session title>` | the row's Edit button |
| `bell-feed-upcoming.cancel.<Session title>` | the row's Cancel button |
| `bell-feed-upcoming.more` | "Show N More" |
| `bell-feed-entry.<uuid>` (existing, value `reminder`) | a fired row; keep |
| `bell-feed-reminder.again15.<uuid>`, `bell-feed-reminder.again60.<uuid>` | Remind Again buttons |
| `bell-feed-reminder.done.<uuid>` | Done |
| `bell-feed.toolbar-button` | the bell button, if it has no identifier yet; value = the pending summary |

Session title keys match the Sidebar's `session-row.<title>` convention (`Views/SessionSidebarView.swift:392`). Existing `bell-feed-path.*`, `bell-feed-message.*` and `bell-feed-reminder-detail.*` stay on the fired row.

VoiceOver: an upcoming row reads "Reminder, <text>, <Session>, <phrase>"; Edit and Cancel are exposed as custom actions on the row as well as buttons.

## Option B: Bells | Reminders segments

- The Bell Feed header gains a segmented control inside the popover: **Bells** and **Reminders**, each with a count.
- **Bells** is today's list with `.reminder` entries filtered out.
- **Reminders** has three groups: **Due** (fired, unacknowledged, with Remind Again / Done), **Upcoming** (as in A), **Earlier Today** (Reminders acknowledged this launch, dimmed, last 10, each with Remind Again).
- Opens on Reminders when a Reminder is due and unseen, otherwise on the last-used segment. ⌘1 / ⌘2 switch segments.
- Sidebar: nothing. Toolbar bell: unchanged, no pending signal.
- For: the bell list never moves for a Reminder; a real history of past Reminders.
- Against: a pending Reminder is two steps away and invisible elsewhere; needs new store state for the history; Earlier Today is exactly the "seen rows stay out" clutter the declutter goal removes; ⌘1 / ⌘2 inside the popover compete with Session selection.

## Option C: collapsed summary strip

- One line pinned at the top of the Feed: "(clock) 2 upcoming Reminders · next in 12 min ›". A click or Right Arrow expands it in place to the rows from A; Left Arrow collapses. Collapsed each time the popover opens.
- Fired Reminders are ordinary Feed rows, as in A.
- Sidebar: only the fired `alarm.fill` glyph; nothing for pending.
- Toolbar bell: unchanged.
- For: least space in the Feed and Sidebar; one row however many are pending.
- Against: the text is not visible at a glance, which is the point of the note; one more piece of state and an unusual control in a popover list.

## What to remove from #0631's Sidebar work

Code:

- `Views/SessionSidebarOutline.swift:13-24`: `SidebarRowMetrics` (the whole enum).
- `Views/SessionSidebarOutline.swift:65`: `context.coordinator.baseRowHeight = outline.rowHeight`.
- `Views/SessionSidebarOutline.swift:113-118`: `baseRowHeight` and the `reminderLines` snapshot.
- `Views/SessionSidebarOutline.swift:144-147`: the `dueSessionIDs` / `previousLines` / `reminderLines` block in `apply`. This also drops the outline update's dependency on `bellFeed.dueReminderSessionIDs` and every Session's `reminder`.
- `Views/SessionSidebarOutline.swift:187-196`: the `grown` index set and `outline.noteHeightOfRows(withIndexesChanged:)`.
- `Views/SessionSidebarOutline.swift:226-231`: `outlineView(_:heightOfRowByItem:)`. The outline goes back to the uniform `.medium` row height it had after #0627.
- `Views/SessionSidebarView.swift:348` and `:367-374`: the `VStack` wrapper and the `ReminderLines` mount in `SessionSidebarRow.body`; the body is the `HStack` again.
- `Views/SessionSidebarView.swift:471-521`: `ReminderLines` (the struct, its tap gesture and tooltip).
- `Views/SessionSidebarView.swift:449-469`: `ReminderBadge` becomes a fixed-frame image (Option A) or is deleted with `DueReminderAlarm` at `:523-547` (Option B).
- `Views/SessionSidebarView.swift:591-592`: the `SessionRowMenu` comment that mentions Reminder lines.

Keep: `ReminderFormat.relativeLine` and `dueLine` (`Model/SessionReminder.swift:203-235`). The Feed rows reuse them; only their doc comments ("The Sidebar's caption…") change. Keep `BellFeedStore.dueReminderSessionIDs` and `unseenReminderEntries(forSessionID:)` (`Runtime/BellFeedStore.swift:207-218`, `:381`) if the Sidebar glyph stays.

Tests:

- `BattyKit/Tests/BattyKitTests/SessionDetailLayoutConvergenceTests.swift:268`: `sidebarReminderLinesGrowAndShrinkConverge` goes.
- `BattyUITests/SessionReminderTests.swift:366`: `testClickingTheSidebarReminderLinesOpensEditMode` goes; replace with an edit-from-the-Feed test.
- `BattyUITests/SessionReminderTests.swift:384`: `testRightClickOnTheReminderLinesOpensTheContextMenu` goes (a right-click on the row is already covered by `testCancelRemovesTheBadgeAndNothingFiresLater`, `:403`).
- The tests that read `reminderState` from the row's accessibility value (`:38-46`) keep working unchanged.

Docs:

- `Concepts.md:71`: drop "or Reminder lines".
- `Concepts.md:166`: drop "While a Reminder is pending or due the row grows by two lines…".
- `Concepts.md:254`: Bell Feed contents gain the Upcoming Reminders section.
- `Concepts.md:276`: drop "a click on the row's Reminder lines".
- `Concepts.md:277`: drop "and the Sidebar row's text line".
- `Concepts.md:280-281`: Remind Again and Done remove the entry.
- `BattyKit/Sources/BattyKit/Help/06-notifications.md:50`: replace the Sidebar-lines sentence with the Bell Feed.
- `issues/0631.md` user decision 8 (`:224`) is superseded; record that in the new issue, not by editing #0631.

## About the stale chevron

The leftover chevron appeared after a row shrank, and the only height change in the outline is the `noteHeightOfRows` call that `apply` makes from the representable's update (`Views/SessionSidebarOutline.swift:187-196`). That makes it the likely cause, but I did not reproduce it or trace it. Removing variable row heights removes the trigger either way. If a chevron artifact is ever seen again with fixed heights, it is a separate bug in the disclosure positioning restored by #0627.

## Open questions, with a default for each

1. **Sidebar glyph for a pending Reminder?** Default: yes, the fixed `clock` (Option A). Alternative: fired-only (C) or nothing (B).
2. **Is the Sidebar glyph clickable?** Default: no; tooltip only.
3. **Click on an upcoming row: Open Session or Edit?** Default: Open Session, for consistency with every other Feed row; Edit is the pencil, the context menu and `E`.
4. **Remind Again removes the fired row?** Default: yes, from the Feed button and the notification action. This changes "marks the entry seen and kept" (`Concepts.md:280`).
5. **Does Clear All remove fired Reminder rows?** Default: no; it marks them seen, as today. Done removes one row.
6. **Cap on upcoming rows?** Default: 3, then "Show N More".
7. **Does the bell glyph change for a pending Reminder?** Default: no; tooltip and accessibility value only.
8. **Feed keys `E`, `R`, Delete.** Default: as specified, subject to a VM check that type-select does not take them.
9. **A "past Reminders" history after acknowledgement (B's Earlier Today)?** Default: no. "Past" means fired and not yet dealt with; the declutter goal keeps acknowledged rows out.
10. **A Remind Me… entry inside the Bell Feed for the selected Session?** Default: no; ⇧⌘R and the menus cover it, and the Feed is for reading.
11. **Sequencing with #0635.** #0633 and #0634 have landed. Default: land #0635 first; Edit from a popover presents the bar and touches the same path.

---

# Part 2: Reminders on their own toolbar button (Options D, E, F)

User, verbatim: "Should we consider keeping Reminders out of the Bell Feed and instead add another icon next to the bell in the top right for Reminders? Show me designs for this approach."

The "no new toolbar buttons" rule is being reconsidered by the user for this, so one new toolbar item is in scope.

## Overall recommendation: Option D

If a second toolbar button is acceptable, build D instead of A. If it is not, A stands.

- A Reminder and a bell are different things. A bell is something a terminal did that the user missed. A Reminder is something the user wrote, with a future time. Option A needed a special case for each place they met: upcoming rows that are never unseen, Clear All skipping them, one selection spanning two lists, a fired row removed on Remind Again so it is not shown twice. D has none of these.
- The declutter goal is served better: the Bell Feed ends up with fewer rows than today, not more.
- The button is a visible home for New Reminder… and for checking what is pending. A has no such place.
- The costs are real: one more toolbar button and shortcut, two icons to check after being away, and a larger build than A because fired Reminders move out of the Bell Feed's store.

E is the fallback if D's build is too large for 1.4.0: it needs the same model work but almost no view work, and its menu can be swapped for D's popover later. F is not recommended.

## What D, E and F share

### The toolbar item

- **Glyph and states** (hierarchical rendering, like the bell at `Views/SessionDetailView.swift:416-418`):

  | State | SF Symbol | Colour |
  |---|---|---|
  | No Reminders | `alarm` | normal toolbar tint |
  | At least one pending, none fired | `alarm.fill` | normal toolbar tint |
  | At least one fired and not dealt with | `alarm.waves.left.and.right.fill` | accent |

  All three names are in `Resources/SFSymbolNames.txt:401-412`. The alarm family matches the Quick Reminder bar's glyph. No count is drawn on the button; counts are in the tooltip and the accessibility value. Fired wins over pending when both exist.
- **Placement:** immediately left of the bell, inside the same `ToolbarItemGroup` (`Views/SessionDetailView.swift:203-233`), so the bell keeps the corner position it has today. Order becomes: Split Horizontally, Split Vertically, Reminders, Bell Feed.
- **Its own view struct**, like `BellFeedToolbarButton` (`Views/SessionDetailView.swift:404-432`), so a Reminder change re-renders only this button and not `SessionDetailView.body`.
- **Tooltip:** "Reminders (⌥⌘R)", then the state: "· 2 upcoming, next at 3:45 PM" or "· 1 due, 2 upcoming". Build the shortcut text from the live binding.
- **Shortcut:** a new `ShortcutAction` (`toggleReminders`, "Show Reminders"), appended after `remindMe`, default **⌥⌘R**. No default in `Shortcuts/ShortcutAction.swift:102-184` uses ⌥⌘R, and the hard-coded menu shortcuts (`Commands/BattyCommands.swift:305-320`, `:765`) do not either. It pairs with ⇧⌘R (Remind Me…). Add the menu item beside Toggle Bell Feed (`Commands/BattyCommands.swift:329`), a case in `Commands/BattyShortcuts.swift` next to `:184`, and a Command Palette row.
- **Existing bug to fix in the same change:** the bell's tooltip says "Bell Feed (⌘⇧N)" (`Views/SessionDetailView.swift:420`). The Bell Feed's default is ⌘⇧B (`Shortcuts/ShortcutAction.swift:157-158`) and ⌘⇧N is New Window (`:167-168`).
- **Narrow window / toolbar overflow:** not verified. I did not find a minimum Window width or test what the bell's popover does today when its item is pushed into the overflow menu. Trailing items overflow first, so the bell would go before Reminders. A popover has no anchor once its button is in the overflow menu; E's pull-down menu does not have this problem because an overflowed menu becomes a submenu. For D, check the bell's current behaviour in the VM and make Reminders match it.
- **Accessibility identifiers:** `toolbar.reminders` (the convention of `toolbar.split-horizontal`, `Views/SessionDetailView.swift:215`), with value `none`, `2 upcoming` or `1 due, 2 upcoming`. The bell has no identifier today; add `toolbar.bell-feed` while there.

### Fired Reminders leave the Bell Feed entirely

Confirmed as the design: a fired Reminder records no Bell Feed entry and does not turn on `bell.badge`. The System notification is unchanged for the user (same title, subtitle, body and actions).

What has to change:

1. **New store state for fired Reminders.** A small observable list owned by the store, for example `firedReminders: [FiredReminder]` with the Reminder id, Session id, Window id, note, set time, due time and fired time. In-memory only, like the Feed. Pending Reminders stay on `SessionRuntime.reminder`.
2. **`fireReminder`** (`Runtime/AppStateStore+Reminders.swift:313-348`): stop building a `BellFeedEntry(kind: .reminder …)` and calling `bellFeed.record(entry)` (`:337`); append to the fired list instead.
3. **`BellNotifier`** (`Runtime/BellNotifier.swift`): `postReminder(entry:reminderID:projectID:sessionTitle:)` takes a `BellFeedEntry` in the protocol (`:37`), the no-op notifier (`:52`) and the real one (`:175`), and `reminderContent` / `reminderUserInfo` read the entry's `message`, `reminderSetAt`, `reminderDueAt`, `timestamp`, `id` and `sessionID` (`:229-262`). Change all of them to take the fired-Reminder value. The userInfo stops carrying `entryIdUserInfoKey` (`:255`) for Reminders; it already carries the Reminder id and Session id.
4. **Notification tap routing** (`Runtime/AppStateStore+Reminders.swift:213-222`, `:225-245`): a Reminder tap can no longer resolve through `.jumpToEntry(entryID)`. Add a route keyed on the Reminder id / Session id that makes the Window key and selects the Session, which is what `jumpToReminderEntry` does today (`Runtime/WindowRuntime.swift:1331`).
5. **`remindAgain`** (`Runtime/AppStateStore+Reminders.swift:71-86`): replace `markBellSeen(id: entryID)` with removing the fired record.
6. **`BellFeedStore`** (`Runtime/BellFeedStore.swift`): remove `Kind.reminder` (`:59-61`), `reminderSetAt` / `reminderDueAt` (`:65-69`, `:96-97`, `:112-113`, `:117`, `:142-143`), `dueReminderSessionIDs` (`:207-218`), `unseenReminderEntries(forSessionID:)` (`:381`), `removeReminderEntries(forSessionID:)` (`:389`) and the Reminder note in `removeEntries(matchingTabIDs:)` (`:402`). `unseenCount` then counts bells only, which is what stops a Reminder lighting `bell.badge` (`Views/SessionDetailView.swift:416`). `BellFeedEntry` is `Codable`; check whether the capture log (#0523) needs `kind` kept as a decode-only field.
7. **Callers of those** move to the fired list: Session removal (`Runtime/WindowRuntime.swift:426`), `jumpToBellEntry`'s Reminder branch (`:1307-1310`), the visit path (`:1348`), `markSelectedSessionReminderEntriesSeen` (`:1360`, `:1388-1393`), Window close (`Runtime/AppStateStore.swift:530`) and the store-level jump (`:2461-2463`).
8. **`BellFeedView`** (`Views/BellFeedView.swift`): delete `reminderBody` and `secondaryLine` (`:194-245`), `ReminderEntryAccessibility` (`:60`, `:288-300`) and the Reminder branch of `pathLabel` (`:163-165`). The Feed view goes back to one row type.
9. **Sidebar** reads move from `store.bellFeed.dueReminderSessionIDs` (`Views/SessionSidebarView.swift:336`, `:367`, `:465`) to the fired list.
10. **Tests:** `AppStateStoreReminderTests` and `BellFeedStoreTests` assert on `.reminder` entries in many places; `BattyUITests/SessionReminderTests.swift:139-150` (`reminderEntryIDs`) finds fired Reminders through `bell-feed-entry.*` rows. All move to the new list and popover.
11. **Docs:** `Concepts.md:254` (the Feed holds one kind of entry again), `:272-283` (Reminder: where it shows, firing, acknowledging), a mention of the Reminders toolbar button and its shortcut, and `Help/06-notifications.md`.

Everything in "What to remove from #0631's Sidebar work" in Part 1 applies unchanged to D, E and F.

### When a fired Reminder leaves the Due list

There is no seen / unseen state. A fired Reminder is in the Due list until one of:

- the Session is visited (click the row, Return, the notification's Open Session, selecting the Session in the Sidebar or by ⌘1–9), as today;
- **Done** is chosen;
- **Remind Again** is chosen (it becomes a new pending Reminder);
- the Session closes.

Opening the popover does not clear anything, and there is no Clear All. The toolbar glyph rings for as long as the Due list is not empty.

## Option D: Reminders button and popover (recommended)

**Popover**, 360 x 420, the Bell Feed's size, anchored to the Reminders button.

```
Reminders                              + New Reminder…
------------------------------------------------------
Due                                                  1
 (alarm) Check the deploy finished…          2 min ago
         api · due 3:31 PM
         [Remind Again in 15 Minutes] [In 1 Hour] [Done]
Upcoming                                             2
 (clock) Check on ./build.sh unit            in 12 min
         Session 1 · 3:45 PM              (pencil) (x)
 (clock) Review the release notes…            tomorrow
         Batty · tomorrow at 9:00 AM
------------------------------------------------------
↩ Open Session   E Edit   ⌫ Cancel            ⇧⌘R New
```

- **Sections:** Due first (most recently fired first), then Upcoming (soonest first). A section with no rows is not shown.
- **Rows:** as specified for Option A, text first, then `<Session> · <time>`, relative time trailing. Due rows use the accent `alarm` glyph and an accent trailing time; they have no unseen dot. Relative times are drawn in `TimelineView(.everyMinute)`.
- **Row actions:**

  | Action | Due row | Upcoming row |
  |---|---|---|
  | Open Session | click, Return (removes the row) | click, Return |
  | Remind Again in 15 Minutes / 1 Hour | inline buttons on hover or selection, context menu, `R` = 15 minutes | not offered |
  | Done | inline button, context menu, Delete | not offered |
  | Edit Reminder… | not offered | pencil on hover, context menu, `E` |
  | Cancel Reminder | not offered | x on hover, context menu, Delete |

  Edit closes the popover and opens the Quick Reminder bar in edit mode for that Session (`ReminderActions.openBar(for:in:)`, `Views/ReminderMenu.swift:31`). Remind Again is disabled when the Session has a newer pending Reminder (the #0633 rule).
- **New Reminder…** in the header: closes the popover and opens the Quick Reminder bar for the Window's selected Session, the same as ⇧⌘R (`ReminderActions.openBar(in:)`, `Views/ReminderMenu.swift:37`). When that Session already has a pending Reminder the bar opens in edit mode, as every entry point does. Disabled with no selected Session.
- **Empty state:** `ContentUnavailableView` with the `alarm` glyph, "No Reminders", "Set one on a Session to be brought back to it later.", and a "New Reminder for <Session>…" button showing ⇧⌘R.
- **Keyboard:** Up / Down across Due then Upcoming, Return, Escape, `E`, `R`, Delete as in the table; ⇧⌘R works from the popover because it is a menu shortcut. Initial selection: the first Due row, else the first Upcoming row.
- **Sidebar:** keeps the fixed 16 pt glyph from Option A (`clock` pending, `alarm.fill` fired). The popover says which Sessions have Reminders, but the glyph says it without opening anything, and the fired glyph matches the ringing toolbar button.
- **Accessibility identifiers:** `reminders.list`, `reminders.new`, `reminders.empty`, `reminders-due.<Session title>`, `reminders-upcoming.<Session title>` (value `reminder pending: <phrase> — <text>` from `ReminderActions.detail`, or `reminder due`), and on rows `.again15`, `.again60`, `.done`, `.edit`, `.cancel` inserted after the prefix, for example `reminders-upcoming.edit.<Session title>`.

## Option E: Reminders pull-down menu

- The toolbar item is a SwiftUI `Menu` with the same three glyph states.
- Items: **New Reminder for <Session>…** (⇧⌘R), then a "Due" section and an "Upcoming" section. Each Reminder is a two-line item (text; `<Session> · <time>`) with an alarm or clock image and a submenu.
  - Due submenu: Open Session, Remind Again in 15 Minutes, Remind Again in 1 Hour, Done.
  - Upcoming submenu: Open Session, Edit Reminder…, Cancel Reminder.
- With no Reminders: New Reminder… and a disabled "No Reminders".
- Times are computed when the menu opens; they do not tick while it is open.
- Sidebar: the fired `alarm.fill` glyph only.
- Identifiers: `toolbar.reminders`, `menu.reminders.new`, `menu.reminders.due.<Session title>`, `menu.reminders.upcoming.<Session title>`, and `.open`, `.again15`, `.again60`, `.done`, `.edit`, `.cancel` on the submenu items.
- For: least view code; native keyboard, VoiceOver and overflow behaviour; the model work is the same as D so D can replace it later.
- Against: every action is two levels deep; text is cut to one line; no hover actions; reads as a utility menu rather than a list.

## Option F: the button appears only while Reminders exist

- The toolbar item is present only while a Reminder is pending or fired. With none, the toolbar is exactly today's.
- Popover as D, without New Reminder… and without an empty state.
- Sidebar: nothing; the button's presence is the signal.
- For: no toolbar cost for people who do not use Reminders.
- Against: items appearing and disappearing move the split buttons; nowhere discoverable to create a Reminder; a toolbar whose structure follows model state needs care under `docs/swiftui-observation-rules.md`. Not recommended.

## A against D and E

| | A · Upcoming section in the Bell Feed | D · Reminders button and popover | E · Reminders menu |
|---|---|---|---|
| Where a pending Reminder is read | Bell Feed, top section | Reminders popover | Reminders menu |
| Where a fired Reminder is found | Bell Feed list; lights the bell badge | Reminders popover; the Reminders button rings; bell untouched | Same as D |
| Bell Feed rows | More than today | Fewer than today: no Reminder rows | Same as D |
| Toolbar | No change | One more button | One more button |
| New Reminder… entry | None in the Feed | Popover header and empty state | First menu item |
| Special cases between bells and Reminders | Upcoming rows never unseen, skipped by Clear All, one selection over two lists | None | None |
| Build size | Medium: views only, no new store state | Largest: fired-Reminder state, notification routing, popover, shortcut, test rewrites | Medium: D's model work, little view work |
| Places to look after being away | One | Two | Two |
| Keeps the "no new toolbar buttons" rule | Yes | No | No |

## Open questions for Part 2, with a default for each

1. **Alarm or clock glyph family for the button?** Default: alarm (`alarm` / `alarm.fill` / `alarm.waves.left.and.right.fill`). The alternative `clock` / `clock.badge` mirrors `bell` / `bell.badge` but has only two states.
2. **Left or right of the bell?** Default: left, so the bell does not move.
3. **Shortcut.** Default: ⌥⌘R, rebindable.
4. **Does a fired Reminder also flag the bell?** Default: no. That is the point of the split.
5. **Sidebar glyph with D?** Default: keep both states, as in A.
6. **Is there a Clear All for Due?** Default: no; Done per row. Due lists are short.
7. **Toolbar overflow.** Default: match whatever the bell does today, after checking it in the VM.
8. **D now or E first?** Default: D. E only if the 1.4.0 schedule needs the smaller view change.
