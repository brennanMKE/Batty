# Bell Feed capture log

An opt-in, local-only log of every Bell event's raw input next to the text
Batty showed for it, so the Bell Feed can be tuned on real data (#0523).
#0524 adds `rating` records to the same file.

## Turning it on

Settings → Advanced → Diagnostics → **Capture Bell Feed data**. Off by
default in every build. With it off, the bell paths do no capture work: no
process lookup, no writer call, no file or directory touched. **Reveal
Capture File in Finder** and **Clear Capture** work whether it is on or off.
Clear deletes both generations after an in-view confirmation.

The file holds notification text, Tab and Session titles and working
directories. Terminal output can contain secrets. The file stays on this Mac
and is never sent anywhere.

## File

- `~/Library/Application Support/<Batty | Batty Beta>/bell-feed-capture.jsonl`
  (directory from `SessionNameCache.resolvedDirectoryName`).
- UTF-8 JSON Lines: one object per line, `\n`-terminated, keys sorted.
- Written by a serial queue off the main actor (`BellCaptureWriter`). A write
  failure is logged (`BellFeedCapture` category) and otherwise ignored.

### Rotation

When the current file reaches 1000 records or 10 MB, whichever comes first,
it is renamed to `bell-feed-capture.1.jsonl` (replacing any older one) and a
new current file starts. Every record type counts toward the 1000. About two
generations survive.

## Schema

Every record has `schema` (integer, currently `1`), `type`, `recordID`
(fresh UUID), `entryID` and `capturedAt` (ISO 8601 UTC). **Bump `schema` on
any breaking change** (removed or retyped field, changed meaning); adding a
field is not breaking. Optional fields are always present, as explicit `null`.

### Join rules

`entryID` is the `BellFeedEntry.id` the Bell Feed shows. A collapsed repeat
(#0298) writes its own `event` record carrying the **surviving** entry's id,
not the discarded incoming one. A `summary` or `rating` record joins to its
`event` records by `entryID`; one entry can therefore have several `event`
records (`collapse.collapsed == true` after the first) and at most one
`summary`. A `summary` is written only if its `event` was captured, and always after it in
the file. Ordering holds because the summarization `Task` is main-actor
isolated and cannot start until the synchronous enqueue of the `event` has run,
and both go through one serial queue. **Clear Capture** bumps a writer
generation; a `summary` scheduled before the clear is dropped on the queue, so
it never lands in the fresh file without its event. The one remaining case is
a summary that outlives a rotation past two generations (a 1000-record burst
while one model call is in flight), which would leave an orphan `summary` in
the current file; analysis should ignore a `summary` with no matching `event`.

### `type: "event"` (one per Bell event, every occurrence)

| Field | Type | Notes |
|---|---|---|
| `appVersion`, `appBuild` | string, null | Bundle short version and build |
| `windowID`, `sessionID`, `paneID`, `tabID` | UUID | |
| `trigger` | string | `bel`, `oscNotification`, `cliNotification` |
| `message` | string, null | Raw OSC 9/777 body or CLI `title\nbody`; null for a bare BEL. Capped at 16384 characters |
| `messageTruncated` | bool | `message` was cut at the cap |
| `tabTitle` | string | `terminal.title` |
| `tabLabel` | string | Override-aware label the UI shows |
| `sessionTitle` | string | |
| `foregroundProcess` | object, null | `{pid: int, name: string?, executablePath: string?}`; null when libghostty reports no pid |
| `workingDirectory` | string, null | |
| `screen` | [string], null | Last lines of the viewport. **Always null today**, see below |
| `screenUnavailableReason` | string, null | `unsupportedByTerminalHost` when `screen` is null |
| `seenAtCreation` | bool | Tab was focused in the key window |
| `battyActive`, `sessionMuted`, `systemNotificationsEnabled`, `notifierPresent` | bool | Gate facts from the `BellDecisionRecord` |
| `collapse` | object | `{collapsed: bool, repeatCount: int, firstOccurrenceAt: ISO date}` of the surviving entry |
| `notification` | object | `{outcome: "submitted" \| "suppressed", reason: string?}`; reasons are `nilNotifier`, `sessionMuted`, `systemNotificationsDisabled`, `frontmostAndSeen`, `collapsedIntoUnread` |
| `notificationTitle`, `notificationBody` | string, null | Exact strings `BellNotifier.post` uses; null when suppressed |
| `feedRowPath` | string | Row path label |
| `feedRowText` | string, null | `summary ?? message` at record time (the summary is not there yet for a new entry); null when empty, as the row shows nothing then |
| `summarization` | string | `scheduled`, `skippedNoSummarizer`, `skippedDisabled`, `notApplicableCollapsed` |

`notification` is taken from the same `BellDecisionRecord` that goes into the
in-memory decision history; the gates are not recomputed.

### `type: "summary"` (one per scheduled summarization, written when it ends)

| Field | Type | Notes |
|---|---|---|
| `instructions`, `prompt` | string, null | Exactly what was sent to the model; null if it never got that far |
| `rawReply` | string, null | Model reply before sanitizing |
| `status` | string | `ok`, `none` (model said NONE), `rejectedBySanitize`, `modelUnavailable`, `error`, `cancelled`, `timedOut` (reserved, never produced today) |
| `errorDescription` | string, null | For `error` |
| `elapsedSeconds` | number | Wall time of the summarizer call |
| `sanitizedSummary` | string, null | What `NotificationSummary.sanitize` kept |
| `feedRowText` | string, null | Row text after the update; null if the entry left the feed |

An app quit before the model replies leaves an `event` with no `summary`.
That is expected.

### Screen text

`screen` is null because Batty has no route to the terminal's text. The
pinned libghostty-spm keeps `TerminalSurface` and the `ghostty_surface_t`
internal and exposes no read API on `TerminalView`. Reading the viewport
needs an upstream change (expose `readViewportText()`) or another way to get
the surface handle.

## Example queries

Raw message next to the final row text:

```sh
jq -c 'select(.type=="event") | {trigger, message, feedRowText, notification: .notification.outcome}' \
  "$HOME/Library/Application Support/Batty/bell-feed-capture.jsonl"
```

Summaries the model produced versus what the row ended up showing:

```sh
jq -c 'select(.type=="summary") | {entryID, status, rawReply, feedRowText}' bell-feed-capture.jsonl
```
