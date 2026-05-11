# Sparkle auto-update configuration

The Sparkle SPM dependency is wired in (`BattyKit/Package.swift`), the
controller class lives in `BattyKit/Sources/BattyKit/UpdaterController.swift`,
and the "Check for Updates…" menu item is in `BattyCommands`. The menu item
is disabled until `SUFeedURL` is set on the app's `Info.plist` at runtime —
which means until the three user-side setup steps below are completed,
Sparkle stays dormant.

## One-time setup

1. **Pick an appcast hosting URL.** Common options:
   - GitHub Pages on the project repo: `https://brennanMKE.github.io/Batty/appcast.xml` (free, push-to-deploy via a `gh-pages` branch).
   - S3 / CloudFront for higher control.
   - Self-hosted on `sstools.co`.

   Pick whichever and remember the URL for the rest of these steps.

2. **Generate an EdDSA signing key pair.** Sparkle ships `generate_keys` in
   the SPM checkout. Build it once:

   ```bash
   xcrun swift run --package-path .build/checkouts/Sparkle/bin generate_keys
   ```

   The tool stores the private key in your keychain under the name
   `https://sparkle-project.org` and prints the public key. Save the printed
   public key somewhere — you'll embed it in step 3.

3. **Add `SUFeedURL` and `SUPublicEDKey` to the Batty target's Info.plist.**
   The project uses `GENERATE_INFOPLIST_FILE = YES`, so the synthesized plist
   doesn't honor arbitrary keys via `INFOPLIST_KEY_*` build settings. Options:
   - Add an Info.plist file (`Batty/Info.plist`) with `SUFeedURL` and
     `SUPublicEDKey`, then set `INFOPLIST_FILE = Batty/Info.plist` and
     `GENERATE_INFOPLIST_FILE = NO` on the Batty target.
   - Or, in Xcode, target Build Settings → "Info" section → add
     `INFOPLIST_KEY_SUFeedURL` and `INFOPLIST_KEY_SUPublicEDKey` if your
     Xcode honors them (verify by inspecting the built bundle's
     `Contents/Info.plist`).

   Minimum keys:

   ```xml
   <key>SUFeedURL</key>
   <string>https://your-host/appcast.xml</string>
   <key>SUPublicEDKey</key>
   <string>BASE64_PUBLIC_KEY_FROM_STEP_2</string>
   <key>SUEnableAutomaticChecks</key>
   <true/>
   ```

## Per-release

The release pipeline (`scripts/release.sh`) produces `dist/Batty-<sha>.dmg`.
For Sparkle to advertise the build, append a new `<item>` to
`appcast.xml`:

```xml
<item>
  <title>1.0.1</title>
  <pubDate>Mon, 12 May 2026 00:00:00 +0000</pubDate>
  <enclosure
    url="https://your-host/Batty-1.0.1.dmg"
    sparkle:version="42"
    sparkle:shortVersionString="1.0.1"
    sparkle:edSignature="EDDSA_SIG_FROM_sign_update"
    length="12345678"
    type="application/octet-stream" />
</item>
```

Use `sign_update` (also in Sparkle's `bin/`) to compute the EdDSA signature
over the DMG before publishing:

```bash
.build/checkouts/Sparkle/bin/sign_update path/to/Batty-1.0.1.dmg
```

The output is the value for `sparkle:edSignature`.

Push the updated `appcast.xml` to your hosting destination. Sparkle clients
poll the feed and prompt the user on next launch (or via "Check for
Updates…" from the app menu).

## Verification

- With `SUFeedURL` empty: the menu item is disabled.
- With `SUFeedURL` set: the menu item enables; clicking it runs Sparkle's
  standard "fetching appcast" UI.
- With a fresh appcast item: the user sees the prompt, the DMG downloads,
  and Sparkle installs on relaunch.
