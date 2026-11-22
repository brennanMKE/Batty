#!/bin/zsh
# run-sparkle-update-vm.sh — test that a Sparkle update keeps every Session
# and its running processes, inside a disposable Tart VM (#0715).
#
# Why a VM: the test installs a Beta into /Applications, registers launchd
# agents, disables Gatekeeper and lets Sparkle replace the app. None of that
# may happen on this host (AGENTS.md, "UI test automation"). Why the builds
# happen on the host: the reproduction needs team-signed packages
# (OutgoingCodeSigningEnforcement skips the requirement for an unsigned app,
# so an unsigned build would pass for the wrong reason), and only this host
# holds the Developer ID. The packages are built with the sanctioned
# `./build.sh package --sign` (Manual signing, committed profile, never
# --notarize) and installed only inside the VM.
#
# Per run:
#   1. Resolve --ref and fold each --merge into a throwaway merge commit
#      (git merge-tree / commit-tree; no branch, no working-tree change).
#      Preflight the ref's tree: #0715's build-beta.sh variables, #0714's hook,
#      BattyHost (#0696).
#   2. Generate a throwaway Ed25519 key into a temp folder
#      (tools/sparkle-test-key.swift; never the Keychain).
#   3. Export the commit into build/sparkle-tests/work/{A,B}/Batty with
#      SlidingTabs beside it, and build A then B (build number A+1) with the
#      test feed URL and public key. Check both packages: feed, key, versions,
#      team-signed BattyHost, different BattyHost cdhashes, codesign --verify.
#   4. Make B.dmg, sign it with `sign_update --ed-key-file`, prove the key
#      format, write appcast.xml. A goes to the guest as A.zip.
#   5. Sweep stale clones, wait for a free slot, disk, memory, lease (shared
#      with the UI runner through tools/vm-lib.zsh).
#   6. Per mode (relaunch, then onquit), a fresh clone: tools/vm-guest-sparkle.sh
#      setup, launch, populate, snapshot baseline, trigger, collect; pull the
#      results; tools/sparkle-update-check.py; stop and delete the clone.
#   7. Last line on every path: CHECK SPARKLE: PASSED|FAILED|ERROR [(detail)].
#      Exit 0 passed, 1 a check failed, 2 could not run, 129/130/143 interrupted.
#
# Usage:
#   tools/run-sparkle-update-vm.sh [--ref <commit-ish>] [--merge <ref>]... \
#       [--mode relaunch|onquit|both] [--clean] [--keep-packages] \
#       [--reuse-packages <run-id>] [--dry-run]
#
#   tools/run-sparkle-update-vm.sh --ref issue/0696 --merge main
#
# Results: build/sparkle-tests/<run-id>/ (never the private key).

set -euo pipefail

CHECK_LINE=""
INTERRUPTED=0
finish_check_line() {
  local rc=$1
  if [[ -z "$CHECK_LINE" ]] && (( rc != 0 )); then
    if (( INTERRUPTED )); then
      CHECK_LINE="CHECK SPARKLE: ERROR (interrupted)"
    else
      CHECK_LINE="CHECK SPARKLE: ERROR (aborted, exit $rc)"
      rc=2
    fi
  fi
  if [[ -n "$CHECK_LINE" ]]; then
    print -r -- "$CHECK_LINE"
    [[ -n "${RESULTS_DIR:-}" && -d "${RESULTS_DIR:-/nonexistent}" ]] && print -r -- "$CHECK_LINE" >> "$RESULTS_DIR/summary.txt"
  fi
  return $rc
}
# Until cleanup() takes over below, so a usage error still ends with a CHECK line.
early_exit() {
  local rc=$?
  set +e
  trap - EXIT
  finish_check_line $rc
  exit $?
}
trap early_exit EXIT
trap 'INTERRUPTED=1; exit 129' HUP
trap 'INTERRUPTED=1; exit 130' INT
trap 'INTERRUPTED=1; exit 143' TERM

log()  { print -r -- "==> $*"; [[ -n "${RESULTS_DIR:-}" && -d "${RESULTS_DIR:-/nonexistent}" ]] && print -r -- "==> $*" >> "$RESULTS_DIR/summary.txt"; return 0; }
fail() { print -r -- "!! $*" >&2; CHECK_LINE="CHECK SPARKLE: ERROR ($*)"; exit 2; }

