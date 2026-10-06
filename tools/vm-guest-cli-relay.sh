#!/bin/zsh
# vm-guest-cli-relay.sh — launched by a guest-only launchd agent (inetd style,
# one connection per run, loopback only; set up by vm-guest-broker.sh, #0419).
#
# The XCUITest runner is App Sandboxed and its children inherit the sandbox, so
# a `batty` it spawns cannot mach-lookup the broker. This relay runs the
# embedded CLI outside that sandbox on the runner's behalf: it reads one line of
# arguments from stdin, runs the CLI with them (no shell evaluation), and writes
# the combined output followed by a final "__EXIT__ <status>" line.
#
# Usage (set in the agent plist): vm-guest-cli-relay.sh <path/to/batty>

cli="${1:?usage: vm-guest-cli-relay.sh <batty>}"
[[ -x "$cli" ]] || { print -r -- "relay: $cli is not executable"; print -r -- "__EXIT__ 126"; exit 0; }

IFS= read -r line
args=( "${(@ps:\t:)line}" )
out="$(/usr/bin/perl -e 'alarm 45; exec @ARGV' -- "$cli" "${args[@]}" 2>&1 < /dev/null)"
rc=$?
print -r -- "$out"
print -r -- "__EXIT__ $rc"
