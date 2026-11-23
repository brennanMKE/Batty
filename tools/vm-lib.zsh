# vm-lib.zsh — Tart VM lifecycle helpers shared by tools/run-ui-tests-vm.sh
# and tools/run-sparkle-update-vm.sh. Sourced, never run.
#
# The caller defines `log` (one `==> ` line) and owns the globals these
# functions read and set: CLONE, TEST_PID, TART_RUN_PID, step_rc, LEASE_ID,
# MEMORY_REQUEST_ID and MEMORY_COORD_DIR. Functions that can't go on set
# VM_LIB_ERROR and return non-zero; the caller turns that into its own
# CHECK line, so each runner keeps its own messages and exit codes.

VM_LIB_ERROR=""

# Kill $1, waiting up to ~30s (polling kill -0) for it to actually go away
# before escalating to KILL -- never an unbounded `wait`, so cleanup can't
# hang indefinitely on a wedged child.
vm_bounded_kill() {
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

# --- Memory (memory-signal protocol, as in Changeover's/Curator's run-ui-tests-vm.sh) ---

vm_memory_available_bytes() {
  local page free inactive purgeable
  page=$(sysctl -n vm.pagesize)
  free=$(vm_stat | awk '/Pages free/ {gsub("\\.","",$3); print $3}')
  inactive=$(vm_stat | awk '/Pages inactive/ {gsub("\\.","",$3); print $3}')
  purgeable=$(vm_stat | awk '/Pages purgeable/ {gsub("\\.","",$3); print $3}')
  print -r -- $(( (free + inactive + purgeable) * page ))
}

vm_memory_observer_live() {
  local dir hb now mtime
  dir="${MEMORY_COORDINATION_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/memory-coordination}"
  hb="$dir/heartbeat"
  [[ -f "$hb" ]] || return 1
  now=$(date +%s)
  mtime=$(stat -f %m "$hb" 2>/dev/null) || return 1
  (( now - mtime <= 15 ))
}

# vm_memory_request_and_wait <bytes> <id-prefix> <requester> <reason>
vm_memory_request_and_wait() {
  local need_bytes=$1 id_prefix=$2 requester=$3 reason=$4 dir id deadline
  dir="${MEMORY_COORDINATION_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/memory-coordination}"
  vm_memory_observer_live || return 4
  id="$id_prefix-$$-$(date +%s)"
  MEMORY_REQUEST_ID="$id"
  MEMORY_COORD_DIR="$dir"
  mkdir -p "$dir/requests" "$dir/ready" "$dir/failed" "$dir/release"
  print -r -- "{\"id\": \"$id\", \"resource\": \"memory\", \"bytes\": $need_bytes, \"requester\": \"$requester\", \"reason\": \"$reason\", \"pid\": $$, \"created\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
    > "$dir/requests/$id.json"
  deadline=$(( SECONDS + 120 ))
  while (( SECONDS < deadline )); do
    [[ -f "$dir/ready/$id.json" ]] && return 0
    [[ -f "$dir/failed/$id.json" ]] && return 3
    sleep 2
  done
  return 4
}

vm_memory_release() {
  if [[ -n "${MEMORY_REQUEST_ID:-}" && -n "${MEMORY_COORD_DIR:-}" ]]; then
    mkdir -p "$MEMORY_COORD_DIR/release" 2>/dev/null || true
    print -r -- "{\"id\": \"$MEMORY_REQUEST_ID\", \"released\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
      > "$MEMORY_COORD_DIR/release/$MEMORY_REQUEST_ID.json" 2>/dev/null || true
    unset MEMORY_REQUEST_ID MEMORY_COORD_DIR
  fi
}

# vm_sweep_stale_clones <prefix> <golden> <self-clone>
#
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
vm_sweep_stale_clones() {
  local prefix="$1" golden="$2" self_clone="$3" old old_pid
  for old in $(tart list | awk -v p="^$prefix-[0-9]{8}-[0-9]{6}-[0-9]+\$" '$2 ~ p { print $2 }'); do
    [[ "$old" == "$golden" || "$old" == "$self_clone" ]] && continue
    old_pid="${old##*-}"
    if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
      log "Skipping $old — its run-id pid ($old_pid) is still alive (a concurrent run, not stale)"
      continue
    fi
    log "Sweeping stale clone: $old"
    tart stop "$old" >/dev/null 2>&1 || true
    tart delete "$old" >/dev/null 2>&1 || true
  done
  return 0
}

# Apple allows two macOS guests at once, and every project on this host
# shares that and the RAM. The host is busy enough in practice (several
# projects cycling VMs concurrently) that a slot can take a while to open
# up, so wait for one rather than failing on the first refusal.
# WAIT_FOR_SLOT_SECS=0 restores the old immediate-fail behavior.
vm_wait_for_free_slot() {
  WAIT_FOR_SLOT_SECS="${WAIT_FOR_SLOT_SECS:-1200}"
  WAIT_POLL_SECS="${WAIT_POLL_SECS:-30}"
  (( WAIT_POLL_SECS >= 1 )) || WAIT_POLL_SECS=1
  local running wait_start wait_deadline
  running=$(tart list | awk '$NF == "running" { print $2 }')
  if [[ -n "$running" ]]; then
    if (( WAIT_FOR_SLOT_SECS == 0 )); then
      VM_LIB_ERROR="Another VM is running ($running). Wait for it to finish."
      return 1
    fi
    log "Another VM is running ($running). Waiting up to ${WAIT_FOR_SLOT_SECS}s for a free slot (polling every ${WAIT_POLL_SECS}s; override with WAIT_FOR_SLOT_SECS/WAIT_POLL_SECS, or WAIT_FOR_SLOT_SECS=0 to fail immediately instead)."
    wait_start=$SECONDS
    wait_deadline=$(( SECONDS + WAIT_FOR_SLOT_SECS ))
    while [[ -n "$running" ]]; do
      if (( SECONDS >= wait_deadline )); then
        VM_LIB_ERROR="Timed out after ${WAIT_FOR_SLOT_SECS}s waiting for another VM to finish ($running still running)."
        return 1
      fi
      sleep "$WAIT_POLL_SECS"
      running=$(tart list | awk '$NF == "running" { print $2 }')
    done
    log "Slot free after $(( SECONDS - wait_start )) s of waiting"
  fi
  return 0
}

# --- Wait for a Tart slot ----------------------------------------------------
# One host, several repos and sessions. `tart-lease` admits at most two guests
# and only grants the second when memory allows. Acquired after the
# memory-signal work so it sees memory the observer just freed.
# See Homelab protocols/tart-lease/PROTOCOL.md
vm_lease_acquire() {
  local label="$1"
  if command -v tart-lease >/dev/null; then
    LEASE_ID=$(tart-lease acquire --label "$label" --pid $$)
  else
    log "WARNING: tart-lease not on PATH — running without admission control"
  fi
}

# Give the Tart slot back. Not fatal if missed: leases are pid-stamped and the
# next acquire prunes ours.
vm_lease_release() {
  if [[ -n "${LEASE_ID:-}" ]]; then
    tart-lease release --id "$LEASE_ID" 2>/dev/null || true
    LEASE_ID=""
  fi
}

# vm_boot <clone> <share-dir> <tart-run-log> <timeout-secs>
# Boots headless and muted with <share-dir> mounted read-only as "run", waits
# for `tart exec` to answer, and confirms the guest is virtualized. Sets
# TART_RUN_PID.
vm_boot() {
  local clone="$1" share="$2" runlog="$3" timeout="$4" boot_start boot_deadline hv
  log "Booting $clone (headless, muted, export mounted read-only)"
  boot_start=$SECONDS
  # --no-audio: without it Tart routes guest audio to the host output (e.g. the
  # notification sound from `batty notify --sound`). No UI test depends on sound.
  # --no-clipboard: otherwise the host's clipboard is mirrored into the guest,
  # leaking it into the VM and making pasteboard-dependent tests host-dependent.
  tart run "$clone" --no-graphics --no-audio --no-clipboard --dir=run:"$share":ro >"$runlog" 2>&1 &
  TART_RUN_PID=$!
  boot_deadline=$(( SECONDS + timeout ))
  until tart exec "$clone" true >/dev/null 2>&1; do
    if (( SECONDS >= boot_deadline )); then
      VM_LIB_ERROR="Guest did not become reachable within ${timeout}s (see $runlog)"
      return 1
    fi
    sleep 5
  done
  log "Guest reachable after $(( SECONDS - boot_start )) s (elapsed since boot start, not script start)"

  log "Confirming the guest is actually virtualized (kern.hv_vmm_present)"
  hv=$(tart exec "$clone" /usr/sbin/sysctl -n kern.hv_vmm_present) || hv="?"
  if [[ "$hv" != "1" ]]; then
    VM_LIB_ERROR="Guest reports kern.hv_vmm_present=$hv, expected 1 — refusing to trust the host guard inside this guest"
    return 1
  fi
  return 0
}

# Wait up to $1 seconds for the background job in TEST_PID, killing it at the
# bound. Sets step_rc (124 when the host-side bound hit).
vm_wait_bounded() {
  local secs="$1" label="$2" waited=0
  while kill -0 "$TEST_PID" 2>/dev/null && (( waited < secs )); do
    sleep 2
    (( waited += 2 ))
  done
  if kill -0 "$TEST_PID" 2>/dev/null; then
    log "$label exceeded ${secs}s on the host side — killing it"
    vm_bounded_kill "$TEST_PID" "$label"
    step_rc=124
  else
    step_rc=0
    wait "$TEST_PID" || step_rc=$?
  fi
  unset TEST_PID
}

# Run one guest command string, backgrounded and bounded on the host too (the
# `tart exec` itself can wedge). Sets step_rc. An optional third argument is a
# host file that also receives the step's output; with it, the step's stderr
# is merged into stdout (`2>&1`) on the terminal too. $! stays the
# `tart exec` job, so step_rc is still its status.
vm_run_guest_step() {
  local secs="$1" cmd="$2" tee_file="${3:-}"
  if [[ -n "$tee_file" ]]; then
    tart exec "$CLONE" /bin/zsh -lc "$cmd" > >(tee "$tee_file") 2>&1 &
  else
    tart exec "$CLONE" /bin/zsh -lc "$cmd" &
  fi
  TEST_PID=$!
  vm_wait_bounded "$secs" "guest step"
}
