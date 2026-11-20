#!/usr/bin/env python3
"""Render website/docs/cli/ from `batty capabilities --json`.

    python3 -I tools/build-cli-reference.py [--check]
        [--refresh-json (--cli-version X.Y.Z | --cli PATH)] [--json PATH] [--out DIR]

Default: render index.md and index.html from the committed capabilities.json.
--refresh-json first replaces capabilities.json with the CLI's own --json
stdout, byte for byte: from a SwiftPM build of the batty target with every
release flag on (needs --cli-version, which replaces the "unknown" a bare
binary reports), or from an installed CLI given with --cli.
--check renders in memory, writes nothing, and exits 1 when a page differs.
"""

import argparse
import html
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_JSON = ROOT / "website" / "docs" / "cli" / "capabilities.json"
DEFAULT_OUT = ROOT / "website" / "docs" / "cli"
REQUIRED_KEYS = ("cliVersion", "verbs", "exitCodes", "jsonSchemaDialect")
HINTS = (
    ("readOnlyHint", "read-only"),
    ("destructiveHint", "destructive"),
    ("idempotentHint", "idempotent"),
    ("openWorldHint", "open-world"),
)
VERSION_LINE = re.compile(r'^  "cliVersion" : "unknown",$', re.M)
REGENERATE = "run python3 -I tools/build-cli-reference.py to regenerate"


class UsageError(Exception):
    pass


def apply_cli_version(text, version):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise UsageError(f"--cli-version must look like X.Y.Z, got {version!r}")
    matches = VERSION_LINE.findall(text)
    if len(matches) != 1:
        raise UsageError(f'expected exactly one "cliVersion" : "unknown" line, found {len(matches)}')
    return VERSION_LINE.sub(f'  "cliVersion" : "{version}",', text)


def validate(payload):
    if not isinstance(payload, dict):
        raise UsageError("capabilities JSON is not an object")
    for key in REQUIRED_KEYS:
        if key not in payload:
            raise UsageError(f"capabilities JSON has no {key!r}")
    names = [v["name"] for v in payload["verbs"]]
    dupes = sorted({n for n in names if names.count(n) > 1})
    if dupes:
        raise UsageError(f"duplicate verb names: {', '.join(dupes)}")


def groups(payload):
    out = []
    index = {}
    for verb in payload["verbs"]:
        noun = verb["name"].split(" ")[0] if " " in verb["name"] else ""
        if noun not in index:
            index[noun] = len(out)
            out.append((noun, []))
        out[index[noun]][1].append(verb)
    out.sort(key=lambda g: g[0] != "")
    return out


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def group_title(noun):
    return "Top-level commands" if noun == "" else f"`{noun}`"


def hint_line(annotations):
    hints = [label for key, label in HINTS if annotations.get(key)]
    return ", ".join(hints) if hints else "none"


def param_rows(schema):
    rows = []
    for key in sorted(schema.get("properties", {})):
        p = schema["properties"][key]
        if p.get("cliKind") == "positional" or not p.get("names"):
            param = f"<{key}>" if p.get("cliKind") == "positional" else key
        else:
            param = ", ".join(p["names"])
        allowed = []
        aliases = p.get("enumValueNames", {})
        for value in p.get("enum", []):
            alias = aliases.get(value)
            allowed.append(f"{value} ({', '.join(alias)})" if alias else str(value))
        rng = ""
        if "minimum" in p or "maximum" in p:
            rng = f"{p.get('minimum', '')}–{p.get('maximum', '')}"
        rows.append([
            param,
            p.get("cliKind", ""),
            p.get("type", ""),
            "yes" if p.get("cliRequired") else "no",
            "" if p.get("default") is None else str(p["default"]),
            ", ".join(allowed),
            rng,
            p.get("description", ""),
        ])
    return rows


COLUMNS = ["Parameter", "Kind", "Type", "Required", "Default", "Allowed values", "Range", "Description"]


def conflicts(schema):
    return [c["description"] for c in schema.get("conflicts", []) if c.get("description")]


def md_cell(text):
    return text.replace("|", "\\|").replace("\n", " ")


