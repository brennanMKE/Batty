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
- **Sparkle EdDSA key** (only when #0038 lands): `generate_keys` stores the
  private key in your keychain; the public key goes into `Info.plist` as
  `SUPublicEDKey`.

## Release steps

1. **Choose the version**

   Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `Configuration/Build.xcconfig`. Convention: SemVer for marketing
   (`1.2.0`), monotonically-increasing integer for the build (`42`).
   Commit the bump on its own as `Bump version to <X.Y.Z>`.

2. **Sanity-check the build**

   ```bash
   xcodebuild -scheme Batty -destination 'platform=macOS' build
   xcrun swift test --package-path BattyKit
   ```

   Both should pass clean. Don't proceed if anything is red.

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

6. **Tag the release**

   ```bash
   git tag -a v<X.Y.Z> -m "Batty <X.Y.Z>"
   git push origin v<X.Y.Z>
   ```

7. **Publish the appcast** (when #0038 lands)

   - Add a `<item>` entry to `appcast.xml` with the new version, build,
     download URL, EdDSA signature, and release-notes URL.
   - Push to wherever the appcast is hosted (decision pending — see #0038).

8. **Write release notes**

   - User-visible changes only. Match the `## Changes` section style from
     the previous tag.
   - Link any closed `#NNNN` issues for the milestone.
   - Note any known regressions or Gotchas the user should be aware of.

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
