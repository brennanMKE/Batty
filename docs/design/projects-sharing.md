# Shared and local Projects (#0501)

Status: phase (a) is implemented; phase (b), the iCloud backend, is not.
Until phase (b) lands the Shared flag is stored and shown but **nothing
leaves the Mac**.

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
`publish(_:)`, `withdraw(id:)`, `tombstone(id:deletedAt:)` and
`changes: AsyncStream<Void>`. `ProjectStore(fileURL:fileManager:clock:backend:home:)`
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

`LocalOnlyProjectSyncBackend` is the only implementation here. It reports
`isAvailable == false`, keeps entries in memory and logs its calls for tests.

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

## Phase (b) checklist (needs user sign-off; not agent work)

`Configuration/` and `scripts/` are restricted areas and the account steps are
the user's.

1. Apple developer account: enable iCloud (key-value storage) on
   `co.sstools.Batty` and `co.sstools.Batty.beta`; create a Developer ID
   provisioning profile for the Prod App ID; regenerate the Beta development
   profile. Enabling the capability invalidates existing profiles.
2. `Batty/Batty.entitlements`: add the `ubiquity-kvstore-identifier` key. The
   file is shared by both variants; the `$(…)` form keeps one file.
3. `Batty.xcodeproj/project.pbxproj`: the capability under `SystemCapabilities`.
   This is meant to be committed, unlike the product-name residue.
4. `Configuration/Build.xcconfig`: possibly nothing under automatic signing;
   otherwise `PROVISIONING_PROFILE_SPECIFIER` for Release. Decide by inspecting
   the exported app for `Contents/embedded.provisionprofile`.
5. `scripts/release.sh`, `verify-dmg.sh`, `preflight.sh`: keep the profile and
   entitlement through the re-sign step, and assert both are present and report
   the profile's expiry.
6. `scripts/run-ui-tests.sh` and the VM: the runner ad-hoc signs, and a
   restricted entitlement without an authorizing profile can get the app killed
   at launch. **Unverified** whether it launches in the VM; check first. The
   likely fix is a UI-test entitlements file without the iCloud key, which also
   keeps the VM (no iCloud account) honest: `isAvailable == false`.
7. `docs/code-signing.md`: a Developer ID provisioning profile section.

Phase (b) must also:

- publish a locally suffixed name (`Name 2`, from merge rule 5) on the next
  `upsert` of that Project, which then propagates the suffix; decide whether
  that is wanted before shipping.

Phase (b) itself: `KeyValueProjectSyncBackend` over `NSUbiquitousKeyValueStore`
(`didChangeExternallyNotification` mapped to `changes`, quota and account-change
handling, `isAvailable` from `ubiquityIdentityToken`, 30-day tombstone pruning),
a sync status in the picker, optionally `"shared"` in `batty project list --json`,
and UI tests driving the backend through a fake. Its first task is to verify, on
a notarized Developer ID build, that the entitlement plus profile launches and
syncs between two Macs.

## Sources

- Apple, *Supported capabilities (macOS)*: https://developer.apple.com/help/account/reference/supported-capabilities-macos
- Apple, *Developer ID*: https://developer.apple.com/support/developer-id
- Apple, *Enable app capabilities*: https://developer.apple.com/help/account/identifiers/enable-app-capabilities/
- Apple, iCloud Design Guide, *Designing for Key-Value Data in iCloud*: https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForKey-ValueDataIniCloud.html
- Apple Developer Forums, *Resolving Code Signing Crashes on Launch*: https://developer.apple.com/forums/thread/706427
