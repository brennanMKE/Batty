#!/usr/bin/env zsh
# scripts/build.sh — thin xcodebuild wrapper.
#
# Usage:
#   scripts/build.sh                   # defaults to: build (Prod scheme)
#   scripts/build.sh unit              # run BattyKitTests only (fast, no UI)
#   scripts/build.sh test              # run UI tests (slow; use scripts/run-ui-tests.sh for one class)
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
