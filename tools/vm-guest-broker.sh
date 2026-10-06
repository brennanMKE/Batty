#!/bin/zsh
# vm-guest-broker.sh — runs INSIDE the Tart guest only (called by
# run-ui-tests-vm.sh through `tart exec`). Starts the built app's embedded
# broker as a per-user launchd agent, installs a loopback relay for the
# embedded `batty` CLI, and records what codesign and launchd report, so
# BattyUITests can drive the app through that CLI (#0419).
#
# Why not SMAppService: Batty deliberately registers the broker only from
# Settings (#0270), and SMAppService resolves the agent against the calling
# bundle, so nothing outside the app can opt in through it. A fresh guest has
# never opted in, so no Mach service exists and every connection is
# invalidated. This script stands in for that opt-in by bootstrapping an
# equivalent agent (same Label, same MachServices key, absolute Program path)
# straight into launchd. The shipped app is untouched.
#
# Usage: vm-guest-broker.sh <path/to/Batty Beta.app> <diagnostics-log>

set -u

app="${1:?usage: vm-guest-broker.sh <app> <log>}"
log="${2:?usage: vm-guest-broker.sh <app> <log>}"
uid="$(/usr/bin/id -u)"

note() { print -r -- "== $*" >> "$log"; }
run()  { note "\$ $*"; /usr/bin/perl -e 'alarm 20; exec @ARGV' -- "$@" < /dev/null >> "$log" 2>&1; local rc=$?; note "rc=$rc"; return $rc; }

: > "$log"
[[ "$(/usr/sbin/sysctl -n kern.hv_vmm_present 2>/dev/null)" == "1" ]] || { print -r -- "refusing: not a VM guest" >&2; exit 1; }

src_plist=""
for p in "$app"/Contents/Library/LaunchAgents/*.broker.plist(N); do src_plist="$p"; done
[[ -n "$src_plist" ]] || { note "no embedded broker plist in $app"; exit 1; }

label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$src_plist")"
broker="$app/Contents/Resources/bin/BattyBroker"
cli="$app/Contents/Resources/bin/batty"
agent_plist="$HOME/Library/LaunchAgents/$label.plist"

note "app=$app label=$label uid=$uid"
run /usr/bin/codesign -dvvv "$app"
run /usr/bin/codesign -dvvv "$broker"
run /usr/bin/codesign --verify --deep --strict "$app"
run /bin/launchctl managername

/bin/mkdir -p "$HOME/Library/LaunchAgents"
/bin/cat > "$agent_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>Program</key>
	<string>$broker</string>
	<key>MachServices</key>
	<dict>
		<key>$label</key>
		<true/>
	</dict>
</dict>
</plist>
PLIST
run /usr/bin/plutil -lint "$agent_plist"

/usr/bin/perl -e 'alarm 20; exec @ARGV' -- /bin/launchctl bootout "gui/$uid/$label" </dev/null >/dev/null 2>&1
if ! run /bin/launchctl bootstrap "gui/$uid" "$agent_plist"; then
  note "gui domain bootstrap failed"
  exit 1
fi
run /bin/launchctl print "gui/$uid/$label"
run "$cli" ping

# CLI relay on loopback (see vm-guest-cli-relay.sh): the sandboxed UI-test
# runner cannot run the CLI itself.
relay_label="co.sstools.Batty.beta.uitest-cli-relay"
relay_port=47911
relay_plist="$HOME/Library/LaunchAgents/$relay_label.plist"
relay_script="${0:A:h}/vm-guest-cli-relay.sh"
/bin/cat > "$relay_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$relay_label</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/zsh</string>
		<string>$relay_script</string>
		<string>$cli</string>
	</array>
	<key>inetdCompatibility</key>
	<dict>
		<key>Wait</key>
		<false/>
	</dict>
	<key>Sockets</key>
	<dict>
		<key>Listeners</key>
		<dict>
			<key>SockNodeName</key>
			<string>127.0.0.1</string>
			<key>SockServiceName</key>
			<string>$relay_port</string>
		</dict>
	</dict>
</dict>
</plist>
PLIST
run /usr/bin/plutil -lint "$relay_plist"
/usr/bin/perl -e 'alarm 20; exec @ARGV' -- /bin/launchctl bootout "gui/$uid/$relay_label" </dev/null >/dev/null 2>&1
run /bin/launchctl bootstrap "gui/$uid" "$relay_plist"
note "relay self-test"
print -r -- "ping" | /usr/bin/perl -e 'alarm 30; exec @ARGV' -- /usr/bin/nc 127.0.0.1 "$relay_port" >> "$log" 2>&1
note "relay self-test rc=$?"
exit 0
