#!/usr/bin/env zsh
# Copies vendored Ghostty terminfo + shell-integration resources into the
# built Batty.app bundle so libghostty can find them at runtime.
#
# Intended to run as a Run Script build phase in Xcode (Batty target →
# Build Phases → New Run Script Phase). Idempotent; safe to re-run.
#
# Inputs (from Xcode env):
#   SRCROOT             — repo root.
#   TARGET_BUILD_DIR    — build dir for the current configuration.
#   UNLOCALIZED_RESOURCES_FOLDER_PATH — typically Batty.app/Contents/Resources.

set -euo pipefail

SRC="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}/Resources/ghostty-runtime"
DEST="${TARGET_BUILD_DIR:-${PWD}/build}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-Batty.app/Contents/Resources}"

if [[ ! -d "$SRC" ]]; then
    print -u2 "error: missing $SRC — terminfo / shell-integration resources not vendored"
    exit 1
fi

mkdir -p "$DEST/terminfo/78"
mkdir -p "$DEST/ghostty/shell-integration"

cp -f "$SRC/terminfo/78/xterm-ghostty" "$DEST/terminfo/78/xterm-ghostty"
rsync -a --delete "$SRC/ghostty/shell-integration/" "$DEST/ghostty/shell-integration/"

# Sentinel check — bail loud if the canonical file is missing post-copy.
if [[ ! -f "$DEST/terminfo/78/xterm-ghostty" ]]; then
    print -u2 "error: $DEST/terminfo/78/xterm-ghostty missing after copy"
    exit 1
fi

print "Bundled Ghostty runtime resources into $DEST"
