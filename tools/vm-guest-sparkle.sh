#!/bin/zsh
# vm-guest-sparkle.sh — runs INSIDE the Tart guest only (called by
# tools/run-sparkle-update-vm.sh through `tart exec`). One step per call:
#
#   setup               install A, guest-only Gatekeeper change, feed server,
#                       opt-in, broker and BattyHost agents, log capture
#   launch <mode>       open A with BATTY_BETA_SPARKLE_AUTO=<mode>, wait for
#                       `sparkle-auto: armed` and `batty ping`
#   populate            Sessions, splits, Tabs, a Project, running processes
#   snapshot <name>     write ~/results/<name>/
#   trigger <mode>      post the #0714 check notification and follow the update
#   collect             split the log stream, crash reports, defaults
#
# Every command that can block is bounded (perl alarm) and every wait polls a
# file, a pid or the log stream up to a bound. Exit 0 on success; any other exit prints one
# `GUEST-ERROR: <detail>` line, which the host runner turns into its ERROR.

set -u

APP="/Applications/Batty Beta.app"
CLI="$APP/Contents/Resources/bin/batty"
SHARE="/Volumes/My Shared Files/run"
R="$HOME/results"
S="$HOME/sparkle"
STREAM="$R/logs/stream.log"
BUNDLE_ID="co.sstools.Batty.beta"
OPT_IN_KEY="co.sstools.Batty.keepTerminalsRunningWhenBattyQuits"
CHECK_NOTIFICATION="co.sstools.Batty.beta.sparkle-auto.check"
FEED_PORT=47912
AGENT_DIR="$HOME/Library/Application Support/BattyUITests/agents"
uid="$(/usr/bin/id -u)"

err() { print -r -- "GUEST-ERROR: $*"; exit 3; }
note() { print -r -- "== $(date '+%H:%M:%S') $*"; }
tmo() { local s=$1; shift; /usr/bin/perl -e 'alarm shift; exec @ARGV' -- "$s" "$@"; }
now() { date '+%Y-%m-%d %H:%M:%S'; }
stream_size() { [[ -f "$STREAM" ]] && /usr/bin/stat -f %z "$STREAM" || print 0; }

# wait_log <offset> <secs> <regex>: prints the first matching line written
# after byte <offset>; returns 1 at the bound.
wait_log() {
  local off=$1 secs=$2 re=$3 deadline=$(( SECONDS + $2 )) line
  while (( SECONDS < deadline )); do
    line=$(/usr/bin/tail -c +$(( off + 1 )) "$STREAM" 2>/dev/null | /usr/bin/grep -E -m1 -- "$re")
    [[ -n "$line" ]] && { print -r -- "$line"; return 0; }
    sleep 1
  done
  return 1
}

wait_pid_exit() {
  local pid=$1 deadline=$(( SECONDS + $2 ))
  while kill -0 "$pid" 2>/dev/null; do (( SECONDS < deadline )) || return 1; sleep 1; done
  return 0
}

# Evidence for an app that won't quit: what's on screen and where it waits.
stuck() {
  tmo 20 /usr/sbin/screencapture -x "$R/screenshot-stuck.png" 2>/dev/null
  tmo 30 /usr/bin/sample "$1" 3 -file "$R/sample-stuck.txt" >/dev/null 2>&1
}

app_pid() { /usr/bin/pgrep -x "Batty Beta" | /usr/bin/head -1; }
app_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null; }

wait_ping() {
  local deadline=$(( SECONDS + $1 ))
  until tmo 10 "$CLI" ping >/dev/null 2>&1; do (( SECONDS < deadline )) || return 1; sleep 2; done
}

