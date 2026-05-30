#!/usr/bin/env zsh
# Emit a ready-to-paste Sparkle <item> for a built DMG.
#
# Every attribute is derived from the artifact itself — the app's
# CFBundleShortVersionString and CFBundleVersion are read from the bundle
# *inside* the DMG, the length is the DMG's byte count, and the EdDSA
# signature is computed over the DMG. Nothing is hand-typed.
#
# Why this exists (#0226): 1.0.3 shipped with a hand-typed
# sparkle:version="20260521" while the DMG's real CFBundleVersion was
# 20260522, and a marketing version that was never bumped
# (CFBundleShortVersionString=1.0.2 inside a DMG named "1.0.3"). Sparkle
# compares CFBundleVersion for the update decision but prints the marketing
# strings in its dialog, so clients saw "You're up to date" naming 1.0.3 as
# newest while running "1.0.2". Generating the appcast item from the artifact
# makes both drifts impossible.
#
# Usage:
#   scripts/appcast-item.sh dist/Batty-<sha>.dmg
#
# The printed enclosure URL and release-notes link follow the published
# convention and are derived from the marketing version:
#   url:             https://batty.sstools.co/downloads/Batty-<X.Y.Z>.dmg
#   releaseNotesLink https://batty.sstools.co/changelog.html#v<X-Y-Z>
# Copy the DMG to website/downloads/Batty-<X.Y.Z>.dmg before deploying.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"

DMG="${1:-}"
if [[ -z "$DMG" || ! -f "$DMG" ]]; then
    print -u2 "usage: scripts/appcast-item.sh <path/to/Batty-*.dmg>"
    exit 2
fi

MIN_SYSTEM=$(grep -E '^MACOSX_DEPLOYMENT_TARGET' "$REPO_ROOT/Configuration/Build.xcconfig" \
    2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ')
MIN_SYSTEM="${MIN_SYSTEM:-15.6}"

# Locate sign_update — it ships as an SPM artifact, either under the package
# .build (CLI swift build) or Xcode's DerivedData (Xcode-driven build).
find_sign_update() {
    local candidates=(
        "$REPO_ROOT/BattyKit/.build/artifacts/sparkle/Sparkle/bin/sign_update"
        $HOME/Library/Developer/Xcode/DerivedData/Batty-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update(N)
    )
    local c
    for c in $candidates; do
        [[ -x "$c" ]] && { print -r -- "$c"; return 0 }
    done
    return 1
}

SIGN_UPDATE=$(find_sign_update) || {
    print -u2 "error: sign_update not found. Build BattyKit once (scripts/build.sh) so"
    print -u2 "       the Sparkle SPM artifacts are produced, then retry."
    exit 1
}

# Read the version fields from the app bundle inside the DMG. Mount read-only,
# no-browse, on a random mountpoint; always detach on exit.
MOUNT_DIR=$(hdiutil attach "$DMG" -nobrowse -readonly -mountrandom /tmp \
    | awk '/\/tmp\// {print $NF; exit}')
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
    print -u2 "error: failed to mount $DMG"
    exit 1
fi
trap 'hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true' EXIT

APP=$(print -r -- "$MOUNT_DIR"/*.app(N) | head -1)
if [[ -z "$APP" || ! -d "$APP" ]]; then
    print -u2 "error: no .app found inside $DMG"
    exit 1
fi

PLIST="$APP/Contents/Info.plist"
SHORT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")

if [[ -z "$SHORT_VERSION" || -z "$BUILD_VERSION" ]]; then
    print -u2 "error: could not read version fields from $PLIST"
    exit 1
fi

# sign_update prints: sparkle:edSignature="..." length="..."
SIG_LINE=$("$SIGN_UPDATE" --account Batty "$DMG")
ED_SIGNATURE=$(print -r -- "$SIG_LINE" | grep -oE 'sparkle:edSignature="[^"]+"' | sed -E 's/.*="([^"]+)"/\1/')
LENGTH=$(print -r -- "$SIG_LINE" | grep -oE 'length="[0-9]+"' | sed -E 's/.*="([0-9]+)"/\1/')

if [[ -z "$ED_SIGNATURE" || -z "$LENGTH" ]]; then
    print -u2 "error: sign_update output not understood:"
    print -u2 "       $SIG_LINE"
    exit 1
fi

# Cross-check length against the actual file size.
ACTUAL_BYTES=$(stat -f '%z' "$DMG")
if [[ "$LENGTH" != "$ACTUAL_BYTES" ]]; then
    print -u2 "error: sign_update length ($LENGTH) != DMG byte size ($ACTUAL_BYTES)"
    exit 1
fi

ANCHOR="v${SHORT_VERSION//./-}"
PUBDATE=$(date -u +"%a, %d %b %Y 00:00:00 +0000")

cat <<EOF
    <item>
      <title>${SHORT_VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:minimumSystemVersion>${MIN_SYSTEM}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://batty.sstools.co/changelog.html#${ANCHOR}</sparkle:releaseNotesLink>
      <description><![CDATA[
        TODO: paste user-visible release notes for ${SHORT_VERSION} here.
      ]]></description>
      <enclosure
        url="https://batty.sstools.co/downloads/Batty-${SHORT_VERSION}.dmg"
        sparkle:version="${BUILD_VERSION}"
        sparkle:shortVersionString="${SHORT_VERSION}"
        sparkle:edSignature="${ED_SIGNATURE}"
        length="${LENGTH}"
        type="application/octet-stream" />
    </item>
EOF

print -u2 ""
print -u2 "Generated <item> for Batty ${SHORT_VERSION} (build ${BUILD_VERSION})."
print -u2 "  - Paste it as the FIRST <item> in website/appcast.xml (newest first)."
print -u2 "  - Copy the DMG to website/downloads/Batty-${SHORT_VERSION}.dmg."
print -u2 "  - Fill in the <description> release notes."
