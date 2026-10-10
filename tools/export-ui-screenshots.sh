#!/bin/zsh
# export-ui-screenshots.sh — export the named PNG screenshots that
# BattyUITests/ViewGalleryTests attaches to a UI test .xcresult as
# <attachment-name>.png (#0451).
#
# Usage:
#   tools/export-ui-screenshots.sh build/ui-tests/<run-id>/UITests.xcresult [out-dir]
#
# out-dir defaults to <run-id>/screenshots next to the bundle. The test sets
# lifetime = .keepAlways on each attachment, so a passing run keeps them
# without BATTY_UI_KEEP_RECORDINGS=1.
#
# Stock macOS tools only: xcresulttool and python3 (for the manifest).

set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  print -u2 "usage: ${0:t} <path/to/UITests.xcresult> [out-dir]"
  exit 64
fi

BUNDLE="${1:A}"
[[ -d "$BUNDLE" ]] || { print -u2 "not a result bundle: $1"; exit 66; }
OUT="${2:-${BUNDLE:h}/screenshots}"
mkdir -p "$OUT"
OUT="${OUT:A}"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ui-screenshots.XXXXXX")"
trap '[[ -n "$STAGE" && -d "$STAGE" ]] && /bin/rm -r "$STAGE"' EXIT

xcrun xcresulttool export attachments --path "$BUNDLE" --output-path "$STAGE" \
  --filter 'gallery.*' > /dev/null

[[ -f "$STAGE/manifest.json" ]] || { print -u2 "no manifest produced"; exit 1; }

# Prints "<exportedFileName>\t<attachment name>" per PNG. Xcode suffixes a
# name with "_<n>_<UUID>" when it stores the attachment; the suggested
# human-readable name is used when the manifest has one.
names="$(/usr/bin/python3 -I - "$STAGE/manifest.json" <<'PY'
import json, re, sys
seen = {}
for entry in json.load(open(sys.argv[1])):
    for att in entry["attachments"]:
        file = att["exportedFileName"]
        if not file.endswith(".png"):
            continue
        name = att.get("suggestedHumanReadableName") or file
        name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}", "", name)
        name = re.sub(r"\.png$", "", name)
        if not name.startswith("gallery."):
            continue
        n = seen.get(name, 0) + 1
        seen[name] = n
        print(f"{file}\t{name if n == 1 else f'{name}.{n}'}")
PY
)"

if [[ -z "$names" ]]; then
  print "No gallery screenshots in $BUNDLE."
  exit 0
fi

count=0
while IFS=$'\t' read -r file base; do
  /bin/cp "$STAGE/$file" "$OUT/$base.png"
  (( count += 1 ))
done <<< "$names"

print "Exported $count screenshot(s) to $OUT"
