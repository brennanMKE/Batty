#!/usr/bin/env zsh
# Run the UI test suite (or a subset) without macOS Gatekeeper trashing the
# test runner mid-bootstrap.
#
# The problem: Xcode builds `BattyUITests-Runner.app` by copying Apple's
# stock `XCTRunner.app` template (Apple-signed) and then dropping our
# `BattyUITests.xctest` bundle inside its `PlugIns/` without re-signing the
# outer runner. The runner's own code signature now references resources
# (the xctest bundle) that weren't part of what Apple signed, so
# `spctl --assess` reports:
#
#     code has no resources but signature indicates they must be present
#
# AppleSystemPolicy (ASP) treats this as a tampered Apple binary, refuses
# to launch it, and macOS Gatekeeper translocates the bundle to ~/.Trash
# before killing it. From the user's point of view: every UI test run
# prompts them to move the runner to the trash. From xcodebuild's point
# of view: "Early unexpected exit, operation never finished bootstrapping
# — Test crashed with signal kill before establishing connection."
#
# The fix: re-sign the runner ad-hoc after `build-for-testing` so the
# signature matches the actual on-disk contents, then run the tests via
# `test-without-building`. Ad-hoc signing is what the project already
# does for local non-release builds (`CODE_SIGN_IDENTITY=-`), so this
# stays consistent with the existing signing posture and does not
# require a Developer ID cert.
#
# Usage:
#   scripts/run-ui-tests.sh                              # all UI tests
#   scripts/run-ui-tests.sh BattyUITests/TabRenameTests  # one class
#   scripts/run-ui-tests.sh BattyUITests/TabRenameTests/testResetActiveTabTitleClearsOverride  # one test
#
# Multiple test targets can be passed; each becomes a -only-testing arg.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
SCHEME="Batty (Beta)"
DESTINATION="platform=macOS"

cd "$REPO_ROOT"

# The upstream libghostty.framework macOS slice is packaged as a shallow
# bundle and Xcode's embed-frameworks validation rejects it. Resolve SPM
# first, then reshape the slice in-place, then build the test bundle.
# See issues/0212.md.
print "==> Resolving SPM packages..."
xcodebuild -scheme "$SCHEME" -destination "$DESTINATION" -resolvePackageDependencies 2>&1 | tail -3

print "==> Patching libghostty.framework macOS slice..."
"$REPO_ROOT/scripts/fix-libghostty-framework.sh"

print "==> Building test bundle..."
xcodebuild \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build-for-testing 2>&1 | tail -3

# Locate the freshly built products. Both apps live next to each other
# under the active DerivedData/Build/Products/<Configuration>/ folder.
PRODUCTS_DIR=$(xcodebuild -scheme "$SCHEME" -destination "$DESTINATION" \
    -showBuildSettings build-for-testing 2>/dev/null \
    | awk -F= '/[[:space:]]BUILT_PRODUCTS_DIR =/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}')

if [[ -z "$PRODUCTS_DIR" || ! -d "$PRODUCTS_DIR" ]]; then
    print -u2 "==> Could not locate BUILT_PRODUCTS_DIR (got: '$PRODUCTS_DIR')"
    exit 1
fi

RUNNER="$PRODUCTS_DIR/BattyUITests-Runner.app"
HOST_APP="$PRODUCTS_DIR/Batty Beta.app"

if [[ ! -d "$RUNNER" ]]; then
    print -u2 "==> Runner not found at: $RUNNER"
    exit 1
fi

print "==> Re-signing runner and host app ad-hoc..."
# --deep walks frameworks too. Apple deprecated --deep on signing but
# kept it working; for ad-hoc local UI test builds it's the simplest
# way to repair the whole bundle's signature in one shot.
codesign --force --deep --sign - "$RUNNER" 2>&1 | sed 's/^/  /'
if [[ -d "$HOST_APP" ]]; then
    codesign --force --deep --sign - "$HOST_APP" 2>&1 | sed 's/^/  /'
fi

# Build the -only-testing args from any positional arguments.
TEST_FILTER_ARGS=()
for spec in "$@"; do
    TEST_FILTER_ARGS+=("-only-testing:$spec")
done

print "==> Running tests (test-without-building)..."
xcodebuild \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    "${TEST_FILTER_ARGS[@]}" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    test-without-building
