#!/usr/bin/env zsh
# Sourced by release.sh; not run on its own.
#
# release.sh must still remove the Release Batty.app it leaves in build/
# (#0026), but nothing else in build/ is the release's to delete: VM runner
# results (build/ui-tests, build/sparkle-tests) and check logs live there too.

# release_clean_owned_artifacts <build_dir> <path>...
# Validates every path is strictly under build_dir before deleting any.
release_clean_owned_artifacts() {
    local build_dir="$1"
    shift
    if [[ -z "$build_dir" || "$build_dir" == "/" ]]; then
        print -u2 "release_clean_owned_artifacts: refusing build dir '$build_dir'"
        return 1
    fi
    local root="${build_dir:A}"
    if [[ "$root" == "/" ]]; then
        print -u2 "release_clean_owned_artifacts: refusing build dir '$build_dir'"
        return 1
    fi
    local p resolved
    for p in "$@"; do
        resolved="${p:A}"
        if [[ -z "$p" || "$resolved" == "$root" || "$resolved" != "$root"/* ]]; then
            print -u2 "release_clean_owned_artifacts: refusing '$p' (not strictly under $root)"
            return 1
        fi
    done
    for p in "$@"; do
        rm -rf "$p"
    done
    rmdir "$build_dir" 2>/dev/null || true
}
