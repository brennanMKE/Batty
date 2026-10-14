# Code signing

How Batty is code signed: which identity signs which build, the Developer ID
Application certificate that signs releases, what gets signed inside the
bundle and why, how to check a Mac's keys, and the rules that keep the
account's certificates from being revoked.

This is the overview. The step-by-step documents it links to are:

- `scripts/RELEASE.md` — cutting a release.
- `scripts/RELEASE-CREDENTIALS.md` — checking, moving and backing up the
  release credentials (Developer ID `.p12`, notary `.p8`, Sparkle key).
- `scripts/SPARKLE.md` — the Sparkle update-signing key.

## Identities

All signing is under one team: **`XV8BAAVZ6V`** (`DEVELOPMENT_TEAM` in
`Configuration/Build.xcconfig`, `TEAM_ID` in `scripts/release.sh`).

| Identity | Signs | Where it comes from |
|---|---|---|
| **Developer ID Application: Brennan Stehling (XV8BAAVZ6V)** | Only `./build.sh package --sign` (Beta, with `--notarize`: the exported Beta app, its embedded binaries and the Beta DMG) and `scripts/release.sh`, the latter covering the exported `Batty.app`, its embedded `batty` CLI and `BattyBroker`, and the DMG. Both pass `BATTY_SIGNING=developerid` (Manual signing, the committed profile, the iCloud entitlement); no routine build uses it. | `Configuration/App.xcconfig`; `scripts/build-beta.sh`; `scripts/release.sh` (`SIGN_IDENTITY`) |
| **Apple Development: Brennan Stehling (6T3DM4QG9S)** | Every routine build: `./build.sh`, `run`, `unit`, `release`, Xcode workspace builds (Automatic signing, `BATTY_SIGNING=routine`), with `Batty-local.entitlements` and no profile | `CODE_SIGN_STYLE = Automatic` resolves it |
| Ad-hoc (`-`) | The UI-test runner, and the embedded binaries in an unsigned build | `scripts/run-ui-tests.sh`; `swift build` ad-hoc signs any arm64 binary it links |
| None | `./build.sh package` without `--sign` (the app bundle itself) | `CODE_SIGNING_ALLOWED=NO` in `scripts/build-beta.sh` |

The `(6T3DM4QG9S)` in the Apple Development name is not the team ID. Both
certificates carry team `XV8BAAVZ6V` in their subject `OU`,
which is what the XPC peer checks below match on.

Sparkle's EdDSA key is a separate signing key, not a code-signing identity. It
signs update archives for the appcast, and every installed copy of Batty
trusts it through `SU_PUBLIC_ED_KEY`. See `scripts/SPARKLE.md`, and read the
backup warning in `scripts/RELEASE-CREDENTIALS.md`: losing it has no recovery.

## The Developer ID Application certificate

**`Developer ID Application: Brennan Stehling (XV8BAAVZ6V)`** is the only
identity that can produce a Batty users can install. Apple's notary service
accepts only Developer ID-signed code, and Gatekeeper accepts a downloaded app
only if it is notarized. An Apple Development signature from the same team
does not qualify: same `TeamIdentifier`, wrong certificate type.

- **Expiry.** On the Mac mini, as of 2026-09-22, it is valid until
  **2027-02-01**. `scripts/preflight.sh --credentials-only` reports the
  current date and warns within 30 days of expiry. Apps signed and notarized
  before the certificate expires keep launching after it expires. Only new
  signing needs a valid certificate.
- **It lives in the login keychain with its private key.** Without the private
  key the certificate is useless. `security find-identity -v -p codesigning`
  lists an identity only when both are present.
- **Move it; don't re-issue it.** To use it on a second Mac, export the
  certificate and key together as a password-protected `.p12` from Keychain
  Access (or `scripts/export-release-credentials.sh`) and import it on the
  other Mac. Never click Xcode's Manage Certificates "+" or accept a prompt
  to revoke or replace a certificate. That creates a new one, or revokes the
  existing one on every Mac at once. See `scripts/RELEASE-CREDENTIALS.md` §2.
