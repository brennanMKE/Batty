#!/bin/zsh
# Regenerates website/docs/snippets/ from the shared MCP config renderer.
# --check writes nothing and exits 1 when the committed files have drifted.
set -euo pipefail
ROOT="${0:A:h:h}"
exec swift run --quiet --package-path "$ROOT/BattyKit" BattyAgentSnippets --output "$ROOT/website/docs/snippets" "$@"
