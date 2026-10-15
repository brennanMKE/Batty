#!/bin/zsh
# make-demos.sh — regenerate the website demo clips end to end (#0505).
#
#   tools/demo/make-demos.sh all                 # record in the VM, export, cut, check
#   tools/demo/make-demos.sh record [NN ...]     # VM only; NN narrows it to those clips
#   tools/demo/make-demos.sh export <run-id>     # pull recordings and cue sheets out of the xcresult
#   tools/demo/make-demos.sh cut <run-id> [NN ...]   # trim, speed up, overlay, encode, posters
#   tools/demo/make-demos.sh check <run-id>      # 9 clips, each 5-15 s, under 8 MB
#   tools/demo/make-demos.sh stage <run-id>      # copy the set into website/demo/ (never deploys)
#
# <run-id> is the id of a tools/run-ui-tests-vm.sh run, or "latest".
#
# Recording happens only in the Tart VM (UI scenes: BattyUITests/DemoSceneTests,
# driven by tools/run-ui-tests-vm.sh in demo mode). Everything else runs on the
# host and only edits files: no UI scripting, no screen recording. The VM
# runner exports `git archive HEAD`, so COMMIT FIRST. Output lands in
# build/demo/<run-id>/ (gitignored). Overlay wording lives in tools/demo/overlays/
# and the page captions in website/demo.html; an overlay text change is a re-cut, not a re-record.
#
# Nothing here deploys the website.

set -euo pipefail

HERE="${0:A:h}"
REPO="${HERE:h:h}"
OUT_ROOT="$REPO/build/demo"
CUT="$HERE/DemoCut/.build/release/democut"
LOW=5 HIGH=15 MAX_BYTES=$(( 8 * 1024 * 1024 ))

log()  { print -r -- "==> $*"; }
fail() { print -r -- "!! $*" >&2; exit 1; }

