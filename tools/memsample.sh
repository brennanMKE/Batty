#!/usr/bin/env bash
#
# memsample.sh — developer-side phys_footprint / graphics-region sampling
# harness for Batty (#0291, child of the #0285 memory umbrella).
#
# Wraps the proven read-only commands from issues/0285/investigation-live.md
# (footprint, vmmap geometry census, the region-count invariants) so a
# before/after measurement takes one or two commands instead of hand-run
# one-liners. See tools/README.md for full usage and the four #0285
# experiment recipes (atlas scaling, occlusion reclaim, teardown, content vs
# frame-driven growth).
#
# Never uses `ps -o rss` for footprint — see the umbrella: RSS under-reported
# by 29x/7x on two real instances because it excludes compressed/swapped
# pages. Always phys_footprint, via `footprint -p -f bytes`.
#
# Review round 1 (#0291) findings baked in here:
#   - The IOSurface owner label is the *creating image name*, not the
#     process name — it is only 'Batty' because libghostty is statically
#     linked into the release executable. The Beta build's Ghostty code
#     lives in a separate `Batty Beta.debug.dylib`, so the owner label is
#     derived from the resolved binary's basename (plus a ".debug.dylib"
#     variant), never hardcoded, and a zero match self-diagnoses by
#     printing the observed owner-label histogram.
#   - The "surfaces shared with WindowServer == layers" check is NOT exact
#     on a healthy process — repeated 25-sample idle checks found it
#     oscillates on a ~1s timescale (one CAMetalLayer briefly holding both
#     a displayed front buffer and a committed-not-yet-retired one). This
#     is reported as a range check (layers <= ws <= 2*layers) with the
#     per-geometry total-vs-ws table that made it diagnosable, not a hard
#     pass/fail on an exact count. See the footnote in
#     issues/0285/investigation-live.md.
#
# Review round 2 (#0291) findings baked in here:
#   - Every sample stamps a SCHEMA_VERSION. `diff` refuses (dies) to compare
#     two samples on different schemas, and every field lookup a diff
#     performs is a hard failure if the key is missing rather than a silent
#     0 — an earlier round diffed a stale KB-schema sample against a fresh
#     byte-schema sample of the SAME idle process and printed a phantom
#     +1.4 GB footprint delta at exit code 0. Silently-defaulted deltas are
#     exactly the false-signal class this harness exists to prevent.
#   - `pgrep -P` exits 1 (not 0) when the target has no children, which
#     under `set -e -o pipefail` used to kill the whole script with no
#     error message — reachable via --pid on any non-Batty process, or any
#     Batty instance with zero live Terminal Sessions (a fresh launch
#     before opening a Tab — exactly the baseline of experiments a and c).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DIR="$SCRIPT_DIR/memsamples"

# Bumped whenever a field is renamed, re-scaled (e.g. the round-1 KB->bytes
# switch), or removed. Samples from before this field existed (the original
# KB-based schema) have no "schema" key at all and are treated the same as
# a mismatch: `diff` refuses to compare across schema versions, silently or
# otherwise.
SCHEMA_VERSION=2

RELEASE_PATTERN='Batty\.app/Contents/MacOS/Batty$'
BETA_PATTERN='Batty Beta\.app/Contents/MacOS/Batty Beta$'

# --- generic helpers ---------------------------------------------------

err() { echo "memsample.sh: error: $*" >&2; }
die() { err "$*"; exit 1; }

# Dies with a clear message instead of bash's raw "unbound variable" when
# an option flag is the last token with no value after it.
require_value() {
  local flag="$1" argc="$2"
  [[ "$argc" -ge 2 ]] || die "$flag requires a value"
}

