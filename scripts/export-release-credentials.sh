#!/usr/bin/env zsh
# Export the release credentials this machine has into a portable bundle for
# a second Mac — the ASC API key .p8, the Developer ID Application cert +
# private key as a password-protected .p12, and the Sparkle EdDSA private
# key. Pairs with scripts/import-release-credentials.sh on the target Mac.
# See scripts/RELEASE-CREDENTIALS.md for the full replication/backup story.
#
# THE BUNDLE THIS PRODUCES CONTAINS UNRECOVERABLE SECRETS (the Sparkle
# private key most of all — see scripts/RELEASE-CREDENTIALS.md's "Backup"
# section). Store it somewhere you control (a password manager or an
# encrypted volume), then delete any temporary copy, including the one this
# script just wrote if you move it elsewhere.
#
# Nothing here is destructive: every step only *reads* from the keychain /
# filesystem. Missing items are skipped and reported, not treated as a hard
# failure — run this on whichever machine has some subset of the three
# credentials, then run it again on the other machine and merge the bundles
# by hand if needed.
#
# Usage:
#   scripts/export-release-credentials.sh <destination-dir>
#
# <destination-dir> is created if needed (mode 700) and MUST be outside this
# repository — refused otherwise, since a git commit is the last place these
# secrets should ever land.

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
SETUP_KEYS="$SCRIPT_DIR/setup-keys.sh"
BUILD_XCCONFIG="$REPO_ROOT/Configuration/Build.xcconfig"
APP_XCCONFIG="$REPO_ROOT/Configuration/App.xcconfig"