# clip numbers -> overlay files ("01" -> overlays/01-projects.json)
overlay_files() {
  local nn f
  if (( $# )); then
    for nn in "$@"; do
      f=( "$HERE"/overlays/${nn}-*.json(N) )
      (( ${#f} )) || fail "no overlay file for clip $nn"
      print -r -- "${f[1]}"
    done
  else
    print -rl -- "$HERE"/overlays/*.json
  fi
}

resolve_run() {
  local id="${1:-latest}"
  if [[ "$id" == latest ]]; then id="$(cat "$OUT_ROOT/latest" 2>/dev/null || true)"; fi
  [[ -n "$id" && -d "$OUT_ROOT/$id" ]] || fail "no demo run '$1' under $OUT_ROOT (record or export first)"
  print -r -- "$id"
}

build_cut() {
  log "Building DemoCut"
  swift build -c release --package-path "$HERE/DemoCut" 2>&1 | tail -3
  [[ -x "$CUT" ]] || fail "DemoCut did not build"
}

typeset -A TESTS=(
  01 testClip01Projects 02 testClip02SessionsAndSidebar 03 testClip03SplitsTabsLayouts
  04 testClip04GitStatus 05 testClip05ProcessStatus 06 testClip06BellFeed
  07 testClip07OpenQuicklyAndPalette 08 testClip08Themes 09 testClip09CLI
)

record() {
  local filters=() nn
  if (( $# )); then
    for nn in "$@"; do
      [[ -n "${TESTS[$nn]:-}" ]] || fail "no clip $nn"
      filters+=("BattyUITests/DemoSceneTests/${TESTS[$nn]}")
    done
  else
    filters=("BattyUITests/DemoSceneTests")
  fi
  git -C "$REPO" diff --quiet HEAD -- BattyUITests tools BattyKit Batty || fail "uncommitted changes: the VM runner tests 'git archive HEAD'; commit first"
  local log_file="$(mktemp "${TMPDIR:-/tmp}/make-demos-record.XXXXXX")"
  log "Recording in the Tart VM: ${filters[*]}"
  set +e
  BATTY_UI_DEMO=1 "$REPO/tools/run-ui-tests-vm.sh" "${filters[@]}" 2>&1 | tee "$log_file"
  local rc=${pipestatus[1]}
  set -e
  local bundle="$(sed -n 's/^==> Result bundle: //p' "$log_file" | tail -1)"
  [[ -d "$bundle" ]] || fail "no result bundle came back (runner exit $rc)"
  local run="${bundle:h:t}"
  log "Recorded run $run (runner exit $rc)"
  mkdir -p "$OUT_ROOT/$run"
  print -r -- "$run" > "$OUT_ROOT/latest"
  print -r -- "$run" > "$OUT_ROOT/.last-recorded"
  export_run "$run"
}

export_run() {
  local run="$1" bundle="$REPO/build/ui-tests/$1/UITests.xcresult"
  [[ -d "$bundle" ]] || fail "no $bundle"
  local raw="$OUT_ROOT/$run/raw" stage
  mkdir -p "$raw"
  stage="$(mktemp -d "${TMPDIR:-/tmp}/make-demos-export.XXXXXX")"
  log "Exporting attachments from $bundle"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$stage" > /dev/null
  /usr/bin/python3 -I - "$stage" "$raw" <<'PY'
import json, os, re, shutil, sys
stage, raw = sys.argv[1:3]
manifest = json.load(open(os.path.join(stage, "manifest.json")))
best = {}
for entry in manifest:
    m = re.search(r"testClip(\d\d)", entry["testIdentifier"])
    if not m:
        continue
    nn = m.group(1)
    for att in entry["attachments"]:
        name = att["exportedFileName"]
        human = att.get("suggestedHumanReadableName", "")
        path = os.path.join(stage, name)
        if name.endswith(".mp4"):
            size = os.path.getsize(path)
            if size > best.get((nn, "mp4"), (0, None))[0]:
                best[(nn, "mp4")] = (size, path)
        elif human.startswith("demo.") and ".cues" in human and human.endswith(".json"):
            best[(nn, "cues")] = (1, path)
for (nn, kind), (_, path) in sorted(best.items()):
    dest = os.path.join(raw, f"{nn}.mp4" if kind == "mp4" else f"{nn}.cues.json")
    shutil.copy(path, dest)
    print(f"  {os.path.basename(dest)}")
PY
  rm -rf "$stage"
  print -r -- "$run" > "$OUT_ROOT/latest"
}

cut_clips() {
  local run="$(resolve_run "$1")"; shift
  build_cut
  local raw="$OUT_ROOT/$run/raw" ov nn slug
  for ov in $(overlay_files "$@"); do
    nn="${${ov:t}[1,2]}"; slug="${${ov:t:r}#??-}"
    [[ -f "$raw/$nn.mp4" && -f "$raw/$nn.cues.json" ]] || { print -r -- "  $nn: no recording or cue sheet, skipped"; continue; }
    log "Cutting $nn-$slug"
    "$CUT" cut --raw "$raw/$nn.mp4" --cues "$raw/$nn.cues.json" --overlay "$ov" \
      --out "$OUT_ROOT/$run/$nn-$slug.mp4" --poster "$OUT_ROOT/$run/$nn-$slug.jpg" \
      --align "${DEMO_ALIGN:-start}" ${DEMO_OFFSET:+--offset "$DEMO_OFFSET"} \
      ${DEMO_DEBUG_FRAMES:+--debug-frames} ${DEMO_DEBUG_FRAMES:+"$DEMO_DEBUG_FRAMES"}
  done
  rm -f "$OUT_ROOT/$run"/*.sb-*(N)
}

check() {
  local run="$(resolve_run "$1")" bad=0 f ov nn slug json secs bytes w h audio count=0
  [[ -x "$CUT" ]] || build_cut
  for ov in $(overlay_files); do
    nn="${${ov:t}[1,2]}"; slug="${${ov:t:r}#??-}"
    f="$OUT_ROOT/$run/$nn-$slug.mp4"
    if [[ ! -f "$f" ]]; then print -r -- "FAIL $nn-$slug: missing"; bad=1; continue; fi
    json="$("$CUT" info "$f")"
    secs="$(print -r -- "$json" | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)["seconds"])')"
    bytes="$(print -r -- "$json" | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)["bytes"])')"
    w="$(print -r -- "$json" | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)["width"])')"
    audio="$(print -r -- "$json" | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)["audio"])')"
    local verdict=ok
    (( secs >= LOW && secs <= HIGH )) || verdict="FAIL duration"
    (( bytes <= MAX_BYTES )) || verdict="FAIL size"
    (( audio == 0 )) || verdict="FAIL audio"
    [[ -f "${f:r}.jpg" ]] || verdict="FAIL poster"
    [[ "$verdict" == ok ]] || bad=1
    printf '%-26s %6.1f s  %5.1f MB  %sw  %s\n' "$nn-$slug" "$secs" "$(( bytes / 1048576.0 ))" "$w" "$verdict"
    count=$(( count + 1 ))
  done
  (( count == 9 )) || { print -r -- "FAIL: $count of 9 clips"; bad=1; }
  return $bad
}

stage_set() {
  local run="$(resolve_run "$1")" dest="$REPO/website/demo" f
  check "$run" || fail "the set does not pass check; not staging"
  mkdir -p "$dest"
  for f in "$OUT_ROOT/$run"/[0-9][0-9]-*.mp4 "$OUT_ROOT/$run"/[0-9][0-9]-*.jpg; do
    cp "$f" "$dest/"
  done
  log "Staged into $dest (gitignored). Deploy is a separate, user-approved step."
}

cmd="${1:-}"; (( $# )) && shift
case "$cmd" in
  all)    record "$@"; cut_clips latest; check latest ;;
  record) record "$@" ;;
  export) [[ -n "${1:-}" ]] || fail "usage: make-demos.sh export <run-id>"; mkdir -p "$OUT_ROOT/$1"; export_run "$1" ;;
  cut)    cut_clips "${1:-latest}" "${@:2}" ;;
  check)  check "${1:-latest}" ;;
  stage)  stage_set "${1:-latest}" ;;
  *)      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac
