#!/usr/bin/env zsh
# scripts/build.sh — thin xcodebuild wrapper.
#
# Usage:
#   scripts/build.sh                   # defaults to: build
#   scripts/build.sh test              # run tests
#   scripts/build.sh archive ...       # any xcodebuild action + args
#
# Honors SCHEME env var (default: "Batty (Prod)").

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${SCHEME:-Batty (Prod)}"

cd "$REPO"

ACTION_ARGS=("$@")
if [[ ${#ACTION_ARGS[@]} -eq 0 ]]; then
    ACTION_ARGS=(build)
fi

print "==> xcodebuild ${ACTION_ARGS[*]}"
exec xcodebuild -scheme "$SCHEME" -destination 'platform=macOS' "${ACTION_ARGS[@]}"
