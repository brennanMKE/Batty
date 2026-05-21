# Notifications

How a terminal bell becomes a user-visible signal in Batty. Read this
before touching anything in the bell-capture, bell-feed, or system
notification path. Companion to `Concepts.md` (vocabulary) and
[`view-hierarchy.md`](view-hierarchy.md) (where the live surfaces emit
the underlying events). Issues `#0068`, `#0069`, `#0071`, and the bell
feed's original landing are the history.

Batty's notification pipeline is a fan-out: one `\a` BEL (or one OSC 9 /
OSC 777 desktop notification) emitted by a terminal program produces up
to four user-visible signals, each gated on independent state. Anyone
touching the path needs to keep three things in mind:

1. **`AppStateStore` is the routing hub.** libghostty hands off to
   `TerminalViewState`; SwiftUI `.onChange` observers in `PaneView` push
   into `TabRuntime`; `TabRuntime` returns a delta to `AppStateStore`,
   which decides what to record, what to badge, and what to post.
2. **Focus is the gate on unseen counts.** A bell that lands on the
   tab the user is already looking at is recorded into the feed but
   does **not** bump any unseen counters. Anything off-focus does.
3. **Per-session mute affects only desktop notifications.** The bell
   feed entry is still recorded; the sidebar badge and chip dot still
   update. Mute suppresses the macOS banner / Notification Center post.

---

## 1. User-facing summary

When a terminal program rings the bell (writes `\a`) or fires a rich
desktop-notification escape (OSC 9 / OSC 777), Batty can produce four
signals:

1. **Chip unseen dot** — `BattyTabChip.hasUnseen` shows a small dot on
   the affected tab's chip in the tab bar of its pane.
2. **Sidebar session badge** — the session row in the sidebar shows a
   count of unseen bells across all of its panes and tabs.
3. **Bell-feed entry** — the bell feed popover (toggled with
   `Cmd-Shift-N`, or the toolbar bell button on `SessionDetailView`)
   gains a row with timestamp, the path `Session › Pane N › Tab`, and
   an optional message body (OSC 9 / OSC 777 payload).
4. **macOS desktop notification** — a banner / Notification Center
   entry, gated by **Settings → Notifications → "Show system
   notifications"** AND not per-session muted.

Clicking a feed entry calls `AppStateStore.jumpToBellEntry(_:)`: it
selects the session, focuses the pane, activates the tab, and marks the
entry seen.

Per-session mute lives on the **sidebar right-click menu** (per
`#0068`). "Mute Notifications" / "Unmute Notifications" toggles
`SessionRuntime.notificationsMuted`. While muted, desktop notifications
for that session are suppressed; the bell feed and sidebar/chip
indicators continue to update.

The bell feed header has a **"Clear All"** action that runs
`AppStateStore.markAllBellsSeen()` — every entry is flipped to seen and
every session/pane/tab aggregate is zeroed in one shot.

---

## 2. Trigger sources

Two distinct event kinds enter the pipeline:

- **Plain `\a` BEL** — emitted by any shell, build tool, REPL, or
  process that writes the BEL byte. libghostty surfaces this as
  `TerminalSurfaceBellDelegate.terminalDidRingBell()`, which increments
  `TerminalViewState.bellCount` and updates `lastBellAt`. No message
  body — these bells are anonymous.
- **OSC 9 / OSC 777 desktop notification** — apps that want a rich,
  titled notification can emit OSC 9 (iTerm2 convention) or OSC 777
  (rxvt-unicode convention). libghostty's
  `TerminalSurfaceDesktopNotificationDelegate` reports the title and
  body; `TerminalViewState.lastDesktopNotificationAt` /
  `lastDesktopNotificationTitle` / `lastDesktopNotificationBody`
  update.

Both event kinds are observed by `.onChange` modifiers in `PaneView` and
flow through `TabRuntime` into `AppStateStore`'s bell-routing methods.

---

## 3. The bell-feed pipeline

End-to-end, from libghostty to `UNUserNotificationCenter`:

