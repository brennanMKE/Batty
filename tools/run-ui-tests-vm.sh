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
#      takes effect on the *next* xcodebuild invocation, #0280), then run
#      three bounded guest steps, ad hoc signed (the guest has no
#      certificates): `xcodebuild -workspace Batty.xcworkspace -scheme
#      "Batty UI Tests" build-for-testing`; tools/vm-guest-broker.sh, which
#      starts the built app's embedded broker and a loopback CLI relay
#      (#0419, a fresh guest has never opted in to the broker and the
#      sandboxed UI-test runner cannot run the CLI itself); and
#      `test-without-building` with -only-testing:BattyUITests (or the
#      given specs).
#   5. Stream results back to build/ui-tests/<run-id>/: xcodebuild-build.log
#      and xcodebuild.log (the test step), UITests.xcresult,
#      broker-bootstrap.out and broker-diagnostics.log, app-warnings.log,
#      sandbox-denials.log, crashes/, and the host-side tart-run.log
#      (written directly to this results dir, created before boot, so it
#      survives cleanup). Results are also pulled after the build and
#      bootstrap steps, so a later hang or timeout still returns them.
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
#   BATTY_UI_KEEP_RECORDINGS=1 tools/run-ui-tests-vm.sh ...   # keep recordings of passing tests (#0448)
#
# Run it in the foreground of a shell: a dropped session costs a clone,
# not a work session.

set -euo pipefail

# ONE shared golden for every project on this host, resolved -- never a literal.
# A hardcoded image name is exactly how seven 68 GB goldens (477 GB) appeared on
# cameron; see Homelab protocols/tart-golden/PROTOCOL.md. `require` asserts the
# Xcode floor and fails in one second, not twenty minutes into a build.
command -v tart-golden >/dev/null 2>&1 || {
  echo "tart-golden not found on PATH (MacRoot Root/bin) -- see Homelab protocols/tart-golden/PROTOCOL.md" >&2
  exit 1
}
GOLDEN="$(tart-golden require --xcode 27.0)"
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

