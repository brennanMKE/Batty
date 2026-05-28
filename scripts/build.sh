#!/usr/bin/env zsh
# scripts/build.sh — thin xcodebuild wrapper.
#
# Usage:
#   scripts/build.sh                   # defaults to: build (Prod scheme)
#   scripts/build.sh unit              # run BattyKit unit tests only (fast, no UI)
#   scripts/build.sh test              # run UI tests (slow; use scripts/run-ui-tests.sh for one class)
#   scripts/build.sh archive ...       # any xcodebuild action + args
#
# Honors SCHEME env var (default: "Batty (Prod)").

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${SCHEME:-Batty (Prod)}"

cd "$REPO"

# "unit" is a special action: run BattyTests only (no UI tests).
if [[ "${1:-}" == "unit" ]]; then
    print "==> xcodebuild test (unit tests only)"
    exec xcodebuild test -scheme "$SCHEME" -destination 'platform=macOS' -only-testing:BattyTests
fi

ACTION_ARGS=("$@")
if [[ ${#ACTION_ARGS[@]} -eq 0 ]]; then
    ACTION_ARGS=(build)
fi

print "==> xcodebuild ${ACTION_ARGS[*]}"
exec xcodebuild -scheme "$SCHEME" -destination 'platform=macOS' "${ACTION_ARGS[@]}"