usage() {
  cat <<'EOF'
Usage: tools/memsample.sh <command> [options]

Commands:
  list                                    List running Batty processes (release + beta), unambiguously labeled.
  pid    --target release|beta            Resolve and print the pid for one target. Errors if not found.
  sample --target release|beta [--pid N] --tag TAG [--dir DIR]
                                           Take one sample: footprint totals, region-class census,
                                           the invariants, thread/stack/session counts.
                                           Writes DIR/TAG.json, DIR/TAG.kv, DIR/TAG.census.txt and
                                           appends a line to DIR/samples.jsonl. Prints a human summary.
  invariants --target release|beta [--pid N]
                                           Print just the invariant checks against a live pid, including
                                           the per-geometry owner/WindowServer diagnostic table.
  diff TAG_A TAG_B [--dir DIR]            Diff two prior samples: footprint deltas AND a geometry-class
                                           census diff (the part that catches what totals hide).

DIR defaults to tools/memsamples/ (created on first use, gitignored).

Examples:
  tools/memsample.sh list
  tools/memsample.sh sample --target release --tag baseline
  tools/memsample.sh invariants --target release
  tools/memsample.sh sample --target release --tag after
  tools/memsample.sh diff baseline after

See tools/README.md for the four #0285 experiment recipes (a)-(d).
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required tool '$1' not found on PATH"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- pid resolution ------------------------------------------------------

# Prints "pid<TAB>target<TAB>full-comm-path" for every match, one per line.
# `ps -Ao pid=,comm=` right-justifies pid= with leading spaces; `read -r p c`
# (default IFS) both splits on the first run of whitespace and trims it,
# which a manual ${line%% *} prefix-strip does not handle correctly.
list_processes() {
  while IFS=$' \t' read -r p c; do
    [[ -n "$p" ]] || continue
    if [[ "$c" =~ $RELEASE_PATTERN ]]; then
      printf '%s\trelease\t%s\n' "$p" "$c"
    elif [[ "$c" =~ $BETA_PATTERN ]]; then
      printf '%s\tbeta\t%s\n' "$p" "$c"
    fi
  done < <(ps -Ao pid=,comm=)
  return 0
}

cmd_list() {
  local rows
  rows="$(list_processes)"
  if [[ -z "$rows" ]]; then
    echo "No Batty (release or beta) process found."
    return 0
  fi
  printf '%-8s %-8s %s\n' "PID" "TARGET" "BINARY"
  echo "$rows" | while IFS=$'\t' read -r p t c; do
    printf '%-8s %-8s %s\n' "$p" "$t" "$c"
  done
}

resolve_pid() {
  local target="$1"
  case "$target" in
    release|beta) ;;
    *) die "unknown --target '$target' (expected 'release' or 'beta')" ;;
  esac
  local match
  match="$(list_processes | awk -F'\t' -v t="$target" '$2==t {print; exit}')"
  if [[ -z "$match" ]]; then
    die "no running '$target' Batty process found (checked full binary path, not just comm=; pgrep-by-name is known unreliable here — see #0285)"
  fi
  echo "$match"
}

# The full comm= path for a pid, regardless of how it was resolved (works
# for --pid overrides too), trimmed of ps's padding.
binary_for_pid() {
  local pid="$1"
  ps -o comm= -p "$pid" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

cmd_pid() {
  local target=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) require_value --target "$#"; target="$2"; shift 2 ;;
      *) die "unknown option '$1'" ;;
    esac
  done
  [[ -n "$target" ]] || die "--target release|beta is required"
  local match
  match="$(resolve_pid "$target")"
  IFS=$'\t' read -r p t c <<<"$match"
  echo "$p"
  echo "target=$t binary=$c" >&2
}

# --- sampling --------------------------------------------------------------