def render_md(payload):
    v = payload["cliVersion"]
    lines = [
        "# Batty command-line reference",
        "",
        f"Generated from `batty capabilities --json`, Batty {v}. "
        "Machine-readable copy: [capabilities.json](capabilities.json).",
        "",
        "Run `batty capabilities --json` (`batty-beta` in Batty Beta) for the exact "
        "surface of the build you have installed. Back to [Docs](../index.md).",
    ]
    for noun, verbs in groups(payload):
        lines += ["", f"## {group_title(noun)}"]
        for verb in verbs:
            lines += ["", f"### `batty {verb['name']}`", "", verb["abstract"]]
            if verb["aliases"]:
                lines += ["", "Aliases: " + ", ".join(f"`{a}`" for a in verb["aliases"])]
            lines += ["", f"Hints: {hint_line(verb['annotations'])}", ""]
            rows = param_rows(verb["inputSchema"])
            if rows:
                lines.append("| " + " | ".join(COLUMNS) + " |")
                lines.append("|" + "---|" * len(COLUMNS))
                for row in rows:
                    cells = [f"`{row[0]}`"] + row[1:]
                    lines.append("| " + " | ".join(md_cell(c) for c in cells) + " |")
            else:
                lines.append("No parameters.")
            notes = conflicts(verb["inputSchema"])
            if notes:
                lines.append("")
                lines += [f"- {n}" for n in notes]
    lines += ["", "## Exit codes", "", "| Code | Meaning |", "|---|---|"]
    lines += [f"| {e['code']} | {md_cell(e['meaning'])} |" for e in payload["exitCodes"]]
    lines += [
        "",
        f"Every `inputSchema` follows the JSON Schema dialect `{payload['jsonSchemaDialect']}`.",
        "",
    ]
    return "\n".join(lines)


def e(text):
    return html.escape(str(text), quote=True)


def code_title(noun):
    return "Top-level commands" if noun == "" else f"<code>{e(noun)}</code>"


def render_html(payload):
    v = e(payload["cliVersion"])
    desc = "Every batty command, its parameters and exit codes, generated from batty capabilities --json."
    out = [
        "<!doctype html>",
        '<html lang="en">',
        "<head>",
        '    <meta charset="utf-8">',
        '    <meta name="viewport" content="width=device-width, initial-scale=1">',
        "    <title>CLI reference — Batty</title>",
        f'    <meta name="description" content="{e(desc)}">',
        "",
        '    <link rel="icon" type="image/png" sizes="32x32" href="../../assets/favicon-32.png">',
        '    <link rel="icon" href="../../assets/batty-icon.png" type="image/png">',
        '    <link rel="apple-touch-icon" href="../../assets/apple-touch-icon.png">',
        '    <link rel="stylesheet" href="../../css/style.css">',
        "</head>",
        '<body class="page">',
        '    <header class="page-header">',
        '        <a class="back" href="../index.html">← Docs</a>',
        "        <h1>Batty command-line reference</h1>",
        "    </header>",
        "",
        '    <main class="prose cli-reference">',
        f'        <p class="meta">Generated from <code>batty capabilities --json</code>, Batty {v}. '
        'Machine-readable copy: <a href="capabilities.json">capabilities.json</a>.</p>',
        "        <p>Run <code>batty capabilities --json</code> (<code>batty-beta</code> in Batty Beta) "
        "for the exact surface of the build you have installed.</p>",
    ]
    for noun, verbs in groups(payload):
        gid = "noun-" + (slug(noun) or "top-level")
        out.append(f'        <h2 id="{gid}">{code_title(noun)}</h2>')
        for verb in verbs:
            out.append(f'        <h3 id="verb-{slug(verb["name"])}"><code>batty {e(verb["name"])}</code></h3>')
            out.append(f"        <p>{e(verb['abstract'])}</p>")
            if verb["aliases"]:
                out.append("        <p>Aliases: " + ", ".join(f"<code>{e(a)}</code>" for a in verb["aliases"]) + "</p>")
            out.append(f"        <p>Hints: {e(hint_line(verb['annotations']))}</p>")
            rows = param_rows(verb["inputSchema"])
            if rows:
                out.append("        <table>")
                out.append("            <thead><tr>" + "".join(f"<th>{e(c)}</th>" for c in COLUMNS) + "</tr></thead>")
                out.append("            <tbody>")
                for row in rows:
                    out.append("                <tr><td><code>" + e(row[0]) + "</code></td>" + "".join(f"<td>{e(c)}</td>" for c in row[1:]) + "</tr>")
                out.append("            </tbody>")
                out.append("        </table>")
            else:
                out.append("        <p>No parameters.</p>")
            notes = conflicts(verb["inputSchema"])
            if notes:
                out.append("        <ul>")
                out += [f"            <li>{e(n)}</li>" for n in notes]
                out.append("        </ul>")
    out += [
        '        <h2 id="exit-codes">Exit codes</h2>',
        "        <table>",
        "            <thead><tr><th>Code</th><th>Meaning</th></tr></thead>",
        "            <tbody>",
    ]
    out += [f"                <tr><td>{e(x['code'])}</td><td>{e(x['meaning'])}</td></tr>" for x in payload["exitCodes"]]
    out += [
        "            </tbody>",
        "        </table>",
        f"        <p>Every <code>inputSchema</code> follows the JSON Schema dialect <code>{e(payload['jsonSchemaDialect'])}</code>.</p>",
        "    </main>",
        "",
        "    <footer>",
        "        <nav>",
        '            <a href="../../demo.html">Demo</a>',
        '            <a href="../../changelog.html">Changelog</a>',
        '            <a href="../../privacy.html">Privacy</a>',
        '            <a href="https://github.com/brennanMKE/Batty/issues">Report an issue</a>',
        "        </nav>",
        '        <p class="copyright">© Batty contributors. Built on libghostty (Ghostty contributors, MIT) and SlidingTabs.</p>',
        "    </footer>",
        "</body>",
        "</html>",
        "",
    ]
    return "\n".join(out)


