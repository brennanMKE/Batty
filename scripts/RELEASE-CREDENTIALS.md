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

## Gate: release.sh won't start without it

`scripts/release.sh` runs `scripts/preflight.sh --credentials-only` as its
first action and aborts — before touching `build/`, `dist/`, or anything
else — if this machine can't sign, notarize, and publish right now. This is
the direct fix for how #0306 was filed: a release attempt used to start
anyway and die mid-pipeline on a machine that was missing a credential from
the start. The failure message points at the check's own `[✗]` output.

```bash
scripts/release.sh                      # gated by default
scripts/release.sh --skip-credential-check   # deliberate override
```

Use the override only when you know the check itself can't run correctly
here for some unrelated reason (e.g. testing the pipeline against a mocked
identity) — it does not relax any check inside `preflight.sh`, it just skips
calling it.

## Replicate: moving capability to a second Mac

Three things move independently. None of them regenerate themselves — either
copy the artifact, or (for the notary profile) recreate it from the artifact
that backs it. `scripts/export-release-credentials.sh` and
`scripts/import-release-credentials.sh` automate all three in one pair of
commands; the manual steps under each item below are the fallback if you'd
rather do it by hand (or need to move just one item).

```bash
# On the source Mac (the one that already works)
scripts/export-release-credentials.sh ~/Backups/batty-release-credentials

# Move the resulting folder to the target Mac by a channel you trust
# (see "Backup," below, for where NOT to leave it sitting around)

# On the target Mac
scripts/import-release-credentials.sh ~/Backups/batty-release-credentials
```

Both scripts are non-destructive by construction: export only reads (never
modifies) the source keychain, and import skips-and-reports any item that's
already present on the target rather than overwriting it — importing twice,
or importing onto a Mac that already has some of the three credentials, is
always safe. The export script refuses to write its bundle inside this repo;
the `.p12` passphrase is never handled by either script at all — both
`security export` and `security import` are invoked without `-P`, so
`security` itself prompts through its own secure GUI dialog. (`-P` puts the
passphrase in `security`'s own argv, which `ps` exposes to other local users
on the machine for the life of the call — Apple's own `security export -h` /
`security import -h` flag it: "Use of the -P option is insecure.")

Read both scripts' `--help` for the full list of what each item's
present/missing/skip states look like — the flow below is the manual
equivalent of what they automate.

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
`import-release-credentials.sh` installs the `.p8` to this same path and
either runs `setup-keys.sh` for you (`--run-setup-keys`) or prints the
command to run yourself — it never calls Apple on its own initiative.

### 2. Developer ID Application cert + private key — export/import a `.p12`

`export-release-credentials.sh` uses `security export -t identities`, which
has no per-item filter — if the login keychain holds more than one signing
identity, the `.p12` will contain all of them (harmless, just broader than
strictly necessary; the script warns when this applies). For a `.p12`
containing exactly one identity, use the manual GUI path instead:

The cert must travel with its private key, which means a password-protected
`.p12`, not a re-issue from Apple. **Do not use Xcode's "Manage
Certificates" → re-issue** — that mints a *new* certificate, and this
project's account has already hit certificate-revocation trouble from
extra/duplicate certs (#0270, #0273, #0278, #0281). Move the existing one:

1. On the source Mac: open Keychain Access → My Certificates → find
   "Developer ID Application: Brennan Stehling (XV8BAAVZ6V)" → expand it so
   the private key shows underneath → select both the cert and the key →
   right-click → Export 2 items… → save as a password-protected `.p12`
   named `DeveloperID.p12` (matches what `import-release-credentials.sh`
   looks for).
2. Move the `.p12` to the target Mac (same channel as the `.p8` — see
   Backup below for where that should live).
3. On the target Mac: double-click the `.p12` (or File → Import Items… in
   Keychain Access), enter the export password, choose the login keychain —
   or run `scripts/import-release-credentials.sh` against the folder
   containing it, which does the same via `security import` and, either
   way, first checks whether a Developer ID Application identity for this
   team already exists and skips rather than importing a duplicate.
4. Confirm with `security find-identity -p codesigning -v` — the identity
   should list with a numbered entry, meaning cert *and* key are both
   present. `scripts/preflight.sh --credentials-only` checks the same thing.

### 3. Sparkle EdDSA private key — export/import via `generate_keys`

`export-release-credentials.sh` / `import-release-credentials.sh` wrap
exactly this (as `batty-sparkle.key` in the bundle); by hand it's:

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

**`-f` will never overwrite an existing key** — verified directly from
Sparkle's source: it goes through `SecItemAdd`, which fails with
`errSecDuplicateItem` and exits rather than replacing what's there.
`import-release-credentials.sh` probes with `-p` first and skips before
ever calling `-f`, so a key that's already present is reported as "nothing
was changed" rather than surfacing as `-f`'s own error text. Never run
`generate_keys -f` by hand against a machine you're not certain lacks the
key already — if you're unsure, run `generate_keys --account Batty -p`
first (read-only) to check.

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

**If the Sparkle key has never been exported, export it now**:

```bash
scripts/export-release-credentials.sh ~/Backups/batty-release-credentials
```

(or by hand: `generate_keys --account Batty -x batty-sparkle.key`, see
above) — and put the resulting bundle somewhere backed up before doing
anything else in this doc.

### Restore, end to end, on a fresh Mac

1. Install Xcode + Command Line Tools, `brew install create-dmg fileicon`.
2. One `scripts/build.sh` run, so the Sparkle SPM artifacts
   (`generate_keys`) exist for the next step.
3. Restore the three credentials from wherever the backup bundle lives:

   ```bash
   scripts/import-release-credentials.sh /path/to/batty-release-credentials
   ```

   This installs the `.p8`, imports the `.p12` (prompts for its
   passphrase), imports the Sparkle key, and finishes by running
   `scripts/preflight.sh --credentials-only` itself. Pass
   `--run-setup-keys` to also create the notarytool profile in the same
   step; otherwise run `scripts/setup-keys.sh` yourself as the script
   prints.

   Or by hand, item by item:
   - Import the Developer ID `.p12` into the login keychain (Keychain
     Access or `security import`).
   - Copy the ASC API key to `~/.appstoreconnect/AuthKey_DWLP54ACTJ.p8`,
     run `scripts/setup-keys.sh`.
   - Import the Sparkle key: `generate_keys --account Batty -f
     batty-sparkle.key`.
4. Run `scripts/preflight.sh --credentials-only` — expect every item to
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
