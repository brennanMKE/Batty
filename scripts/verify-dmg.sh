#!/usr/bin/env zsh
# Verify a .dmg is ready for distribution: signed, notarized, stapled, and
# accepted by Gatekeeper — including a simulation of the "downloaded from
# Safari" quarantine scenario the recipient will actually hit.
#
# Usage: scripts/verify-dmg.sh <path/to/file.dmg>
#
# Exit code is 0 only if every check passes.

set -uo pipefail

if [[ $# -ne 1 ]]; then
    print -u2 "usage: $0 <path/to/file.dmg>"
    exit 2
fi

DMG="$1"
if [[ ! -f "$DMG" ]]; then
    print -u2 "error: not a file: $DMG"
    exit 2
fi

# Track failures so we can run every check before exiting.
FAILS=0
MOUNT_POINT=""
TEST_COPY=""

cleanup() {
    if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    fi
    if [[ -n "$TEST_COPY" && -f "$TEST_COPY" ]]; then
        rm -f "$TEST_COPY"
    fi
}
trap cleanup EXIT INT TERM

step() { print "\n==> $*"; }
pass() { print "    PASS: $*"; }
fail() { print "    FAIL: $*"; FAILS=$((FAILS + 1)); }

# 1. Stapler ticket --------------------------------------------------------
step "Stapler ticket attached"
if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    pass "ticket present and valid"
else
    fail "no stapled ticket — recipients without internet will see Gatekeeper warnings"
fi

# 2. Gatekeeper assessment of the DMG --------------------------------------
step "Gatekeeper assessment (DMG)"
SPCTL_OUT=$(spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 || true)
print "$SPCTL_OUT" | sed 's/^/    /'
if print -r -- "$SPCTL_OUT" | grep -q "source=Notarized Developer ID"; then
    pass "notarized + signed"
elif print -r -- "$SPCTL_OUT" | grep -q "source=Developer ID"; then
    fail "signed but NOT notarized — Gatekeeper will warn recipients"
else
    fail "not accepted by Gatekeeper"
fi

# 3. Codesign verification of the DMG --------------------------------------
step "Codesign verification (DMG)"
if codesign --verify --verbose=2 "$DMG" >/dev/null 2>&1; then
    pass "DMG signature valid"
else
    fail "DMG signature invalid or missing"
fi

# 4. Quarantine simulation -------------------------------------------------
step "Quarantine simulation (recipient downloads from Safari)"
TEST_COPY="$(mktemp -d)/$(basename "$DMG")"
cp "$DMG" "$TEST_COPY"
xattr -w com.apple.quarantine \
    "0083;$(printf '%x' $(date +%s));Safari;|com.apple.Safari" \
    "$TEST_COPY"
QSPCTL_OUT=$(spctl --assess --type open --context context:primary-signature -vv "$TEST_COPY" 2>&1 || true)
if print -r -- "$QSPCTL_OUT" | grep -q "source=Notarized Developer ID"; then
    pass "quarantined copy still accepted (recipient will see no warning)"
else
    print -r -- "$QSPCTL_OUT" | sed 's/^/    /'
    fail "quarantined copy rejected — recipients WILL see Gatekeeper warnings"
fi

# 5-8. Mount and inspect the inner app -------------------------------------
step "Mounting DMG to inspect inner app"
ATTACH_OUT=$(hdiutil attach -nobrowse -noautoopen -noverify "$DMG" 2>&1)
MOUNT_POINT=$(print -r -- "$ATTACH_OUT" | awk -F'\t' '/Apple_HFS|Apple_APFS/ { print $NF }' | tail -1)
if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
    fail "could not mount DMG"
    print "$ATTACH_OUT" | sed 's/^/    /'
else
    pass "mounted at $MOUNT_POINT"

    APP=$(/bin/ls -d "$MOUNT_POINT"/*.app 2>/dev/null | head -1)
    if [[ -z "$APP" ]]; then
        fail "no .app bundle found in DMG"
    else
        step "Codesign verification (inner app: $(basename "$APP"))"
        if codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null 2>&1; then
            pass "app signature deep-valid"
        else
            fail "app signature invalid"
        fi

        step "Hardened runtime + entitlements (inner app)"
        CS_OUT=$(codesign -dvv --entitlements - "$APP" 2>&1)
        if print -r -- "$CS_OUT" | grep -q "flags=.*runtime"; then
            pass "hardened runtime enabled"
        else
            fail "hardened runtime NOT enabled — notarization should have caught this"
        fi
        if print -r -- "$CS_OUT" | grep -q "Authority=Apple Root CA"; then
            pass "trust chain reaches Apple Root CA"
        else
            fail "incomplete trust chain"
        fi
        TEAM=$(print -r -- "$CS_OUT" | awk -F= '/^TeamIdentifier=/ { print $2 }')
        IDENT=$(print -r -- "$CS_OUT" | awk -F= '/^Identifier=/ { print $2 }')
        print "    TeamIdentifier: $TEAM"
        print "    Bundle identifier: $IDENT"

        step "Gatekeeper assessment (inner app)"
        if spctl --assess --type execute --verbose=4 "$APP" 2>&1 | grep -q "source=Notarized Developer ID"; then
            pass "app accepted by Gatekeeper"
        else
            fail "app not accepted by Gatekeeper"
        fi
    fi
fi

# 9. Notarization history --------------------------------------------------
step "Recent notarization submissions (informational)"
xcrun notarytool history --keychain-profile Issues-notary 2>/dev/null \
    | awk '/^    --|createdDate|name|status/' | sed 's/^/    /' | head -20 || \
    print "    (skipped — keychain profile 'Issues-notary' not configured on this machine)"

# Summary ------------------------------------------------------------------
print
print "================================================================"
if [[ $FAILS -eq 0 ]]; then
    print "  RESULT: READY TO DISTRIBUTE — all checks passed"
    print "================================================================"
    exit 0
else
    print "  RESULT: NOT READY — $FAILS check(s) failed"
    print "================================================================"
    exit 1
fi
