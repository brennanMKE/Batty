#!/usr/bin/env zsh
# scripts/build.sh — thin xcodebuild wrapper.
#
# Usage:
#   scripts/build.sh                   # defaults to: build (Prod scheme)
#   scripts/build.sh unit              # run BattyKitTests only (fast, no UI)
#   scripts/build.sh ui [target ...]   # run UI tests via run-ui-tests.sh (Beta scheme)
#   scripts/build.sh test              # alias for "ui" -- UI tests never run under Prod
#   scripts/build.sh archive ...       # any xcodebuild action + args
#
# Honors SCHEME env var (default: "Batty (Prod)").
# Uses the Batty.xcworkspace so cross-container package test targets
# (BattyKitTests) are visible alongside the project's own test targets.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${SCHEME:-Batty (Prod)}"
WORKSPACE="Batty.xcworkspace"

cd "$REPO"

# "unit" is a special action: run BattyKitTests only via the workspace
# (skips the BattyTests placeholder and the slow BattyUITests bundle).
if [[ "${1:-}" == "unit" ]]; then
    print "==> xcodebuild test (BattyKitTests)"
    exec xcodebuild test \
        -workspace "$WORKSPACE" \
        -scheme "$SCHEME" \
        -destination 'platform=macOS' \
        -only-testing:BattyKitTests
fi

# UI tests must run against the Beta product, never Prod: the host app's
# bundle id under Prod is co.sstools.Batty, the same id as an installed
# Batty the developer may already be running, and the suite's own scheme
# is "Batty (Beta)". Delegating to run-ui-tests.sh also picks up its
# Gatekeeper re-signing step and its Active.xcconfig handling (#0280) --
# both of which a bare `xcodebuild test` here would skip.
if [[ "${1:-}" == "ui" || "${1:-}" == "test" ]]; then
    shift
    print "==> delegating to scripts/run-ui-tests.sh (Beta scheme)"
    exec "$REPO/scripts/run-ui-tests.sh" "$@"
fi

ACTION_ARGS=("$@")
if [[ ${#ACTION_ARGS[@]} -eq 0 ]]; then
    ACTION_ARGS=(build)
fi

print "==> xcodebuild ${ACTION_ARGS[*]}"
exec xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    "${ACTION_ARGS[@]}"