def render(payload):
    validate(payload)
    return {"index.md": render_md(payload), "index.html": render_html(payload)}


def fetch_json(cli, version):
    if cli:
        cmd = [cli, "capabilities", "--json"]
    else:
        cmd = [
            "swift", "run", "-q",
            "--package-path", str(ROOT / "BattyKit"),
            "--scratch-path", str(ROOT / "BattyKit" / ".build" / "cli-reference"),
            "-Xswiftc", "-DBATTY_VARIANT_BETA",
            "batty", "capabilities", "--json",
        ]
    result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise UsageError(f"{' '.join(cmd)} exited {result.returncode}")
    text = result.stdout
    if version:
        text = apply_cli_version(text, version)
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as err:
        raise UsageError(f"CLI output is not JSON: {err}")
    validate(payload)
    return text


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text(encoding="utf-8") == text:
        print(f"unchanged {path}")
        return
    path.write_text(text, encoding="utf-8")
    os.chmod(path, 0o644)
    print(f"wrote {path}")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Render website/docs/cli/ from batty capabilities --json.")
    parser.add_argument("--check", action="store_true", help="write nothing; exit 1 when a page is stale")
    parser.add_argument("--refresh-json", action="store_true", help="regenerate capabilities.json from the CLI first")
    parser.add_argument("--cli-version", help="version to stamp on a SwiftPM-built CLI's output")
    parser.add_argument("--cli", help="an installed batty CLI to read verbatim")
    parser.add_argument("--json", type=Path, default=DEFAULT_JSON)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 2
    try:
        if args.check and args.refresh_json:
            raise UsageError("--check and --refresh-json can't be combined")
        if args.cli and args.cli_version:
            raise UsageError("--cli keeps the version the CLI reports; drop --cli-version")
        if (args.cli or args.cli_version) and not args.refresh_json:
            raise UsageError("--cli and --cli-version need --refresh-json")
        if args.refresh_json:
            if not (args.cli or args.cli_version):
                raise UsageError("--refresh-json needs --cli-version X.Y.Z or --cli PATH")
            write(args.json, fetch_json(args.cli, args.cli_version))
        try:
            payload = json.loads(args.json.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as err:
            raise UsageError(f"can't read {args.json}: {err}")
        pages = render(payload)
    except UsageError as err:
        print(f"build-cli-reference: {err}", file=sys.stderr)
        return 2
    if args.check:
        stale = []
        for name, text in pages.items():
            path = args.out / name
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                stale.append(path)
                print(f"{'missing' if not path.exists() else 'differs'}: {path}")
        if stale:
            print(REGENERATE)
            return 1
        return 0
    for name, text in pages.items():
        write(args.out / name, text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