- **Developer ID Installer is not needed.** It signs `.pkg` installers. Batty
  ships a DMG signed with the Application identity.

### Where release.sh uses it

`scripts/release.sh` signs in this order:

1. `scripts/install-profiles.sh`, then `xcodebuild archive` (Prod scheme,
   Release, `BATTY_SIGNING=developerid`) followed by `-exportArchive` with `method = developer-id`,
   `teamID = XV8BAAVZ6V`, `signingStyle = manual`,
   `signingCertificate = Developer ID Application` and
   `provisioningProfiles = { co.sstools.Batty = Batty Developer ID }`.
2. It re-signs `Contents/Resources/bin/batty` and
   `Contents/Resources/bin/BattyBroker` with the Developer ID identity,
   `--options runtime --timestamp`. It then re-signs the app bundle with its
   extracted entitlements, so the resource seal matches the changed files.
3. It verifies: `codesign --verify --deep --strict`, then
   `scripts/verify-profile.sh` on the app (see "Provisioning profiles"), then
   checks each embedded binary for the same `Authority` as the app, hardened
   runtime and a secure timestamp. `--deep` does not inspect them (see below),
   so they are checked one by one.
4. It builds the DMG with `create-dmg` and signs it:
   `codesign --sign "$SIGN_IDENTITY" --timestamp`.
5. `notarytool submit --keychain-profile Batty-notary --wait`, then
   `stapler staple` and `spctl -a -t open`.

`scripts/verify-dmg.sh <dmg>` checks the finished DMG from the recipient's
side: stapled ticket, `source=Notarized Developer ID`, DMG signature, a
simulated Safari-quarantined copy, a deep verify of the app inside, and the
same profile and entitlement assertions on the inner app.

Never run `scripts/release.sh` without an explicit go-ahead. Notarization
uploads the binary to Apple.

## Which build signs with what

| Command | Signing |
|---|---|
| `./build.sh` / `./build.sh run` | Apple Development, Automatic, `Batty-local.entitlements`, no profile: no Developer ID authority, no iCloud key, no embedded profile. Never passes `-allowProvisioningUpdates`. |
| `./build.sh unit` | The same routine signing; the test host carries no iCloud key and no embedded profile. |
| `./build.sh ui` | Ad-hoc, no profile, `Batty-local.entitlements`. `tools/run-ui-tests-vm.sh` and `run-ui-tests.sh` build with `CODE_SIGN_IDENTITY=-` (or `CODE_SIGNING_ALLOWED=NO`) plus `BATTY_ENTITLEMENTS=Batty/Batty-local.entitlements PROVISIONING_PROFILE_SPECIFIER=`; the runner is then re-signed ad hoc so Gatekeeper doesn't move it to the Trash. |
| `./build.sh package` | Unsigned app bundle, which needs no profile; the embedded binaries keep `swift build`'s ad-hoc signature. |
| `./build.sh package --sign` | Developer ID Application, Manual (`BATTY_SIGNING=developerid`), the Beta profile and the full entitlements. Installs the profiles first. Meant for about once per Beta install, not once per code change. |
| `./build.sh package --sign --notarize` | The same Developer ID site as `package --sign`, but built the `release.sh` way: `xcodebuild archive` (Release) plus `-exportArchive` (`developer-id`, Manual, the Beta profile), then `bin/BattyBroker`, `bin/batty` and the app re-signed with `--options runtime --timestamp`. Every Mach-O is checked for a secure timestamp, hardened runtime and no `get-task-allow` before the DMG is signed (`dist/Batty-Beta-<sha>.dmg`), notarized and stapled. Uploads to Apple, so only with the user's go-ahead each time. `--no-submit` stops right before `notarytool submit`. |
| `./build.sh release …` | Routine: Apple Development, Automatic, `Batty-local.entitlements`, no profile. This is the `-O` compile check agents run (`archive -configuration Release`); it signs with no Developer ID, carries no iCloud key and embeds no profile. |
| `scripts/release.sh` | Developer ID Application, Manual (`BATTY_SIGNING=developerid`), the Prod profile; only with the user's go-ahead each time. |
| `cd BattyKit && swift test` | None. SwiftPM ad-hoc signs test binaries automatically. |

