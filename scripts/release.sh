#!/usr/bin/env zsh
# Build, sign, notarize, and package Batty.app for distribution.
#
# Produces dist/Batty-<sha>.dmg with a drag-to-Applications layout, signed
# with Developer ID and notarized so Gatekeeper accepts it on first launch
# without right-click bypass.
#
# Usage:
#   scripts/release.sh                     # gated: aborts if this machine
#                                           # can't sign/notarize/publish (#0306)
#   scripts/release.sh --skip-credential-check   # deliberate override

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
PROJECT="$REPO_ROOT/Batty.xcodeproj"
SCHEME="Batty (Prod)"
APP_NAME="Batty"
BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/Export"
EXPORT_PLIST="$BUILD_DIR/exportOptions.plist"

NOTARY_PROFILE="Batty-notary"
TEAM_ID="XV8BAAVZ6V"
SIGN_IDENTITY="Developer ID Application: Brennan Stehling ($TEAM_ID)"

SKIP_CREDENTIAL_CHECK=0
for arg in "$@"; do
    case "$arg" in
        --skip-credential-check) SKIP_CREDENTIAL_CHECK=1 ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed '/^set -euo/d' | sed 's/^# *//'
            exit 0
            ;;
        *)
            print -u2 "error: unknown flag $arg"
            exit 1
            ;;
    esac
done

# --- Credential gate (#0306) ---------------------------------------------
#
# Nothing previously invoked the credential check programmatically, so a
# release attempt on an unequipped machine started anyway and died mid-way
# (the exact complaint #0306 was filed over). Run the fast, no-build
# "can this machine sign/notarize/publish right now" gate first and abort
# before doing anything else if it fails. --skip-credential-check is the
# explicit, deliberate escape hatch for a known-good machine whose check
# can't run for some other reason; it does not bypass any check inside
# preflight.sh itself.

if (( SKIP_CREDENTIAL_CHECK )); then
    print "==> Skipping credential gate (--skip-credential-check)"
else
    print "==> Checking release credentials (scripts/preflight.sh --credentials-only)"
    if ! "$SCRIPT_DIR/preflight.sh" --credentials-only; then
        print -u2 ""
        print -u2 "error: this machine is not release-capable — see the [✗] items above"
        print -u2 "       for what's missing and how to fix it."
        print -u2 "       Override (only if you know what you're doing):"
        print -u2 "         scripts/release.sh --skip-credential-check"
        print -u2 "       See scripts/RELEASE-CREDENTIALS.md."
        exit 1
    fi
    print ""
fi

# --- Preflight ---------------------------------------------------------------

if [[ ! -d "$PROJECT" ]]; then
    print -u2 "error: $PROJECT not found"
    exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    print -u2 "error: create-dmg not installed. Run: brew install create-dmg"
    exit 1
fi

if ! command -v fileicon >/dev/null 2>&1; then
    print -u2 "error: fileicon not installed. Run: brew install fileicon"
    exit 1
fi

if ! security find-identity -p codesigning -v | grep -q "$SIGN_IDENTITY"; then
    print -u2 "error: signing identity not found in Keychain:"
    print -u2 "       $SIGN_IDENTITY"
    print -u2 "       Add via Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application"
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    print -u2 "error: notarytool keychain profile '$NOTARY_PROFILE' missing or invalid."
    print -u2 "       Set up via:"
    print -u2 "         xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
    print -u2 "           --key ~/.appstoreconnect/AuthKey_<KEY_ID>.p8 \\"
    print -u2 "           --key-id <KEY_ID> \\"
    print -u2 "           --issuer <ISSUER_UUID>"
    exit 1
fi

# --- Build & export ----------------------------------------------------------

print "==> Cleaning previous build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

BUILD_NUMBER="$(date -u +%Y%m%d)"
print "==> Build number for this release: $BUILD_NUMBER"

print "==> Writing export options plist"
cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

print "==> Archiving Release"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS' \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

print "==> Exporting signed app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST"

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
    print -u2 "error: exported app not found at $APP_PATH"
    exit 1
