# Building, installing locally, and the signing hazard

> **Vendored copy — not a Batty document.** Copied 2026-07-24 from
> `RemoteControl/docs/build-and-release.md` (a sibling, throwaway,
> read-only checkout at `/Users/brennan/Developer/brennanMKE/RemoteControl`)
> for Batty issue [#0267](../../issues/0267.md). It describes the
> RemoteControl XPC prototype — a different app — not Batty; the
> "must rename" / "copy verbatim" markers throughout are written for that
> porting exercise. The body below is unedited from the source.
>
> **Any bare `#NNNN` below is a RemoteControl issue** (that project's own
> `issues/0001`–`issues/0031` tracker), never a Batty issue — Batty's
> tracker uses the identical `#NNNN` form for a disjoint set of numbers.
> Links to files this vendoring did not copy (RemoteControl's `issues/`
> folder, its repo-root `README.md`) will not resolve; see the source
> checkout above if it still exists.

The most useful thing in this document is the first section, because it
contradicts what most macOS release guidance implies.

## You do not need a Developer ID to install your own app

> **A locally built app carries no `com.apple.quarantine` attribute, so
> Gatekeeper never evaluates it.**

Quarantine is applied by the *downloading* agent — Safari, Mail, Messages,
AirDrop. Nothing applies it to a bundle your own toolchain just produced. Copy
that bundle to `/Applications`, launch it, and macOS runs it without a Gatekeeper
check, an "unidentified developer" dialog, or a right-click-Open ritual.

So for building an app and using it on the machine that built it:

- **No Developer ID Application certificate.**
- **No notarization.**
- **No stapling.**
- **No DMG.**
- An **Apple Development** identity (which you already have if Xcode builds and
  runs) is sufficient. Ad hoc (`-`) works too.

This project spent a large fraction of its total session cost on certificate and
notarization work that local testing never required. If your goal is "I want to
use my app", stop before any of it.

### What actually needs signing, and why

Two things care about the signature even locally:

- **`SMAppService`** can refuse to start an improperly signed launch agent.
- **The bundle seal** breaks if a nested Mach-O is unsigned, which is why the
  embed script signs the CLI itself (see
  [cli-embedding-and-install.md](cli-embedding-and-install.md)).

An Apple Development identity satisfies both.

### What changes when you hand it to someone else

Then quarantine applies, and you need the full pipeline: Developer ID
Application identity, Hardened Runtime, notarization, stapling, and a DMG or ZIP.
That is a genuinely different job — and the point of this section is that it is
*optional*, and separable, and you should not do it while still trying to test.

## A release script for local install

The shape that works: build Release into a directory that is **not** the shared
DerivedData, stage the app into `dist/`, verify it, and tell the user to drag it.

```zsh
#!/usr/bin/env zsh
set -euo pipefail

SCHEME="YourApp"
CONFIGURATION="Release"
OUTPUT_DIR="dist"
# Kept out of ~/Library/Developer/Xcode/DerivedData on purpose: a second copy of
# the app there is exactly what confuses SMAppService registration, which is
# keyed to the bundle.
BUILD_DIR="build/release-derived"

cd "${0:A:h}/.."

rm -rf "$BUILD_DIR"
# The log lives beside the build dir, so its parent must exist before the
# redirect is evaluated -- which happens before xcodebuild ever runs.
mkdir -p "${BUILD_DIR:h}"

xcodebuild build \
    -project "YourApp.xcodeproj" -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR" > "$BUILD_DIR.log" 2>&1

# ditto, not cp: preserves the bundle's symlinks and signature.
mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/YourApp.app"
ditto "$BUILD_DIR/Build/Products/$CONFIGURATION/YourApp.app" "$OUTPUT_DIR/YourApp.app"
```

Note what is **deliberately absent**: `-allowProvisioningUpdates`. See
[the signing hazard](#the-signing-hazard) below.

### The checks worth having

Each of these exists because something got past a passing build.

**1. Warn if the app is running.** Installing over a running app and leaving two
bundles claiming the same launchd label is the documented way to wedge
`SMAppService`. Tell the user to unregister the login item and quit first.

**2. Verify every bundle component exists.** A missing file here means a build
phase silently didn't run:

```zsh
for component in \
    "Contents/MacOS/YourApp" \
    "Contents/MacOS/BrokerAgent" \
    "Contents/Resources/bin/yourctl" \
    "Contents/Library/LaunchAgents/com.example.yourapp.broker.plist"
do
    [[ -e "$APP/$component" ]] || { print -u2 "✗ MISSING $component"; exit 1; }
done
```

**3. Verify the bundle signature *and the embedded CLI separately*.**

```zsh
codesign -v --deep --strict "$APP"
codesign -v "$APP/Contents/Resources/bin/yourctl"    # --deep never reaches this
```

A binary under `Contents/Resources/` is sealed as a **resource**, not nested
code. `--deep` descends into code, not resources, so it will report the bundle
valid while your CLI is entirely unsigned.

**4. Actually execute the embedded CLI.**

```zsh
"$APP/Contents/Resources/bin/yourctl" --version
```

A sibling project shipped a CLI that crashed at launch on a dyld failure because
its verification ran `swift run` and checked the embedded copy with `file` —
architecture only. One second of execution would have caught it. A dynamic-link
failure here means the bundle is broken *even though the build succeeded*.

**5. Print the architectures.**

```zsh
lipo -archs "$APP/Contents/Resources/bin/yourctl"
```

Expect a single arch from an ordinary `xcodebuild build` on Apple Silicon —
`ARCHS` contains only the native one unless you ask otherwise. That is correct
for local install and smaller. If you need Intel compatibility, set
`ARCHS=$(ARCHS_STANDARD)` and confirm the result here rather than assuming the
`--arch` loop in the embed phase produced a fat binary.

### Then get out of the way

End by printing instructions, not by installing:

```
✓ Release ready:  /path/to/dist/YourApp.app

  To install:
    1. Quit YourApp if running (unregister the login item first).
    2. Drag dist/YourApp.app into /Applications, replacing any older copy.
    3. Launch it from /Applications — not from Xcode.
    4. File ▸ Install Command Line Tool…
```

Do not copy into `/Applications` from the script. The drag is one gesture, it is
the user's decision, and it avoids a privileged operation for no gain.

## The signing hazard

This is the part to read before pointing any automation at `xcodebuild`.

> **An Apple Development certificate is only usable on the machine whose keychain
> holds its private key. When automatic signing cannot reach that private key,
> Xcode's built-in remedy is to *revoke the certificate and issue a new one*.**

That is a remote, account-wide, irreversible action. It breaks signing on every
other Mac on the account.

### What happened here

On 2026-07-24, **52 signed `xcodebuild` invocations across 47 commands**, against
a project with Automatic signing and Xcode open, drove `IDEProvisioningRepair` to
revoke and reissue the Apple Development certificate **twice**. The portal already
held 7 development certificates, which is what tipped it into the repair path.
The result was a stream of revocation emails and a blocked Developer ID request
(*"You already have a current Developer ID Application certificate or a pending
certificate request"*).

Two conditions make it much worse in an automated session:

**`-allowProvisioningUpdates` authorizes signing-asset changes, including
revocation, with no human able to intervene.** It is tempting precisely because
it makes signing errors disappear.

**In a non-interactive shell the keychain ACL prompt cannot be answered.** The
toolchain then behaves as if the private key is missing even though it is right
there — which feeds straight into revoke-and-reissue.

With two Macs on one account this ping-pongs: each machine's automatic signing
invalidates the other's certificate.

### The rules

1. **Never pass `-allowProvisioningUpdates` or
   `-allowProvisioningDeviceRegistration`.** If a build genuinely needs one, that
   is a finding to report, not a flag to add.
2. **Never create, revoke, delete, or renew certificates or provisioning
   profiles** — not via `xcodebuild`, `security`, `fastlane`, `codesign`, the API,
   or the portal. Never delete anything from a keychain.
3. **Never resolve a signing error by editing signing configuration.** Team ID,
   `CODE_SIGN_STYLE`, `CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM` stay as they are
   without explicit approval.
4. **Default to not signing at all.**
5. **Stop on the stop-words** rather than retrying with a different flag.

### Build unsigned by default

Signing is needed for device installs and archives. Compiling, type-checking,
unit tests, and static analysis all work unsigned:

```bash
xcodebuild build -project YourApp.xcodeproj -scheme YourApp \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet
```

`CODE_SIGNING_ALLOWED=NO` is the important one: the build system does not invoke
`codesign` at all, so no keychain access happens and no repair logic can fire.
Use this for every iteration. Reach for a signed build only when you need to
*run* the thing.

### Stop-words

If output contains any of these, **stop, do not retry, diagnose read-only**:

- `Revoke certificate`, or any offer to revoke or replace one
- `its private key is not installed in your keychain`
- `No signing certificate … found`
- `errSecInternalComponent` (locked keychain or an ACL denial)
- `User interaction is not allowed` (keychain prompt in a non-interactive shell)
- any suggestion to delete or regenerate a provisioning profile

The specific failure mode to avoid is the **retry loop**. When a signed build
fails the instinct is to try again with one more flag, and each retry moves closer
to the command that revokes a certificate. Drop to an unsigned build to prove the
code compiles — that is real information and it is safe — then report the signing
problem separately.

### Guard the project, not just the session

Put it where the next person (or the next agent) will hit it. `.claude/settings.json`:

```json
{
  "permissions": {
    "deny": [
      "Bash(*allowProvisioningUpdates*)",
      "Bash(*allowProvisioningDeviceRegistration*)",
      "Bash(security delete-certificate*)",
      "Bash(security delete-identity*)",
      "Bash(security set-key-partition-list*)"
    ]
  }
}
```

And a section in `CLAUDE.md` stating the unsigned-build command, the stop-words,
and that device builds and archives are run by a human.

Recovery, when it is needed, is the user's to run: export a `.p12` from the
healthy Mac, or create the certificate once in Xcode's GUI with a person watching
— because Xcode will show the revoke prompt rather than silently accepting it.
Never run `security set-key-partition-list` with a password interpolated into the
command.

## Two copies of the app is its own hazard

Worth stating separately, because it produces confusing behaviour rather than an
error.

`SMAppService` registration is keyed to the **bundle**. Two bundles claiming the
same launchd label — typically a DerivedData copy and the one in `/Applications`
— means launchd's view of which is registered may not be the one you are
launching. Symptoms are intermittent and look like the broker misbehaving.

- Keep **one** copy of the app on disk while testing.
- Delete stale DerivedData bundles before running lifecycle tests.
- Build releases into a project-local directory (as above), not shared
  DerivedData.
- After installing to `/Applications`, launch it **from there**, not from Xcode.

And remember the installer's symlink points *into* the bundle, so replacing the
app at the same path keeps the CLI working, while moving it to a new path makes
the install read as not-installed until re-installed.
