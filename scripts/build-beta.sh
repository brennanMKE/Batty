#!/usr/bin/env zsh
# scripts/build-beta.sh — build a Batty Beta.app for testing alongside the
# Prod app in /Applications, without disturbing it.
#
# #0279: the user runs /Applications/Batty.app (Prod) continuously and wants
# to test Beta builds without interfering with it. This script only ever
# builds — it never launches, quits, or signals the running Prod app, never
# touches launchd/SMAppService, and never copies anything into
# /Applications itself. That last step is yours: this script prints the
# exact command to run once it's done.
#
# Usage:
#   scripts/build-beta.sh                 build unsigned (the default), print the output path
#   scripts/build-beta.sh --sign          build with manual Developer ID signing and the Beta profile
#   scripts/build-beta.sh --sign --notarize
#                                         archive + export (like release.sh), sign with the Developer ID,
#                                         package dist/Batty-Beta-<sha>.dmg, notarize and staple it
#   scripts/build-beta.sh --sign --notarize --no-submit
#                                         the same up to the DMG, then stop before `notarytool submit`;
#                                         writes dist/Batty-Beta-<sha>-unnotarized.dmg and submits nothing
#   scripts/build-beta.sh --teardown      print the teardown steps; makes no changes
#   scripts/build-beta.sh -h | --help     this text
#
# THE SIGNING QUESTION (read this before using --sign)
#
#   Default is unsigned: CODE_SIGNING_ALLOWED=NO / CODE_SIGNING_REQUIRED=NO.
#   The embedded CLI and broker binaries still carry the ad-hoc arm64
#   signature `swift build` applies automatically (see the "Embed CLI" /
#   "Embed Broker" build phases in project.pbxproj) — the app bundle itself
#   is unsigned.
#
#   The project's Developer ID certificate was revoked once already by
#   repeated *signed* local builds against CODE_SIGN_STYLE = Automatic —
#   see issues/0265.md. This script defaults to NOT signing. --sign is the
#   one place besides scripts/release.sh that signs with the Developer ID
#   (#0503): Manual signing with the committed Beta profile, which never
#   contacts Apple, and the full entitlements including the iCloud key.
#   The unsigned build carries no signature and so no entitlements.

#   #0270 separately found that launchd refuses to start an improperly
#   signed LaunchAgent. Whether the ad-hoc signature this script's default
#   build leaves on the broker is enough for SMAppService registration and
#   launchd to start it is an OPEN QUESTION — answering it requires an
#   actual SMAppService registration, which this script never performs
#   itself (see issues/0279.md; #0270 documents that a bad registration can
#   wedge launchd, recovered only via `sfltool resetbtm` + reboot).
#   Coordinate that test with Brennan; never run it unattended, and never
#   while it would collide with the running Prod session.
#
#   Recommended cadence if the unsigned broker never registers: run
#   `--sign` ONCE, install that signed copy, then go back to unsigned
#   builds for every further code change. A signed build belongs to a Beta
#   *install*, not to routine iteration — that is what keeps signed builds
#   rare enough not to risk another revocation.
#
# --notarize (#0506)
#
#   Valid only together with --sign. It is the same sanctioned Developer ID
#   site as --sign, not a new one: Manual signing, the committed Beta
#   profile, no Automatic signing, no -allowProvisioningUpdates. The plain
#   --sign build (Debug, `xcodebuild build`) cannot be notarized -- it has
#   get-task-allow and no secure timestamp on Xcode's own signatures or on
#   Sparkle's nested code -- so --notarize archives the Release
#   configuration and runs -exportArchive (method developer-id), which
#   re-signs nested code with a timestamp, then re-signs the embedded
#   bin/BattyBroker and bin/batty and the app (#0273), exactly as
#   scripts/release.sh does. It checks every Mach-O for a secure timestamp,
#   hardened runtime and no get-task-allow, runs scripts/verify-profile.sh,
#   builds and signs the DMG, and only then submits to Apple.
#
#   Notarization uploads the binary to Apple: a shared-state action, run
#   only with the user's go-ahead each time. --no-submit stops right before
#   `notarytool submit` so everything up to it can be checked without
#   uploading anything to the notary service. codesign --timestamp still
#   contacts Apple's timestamp server. The mode installs nothing and never touches
#   /Applications.
#
# TEARDOWN (also see docs/beta-teardown.md)
#
#   Unregister before delete — #0270 documents that leftover SMAppService
#   state keyed to a bundle identifier is exactly what wedges launchd, and
#   two copies of Batty on disk (Prod + Beta) is that scenario. Run
#   `scripts/build-beta.sh --teardown` for the exact steps; this script
#   only prints them, it never performs the removal itself.
#
# Configuration/Active.xcconfig (review round 1, blocking finding 2)
#
#   Building the Beta scheme requires Active.xcconfig -> Beta.xcconfig
#   (scripts/set-environment.sh Beta), which is also what the "Batty
#   (Beta)" Xcode scheme's own pre-action writes. That pre-action runs
#   AFTER xcodebuild has already resolved build settings for the
#   invocation that triggers it -- so whatever Active.xcconfig says at the
#   START of a build is what that build actually uses, and any pre-action
#   write only takes effect for the NEXT invocation. Left pointed at Beta,
#   the very next `-scheme 'Batty (Prod)'` build (./build.sh, this
#   project's pre-commit gate, CI, or you) would silently build the BETA
#   product while claiming to be Prod -- confusing at best, and a direct
#   violation of "don't interfere with the Prod build" at worst. This
#   script snapshots whatever Active.xcconfig says on entry (including
#   "the file doesn't exist yet") and restores exactly that on exit,
#   success or failure, via `trap ... EXIT`.

