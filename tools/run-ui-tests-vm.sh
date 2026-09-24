#!/bin/zsh
# run-ui-tests-vm.sh — run Batty's UI tests inside a disposable Tart VM.
#
# UI tests never run on this host: XCUITest's testmanagerd bootstraps
# XCTAutomationSupport into every running GUI app it enumerates through
# Accessibility, not just the app under test. On 2026-09-12 a UI test run
# from an unrelated project did exactly that to the user's running Prod
# Batty and crashed it (EXC_BAD_ACCESS in
# -[XCTAutomationSession initWithAccessibilityFramework:dataSource:]),
# killing 38 live Terminal Sessions (#0409). A Batty UI test run on this
# host is the same hazard aimed at the user's own terminals. The
# BattyUITests target refuses to build outside a VM (see the "Refuse to
# build on a host Mac" phase in Batty.xcodeproj), and this script is the
# only supported way to run it. See docs/ui-testing-vm.md.
#
# Per run:
#   1. Preflight: Tart and the golden image present, stale
#      batty-uitest-<run-id> clones swept (before waiting for a slot below --
#      an orphaned clone from a SIGKILLed previous run keeps its `tart run`
#      alive and would otherwise look like "another VM running" forever), no
#      other VM running (Apple allows two macOS guests, and every project on
#      this host shares them and the RAM -- this waits up to
#      WAIT_FOR_SLOT_SECS, default 1200s/20min, polling every
#      WAIT_POLL_SECS, default 30s; WAIT_FOR_SLOT_SECS=0 fails immediately
#      instead), 20 GiB of disk free, enough memory (requested through the
#      memory-signal protocol if the host is short).
#   2. Export a clean snapshot of BOTH repos this build needs, as tar files
#      (never extracted on the host -- this repo commits a real symlink,
#      .cursor/skills/quest, and Tart's virtio-fs share cannot pass a
#      symlink through a read-only mount; extraction happens locally on
#      the guest's own disk instead): `git archive HEAD` of Batty itself,
#      never the live working copy, plus `git archive HEAD` of
#      ../SlidingTabs (BattyKit/Package.swift depends on it via
#      `.package(path: "../../SlidingTabs")`, a separate repo outside this
#      one). The two are laid out as siblings once extracted in the guest,
#      matching the relative path SlidingTabs needs.
#   3. Clone the golden image, boot headless with the export mounted
#      read-only.
#   4. In the guest: extract both tar files locally, write
#      Configuration/Active.xcconfig to select Beta (it's gitignored, so
#      git archive never carries it, and the scheme's own pre-action only
#      takes effect on the *next* xcodebuild invocation, #0280), and run
#      `xcodebuild -workspace Batty.xcworkspace -scheme "Batty UI Tests"
#      -only-testing:BattyUITests test`, ad hoc signed (the guest has no
#      certificates).
#   5. Stream results back to build/ui-tests/<run-id>/: xcodebuild.log,
#      UITests.xcresult, the app's own warnings/crash reports from the
#      guest, and the host-side tart-run.log (written directly to this
#      results dir, created before boot, so it survives cleanup).
#   6. Cleanup on EXIT (trap): bounded-kill the local `tart exec` test
#      process if still running, `tart stop --timeout 30` the clone (tart's
#      own bound on graceful-then-forceful termination), bounded-kill the
#      backgrounded `tart run` process -- Ctrl-C can't be relied on to stop
#      it (a background job starts with SIGINT ignored), so it is killed
#      explicitly -- release any memory-signal request, `tart delete` the
#      clone, and remove the export. Also runs on
#      INT/TERM/HUP -- zsh does not fire an EXIT trap on an uncaught fatal
#      signal, so each of those is trapped explicitly and turned into
#      `exit <code>`, which does run it. A second INT/TERM/HUP arriving
#      while cleanup itself is running is ignored, not left at the default
#      disposition, so it can't kill the script mid-`tart stop` and skip
#      `tart delete`.
#
# Usage:
#   tools/run-ui-tests-vm.sh                              # all UI tests
#   tools/run-ui-tests-vm.sh BattyUITests/TabRenameTests   # one class
#   tools/run-ui-tests-vm.sh BattyUITests/TabRenameTests/testRenameActiveTabUpdatesChipTitle
#
# Run it in the foreground of a shell: a dropped session costs a clone,
# not a work session.