REPO="${0:A:h:h}"
source "$REPO/tools/vm-lib.zsh"

# --- Constants (the #0714 contract lives in tools/vm-guest-sparkle.sh) -----
PREFIX="batty-uitest"
TEAM_ID="XV8BAAVZ6V"
FEED_PORT=47912
FEED_URL="http://127.0.0.1:$FEED_PORT/appcast.xml"
ENCLOSURE_URL="http://127.0.0.1:$FEED_PORT/B.dmg"
GUEST_MEM_MB=12288
BOOT_TIMEOUT_SECS=120
BUILD_HOST_SECS=3600
SLIDINGTABS_REPO="${REPO:h}/SlidingTabs"
WORK="$REPO/build/sparkle-tests/work"
APP_NAME="Batty Beta.app"
GUEST_TOOL="/bin/zsh '/Volumes/My Shared Files/run/tools/vm-guest-sparkle.sh'"

REF="HEAD"; MERGES=(); MODE="both"; CLEAN=0; KEEP=0; REUSE=""; DRY=0
while (( $# )); do
  case "$1" in
    --ref) REF="${2:?--ref needs a value}"; shift 2 ;;
    --merge) MERGES+=("${2:?--merge needs a value}"); shift 2 ;;
    --mode) MODE="${2:?}"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    --keep-packages) KEEP=1; shift ;;
    --reuse-packages) REUSE="${2:?}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
case "$MODE" in
  relaunch|onquit) MODES=("$MODE") ;;
  both) MODES=(relaunch onquit) ;;
  *) fail "--mode must be relaunch, onquit or both" ;;
esac

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RESULTS_DIR="$REPO/build/sparkle-tests/$RUN_ID"
mkdir -p "$RESULTS_DIR/host"
: > "$RESULTS_DIR/summary.txt"
CLONE=""
KEYDIR=""
STAGE=""
SHARE=""
LEASE_ID=""

cleanup() {
  local rc=$?
  set +e
  trap - EXIT
  trap '' INT TERM HUP
  log "Cleaning up (exit $rc)"
  vm_lease_release
  if [[ -n "${TEST_PID:-}" ]]; then vm_bounded_kill "$TEST_PID" "step"; unset TEST_PID; fi
  [[ -n "${CLONE:-}" ]] && tart stop "$CLONE" --timeout 30 >/dev/null 2>&1
  if [[ -n "${TART_RUN_PID:-}" ]]; then vm_bounded_kill "$TART_RUN_PID" "tart-run"; unset TART_RUN_PID; fi
  vm_memory_release
  [[ -n "${CLONE:-}" ]] && tart delete "$CLONE" >/dev/null 2>&1
  [[ -n "${SHARE:-}" ]] && rm -rf "$SHARE"
  [[ -n "${KEYDIR:-}" ]] && rm -rf "$KEYDIR"
  [[ -n "${STAGE:-}" ]] && rm -rf "$STAGE"
  finish_check_line $rc
  exit $?
}
trap cleanup EXIT

# --- 1. Ref, merges, preflight ------------------------------------------------

command -v tart-golden >/dev/null 2>&1 || fail "tart-golden not found"
GOLDEN="$(tart-golden require --xcode 27.0)" || fail "tart-golden require --xcode 27.0 failed"
command -v tart >/dev/null || fail "Tart is not installed"
[[ -d "$SLIDINGTABS_REPO/.git" ]] || fail "SlidingTabs repo not found at $SLIDINGTABS_REPO"

SHA="$(git -C "$REPO" rev-parse --verify "$REF^{commit}")" || fail "cannot resolve --ref $REF"
PARENTS="$SHA"
for m in "${MERGES[@]}"; do
  msha="$(git -C "$REPO" rev-parse --verify "$m^{commit}")" || fail "cannot resolve --merge $m"
  tree="$(git -C "$REPO" merge-tree --write-tree "$SHA" "$msha" 2>/dev/null)" || fail "merge conflict: $m"
  tree="${tree%%$'\n'*}"
  SHA="$(git -C "$REPO" commit-tree "$tree" -p "$SHA" -p "$msha" -m "sparkle-vm throwaway merge")"
  PARENTS+=" + $m@${msha[1,10]}"