```
   libghostty BEL                                  libghostty OSC 9 / OSC 777
          |                                                  |
          v                                                  v
TerminalViewState.bellCount++           TerminalViewState.lastDesktopNotificationAt
          |                                                  |
          | (PaneView .onChange)                             | (PaneView .onChange)
          v                                                  v
TabRuntime.recordBellTickIfNeeded       TabRuntime.recordDesktopNotificationIfNeeded
          |                                                  |
          | (returns Int delta)                              | (returns Bool fired)
          v                                                  v
AppStateStore.recordBellTick(forTabID:)   AppStateStore.recordDesktopNotification(forTabID:)
          |                                                  |
          |  locate(tabID:)  ->  BellLocation                |  locate(tabID:)  ->  BellLocation
          |                                                  |
          +--> BellFeedEntry created and recorded <----------+
          |   (BellFeedStore caps at 200, newest first)      |
          |                                                  |
          +--> propagateUnseen(at:) (skipped if isFocused) <-+
          |   bumps tab/pane/session unseenBellCount         |
          |                                                  |
          +--> postNotification(for:at:) <-------------------+
                          |
                          | (early-return if session.notificationsMuted)
                          v
                  BellNotifier.post(for:sessionTitle:paneIndex:tabLabel:)
                          |
                          | (early-return if Settings "Show system notifications" off)
                          | (early-return if app is active AND entry already seen)
                          v
                  UNUserNotificationCenter.add(request:)
                          |
                          v
                  macOS banner / Notification Center
```

A few important properties of this flow:

- **`recordBellTick` may run more than once per call.** libghostty
  coalesces multiple BEL bytes into a single delta on `bellCount`. The
  store loops `0..<delta` and records one `BellFeedEntry` per
  coalesced bell, so a process that bursts ten `\a`s shows up as ten
  feed rows.
- **OSC 9 / OSC 777 always produces exactly one entry per fire.**
  `recordDesktopNotificationIfNeeded()` returns `true` once per new
  `lastDesktopNotificationAt`; the body of the macOS notification is
  the `lastBellMessage` carried on the `TabRuntime`.
- **Entries record `seen: location.isFocused` at creation.** A bell
  delivered to the tab the user is already viewing lands in the feed
  as already-seen. Off-focus bells land as unseen.
- **`BellFeedStore` is capped at 200 entries.** Oldest entries are
  evicted when the cap is exceeded; see section 5 on auto-clear for
  how this interacts with `markActiveTabSeen()`.

Cross-references: see `BellFeedStore.record(_:)`,
`AppStateStore.recordBellTick(forTabID:surfaceID:windowID:)`,
`AppStateStore.recordDesktopNotification(forTabID:surfaceID:windowID:)`,
and the private `AppStateStore.locate(tabID:)` /
`propagateUnseen(at:)` / `postNotification(for:at:)` helpers.

---

## 4. The "is the user looking at this tab right now" gate

`AppStateStore.locate(tabID:)` walks every session/pane to find the
owning `TabRuntime` and computes a small `BellLocation` value:

```swift
let isFocused = session.id == selectedSessionID
    && session.tree.focusedPaneID == pane.id
    && pane.activeTabID == tab.id
```

All three conditions must hold for `isFocused == true`:

- The session must be the selected one in the sidebar.
- The pane must be the focused pane in that session's split tree.
- The tab must be the active tab in that pane.

The branching at the recording site:

| `isFocused` | `BellFeedEntry.seen` at insert | `propagateUnseen` | Unseen counters change? |
|---|---|---|---|
| `true` | `true` | skipped early-return | no |
| `false` | `false` | runs | `tab.unseenBellCount`, `pane.unseenBellCount`, `session.unseenBellCount` each `+= 1` |

`postNotification` does **not** depend on `isFocused` directly — it
runs in both branches. It's gated separately on
`session.notificationsMuted` (per-session) and, inside
`BellNotifier.post`, on `SettingsPreference.resolvedSystemNotifications()`
(app-wide). `BellNotifier.shouldPost(for:)` also suppresses a duplicate
banner if the app is already active AND the feed entry has already been
marked seen — see section 9 below.

---

## 5. Auto-clear when the user visits a tab

`AppStateStore.markActiveTabSeen()` is the "you looked at it, the
unread state is acknowledged" hook. It runs on every focus-changing
path so visiting a tab acknowledges its bells the way Mail, iMessage,
and Slack do (per `#0069`).

Call sites:

| Trigger | Wired in |
|---|---|
| Sidebar selection (`store.selectedSessionID` change) | `SessionDetailView.onChange(of: store.selectedSessionID)` |
| Focused pane change (`session.tree.focusedPaneID`) | `SessionDetailView.onChange(of: store.selectedSession?.tree.focusedPaneID)` |
| Active tab change (`pane.activeTabID`) | `PaneView.onChange(of: pane.activeTabID)` |
| Initial appearance | `SessionDetailView.onAppear` |

