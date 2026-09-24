#!/usr/bin/env zsh
# build.sh — the single entry point for building and testing Batty.
#
# Everything defaults to the "Batty (Beta)" scheme. Beta is the variant you
# develop and test against: it builds "Batty Beta.app" under the bundle id
# co.sstools.Batty.beta, so it never collides with the Prod app the user
# keeps running from /Applications. Prod is only for release builds, and
# only via the `release` action below.
#
# Usage:
#   ./build.sh                     build (Beta)
#   ./build.sh clean               clean (Beta)
#   ./build.sh unit                BattyKitTests only — fast, no UI, no machine lock
#   ./build.sh ui [target ...]     UI tests — ONLY inside a disposable Tart VM
#                                  (delegates to tools/run-ui-tests-vm.sh, #0412)
#   ./build.sh run                 build, then launch the built Batty Beta.app
#   ./build.sh terminate           quit a running Batty Beta (never touches Prod)
#   ./build.sh release [args]      build with the Prod scheme, for release only
#   ./build.sh package [--sign]    package a Batty Beta.app to install alongside Prod
#                                  (delegates to scripts/build-beta.sh)
#
# Any other action is passed through to xcodebuild under the Beta scheme,
# so `./build.sh archive`, `./build.sh analyze`, etc. still work.
#
# Configuration/Active.xcconfig
#
#   Prod vs Beta is selected by Configuration/Active.xcconfig, a gitignored
#   file that #includes one of Prod.xcconfig / Beta.xcconfig. The scheme
#   pre-action that normally sets it runs *after* xcodebuild has already
#   resolved build settings, so it lags one invocation behind (#0280). This
#   script therefore selects the variant itself before invoking xcodebuild,
#   and restores whatever was there on every exit path -- so no build ever
#   silently produces the other variant, and no run leaves the repo pointed
#   somewhere the next one will trip over.

set -euo pipefail

REPO="${0:A:h}"
cd "$REPO"

WORKSPACE="Batty.xcworkspace"
DESTINATION="platform=macOS"
BETA_SCHEME="Batty (Beta)"
PROD_SCHEME="Batty (Prod)"
BETA_APP_NAME="Batty Beta"

ACTION="${1:-build}"

# Snapshot Active.xcconfig exactly as found (including "absent" -- a fresh
# clone has none, and App.xcconfig's #include? tolerates that) and restore
# it on every exit path, whatever happens. Same pattern and reasoning as
# scripts/build-beta.sh.
ACTIVE_XCCONFIG="$REPO/Configuration/Active.xcconfig"
ACTIVE_XCCONFIG_EXISTED=0
ACTIVE_XCCONFIG_BACKUP=""
if [[ -f "$ACTIVE_XCCONFIG" ]]; then
    ACTIVE_XCCONFIG_EXISTED=1
    ACTIVE_XCCONFIG_BACKUP="$(mktemp "${TMPDIR:-/tmp}/batty-active-xcconfig.XXXXXX")"
    cp "$ACTIVE_XCCONFIG" "$ACTIVE_XCCONFIG_BACKUP"
fi
restore_active_xcconfig() {
    # Capture the triggering status first and re-exit with it, so a Ctrl-C
    # or a build failure is not masked by the trap's own last command.
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

select_variant() {
    "$REPO/scripts/set-environment.sh" "$1" >/dev/null
}

case "$ACTION" in
    ui|test)
        # #0412: UI tests never run on this host -- XCTAutomationSupport
        # loads into every running GUI app testmanagerd can see, not just
        # the app under test, and that crashed the user's running Prod
        # Batty on 2026-09-12 (#0409). tools/run-ui-tests-vm.sh runs the
        # suite inside a disposable Tart VM instead; it owns Beta selection
        # and ad hoc signing for the guest build.
        shift
        print "==> UI tests (Beta, in a Tart VM) via tools/run-ui-tests-vm.sh"
        exec "$REPO/tools/run-ui-tests-vm.sh" "$@"
        ;;

    package)
        shift
        print "==> packaging Batty Beta via scripts/build-beta.sh"
        exec "$REPO/scripts/build-beta.sh" "$@"
        ;;

    unit)
        select_variant Beta
        print "==> xcodebuild test (BattyKitTests, Beta)"
        xcodebuild test \
            -workspace "$WORKSPACE" \
            -scheme "$BETA_SCHEME" \
            -destination "$DESTINATION" \
            -only-testing:BattyKitTests
        ;;

    release)
        shift
        select_variant Prod
        print "==> xcodebuild ${@:-build} (Prod — release only)"
        xcodebuild \
            -workspace "$WORKSPACE" \
            -scheme "$PROD_SCHEME" \
            -destination "$DESTINATION" \
            "${@:-build}"
        ;;

    run)
        select_variant Beta
        print "==> xcodebuild build (Beta), then launch"
        xcodebuild \
            -workspace "$WORKSPACE" \
            -scheme "$BETA_SCHEME" \
            -destination "$DESTINATION" \
            build
        APP_PATH=$(xcodebuild -workspace "$WORKSPACE" -scheme "$BETA_SCHEME" \
            -destination "$DESTINATION" -showBuildSettings build 2>/dev/null \
            | awk -F= '/[[:space:]]BUILT_PRODUCTS_DIR =/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}')
        if [[ -z "$APP_PATH" || ! -d "$APP_PATH/$BETA_APP_NAME.app" ]]; then
            print -u2 "build.sh: $BETA_APP_NAME.app not found under '$APP_PATH'"
            exit 1
        fi
        open "$APP_PATH/$BETA_APP_NAME.app"
        ;;

    terminate)
        # Only ever the Beta app: the Prod app is the user's live session
        # and this script must never signal it.
        if pkill -x "$BETA_APP_NAME"; then
            print "$BETA_APP_NAME terminated."
        else
            print -u2 "$BETA_APP_NAME is not running."
        fi
        ;;

    *)
        select_variant Beta
        print "==> xcodebuild $* (Beta)"
        xcodebuild \
            -workspace "$WORKSPACE" \
            -scheme "$BETA_SCHEME" \
            -destination "$DESTINATION" \
            "$@"
        ;;
esac