set -euo pipefail

GOLDEN="batty-uitest-golden"
PREFIX="batty-uitest"
REPO="${0:A:h:h}"
SLIDINGTABS_REPO="${REPO:h}/SlidingTabs"
GUEST_USER="admin"
GUEST_ROOT="/Users/$GUEST_USER/src"
GUEST_BATTY="$GUEST_ROOT/Batty"
GUEST_RESULTS="/Users/$GUEST_USER/results"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
CLONE="$PREFIX-$RUN_ID"
EXPORT="$(mktemp -d "${TMPDIR:-/tmp}/$PREFIX-export.XXXXXX")"
RESULTS_DIR="$REPO/build/ui-tests/$RUN_ID"
BOOT_TIMEOUT_SECS=120
# Keep in sync with the golden image's memory (`tart set --memory`).
GUEST_MEM_MB=12288

log()  { print -r -- "==> $*"; }
fail() { print -r -- "!! $*" >&2; exit 1; }

# Kill $1, waiting up to ~30s (polling kill -0) for it to actually go away
# before escalating to KILL -- never an unbounded `wait`, so cleanup can't
# hang indefinitely on a wedged child.
bounded_kill() {
  local pid="$1" label="${2:-process}" waited=0
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
  kill "$pid" >/dev/null 2>&1 || true
  while kill -0 "$pid" 2>/dev/null && (( waited < 30 )); do
    sleep 1
    # Pre-increment: post-increment's result is the OLD value, so the first
    # pass evaluates to 0 -- a standalone `(( expr ))` command's exit status
    # is 1 when expr is 0, which set -e treats as a command failure and
    # aborts the whole EXIT-trap cleanup mid-kill, skipping tart stop/KILL/
    # delete for any target that outlives 1s. Verified with a scratch copy
    # of bounded_kill+cleanup: the post-increment form stops after logging
    # "cleanup rc=..." and never reaches the kill, leaking both children;
    # `(( ++waited ))` runs cleanup to completion every time.
    (( ++waited ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    log "$label pid $pid still alive after ${waited}s, sending KILL"
    kill -KILL "$pid" >/dev/null 2>&1 || true
  fi
  wait "$pid" 2>/dev/null || true
}

# zsh does not run an EXIT trap when the process is killed by an uncaught
# INT/TERM/HUP -- the shell terminates directly on the default signal
# disposition (exit code 130/143/129) without ever reaching the `exit`
# builtin that EXIT traps hook. Trapping each signal explicitly and calling
# `exit <code>` from inside it converts that into a real `exit`, which does
# run the EXIT trap -- so cleanup fires either way. cleanup() is written to
# be idempotent (every step is guarded and best-effort).
cleanup() {
  local rc=$?
  # Cleanup is best-effort: no command failure below may cut it short, so
  # disable errexit for the rest of this function rather than relying on
  # every individual command being guarded correctly. A trap that doesn't
  # call `exit` itself still exits the process with the status that was
  # active when the trap fired ($rc, captured above), not whatever a later
  # command inside the trap sets $? to -- verified with a scratch script.
  set +e
  trap - EXIT
  # Ignore, don't restore-to-default: a second Ctrl-C arriving while
  # `tart stop` (below) is still working must not abort cleanup before
  # `tart delete` runs, which `trap -` would allow (default disposition
  # kills the process immediately).
  trap '' INT TERM HUP
  log "Cleaning up (exit $rc)"
  # Give the Tart slot back before the slower teardown, so a waiting session
  # starts sooner. Not fatal if missed: leases are pid-stamped and the next
  # acquire prunes ours.
  if [[ -n "${LEASE_ID:-}" ]]; then
    tart-lease release --id "$LEASE_ID" 2>/dev/null || true
    LEASE_ID=""
  fi
  # The backgrounded `tart run` (below) is a background job, so the shell
  # set its SIGINT disposition to ignored when launching it. Ctrl-C can't be
  # relied on to stop it either way -- tart handles signals itself, and a
  # background job starts with SIGINT ignored regardless of that -- so it is
  # killed explicitly, before `tart delete`, or it keeps the VM's
  # virtualization session alive underneath the delete.
  if [[ -n "${TEST_PID:-}" ]]; then
    bounded_kill "$TEST_PID" "test-exec"
    unset TEST_PID
  fi
  if [[ -n "${CLONE:-}" ]]; then
    # --timeout 30 is tart's own bound on graceful-then-forceful shutdown;
    # confirmed present via `tart stop --help` (default: 30).
    tart stop "$CLONE" --timeout 30 >/dev/null 2>&1 || true
  fi
  if [[ -n "${TART_RUN_PID:-}" ]]; then
    bounded_kill "$TART_RUN_PID" "tart-run"
    unset TART_RUN_PID
  fi
  if [[ -n "${MEMORY_REQUEST_ID:-}" && -n "${MEMORY_COORD_DIR:-}" ]]; then
    mkdir -p "$MEMORY_COORD_DIR/release" 2>/dev/null || true
    print -r -- "{\"id\": \"$MEMORY_REQUEST_ID\", \"released\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
      > "$MEMORY_COORD_DIR/release/$MEMORY_REQUEST_ID.json" 2>/dev/null || true
    unset MEMORY_REQUEST_ID MEMORY_COORD_DIR
  fi
  if [[ -n "${CLONE:-}" ]]; then
    tart delete "$CLONE" >/dev/null 2>&1 || true
  fi
  [[ -n "${EXPORT:-}" ]] && rm -rf "$EXPORT"
}
LEASE_ID=""
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Preflight ---------------------------------------------------------------

command -v tart >/dev/null || fail "Tart is not installed (brew install cirruslabs/cli/tart)"
tart list | awk '{ print $2 }' | grep -qx "$GOLDEN" || fail "Golden image '$GOLDEN' not found (see docs/ui-testing-vm.md — tart clone changeover-uitest-golden $GOLDEN)"

[[ -d "$SLIDINGTABS_REPO/.git" ]] || fail "SlidingTabs repo not found at $SLIDINGTABS_REPO — BattyKit/Package.swift depends on it via a local path"

# A SIGKILL skips the trap, so sweep clones left by earlier runs. This runs
# before the wait-for-a-slot preflight below: an orphaned clone from a
# SIGKILLed previous run keeps its `tart run` alive (Tart shows it as
# "running"), so sweeping it here first is what lets that slot free up --
# swept after the wait instead, the wait would see the orphan as "running"
# and wait for a slot that only sweeping itself can open. Only this script's
# own run-id shape is matched — never a bare "batty-uitest-" prefix match,
# which would also match the golden image itself (the 2026-09-13 Changeover
# incident this pattern guards against, see
# ~/Developer/Homelab/cameron/tart-ui-test-vm.md). A clone whose <pid>
# suffix is still alive belongs to a concurrent run of this same script (the
# "no other VM running" preflight below only checks Tart's own state, which
# a run still booting or between clone-and-boot may not show yet) -- skip it
# rather than deleting a run out from under it. This is a best-effort
# PID-liveness check, not a lock: a dead script's PID can in principle be
# reused by an unrelated process before this sweep runs.
for old in $(tart list | awk -v p="^$PREFIX-[0-9]{8}-[0-9]{6}-[0-9]+\$" '$2 ~ p { print $2 }'); do
  [[ "$old" == "$GOLDEN" || "$old" == "$CLONE" ]] && continue
  old_pid="${old##*-}"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    log "Skipping $old — its run-id pid ($old_pid) is still alive (a concurrent run, not stale)"
    continue
  fi
  log "Sweeping stale clone: $old"
  tart stop "$old" >/dev/null 2>&1 || true
  tart delete "$old" >/dev/null 2>&1 || true
done

# Apple allows two macOS guests at once, and every project on this host
# shares that and the RAM. The host is busy enough in practice (several
# projects cycling VMs concurrently) that a slot can take a while to open
# up, so wait for one rather than failing on the first refusal.
# WAIT_FOR_SLOT_SECS=0 restores the old immediate-fail behavior.
WAIT_FOR_SLOT_SECS="${WAIT_FOR_SLOT_SECS:-1200}"
WAIT_POLL_SECS="${WAIT_POLL_SECS:-30}"
(( WAIT_POLL_SECS >= 1 )) || WAIT_POLL_SECS=1
running=$(tart list | awk '$NF == "running" { print $2 }')
if [[ -n "$running" ]]; then
  if (( WAIT_FOR_SLOT_SECS == 0 )); then
    fail "Another VM is running ($running). Wait for it to finish."
  fi
  log "Another VM is running ($running). Waiting up to ${WAIT_FOR_SLOT_SECS}s for a free slot (polling every ${WAIT_POLL_SECS}s; override with WAIT_FOR_SLOT_SECS/WAIT_POLL_SECS, or WAIT_FOR_SLOT_SECS=0 to fail immediately instead)."
  wait_start=$SECONDS
  wait_deadline=$(( SECONDS + WAIT_FOR_SLOT_SECS ))
  while [[ -n "$running" ]]; do
    (( SECONDS < wait_deadline )) || fail "Timed out after ${WAIT_FOR_SLOT_SECS}s waiting for another VM to finish ($running still running)."
    sleep "$WAIT_POLL_SECS"
    running=$(tart list | awk '$NF == "running" { print $2 }')
  done
  log "Slot free after $(( SECONDS - wait_start )) s of waiting"
fi

free_kb=$(df -k / | awk 'NR == 2 { print $4 }')
(( free_kb / 1024 / 1024 >= 20 )) || fail "Only $((free_kb / 1024 / 1024)) GiB free on / — need at least 20 GiB"

# --- Memory (memory-signal protocol, as in Changeover's/Curator's run-ui-tests-vm.sh) ---

memory_available_bytes() {
  local page free inactive purgeable
  page=$(sysctl -n vm.pagesize)
  free=$(vm_stat | awk '/Pages free/ {gsub("\\.","",$3); print $3}')
  inactive=$(vm_stat | awk '/Pages inactive/ {gsub("\\.","",$3); print $3}')
  purgeable=$(vm_stat | awk '/Pages purgeable/ {gsub("\\.","",$3); print $3}')
  print -r -- $(( (free + inactive + purgeable) * page ))
}

memory_observer_live() {
  local dir hb now mtime
  dir="${MEMORY_COORDINATION_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/memory-coordination}"
  hb="$dir/heartbeat"
  [[ -f "$hb" ]] || return 1
  now=$(date +%s)
  mtime=$(stat -f %m "$hb" 2>/dev/null) || return 1
  (( now - mtime <= 15 ))
}

memory_request_and_wait() {
  local need_bytes=$1 dir id deadline
  dir="${MEMORY_COORDINATION_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/memory-coordination}"
  memory_observer_live || return 4
  id="run-ui-tests-vm-batty-$$-$(date +%s)"
  MEMORY_REQUEST_ID="$id"
  MEMORY_COORD_DIR="$dir"
  mkdir -p "$dir/requests" "$dir/ready" "$dir/failed" "$dir/release"
  print -r -- "{\"id\": \"$id\", \"resource\": \"memory\", \"bytes\": $need_bytes, \"requester\": \"run-ui-tests-vm\", \"reason\": \"Batty UI-test VM needs guest RAM plus build headroom\", \"pid\": $$, \"created\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
    > "$dir/requests/$id.json"
  deadline=$(( SECONDS + 120 ))
  while (( SECONDS < deadline )); do
    [[ -f "$dir/ready/$id.json" ]] && return 0
    [[ -f "$dir/failed/$id.json" ]] && return 3
    sleep 2
  done
  return 4
}

need_bytes=$(( (GUEST_MEM_MB + 4096) * 1024 * 1024 ))
avail_bytes=$(memory_available_bytes)
if (( avail_bytes < need_bytes )); then
  log "Host memory short ($(( avail_bytes / 1073741824 )) GiB of $(( need_bytes / 1073741824 )) GiB) — requesting via the memory-signal protocol"
  set +e; memory_request_and_wait "$need_bytes"; mem_rc=$?; set -e
  (( mem_rc == 0 )) || fail "Memory request not fulfilled (rc=$mem_rc). Free memory (e.g. unload LM Studio models, see ~/Developer/Homelab/cameron/lm-studio-memory.md) and retry."
  avail_bytes=$(memory_available_bytes)
  (( avail_bytes >= need_bytes )) || fail "Observer signaled ready but memory is still short"
fi

# --- Export a clean snapshot of both repos -----------------------------------
#
# Kept as tar files, NOT extracted on the host. Tart's virtio-fs share does
# not pass symlinks through (the same limitation the shared host doc
# documents for copying Xcode.app in): this repo commits a real symlink
# (.cursor/skills/quest), and extracting the export on the host, then
# `cp -R`-ing the resulting tree into the guest over the read-only share,
# failed with "Too many levels of symbolic links". A single regular tar
# file crosses the share fine; extraction happens locally on the guest's
# own disk instead, where a local symlink is unremarkable.

log "Exporting Batty HEAD to $EXPORT/batty.tar"
git -C "$REPO" archive -o "$EXPORT/batty.tar" HEAD
log "Exporting SlidingTabs HEAD to $EXPORT/slidingtabs.tar (BattyKit's local path dependency)"
git -C "$SLIDINGTABS_REPO" archive -o "$EXPORT/slidingtabs.tar" HEAD

# --- Wait for a Tart slot ----------------------------------------------------
# One host, several repos and sessions. `tart-lease` admits at most two guests
# and only grants the second when memory allows. Acquired after the
# memory-signal work so it sees memory the observer just freed.
# See Homelab protocols/tart-lease/PROTOCOL.md

if command -v tart-lease >/dev/null; then
  LEASE_ID=$(tart-lease acquire --label batty --pid $$)
else
  log "WARNING: tart-lease not on PATH — running without admission control"
fi

# --- Clone and boot ----------------------------------------------------------

# Created before booting (not just before "Results back" below) so the
# guest's tart-run log can be written here instead of under $EXPORT, which
# cleanup removes -- a boot-timeout failure needs that log to survive it.
mkdir -p "$RESULTS_DIR"

log "Cloning $GOLDEN → $CLONE"
tart clone "$GOLDEN" "$CLONE"

log "Booting $CLONE (headless, export mounted read-only)"
boot_start=$SECONDS
tart run "$CLONE" --no-graphics --dir=run:"$EXPORT":ro >"$RESULTS_DIR/tart-run.log" 2>&1 &
TART_RUN_PID=$!
boot_deadline=$(( SECONDS + BOOT_TIMEOUT_SECS ))
until tart exec "$CLONE" true >/dev/null 2>&1; do
  (( SECONDS < boot_deadline )) || fail "Guest did not become reachable within ${BOOT_TIMEOUT_SECS}s (see $RESULTS_DIR/tart-run.log)"
  sleep 5
done
log "Guest reachable after $(( SECONDS - boot_start )) s (elapsed since boot start, not script start)"

# --- In the guest ------------------------------------------------------------

log "Confirming the guest is actually virtualized (kern.hv_vmm_present)"
hv=$(tart exec "$CLONE" /usr/sbin/sysctl -n kern.hv_vmm_present)
[[ "$hv" == "1" ]] || fail "Guest reports kern.hv_vmm_present=$hv, expected 1 — refusing to trust the host guard inside this guest"

log "Extracting source into the guest (locally, from the tar files on the read-only share)"
tart exec "$CLONE" /bin/zsh -lc "
  rm -rf $GUEST_ROOT $GUEST_RESULTS
  mkdir -p $GUEST_BATTY $GUEST_ROOT/SlidingTabs $GUEST_RESULTS
  tar -xf '/Volumes/My Shared Files/run/batty.tar' -C $GUEST_BATTY
  tar -xf '/Volumes/My Shared Files/run/slidingtabs.tar' -C $GUEST_ROOT/SlidingTabs
  print -r -- '#include \"Beta.xcconfig\"' > $GUEST_BATTY/Configuration/Active.xcconfig
"

# Build the -only-testing args. Default to the UI target only, so this
# run doesn't re-run BattyKitTests/BattyTests (already covered on the host
# by ./build.sh unit). Positional args replace the default, matching
# today's ./build.sh ui BattyUITests/<Class>[/<test>] convention.
TEST_FILTER_ARGS=()
if (( $# == 0 )); then
  TEST_FILTER_ARGS=(-only-testing:BattyUITests)
else
  for spec in "$@"; do
    TEST_FILTER_ARGS+=(-only-testing:"$spec")
  done
fi

log "Running UI tests in the guest (this runs XCUITest inside the VM only)"
# The "Batty UI Tests" scheme's Test action holds only BattyUITests -- the
# "Batty (Beta)" scheme's own Test action was deliberately narrowed to
# BattyKitTests/BattyTests (#0412), because xcodebuild's test action builds
# every Testable listed in a scheme regardless of -only-testing filters, so
# leaving BattyUITests there made ./build.sh unit try (and fail, at the
# host guard) to build it too.
#
# Run backgrounded and `wait`ed rather than as this script's direct
# foreground command: with the `tart run` background job (above) also
# alive, zsh defers a trapped INT/TERM/HUP until the current foreground
# external command exits on its own -- verified with a scratch script --
# so a plain foreground `tart exec ... test` would make Ctrl-C during the
# ~10-minute test phase wait for it to finish before cleanup ran. `wait`
# on an explicit background PID does not have that problem.
set +e
tart exec "$CLONE" /bin/zsh -lc "
  cd $GUEST_BATTY && xcodebuild -workspace Batty.xcworkspace -scheme 'Batty UI Tests' \
    -destination 'platform=macOS' -resultBundlePath $GUEST_RESULTS/UITests.xcresult \
    ${TEST_FILTER_ARGS[*]} \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    test 2>&1 | tee $GUEST_RESULTS/xcodebuild.log
  exit \${pipestatus[1]}" &
TEST_PID=$!
wait "$TEST_PID"
test_rc=$?
unset TEST_PID
set -e

# --- The app's own warnings and crashes --------------------------------------
# SwiftUI/AppKit state-flow problems ("Modifying state during view update",
# AttributeGraph cycles) surface only in the log, and a crash only in a
# crash report. Keep both with the results.

tart exec "$CLONE" /bin/zsh -lc "
  /usr/bin/log show --last 30m --style compact \
    --predicate 'process CONTAINS \"Batty\" AND (messageType == error OR messageType == fault OR subsystem BEGINSWITH \"com.apple.SwiftUI\" OR subsystem == \"com.apple.AttributeGraph\")' \
    > $GUEST_RESULTS/app-warnings.log 2>&1
  mkdir -p $GUEST_RESULTS/crashes
  cp ~/Library/Logs/DiagnosticReports/Batty*.ips $GUEST_RESULTS/crashes/ 2>/dev/null || true" || true

# --- Results back -------------------------------------------------------------
# $RESULTS_DIR already exists (created before boot, see "Clone and boot"
# above) and already holds tart-run.log; this adds the guest-side results
# alongside it.

log "Pulling results into $RESULTS_DIR"
# Best-effort: under pipefail, a failure on either side of this pipe is a
# standalone command whose nonzero status would otherwise exit the script
# right here (via set -e) with tar's status instead of the test's -- losing
# the pass/fail summary below and reporting the wrong exit code for a test
# run that actually finished. The test's own result is already known
# ($test_rc, above) and must be what this script exits with regardless of
# whether the result bundle made it back.
tart exec "$CLONE" /bin/zsh -lc "tar -C $GUEST_RESULTS -cf - ." | tar -x -C "$RESULTS_DIR" \
  || log "Failed to pull some results back from the guest (see above)"

print ""
if (( test_rc == 0 )); then
  log "RESULT: TEST SUCCEEDED"
else
  log "RESULT: TEST FAILED (exit $test_rc)"
fi
grep -E "Test case .* (passed|failed|skipped)|Executed|TEST (SUCCEEDED|FAILED)" "$RESULTS_DIR/xcodebuild.log" | tail -20 || true
crashes=( "$RESULTS_DIR"/crashes/*.ips(N) )
(( ${#crashes} )) && log "CRASH REPORTS: ${#crashes} in $RESULTS_DIR/crashes/"
warnings="$(grep -c -i -E "modifying state during view update|multiple times per frame|attributegraph: cycle|publishing changes from within view updates|geometry action is cycling|constraint|exception" "$RESULTS_DIR/app-warnings.log" 2>/dev/null || true)"
log "SwiftUI/AppKit warnings in the app's log: ${warnings:-0} (see app-warnings.log)"

print ""
log "Result bundle: $RESULTS_DIR/UITests.xcresult"
log "Full log:      $RESULTS_DIR/xcodebuild.log"

exit "$test_rc"
