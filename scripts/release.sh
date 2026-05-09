#!/usr/bin/env zsh
# Build, sign, notarize, and package Batty.app for distribution.
#
# Produces dist/Batty-<sha>.dmg with a drag-to-Applications layout, signed
# with Developer ID and notarized so Gatekeeper accepts it on first launch
# without right-click bypass.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
PROJECT="$REPO_ROOT/Batty.xcodeproj"
SCHEME="Batty"
BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/Export"
EXPORT_PLIST="$BUILD_DIR/exportOptions.plist"

NOTARY_PROFILE="Batty-notary"
TEAM_ID="XV8BAAVZ6V"
SIGN_IDENTITY="Developer ID Application: Brennan Stehling ($TEAM_ID)"

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
    -destination 'generic/platform=macOS'

print "==> Exporting signed app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST"

APP_PATH="$EXPORT_DIR/$SCHEME.app"
if [[ ! -d "$APP_PATH" ]]; then
    print -u2 "error: exported app not found at $APP_PATH"
    exit 1
fi

print "==> Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

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
    --icon "$SCHEME.app" 175 190 \
    --hide-extension "$SCHEME.app" \
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
print
print "On the recipient's Mac:"
print "  - Double-click the DMG"
print "  - Drag Batty.app onto the Applications shortcut"
print "  - Launch from Applications — no Gatekeeper warning, no right-click bypass"
