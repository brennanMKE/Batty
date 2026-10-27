#!/usr/bin/env zsh
# Sourced by release.sh and preflight.sh; not run on its own.
#
# The release build number (CFBundleVersion, compared by Sparkle as
# sparkle:version) is the UTC time YYYYMMDDHHMM. It was YYYYMMDD until two
# releases on one UTC day got the same number (#0537). Every 12-digit value
# is greater than every 8-digit one, so Sparkle's ordering stays monotonic
# across the change.

release_build_number() {
    date -u +%Y%m%d%H%M
}

# Highest sparkle:version in the checked-out website/appcast.xml and in local
# main's copy. A release/X.Y worktree's appcast lags main's, where items are
# committed. XML comments are stripped so placeholder text never counts.
newest_appcast_build() {
    local repo_root="$1"
    {
        [[ -f "$repo_root/website/appcast.xml" ]] && cat "$repo_root/website/appcast.xml"
        if git -C "$repo_root" rev-parse --verify -q main >/dev/null 2>&1; then
            git -C "$repo_root" show main:website/appcast.xml 2>/dev/null
        fi
        true
    } | perl -0777 -pe 's/<!--.*?-->//gs' \
      | grep -oE 'sparkle:version="[0-9]+"' | grep -oE '[0-9]+' \
      | sort -rn | head -1 || true
}

# Succeeds when <newest> is empty or <candidate> is strictly greater.
build_number_is_newer() {
    local candidate="$1" newest="$2"
    [[ -z "$newest" ]] && return 0
    (( candidate > newest ))
}