fi

# #0273: Contents/Resources/bin/{BattyBroker,batty} are sealed as
# *resources*, not nested code. -exportArchive's re-signing pass reaches
# nested code (Contents/Frameworks/*, the main executable); a loose Mach-O
# sitting under Resources/ is not that, and Archive-time signing (confirmed
# directly, by instrumenting the Embed phases and running a real `xcodebuild
# archive`) stamps them with whatever identity Automatic signing resolved
# for that build -- Apple Development on a machine with no Developer ID
# certificate, and unverified either way on one that has one, since export
# behavior on loose resource binaries could not be tested here. Re-sign both
# explicitly with the same Developer ID identity/options the app itself was
# just exported with, then re-sign the app bundle so its resource seal
# (Contents/_CodeSignature/CodeResources) reflects the now-modified file
# bytes -- otherwise the app's own signature verification below would fail
# against files it no longer recognizes. Re-signing something that turns out
# to already be correctly signed is harmless and produces the same end
# state, so this is safe regardless of what -exportArchive actually does.
print "==> Re-signing embedded agent + CLI with the Developer ID identity (#0273)"
ENTITLEMENTS_PLIST="$BUILD_DIR/app-entitlements.plist"
codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null > "$ENTITLEMENTS_PLIST" || true
for rel_path in "Contents/Resources/bin/BattyBroker" "Contents/Resources/bin/batty"; do
    bin_path="$APP_PATH/$rel_path"
    if [[ ! -f "$bin_path" ]]; then
        print -u2 "error: $rel_path missing from exported app"
        exit 1
    fi
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$bin_path"
    print "    re-signed: $rel_path"
