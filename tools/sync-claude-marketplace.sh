#!/bin/zsh
# Regenerates the public Claude Code plugin marketplace and copies it into a
# local clone of the marketplace repo (AgentPluginTree.publicRepository).
# It never commits, tags or pushes: it prints those git commands for the user.
#   tools/sync-claude-marketplace.sh <clone> [--version X.Y.Z] [--from DIR] [--dry-run]
# --from syncs an already generated tree instead of regenerating one.
# --dry-run runs every safety check, prints what it would replace, writes nothing.
#
# Only the managed paths below are ever written or deleted in the clone, and
# --delete is confined to the managed directories, so a wrong <clone> can at
# worst lose those paths. The clone must be the top level of a git repo that
# is not any checkout or worktree of this repo, and must be either empty
# (apart from IGNORED_WHEN_EMPTY) or already hold this marketplace's
# .claude-plugin/marketplace.json.
set -euo pipefail
ROOT="${0:A:h:h}"
MARKETPLACE_NAME="batty-plugins"
MANAGED_DIRS=(.claude-plugin batty)
MANAGED_FILES=(README.md)
IGNORED_WHEN_EMPTY=(.git LICENSE README.md .gitignore .gitattributes)

usage() {
    print -u2 "usage: tools/sync-claude-marketplace.sh <clone> [--version X.Y.Z] [--from DIR] [--dry-run]"
    exit 2
}
refuse() {
    print -u2 "error: $1; nothing was changed"
    exit 2
}

(( $# >= 1 )) || usage
CLONE="${1:A}"
shift
FROM=""
DRY_RUN=0
GEN_ARGS=()
while (( $# )); do
    case "$1" in
        --version) (( $# >= 2 )) || usage; GEN_ARGS+=(--version "$2"); shift 2 ;;
        --from) (( $# >= 2 )) || usage; FROM="${2:A}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) usage ;;
    esac
done

[[ -d "$CLONE" ]] || refuse "$CLONE is not a directory"
TOP=$(git -C "$CLONE" rev-parse --show-toplevel 2>/dev/null) || refuse "$CLONE is not a git repository"
[[ "${TOP:A}" == "$CLONE" ]] || refuse "$CLONE is not the top level of its git repository (${TOP:A})"
CLONE_COMMON=$(git -C "$CLONE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || refuse "cannot resolve the git directory of $CLONE"
ROOT_COMMON=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || refuse "cannot resolve the git directory of $ROOT"
[[ "${CLONE_COMMON:A}" != "${ROOT_COMMON:A}" ]] \
    || refuse "$CLONE is a checkout or worktree of this repo, not the marketplace clone"

MARKETPLACE_JSON="$CLONE/.claude-plugin/marketplace.json"
if [[ -f "$MARKETPLACE_JSON" ]]; then
    NAME=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name", ""))' "$MARKETPLACE_JSON" 2>/dev/null) \
        || refuse "$MARKETPLACE_JSON is not valid JSON"
    [[ "$NAME" == "$MARKETPLACE_NAME" ]] || refuse "$MARKETPLACE_JSON names marketplace '$NAME', not '$MARKETPLACE_NAME'"
else
    for entry in "$CLONE"/*(DN); do
        (( ${IGNORED_WHEN_EMPTY[(Ie)${entry:t}]} )) && continue
        refuse "$CLONE is not empty and holds no .claude-plugin/marketplace.json (found ${entry:t})"
    done
fi
for p in $MANAGED_DIRS $MANAGED_FILES; do
    [[ ! -L "$CLONE/$p" ]] || refuse "$CLONE/$p is a symbolic link"
done
for d in $MANAGED_DIRS; do
    [[ ! -e "$CLONE/$d" || -d "$CLONE/$d" ]] || refuse "$CLONE/$d is not a directory"
done
for f in $MANAGED_FILES; do
    [[ ! -e "$CLONE/$f" || -f "$CLONE/$f" ]] || refuse "$CLONE/$f is not a regular file"
done

if (( DRY_RUN )); then
    print "dry run: $CLONE passed every check; a real run would replace ${MANAGED_DIRS[*]} ${MANAGED_FILES[*]} there"
    exit 0
fi

if [[ -n "$FROM" ]]; then
    SRC="$FROM"
else
    SRC="$ROOT/build/claude-marketplace"
    python3 -I "$ROOT/tools/build-agent-downloads.py" --no-skill --marketplace-out "$SRC" "${GEN_ARGS[@]}"
fi
[[ -f "$SRC/.claude-plugin/marketplace.json" ]] || refuse "$SRC holds no .claude-plugin/marketplace.json"
for d in $MANAGED_DIRS; do
    [[ -d "$SRC/$d" ]] || refuse "$SRC/$d is missing"
done

for d in $MANAGED_DIRS; do
    mkdir -p "$CLONE/$d"
    rsync -a --delete "$SRC/$d/" "$CLONE/$d/"
done
for f in $MANAGED_FILES; do
    if [[ -f "$SRC/$f" ]]; then
        cp "$SRC/$f" "$CLONE/$f"
    fi
done
if command -v claude >/dev/null 2>&1; then
    claude plugin validate "$CLONE"
fi
VERSION=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$SRC/batty/.claude-plugin/plugin.json")
git -C "$CLONE" status --short
cat <<CMDS

Review the diff, then run these yourself:
  git -C "$CLONE" add -A
  git -C "$CLONE" commit -m "Batty $VERSION"
  git -C "$CLONE" tag v$VERSION
  git -C "$CLONE" push origin main --tags
CMDS