What the method does:

1. Resolves the now-active tab via `selectedSession.focusedPane` and
   its `activeTabID`.
2. Walks `bellFeed.entries`, picks every unseen entry whose `tabID`
   matches, and calls `markBellSeen(id:)` on each. `markBellSeen`
   flips the entry's `seen` flag and decrements
   tab/pane/session aggregates via the private `decrementUnseen(for:)`
   helper.
3. **Zeroes any residual `tab.unseenBellCount`.** Because
   `BellFeedStore` is capped at 200 entries, older entries can be
   evicted from the feed before they've been seen. The aggregate
   counters on `TabRuntime` / `PaneRuntime` / `SessionRuntime` would
   then point at entries that no longer exist. The residual sweep
   subtracts whatever `tab.unseenBellCount` was from the pane and
   session aggregates and resets the tab to zero.

The walk happens on `AppStateStore` (main actor) and mutates
observable counts that drive the chip dot and sidebar badge — both UI
elements update in the same frame.

---

## 6. Auto-cleanup when a tab, pane, or session closes

When a tab is closed, its bell-feed entries would otherwise point at a
tab that no longer exists. The cleanup path (per `#0071`) keeps the
feed coherent with the live model:

- `BellFeedStore.removeEntries(matchingTabIDs:)` — purges every entry
  whose `tabID` is in the supplied set and returns the removed entries.
- `AppStateStore.cleanUpBellState(forTabIDs:)` — calls
  `removeEntries(matchingTabIDs:)`, then loops over each removed entry
  that was still unseen and runs `decrementUnseen(for:)` so the
  tab/pane/session aggregates stay in sync.

Wired in:

| Code path | Tab IDs cleared |
|---|---|
| `AppStateStore.closeTab(id:)` | `{ tabID }` (the single tab being closed) |
| `AppStateStore.removeSession(id:)` | Union of every `tab.id` across every pane in the session |

The result: the feed never shows entries pointing at non-existent tabs,
and the aggregate counts never drift when tabs disappear out from
under unseen entries. `pathLabel(for:)` in `BellFeedView` would render
`(closed)` for an orphan entry, but in practice the cleanup ensures
that branch is rarely reached.

---

## 7. Per-session mute

Per `#0068`, each session carries a `notificationsMuted` flag:

| Where | What |
|---|---|
| `SessionRuntime.notificationsMuted: Bool` | Runtime state. `@Observable` via the surrounding class; defaults to `false`. |
| `SessionRuntime.notificationsMuted: Bool` (persisted side) | Runtime state only. Mute state does not survive a relaunch — each session starts unmuted. |
| Sidebar right-click → "Mute Notifications" / "Unmute Notifications" | The user-facing toggle. Lives in `SessionSidebarView`. |

The gate in `AppStateStore.postNotification(for:at:)`:

```swift
guard let notifier else { return }
guard !location.session.notificationsMuted else { return }
```

Behavior contract:

- **The bell-feed entry is still recorded.** Mute does not suppress
  the row in `BellFeedView`.
- **Unseen counts still update.** Chip dot and sidebar badge fire as
  usual.
- **The desktop notification is suppressed.** No banner, no
  Notification Center entry.
- **Sound is not gated by mute.** libghostty plays its bell sound
  internally and there is no app-level gate at the per-session
  level in v1. The app-wide "Play sound" toggle in
  Settings → Notifications controls whether the `UNNotificationContent`
  request carries `.default` sound; it does not stop libghostty from
  ringing in-surface.

Mute state does not survive a relaunch — each session starts unmuted on launch.

---

## 8. Settings

**Settings → Notifications** exposes two app-wide preferences (both
stored in `UserDefaults` via `SettingsPreference`):

