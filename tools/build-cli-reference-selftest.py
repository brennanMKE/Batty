#!/usr/bin/env python3
"""Offline cases for tools/build-cli-reference.py.

    python3 -I tools/build-cli-reference-selftest.py [path/to/build-cli-reference.py]

Renders fixture payloads in temporary folders. Never builds or runs the CLI.
"""

import contextlib
import copy
import importlib.util
import io
import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
target = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "build-cli-reference.py"
spec = importlib.util.spec_from_file_location("build_cli_reference", target)
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)

HINTS = {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False}
EMPTY = {"type": "object", "properties": {}, "required": []}

PAYLOAD = {
    "cliVersion": "9.8.7",
    "jsonSchemaDialect": "https://json-schema.org/draft/2020-12/schema",
    "exitCodes": [{"code": 0, "meaning": "Success."}, {"code": 1, "meaning": "Fail <a> & b | c"}],
    "verbs": [
        {"name": "ping", "abstract": "Ping it.", "aliases": [], "annotations": HINTS, "inputSchema": EMPTY},
        {"name": "pane split", "abstract": "Split <the> pane & more | pipes.", "aliases": ["sp"],
         "annotations": {k: False for k in HINTS}, "inputSchema": {
             "type": "object", "required": ["count"],
             "properties": {
                 "count": {"cliKind": "option", "cliRequired": True, "default": "2", "description": "How many | n.",
                           "names": ["--count"], "type": "integer", "minimum": 1, "maximum": 9},
                 "direction": {"cliKind": "flag", "cliRequired": False, "default": "horizontal", "description": "Dir.",
                               "enum": ["horizontal", "vertical"],
                               "enumValueNames": {"horizontal": ["-h"], "vertical": ["-v"]}, "names": [], "type": "string"},
                 "path": {"cliKind": "positional", "cliRequired": False, "description": "Where.", "names": [], "type": "string"},
             },
             "conflicts": [{"description": "--a and --b clash", "kind": "mutuallyExclusive", "parameters": ["a", "b"]}],
         }},
        {"name": "pane close", "abstract": "Close.", "aliases": [], "annotations": HINTS, "inputSchema": EMPTY},
        {"name": "id", "abstract": "Id.", "aliases": [], "annotations": HINTS, "inputSchema": EMPTY},
    ],
}

failures = 0


def check(cond, label):
    global failures
    if not cond:
        failures += 1
        print(f"FAIL {label}")
    else:
        print(f"ok   {label}")


def run(argv):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return cr.main(argv)


pages = cr.render(copy.deepcopy(PAYLOAD))
md, page = pages["index.md"], pages["index.html"]
for v in PAYLOAD["verbs"]:
    check(md.count(f"### `batty {v['name']}`") == 1, f"md lists {v['name']} once")
    check(page.count(f"<code>batty {v['name']}</code></h3>") == 1, f"html lists {v['name']} once")
check(md.index("## Top-level commands") < md.index("## `pane`"), "top-level group first")
check(md.index("batty id`") < md.index("## `pane`"), "single-word verbs grouped at top")
check(md.index("batty pane split") < md.index("batty pane close"), "JSON order kept within a noun")
check("Batty 9.8.7" in md and "Batty 9.8.7" in page, "pages state cliVersion")
check("How many \\| n." in md, "md escapes pipes in table cells")
check("Fail <a> & b \\| c" in md, "md escapes pipes in exit codes")
check("Split &lt;the&gt; pane &amp; more | pipes." in page, "html escapes < and &")
check("<the>" not in page, "no raw < in html")
check("| `<path>` | positional |" in md, "positional rendered as <name>")
check("horizontal (-h), vertical (-v)" in md, "enum aliases")
check("1–9" in md, "range")
check("- --a and --b clash" in md, "conflicts listed")
check("Hints: read-only, idempotent" in md and "Hints: none" in md, "hints")
check("No parameters." in md, "empty schema")

UNKNOWN = '{\n  "cliVersion" : "unknown",\n  "verbs" : [\n\n  ]\n}\n'
check(cr.apply_cli_version(UNKNOWN, "1.2.3") == UNKNOWN.replace("unknown", "1.2.3"), "apply_cli_version replaces one line")
for bad, label in ((UNKNOWN.replace("unknown", "1.0.0"), "zero matches"), (UNKNOWN + UNKNOWN, "two matches")):
    try:
        cr.apply_cli_version(bad, "1.2.3")
        check(False, f"apply_cli_version rejects {label}")
    except cr.UsageError:
        check(True, f"apply_cli_version rejects {label}")

dup = copy.deepcopy(PAYLOAD)
dup["verbs"].append(copy.deepcopy(dup["verbs"][0]))
try:
    cr.render(dup)
    check(False, "duplicate verb names rejected")
except cr.UsageError:
    check(True, "duplicate verb names rejected")

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    j = tmp / "capabilities.json"
    j.write_text(json.dumps(PAYLOAD), encoding="utf-8")
    out = tmp / "out"
    args = ["--json", str(j), "--out", str(out)]
    check(run(args + ["--check"]) == 1, "--check exits 1 when pages are missing")
    check(run(args) == 0, "render writes pages")
    check(run(args + ["--check"]) == 0, "--check exits 0 on fresh output")
    (out / "index.md").write_text("edited\n", encoding="utf-8")
    check(run(args + ["--check"]) == 1, "--check exits 1 on a modified page")
    check(run(args + ["--check", "--refresh-json", "--cli-version", "1.0.0"]) == 2, "--check with --refresh-json exits 2")
    check(run(args + ["--refresh-json", "--cli", "/x", "--cli-version", "1.0.0"]) == 2, "--cli with --cli-version exits 2")
    j.write_text(json.dumps(dup), encoding="utf-8")
    check(run(args) == 2, "duplicate verbs exit 2")

print("selftest:", "FAILED" if failures else "passed")
sys.exit(1 if failures else 0)