## Hardened runtime and entitlements

`ENABLE_HARDENED_RUNTIME = YES` on the app target. Notarization requires it.
The app is not sandboxed (`ENABLE_APP_SANDBOX = NO`), because a terminal has
to run arbitrary user processes.

Until #0503 `CODE_SIGN_ENTITLEMENTS` was set nowhere, so
`Batty/Batty.entitlements` was never part of a signature, and the
`allow-jit` and `allow-dyld-environment-variables` keys it then listed were
never granted. Prod 1.2.0 was signed without them; the file no longer
lists them, because adding them would loosen the hardened runtime for no
observed need.

There are two entitlements files, chosen by the build setting
`BATTY_ENTITLEMENTS`, which `Configuration/App.xcconfig` derives from
`BATTY_SIGNING` (`routine` by default, `developerid` on the command line); the
app target maps it to `CODE_SIGN_ENTITLEMENTS`:

| File | Holds | Used by |
|---|---|---|
| `Batty/Batty.entitlements` | `com.apple.developer.ubiquity-kvstore-identifier = $(TeamIdentifierPrefix)$(CFBundleIdentifier)`, i.e. `XV8BAAVZ6V.co.sstools.Batty` (Prod) and `XV8BAAVZ6V.co.sstools.Batty.beta` (Beta) | Developer ID builds (`BATTY_SIGNING=developerid`), which embed a profile |
| `Batty/Batty-local.entitlements` (default) | Nothing | Every routine build, `./build.sh unit` and the UI-test builds |

The kvstore key is **restricted**: valid only in a signature whose embedded
provisioning profile authorizes it. Without one the system kills the app at
launch (AMFI "restricted entitlements"), and `xcodebuild` itself refuses to
sign the target (`"Batty" requires a provisioning profile`). That is why only a
Developer ID build, which has a profile, gets the file with the key, and why the app builds
a sync backend only when its own signature carries the key
(`ProjectSyncEntitlement.isPresent()`).

Adding an entitlement changes what notarization accepts and what the signature
promises. Treat it as a reviewed change.

## Provisioning profiles

The iCloud key-value entitlement needs a **Developer ID provisioning
profile** embedded in the app at `Contents/embedded.provisionprofile`. Two are
tracked in `Configuration/Profiles/`; they hold certificates and entitlements,
no secrets:

| Profile | Name | App ID | UUID |
|---|---|---|---|
| `Batty.provisionprofile` | `Batty Developer ID` | `XV8BAAVZ6V.co.sstools.Batty` | `11662ab9-522a-4d42-b7ce-d6d278aea0ee` |
| `Batty_Beta.provisionprofile` | `Batty Beta Developer ID` | `XV8BAAVZ6V.co.sstools.Batty.beta` | `ddd8d7ec-3279-4888-873c-6c36f3aa2aab` |

- **Where they come from.** Created in the developer portal by a person
  (Certificates, Identifiers & Profiles, Developer ID distribution), then
  copied here. When creating one you choose which Developer ID Application
  certificate it authorizes; **it must be the certificate this Mac signs
  with**. The profiles first committed (named `Batty` and `Batty Beta`) listed a
  different certificate (SHA-1 `4CDDC1D0...`, serial `67D6C92434FAAED2`) whose
  private key the release Mac does not hold, and `xcodebuild` stopped with
  `Provisioning profile "Batty" doesn't include signing certificate`. They
  were replaced by the `... Developer ID` profiles, which list only serial
  `5DAD92F9908AF699` (SHA-1 `B3D61A34...`), the certificate this Mac signs
  with. Importing the other certificate's .p12
  instead would leave two identities with the same name, which makes
  `codesign --sign "<name>"` ambiguous in `release.sh`. `scripts/preflight.sh`
  and `scripts/verify-profile.sh` check it.