if [[ $# -ge 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    sed -n '2,/^set -uo/p' "$0" | sed '/^set -uo/d' | sed 's/^# *//'
    exit 0
fi

if [[ $# -ne 1 ]]; then
    print -u2 "usage: scripts/export-release-credentials.sh <destination-dir>"
    exit 2
fi

DEST_ARG="$1"

pass() { print "  [✓] $1"; }
warn() { print "  [!] $1"; }
fail() { print "  [✗] $1"; }

# --- Resolve destination, refuse anything inside the repo -------------------
#
# The destination may not exist yet, so plain `:A` (which requires the path
# to exist to fully resolve) isn't reliable here. Walk up from the full path
# to the longest EXISTING ancestor directory, resolve that ancestor for real
# (`:A`, following symlinks), then re-normalize the non-existent suffix
# lexically, one component at a time (`..` pops, `.` is dropped) instead of
# reattaching it as a raw string. A prior version reattached the suffix
# as-is, so a suffix containing `..` after a non-existent intermediate
# component (e.g. `nonexistentdir/../Batty/deep/nested`) skipped the repo
# check entirely — the string comparison never saw the `..` collapse back
# into the repo, even though `mkdir -p` on that same string does land there
# (mkdir -p creates `nonexistentdir` before it needs to resolve the `..`
# that follows it, so by the time the kernel gets there, the `..` walks back
# out for real). Doing the collapse ourselves, in-process, before any
# `mkdir` runs closes that gap without depending on filesystem side effects.
resolve_abs() {
    local p="$1"
    if [[ -e "$p" ]]; then
        print -r -- "${p:A}"
        return
    fi
    local abs_p
    if [[ "$p" == /* ]]; then
        abs_p="$p"
    else
        abs_p="$PWD/$p"
    fi
    local ancestor="$abs_p"
    local -a suffix
    while [[ "$ancestor" != "/" && ! -d "$ancestor" ]]; do
        suffix=("${ancestor:t}" "${suffix[@]}")
        ancestor="${ancestor:h}"
    done
    local resolved="${ancestor:A}"
    local comp
    for comp in "${suffix[@]}"; do
        case "$comp" in
            ".") ;;
            "..") resolved="${resolved:h}" ;;
            *) resolved="$resolved/$comp" ;;
        esac
    done
    print -r -- "$resolved"
}

DEST_ABS="$(resolve_abs "$DEST_ARG")"
REPO_ABS="${REPO_ROOT:A}"

if [[ "$DEST_ABS" == "$REPO_ABS" || "$DEST_ABS" == "$REPO_ABS"/* ]]; then
    fail "destination ($DEST_ABS) is inside the Batty repository ($REPO_ABS) — refusing"
    print -u2 ""
    print -u2 "  This bundle contains unrecoverable secrets and must never be committed"
    print -u2 "  or land anywhere git could pick it up. Choose a destination outside the"
    print -u2 "  repo, e.g.:"
    print -u2 "    scripts/export-release-credentials.sh ~/Backups/batty-release-credentials"
    exit 1
fi

if ! mkdir -p "$DEST_ABS"; then
    fail "could not create destination directory ($DEST_ABS)"
    exit 1
fi
if ! chmod 700 "$DEST_ABS"; then
    fail "chmod 700 failed on destination directory ($DEST_ABS)"
    exit 1
fi

print "==> Exporting release credentials to: $DEST_ABS"
print ""

EXPORTED_COUNT=0
SKIPPED_COUNT=0

# --- 1. ASC API key .p8 ------------------------------------------------------
#
# Read the expected path from setup-keys.sh itself rather than hardcoding
# it here a second time — the two must never drift.

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
    if [[ ! -f "$asc_key" ]]; then
        warn "ASC API key not found at $asc_key on this machine — skipped"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    fi
    local dest="$DEST_ABS/$(basename "$asc_key")"
    if ! cp "$asc_key" "$dest"; then
        fail "cp failed while exporting ASC API key to $dest — NOT exported"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    fi
    if ! chmod 600 "$dest"; then
        fail "chmod 600 failed on $dest after export — permissions may be too open, remove it and retry"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    fi
    pass "ASC API key exported ($asc_key -> $dest)"
    EXPORTED_COUNT=$((EXPORTED_COUNT + 1))
}
section_asc
print ""

# --- 2. Developer ID Application cert + private key, as a .p12 --------------
#
# `security export -t identities` has no per-item filter — it exports every
# cert+key pair in the given keychain, not just the one we want. Warn if the
# login keychain holds more than one signing identity so the operator knows
# the .p12 may be broader than just Batty's Developer ID cert; it is still
# safe (nothing is modified), just worth knowing before handing the file to
# someone else. A cleaner single-identity export is the GUI path documented
# in scripts/RELEASE-CREDENTIALS.md (Keychain Access > Export 2 items…).

section_p12() {
    print -- "-- Developer ID Application cert + private key (.p12) --"
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
    if [[ -z "$sign_identity" ]]; then
        warn "no Developer ID Application identity for team $team_id in the login keychain — skipped"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    fi

    local all_identities
    all_identities=$(security find-identity -v 2>/dev/null | grep -c '^ *[0-9]) ' || true)
    if [[ "${all_identities:-0}" -gt 1 ]]; then
        warn "login keychain has $all_identities signing identities total — the .p12 will contain ALL of them, not just Developer ID Application"
        security find-identity -v 2>/dev/null | sed 's/^/      /'
    fi

    local dest="$DEST_ABS/DeveloperID.p12"
    if [[ -e "$dest" ]]; then
        fail "$dest already exists — remove it first if you want a fresh export (never auto-overwritten)"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    fi

    print "A GUI prompt from security(1) will ask you to set a passphrase to protect the exported .p12 — that dialog, not this terminal, is where it's typed."
    if security export -k login.keychain-db -t identities -f pkcs12 -o "$dest" >${TMPDIR:-/tmp}/batty-export-p12.log 2>&1; then
        if chmod 600 "$dest"; then
            pass "Developer ID .p12 exported ($dest)"
            EXPORTED_COUNT=$((EXPORTED_COUNT + 1))
        else
            fail "chmod 600 failed on $dest after export — permissions may be too open, remove it and retry"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        fi
    else
        fail "security export failed (see ${TMPDIR:-/tmp}/batty-export-p12.log) — Developer ID .p12 NOT exported"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    fi
}
section_p12
print ""

# --- 3. Sparkle EdDSA private key --------------------------------------------
#
# generate_keys -x exports the EXISTING key only — verified directly from
# Sparkle's source (generate_keys/main.swift): export mode calls
# findSecret(account:) and fails with "No existing signing key found!" if
# there isn't one already; it never generates a new keypair as a side
# effect of -x. It also refuses to overwrite an existing destination file
# (checked before the keychain lookup even runs) — so check that ourselves
# first and skip cleanly instead of letting -x abort with its own error.
# Never call generate_keys with -f here; -x only.

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
    local generate_keys
    generate_keys=$(find_sparkle_tool generate_keys) || {
        warn "generate_keys not found — run scripts/build.sh once to produce the Sparkle SPM artifacts, then re-run this export"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    }

    local dest="$DEST_ABS/batty-sparkle.key"
    if [[ -e "$dest" ]]; then
        warn "$dest already exists in the destination bundle — leaving it in place (generate_keys -x refuses to overwrite; remove it yourself first for a fresh export)"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    fi

    if "$generate_keys" --account Batty -x "$dest" >${TMPDIR:-/tmp}/batty-export-sparkle.log 2>&1; then
        if chmod 600 "$dest"; then
            pass "Sparkle EdDSA private key exported ($dest)"
            EXPORTED_COUNT=$((EXPORTED_COUNT + 1))
        else
            fail "chmod 600 failed on $dest after export — permissions may be too open, remove it and retry"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        fi
    else
        warn "no Sparkle EdDSA private key found in login keychain (account 'Batty') on this machine — skipped (see ${TMPDIR:-/tmp}/batty-export-sparkle.log)"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    fi
}
section_sparkle
print ""

# --- Summary ------------------------------------------------------------------

print -- "-- Summary --"
print "  $EXPORTED_COUNT item(s) exported, $SKIPPED_COUNT skipped, to: $DEST_ABS"
print ""
print "  WARNING: this bundle contains unrecoverable secrets (the Sparkle"
print "  private key especially — losing it permanently breaks updates for"
print "  every existing install; there is no recovery path through Apple or"
print "  anywhere else). Move it to storage you control (a password manager"
print "  or an encrypted volume), then delete this copy and any other"
print "  temporary copy made along the way (e.g. in Downloads, Airdrop, a"
print "  clipboard manager's history)."
print ""
print "  Import on the target Mac with:"
print "    scripts/import-release-credentials.sh $DEST_ABS"

if [[ "$EXPORTED_COUNT" -eq 0 ]]; then
    fail "nothing was exported — this machine has none of the three credentials"
    exit 1
fi
exit 0