# Reads footprint -p -f bytes text on stdin, prints "<dirty-bytes> <regions>"
# for one category, or nothing if not found. Every value in -f bytes output
# is "<integer> B", so no unit conversion is needed — this is the whole
# reason -f bytes replaced the human-readable (rounded-to-3-figures) table.
#
# Matches by anchoring `cat` to the trailing field of the (whitespace-
# trimmed) line, not by index()-style substring search anywhere in it: a
# substring match would (currently harmlessly, but fragile against a future
# category name) match "IOSurface" inside some other longer category text
# containing it, emitting two lines into what the caller treats as a scalar
# and silently corrupting both the JSON and the $(( )) arithmetic.
extract_category_bytes() {
  local cat="$1" catlen=${#1}
  awk -v cat="$cat" -v catlen="$catlen" '
    {
      line = $0
      sub(/[ \t]+$/, "", line)
      if (length(line) >= catlen && substr(line, length(line) - catlen + 1) == cat) {
        pre = substr(line, 1, length(line) - catlen)
        n = split(pre, a, " ")
        # dirty(2 tokens: num,"B") + clean(2) + reclaimable(2) + regions(1) = 7
        if (n >= 7) { print a[1], a[n] }
      }
    }
  '
}

# Populates SURFACE_ROWS ("owner<TAB>ws<TAB>geometry", one per IOSurface),
# BATTY_IOSURFACES / BATTY_WINDOWSERVER (counted against the binary's own
# owner-label candidates, not a hardcoded 'Batty'), OWNER_HISTOGRAM (every
# owner label actually observed, for self-diagnosis), and OWNER_GEO_TABLE
# (total vs WindowServer-shared count per geometry class, target-owner only).
compute_target_owner_stats() {
  local vm="$1" binary="$2"
  local base="${binary##*/}"
  TARGET_OWNER_PRIMARY="$base"
  TARGET_OWNER_DYLIB="${base}.debug.dylib"

  # SurfaceID detail lines look like:
  #   IOSurface ... SurfaceID: 0x11a  820x962 (BGRA) 3136K  'Batty'
  #   IOSurface ... SurfaceID: 0x227  820x962 (BGRA) 3136K  'Batty', shared with WindowServer[607]
  # The quoted string is the *creating image name* (verified: Electron ->
  # 'Electron Framework', most AppKit apps -> 'RenderBox', Finder -> 'CA
  # Whippet Drawable'), not the process name — 'Batty' only because
  # libghostty is statically linked into Batty's own executable.
  SURFACE_ROWS="$(printf '%s\n' "$vm" | awk -v q="'" '
    /SurfaceID:/ {
      owner = ""; geo = ""
      pat = q "[^" q "]*" q
      if (match($0, pat)) owner = substr($0, RSTART + 1, RLENGTH - 2)
      ws = ($0 ~ /WindowServer/) ? 1 : 0
      if (match($0, /[0-9]+x[0-9]+ \([A-Z0-9]+\) [0-9.]+[KMG]/)) geo = substr($0, RSTART, RLENGTH)
      printf "%s\t%s\t%s\n", owner, ws, geo
    }
  ')"

  BATTY_IOSURFACES="$(printf '%s\n' "$SURFACE_ROWS" | awk -F'\t' -v c1="$TARGET_OWNER_PRIMARY" -v c2="$TARGET_OWNER_DYLIB" '
    $1==c1 || $1==c2 { n++ } END { print n+0 }
  ')"
  BATTY_WINDOWSERVER="$(printf '%s\n' "$SURFACE_ROWS" | awk -F'\t' -v c1="$TARGET_OWNER_PRIMARY" -v c2="$TARGET_OWNER_DYLIB" '
    ($1==c1 || $1==c2) && $2=="1" { n++ } END { print n+0 }
  ')"
  # Guard against an empty SURFACE_ROWS (process has zero live IOSurfaces):
  # `printf '%s\n' ""` still emits one blank line, which sort/uniq -c would
  # otherwise count as a bogus "1 <empty owner>" row and mask the intended
  # "(no IOSurface SurfaceID lines found at all)" message.
  if [[ -n "$SURFACE_ROWS" ]]; then
    OWNER_HISTOGRAM="$(printf '%s\n' "$SURFACE_ROWS" | awk -F'\t' '{print $1}' | sort | uniq -c | sort -rn)"
  else
    OWNER_HISTOGRAM=""
  fi
  OWNER_GEO_TABLE="$(printf '%s\n' "$SURFACE_ROWS" | awk -F'\t' -v c1="$TARGET_OWNER_PRIMARY" -v c2="$TARGET_OWNER_DYLIB" '
    ($1==c1 || $1==c2) {
      total[$3]++
      if ($2=="1") ws[$3]++
    }
    END { for (g in total) printf "%d\t%d\t%s\n", total[g], ws[g]+0, g }
  ' | sort -t "$(printf '\t')" -k3)"
}

# Populates globals from a single footprint -p -f bytes + vmmap pass
# against $1 (pid). Byte-precise: -f bytes avoids the human-readable
# table's 3-4 significant-figure rounding (which made a ~1 MB rounding
# artifact look like a real footprint change in earlier testing).
sample_pid() {
  local pid="$1"
  local fp_out vm_out binary

  fp_out="$(footprint -p "$pid" -f bytes 2>&1)" || die "footprint -p $pid failed:
$fp_out
(footprint may need to run from an interactive Terminal session with the right privileges)"

  vm_out="$(vmmap "$pid" 2>&1)" || die "vmmap $pid failed:
$vm_out
(vmmap can require the target run as the same user, or sudo for other users' processes)"

  binary="$(binary_for_pid "$pid")"
  SAMPLE_BINARY="$binary"

  FP_TOTAL_BYTES="$(printf '%s\n' "$fp_out" | awk '/^ *phys_footprint:/{print $2; exit}')"
  FP_PEAK_BYTES="$(printf '%s\n' "$fp_out" | awk '/^ *phys_footprint_peak:/{print $2; exit}')"
  FP_TOTAL_BYTES="${FP_TOTAL_BYTES:-0}"
  FP_PEAK_BYTES="${FP_PEAK_BYTES:-0}"

  local cat_line
  cat_line="$(printf '%s\n' "$fp_out" | extract_category_bytes "IOAccelerator (graphics)")"
  IOACCEL_BYTES="$(echo "$cat_line" | awk '{print $1+0}')"
  IOACCEL_REGIONS="$(echo "$cat_line" | awk '{print $2+0}')"

  cat_line="$(printf '%s\n' "$fp_out" | extract_category_bytes "IOSurface")"
  IOSURFACE_BYTES="$(echo "$cat_line" | awk '{print $1+0}')"
  IOSURFACE_REGIONS="$(echo "$cat_line" | awk '{print $2+0}')"

  cat_line="$(printf '%s\n' "$fp_out" | extract_category_bytes "Owned physical footprint (unmapped) (graphics)")"
  UNMAPPED_GFX_BYTES="$(echo "$cat_line" | awk '{print $1+0}')"
  UNMAPPED_GFX_REGIONS="$(echo "$cat_line" | awk '{print $2+0}')"

  # "stack" is footprint's own category (dirty size + region count of every
  # Stack/STACK GUARD/Stack (reserved)/Stack Guard region together) — read
  # directly from footprint's table instead of re-deriving via a vmmap
  # regex, which previously over-counted by exactly 4 because vmmap's
  # trailing per-category *summary* table also has lines starting with
  # "Stack"/"STACK GUARD"/"Stack Guard" and a naive anchored grep matched
  # those too.
  cat_line="$(printf '%s\n' "$fp_out" | extract_category_bytes "stack")"
  STACK_REGIONS="$(echo "$cat_line" | awk '{print $2+0}')"

  # geometry-class census across ALL owners (not just the target binary) —
  # this is the general "what does the whole layer census look like" view
  # used by `diff`'s class-level comparison, matching the recipe in
  # issues/0285/investigation-live.md. [KMG] covers a display large enough
  # to produce a gigabyte-sized drawable class, not just K/M.
  CENSUS="$(printf '%s\n' "$vm_out" | grep -oE "[0-9]+x[0-9]+ \([A-Z0-9]+\) [0-9.]+[KMG]  '[^']*'" | sort | uniq -c | sort -rn || true)"

  compute_target_owner_stats "$vm_out" "$binary"

  ATLAS_1040K="$(printf '%s\n' "$vm_out" | grep -cE "^IOAccelerator \(graphics\).*\[ *1040K" || true)"

  # Thread count is a proxy, not a native thread-count syscall result: it's
  # the count of named "Stack ... thread N" detail lines from vmmap, which
  # issues/0285/investigation-live.md (H4) established is 1:1 with live
  # threads (confirmed distinct from STACK_REGIONS above, which counts
  # Stack + STACK GUARD + misc regions, roughly 2x the thread count).
  THREADS="$(printf '%s\n' "$vm_out" | grep -c "^Stack .*thread" || true)"

  # pgrep exits 1 (not 0) when the target has no children at all — under
  # `set -e -o pipefail` that killed the whole script with no error message
  # for any --pid target with zero children, or any Batty instance with
  # zero live Terminal Sessions (a fresh launch before opening a Tab).
  TERMINAL_SESSIONS="$({ pgrep -P "$pid" 2>/dev/null || true; } | wc -l | tr -d ' ')"
}

print_invariants() {
  local layers=0
  local layers_defined=0
  if [[ "$BATTY_IOSURFACES" =~ ^[0-9]+$ ]] && [[ "$BATTY_IOSURFACES" -gt 0 ]] && [[ $((BATTY_IOSURFACES % 3)) -eq 0 ]]; then
    layers=$((BATTY_IOSURFACES / 3))
    layers_defined=1
  fi

  echo "Owner label used for this binary: '$TARGET_OWNER_PRIMARY' (also checked '$TARGET_OWNER_DYLIB')"
  echo ""
  echo "Invariants (issues/0285/investigation-live.md):"

  if [[ "$BATTY_IOSURFACES" -gt 0 && $((BATTY_IOSURFACES % 3)) -eq 0 ]]; then
    printf '  [PASS] IOSurfaces owned by this binary = layers x 3 : %d IOSurfaces / 3 = %d layers exactly\n' \
      "$BATTY_IOSURFACES" "$layers"
  elif [[ "$BATTY_IOSURFACES" -gt 0 ]]; then
    printf '  [FAIL] IOSurfaces owned by this binary = layers x 3 : %d IOSurfaces is NOT a multiple of 3 -- deviation, report this\n' \
      "$BATTY_IOSURFACES"
  else
    printf '  [FAIL] IOSurfaces owned by this binary = layers x 3 : 0 IOSurfaces matched owner candidates ('"'"'%s'"'"', '"'"'%s'"'"')\n' \
      "$TARGET_OWNER_PRIMARY" "$TARGET_OWNER_DYLIB"
    echo "         Observed owner labels in this process (count, quoted label) -- pick the real one from here:"
    if [[ -n "$OWNER_HISTOGRAM" ]]; then
      echo "$OWNER_HISTOGRAM" | sed 's/^/           /'
    else
      echo "           (no IOSurface SurfaceID lines found at all)"
    fi
  fi

  if [[ "$layers_defined" -eq 1 ]]; then
    local lo=$layers hi=$((layers * 2))
    if [[ "$BATTY_WINDOWSERVER" -ge "$lo" && "$BATTY_WINDOWSERVER" -le "$hi" ]]; then
      printf '  [ OK ] WindowServer-shared in [layers, 2x layers]   : %d shared, layers=%d (range %d-%d)\n' \
        "$BATTY_WINDOWSERVER" "$layers" "$lo" "$hi"
    else
      printf '  [FAIL] WindowServer-shared in [layers, 2x layers]   : %d shared, layers=%d (range %d-%d) -- deviation, report this\n' \
        "$BATTY_WINDOWSERVER" "$layers" "$lo" "$hi"
    fi
    echo "         (NOT an exact layers x 1 check: a 25-sample idle check found this oscillates on a ~1s"
    echo "          timescale — one CAMetalLayer can briefly hold both a displayed front buffer and a"
    echo "          committed-not-yet-retired one. Range, not equality, is the real invariant.)"
    if [[ -n "$OWNER_GEO_TABLE" ]]; then
      echo "         Per-geometry total vs WindowServer-shared (this is what makes a deviation diagnosable):"
      printf '           %8s %8s   %s\n' "total" "ws" "geometry"
      echo "$OWNER_GEO_TABLE" | awk -F'\t' '{printf "           %8s %8s   %s\n", $1, $2, $3}'
    fi

    if [[ "$ATLAS_1040K" -eq "$BATTY_IOSURFACES" ]]; then
      printf '  [PASS] 1040K atlas count = IOSurface count          : %d == %d\n' \
        "$ATLAS_1040K" "$BATTY_IOSURFACES"
    else
      printf '  [FAIL] 1040K atlas count = IOSurface count          : %d != %d -- deviation, report this\n' \
        "$ATLAS_1040K" "$BATTY_IOSURFACES"
    fi
  else
    echo "  [SKIP] WindowServer-shared check                   : layers undefined (invariant 1 failed above)"
    echo "  [SKIP] 1040K atlas count check                     : layers undefined (invariant 1 failed above)"
  fi
}

cmd_invariants() {
  local target="" pid_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) require_value --target "$#"; target="$2"; shift 2 ;;
      --pid) require_value --pid "$#"; pid_override="$2"; shift 2 ;;
      *) die "unknown option '$1'" ;;
    esac
  done

  local pid label
  if [[ -n "$pid_override" ]]; then
    pid="$pid_override"; label="pid $pid (target unspecified, use --target for an unambiguous label)"
  else
    [[ -n "$target" ]] || die "--target release|beta or --pid N is required"
    local match; match="$(resolve_pid "$target")"
    IFS=$'\t' read -r pid t c <<<"$match"
    label="$t ($c), pid $pid"
  fi

  echo "Target: $label"
  sample_pid "$pid"
  print_invariants
}