done
if [[ -s "$ENTITLEMENTS_PLIST" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS_PLIST" "$APP_PATH"
else
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP_PATH"
fi
print "    re-signed: $APP_NAME.app (resource seal updated)"

print "==> Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Contents/Resources/bin is sealed as a *resource*, not nested code, so
# --deep --strict above never inspects either binary dropped there — an
# ad-hoc-signed or timestamp-less CLI/agent would pass it silently and only
# surface as a notarization rejection several minutes later, after the slow
# submit-and-wait round trip below. Fail fast, before that cost, by
# inspecting each directly for exactly what the notary service checks:
# Developer ID (not ad-hoc), the app's own team, hardened runtime, and a
# secure timestamp. This should always pass now that the re-sign above ran
# unconditionally, but it stays as a genuine assertion rather than a
# tautology — a future edit that removes or reorders the re-sign step would
# still be caught here.
print "==> Verifying embedded agent + CLI signatures directly (not covered by --deep --strict)"
APP_CS_OUT=$(codesign -dv "$APP_PATH" 2>&1)
APP_TEAM=$(print -r -- "$APP_CS_OUT" | awk -F= '/^TeamIdentifier=/ { print $2 }')
# `exit` inside the awk action would close the pipe while codesign is still
# writing its multi-line -dvvv output, so codesign gets SIGPIPE, the pipeline
# returns 141, and `set -o pipefail` + `set -e` (line 8) would abort the
# whole release right here, every time — reproduced 10/10 in review. The
# `!seen` guard keeps only the first (leaf) match without closing the pipe
# early.
APP_AUTHORITY=$(codesign -dvvv "$APP_PATH" 2>&1 | awk -F= '/^Authority=/ && !seen { print $2; seen = 1 }')
if [[ "$APP_AUTHORITY" != "$SIGN_IDENTITY" ]]; then
    print -u2 "error: exported app's Authority is '$APP_AUTHORITY', expected '$SIGN_IDENTITY'"
    print -u2 "       -exportArchive did not sign with the Developer ID identity requested above."
    exit 1
fi
for rel_path in "Contents/Resources/bin/BattyBroker" "Contents/Resources/bin/batty"; do
    bin_path="$APP_PATH/$rel_path"
    if [[ ! -f "$bin_path" ]]; then
        print -u2 "error: $rel_path missing from exported app"
        exit 1
    fi

    CS_BIN_OUT=$(codesign -dv "$bin_path" 2>&1)
    if print -r -- "$CS_BIN_OUT" | grep -q "flags=.*adhoc"; then
        print -u2 "error: $rel_path is ad-hoc signed — will fail notarization"
        exit 1
    fi

    BIN_TEAM=$(print -r -- "$CS_BIN_OUT" | awk -F= '/^TeamIdentifier=/ { print $2 }')
    if [[ "$BIN_TEAM" != "$APP_TEAM" ]]; then
        print -u2 "error: $rel_path TeamIdentifier is '$BIN_TEAM', expected the app's '$APP_TEAM'"
        exit 1
    fi

    # Team ID alone isn't enough: an Apple Development and a Developer ID
    # Application certificate share the same TeamIdentifier, but only the
    # latter is notarization-eligible. Require the identical Authority as
    # the app itself — this is the check that would have caught #0270's
    # "presumed but not independently verified" gap in
    # docs/batty-cli-install.md §6 (whether archive/export actually re-signs
    # a loose Resources/bin/* binary with the distribution identity, or
    # leaves it however the build-time Embed phase signed it) had the
    # re-sign step above not closed it directly.
    BIN_AUTHORITY=$(codesign -dvvv "$bin_path" 2>&1 | awk -F= '/^Authority=/ && !seen { print $2; seen = 1 }')
    if [[ "$BIN_AUTHORITY" != "$APP_AUTHORITY" ]]; then
        print -u2 "error: $rel_path Authority is '$BIN_AUTHORITY', expected the app's '$APP_AUTHORITY'"
        print -u2 "       Same team, wrong certificate type — not notarization-eligible."
        exit 1
    fi

    if ! print -r -- "$CS_BIN_OUT" | grep -q "flags=.*runtime"; then
        print -u2 "error: $rel_path does not have hardened runtime enabled"
        exit 1
    fi

    if ! print -r -- "$CS_BIN_OUT" | grep -q "^Timestamp="; then
        print -u2 "error: $rel_path has no secure timestamp — the notary service will reject it"
        exit 1
    fi

    print "    OK: $rel_path (Authority=$BIN_AUTHORITY, hardened runtime, secure timestamp)"
done

# Version-consistency gate (#0226): confirm the *built* bundle carries the
# versions we expect before it gets packaged and notarized. Two failure modes
# this catches:
#   - CFBundleShortVersionString != MARKETING_VERSION from App.xcconfig — a
#     per-target pbxproj override or stale build setting won and the marketing
#     version drifted (1.0.3 shipped as 1.0.2).
#   - CFBundleVersion != the build number we injected — the archive didn't
#     honor the CURRENT_PROJECT_VERSION override, so Sparkle's comparison key
#     would be wrong.
# Failing here is cheap; discovering it in users' update dialogs is not.
EXPECTED_SHORT=$(grep -E '^MARKETING_VERSION' "$REPO_ROOT/Configuration/App.xcconfig" \
    | head -1 | awk -F= '{print $2}' | tr -d ' ')
ACTUAL_SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
ACTUAL_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
if [[ "$ACTUAL_SHORT" != "$EXPECTED_SHORT" ]]; then
    print -u2 "error: built CFBundleShortVersionString ($ACTUAL_SHORT) != MARKETING_VERSION ($EXPECTED_SHORT)"
    print -u2 "       The bundle's marketing version drifted from App.xcconfig. Check for a"
    print -u2 "       per-target MARKETING_VERSION override in project.pbxproj (preflight flags this)."
    exit 1
fi
if [[ "$ACTUAL_BUILD" != "$BUILD_NUMBER" ]]; then
    print -u2 "error: built CFBundleVersion ($ACTUAL_BUILD) != injected build number ($BUILD_NUMBER)"
    print -u2 "       The archive did not honor CURRENT_PROJECT_VERSION=$BUILD_NUMBER."
    exit 1
fi
print "==> Version check: $ACTUAL_SHORT (build $ACTUAL_BUILD) matches App.xcconfig + build number"

# AppIcon.icns is generated from Assets.xcassets/AppIcon.appiconset during the
# build and lives inside the built bundle. The same file drives both the
# mounted volume's Finder icon (--volicon below) and the DMG file's Finder
# icon (fileicon, applied after stapling).
APP_ICON="$APP_PATH/Contents/Resources/AppIcon.icns"
if [[ ! -f "$APP_ICON" ]]; then
    print -u2 "error: AppIcon.icns not found at $APP_ICON"
    exit 1
fi

# --- DMG ---------------------------------------------------------------------

GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || print unknown)"

# Build/sign/notarize/staple all happen against a fixed-name DMG that matches
# the volume name. Reason: when the DMG filename and --volname differ, macOS
# (Gatekeeper provenance handling, observed during notarytool roundtrip) can
# silently rename the file on disk to match the volume — which then breaks
# the next step in the pipeline. Keeping name == volname avoids the rename;
# we tag with the git sha by renaming once, after stapling completes.
WORK_DMG="$DIST_DIR/Batty.dmg"
DMG_PATH="$DIST_DIR/Batty-$GIT_SHA.dmg"

print "==> Creating DMG: $WORK_DMG"
rm -f "$WORK_DMG" "$DMG_PATH"
create-dmg \
    --volname "Batty" \
    --volicon "$APP_ICON" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "$APP_NAME.app" 175 190 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 425 190 \
    --no-internet-enable \
    "$WORK_DMG" \
    "$APP_PATH"

print "==> Signing DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$WORK_DMG"

# --- Notarize ----------------------------------------------------------------

print "==> Submitting for notarization (this can take several minutes)"
xcrun notarytool submit "$WORK_DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

print "==> Stapling notarization ticket"
xcrun stapler staple "$WORK_DMG"
xcrun stapler validate "$WORK_DMG"

print "==> Verifying Gatekeeper acceptance"
spctl -a -t open --context context:primary-signature -vv "$WORK_DMG"

print "==> Tagging final artifact with git sha"
mv "$WORK_DMG" "$DMG_PATH"

# Set the DMG file's Finder icon to the app icon. fileicon writes only to
# extended attributes (com.apple.ResourceFork + com.apple.FinderInfo) and
# leaves the disk image's data fork untouched, so codesign and the stapled
# notarization ticket on the .dmg remain valid.
print "==> Setting DMG file icon"
fileicon set "$DMG_PATH" "$APP_ICON"

# --- Cleanup -----------------------------------------------------------------

# Tear down the intermediate build/ directory after the DMG is produced.
# Reason (#0026): leaving a Release Batty.app in build/ means LaunchServices
# indexes it alongside the Debug build that Xcode normally runs from
# DerivedData. Both share bundle id co.sstools.Batty, and tapping a
# notification can route to either — producing two Batty.app dock icons.
# Removing the .app here keeps the DMG as the canonical distributable.
print "==> Cleaning up build artifacts ($BUILD_DIR)"
rm -rf "$BUILD_DIR"

print
print "Done. Distributable at:"
print "  $DMG_PATH"
print "  Build number: $BUILD_NUMBER"
print

# Emit a ready-to-paste appcast <item> derived from the artifact itself, so
# sparkle:version / sparkle:shortVersionString / length / edSignature can never
# be hand-typed out of sync with the DMG (#0226). Best-effort: if the Sparkle
# signing key isn't available on this machine the release still succeeded — the
# operator can run scripts/appcast-item.sh later.
print "==> Appcast item for website/appcast.xml (paste as the first <item>):"
print
if ! "$SCRIPT_DIR/appcast-item.sh" "$DMG_PATH"; then
    print -u2 "note: could not auto-generate the appcast item; run scripts/appcast-item.sh \"$DMG_PATH\" manually."
fi
print
print "On the recipient's Mac:"
print "  - Double-click the DMG"
print "  - Drag Batty.app onto the Applications shortcut"
print "  - Launch from Applications — no Gatekeeper warning, no right-click bypass"
