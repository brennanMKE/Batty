#!/bin/zsh
# export-ui-recordings.sh — export the per-test screen recordings from a UI
# test .xcresult as <Class>.<testMethod>.mp4 plus a .poster.png each (#0448).
#
# Usage:
#   tools/export-ui-recordings.sh build/ui-tests/<run-id>/UITests.xcresult [out-dir]
#
# out-dir defaults to <run-id>/recordings next to the bundle. A bundle only
# holds recordings for passing tests if the run used
# BATTY_UI_KEEP_RECORDINGS=1 tools/run-ui-tests-vm.sh ... (see
# docs/ui-testing-vm.md); otherwise only failed tests have one.
#
# Stock macOS tools only: xcresulttool, qlmanage, python3 (for the manifest).

set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  print -u2 "usage: ${0:t} <path/to/UITests.xcresult> [out-dir]"
  exit 64
fi

BUNDLE="${1:A}"
[[ -d "$BUNDLE" ]] || { print -u2 "not a result bundle: $1"; exit 66; }
OUT="${2:-${BUNDLE:h}/recordings}"
mkdir -p "$OUT"
OUT="${OUT:A}"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ui-recordings.XXXXXX")"
trap '[[ -n "$STAGE" && -d "$STAGE" ]] && /bin/rm -r "$STAGE"' EXIT

xcrun xcresulttool export attachments --path "$BUNDLE" --output-path "$STAGE" \
  --filter '*.mp4' > /dev/null

[[ -f "$STAGE/manifest.json" ]] || { print -u2 "no manifest produced"; exit 1; }

# Prints "<exportedFileName>\t<Class.testMethod>" per recording. A test with
# several recordings (retries, repeated runs) gets .2, .3 ... suffixes.
names="$(/usr/bin/python3 -I - "$STAGE/manifest.json" <<'PY'
import json, re, sys
seen = {}
for entry in json.load(open(sys.argv[1])):
    ident = re.sub(r"\(\)$", "", entry["testIdentifier"]).replace("/", ".")
    for att in entry["attachments"]:
        name = att["exportedFileName"]
        if not name.endswith(".mp4"):
            continue
        n = seen.get(ident, 0) + 1
        seen[ident] = n
        print(f"{name}\t{ident if n == 1 else f'{ident}.{n}'}")
PY
)"

if [[ -z "$names" ]]; then
  print "No screen recordings in $BUNDLE (a run without BATTY_UI_KEEP_RECORDINGS=1 keeps them only for failed tests)."
  exit 0
fi

count=0
while IFS=$'\t' read -r file base; do
  /bin/cp "$STAGE/$file" "$OUT/$base.mp4"
  /usr/bin/qlmanage -t -s 800 -o "$STAGE" "$OUT/$base.mp4" > /dev/null 2>&1 || true
  if [[ -f "$STAGE/$base.mp4.png" ]]; then
    /bin/mv "$STAGE/$base.mp4.png" "$OUT/$base.poster.png"
  else
    print -u2 "warning: no poster generated for $base.mp4"
  fi
  (( count += 1 ))
done <<< "$names"

print "Exported $count recording(s) to $OUT"
