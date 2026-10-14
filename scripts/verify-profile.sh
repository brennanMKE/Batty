#!/usr/bin/env zsh
# scripts/verify-profile.sh <path/to/App.app> -- check that a signed app embeds
# the provisioning profile that authorizes its iCloud key-value entitlement.
#
# Asserts, for the app's own bundle identifier B and team T:
#   1. Contents/embedded.provisionprofile exists;
#   2. the profile's com.apple.application-identifier is T.B and it carries
#      com.apple.developer.ubiquity-kvstore-identifier;
#   3. the app's signature carries com.apple.developer.ubiquity-kvstore-identifier
#      equal to T.B;
#   4. the certificate that signed the app is one of the profile's
#      DeveloperCertificates (otherwise the system rejects the app at launch);
#   5. the profile has not expired.
# It prints the profile's name, UUID and ExpirationDate. Exit 0 only if every
# assertion passes. Read-only against the app.

set -uo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
    print -u2 "usage: $0 <path/to/App.app>"
    exit 2
fi

APP="$1"
PROFILE="$APP/Contents/embedded.provisionprofile"
KVKEY="com.apple.developer.ubiquity-kvstore-identifier"
FAILS=0
pass() { print "    PASS: $*"; }
fail() { print "    FAIL: $*"; FAILS=$((FAILS + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/batty-verify-profile.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
TEAM="$(codesign -dv "$APP" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
EXPECTED="$TEAM.$BUNDLE_ID"
if [[ -z "$BUNDLE_ID" || -z "$TEAM" ]]; then
    fail "could not read the bundle identifier ('$BUNDLE_ID') or team ('$TEAM') of $APP"
    exit 1
fi

if [[ ! -f "$PROFILE" ]]; then
    fail "no Contents/embedded.provisionprofile in $APP"
    exit 1
fi
pass "embedded.provisionprofile present"

if ! security cms -D -i "$PROFILE" > "$WORK/profile.plist" 2>/dev/null; then
    fail "the embedded profile could not be decoded"
    exit 1
fi
profile_value() { /usr/libexec/PlistBuddy -c "Print $1" "$WORK/profile.plist" 2>/dev/null; }

PROFILE_NAME="$(profile_value :Name)"
PROFILE_UUID="$(profile_value :UUID)"
PROFILE_EXPIRY="$(/usr/libexec/PlistBuddy -x -c 'Print :ExpirationDate' "$WORK/profile.plist" 2>/dev/null | sed -n 's/.*<date>\(.*\)<\/date>.*/\1/p')"
print "    Profile: $PROFILE_NAME ($PROFILE_UUID)"
print "    Profile ExpirationDate: $PROFILE_EXPIRY"

if [[ "$(profile_value :Entitlements:com.apple.application-identifier)" == "$EXPECTED" ]]; then
    pass "profile application-identifier is $EXPECTED"
else
    fail "profile application-identifier is '$(profile_value :Entitlements:com.apple.application-identifier)', expected $EXPECTED"
fi

codesign -d --entitlements - --xml "$APP" 2>/dev/null > "$WORK/app-entitlements.plist"
APP_KV="$(/usr/libexec/PlistBuddy -c "Print :$KVKEY" "$WORK/app-entitlements.plist" 2>/dev/null || true)"
PROFILE_KV="$(profile_value ":Entitlements:$KVKEY")"
# The profile's value is a pattern such as XV8BAAVZ6V.*; the app's signed
# value must be covered by it.
if [[ -n "$PROFILE_KV" && -n "$APP_KV" && "$APP_KV" == ${~PROFILE_KV} ]]; then
    pass "profile's $KVKEY ($PROFILE_KV) covers the app's ($APP_KV)"
else
    fail "profile's $KVKEY ('$PROFILE_KV') does not cover the app's ('$APP_KV')"
fi
if [[ "$APP_KV" == "$EXPECTED" ]]; then
    pass "signature carries $KVKEY = $APP_KV"
else
    fail "signature carries $KVKEY = '${APP_KV}', expected $EXPECTED"
fi

codesign -d --extract-certificates="$WORK/cert" "$APP" >/dev/null 2>&1
if [[ -f "$WORK/cert0" ]]; then
    LEAF_SHA1="$(shasum "$WORK/cert0" | awk '{ print toupper($1) }')"
    MATCHED=0
    index=0
    while true; do
        sha="$(/usr/libexec/PlistBuddy -c "Print :DeveloperCertificates:$index" "$WORK/profile.plist" 2>/dev/null \
            | perl -0pe 's/\n\z//' | shasum | awk '{ print toupper($1) }')"
        # PlistBuddy prints nothing for a missing index; shasum of nothing is the empty digest.
        [[ "$sha" == "DA39A3EE5E6B4B0D3255BFEF95601890AFD80709" ]] && break
        [[ "$sha" == "$LEAF_SHA1" ]] && MATCHED=1
        index=$((index + 1))
    done
    if (( MATCHED )); then
        pass "the signing certificate ($LEAF_SHA1) is one the profile lists"
    else
        fail "the signing certificate ($LEAF_SHA1) is NOT listed in the profile's DeveloperCertificates; the system rejects such an app at launch"
    fi
else
    fail "could not extract the signing certificate"
fi

if [[ -n "$PROFILE_EXPIRY" ]]; then
    EXPIRY_EPOCH="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$PROFILE_EXPIRY" +%s 2>/dev/null || true)"
    if [[ -n "$EXPIRY_EPOCH" ]] && (( EXPIRY_EPOCH > $(date +%s) )); then
        pass "profile has not expired"
    else
        fail "profile expired or its expiry could not be read ($PROFILE_EXPIRY)"
    fi
else
    fail "profile has no ExpirationDate"
fi

exit $(( FAILS > 0 ))
