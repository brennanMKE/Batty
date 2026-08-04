# Release credentials: check, replicate, back up

Batty is released from whichever Mac has the right credentials installed —
today that means the MacBook Air and/or the Mac mini. This doc answers three
questions: is this machine release-capable right now, how do I move that
capability to another Mac, and what do I need to back up so losing a laptop
doesn't mean losing the ability to ship updates.

## Check: is this machine release-capable?

```bash
scripts/preflight.sh --credentials-only
```

Fast (no build, no test run, no network calls beyond the notary/keychain
probes), pass/fail per item, non-zero exit if anything is missing. Run it on
both Macs before deciding where to cut a release — don't wait to discover the
gap mid-`release.sh`, which is how #0306 was filed (`notarytool history`
failed with "No Keychain password item found" partway through an attempt).

It checks, grouped by what breaks if the item is missing:

| Item | What it blocks if missing |
|---|---|
| Developer ID Application identity + private key | `codesign` fails immediately |
| Certificate expiry | Nothing yet — warns inside a 30-day window |
| `Batty-notary` notarytool keychain profile | `notarytool submit` fails |
| ASC API key `~/.appstoreconnect/AuthKey_DWLP54ACTJ.p8` | Can't *recreate* the profile above on this machine |
| `create-dmg`, `fileicon` | `release.sh` exits before archiving |
| `codesign`, `xcodebuild`, `notarytool`, `stapler`, `spctl`, `hdiutil`, `PlistBuddy`, `xmllint`, `rsync` | Various pipeline steps |
| `sign_update` (Sparkle SPM artifact) | `appcast-item.sh` can't run |
| Sparkle EdDSA private key (login keychain, account `Batty`) | Release completes, but existing installs never see it as an update — unverifiable without a matching signature |
| `Configuration/Active.xcconfig` → `Prod.xcconfig` | Silently ships `Batty Beta.app` under the Prod scheme (#0280) |

This is `scripts/preflight.sh`'s existing "Product variant gate" and
"Credential gates" sections in isolation — the full `scripts/preflight.sh`
(no flag) runs these plus the build, version, website, and workspace gates
for the complete pre-release walkthrough. One script, two depths: add
`--credentials-only` when the only question is "can this machine reach Apple
and Sparkle with the right keys," skip it for the full release-readiness
pass. (See "Why extend `preflight.sh` instead of a new script" below.)

Each run stamps `scripts/.release-integrity-state` (gitignored, machine-local)
with today's date against every item that just passed. A later failure for
that item then prints when it last worked here — e.g. a cert that expired
overnight reads "EXPIRED... (last confirmed good on this machine:
2026-07-30)" instead of a bare failure, so a silent keychain deletion or
lapsed cert doesn't go unnoticed between releases.

## Replicate: moving capability to a second Mac

Three things move independently. None of them regenerate themselves — either
copy the artifact, or (for the notary profile) recreate it from the artifact
that backs it.

### 1. Notary access — copy the `.p8`, then re-run setup

The `Batty-notary` keychain profile itself **cannot be exported** — it's a
machine-local keychain item, `notarytool store-credentials` writes it fresh
each time. But this project already uses the ASC API key form (not an Apple
ID + app-specific password), and that key *is* a portable file:

```bash
# On the source Mac, copy the file wherever you move files between these two Macs
~/.appstoreconnect/AuthKey_DWLP54ACTJ.p8

# On the target Mac
mkdir -p ~/.appstoreconnect
cp AuthKey_DWLP54ACTJ.p8 ~/.appstoreconnect/
scripts/setup-keys.sh
```

`setup-keys.sh` runs `notarytool store-credentials` with `--key
~/.appstoreconnect/AuthKey_DWLP54ACTJ.p8 --key-id DWLP54ACTJ --issuer
<UUID>` — the same form `release.sh`'s own error message prescribes when the
profile is missing. Confirm with `scripts/preflight.sh --credentials-only`.

### 2. Developer ID Application cert + private key — export/import a `.p12`

