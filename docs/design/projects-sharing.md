# Shared and local Projects (#0501)

Status: phase (a) (#0501) and phase (b) (#0503), the iCloud key-value backend,
are implemented. A Shared Project syncs only in a build whose signature carries
the iCloud key-value entitlement (a Prod or Beta build signed with its
provisioning profile) and is not running tests. In any other build, and in
any test process even when the host is signed with the entitlement, no
backend is built and the Shared flag on a Project is stored and shown but **nothing leaves the
Mac**. Two-Mac sync has not been verified by an agent.

A Project is **local** by default. The user can mark it **Shared** with a
checkbox on every picker card and in the Project Editor, meaning "sync this
Project through iCloud to my other Macs". Sharing is an explicit per-Project
choice: a root path and startup commands are this Mac's, and syncing a record
the user never chose to share would be a surprise.

## The sync contract: definition versus device state

Every record in `projects.json` (still version 1) splits into groups. The
split is enforced by types, not by convention.

| Group | Fields | Syncs |
|---|---|---|
| Definition | `id`, `name`, `rootPath` (portable form), `color`, `symbol`, `layout`, `runStartupCommandsOnOpen`, `modifiedAt` | yes, when shared |
| Device state | `lastOpenedAt`, `approvedCommandsHash` | never |
| Membership | `isShared` | implied by presence in the shared set; never a field of the synced record |

`ProjectSyncRecord` (`Model/ProjectSync.swift`) holds exactly the Definition
row. It has no `isShared`, `lastOpenedAt` or `approvedCommandsHash`, so device
state cannot reach a payload. The trust approval (#0473) is consent given on
one Mac for commands that run on that Mac; if it synced, approving a command
set on Mac A would let the same commands run unprompted on Mac B. Recency
(#0492) ranks the picker by what this person opened on this Mac, and syncing
it would turn every open into a sync write.

`projects.json` gains two optional keys per Project: `isShared` (written only
when true, so a local Project's object is unchanged) and `modifiedAt`. Both
are additive; a build without this change ignores them.

`modifiedAt` is stamped by `ProjectStore` on every definition write (`upsert`,
`setShared`) and is the last-writer-wins key. It is not stamped by
`recordOpen` or `recordApproval`, which write device state only: neither
stamps, publishes, or rewrites a file that could not be fully loaded.

## Portable root

In memory and in `projects.json` the root stays absolute. In a sync record
only, a root under the home directory is written `~/…` and home itself `~`
(`PortablePath`, pure, home passed in). A root outside home is written as is.
A path that merely shares a string prefix with home (`/Users/brennan2/x` for
home `/Users/brennan`) is not rewritten. Only a leading `~/` or a bare `~` is
expanded on decode; `~user/…` is not.

A Project whose root does not exist on this Mac is a normal, visible Project
with a `Folder not found` caption on its picker cards
(`project-picker.missing-root.<name>`). Opening it fails with
`ProjectOpenError.rootMissing`, and the editor will not save it until the root
exists. The existence check is injected into `ProjectPickerModel` and answered
lazily, once per root, by a cache object shared by every copy of the model
(`refreshed` returns copies). The first render that builds a card for a root
pays one check; later renders read the cache.

## Merge rules (`ProjectSyncMerge.apply`, pure)

Last writer wins per Project; a Project is replaced whole, never merged by
field. Clocks are assumed roughly in sync, which is acceptable for one
person's own Macs.

1. Unknown id, record: insert as a shared Project with no device state.
2. Known id, record: replace the definition and keep device state when
   `remote.modifiedAt` is later than the local one (a nil local date is older
   than any date). Equal or older is ignored.
3. Known id, tombstone: delete only if the local Project is still shared. One
   the user has since made local on this Mac is kept. A tombstone for an
   unknown id is ignored.
4. Known shared id absent from the remote set (withdrawn elsewhere): the local
   Project becomes local and is kept. Nothing is deleted by absence; only a
   tombstone deletes.
5. Name collision (names are unique case-insensitively): the incoming name
   gets a numeric suffix on this Mac (`Name 2`, `Name 3`, …).
6. Idempotent: applying the same remote set twice equals applying it once.

Unsharing and deleting are different events on purpose: withdrawing removes
the shared entry and other Macs keep their copy as local, while deleting
leaves a tombstone other Macs apply. A tombstone is meant to be pruned after
30 days by the phase (b) backend.

## Backend protocol

`ProjectSyncBackend` (`@MainActor`): `isAvailable`, `snapshot()`,
`publish(_:) throws`, `withdraw(id:)`, `tombstone(id:deletedAt:)`,
`changes: AsyncStream<Void>` and `onSyncError`. `ProjectStore(fileURL:fileManager:clock:backend:home:)`
takes an optional backend. With `nil` (production in phase (a)) none of the
sync code runs. With one, `upsert` and `setShared(true)` of a shared Project
`publish`, an unshare `withdraw`s, and `delete` of a shared Project
`tombstone`s. Local Projects never reach it.

The store applies the merge on each `changes` event. That is the one write to
`projects.json` that is not a direct user action, and it is skipped while the
file could not be fully loaded. The store ignores `changes` from a backend whose `isAvailable` is false, but
phase (b) must also only yield `changes` after a real remote read: rule 4 treats an empty snapshot as "everything withdrawn",
so a backend that yields before its first sync would turn every shared Project
local.

`LocalOnlyProjectSyncBackend` keeps entries in memory and logs its calls for
tests; it never throws. `ICloudKeyValueProjectSyncBackend` is the production
implementation (next section).

## The iCloud key-value backend (phase b, #0503)

`ICloudKeyValueProjectSyncBackend` (`Model/ICloudKeyValueProjectSyncBackend.swift`)
takes a `KeyValueStoring` (`NSUbiquitousKeyValueStore` in production, a fake in
tests) and a `NotificationCenter`.

- **Keys.** `project.<uuid>`, value compact JSON (`.sortedKeys`, no pretty
  printing, ISO 8601 dates with fractional seconds). A record is a
  `ProjectSyncRecord`; a tombstone is `{"deletedAt": "..."}`. `withdraw`
  removes the key. `snapshot()` skips and logs a value it cannot decode, or
  whose record id differs from its key, and never deletes it.
- **Changes.** `didChangeExternallyNotification` for the backend's store:
  `ServerChange` and `InitialSyncChange` yield `changes` unless every changed
  key is outside the `project.` prefix; `AccountChange` yields;
  `QuotaViolationChange` never yields, sets `lastError` and calls `onSyncError`.
  Construction calls `synchronize()` and yields once, so the store merges what
  the system cache already holds at launch.
- **The authority guard.** An empty snapshot means "everything withdrawn"
  (merge rule 4), but the launch merge and the merge after an account change
  read a cache that may not be filled yet. `snapshotIsAuthoritative` is false
  from construction and again after an `AccountChange`, and true after a
  `ServerChange` or `InitialSyncChange`; the store passes it to the merge as
  `withdrawAbsent`, so rule 4 applies only after one of those two follows.
  Records and tombstones apply either way.
- **Availability.** `isAvailable` is the entitlement alone: key-value
  storage can work while `ubiquityIdentityToken` stays nil for an app with no
  ubiquity container. Construction logs once at info level whether the
  entitlement and the token are present. The store ignores `changes` while
  `isAvailable` is false.
- **Limits, enforced before writing.** A value over 1,000,000 bytes, a key
  count that would pass 1,024 (any key in the store counts), or project values
  that would total over 1,000,000 bytes make `publish` throw
  `ProjectSyncError.quotaExceeded(reason:)` and write nothing. Apple states the
  size limits as 1 MB; the decimal reading is the conservative one.
- **Store order.** `ProjectStore.upsert` and `setShared(true)` call `publish`
  before the local commit, so a refused share leaves `isShared` false and
  `projects.json` untouched, and the error reaches the caller. The store keeps
  the message in `syncError` until the next successful publish.
- **Where the error shows.** The picker shows `syncError` as a caption under
  the cards (`project-picker.sync-error`) and the checkbox stays unchecked;
  the editor shows it as `saveError`, and Save fails.
- **Tombstone pruning.** Each `snapshot()` removes tombstones older than 30
  days using the injected clock. It is the only write no user action caused.
- **Wiring.** `AppStateStore.projectStore` builds the backend only with
  the entitlement present
  (`ProjectSyncEntitlement.isPresent()`, via `projectSyncBackendFactory`) and
  the process is not a test (`ProjectSyncEntitlement.isTestProcess()`: the
  environment has `XCTestConfigurationFilePath`, or `XCTestCase` is loaded);
  otherwise the store gets `nil`.
- **Local suffix.** A name suffixed by merge rule 5 (`Name 2`) is published on
  the next `upsert` of that Project and then propagates. That is wanted.

Signing, profiles and the two entitlements files: `docs/code-signing.md`.

## Where the checkbox is

One identifier scheme, always its own click target: `project-picker.shared.<name>`
on large cards (summary row), compact cards (path row) and Open now chips, and
`project-editor.shared` in the editor header's `Sharing` column. A click writes
at once through `onSetShared` and does not select, open or dismiss; it does not
go through `onAction`, which dismisses first. Shared cards show an `icloud`
glyph by the symbol. On a chip the control is itself an `icloud` / `icloud.fill`
button, so it takes the glyph's place.

## Recommended mechanism for phase (b): iCloud key-value storage

Apple's *Supported capabilities (macOS)* table lists iCloud CloudKit, iCloud
documents and iCloud key-value storage as supported for **Developer ID**
(read 2026-10-13). All three need the iCloud capability on the App ID and a
Developer ID provisioning profile embedded in the app; the profile is
evaluated at every launch and an expired one stops the app launching (profiles
created after 2017-02-22 last 18 years).

| | Key-value storage | CloudKit | iCloud Drive file |
|---|---|---|---|
| Entitlement | `com.apple.developer.ubiquity-kvstore-identifier` | `icloud-services`, container ids | `icloud-services`, ubiquity container ids |
| Granularity | per key | per record | whole file |
| Limits | 1 MB total, 1,024 keys, 1 MB per value, 64-byte keys | user quota | user quota |
| Conflicts | latest per key | per record | `NSFileVersion` |

Recommendation: **key-value storage**, one key `project.<uuid>` per shared
Project holding compact JSON of `ProjectSyncRecord`, tombstones as
`{ "deletedAt": … }`. Records are small and per-Project last-writer-wins maps
onto per-key latest-wins. Measured with the Definition fields and a
`~`-relative root: 1,330 bytes for a 4-Pane, 6-Tab Project with six startup
commands, 336 bytes for a single-Pane Project. At about 1,100 bytes average
the quota holds roughly 950 shared Projects and the key cap about 1,000
entries; a key of `project.<uuid>` is 44 bytes. The backend must encode
compactly and handle the quota-violation reason. The protocol exists so
CloudKit can replace it if the count or size nears the quota.

### Prod and Beta

`$(TeamIdentifierPrefix)$(CFBundleIdentifier)` gives
`XV8BAAVZ6V.co.sstools.Batty` and `XV8BAAVZ6V.co.sstools.Batty.beta`: two
independent stores, as Application Support is already split per variant
(#0279). A Beta build never writes into the set a Prod build reads. Both App
IDs need the capability.

## Phase (b) checklist

Done in #0503 unless marked otherwise; `Configuration/` and `scripts/` are
restricted areas and the account steps were the user's.

1. Apple developer account: iCloud (key-value storage) on both App IDs and a
   Developer ID provisioning profile for each (`Batty Developer ID`,
   `Batty Beta Developer ID`, in `Configuration/Profiles/`, listing only the
   certificate this Mac signs with). Done by the user.
2. `Batty/Batty.entitlements`: the `ubiquity-kvstore-identifier` key only
   (`$(TeamIdentifierPrefix)$(CFBundleIdentifier)`), with
   `Batty-local.entitlements` for builds without a profile. Done.
3. `Batty.xcodeproj/project.pbxproj`: no `SystemCapabilities` entry was added;
   the app target maps `CODE_SIGN_ENTITLEMENTS` and
   `PROVISIONING_PROFILE_SPECIFIER` from xcconfig variables. Done.
4. `Configuration/*.xcconfig`: `BATTY_SIGNING` selects routine (Automatic, no
   profile, no iCloud key) or Developer ID (Manual, the variant's profile, the
   iCloud key); only `package --sign` and the release pipeline pass
   `developerid`. Done.
5. `scripts/release.sh`, `verify-dmg.sh`, `preflight.sh`: profile and
   entitlement assertions and the profile's expiry, through
   `scripts/verify-profile.sh`. Done; not run end to end (needs a release
   run and notarization).
6. `scripts/run-ui-tests.sh` and the VM: builds pass the
   `Batty-local.entitlements` override, so the app has no entitlement and no
   backend; `ProjectsSyncEntitlementTests` checks it. Done; the VM run is the
   orchestrator's.
7. `docs/code-signing.md`: a Developer ID provisioning profile section. Done.

Still open after #0503:

- The sync status glyph in the picker (`icloud.slash` with no account) and
  `"shared"` in `batty project list --json`.
- Two-Mac sync on a notarized Developer ID build, by hand, including: sign
  out and in of iCloud, and an edit on one Mac while Batty on the other is
  quit, then launching it.

## Sources

- Apple, *Supported capabilities (macOS)*: https://developer.apple.com/help/account/reference/supported-capabilities-macos
- Apple, *Developer ID*: https://developer.apple.com/support/developer-id
- Apple, *Enable app capabilities*: https://developer.apple.com/help/account/identifiers/enable-app-capabilities/
- Apple, iCloud Design Guide, *Designing for Key-Value Data in iCloud*: https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForKey-ValueDataIniCloud.html
- Apple Developer Forums, *Resolving Code Signing Crashes on Launch*: https://developer.apple.com/forums/thread/706427
