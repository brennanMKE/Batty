#!/usr/bin/env zsh
# Import a release-credential bundle produced by
# scripts/export-release-credentials.sh onto a fresh Mac: the ASC API key
# .p8, the Developer ID Application .p12, and the Sparkle EdDSA private key.
# See scripts/RELEASE-CREDENTIALS.md for the full replication/backup story.
#
# IDEMPOTENT AND NON-DESTRUCTIVE BY DESIGN: every step checks for an
# existing credential first and skips (reporting it) rather than
# overwriting. This is most important for the Sparkle key -- SUPublicEDKey
# is baked into every shipped copy of Batty already installed, so silently
# replacing the matching private key would permanently break updates for
# every existing install, with no recovery path. Re-running this script is
# always safe.
#
# Usage:
#   scripts/import-release-credentials.sh <bundle-dir> [--run-setup-keys]
#
# <bundle-dir> is the directory produced by export-release-credentials.sh
# (or one assembled by hand with the same three filenames: AuthKey_*.p8,
# DeveloperID.p12, batty-sparkle.key).
#
# --run-setup-keys additionally runs scripts/setup-keys.sh after installing
# the .p8, which calls `notarytool store-credentials` -- a network call to
# Apple. Default is to print the command and let you run it yourself; this
# script never invokes it on its own initiative.
#
# Ends by running scripts/preflight.sh --credentials-only and printing the
# resulting state of this machine.

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
SETUP_KEYS="$SCRIPT_DIR/setup-keys.sh"
BUILD_XCCONFIG="$REPO_ROOT/Configuration/Build.xcconfig"

pass() { print -- "  [✓] $1"; }
warn() { print -- "  [!] $1"; }
fail() { print -- "  [✗] $1"; }

RUN_SETUP_KEYS=0
BUNDLE_ARG=""
for arg in "$@"; do
    case "$arg" in
        --run-setup-keys) RUN_SETUP_KEYS=1 ;;
        -h|--help)
            sed -n '2,/^set -uo/p' "$0" | sed '/^set -uo/d' | sed 's/^# *//'
            exit 0
            ;;
        -*)
            print -u2 "error: unknown flag $arg"
            exit 2
            ;;
        *)
            if [[ -n "$BUNDLE_ARG" ]]; then
                print -u2 "error: unexpected extra argument: $arg"
                exit 2
            fi
            BUNDLE_ARG="$arg"
            ;;
    esac
done

if [[ -z "$BUNDLE_ARG" ]]; then
    print -u2 "usage: scripts/import-release-credentials.sh <bundle-dir> [--run-setup-keys]"
    exit 2
fi

if [[ ! -d "$BUNDLE_ARG" ]]; then
    print -u2 "error: $BUNDLE_ARG is not a directory"
    exit 2
fi
BUNDLE_DIR="${BUNDLE_ARG:A}"

print "==> Importing release credentials from: $BUNDLE_DIR"
print ""

IMPORTED_COUNT=0
SKIPPED_COUNT=0

# --- 1. ASC API key .p8 ------------------------------------------------------

section_asc() {
    print -- "-- ASC API key --"
    local key_line asc_key
    key_line=$(grep -oE -- '--key +[^ ]+' "$SETUP_KEYS" 2>/dev/null | head -1)
    asc_key=$(print -r -- "$key_line" | awk '{print $2}')
    if [[ -z "$asc_key" ]]; then
        fail "could not determine the ASC API key path from $SETUP_KEYS — check it by hand"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    fi
    asc_key="${asc_key/#\~/$HOME}"

    local src="$BUNDLE_DIR/$(basename "$asc_key")"
    if [[ ! -f "$src" ]]; then
        warn "ASC API key not found in bundle ($src) — skipped"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    fi

    if [[ -f "$asc_key" ]]; then
        if cmp -s "$src" "$asc_key"; then
            pass "ASC API key already present at $asc_key and matches the bundle — nothing to do"
        else
            fail "a DIFFERENT file already exists at $asc_key — NOT overwriting. Remove it yourself first if you intend to replace it"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        fi
        return
    fi

    if ! mkdir -p "${asc_key:h}"; then
        fail "mkdir -p ${asc_key:h} failed — ASC API key NOT imported"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    fi
    if ! cp "$src" "$asc_key"; then
        fail "cp failed while installing ASC API key to $asc_key — NOT imported"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    fi
    if ! chmod 600 "$asc_key"; then
        fail "chmod 600 failed on $asc_key after import — permissions may be too open, remove it and retry"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    fi
    pass "ASC API key installed at $asc_key"
    IMPORTED_COUNT=$((IMPORTED_COUNT + 1))

    if (( RUN_SETUP_KEYS )); then
        print "    Running scripts/setup-keys.sh to create the notarytool profile..."
        if "$SETUP_KEYS"; then
            pass "notarytool profile created via scripts/setup-keys.sh"
        else
            fail "scripts/setup-keys.sh failed — see its output above"
        fi
    else
        print "    Run this to create the notarytool profile (calls Apple; not run automatically):"
        print "      scripts/setup-keys.sh"
    fi
}
section_asc
print ""