done
log "Testing $SHA ($REF${MERGES:+ with ${MERGES[*]}})"

git -C "$REPO" show "${SHA}:scripts/build-beta.sh" | grep -q BATTY_BETA_FEED_URL || fail "ref predates #0715"
git -C "$REPO" grep -q BATTY_BETA_SPARKLE_AUTO "$SHA" -- BattyKit || fail "ref lacks the #0714 hook"
git -C "$REPO" ls-tree -d "$SHA" BattyKit/Sources/BattyHost | grep -q . || fail "ref has no BattyHost (#0696)"
log "Preflight: ref OK (#0715 variables, #0714 hook, BattyHost present)"

free_kb=$(df -k / | awk 'NR == 2 { print $4 }')
(( free_kb / 1024 / 1024 >= 40 )) || fail "Only $((free_kb / 1024 / 1024)) GiB free on / — need at least 40 GiB"

ST_SHA="$(git -C "$SLIDINGTABS_REPO" rev-parse HEAD)"
{
  print "ref=$REF"; print "sha=$SHA"; print "parents=$PARENTS"; print "slidingtabs=$ST_SHA"
  print "feed=$FEED_URL"; print "golden=$GOLDEN"; print "modes=${MODES[*]}"
} > "$RESULTS_DIR/run.txt"

if (( DRY )); then
  for f in tools/run-sparkle-update-vm.sh tools/vm-lib.zsh tools/vm-guest-sparkle.sh tools/run-ui-tests-vm.sh scripts/build-beta.sh scripts/appcast-item.sh; do
    zsh -n "$REPO/$f" || fail "zsh -n $f"
  done
  log "Preflight: zsh -n OK"
  python3 -I "$REPO/tools/sparkle-update-check-selftest.py" >/dev/null || fail "sparkle-update-check selftest"
  python3 -I "$REPO/tools/appcast-item-selftest.py" >/dev/null || fail "appcast-item selftest"
  xcrun swift "$REPO/tools/sparkle-test-key.swift" selftest >/dev/null || fail "sparkle-test-key selftest"
  log "Preflight: three self-tests OK"
  log "Would build A and B from $SHA in $WORK/{A,B}, golden $GOLDEN, modes ${MODES[*]}"
  CHECK_LINE="CHECK SPARKLE: ERROR (dry run: nothing tested)"
  exit 2
fi

# --- 2-4. Packages -------------------------------------------------------------

PKG="$WORK/packages"
if [[ -n "$REUSE" ]]; then
  PKG="$REPO/build/sparkle-tests/$REUSE/packages"
  [[ -f "$PKG/A.zip" && -f "$PKG/B.dmg" && -f "$PKG/appcast.xml" && -f "$PKG/packages.txt" ]] || fail "no packages in run $REUSE (was it run with --keep-packages?)"
  cp "$PKG/appcast.xml" "$PKG/ed25519.pub" "$PKG/packages.txt" "$RESULTS_DIR/host/"
  log "Reusing packages from $REUSE"