set -euo pipefail

SCRIPT_PATH="${0:A}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="Batty (Beta)"
WORKSPACE="Batty.xcworkspace"
CONFIGURATION="Debug"
APP_NAME="Batty Beta.app"
BUILD_ROOT="$REPO/beta-build"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
OUT_DIR="$BUILD_ROOT/Products"

print_help() {
    sed -n '2,/^set -euo pipefail$/p' "$SCRIPT_PATH" | sed '$d' | sed 's/^# \{0,1\}//'
}

SIGN=0
NOTARIZE=0
NO_SUBMIT=0
TEARDOWN=0

for arg in "$@"; do
    case "$arg" in
        --sign) SIGN=1 ;;
        --notarize) NOTARIZE=1 ;;
        --no-submit) NO_SUBMIT=1 ;;
        --teardown) TEARDOWN=1 ;;
        -h|--help) print_help; exit 0 ;;
        *)
            print -u2 "build-beta.sh: unknown flag: $arg"
            print -u2 "usage: $0 [--sign [--notarize [--no-submit]]] [--teardown] [-h|--help]"
            exit 2
            ;;
    esac
done

if (( NOTARIZE && ! SIGN )); then
    print -u2 "build-beta.sh: --notarize requires --sign (only a Developer ID signed build can be notarized)"
    print -u2 "usage: $0 --sign --notarize [--no-submit]"
    exit 2
fi
if (( NO_SUBMIT && ! NOTARIZE )); then
    print -u2 "build-beta.sh: --no-submit is only meaningful with --sign --notarize"
    print -u2 "usage: $0 --sign --notarize [--no-submit]"
    exit 2
fi

if (( TEARDOWN )); then
    cat <<'EOF'
Beta teardown — do this in order. Unregistering before deleting matters:
#0270 records that leftover SMAppService state keyed to a bundle
identifier is exactly what wedges launchd, and this two-variant setup is
that scenario waiting to happen if the order is reversed.

  1. Quit "Batty Beta" if it's running.
  2. Unregister its LaunchAgent BEFORE deleting the app bundle:
     System Settings -> General -> Login Items & Extensions ->
     "Allow in the Background" -> find "Batty Beta" -> turn it off.
     (Batty's own Settings window also surfaces broker registration
     state, if you'd rather unregister from there.)
  3. Remove the app:
       rm -rf "/Applications/Batty Beta.app"
  4. Remove the CLI symlink:
       rm -f /usr/local/bin/batty-beta
  5. Remove Beta's Application Support directory (session-name cache, any
     future workspace state):
       rm -rf "$HOME/Library/Application Support/Batty Beta"
  6. Optional — clear Beta's UserDefaults:
       defaults delete co.sstools.Batty.beta
  7. Optional — remove Beta's saved window state and caches:
       rm -rf "$HOME/Library/Saved Application State/co.sstools.Batty.beta.savedState"
       rm -rf "$HOME/Library/Caches/co.sstools.Batty.beta"