# --- 2. Developer ID Application cert + private key (.p12) ------------------
#
# Skip entirely if a Developer ID Application identity for this team
# already exists in the login keychain. Importing a second copy on top of
# an existing one is exactly the kind of duplicate-certificate situation
# that led to this project's certificate-revocation incident (#0270/#0273/
# #0278/#0281) -- so "already present" is a hard skip, not a soft one.

section_p12() {
    print -- "-- Developer ID Application cert + private key (.p12) --"
    local src="$BUNDLE_DIR/DeveloperID.p12"
    if [[ ! -f "$src" ]]; then
        warn "DeveloperID.p12 not found in bundle — skipped"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    fi

    local team_id identity_line sign_identity
    team_id=$(grep -E '^DEVELOPMENT_TEAM' "$BUILD_XCCONFIG" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
    if [[ -z "$team_id" ]]; then
        fail "could not read DEVELOPMENT_TEAM from $BUILD_XCCONFIG"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    fi
    identity_line=$(security find-identity -p codesigning -v 2>/dev/null \
        | grep "Developer ID Application.*$team_id" | head -1)
    sign_identity=$(print -r -- "$identity_line" | sed -E 's/.*"(.*)"/\1/')
    if [[ -n "$sign_identity" ]]; then
        pass "Developer ID Application identity already present in login keychain for team $team_id — skipping import (existing credential preserved, not touched)"
        return
    fi

    print "A GUI prompt from security(1) will ask for the .p12's passphrase — that dialog, not this terminal, is where it's typed."
    if security import "$src" -k login.keychain-db -T /usr/bin/codesign >${TMPDIR:-/tmp}/batty-import-p12.log 2>&1; then
        identity_line=$(security find-identity -p codesigning -v 2>/dev/null \
            | grep "Developer ID Application.*$team_id" | head -1)
        if [[ -n "$identity_line" ]]; then
            pass "Developer ID .p12 imported and identity confirmed present"
            IMPORTED_COUNT=$((IMPORTED_COUNT + 1))
        else
            fail "security import reported success but the identity still isn't visible via find-identity — check Keychain Access manually"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        fi
    else
        fail "security import failed (see ${TMPDIR:-/tmp}/batty-import-p12.log) — check the passphrase and try again"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    fi
}
section_p12
print ""

# --- 3. Sparkle EdDSA private key --------------------------------------------
#
# Critical safety point, verified directly from Sparkle's source
# (generate_keys/main.swift): -f imports via SecItemAdd, which returns
# errSecDuplicateItem and exits WITHOUT overwriting when a key already
# exists for the account. That is the correct, safe behavior and this
# script must never try to work around it -- so probe first with -p (a
# read-only lookup) and skip cleanly with the same message either way,
# rather than depending on -f's own refusal.

find_sparkle_tool() {
    local name="$1" candidates c
    candidates=(
        "$REPO_ROOT/BattyKit/.build/artifacts/sparkle/Sparkle/bin/$name"
        $HOME/Library/Developer/Xcode/DerivedData/Batty-*/SourcePackages/artifacts/sparkle/Sparkle/bin/$name(N)
    )
    for c in $candidates; do
        [[ -x "$c" ]] && { print -r -- "$c"; return 0 }
    done
    return 1
}

section_sparkle() {
    print -- "-- Sparkle EdDSA private key --"
    local src="$BUNDLE_DIR/batty-sparkle.key"
    if [[ ! -f "$src" ]]; then
        warn "batty-sparkle.key not found in bundle — skipped"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    fi

    local generate_keys
    generate_keys=$(find_sparkle_tool generate_keys) || {
        warn "generate_keys not found — run scripts/build.sh once to produce the Sparkle SPM artifacts, then re-run this import"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    }

    local existing_pub
    existing_pub=$("$generate_keys" --account Batty -p 2>/dev/null) || existing_pub=""
    if [[ -n "$existing_pub" ]]; then
        pass "a Sparkle key already exists on this machine (account 'Batty') — nothing was changed. If this doesn't match the app's SUPublicEDKey, resolve that by hand; this script will not overwrite it"
        return
    fi

    if "$generate_keys" --account Batty -f "$src" >${TMPDIR:-/tmp}/batty-import-sparkle.log 2>&1; then
        pass "Sparkle EdDSA private key imported (account 'Batty')"
        IMPORTED_COUNT=$((IMPORTED_COUNT + 1))
    else
        fail "generate_keys -f failed (see ${TMPDIR:-/tmp}/batty-import-sparkle.log) — Sparkle key NOT imported"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    fi
}
section_sparkle
print ""

# --- Summary ------------------------------------------------------------------

print -- "-- Summary --"
print "  $IMPORTED_COUNT item(s) imported, $SKIPPED_COUNT skipped/already-present"
print ""
print "==> Running the credential check to confirm this machine's state"
print ""
"$SCRIPT_DIR/preflight.sh" --credentials-only
exit $?
