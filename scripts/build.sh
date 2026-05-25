#!/usr/bin/env zsh
# scripts/build.sh — run xcodebuild with the libghostty.framework macOS-slice
# workaround applied between SPM resolution and the xcodebuild action.
#
# Why this exists: upstream Lakr233/libghostty-spm ships the macOS slice of
# GhosttyKit.xcframework as a shallow bundle, which macOS embed-frameworks
# validation rejects. fix-libghostty-framework.sh reshapes it to the
# versioned layout. The fixup has to run before ProcessXCFramework, which
# rules out doing it as an Xcode build phase. See issues/0212.md.
#
# Usage:
#   scripts/build.sh                   # defaults to: build
#   scripts/build.sh test              # run tests
#   scripts/build.sh test -only-testing:BattyKitTests/...
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

print "==> Resolving SPM packages"
xcodebuild -scheme "$SCHEME" -destination 'platform=macOS' -resolvePackageDependencies

print "==> Patching libghostty.framework macOS slice"
"$REPO/scripts/fix-libghostty-framework.sh"

print "==> xcodebuild ${ACTION_ARGS[*]}"
exec xcodebuild -scheme "$SCHEME" -destination 'platform=macOS' "${ACTION_ARGS[@]}"