- **Evaluated at every launch.** The system checks the embedded profile each
  time the app starts, and an expired profile stops it launching. These were
  created 2026-10-13 and expire in 2044 (18 years); `preflight.sh` and
  `verify-profile.sh` print the exact date.
  `scripts/preflight.sh` warns inside a year of expiry and fails on an expired
  one.
- **Regenerate on a capability change.** Enabling or disabling a capability on
  an App ID invalidates its profiles. Adding `icloud-services` or a container
  later means new profiles; the current ones already allow them, but Batty
  requests only the kvstore key.
- **Selection.** `Configuration/App.xcconfig` (Prod) and `Beta.xcconfig` set
  `BATTY_DEVELOPER_ID_PROFILE` (`Batty Developer ID`, `Batty Beta Developer ID`),
  which becomes `PROVISIONING_PROFILE_SPECIFIER` only when `BATTY_SIGNING` is
  `developerid`. `BattyTests` shares `App.xcconfig`, so its target settings pin
  Automatic, Apple Development and no profile; it never picks up the app's. The switch is a variable read in the xcconfig, not a command-line
  `CODE_SIGN_*` override, because a command-line profile specifier or signing
  style would reach the Swift package targets, which cannot take a profile. `xcodebuild` finds a profile by name
  only among installed ones, so `scripts/install-profiles.sh` copies the repo
  copies to `~/Library/Developer/Xcode/UserData/Provisioning Profiles/<UUID>.provisionprofile`
  (the directory this Xcode reads: it resolved `Batty Beta Developer ID` from there). It is
  idempotent, a plain file copy that contacts nobody, removes an installed
  profile only when it has the same Name as a repo profile but a different
  UUID, or is one of the two retired profiles named `Batty` and `Batty Beta`
  (so the specifier cannot pick a stale one), and `./build.sh package --sign`,
  `scripts/release.sh` run it. No `xcodebuild`
  call in the repo passes `-allowProvisioningUpdates`.
- **Manual signing.** A Developer ID build uses `CODE_SIGN_STYLE = Manual`,
  which never contacts Apple, so it cannot create or revoke certificates; the
  #0265 incident came from Automatic signing managing them. Routine builds
  stay Automatic but never use the Developer ID identity and never carry a
  restricted entitlement.
- **Checks.** `scripts/verify-profile.sh <app>` asserts that the profile is
  embedded, that its application identifier is `<team>.<bundle id>`, that the
  app's signature carries the kvstore key with that value, that the signing
  certificate is one the profile lists, and that the profile has not expired;
  it prints the `ExpirationDate`. `release.sh` runs it after the re-sign and
  `verify-dmg.sh` on the inner app of the finished DMG.

## Embedded binaries