# XCTest records every UI test but stores the recording with the scheme's
# default attachment lifetime, deleteOnSuccess, so a passing test leaves none
# (#0448). BATTY_UI_KEEP_RECORDINGS=1 sets both lifetimes to keepAlways on the
# guest's own copy of the scheme -- the tracked scheme is never touched, and a
# run without the switch is unchanged. Bundles grow to hundreds of MB; see
# pull_results for the matching bound.
KEEP_RECORDINGS=0
if [[ "${BATTY_UI_KEEP_RECORDINGS:-}" == "1" ]]; then
  KEEP_RECORDINGS=1
  log "BATTY_UI_KEEP_RECORDINGS=1: keeping screen recordings for passing tests too"
  tart exec "$CLONE" /bin/zsh -lc "
    f='$GUEST_BATTY/Batty.xcodeproj/xcshareddata/xcschemes/Batty UI Tests.xcscheme'
    /usr/bin/sed -i '' 's|<TestAction\$|<TestAction systemAttachmentLifetime = \"keepAlways\" userAttachmentLifetime = \"keepAlways\"|' \"\$f\"
    [[ \$(/usr/bin/grep -c 'systemAttachmentLifetime = \"keepAlways\"' \"\$f\") == 1 ]]" \
    || { log "Could not enable recording retention in the guest scheme"; exit 1; }
fi

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

# ViewGalleryTests (#0451) is on request only: it skips unless the runner sees
# BATTY_UI_GALLERY=1, which `xcodebuild` forwards from a TEST_RUNNER_ variable.
# Only a filter that names the class turns it on, so a plain run is unaffected.
GALLERY_ENV=""
for spec in "$@"; do
  [[ "$spec" == *ViewGalleryTests* ]] && GALLERY_ENV="TEST_RUNNER_BATTY_UI_GALLERY=1"
done

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
# on an explicit background PID does not have that problem. run_guest_step
# below goes one step further: it polls the background PID with `kill -0`
# and `sleep 2` rather than `wait`ing on it outright, so a wedged
# `tart exec` can be killed at a host-side bound.
# Build first, start the app's embedded broker (#0419), then test without
# rebuilding: the broker's absolute path only exists once the app is built, and
# a fresh guest has never opted in through Settings, so without this step every
# XPC verb fails (see tools/vm-guest-broker.sh). -derivedDataPath pins where the
# built app lands. A failed bootstrap is logged to broker-diagnostics.log and
# does not stop the run.
GUEST_DD="$GUEST_ROOT/DerivedData"
GUEST_APP="$GUEST_DD/Build/Products/Debug/Batty Beta.app"
# Guest-side hard bound: SIGALRM survives exec, so nothing run through this can
# outlive its limit even if the guest command blocks on a prompt.
GUEST_TMO='/usr/bin/perl -e "alarm shift; exec @ARGV" --'

# Wait up to $1 seconds for the background job in TEST_PID, killing it at the
# bound. Sets step_rc (124 when the host-side bound hit).
wait_bounded() {
  local secs="$1" label="$2" waited=0
  while kill -0 "$TEST_PID" 2>/dev/null && (( waited < secs )); do
    sleep 2
    (( waited += 2 ))
  done
  if kill -0 "$TEST_PID" 2>/dev/null; then
    log "$label exceeded ${secs}s on the host side — killing it"
    bounded_kill "$TEST_PID" "$label"
    step_rc=124
  else
    step_rc=0
    wait "$TEST_PID" || step_rc=$?
  fi
  unset TEST_PID
}

# Run one guest command string, backgrounded and bounded on the host too (the
# `tart exec` itself can wedge). Sets step_rc.
run_guest_step() {
  local secs="$1" cmd="$2"
  tart exec "$CLONE" /bin/zsh -lc "$cmd" &
  TEST_PID=$!
  wait_bounded "$secs" "guest step"
}

# Best-effort, bounded pull of whatever the guest has so far, so a later hang
# or timeout still returns the earlier steps' output.
pull_results() {
  local tarball="$EXPORT/pull.tar"
  local guest_secs=90 host_secs=120
  (( KEEP_RECORDINGS )) && { guest_secs=600; host_secs=660 }
  tart exec "$CLONE" /bin/zsh -lc "$GUEST_TMO $guest_secs tar -C $GUEST_RESULTS -cf - ." > "$tarball" 2>/dev/null &
  TEST_PID=$!
  wait_bounded $host_secs "result pull"
  tar -x -C "$RESULTS_DIR" -f "$tarball" 2>/dev/null || log "Failed to pull some results back from the guest"
  rm -f "$tarball"
}

set +e
# SwiftPM's repository cache occasionally fails on a fresh clone (exit 74); one
# bounded retry. A persistent failure still surfaces in the build step below.
run_guest_step 700 "
  cd $GUEST_BATTY
  for attempt in 1 2; do
    $GUEST_TMO 300 xcodebuild -workspace Batty.xcworkspace -scheme 'Batty UI Tests' -resolvePackageDependencies && break
    print -r -- \"package resolution attempt \$attempt failed\"
  done
  exit 0"
run_guest_step 1500 "
  cd $GUEST_BATTY
  $GUEST_TMO 1200 xcodebuild -workspace Batty.xcworkspace -scheme 'Batty UI Tests' \
    -destination 'platform=macOS' -derivedDataPath $GUEST_DD \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    build-for-testing 2>&1 | tee $GUEST_RESULTS/xcodebuild-build.log
  exit \${pipestatus[1]}"
build_rc=$step_rc
pull_results
if (( build_rc != 0 )); then
  test_rc=$build_rc
else
  run_guest_step 150 "
    ls -la '$GUEST_APP' > $GUEST_RESULTS/broker-bootstrap.out 2>&1
    $GUEST_TMO 90 /bin/zsh $GUEST_BATTY/tools/vm-guest-broker.sh '$GUEST_APP' $GUEST_RESULTS/broker-diagnostics.log < /dev/null >> $GUEST_RESULTS/broker-bootstrap.out 2>&1
    print -r -- \"bootstrap script rc=\$?\" >> $GUEST_RESULTS/broker-bootstrap.out"
  pull_results
  run_guest_step 2700 "
    cd $GUEST_BATTY
    /usr/bin/env $GALLERY_ENV $GUEST_TMO 2400 xcodebuild -workspace Batty.xcworkspace -scheme 'Batty UI Tests' \
      -destination 'platform=macOS' -derivedDataPath $GUEST_DD \
      -resultBundlePath $GUEST_RESULTS/UITests.xcresult \
      ${TEST_FILTER_ARGS[*]} \
      CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
      test-without-building 2>&1 | tee $GUEST_RESULTS/xcodebuild.log
    exit \${pipestatus[1]}"
  test_rc=$step_rc
fi
set -e

# --- The app's own warnings and crashes --------------------------------------
# SwiftUI/AppKit state-flow problems ("Modifying state during view update",
# AttributeGraph cycles) surface only in the log, and a crash only in a
# crash report. Keep both with the results.

run_guest_step 300 "
  $GUEST_TMO 120 /usr/bin/log show --last 30m --info --style compact \
    --predicate 'process CONTAINS \"Batty\" AND (messageType == error OR messageType == fault OR category == \"AppXPCCoordinator\" OR category == \"BrokerAgentController\" OR subsystem BEGINSWITH \"com.apple.SwiftUI\" OR subsystem == \"com.apple.AttributeGraph\")' \
    > $GUEST_RESULTS/app-warnings.log 2>&1
  $GUEST_TMO 120 /usr/bin/log show --last 30m --info --style compact \
    --predicate 'eventMessage CONTAINS \"deny(\" OR subsystem == \"com.apple.sandbox.reporting\"' \
    > $GUEST_RESULTS/sandbox-denials.log 2>&1
  mkdir -p $GUEST_RESULTS/crashes
  cp ~/Library/Logs/DiagnosticReports/Batty*.ips $GUEST_RESULTS/crashes/ 2>/dev/null || true"

# --- The app's carried-over guest state (#0444) -------------------------------
# Everything the app persists in the guest survives from one launch to the
# next for the whole run, so a launch-time failure cascade has to be read
# against the state it inherited. Captured as it stands at the end of the run,
# plus the app's own info-level log (the filtered log above keeps only
# errors/faults). Small by design: defaults, the saved-state and Application
# Support listings, the name cache, and the app subsystem's log.

run_guest_step 200 "
  mkdir -p $GUEST_RESULTS/guest-state
  $GUEST_TMO 30 /usr/bin/defaults read co.sstools.Batty.beta > $GUEST_RESULTS/guest-state/defaults.txt 2>&1
  ls -laR ~/Library/Saved\\ Application\\ State/co.sstools.Batty.beta.savedState > $GUEST_RESULTS/guest-state/saved-state-listing.txt 2>&1
  ls -laR ~/Library/Application\\ Support/Batty\\ Beta > $GUEST_RESULTS/guest-state/app-support-listing.txt 2>&1
  cp ~/Library/Application\\ Support/Batty\\ Beta/session-name-cache.json $GUEST_RESULTS/guest-state/ 2>/dev/null
  $GUEST_TMO 120 /usr/bin/log show --last 30m --info --debug --style compact \
    --predicate 'subsystem BEGINSWITH \"co.sstools.Batty\"' \
    > $GUEST_RESULTS/guest-state/app-info.log 2>&1"

# AppKit/SwiftUI's own decisions (state restoration, scene creation) log under
# system subsystems, not the app's. That log is hundreds of thousands of lines,
# so it is opt-in: BATTY_UI_FULL_APP_LOG=1 tools/run-ui-tests-vm.sh ... (#0444
# found its root cause there).
if [[ "${BATTY_UI_FULL_APP_LOG:-}" == "1" ]]; then
  run_guest_step 400 "
    $GUEST_TMO 300 /usr/bin/log show --last 30m --info --debug --style compact \
      --predicate 'process == \"Batty Beta\"' \
      > $GUEST_RESULTS/guest-state/app-all-processes.log 2>&1"
fi

# --- Results back -------------------------------------------------------------
# $RESULTS_DIR already exists (created before boot, see "Clone and boot"
# above) and already holds tart-run.log; this adds the guest-side results
# alongside it.

log "Pulling results into $RESULTS_DIR"
# Best-effort and bounded (see pull_results): the test's own result is already
# known ($test_rc, above) and must be what this script exits with regardless of
# whether the result bundle made it back.
pull_results

print ""
if (( test_rc == 0 )); then
  log "RESULT: TEST SUCCEEDED"
else
  log "RESULT: TEST FAILED (exit $test_rc)"
fi
summary_log="$RESULTS_DIR/xcodebuild.log"
[[ -f "$summary_log" ]] || summary_log="$RESULTS_DIR/xcodebuild-build.log"
grep -E "Test case .* (passed|failed|skipped)|Executed|TEST (SUCCEEDED|FAILED)|TEST (BUILD|EXECUTE) (SUCCEEDED|FAILED)|error:" "$summary_log" | tail -20 || true
crashes=( "$RESULTS_DIR"/crashes/*.ips(N) )
(( ${#crashes} )) && log "CRASH REPORTS: ${#crashes} in $RESULTS_DIR/crashes/"
warnings="$(grep -c -i -E "modifying state during view update|multiple times per frame|attributegraph: cycle|publishing changes from within view updates|geometry action is cycling|constraint|exception" "$RESULTS_DIR/app-warnings.log" 2>/dev/null || true)"
log "SwiftUI/AppKit warnings in the app's log: ${warnings:-0} (see app-warnings.log)"

print ""
log "Result bundle: $RESULTS_DIR/UITests.xcresult"
log "Full log:      $summary_log"

exit "$test_rc"