json_field() { /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

write_agent() {  # write_agent <label> <plist-path> <extra xml> <program args...>
  local label=$1 plist=$2 extra=$3; shift 3
  local args="" a
  for a in "$@"; do args+="<string>${a//&/&amp;}</string>"; done
  /bin/mkdir -p "${plist:h}"
  print -r -- "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array>$args</array>
$extra
</dict></plist>" > "$plist"
  tmo 20 /bin/launchctl bootout "gui/$uid/$label" </dev/null >/dev/null 2>&1
  tmo 20 /bin/launchctl bootstrap "gui/$uid" "$plist" </dev/null
}

[[ "$(/usr/sbin/sysctl -n kern.hv_vmm_present 2>/dev/null)" == "1" ]] || { print -r -- "GUEST-ERROR: refusing: not a VM guest"; exit 1; }

step="${1:-}"; shift || true

case "$step" in
setup)
  /bin/mkdir -p "$R/logs" "$R/crashes" "$S/feed" "$S/pids" "$S/bin" "$S/project" "$S/s2" "$S/s3" "$S/tools"
  exec > >(/usr/bin/tee -a "$R/setup.log") 2>&1
  note "sw_vers"; /usr/bin/sw_vers
  /bin/cp "$SHARE"/tools/*.sh "$S/tools/"

  note "log capture"
  write_agent co.sstools.sparkle-test.logstream "$AGENT_DIR/co.sstools.sparkle-test.logstream.plist" \
    "<key>RunAtLoad</key><true/><key>StandardOutPath</key><string>$STREAM</string><key>StandardErrorPath</key><string>$R/logs/stream.err</string>" \
    /usr/bin/log stream --level info --style compact \
    --predicate "subsystem == \"$BUNDLE_ID\" OR process == \"BattyHost\" OR subsystem BEGINSWITH \"org.sparkle-project\" OR eventMessage CONTAINS \"-67065\"" \
    || err "log stream agent failed"
  deadline=$(( SECONDS + 30 ))
  until [[ -s "$STREAM" ]]; do (( SECONDS < deadline )) || break; sleep 1; done

  note "install A"
  tmo 120 /usr/bin/ditto -x -k "$SHARE/A.zip" /Applications || err "unzip A failed"
  /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null
  note "Gatekeeper (guest only)"
  tmo 20 /usr/bin/sudo -n /usr/sbin/spctl --global-disable; print -r -- "spctl --global-disable rc=$?"
  tmo 20 /usr/sbin/spctl --status
  tmo 30 /usr/bin/codesign -dvvv "$APP"
  tmo 30 /usr/bin/codesign -dvvv "$APP/Contents/Resources/bin/BattyHost"

  note "feed server"
  # The headless updater also runs Sparkle's own launch-time check, so the feed
  # holds no item until `trigger` swaps the real appcast in.
  /bin/cp "$SHARE/appcast.xml" "$S/appcast-real.xml" || err "copy feed failed"
  /bin/cp "$SHARE/B.dmg" "$S/feed/" || err "copy feed failed"
  /usr/bin/sed '/<item>/,/<\/item>/d' "$S/appcast-real.xml" > "$S/feed/appcast.xml"
  write_agent co.sstools.sparkle-test.feed "$AGENT_DIR/co.sstools.sparkle-test.feed.plist" \
    "<key>RunAtLoad</key><true/><key>StandardErrorPath</key><string>$R/logs/feed-server.log</string>" \
    /usr/bin/python3 -m http.server $FEED_PORT --bind 127.0.0.1 --directory "$S/feed" || err "feed agent failed"
  ok=0
  for i in {1..20}; do tmo 5 /usr/bin/curl -sf -o /dev/null "http://127.0.0.1:$FEED_PORT/appcast.xml" && { ok=1; break; }; sleep 1; done
  (( ok )) || err "feed server did not answer"

  note "opt-in"
  /usr/bin/defaults write "$BUNDLE_ID" "$OPT_IN_KEY" -bool YES
  # Settings "Confirm before quitting" off: otherwise the "Quit Batty?" alert
  # (QuitConfirmation) blocks Sparkle's terminate request with nobody to
  # answer it. The run records this as a finding, not a failure.
  /usr/bin/defaults write "$BUNDLE_ID" co.sstools.Batty.confirmQuit -bool NO

  note "broker"
  tmo 90 /bin/zsh "$S/tools/vm-guest-broker.sh" "$APP" "$R/broker-diagnostics.log" </dev/null
  print -r -- "broker bootstrap rc=$?"

  note "BattyHost agent"
  {
    src=( "$APP"/Contents/Library/LaunchAgents/*.host.plist(N) )
    (( ${#src} )) || err "no embedded host plist"
    label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$src[1]")
    services=$(/usr/bin/plutil -extract MachServices xml1 -o - "$src[1]" | /usr/bin/sed -n '/<dict>/,/<\/dict>/p')
    write_agent "$label" "$AGENT_DIR/$label.plist" \
      "<key>MachServices</key>$services<key>ProcessType</key><string>Interactive</string><key>AbandonProcessGroup</key><true/>" \
      "$APP/Contents/Resources/bin/BattyHost" || err "BattyHost agent bootstrap failed"
    /bin/cat "$AGENT_DIR/$label.plist"
    tmo 20 /bin/launchctl print "gui/$uid/$label"
  } > "$R/host-agent.log" 2>&1 || err "BattyHost agent (see host-agent.log)"
  exit 0
  ;;

launch)
  mode="${1:?mode}"
  off=$(stream_size)
  tmo 30 /usr/bin/open --env "BATTY_BETA_SPARKLE_AUTO=$mode" -a "$APP" || err "open A failed"
  if ! line=$(wait_log $off 60 "sparkle-auto: (armed mode=|start failed|ignored:)"); then
    [[ -n "$(app_pid)" ]] || {
      tmo 60 /usr/bin/log show --last 5m --predicate 'subsystem == "com.apple.syspolicy"' > "$R/logs/syspolicy.log" 2>&1
      err "A did not launch: Gatekeeper?"
    }
    err "no sparkle-auto: armed line within 60s"
  fi
  [[ "$line" == *"armed mode=$mode"* ]] || err "sparkle-auto: ${line##*sparkle-auto: }"
  wait_ping 60 || err "batty ping failed after launch"
  print -r -- "launched pid=$(app_pid) mode=$mode"
  ;;

populate)
  exec >> "$R/populate.log" 2>&1
  print -r -- '#!/bin/zsh
print $$ > ~/sparkle/pids/$1
print SPARKLE-MARK-$1
exec /bin/zsh -il' > "$S/bin/mark"
  print -r -- '#!/bin/zsh
print $$ > ~/sparkle/pids/counter
n=0
while :; do (( n++ )); print $n >> ~/sparkle/counter.txt; print $n; sleep 1; done' > "$S/bin/counter"
  /bin/chmod +x "$S/bin/mark" "$S/bin/counter"
  /usr/bin/python3 -c '
import struct, sys, zlib
w = h = 64
raw = b"".join(b"\x00" + bytes([40, 90, 160]) * w for _ in range(h))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
' "$S/bg.png"
  c() { note "batty $*"; local out; out=$(tmo 30 "$CLI" "$@") || err "batty $1 $2 failed: $out"; print -r -- "$out"; REPLY="$out"; }
  c project create --name SparkleTest --path "$S/project" --symbol hammer --background-file "$S/bg.png" --opacity 30 --terminal-opacity 70 --json
  c project open SparkleTest --json; p1=$(print -r -- "$REPLY" | json_field paneID)
  c pane split --pane "$p1" -c "$S/bin/mark p1b" --json
  c tab new --pane "$p1" -c "$S/bin/counter" --json
  c new "$S/s2" --json; p2=$(print -r -- "$REPLY" | json_field paneID)
  c pane split --vertical --pane "$p2" -c "$S/bin/mark s2b" --json
  c tab new --pane "$p2" -c "$S/bin/mark s2c" --json
  c tab new --pane "$p2" -c "$S/bin/mark s2d" --json
  c new "$S/s3" --json; p3=$(print -r -- "$REPLY" | json_field paneID)
  c tab new --pane "$p3" --json
  deadline=$(( SECONDS + 90 ))
  while :; do
    n=$(/usr/bin/tail -1 "$S/counter.txt" 2>/dev/null)
    [[ -s $S/pids/p1b && -s $S/pids/s2b && -s $S/pids/s2c && -s $S/pids/s2d && -s $S/pids/counter && ${n:-0} -ge 3 ]] && break
    (( SECONDS < deadline )) || err "populate: shells did not start (see populate.log)"
    sleep 1
  done
  print -r -- "populated"
  ;;

snapshot)
  name="${1:?name}"; d="$R/$name"; /bin/mkdir -p "$d"
  layout="$HOME/Library/Application Support/Batty Beta/terminal-layout.json"
  # The app writes the layout on a timer: wait until it lists every Tab the
  # app reports, so the snapshot is never a half-written baseline.
  deadline=$(( SECONDS + 60 ))
  while :; do
    tmo 20 "$CLI" list --json > "$d/topology.json" 2>&1
    want=$(/usr/bin/python3 -c '
import json, sys
def tabs(n):
    if isinstance(n, dict): return (len(n["tabs"]) if isinstance(n.get("tabs"), list) else 0) + sum(tabs(v) for k, v in n.items() if k != "tabs")
    if isinstance(n, list): return sum(tabs(v) for v in n)
    return 0
try: print(tabs(json.load(open(sys.argv[1]))), tabs(json.load(open(sys.argv[2]))))
except Exception: print("0 -1")
' "$d/topology.json" "$layout")
    [[ "${want% *}" == "${want#* }" && "${want% *}" != 0 ]] && break
    (( SECONDS < deadline )) || { print -r -- "layout tabs/topology tabs: $want" > "$d/layout-wait.txt"; break; }
    sleep 2
  done
  /bin/cp "$layout" "$d/terminal-layout.json" 2>/dev/null
  /bin/ps -A -o pid=,ppid=,pgid=,stat=,tty=,lstart=,comm= > "$d/ps.txt"
  : > "$d/host.txt"
  for p in $(/usr/bin/pgrep -x BattyHost); do
    print -r -- "pid=$p" >> "$d/host.txt"
    tmo 20 /usr/bin/codesign -dvvv "$p" >> "$d/host.txt" 2>&1 || print -r -- "codesign of running pid $p failed rc=$?" >> "$d/host.txt"
  done
  tmo 20 /usr/bin/codesign -dvvv "$APP/Contents/Resources/bin/BattyHost" > "$d/codesign-disk.txt" 2>&1
  print -r -- "pid=$(app_pid)
version=$(app_version)" > "$d/app.txt"
  /bin/cp -R "$S/pids" "$d/" 2>/dev/null
  /bin/cp "$S/counter.txt" "$d/counter.txt" 2>/dev/null
  tmo 20 /usr/sbin/screencapture -x "$d/screenshot-$name.png" 2>/dev/null
  print -r -- "snapshot $name written"
  ;;

trigger)
  mode="${1:?mode}"
  base_pid=$(/usr/bin/sed -n 's/^pid=//p' "$R/baseline/app.txt")
  [[ -n "$base_pid" ]] || err "no baseline app pid"
  off=$(stream_size)
  now > "$R/trigger-time.txt"
  /bin/cp "$S/appcast-real.xml" "$S/feed/appcast.xml" || err "swap in the real appcast"
  tmo 20 /usr/bin/osascript -l JavaScript -e "ObjC.import(\"Foundation\"); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(\"$CHECK_NOTIFICATION\", \$(), \$(), true)" \
    || err "posting the check notification failed"
  if [[ "$mode" == relaunch ]]; then
    line=$(wait_log $off 180 "sparkle-auto: (installing and relaunching|error:|check ignored)") || err "timeout: sparkle-auto: installing and relaunching"
    [[ "$line" == *"installing and relaunching"* ]] || err "sparkle: ${line##*sparkle-auto: }"
    wait_pid_exit "$base_pid" 120 || { stuck "$base_pid"; err "timeout: A (pid $base_pid) did not exit"; }
  else
    line=$(wait_log $off 180 "sparkle-auto: (staged for install on quit|error:|check ignored)") || err "timeout: sparkle-auto: staged for install on quit"
    [[ "$line" == *"staged for install on quit"* ]] || err "sparkle: ${line##*sparkle-auto: }"
    tmo 30 /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" || err "quit A"
    wait_pid_exit "$base_pid" 120 || err "timeout: A (pid $base_pid) did not exit after quit"
    deadline=$(( SECONDS + 180 ))
    want=$(/usr/bin/sed -n 's/.*sparkle:version="\([0-9]*\)".*/\1/p' "$S/appcast-real.xml" | /usr/bin/head -1)
    until [[ "$(app_version)" == "$want" ]] && ! /usr/bin/pgrep -x Autoupdate >/dev/null; do
      (( SECONDS < deadline )) || err "timeout: install on quit (version $(app_version), want $want)"
      sleep 2
    done
    off=$(stream_size)
    tmo 30 /usr/bin/open -a "$APP" || err "reopen failed"
  fi
  deadline=$(( SECONDS + 120 ))
  until new_pid=$(app_pid) && [[ -n "$new_pid" && "$new_pid" != "$base_pid" ]]; do
    (( SECONDS < deadline )) || err "timeout: no new Batty Beta pid"
    sleep 1
  done
  wait_log $off 90 "restore:" >/dev/null || print -r -- "WARNING: no restore: line within 90s"
  if ! wait_ping 60; then
    print -r -- "WARNING: broker-restarted"
    print -r -- "broker-restarted" >> "$R/warnings.txt"
    tmo 20 /bin/launchctl kickstart -k "gui/$uid/co.sstools.Batty.beta.broker" </dev/null
    wait_ping 60 || err "batty ping failed after the update (broker restarted once)"
  fi
  /bin/zsh "$0" snapshot after || err "snapshot after failed"
  at=$(/usr/bin/tail -1 "$R/after/counter.txt" 2>/dev/null)
  deadline=$(( SECONDS + 30 ))
  while (( $(/usr/bin/tail -1 "$S/counter.txt" 2>/dev/null || print 0) < ${at:-0} + 3 )) && (( SECONDS < deadline )); do sleep 1; done
  /bin/cp "$S/counter.txt" "$R/after/counter-final.txt"
  /bin/cp "$S/counter.txt" "$R/counter-final.txt"
  print -r -- "trigger $mode done: new pid $new_pid"
  ;;

collect)
  L="$R/logs"
  /usr/bin/grep -E 'restore:' "$STREAM" > "$L/restore.log" 2>/dev/null
  /usr/bin/grep -E 'sparkle-auto:' "$STREAM" > "$L/sparkle-auto.log" 2>/dev/null
  /usr/bin/grep -E 'BattyHost' "$STREAM" > "$L/battyhost.log" 2>/dev/null
  /usr/bin/grep -E 'org.sparkle-project|Autoupdate' "$STREAM" > "$L/sparkle.log" 2>/dev/null
  tmo 120 /usr/bin/log show --last 60m --info --style compact \
    --predicate 'eventMessage CONTAINS "-67065" OR eventMessage CONTAINS "terminal helper connection" OR eventMessage CONTAINS "helper unavailable"' \
    > "$L/security.log" 2>&1
  /bin/cp ~/Library/Logs/DiagnosticReports/Batty*.ips "$R/crashes/" 2>/dev/null
  tmo 20 /usr/bin/defaults read "$BUNDLE_ID" > "$R/defaults.txt" 2>&1
  print -r -- "collected"
  ;;

*)
  print -r -- "GUEST-ERROR: unknown step '$step'"; exit 2 ;;
esac
exit 0