The `batty` CLI and the `BattyBroker` launch agent are built with
`swift build` by the "Embed CLI" and "Embed Broker" run-script phases. Those
phases copy them into `Contents/Resources/bin/`. Two things follow (#0273):

- **They are sealed as resources, not as nested code.** `codesign --deep
  --strict` never inspects them, so an ad-hoc signature there passes every
  bundle-level check and then fails notarization minutes later. That is why
  both run-script phases sign them explicitly, and why `release.sh` re-signs
  and inspects them one by one.
- **The secure timestamp is keyed on `ACTION`.** Each phase signs with
  `--timestamp` only when `ACTION = install` (Archive). Every other build uses
  `--timestamp=none`, so iteration builds never wait on Apple's timestamp
  server. The notary service rejects a nested Developer ID binary that has no
  timestamp.

launchd refuses to start an improperly signed LaunchAgent (#0270), so the
broker's signature matters at run time too, not only for notarization.

## XPC peer validation

Every XPC listener and every outgoing XPC connection between the app, the
broker and the CLI requires its peer to be signed by the same team (#0273,
#0278). The requirement string comes from
`BattyKit/Sources/BattyXPCCore/PeerCodeSigningRequirement.swift`:

```
anchor apple generic and certificate leaf[subject.OU] = "XV8BAAVZ6V"
```

It accepts Apple Development and Developer ID signatures alike, so a
Development-signed Beta talks to its own Development-signed broker. When the
running binary has no team (an unsigned or ad-hoc build), no requirement is
set and any peer is accepted. That is the deliberate escape hatch for
unsigned iteration builds.

## Checking a Mac's keys

The fast, complete check:

```bash
scripts/preflight.sh --credentials-only
```

It covers the Developer ID identity and its expiry, the `Batty-notary`
profile, the App Store Connect API key, the Sparkle key and the release tools.
`scripts/release.sh` runs it first and aborts if anything fails.

The individual checks behind it:

```bash
# Identities that have a private key. Expect a "Developer ID Application:
# Brennan Stehling (XV8BAAVZ6V)" line for releases.
security find-identity -v -p codesigning

# Expiry and team of the Developer ID certificate
security find-certificate -c "Developer ID Application" -p \
    | openssl x509 -noout -subject -enddate

# Notary credentials (recreate with scripts/setup-keys.sh if this fails)
xcrun notarytool history --keychain-profile Batty-notary
```

In Keychain Access, open the login keychain and choose My Certificates. A
certificate that expands to show a private key underneath can sign. One with
nothing underneath cannot.

To check that `codesign` can reach the key from a shell, not just from Xcode,
run this in Terminal yourself:

```bash
cp /usr/bin/true /tmp/t && codesign -s "Developer ID Application" -f /tmp/t && codesign -dv /tmp/t
```

If a keychain dialog asks for access, choose Always Allow. In a
non-interactive shell (an agent, CI) the same prompt can't be answered and
shows up as `errSecInternalComponent` or `User interaction is not allowed`.

## Rules

- **Never pass `-allowProvisioningUpdates` or
  `-allowProvisioningDeviceRegistration`.** They let `xcodebuild` create,
  replace or revoke certificates and profiles with nobody watching.
- **Never create, revoke, renew or delete certificates or profiles from a
  script or agent session.** Signing identity changes are made by a person,
  in Xcode or the developer portal, deliberately.
  This is about the Apple Developer account and the keychain. Copying the
  repo's profiles into the local profiles directory, and removing a stale local
  copy of a profile with the same name (`scripts/install-profiles.sh`), are
  local file operations and are allowed.
- **Don't change `CODE_SIGN_STYLE`, `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY`
  or the provisioning profile settings in the project to fix a signing
  error.**
  `Configuration/` is a restricted area; signing is switched in
  `Configuration/App.xcconfig` (`BATTY_SIGNING`). Command-line overrides
  for a one-off build are fine.
- **Build unsigned when signing isn't what's being tested.** Use
  `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` or `swift test`.
- **Stop on signing prompts.** If output mentions revoking a certificate, a
  private key "not installed in your keychain", or an offer to create or
  replace a certificate, stop. Don't retry with more flags; diagnose with the
  read-only checks above.

Why this is strict: #0265 records a $27.43 certificate-revocation incident
caused by repeated *signed* local builds against an Automatic-signing project.
The note in `scripts/build-beta.sh`, and later issues (#0279, #0306), describe
it as the revocation of this project's Developer ID certificate. Revocation is
remote and account-wide. With two Macs on one account, each machine's
automatic signing can invalidate the other's certificate, and both machines'
builds break at once.
