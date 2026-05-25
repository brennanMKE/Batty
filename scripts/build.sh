#!/usr/bin/env zsh
# scripts/build.sh — build Batty with the libghostty.framework macOS-slice
# workaround applied between SPM resolution and the build proper.
#
# Why this exists: upstream Lakr233/libghostty-spm ships the macOS slice of
# GhosttyKit.xcframework as a shallow bundle, which macOS embed-frameworks
# validation rejects. fix-libghostty-framework.sh reshapes it to the
# versioned layout. The fixup has to run before ProcessXCFramework, which
# rules out doing it as an Xcode build phase. See issues/0212.md.
#
# Usage: scripts/build.sh [extra xcodebuild args]
# Honors SCHEME env var (default: "Batty (Prod)").

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="${SCHEME:-Batty (Prod)}"

cd "$REPO"

print "==> Resolving SPM packages"
xcodebuild -scheme "$SCHEME" -destination 'platform=macOS' -resolvePackageDependencies

print "==> Patching libghostty.framework macOS slice"
"$REPO/scripts/fix-libghostty-framework.sh"

print "==> Building"
exec xcodebuild -scheme "$SCHEME" -destination 'platform=macOS' build "$@"