else
  (( CLEAN )) && rm -rf "$WORK"
  rm -rf "$PKG"; mkdir -p "$PKG"
  KEYDIR="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-key.XXXXXX")"
  PUB="$(xcrun swift "$REPO/tools/sparkle-test-key.swift" generate "$KEYDIR")" || fail "key generation"
  cp "$KEYDIR/ed25519.pub" "$RESULTS_DIR/host/"

  source "$REPO/scripts/build-number.sh"
  BUILD_A="$(release_build_number)"
  BUILD_B=$(( BUILD_A + 1 ))
  print "build_a=$BUILD_A\nbuild_b=$BUILD_B" >> "$RESULTS_DIR/run.txt"

  for v in A B; do
    tree="$WORK/$v"
    # Keep beta-build/ (DerivedData) for an incremental rebuild; wipe the sources.
    mkdir -p "$tree/Batty" "$tree/SlidingTabs"
    find "$tree/Batty" -mindepth 1 -maxdepth 1 ! -name beta-build -exec rm -rf {} +
    rm -rf "$tree/SlidingTabs"; mkdir -p "$tree/SlidingTabs"
    git -C "$REPO" archive "$SHA" | tar -x -C "$tree/Batty"
    git -C "$SLIDINGTABS_REPO" archive HEAD | tar -x -C "$tree/SlidingTabs"
    num=$BUILD_A; [[ $v == B ]] && num=$BUILD_B
    log "Building $v (build $num) in $tree/Batty -- ./build.sh package --sign (log: host/build-$v.log)"
    ( cd "$tree/Batty" && env BATTY_BETA_FEED_URL="$FEED_URL" BATTY_BETA_ED_PUBLIC_KEY="$PUB" \
        BATTY_BETA_BUILD_NUMBER="$num" ./build.sh package --sign ) > "$RESULTS_DIR/host/build-$v.log" 2>&1 &
    TEST_PID=$!
    vm_wait_bounded $BUILD_HOST_SECS "build $v"
    (( step_rc == 0 )) || fail "build $v failed (rc=$step_rc, see host/build-$v.log)"
  done

  APP_A="$WORK/A/Batty/beta-build/Products/$APP_NAME"
  APP_B="$WORK/B/Batty/beta-build/Products/$APP_NAME"
  pl() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
  hostinfo() { codesign -dvvv "$1/Contents/Resources/bin/BattyHost" 2>&1; }
  {
    for v in A B; do
      app="$WORK/$v/Batty/beta-build/Products/$APP_NAME"
      print "== $v: $app"
      print "CFBundleVersion=$(pl "$app" CFBundleVersion)"
      print "SUFeedURL=$(pl "$app" SUFeedURL)"
      print "SUPublicEDKey=$(pl "$app" SUPublicEDKey)"
      hostinfo "$app" | grep -E '^(Identifier|TeamIdentifier|CDHash|Authority)='
    done
  } > "$RESULTS_DIR/host/packages.txt"
  for app in "$APP_A" "$APP_B"; do
    [[ "$(pl "$app" SUFeedURL)" == "$FEED_URL" ]] || fail "SUFeedURL wrong in $app"
    [[ "$(pl "$app" SUPublicEDKey)" == "$PUB" ]] || fail "SUPublicEDKey wrong in $app"
    [[ "$(hostinfo "$app" | awk -F= '/^TeamIdentifier=/ {print $2}')" == "$TEAM_ID" ]] \
      || fail "BattyHost is not team-signed in $app (an unsigned host would pass for the wrong reason)"
    codesign --verify --deep --strict "$app" || fail "codesign --verify failed for $app"
  done
  [[ "$(pl "$APP_A" CFBundleVersion)" == "$BUILD_A" && "$(pl "$APP_B" CFBundleVersion)" == "$BUILD_B" ]] || fail "package build numbers"
  HA="$(hostinfo "$APP_A" | awk -F= '/^CDHash=/ {print $2}')"
  HB="$(hostinfo "$APP_B" | awk -F= '/^CDHash=/ {print $2}')"
  [[ -n "$HA" && "$HA" != "$HB" ]] || fail "BattyHost cdhashes of A and B are identical"
  log "Packages OK: A=$BUILD_A B=$BUILD_B, BattyHost cdhash A=$HA B=$HB"

  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-b.XXXXXX")"
  ditto "$APP_B" "$STAGE/$APP_NAME"
  hdiutil create -quiet -volname "Batty Beta" -srcfolder "$STAGE" -format UDZO "$PKG/B.dmg" || fail "hdiutil B.dmg"
  rm -rf "$STAGE"; STAGE=""
  SIGN_UPDATE="$WORK/B/Batty/beta-build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
  [[ -x "$SIGN_UPDATE" ]] || fail "sign_update not found at $SIGN_UPDATE"
  sigline="$("$SIGN_UPDATE" --ed-key-file "$KEYDIR/ed25519.key" "$PKG/B.dmg")" || fail "sign_update"
  sig="$(print -r -- "$sigline" | sed -E 's/.*edSignature="([^"]+)".*/\1/')"
  xcrun swift "$REPO/tools/sparkle-test-key.swift" verify --public "$PUB" --signature "$sig" "$PKG/B.dmg" >/dev/null \
    || fail "sparkle key format"
  item="$("$REPO/scripts/appcast-item.sh" --ed-key-file "$KEYDIR/ed25519.key" --enclosure-url "$ENCLOSURE_URL" \
    --sign-update "$SIGN_UPDATE" "$PKG/B.dmg" 2>/dev/null)" || fail "appcast-item.sh"
  {
    print '<?xml version="1.0" encoding="utf-8"?>'
    print '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
    print '  <channel>'
    print '    <title>Batty Beta test feed (#0715)</title>'
    print -r -- "$item"
    print '  </channel>'
    print '</rss>'
  } > "$PKG/appcast.xml"
  ditto -c -k --keepParent "$APP_A" "$PKG/A.zip"
  cp "$PKG/appcast.xml" "$RESULTS_DIR/host/"
  cp "$RESULTS_DIR/host/ed25519.pub" "$RESULTS_DIR/host/packages.txt" "$PKG/"
  rm -rf "$KEYDIR"; KEYDIR=""
fi
B_BUILD="$(sed -n 's/.*sparkle:version="\([0-9]*\)".*/\1/p' "$PKG/appcast.xml" | head -1)"
B_HASH="$(awk -F= '/^== B/ {b=1} b && /^CDHash=/ {print $2; exit}' "$PKG/packages.txt")"
[[ -n "$B_BUILD" && -n "$B_HASH" ]] || fail "cannot read B's build or host cdhash from the packages"

# --- 5. Slot, disk, memory, lease ------------------------------------------------

SHARE="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-share.XXXXXX")"
mkdir -p "$SHARE/tools"
cp "$PKG/A.zip" "$PKG/B.dmg" "$PKG/appcast.xml" "$SHARE/"
cp "$REPO/tools/vm-guest-sparkle.sh" "$REPO/tools/vm-guest-broker.sh" "$REPO/tools/vm-guest-cli-relay.sh" "$SHARE/tools/"

vm_sweep_stale_clones "$PREFIX" "$GOLDEN" ""
vm_wait_for_free_slot || fail "$VM_LIB_ERROR"
free_kb=$(df -k / | awk 'NR == 2 { print $4 }')
(( free_kb / 1024 / 1024 >= 20 )) || fail "Only $((free_kb / 1024 / 1024)) GiB free on / — need at least 20 GiB"
need_bytes=$(( (GUEST_MEM_MB + 4096) * 1024 * 1024 ))
avail_bytes=$(vm_memory_available_bytes)
if (( avail_bytes < need_bytes )); then
  log "Host memory short — requesting via the memory-signal protocol"
  set +e; vm_memory_request_and_wait "$need_bytes" run-sparkle-update-vm-batty run-sparkle-update-vm "Batty Sparkle update VM needs guest RAM"; mem_rc=$?; set -e
  (( mem_rc == 0 )) || fail "Memory request not fulfilled (rc=$mem_rc)"
fi
vm_lease_acquire batty
print -r -- "lease=${LEASE_ID:-none}" > "$RESULTS_DIR/host/tart-lease.txt"

# --- 6. One clone per mode ------------------------------------------------------

MODE_RESULTS=()   # "<mode>|PASSED|FAILED|ERROR|<detail>"
set +e
for m in "${MODES[@]}"; do
  out="$RESULTS_DIR/$m"; mkdir -p "$out/guest"
  CLONE="$PREFIX-$(date +%Y%m%d-%H%M%S)-$$"
  log "[$m] cloning $GOLDEN → $CLONE"
  tart clone "$GOLDEN" "$CLONE" || { MODE_RESULTS+=("$m|ERROR|tart clone failed"); CLONE=""; continue; }
  mstatus=""; detail=""
  if ! vm_boot "$CLONE" "$SHARE" "$out/tart-run.log" "$BOOT_TIMEOUT_SECS"; then
    mstatus=ERROR; detail="$VM_LIB_ERROR"
  else
    pull() {
      tart exec "$CLONE" /bin/zsh -lc "tar -C ~/results -cf - . 2>/dev/null" > "$SHARE/pull.tar" 2>/dev/null &
      TEST_PID=$!; vm_wait_bounded 180 "result pull"
      tar -x -C "$out/guest" -f "$SHARE/pull.tar" 2>/dev/null; rm -f "$SHARE/pull.tar"
    }
    for st in "setup:300" "launch $m:150" "populate:240" "snapshot baseline:120" "trigger $m:900" "collect:240"; do
      cmd="${st%:*}"; secs="${st##*:}"
      log "[$m] guest: $cmd"
      gout="$out/step-${cmd// /-}.out"
      tart exec "$CLONE" /bin/zsh -lc "$GUEST_TOOL $cmd" > "$gout" 2>&1 &
      TEST_PID=$!; vm_wait_bounded "$secs" "$cmd"
      if (( step_rc != 0 )) && [[ "$cmd" != collect ]]; then
        mstatus=ERROR
        detail="$(grep -h '^GUEST-ERROR: ' "$gout" | tail -1 | sed 's/^GUEST-ERROR: //')"
        [[ -n "$detail" ]] || { pull; detail="$(grep -h "^GUEST-ERROR: " "$out"/guest/*.log 2>/dev/null | tail -1 | sed "s/^GUEST-ERROR: //")"; }
        [[ -n "$detail" ]] || detail="$cmd: exit $step_rc"
        (( step_rc == 124 )) && detail="timeout: $cmd"
        log "[$m] $detail"
        tart exec "$CLONE" /bin/zsh -lc "$GUEST_TOOL collect" >/dev/null 2>&1 &
        TEST_PID=$!; vm_wait_bounded 240 "collect"
        pull
        break
      fi
      pull
    done
  fi
  tart stop "$CLONE" --timeout 30 >/dev/null 2>&1
  [[ -n "${TART_RUN_PID:-}" ]] && { vm_bounded_kill "$TART_RUN_PID" "tart-run"; unset TART_RUN_PID; }
  tart delete "$CLONE" >/dev/null 2>&1
  CLONE=""

  if [[ -z "$mstatus" ]]; then
    g="$out/guest"
    python3 -I "$REPO/tools/sparkle-update-check.py" --mode "$m" --baseline "$g/baseline" --after "$g/after" \
      --logs "$g/logs" --crashes "$g/crashes" --expect-build "$B_BUILD" --b-host-cdhash "$B_HASH" \
      --trigger-time "$(cat "$g/trigger-time.txt" 2>/dev/null)" --out "$out" > "$out/checker.out" 2>&1
    crc=$?
    cat "$out/checker.out" | sed "s/^/    [$m] /"
    case $crc in
      0) mstatus=PASSED ;;
      1) mstatus=FAILED
         detail="$(python3 -c 'import json,sys; print(next(c["detail"] for c in json.load(open(sys.argv[1])) if not c["passed"]))' "$out/checks.json")" ;;
      *) mstatus=ERROR; detail="checker: $(tail -1 "$out/checker.out")" ;;
    esac
    [[ -f "$g/warnings.txt" ]] && log "[$m] WARNING: $(tr '\n' ' ' < "$g/warnings.txt")"
  fi
  log "[$m] $mstatus${detail:+ ($detail)}"
  MODE_RESULTS+=("$m|$mstatus|$detail")
done
set -e

(( KEEP )) && [[ -z "$REUSE" ]] && { mkdir -p "$RESULTS_DIR/packages"; cp "$PKG"/{A.zip,B.dmg,appcast.xml,ed25519.pub,packages.txt} "$RESULTS_DIR/packages/"; }

worst=PASSED; parts=()
for r in "${MODE_RESULTS[@]}"; do
  m="${r%%|*}"; rest="${r#*|}"; st="${rest%%|*}"; d="${rest#*|}"
  [[ $st == ERROR ]] && worst=ERROR
  [[ $st == FAILED && $worst == PASSED ]] && worst=FAILED
  [[ $st != PASSED ]] && parts+=("$m: $d")
done
log "Results: $RESULTS_DIR"
case $worst in
  PASSED) CHECK_LINE="CHECK SPARKLE: PASSED (${MODES[*]})"; exit 0 ;;
  FAILED) CHECK_LINE="CHECK SPARKLE: FAILED (${(j:; :)parts})"; exit 1 ;;
  *)      CHECK_LINE="CHECK SPARKLE: ERROR (${(j:; :)parts})"; exit 2 ;;
esac
