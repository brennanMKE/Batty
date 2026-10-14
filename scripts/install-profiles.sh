#!/usr/bin/env zsh
# scripts/install-profiles.sh -- copy the repo's Developer ID provisioning
# profiles into the directory xcodebuild reads installed profiles from.
#
# Manual signing selects a profile by name (PROVISIONING_PROFILE_SPECIFIER),
# and xcodebuild finds a name only among installed profiles. This is a local
# file copy named by each profile's UUID; it contacts nobody and never
# creates, renews or revokes a certificate or profile. Idempotent: a profile
# already installed with identical bytes is left alone. An installed profile
# with the same Name as a repo profile but a different UUID is removed, so the
# specifier cannot resolve to a stale one; profiles with other names are never
# touched, except the retired names below. BATTY_PROFILES_REPO_DIR and BATTY_PROFILES_INSTALL_DIR override the
# two directories (for checking this script against scratch directories).
#
# Usage: scripts/install-profiles.sh [--quiet]

set -euo pipefail

REPO="${0:A:h:h}"
PROFILES_DIR="${BATTY_PROFILES_REPO_DIR:-$REPO/Configuration/Profiles}"
DEST="${BATTY_PROFILES_INSTALL_DIR:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles}"
QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

if [[ ! -d "$PROFILES_DIR" ]]; then
    print -u2 "install-profiles.sh: $PROFILES_DIR not found"
    exit 1
fi

mkdir -p "$DEST"
profiles=("$PROFILES_DIR"/*.provisionprofile(N))
if (( ${#profiles} == 0 )); then
    print -u2 "install-profiles.sh: no .provisionprofile files in $PROFILES_DIR"
    exit 1
fi

profile_field() {
    local decoded
    decoded="$(mktemp "${TMPDIR:-/tmp}/batty-profile.XXXXXX")"
    if security cms -D -i "$1" > "$decoded" 2>/dev/null; then
        /usr/libexec/PlistBuddy -c "Print :$2" "$decoded" 2>/dev/null
    fi
    rm -f "$decoded"
}

# Retired profiles that list a certificate this Mac does not hold; removed
# from the local directory (never from the account) wherever they are found.
retired_names=("Batty" "Batty Beta")

typeset -A repo_uuid_by_name
for profile in "${profiles[@]}"; do
    repo_uuid_by_name[$(profile_field "$profile" Name)]="$(profile_field "$profile" UUID)"
done

for installed in "$DEST"/*.provisionprofile(N); do
    name="$(profile_field "$installed" Name)"
    [[ -n "$name" ]] || continue
    if [[ -z "${repo_uuid_by_name[$name]:-}" ]]; then
        if (( ${retired_names[(Ie)$name]} )); then
            rm -f "$installed"
            (( QUIET )) || print "retired profile removed: ${installed:t} (named $name)"
        fi
        continue
    fi
    if [[ "${installed:t:r}" != "${repo_uuid_by_name[$name]}" ]]; then
        rm -f "$installed"
        (( QUIET )) || print "stale profile removed: ${installed:t} (named $name)"
    fi
done

for profile in "${profiles[@]}"; do
    decoded="$(mktemp "${TMPDIR:-/tmp}/batty-profile.XXXXXX")"
    security cms -D -i "$profile" > "$decoded"
    uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$decoded")"
    rm -f "$decoded"
    if [[ -z "$uuid" ]]; then
        print -u2 "install-profiles.sh: could not read the UUID of $profile"
        exit 1
    fi
    target="$DEST/$uuid.provisionprofile"
    if [[ -f "$target" ]] && cmp -s "$profile" "$target"; then
        (( QUIET )) || print "profile already installed: ${profile:t} ($uuid)"
    else
        cp "$profile" "$target"
        (( QUIET )) || print "profile installed: ${profile:t} ($uuid)"
    fi
done
