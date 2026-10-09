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
| **Developer ID Application: Brennan Stehling (XV8BAAVZ6V)** | Release builds: the exported `Batty.app`, its embedded `batty` CLI and `BattyBroker`, and the DMG | `scripts/release.sh` (`SIGN_IDENTITY`) |
| **Apple Development: Brennan Stehling (6T3DM4QG9S)** | Ordinary Debug/Beta builds from `./build.sh` and Xcode | `CODE_SIGN_STYLE = Automatic` resolves `CODE_SIGN_IDENTITY = Apple Development` |
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

1. `xcodebuild archive` (Prod scheme, Release) followed by `-exportArchive`
   with `method = developer-id`, `teamID = XV8BAAVZ6V`,
   `signingStyle = automatic`.
2. It re-signs `Contents/Resources/bin/batty` and
   `Contents/Resources/bin/BattyBroker` with the Developer ID identity,
   `--options runtime --timestamp`. It then re-signs the app bundle with its
   extracted entitlements, so the resource seal matches the changed files.
3. It verifies: `codesign --verify --deep --strict`, then checks each embedded
   binary for the same `Authority` as the app, hardened runtime and a secure
   timestamp. `--deep` does not inspect them (see below), so they are checked
   one by one.
4. It builds the DMG with `create-dmg` and signs it:
   `codesign --sign "$SIGN_IDENTITY" --timestamp`.
5. `notarytool submit --keychain-profile Batty-notary --wait`, then
   `stapler staple` and `spctl -a -t open`.

`scripts/verify-dmg.sh <dmg>` checks the finished DMG from the recipient's
side: stapled ticket, `source=Notarized Developer ID`, DMG signature, a
simulated Safari-quarantined copy, and a deep verify of the app inside.

Never run `scripts/release.sh` without an explicit go-ahead. Notarization
uploads the binary to Apple.

## Which build signs with what

| Command | Signing |
|---|---|
| `./build.sh` / `./build.sh unit` / `./build.sh run` | Apple Development (Automatic). Never passes `-allowProvisioningUpdates`, so it cannot create or revoke certificates. |
| `./build.sh ui` | Ad-hoc. `run-ui-tests.sh` builds with `CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO`, then re-signs the test runner ad hoc so Gatekeeper doesn't move it to the Trash. |
| `./build.sh package` | Unsigned app bundle; the embedded binaries keep `swift build`'s ad-hoc signature. |
| `./build.sh package --sign` | Automatic signing. Meant for about once per Beta install, not once per code change. |
| `./build.sh release …` / `scripts/release.sh` | Developer ID Application. |
| `cd BattyKit && swift test` | None. SwiftPM ad-hoc signs test binaries automatically. |

## Hardened runtime and entitlements

`ENABLE_HARDENED_RUNTIME = YES` on the app target. Notarization requires it.
The app is not sandboxed (`ENABLE_APP_SANDBOX = NO`), because a terminal has
to run arbitrary user processes.

`Batty/Batty.entitlements` grants two hardened-runtime exceptions that child
processes inherit through the shell:

- `com.apple.security.cs.allow-jit` — for JIT runtimes (Node, JVMs, modern
  Python).
- `com.apple.security.cs.allow-dyld-environment-variables` — so
  `DYLD_LIBRARY_PATH`, sanitizers and similar tools work in a Batty shell.

Adding an entitlement changes what notarization accepts and what the signature
promises. Treat it as a reviewed change.

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
- **Don't change `CODE_SIGN_STYLE`, `DEVELOPMENT_TEAM` or
  `CODE_SIGN_IDENTITY` in the project to fix a signing error.**
  `Configuration/Build.xcconfig` is a restricted file. Command-line overrides
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
