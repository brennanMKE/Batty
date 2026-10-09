# Apple Foundation Models in Batty

Batty uses Apple's on-device Foundation Models framework (Apple
Intelligence) for three small jobs:

| Feature | What it produces | Where it shows | Issue |
|---|---|---|---|
| Session auto-naming | a 2–4 word Session title | Sidebar Session row | #0231, #0232 |
| Tab auto-naming | a 2–4 word Tab name | Tab chip, and the Sidebar Pane row for a Pane's first Tab | #0260 |
| Bell summaries | a short phrase describing a bell notification | Bell Feed row | #0246 |

Settings toggles for these were added in #0233 (naming) and #0246
(summaries).

Every feature is **optional**. Batty works the same without the model:
when the model is unavailable, turned off, fails, or gives a poor answer,
the feature does nothing and the deterministic behavior stays in place.
No code path waits on the model before showing something to the user.

All inference runs on the device. Nothing is sent over the network.

## Availability and gating

The app's deployment target is macOS 15.6. Foundation Models needs macOS 26,
so availability is checked in layers:

1. **Compile time**: `#if canImport(FoundationModels)`. The code still
   builds with an SDK that doesn't have the framework.
2. **OS version**: the `makeIfAvailable()` factories return `nil` before
   macOS 26. `BattyApp.swift` wires the results into
   `AppStateStore.shared.nameSuggester` and `.notificationSummarizer`. If
   either is `nil`, that feature is off for the whole process.
3. **Model state, checked on every call**:
   `SystemLanguageModel.default.availability` must be `.available`. That
   covers Apple Intelligence being turned off and the model not yet being
   downloaded. Because the check runs on every call, turning Apple
   Intelligence on takes effect without relaunching Batty.
4. **User setting, checked on every call**:
   - Settings → General → Session Naming → "Use Apple Intelligence to
     suggest names" (`SettingsPreference.autoNameWithAIKey`). Controls
     both Session and Tab naming.
   - Settings → Notifications → Bell → "Use Apple Intelligence to summarize
     notifications" (`summarizeNotificationsWithAIKey`).

   Both default to **on**. Their `resolved…()` accessors return the default
   when the key has never been written. Before macOS 26 the toggles are
   disabled and show "Requires macOS 26". They check only the OS version,
   not whether the model is actually available.

## Code map

| File | Role |
|---|---|
| `BattyKit/Sources/BattyKit/ProjectName/SessionNameSuggester.swift` | `SessionNameSuggesting` protocol, `FoundationModelsNameSuggester`, the `readFile`/`setSessionName` tools, `SessionNameSuggestion.sanitize` |
| `BattyKit/Sources/BattyKit/ProjectName/NotificationSummarizer.swift` | `NotificationSummarizing` protocol, `FoundationModelsNotificationSummarizer`, `NotificationSummary.sanitize` |
| `BattyKit/Sources/BattyKit/Runtime/AppStateStore.swift` | Scheduling, cancellation, the in-memory cache, and applying results (Session, Tab, and bell) |
| `BattyKit/Sources/BattyKit/Util/TabTitleFormatter.swift` | Decides where the AI Tab name ranks among a Tab chip's title sources |
| `BattyKit/Sources/BattyKit/Runtime/BellFeedStore.swift` | `BellFeedEntry.summary`, and `updateSummary(_:forEntryID:)`, the only way a summary gets written |
| `BattyKit/Sources/BattyKit/Views/SettingsView.swift`, `Settings/SettingsPreferences.swift` | The toggles and their defaults |
| `Batty/BattyApp.swift` | Wires the suggester and summarizer into `AppStateStore` |

The rest of the app depends only on the two protocols, so tests can
substitute fakes, and the Foundation Models types stay confined to the two
`ProjectName/` files.

## Session and Tab naming

### Where the AI step fits

Naming is triggered when a Terminal Session's working directory changes.
`PaneView` wires `onWorkingDirectoryChange` to call
`AppStateStore.handleWorkingDirectoryChange(forTabID:)` (Session) and
`updateTabAutoName(for:)` (Tab), and also calls them once when that wiring is
set up.

For a **Session**, the AI is the last resort in a deterministic chain:

1. `SessionNameCache` hit (a name the user typed before for this
   directory).
2. Project-name rules (`ProjectNameResolver`), if "Name sessions from
   project files" is on.
3. Otherwise the default `Session N`. **Only here** does the AI step run.

Session naming only applies to single-Pane Sessions whose user hasn't
renamed them (`titleOverride == false`), and it follows only the anchor
Tab's directory. See #0213 for why multi-Pane Sessions are skipped.

For a **Tab**, every Tab in every Pane gets its own suggestion from its own
directory, unless the user renamed that Tab (`titleOverride != nil`). The
result goes into `TabRuntime.aiSuggestedName`. `TabTitleFormatter` ranks it
**below** a home-directory `~`, the running command, and the shell's own
title, and **above** the project name and the prettified path.

### The model call

`FoundationModelsNameSuggester.suggestName(forPath:)` creates a new
`LanguageModelSession` for each request, so no context is shared with any
other model use. It uses **tool calling**, added in #0232:

- The prompt contains the folder path and up to 20 non-hidden top-level
  entries, sorted, with `(folder)` after each directory.