Prod (/Applications/Batty.app, co.sstools.Batty, ~/Library/Application
Support/Batty) is untouched by any of the above — the two variants were
made to not share state for exactly this reason (#0279).
EOF
    exit 0
fi

cd "$REPO"

# Snapshot Active.xcconfig exactly as it is on entry -- including "absent"
# (a fresh clone has no Active.xcconfig; App.xcconfig's #include? tolerates
# that) -- and restore it on the way out, whatever the exit path. See the
# "Configuration/Active.xcconfig" note in the header comment above for why
# this matters: the scheme pre-action that normally does this lags one
# invocation behind, so this script must not be the thing that leaves the
# repo silently pointed at Beta for the next Prod build.
ACTIVE_XCCONFIG="$REPO/Configuration/Active.xcconfig"
ACTIVE_XCCONFIG_EXISTED=0
ACTIVE_XCCONFIG_BACKUP=""
if [[ -f "$ACTIVE_XCCONFIG" ]]; then
    ACTIVE_XCCONFIG_EXISTED=1
    ACTIVE_XCCONFIG_BACKUP="$(mktemp "${TMPDIR:-/tmp}/batty-active-xcconfig.XXXXXX")"
    cp "$ACTIVE_XCCONFIG" "$ACTIVE_XCCONFIG_BACKUP"
fi
restore_active_xcconfig() {
    # Capture the exit status that triggered this trap (e.g. 130 on
    # SIGINT) before running anything else, and re-exit with it explicitly
    # at the end -- otherwise the trap's own last command's status becomes
    # the script's reported exit code, silently turning a Ctrl-C or a
    # build failure into a reported success.
    local exit_status=$?
    if (( ACTIVE_XCCONFIG_EXISTED )); then
        cp "$ACTIVE_XCCONFIG_BACKUP" "$ACTIVE_XCCONFIG"
        rm -f "$ACTIVE_XCCONFIG_BACKUP"
    else
        rm -f "$ACTIVE_XCCONFIG"
    fi
    exit "$exit_status"
}
trap restore_active_xcconfig EXIT

"$REPO/scripts/set-environment.sh" Beta

# #0317: xcodebuild does not clean build products it no longer manages, so
# when a dependency relocates or renames an emitted header (as libghostty-spm
# did going 1.2.2 -> 1.3.2, #0286), a stale copy lingers in this script's
# long-lived $DERIVED_DATA tree and can shadow the current one, silently
# compiling against a previous revision. Guard against that by comparing the
# package-pin inputs against a stamp file in $BUILD_ROOT (gitignored) and
# wiping $DERIVED_DATA whenever they've changed (or there's no stamp yet --
# first run, or a hand-cleared stamp, must clean rather than silently skip
# the guard).
#
# RESOLVED_INPUTS is the union of every file that can move a pin, not just
# the resolved-pins file, because Batty.xcodeproj/.../Package.resolved is
# NOT build-maintained -- issues/0286.md's own Gotchas record that
# `xcodebuild -resolvePackageDependencies` resolves into DerivedData only and
# does not write back to it, so it changes only when someone remembers to
# hand-edit it. Git history has real bumps that touched BattyKit/Package.swift
# + BattyKit/Package.resolved (the `swift package resolve` shape) WITHOUT
# touching the xcodeproj file at all -- hashing only the xcodeproj file would
# have missed those permanently, since nothing ever re-touches it afterward.
# BattyKit/Package.swift is the leading indicator: it's human-authored and
# always changes first for the `revision:`-pinned dependencies (incl.
# libghostty-spm at BattyKit/Package.swift:31-33). Hashing all three catches
# every bump shape seen in history. Residual gap, accepted as out of scope:
# a range-pinned dependency (e.g. Sparkle) can re-resolve to a newer release
# with none of these three files changing -- nothing short of re-resolving on
# every build would close that, and that defeats the point of the guard.
RESOLVED_INPUTS=(
    "$REPO/BattyKit/Package.swift"
    "$REPO/BattyKit/Package.resolved"
    "$REPO/Batty.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)
STAMP_FILE="$BUILD_ROOT/.package-resolved-stamp"

mkdir -p "$BUILD_ROOT"

for f in "${RESOLVED_INPUTS[@]}"; do
    if [[ ! -f "$f" ]]; then
        print -u2 "build-beta.sh: missing package-pin input: $f"
        print -u2 "(the #0317 stale-products guard cannot be evaluated; refusing to build)"
        exit 1
    fi
done

CURRENT_RESOLVED_HASH="$(cat "${RESOLVED_INPUTS[@]}" | shasum -a 256 | awk '{print $1}')"

STORED_RESOLVED_HASH=""
if [[ -f "$STAMP_FILE" ]]; then
    STORED_RESOLVED_HASH="$(<"$STAMP_FILE")"
fi

if [[ "$CURRENT_RESOLVED_HASH" == "$STORED_RESOLVED_HASH" ]]; then
    print "==> Resolved package pins unchanged since last Beta build — keeping $DERIVED_DATA."
else
    if [[ -d "$DERIVED_DATA" ]]; then
        print "==> Resolved package pins changed (or no stamp found) — clearing $DERIVED_DATA"
        print "    to avoid stale build products shadowing a relocated/renamed header (#0317)."
        rm -rf "$DERIVED_DATA"
    else
        print "==> No stamp found and no existing $DERIVED_DATA — nothing to clean, recording stamp."
    fi
    print "$CURRENT_RESOLVED_HASH" > "$STAMP_FILE"
fi

notarize_flow() {
    local TEAM_ID="XV8BAAVZ6V"
    local SIGN_IDENTITY="Developer ID Application: Brennan Stehling ($TEAM_ID)"
    local NOTARY_PROFILE="Batty-notary"
    local BUNDLE_ID="co.sstools.Batty.beta"
    local PROFILE_NAME="Batty Beta Developer ID"
    local WORK_ROOT="$BUILD_ROOT/notarize"
    local ARCHIVE_PATH="$WORK_ROOT/Batty Beta.xcarchive"
    local EXPORT_DIR="$WORK_ROOT/Export"
    local EXPORT_PLIST="$WORK_ROOT/exportOptions.plist"
    local DIST_DIR="$REPO/dist"
    local VOLNAME="Batty Beta"
    local WORK_DMG="$DIST_DIR/$VOLNAME.dmg"
    local GIT_SHA
    GIT_SHA="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || print unknown)"
    local FINAL_DMG="$DIST_DIR/Batty-Beta-$GIT_SHA.dmg"
    (( NO_SUBMIT )) && FINAL_DMG="$DIST_DIR/Batty-Beta-$GIT_SHA-unnotarized.dmg"

    if ! command -v create-dmg >/dev/null 2>&1; then
        print -u2 "error: create-dmg not installed. Run: brew install create-dmg"
        return 1
    fi
    if ! security find-identity -p codesigning -v | grep -q "$SIGN_IDENTITY"; then
        print -u2 "error: signing identity not found in Keychain: $SIGN_IDENTITY"
        return 1
    fi
    if (( ! NO_SUBMIT )) && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        print -u2 "error: notarytool keychain profile '$NOTARY_PROFILE' missing or invalid."
        return 1
    fi

    rm -rf "$WORK_ROOT"
    mkdir -p "$WORK_ROOT" "$DIST_DIR"

    cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>$BUNDLE_ID</key>
        <string>$PROFILE_NAME</string>
    </dict>
</dict>
</plist>
PLIST

    print "==> xcodebuild archive ($SCHEME, Release)"
    xcodebuild archive \
        -workspace "$WORKSPACE" \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        -derivedDataPath "$DERIVED_DATA" \
        -destination 'generic/platform=macOS' \
        BATTY_SIGNING=developerid

    print "==> Exporting signed app (developer-id, manual)"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$EXPORT_PLIST"

    local APP_PATH="$EXPORT_DIR/$APP_NAME"
    if [[ ! -d "$APP_PATH" ]]; then
        print -u2 "error: exported app not found at $APP_PATH"
        return 1
    fi

    # Same reason as release.sh (#0273): bin/* are sealed as resources, so
    # -exportArchive does not necessarily re-sign them.
    print "==> Re-signing embedded agent + CLI with the Developer ID identity (#0273)"
    local ENTITLEMENTS_PLIST="$WORK_ROOT/app-entitlements.plist"
    codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null > "$ENTITLEMENTS_PLIST" || true
    local rel_path bin_path
    for rel_path in "Contents/Resources/bin/BattyBroker" "Contents/Resources/bin/batty"; do
        bin_path="$APP_PATH/$rel_path"
        if [[ ! -f "$bin_path" ]]; then
            print -u2 "error: $rel_path missing from exported app"
            return 1
        fi
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$bin_path"
        print "    re-signed: $rel_path"
    done
    if [[ -s "$ENTITLEMENTS_PLIST" ]]; then
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS_PLIST" "$APP_PATH"
    else
        print -u2 "error: could not extract the exported app's entitlements"
        return 1
    fi
    print "    re-signed: $APP_NAME (resource seal updated)"

    print "==> Verifying app signature"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"

    print "==> Verifying the embedded provisioning profile and iCloud entitlement (#0503)"
    if ! "$REPO/scripts/verify-profile.sh" "$APP_PATH"; then
        print -u2 "error: the exported app's provisioning profile or iCloud entitlement is wrong (see FAIL lines above)."
        return 1
    fi

    # The notary service inspects every Mach-O, including those nested in
    # Sparkle.framework, which --deep --strict does not report on.
    print "==> Verifying every Mach-O: Developer ID Authority, hardened runtime, secure timestamp, no get-task-allow"
    local app_authority
    app_authority=$(codesign -dvvv "$APP_PATH" 2>&1 | awk -F= '/^Authority=/ && !seen { print $2; seen = 1 }')
    if [[ "$app_authority" != "$SIGN_IDENTITY" ]]; then
        print -u2 "error: exported app's Authority is '$app_authority', expected '$SIGN_IDENTITY'"
        return 1
    fi
    local app_team
    app_team=$(codesign -dv "$APP_PATH" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')
    local f cs authority team ts ftype ents count=0 bad=0
    while IFS= read -r -d '' f; do
        ftype=$(file -b "$f")
        if [[ "$ftype" != *Mach-O* ]]; then
            continue
        fi
        count=$((count + 1))
        cs=$(codesign -dvv "$f" 2>&1) || { print -u2 "error: cannot read signature of ${f#$APP_PATH/}"; bad=$((bad + 1)); continue; }
        authority=$(print -r -- "$cs" | awk -F= '/^Authority=/ && !seen { print $2; seen = 1 }')
        team=$(print -r -- "$cs" | awk -F= '/^TeamIdentifier=/ { print $2 }')
        ts=$(print -r -- "$cs" | awk -F= '/^Timestamp=/ { print $2 }')
        if [[ "$authority" != "$app_authority" || "$team" != "$app_team" ]]; then
            print -u2 "error: ${f#$APP_PATH/}: Authority '$authority' / team '$team' differ from the app's"
            bad=$((bad + 1)); continue
        fi
        if ! print -r -- "$cs" | grep -q "flags=.*runtime"; then
            print -u2 "error: ${f#$APP_PATH/}: hardened runtime is off"
            bad=$((bad + 1)); continue
        fi
        if [[ -z "$ts" ]]; then
            print -u2 "error: ${f#$APP_PATH/}: no secure timestamp -- the notary service will reject it"
            bad=$((bad + 1)); continue
        fi
        ents=$(codesign -d --entitlements - "$f" 2>/dev/null || true)
        if [[ "$ents" == *get-task-allow* ]]; then
            print -u2 "error: ${f#$APP_PATH/}: carries com.apple.security.get-task-allow"
            bad=$((bad + 1)); continue
        fi
        print "    OK: ${f#$APP_PATH/}  [Timestamp=$ts]"
    done < <(find "$APP_PATH" -type f -print0)
    if (( count == 0 || bad > 0 )); then
        print -u2 "error: $bad of $count Mach-O files failed the notarization pre-check"
        return 1
    fi
    print "    $count Mach-O files checked"

    local APP_ICON="$APP_PATH/Contents/Resources/AppIcon.icns"
    if [[ ! -f "$APP_ICON" ]]; then
        print -u2 "error: AppIcon.icns not found at $APP_ICON"
        return 1
    fi

    # Keeping the work file's name equal to the volume name avoids the
    # Gatekeeper-triggered rename release.sh documents.
    print "==> Creating DMG: $WORK_DMG"
    rm -f "$WORK_DMG" "$FINAL_DMG" "$DIST_DIR"/rw.*.dmg(N)
    # --skip-jenkins omits the Finder AppleScript layout, which fails with
    # "Can't get disk (-1728)" when Finder is slow to see the new volume.
    # The Applications link and volume icon are kept.
    if ! create-dmg \
        --skip-jenkins \
        --volname "$VOLNAME" \
        --volicon "$APP_ICON" \
        --icon-size 100 \
        --app-drop-link 425 190 \
        --no-internet-enable \
        "$WORK_DMG" \
        "$APP_PATH"; then
        rm -f "$DIST_DIR"/rw.*.dmg(N)
        print -u2 "error: create-dmg failed"
        return 1
    fi
    rm -f "$DIST_DIR"/rw.*.dmg(N)

    print "==> Signing DMG"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$WORK_DMG"
    codesign --verify --verbose=2 "$WORK_DMG"

    if (( NO_SUBMIT )); then
        mv "$WORK_DMG" "$FINAL_DMG"
        print ""
        print "==> --no-submit: stopping before notarytool submit. Nothing was uploaded to the notary service (codesign still contacts the timestamp server)."
        print "    Signed, NOT notarized DMG: $FINAL_DMG"
        print "    Would run next:"
        print "      xcrun notarytool submit \"$WORK_DMG\" --keychain-profile $NOTARY_PROFILE --wait"
        print "      xcrun stapler staple / validate, scripts/verify-dmg.sh"
        rm -rf "$WORK_ROOT"
        return 0
    fi

    print "==> Submitting for notarization (this can take several minutes)"
    xcrun notarytool submit "$WORK_DMG" --keychain-profile "$NOTARY_PROFILE" --wait

    print "==> Stapling notarization ticket"
    xcrun stapler staple "$WORK_DMG"
    xcrun stapler validate "$WORK_DMG"

    print "==> Verifying the stapled DMG (scripts/verify-dmg.sh)"
    if ! "$REPO/scripts/verify-dmg.sh" "$WORK_DMG"; then
        print -u2 "error: verify-dmg.sh failed (see FAIL lines above)."
        return 1
    fi

    mv "$WORK_DMG" "$FINAL_DMG"
    fileicon set "$FINAL_DMG" "$APP_ICON" 2>/dev/null || true
    rm -rf "$WORK_ROOT"

    print ""
    print "==> Notarized Beta DMG: $FINAL_DMG"
    print ""
    print "Installing stays manual: mount the DMG and drag \"$APP_NAME\" to Applications."
    print "Teardown steps: scripts/build-beta.sh --teardown  (also docs/beta-teardown.md)"
}

SIGN_FLAGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
if (( SIGN )); then
    print "==> --sign: building with manual Developer ID signing and the Beta provisioning profile."
    "$REPO/scripts/install-profiles.sh" --quiet
    print "    This should be rare — once per Beta install, not per code change."
    print "    Repeated signed local builds are what revoked the cert before (see issues/0265.md)."
    SIGN_FLAGS=(BATTY_SIGNING=developerid)
else
    print "==> Building unsigned (default). Pass --sign only if launchd refuses the broker."
fi

if (( NOTARIZE )); then
    notarize_flow
    exit $?
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

print "==> xcodebuild build ($SCHEME, $CONFIGURATION)"
xcodebuild build \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'platform=macOS' \
    "${SIGN_FLAGS[@]}"

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
if [[ ! -d "$BUILT_APP" ]]; then
    print -u2 "build-beta.sh: expected build product not found at $BUILT_APP"
    print -u2 "(PRODUCT_NAME must resolve to \"Batty Beta\" — check Configuration/Beta.xcconfig)"
    exit 1
fi

# Leave exactly one copy behind, in a location this script owns —
# release.sh's #0026 comment documents that a stray leftover .app confuses
# LaunchServices routing, and this is doubly relevant with two variants
# both registering the batty:// scheme (#0279 leak 3).
ditto "$BUILT_APP" "$OUT_DIR/$APP_NAME"

print ""
print "==> Built: $OUT_DIR/$APP_NAME"
print ""
if (( SIGN )); then
    print "Signed with Developer ID (manual signing, Beta provisioning profile)."
else
    print "Unsigned — ad-hoc arm64 signature on the embedded CLI/broker only, no"
    print "signature on the app bundle itself. Whether that's enough for launchd to"
    print "start the bundled LaunchAgent is not yet known — see the signing notes in"
    print "this script's --help. Try this build first; only re-run with --sign if the"
    print "broker never registers."
fi
print ""
print "Next step — this script does not copy into /Applications itself:"
print "  cp -R \"$OUT_DIR/$APP_NAME\" \"/Applications/$APP_NAME\""
print ""
print "Teardown steps: scripts/build-beta.sh --teardown  (also docs/beta-teardown.md)"
