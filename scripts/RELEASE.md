# Cutting a Batty release

End-to-end checklist for producing a signed, notarized, stapled DMG that
Gatekeeper accepts on a clean Mac. Pairs with `scripts/release.sh`.

## One-time setup

- **Apple Developer account** with a Developer ID Application certificate
  installed in your login keychain. Team ID: `XV8BAAVZ6V`
  (`Configuration/Build.xcconfig:DEVELOPMENT_TEAM`).
- **Notary keychain profile.** Run `scripts/setup-keys.sh` and follow the
  prompts. This stores an app-specific Apple ID password under the
  `Batty-notary` profile that `notarytool` looks for.
- **Sparkle EdDSA key**: `generate_keys` stores the private key in your
  keychain; the public key goes into `Info.plist` as `SUPublicEDKey`.
  See `scripts/SPARKLE.md`.
- **EC2 website deploy env vars** in your shell init:
  - `export BATTY_EC2_KEY=~/keys/batty.pem` — path to your AWS .pem
    (must be `chmod 600`).
  - `export BATTY_EC2_HOST=ec2-user@batty.sstools.co` — SSH login.
  - `export BATTY_EC2_PATH=/var/www/batty` — remote document root.
  - `export BATTY_EC2_PORT=22` — optional, defaults to 22.

## Release steps

0. **Run the preflight**

   ```bash
   scripts/preflight.sh
   ```

   Walks every release-readiness gate (build, tests, version drift,
   Sparkle plist, signing cert, notarytool profile, website env vars,
   fork pin, working tree). Fix every `[✗]` before continuing;
   warnings (`[!]`) are advisory but worth scanning. `--skip-build`
   for a faster ad-hoc check, `--strict` to promote warnings to
   failures, `--allow-dirty` for a dry-run scope.

1. **Choose the version**

   Bump `MARKETING_VERSION` in `Configuration/App.xcconfig` — that
   file is the single source of truth for the marketing version.
   `project.pbxproj` no longer carries per-target overrides and the
   Info.plist reads the value via `$(VAR)` substitution. The
   preflight enforces this: any `MARKETING_VERSION = …` line that
   appears in `project.pbxproj` is a `[✗]`. SemVer convention
   (`1.2.0`).

   **Do not bump `CURRENT_PROJECT_VERSION` by hand.** `release.sh`
   overrides it at archive time with today's UTC date in `YYYYMMDD`
   form (e.g. `20260514`) — the monotonically-increasing build
   number Sparkle compares against. The static value left in
   `App.xcconfig` is only used by Xcode-driven Debug builds, which
   Sparkle never sees. The auto-derived number is printed at the
   end of `release.sh` so it can be pasted into `appcast.xml` as
   `sparkle:version`.

   Commit the marketing-version bump on its own as
   `Bump version to <X.Y.Z>`.

2. **Sanity-check the build and run tests**

   ```bash
   scripts/build.sh          # confirms the build is clean
   scripts/build.sh unit     # BattyKit unit tests — fast, <30 s
   scripts/run-ui-tests.sh   # full UI test suite — ~10 min, locks the machine
   ```

   All three must pass clean. Don't proceed if anything is red.

   **Run the preflight on the Mac mini**, not the MacBook. The UI test
   suite locks the machine for ~10 minutes. The Mac mini keeps your
   development machine free.

   UI tests are the gate for releases. Any regression found here must be
   fixed and tracked as a new issue before cutting the release — do not
   ship over a failing UI test. Unit tests (`scripts/build.sh unit`)
   should already be passing from routine development commits.

3. **Run the release pipeline**

   ```bash
   scripts/release.sh
   ```

   This archives → exports → signs → notarizes → staples → DMG-packages →
   verifies. Output lands at `dist/Batty-<sha>.dmg`. Notarization round-trip
   typically takes 2–10 minutes; the script blocks via `notarytool ... --wait`.

   **Do not run this step autonomously from an agent session.** The submission
   counts as modifying a shared system (Apple's notary service).

4. **Verify the DMG**

   ```bash
   scripts/verify-dmg.sh dist/Batty-<sha>.dmg
   ```

   Confirms signing, notarization, stapling, and Gatekeeper acceptance under
   quarantine. Should print all checks passing.

5. **Smoke-test on a clean Mac**

   Either:
   - A fresh user account that has never run Batty, OR
   - A spare Mac / VM where the bundle ID hasn't been seen.

   Drag from the DMG to `/Applications`, double-click, confirm it opens
   without right-click bypass and without "from an unidentified developer"
   warning.

6. **Update the appcast and changelog**

   - Add a `<item>` entry to `website/appcast.xml` with the new
     `<sparkle:minimumSystemVersion>`, release-notes link, and
     enclosure URL pointing at the DMG you copied into
     `website/downloads/Batty-<X.Y.Z>.dmg`. Use the **build number
     printed at the end of `release.sh`** (the `YYYYMMDD` value) for
     `sparkle:version`, and the marketing version for
     `sparkle:shortVersionString`. Generate the
     `sparkle:edSignature` via
     `BattyKit/.build/artifacts/sparkle/Sparkle/bin/sign_update --account Batty`
     (see `scripts/SPARKLE.md`; the `--account Batty` flag is required).
   - Stamp `website/changelog.html` — add an `<article id="vX-Y-Z">`
     summarising user-visible changes for this version. Link closed
     `#NNNN` issues from the milestone.

7. **Deploy the website**

   ```bash
   scripts/deploy-website.sh
   ```

   Pushes `website/` to `$BATTY_EC2_HOST:$BATTY_EC2_PATH` via rsync over
   SSH using `$BATTY_EC2_KEY`. Verifies the env vars and key
   permissions before pushing. Sparkle clients poll the appcast on a
   schedule, so the new version appears in "Check for Updates…" within
   a few hours.

8. **Tag the release**

   ```bash
   scripts/tag-release.sh
   ```

   Reads `MARKETING_VERSION` from `App.xcconfig`, creates an
   annotated `v<X.Y.Z>` tag on the current HEAD, and prompts before
   pushing to origin. `--push` or `--no-push` to skip the prompt.

9. **Write release notes**

   - User-visible changes only. Match the `## Changes` section style from
     the previous tag.
   - Link any closed `#NNNN` issues for the milestone.
   - Note any known regressions or Gotchas the user should be aware of.
   - Mirror these notes in `website/changelog.html` so the public site
     and the git tag stay in sync.

## Troubleshooting

- **`spctl --assess` fails on the freshly-signed `.app` but the DMG is
  fine.** Stapling-before-DMG vs after issue. The script staples the DMG;
  re-test via `verify-dmg.sh` rather than the raw `.app`.
- **Notarization rejected.** `xcrun notarytool log <submission-id>
  --keychain-profile Batty-notary` prints the actual issues. Most common
  causes: hardened runtime missing on a binary, embedded `.dylib`s without
  a signature, or a mismatched bundle ID.
- **DMG fails Gatekeeper on the test Mac.** Make sure the test Mac actually
  doesn't have a previous unstapled copy in its quarantine cache. `spctl
  --reset-default --type execute` clears it; sometimes a logout helps too.
