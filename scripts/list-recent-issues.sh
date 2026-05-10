#!/usr/bin/env zsh
# List recently updated issues sorted by file mtime, newest first.
#
# Each line is: number, status, age, title — four columns separated by
# two spaces, suitable for piping into grep/awk. Age is the time since
# the file was last modified (e.g. 12s, 4m, 3h, 2d, 5w, 6mo, 1y).

set -euo pipefail
zmodload zsh/datetime

SCRIPT_DIR="${0:A:h}"
SCRIPT_NAME="${0##*/}"
REPO_ROOT="${SCRIPT_DIR:h}"
ISSUES_DIR="$REPO_ROOT/issues"

LIMIT=20

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [-n LIMIT] [-h]

List recently updated issues from $ISSUES_DIR, sorted by mtime (newest first).
Columns: number  status  age  title.

Options:
  -n LIMIT  Show at most LIMIT issues (default: 20). Use 0 for no limit.
  -h        Show this help.
EOF
}

# Format a duration in seconds as a compact human-readable age:
#   <60s -> Ns, <60m -> Nm, <24h -> Nh, <7d -> Nd, <30d -> Nw,
#   <365d -> Nmo, else Ny.
human_age() {
    local secs=$1
    if (( secs < 60 )); then
        printf "%ds" "$secs"
    elif (( secs < 3600 )); then
        printf "%dm" $(( secs / 60 ))
    elif (( secs < 86400 )); then
        printf "%dh" $(( secs / 3600 ))
    elif (( secs < 604800 )); then
        printf "%dd" $(( secs / 86400 ))
    elif (( secs < 2592000 )); then
        printf "%dw" $(( secs / 604800 ))
    elif (( secs < 31536000 )); then
        printf "%dmo" $(( secs / 2592000 ))
    else
        printf "%dy" $(( secs / 31536000 ))
    fi
}

while getopts "n:h" opt; do
    case "$opt" in
        n) LIMIT="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [[ ! -d "$ISSUES_DIR" ]]; then
    print -u2 "error: $ISSUES_DIR not found"
    exit 1
fi

# zsh glob qualifiers:
#   N   null-glob (don't error if no match)
#   .   regular files only
#   om  order by mtime, newest first
typeset -a files
files=("$ISSUES_DIR"/[0-9][0-9][0-9][0-9].md(N.om))

if (( ${#files} == 0 )); then
    print -u2 "no issue files in $ISSUES_DIR"
    exit 0
fi

if (( LIMIT > 0 )) && (( ${#files} > LIMIT )); then
    files=("${files[@]:0:$LIMIT}")
fi

now=$EPOCHSECONDS

for f in $files; do
    id="${${f:t}:r}"

    # `status` is a read-only built-in in zsh ($? alias), so use `state`.
    state=$(awk -F'\\|' '
        /^\| \*\*Status\*\* \|/ {
            gsub(/^[ \t]+|[ \t]+$/, "", $3)
            print $3
            exit
        }
    ' "$f")
    [[ -z "$state" ]] && state="?"

    # Title line: "# NNNN — Title". Strip the prefix (em-dash is U+2014).
    title=$(awk 'NR==1 {
        sub(/^# +[0-9]+ +— +/, "")
        print
        exit
    }' "$f")
    [[ -z "$title" ]] && title="(no title)"

    mtime=$(stat -f %m "$f")
    age=$(human_age $(( now - mtime )))

    printf "%s  %-12s  %5s  %s\n" "$id" "$state" "$age" "$title"
done
