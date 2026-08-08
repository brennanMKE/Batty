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
#   scripts/build-beta.sh --sign          build with Automatic (Developer ID) signing
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
#   repeated *signed* local builds against CODE_SIGN_STYLE = Automatic
#   (Configuration/Build.xcconfig) — see issues/0265.md. This script
#   defaults to NOT signing so iterating on Beta builds can never repeat
#   that.
#
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
#   the very next `-scheme 'Batty (Prod)'` build (scripts/build.sh, this
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
TEARDOWN=0

for arg in "$@"; do
    case "$arg" in
        --sign) SIGN=1 ;;
        --teardown) TEARDOWN=1 ;;
        -h|--help) print_help; exit 0 ;;
        *)
            print -u2 "build-beta.sh: unknown flag: $arg"
            print -u2 "usage: $0 [--sign] [--teardown] [-h|--help]"
            exit 2
            ;;
    esac
done

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

SIGN_FLAGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
if (( SIGN )); then
    print "==> --sign: building with Automatic (Developer ID) signing."
    print "    This should be rare — once per Beta install, not per code change."
    print "    Repeated signed local builds are what revoked the cert before (see issues/0265.md)."
    SIGN_FLAGS=()
else
    print "==> Building unsigned (default). Pass --sign only if launchd refuses the broker."
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
    print "Signed with Developer ID (Automatic signing)."
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