The cert must travel with its private key, which means a password-protected
`.p12`, not a re-issue from Apple. **Do not use Xcode's "Manage
Certificates" → re-issue** — that mints a *new* certificate, and this
project's account has already hit certificate-revocation trouble from
extra/duplicate certs (#0270, #0273, #0278, #0281). Move the existing one:

1. On the source Mac: open Keychain Access → My Certificates → find
   "Developer ID Application: Brennan Stehling (XV8BAAVZ6V)" → expand it so
   the private key shows underneath → select both the cert and the key →
   right-click → Export 2 items… → save as a password-protected `.p12`.
2. Move the `.p12` to the target Mac (same channel as the `.p8` — see
   Backup below for where that should live).
3. On the target Mac: double-click the `.p12` (or File → Import Items… in
   Keychain Access), enter the export password, choose the login keychain.
4. Confirm with `security find-identity -p codesigning -v` — the identity
   should list with a numbered entry, meaning cert *and* key are both
   present. `scripts/preflight.sh --credentials-only` checks the same thing.

### 3. Sparkle EdDSA private key — export/import via `generate_keys`

```bash
# On the source Mac (from wherever the Sparkle SPM artifacts landed —
# see scripts/SPARKLE.md for the exact path)
generate_keys --account Batty -x batty-sparkle.key

# Move batty-sparkle.key to the target Mac, then:
generate_keys --account Batty -f batty-sparkle.key
```

`-x` exports and removes ambiguity about which account; `-f` imports into
the target's login keychain under the same account name. `--account Batty`
must match on both ends — omitting it signs against the default `ed25519`
account and `sign_update` fails with "Signing key not found for account
ed25519" (see `scripts/SPARKLE.md`). After importing, confirm the public
half still matches `SU_PUBLIC_ED_KEY` in `Configuration/App.xcconfig` — the
credentials check does this automatically.

## Backup: what's irreplaceable, and how bad is losing it

Three files matter. Store them somewhere you control and isn't just "the one
Mac that happens to have them" — a password manager or an encrypted volume
both work; pick whichever you already trust with other credentials. This doc
doesn't prescribe a product.

| Item | If lost | Recoverable? |
|---|---|---|
| ASC API key `.p8` | Can't notarize from a machine without an existing profile | Apple lets you generate a new key in App Store Connect — friction, not data loss |
| Developer ID `.p12` | Can't sign from a machine without the cert already imported | Re-issue from Apple — but see the revocation history above; treat re-issuing as a last resort |
| Sparkle EdDSA private key | **Can never sign an update again** | **No.** `SUPublicEDKey` is baked into every copy of Batty already installed. Without the matching private key, no future release can be verified by those installs — not through Apple, not through any recovery flow. There is no second copy unless one was exported. |

The Sparkle key is the one that matters most. Losing the `.p8` or the `.p12`
costs time. Losing the Sparkle private key with no backup means every
existing install is stuck on its current version forever, or has to be
manually reinstalled from a fresh DMG with a new key — a break in your own
users' trust chain, not just an inconvenience to you.

**If the Sparkle key has never been exported, export it now**
(`generate_keys --account Batty -x batty-sparkle.key`, see above) and put
the file somewhere backed up before doing anything else in this doc.

### Restore, end to end, on a fresh Mac

1. Install Xcode + Command Line Tools, `brew install create-dmg fileicon`.
2. Import the Developer ID `.p12` into the login keychain (Keychain Access
   or `security import`).
3. Copy the ASC API key to `~/.appstoreconnect/AuthKey_DWLP54ACTJ.p8`, run
   `scripts/setup-keys.sh`.
4. Import the Sparkle key: `generate_keys --account Batty -f
   batty-sparkle.key` (needs one `scripts/build.sh` run first so the
   `generate_keys` binary exists as a Sparkle SPM artifact).
5. Run `scripts/preflight.sh --credentials-only` — expect every item to
   pass. Fix whatever doesn't before attempting a release from this machine.

## Why extend `preflight.sh` instead of a new script

The original ask (#0306) offered a choice: extend `scripts/preflight.sh`, or
add a separate credential-check script for it to call. A new
`check-release-integrity.sh` would have duplicated logic `preflight.sh`
already has — the `TEAM_ID`/`SIGN_IDENTITY` lookup, the notary-profile probe,
the `pass`/`fail`/`warn`/`section` output format — and given users two
commands to remember for overlapping questions ("is this machine ready to
release" vs. "can this machine sign/notarize"). `preflight.sh` already had a
`--skip-build` fast path; the credential checks it already ran were just
warn-level and incomplete (no expiry, no `.p8`, no Sparkle key, no
`Active.xcconfig` check). Adding `--credentials-only` and promoting the
release-blocking checks from warn to fail keeps one entry point
(`scripts/preflight.sh`) with two depths, rather than two entry points that
partially overlap.