- `readFile(fileName:)` returns up to the first 4 KB of **one top-level
  file from that listing**. Any other name is rejected, which rules out
  path traversal. It checks `isReadableFile` (`access(2)`) before
  `open(2)`, so it never triggers a macOS privacy (TCC) consent prompt. It
  returns short messages the model can act on for a directory, an empty
  file, a non-UTF-8 file, or a file it isn't permitted to read. The
  instructions tell the model to read at most 2–3 files.
- `setSessionName(name:)` saves the answer in a `SuggestedNameBox`. The
  first call wins, and later calls are reported back as ignored.
- The model's final text reply is **ignored**. If it finishes without
  calling `setSessionName`, that means "no good name" (temporary folders,
  hashes, untitled folders).

The same suggester serves both Session and Tab naming. Its protocol and
tools are named for Sessions only because Session naming came first.

### Validation and applying results

- `SessionNameSuggestion.sanitize` strips quotes and rejects `NONE`, empty
  names, names over 40 characters or 4 words, and anything other than
  letters, digits, spaces, `-`, and `_`.
- Results, including "no name", are cached per directory in
  `nameSuggestionMemo`. The cache holds at most 256 entries and is cleared
  when full. Session and Tab naming share it, so one model call covers
  every Tab in the same directory. It is **never persisted**: AI names are
  recomputed on each launch.
- Only one request per Session or Tab runs at a time
  (`nameSuggestionTasks`, `tabNameSuggestionTasks`). A repeat report of the
  same directory keeps the running request. A new directory cancels it and
  starts another.
- Results are applied only if nothing changed in the meantime. For a
  Session: it still exists, still has one Pane, hasn't been renamed, its
  directory is unchanged, and its title is still the default. For a Tab:
  no user rename and the same directory.
- An AI name **never** writes `SessionNameCache` or sets `titleOverride`.
  It carries the same weight as a rules-derived name: the next `cd`
  recomputes it, and only an explicit user rename is stored. A user rename
  cancels any request in progress. Reset Title, or committing an empty
  rename, starts Tab auto-naming again right away.

## Bell summaries

`FoundationModelsNotificationSummarizer.summarize(message:tabTitle:sessionTitle:)`
sends the OSC 9 message, if there is one, plus the Tab and Session titles
in a plain `LanguageModelSession` with no tools. The instructions ask for
one short phrase ("build failed: 3 errors", "tests passed"), or `NONE`.

- `AppStateStore.scheduleSummarization` runs after a bell entry is recorded.
  The entry appears in the Bell Feed immediately with its raw message
  ("Bell" for a plain BEL character). The summary is filled in later
  through `BellFeedStore.updateSummary`.
- `NotificationSummary.sanitize` strips quotes and rejects `NONE`, empty
  text, text over 120 characters, and control characters.
- `BellFeedView` displays `entry.summary ?? entry.message`. The summary is
  **not** used in the macOS system notification, which has already been
  posted by the time the model replies.

See [`notifications.md`](notifications.md) for the rest of the bell
pipeline.

## Rules for new uses

Follow the existing pattern when adding a model-backed feature:

- **Put it behind a protocol** in BattyKit, with a `makeIfAvailable()`
  factory that returns `nil` before macOS 26. Keep
  `import FoundationModels` inside `#if canImport(FoundationModels)`.
- **Never throw to the caller.** Return `nil` for "no answer" and log the
  reason with the file's `Logger`.
- **Show the deterministic result first** and treat the model's answer as a
  later improvement. The UI must be correct if the model never answers.
- **Sanitize every result** before it reaches any state the UI reads.
  Small models return quotes, too many words, and `NONE` in its various
  spellings.
- **Only apply a result if nothing changed** since the request started,
  and never overwrite an explicit user choice.
- **Use a new `LanguageModelSession` per request** unless shared context is
  the goal.
- **Use tools to limit what the model can reach.** Accept only names from a
  list you built yourself. Check permissions without triggering TCC
  prompts. Cap how much of a file is read.
- **Gate it with a Settings toggle**, checked on every call.
- **Write results to observed state only from the completion of a `Task`
  started by an event**, never from view code. See
  [`swiftui-observation-rules.md`](swiftui-observation-rules.md).

## Testing

The model itself is never run in unit tests. The logic that doesn't depend
on it is kept separate so it can be tested on any machine:

- `SessionNameToolTests.swift`: `readExcerpt` (allow-list, path
  traversal, byte cap, UTF-8 truncation, binary files, directories,
  permissions, empty files), `listingLine`, and `SuggestedNameBox`.
- `AISessionNamingTests.swift`, `TabAutoNamingTests.swift`,
  `MultiWindowCWDNamingTests.swift`: Session and Tab naming against fake
  `SessionNameSuggesting` implementations, covering sanitization, the
  cache, cancellation, discarding stale results, and user renames.
- `BellNotificationSummaryTests.swift`: `NotificationSummary.sanitize`,
  the prompt, the settings default, `BellFeedEntry` Codable, and the
  `AppStateStore` → `BellFeedStore.updateSummary` path, using fake
  summarizers.

All live in `BattyKit/Tests/BattyKitTests/`.

To check real model behavior, watch the `SessionNameSuggester` and
`NotificationSummarizer` log categories in Console.app. Each request logs
its result and elapsed time.
