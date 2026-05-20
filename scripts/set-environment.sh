#!/bin/sh
#
# set-environment.sh <Beta|Prod>
#
# Writes Configuration/Active.xcconfig to include the named variant's
# xcconfig file. Called as a pre-action by the "Batty (Beta)" and
# "Batty (Prod)" Xcode schemes before each build.
#
# Can also be run directly from the repo root:
#   ./scripts/set-environment.sh Beta
#   ./scripts/set-environment.sh Prod

set -e

VARIANT="${1}"
if [ -z "$VARIANT" ]; then
    echo "error: Usage: $0 <Beta|Prod>" >&2
    exit 1
fi

# Resolve the Configuration directory.
# When invoked from an Xcode scheme pre-action, PROJECT_DIR is set.
# When invoked from the terminal, derive it from the script's location.
if [ -n "${PROJECT_DIR}" ]; then
    CONFIG_DIR="${PROJECT_DIR}/Configuration"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    CONFIG_DIR="${SCRIPT_DIR}/../Configuration"
fi

TARGET="${CONFIG_DIR}/${VARIANT}.xcconfig"
ACTIVE="${CONFIG_DIR}/Active.xcconfig"

if [ ! -f "$TARGET" ]; then
    echo "error: No xcconfig found for variant '${VARIANT}' at ${TARGET}" >&2
    exit 1
fi

printf '#include "%s.xcconfig"\n' "$VARIANT" > "$ACTIVE"
echo "set-environment.sh: Active.xcconfig → ${VARIANT}.xcconfig"