cmd_sample() {
  local target="" pid_override="" tag="" dir="$DEFAULT_DIR"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) require_value --target "$#"; target="$2"; shift 2 ;;
      --pid) require_value --pid "$#"; pid_override="$2"; shift 2 ;;
      --tag) require_value --tag "$#"; tag="$2"; shift 2 ;;
      --dir) require_value --dir "$#"; dir="$2"; shift 2 ;;
      *) die "unknown option '$1'" ;;
    esac
  done
  [[ -n "$tag" ]] || die "--tag NAME is required (used as the sample's filename stem)"
  [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || die "--tag '$tag' must match ^[A-Za-z0-9._-]+\$ (it becomes a filename and a bare JSON string value — an unquoted '\"' or a path separator like '/' will write invalid JSON or a stray file path)"

  local pid target_label
  if [[ -n "$pid_override" ]]; then
    pid="$pid_override"
    target_label="${target:-unspecified}"
  else
    [[ -n "$target" ]] || die "--target release|beta or --pid N is required"
    local match; match="$(resolve_pid "$target")"
    IFS=$'\t' read -r pid target_label _ <<<"$match"
  fi

  mkdir -p "$dir"
  sample_pid "$pid"
  local binary="$SAMPLE_BINARY"

  local ts; ts="$(now_iso)"
  local json_file="$dir/$tag.json"
  local kv_file="$dir/$tag.kv"
  local census_file="$dir/$tag.census.txt"
  local jsonl_file="$dir/samples.jsonl"

  printf '%s\n' "$CENSUS" > "$census_file"

  local layers=0
  [[ "$BATTY_IOSURFACES" -gt 0 && $((BATTY_IOSURFACES % 3)) -eq 0 ]] && layers=$((BATTY_IOSURFACES / 3))

  # JSON is hand-built: every value here is a number or a value we control
  # (target label, binary path with no embedded quotes) so this is safe
  # without a JSON library, and keeps the harness dependency-free.
  cat > "$json_file" <<JSONEOF
{
  "schema": $SCHEMA_VERSION,
  "timestamp": "$ts",
  "tag": "$tag",
  "target": "$target_label",
  "pid": $pid,
  "binary": "$binary",
  "owner_label": "$TARGET_OWNER_PRIMARY",
  "phys_footprint_bytes": $FP_TOTAL_BYTES,
  "phys_footprint_peak_bytes": $FP_PEAK_BYTES,
  "iosurface_bytes": $IOSURFACE_BYTES,
  "iosurface_regions": $IOSURFACE_REGIONS,
  "ioaccel_bytes": $IOACCEL_BYTES,
  "ioaccel_regions": $IOACCEL_REGIONS,
  "unmapped_gfx_bytes": $UNMAPPED_GFX_BYTES,
  "unmapped_gfx_regions": $UNMAPPED_GFX_REGIONS,
  "threads": $THREADS,
  "stack_regions": $STACK_REGIONS,
  "terminal_sessions": $TERMINAL_SESSIONS,
  "batty_iosurfaces": $BATTY_IOSURFACES,
  "batty_windowserver_shared": $BATTY_WINDOWSERVER,
  "atlas_1040k_count": $ATLAS_1040K,
  "layers": $layers
}
JSONEOF
  # One line per sample also appended to a running JSONL log, so a whole
  # investigation session accumulates in one comparable, greppable file.
  tr -d '\n' < "$json_file" | sed 's/  */ /g' >> "$jsonl_file"
  echo "" >> "$jsonl_file"

  # Flat key=value form for the diff command to source without a JSON parser.
  cat > "$kv_file" <<KVEOF
schema=$SCHEMA_VERSION
timestamp=$ts
target=$target_label
pid=$pid
binary=$binary
owner_label=$TARGET_OWNER_PRIMARY
phys_footprint_bytes=$FP_TOTAL_BYTES
phys_footprint_peak_bytes=$FP_PEAK_BYTES
iosurface_bytes=$IOSURFACE_BYTES
iosurface_regions=$IOSURFACE_REGIONS
ioaccel_bytes=$IOACCEL_BYTES
ioaccel_regions=$IOACCEL_REGIONS
unmapped_gfx_bytes=$UNMAPPED_GFX_BYTES
unmapped_gfx_regions=$UNMAPPED_GFX_REGIONS
threads=$THREADS
stack_regions=$STACK_REGIONS
terminal_sessions=$TERMINAL_SESSIONS
batty_iosurfaces=$BATTY_IOSURFACES
batty_windowserver_shared=$BATTY_WINDOWSERVER
atlas_1040k_count=$ATLAS_1040K
layers=$layers
KVEOF

  echo "=== sample '$tag' :: $ts ==="
  echo "Target: $target_label   pid: $pid"
  echo "Binary: $binary"
  printf 'phys_footprint      : %6d MB  (peak %d MB)\n' $((FP_TOTAL_BYTES/1048576)) $((FP_PEAK_BYTES/1048576))
  printf 'IOSurface           : %6d MB / %d regions\n' $((IOSURFACE_BYTES/1048576)) "$IOSURFACE_REGIONS"
  printf 'IOAccelerator (gfx) : %6d MB / %d regions\n' $((IOACCEL_BYTES/1048576)) "$IOACCEL_REGIONS"
  printf 'Unmapped (gfx)      : %6d MB / %d regions\n' $((UNMAPPED_GFX_BYTES/1048576)) "$UNMAPPED_GFX_REGIONS"
  printf 'Threads (proxy)     : %6d   Stack regions: %d\n' "$THREADS" "$STACK_REGIONS"
  printf 'Live Terminal Sessions (child procs): %d\n' "$TERMINAL_SESSIONS"
  echo ""
  print_invariants
  echo ""
  echo "Wrote: $json_file"
  echo "       $kv_file"
  echo "       $census_file"
  echo "       (appended) $jsonl_file"
}

