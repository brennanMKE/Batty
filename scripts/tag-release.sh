#!/usr/bin/env zsh
# Tag the current HEAD with v<MARKETING_VERSION>. Reads the version from
# Configuration/App.xcconfig so the tag always matches what shipped.
#
# Run from a clean working tree, ideally after release.sh produced a DMG
# and after deploy-website.sh pushed the updated appcast. Prompts before
# pushing the tag to origin so the user can review locally first.
#
# Usage:
#   scripts/tag-release.sh                 # interactive
#   scripts/tag-release.sh --push          # tag and push without prompting
#   scripts/tag-release.sh --no-push       # tag locally only

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
XCCONFIG="$REPO_ROOT/Configuration/App.xcconfig"

push_mode="ask"
for arg in "$@"; do
    case "$arg" in
        --push) push_mode="yes" ;;
        --no-push) push_mode="no" ;;
        -h|--help)
            sed -n '1,/^set -euo/p' "$0" | sed '/^set -euo/d'
            exit 0
            ;;
        *)
            print -u2 "error: unknown flag $arg"
            exit 1
            ;;
    esac
done

if [[ ! -f "$XCCONFIG" ]]; then
    print -u2 "error: $XCCONFIG not found"
    exit 1
fi

VERSION=$(grep -E '^MARKETING_VERSION' "$XCCONFIG" | head -1 | awk -F= '{print $2}' | tr -d ' ')

if [[ -z "$VERSION" ]]; then
    print -u2 "error: could not extract MARKETING_VERSION from $XCCONFIG"
    exit 1
fi

TAG="v$VERSION"

if [[ -n "$(git status --porcelain)" ]]; then
    print -u2 "error: working tree is not clean — commit or stash first"
    git status --short
    exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    print -u2 "error: tag $TAG already exists locally"
    print -u2 "       git tag -d $TAG to remove, then re-run"
    exit 1
fi

HEAD_SHA=$(git rev-parse --short HEAD)

print "==> Tagging HEAD ($HEAD_SHA) as $TAG"
git tag -a "$TAG" -m "Batty $VERSION"

print "==> Created annotated tag:"
git show --no-patch --pretty=format:'%H%n  Tagger: %an <%ae>%n  Date:   %ad%n  %s%n' "$TAG"
print ""

case "$push_mode" in
    yes)
        print "==> Pushing $TAG to origin"
        git push origin "$TAG"
        ;;
    no)
        print "Tag created locally. To publish: git push origin $TAG"
        ;;
    ask)
        print ""
        if [[ -t 0 ]]; then
            printf "Push %s to origin? [y/N] " "$TAG"
            read -r reply
            case "$reply" in
                y|Y|yes)
                    git push origin "$TAG"
                    ;;
                *)
                    print "Skipped. To publish later: git push origin $TAG"
                    ;;
            esac
        else
            print "Non-interactive; not pushing. To publish: git push origin $TAG"
        fi
        ;;
esac
