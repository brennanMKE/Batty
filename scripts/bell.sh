#!/usr/bin/env zsh
# scripts/bell.sh — emit a BEL or OSC 9 notification for testing the Bell Feed.
#
# Usage:
#   scripts/bell.sh                          # plain BEL
#   scripts/bell.sh "Build finished"         # OSC 9 with message
#   scripts/bell.sh -d 5 "Switch panes!"     # delay 5s, then fire
#   scripts/bell.sh -n 3 "Heartbeat"         # 3 pulses, 1s apart

set -euo pipefail

delay=0
count=1

while getopts "d:n:h" opt; do
    case "$opt" in
        d) delay="$OPTARG" ;;
        n) count="$OPTARG" ;;
        h) sed -n '2,7p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))

message="$*"

(( delay > 0 )) && sleep "$delay"

for (( i = 1; i <= count; i++ )); do
    if [[ -n "$message" ]]; then
        printf '\033]9;%s\007' "$message"
    else
        printf '\a'
    fi
    (( i < count )) && sleep 1
done