# --- diff --------------------------------------------------------------

# Reads one key=value field from a sample's .kv file, or dies loudly if the
# key is absent (never returns an empty string as a silent stand-in for
# "missing"). Used everywhere `diff` reads a sample field: an absent key
# most often means the sample predates that field (a schema mismatch a
# stale samples.jsonl/memsamples/ directory can genuinely contain), and
# treating that as "0" rather than an error is exactly how a round-1 diff
# once reported a phantom +1.4 GB footprint delta between a KB-schema
# sample and a bytes-schema sample of the same idle process.
kv_get_required() {
  local file="$1" key="$2"
  local val
  if ! val="$(awk -F= -v k="$key" '$1==k { print substr($0, length(k)+2); f=1 } END { exit(f ? 0 : 1) }' "$file")"; then
    die "sample '$file' has no '$key' field -- likely a schema mismatch (this sample predates that field); re-take it with the current memsample.sh before diffing"
  fi
  printf '%s' "$val"
}

cmd_diff() {
  local dir="$DEFAULT_DIR"
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) require_value --dir "$#"; dir="$2"; shift 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [[ ${#positional[@]} -eq 2 ]] || die "usage: diff TAG_A TAG_B [--dir DIR]"
  local tag_a="${positional[0]}" tag_b="${positional[1]}"

  local kv_a="$dir/$tag_a.kv" kv_b="$dir/$tag_b.kv"
  local census_a="$dir/$tag_a.census.txt" census_b="$dir/$tag_b.census.txt"
  [[ -f "$kv_a" ]] || die "no sample '$tag_a' in $dir (run: sample --tag $tag_a ...)"
  [[ -f "$kv_b" ]] || die "no sample '$tag_b' in $dir (run: sample --tag $tag_b ...)"

  # Hard schema gate: a sample missing the "schema" key entirely (the
  # original round-1 KB-based format had no such field) or carrying a
  # different schema number cannot be compared field-for-field -- units,
  # field names, or both may differ. This must die, not warn: see the
  # #0291 round-2 finding of a phantom +1.4 GB delta from silently diffing
  # across exactly this kind of mismatch.
  local schema_a schema_b
  schema_a="$(kv_get_required "$kv_a" schema)"
  schema_b="$(kv_get_required "$kv_b" schema)"
  [[ "$schema_a" == "$schema_b" ]] || die "schema mismatch: '$tag_a' is schema $schema_a, '$tag_b' is schema $schema_b -- these samples use different field sets and/or units and cannot be diffed. Re-take both samples with the current memsample.sh."

  echo "=== diff: $tag_a -> $tag_b (schema $schema_a) ==="
  echo "$tag_a: $(kv_get_required "$kv_a" timestamp)  target=$(kv_get_required "$kv_a" target) pid=$(kv_get_required "$kv_a" pid)"
  echo "$tag_b: $(kv_get_required "$kv_b" timestamp)  target=$(kv_get_required "$kv_b" target) pid=$(kv_get_required "$kv_b" pid)"
  if [[ "$(kv_get_required "$kv_a" pid)" != "$(kv_get_required "$kv_b" pid)" ]]; then
    echo "NOTE: different pids -- comparing two different process instances, not the same one over time."
  fi
  if [[ "$(kv_get_required "$kv_a" target)" != "$(kv_get_required "$kv_b" target)" ]]; then
    echo "WARNING: different targets ($(kv_get_required "$kv_a" target) vs $(kv_get_required "$kv_b" target)) -- this diff mixes release and beta and is not meaningful."
  fi
  if [[ "$(kv_get_required "$kv_a" binary)" != "$(kv_get_required "$kv_b" binary)" ]]; then
    echo "WARNING: different binaries under the same target label ($(kv_get_required "$kv_a" binary) vs $(kv_get_required "$kv_b" binary))."
  fi
  echo ""

  local metrics=(phys_footprint_bytes phys_footprint_peak_bytes iosurface_bytes iosurface_regions \
                  ioaccel_bytes ioaccel_regions unmapped_gfx_bytes unmapped_gfx_regions \
                  threads stack_regions terminal_sessions batty_iosurfaces \
                  batty_windowserver_shared atlas_1040k_count layers)
  printf '%-28s %14s %14s %14s\n' "metric" "$tag_a" "$tag_b" "delta"
  for m in "${metrics[@]}"; do
    local va vb
    va="$(kv_get_required "$kv_a" "$m")"
    vb="$(kv_get_required "$kv_b" "$m")"
    local delta=$((vb - va))
    local sign=""
    [[ $delta -gt 0 ]] && sign="+"
    printf '%-28s %14s %14s %14s\n' "$m" "$va" "$vb" "${sign}${delta}"
  done
  echo ""
  echo "Note: batty_windowserver_shared can show +-1 (or more, up to +-layers) between two"
  echo "samples of a completely idle process -- one CAMetalLayer briefly holding both a"
  echo "displayed front buffer and a committed-not-yet-retired one is normal, not a finding."
  echo "See the WindowServer-shared range check in \`invariants\` / tools/README.md."

  echo ""
  echo "--- geometry-class census diff (the methodological lesson: diff classes, not just totals) ---"
  if [[ -f "$census_a" && -f "$census_b" ]]; then
    local tmp_diff; tmp_diff="$(mktemp "${TMPDIR:-/tmp}/memsample_census.XXXXXX")"
    if diff -u "$census_a" "$census_b" > "$tmp_diff" 2>&1; then
      echo "(no geometry-class changes)"
    else
      tail -n +3 "$tmp_diff"
    fi
    rm -f "$tmp_diff"
  else
    echo "(census file missing for one or both samples; nothing to diff)"
  fi
}

# --- dispatch ------------------------------------------------------------

main() {
  require_cmd footprint
  require_cmd vmmap
  require_cmd ps
  require_cmd awk

  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage; exit 1; }
  shift || true

  case "$cmd" in
    list) cmd_list "$@" ;;
    pid) cmd_pid "$@" ;;
    sample) cmd_sample "$@" ;;
    invariants) cmd_invariants "$@" ;;
    diff) cmd_diff "$@" ;;
    -h|--help|help) usage ;;
    *) err "unknown command '$cmd'"; usage; exit 1 ;;
  esac
}

main "$@"