| Toggle | Key | What it gates |
|---|---|---|
| "Play sound" | `SettingsPreference.bellSoundKey` | When on, `BellNotifier` sets `content.sound = .default` on the `UNMutableNotificationContent`. (Also controls libghostty's in-surface bell sound via `applyShellAndAppearancePreferences(to:)`.) |
| "Show system notifications" | `SettingsPreference.systemNotificationsKey` | When off, `BellNotifier.post` early-returns before constructing the request. No banner regardless of session mute state. |

A help row underneath reminds the user that **per-session mute lives
on the Session row's right-click menu**, since it isn't surfaced in
Settings (accurate as of `#0068`).

---

## 9. Bell feed UI

`BellFeedView` lives in `BellFeedView.swift` and is presented as a
popover anchored on either the toolbar bell button on
`SessionDetailView` or the `.battyToggleBellFeed` `NotificationCenter`
event (default shortcut `Cmd-Shift-N`, customizable in
Settings → Shortcuts; the menu item is in `BattyCommands`).

Layout:

- Fixed-size popover (`360 × 420`).
- Header: "Bell Feed" title plus a "Clear All" button that runs
  `AppStateStore.markAllBellsSeen()`. The button hides when the feed
  is empty.
- Body: `ContentUnavailableView("No bell events", systemImage:
  "bell.slash", …)` when empty; otherwise a plain `List` of
  `BellFeedRow`s in reverse-chronological order (newest first).

Each row renders the timestamp, the path label `Session › Pane N › Tab
Label`, and the optional `entry.message`. Unseen entries are
highlighted; seen entries are dimmed.

Interactions:

- **Tap a row** — `handleJump(to:)` calls `markBellSeen(id:)` then the
  caller-provided `onJump` closure, which routes to
  `AppStateStore.jumpToBellEntry(_:)` (selects session, focuses pane,
  activates tab).
- **Return key** — same as tap on the currently selected row, via
  `.onKeyPress(.return)`.
- **Path label for closed tabs** — `pathLabel(for:)` falls back to
  `"(closed)"` if the entry's session / pane / tab can't be resolved.
  In practice the cleanup path in section 6 makes this rare.

`BellNotifier.shouldPost(for:)` adds one more gate on the macOS-banner
side: if the app is currently active **and** the feed entry has already
been marked seen, the banner is suppressed. The rationale is that a
user with Batty in the foreground who has already clicked through to
the tab doesn't need a delayed banner for the same bell.

---

## 10. Where to look in the code

| File | Role |
|---|---|
| [`../BattyKit/Sources/BattyKit/BellFeedStore.swift`](../BattyKit/Sources/BattyKit/BellFeedStore.swift) | The entry log. `@Observable`, capped at 200, owns `record`, `markSeen`, `markAllSeen`, `unseenCount(forTabID:/forPaneID:/forSessionID:)`, `removeEntries(matchingTabIDs:)`. Also declares `Notification.Name.battyToggleBellFeed`. |
| [`../BattyKit/Sources/BattyKit/BellNotifier.swift`](../BattyKit/Sources/BattyKit/BellNotifier.swift) | `BellNotifying` protocol and the `UNUserNotificationCenter` implementation. Handles auth, the "Show system notifications" gate, the foreground-and-seen suppression, and the tap-to-jump delegate (`onTapEntry`). |
| [`../BattyKit/Sources/BattyKit/AppStateStore.swift`](../BattyKit/Sources/BattyKit/AppStateStore.swift) | The router. `recordBellTick`, `recordDesktopNotification`, `markBellSeen`, `markAllBellsSeen`, `markActiveTabSeen`, `jumpToBellEntry`, `closeTab` / `removeSession` (cleanup hooks), and the private `locate(tabID:)` / `propagateUnseen` / `postNotification` / `decrementUnseen` / `cleanUpBellState`. |
| [`../BattyKit/Sources/BattyKit/BellFeedView.swift`](../BattyKit/Sources/BattyKit/BellFeedView.swift) | The popover and `BellFeedRow`. Path-label formatting lives here. |
| [`../BattyKit/Sources/BattyKit/TabRuntime.swift`](../BattyKit/Sources/BattyKit/TabRuntime.swift) | `recordBellTickIfNeeded()` (returns `Int` delta), `recordDesktopNotificationIfNeeded()` (returns `Bool`), `bellCount` / `unseenBellCount` / `lastBellAt` / `lastBellMessage`. |
| [`../BattyKit/Sources/BattyKit/PaneView.swift`](../BattyKit/Sources/BattyKit/PaneView.swift) | `.onChange(of: tab.terminal.bellCount)` and `.onChange(of: tab.terminal.lastDesktopNotificationAt)` observers; also `.onChange(of: pane.activeTabID)` that calls `markActiveTabSeen()`. |
| [`../BattyKit/Sources/BattyKit/SessionDetailView.swift`](../BattyKit/Sources/BattyKit/SessionDetailView.swift) | `.onChange(of: store.selectedSessionID)` and `.onChange(of: store.selectedSession?.tree.focusedPaneID)` hooks calling `markActiveTabSeen()`. Also receives the `.battyToggleBellFeed` notification to present the popover. |
| [`../BattyKit/Sources/BattyKit/BattyTabChip.swift`](../BattyKit/Sources/BattyKit/BattyTabChip.swift) | The unseen-bell dot on tab chips. `hasUnseen` + `showsUnseenDot = hasUnseen && !isActive`. |
| [`../BattyKit/Sources/BattyKit/SessionRuntime.swift`](../BattyKit/Sources/BattyKit/SessionRuntime.swift) | `notificationsMuted` flag (observable). |
| [`../BattyKit/Sources/BattyKit/SessionSidebarView.swift`](../BattyKit/Sources/BattyKit/SessionSidebarView.swift) | Right-click "Mute Notifications" / "Unmute Notifications" toggle. |
| [`../BattyKit/Sources/BattyKit/LayoutModel.swift`](../BattyKit/Sources/BattyKit/LayoutModel.swift) | `Session.notificationsMuted` Codable field (`decodeIfPresent ?? false`). |
| [`../BattyKit/Sources/BattyKit/SettingsView.swift`](../BattyKit/Sources/BattyKit/SettingsView.swift) | `NotificationsSettingsView` — the "Play sound" + "Show system notifications" toggles plus the per-session-mute help row. |
| [`../BattyKit/Sources/BattyKit/BattyCommands.swift`](../BattyKit/Sources/BattyKit/BattyCommands.swift) | The "Toggle Bell Feed" menu item that posts `.battyToggleBellFeed`. |
| [`../BattyKit/Sources/BattyKit/BattyShortcuts.swift`](../BattyKit/Sources/BattyKit/BattyShortcuts.swift) | Dispatches `.toggleBellFeed` from the NSEvent monitor. |

---

## 11. Related issues and history

- The bell feed initially landed when `BellFeedStore` / `BellFeedView`
  were introduced (verify the exact issue number when stitching
  history). The shape captured here reflects the state after the
  follow-up issues below.
- `#0068` — Per-session mute. Added
  `SessionRuntime.notificationsMuted` and the sidebar right-click
  toggle; gated `postNotification` on the flag.
- `#0069` — Auto-clear on tab focus. Added `markActiveTabSeen()` and
  its three `.onChange` call sites, plus the residual
  `tab.unseenBellCount` sweep that handles entries evicted from the
  feed cap.
- `#0071` — Cleanup on tab/pane/session close. Added
  `BellFeedStore.removeEntries(matchingTabIDs:)` and
  `AppStateStore.cleanUpBellState(forTabIDs:)`; wired into
  `closeTab(id:)` and `removeSession(id:)`.

---

## Quick answer key

- *Why didn't my muted session's badge update?* — It should have.
  Mute only suppresses desktop notifications. The bell-feed entry is
  still recorded and the unseen counts (chip dot, sidebar badge) still
  cascade through `propagateUnseen`. If the badge truly didn't update,
  check whether the bell landed on the focused tab — focused bells
  insert with `seen: true` and skip `propagateUnseen` by design.
- *Why did the feed show an entry I can't click?* — The entry's
  `sessionID` / `paneID` / `tabID` no longer resolve to a live tab.
  This should be rare because `cleanUpBellState(forTabIDs:)` purges
  entries on tab close; if it happens, the tab was closed via a path
  that doesn't route through `closeTab(id:)` (worth filing).
- *Why didn't the desktop notification fire even though the sidebar
  badged?* — Three plausible gates: (a) Settings → Notifications →
  "Show system notifications" is off; (b) the session is muted via
  the sidebar right-click menu; (c) the app is active and the entry
  was already marked seen, so `BellNotifier.shouldPost(for:)`
  suppressed the duplicate. The sidebar badge fires independently of
  all three.
- *What's the keyboard shortcut for the bell feed?* — `Cmd-Shift-N` by
  default. Customizable at Settings → Shortcuts → "Toggle Bell Feed".
  See [`shortcuts.md`](shortcuts.md).
- *Where is mute persisted?* — It isn't. Mute state lives in
  `SessionRuntime.notificationsMuted` for the duration of the app session
  only; it resets to `false` on relaunch.

---

*Document version: 1 — 2026-05-12.*
