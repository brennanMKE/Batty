#!/usr/bin/env python3
"""Refresh website/docs/index.md from the agent snippets and render index.html.

    python3 -I tools/build-docs-page.py [--check] [--md PATH] [--html PATH]
                                        [--snippets DIR] [--capabilities FILE]

Each `<!-- generated:<name> -->` ... `<!-- /generated -->` region of the
Markdown is replaced with a fenced block holding website/docs/snippets/<name>.
The Markdown is then rendered, as a small subset (ATX headings #-###,
paragraphs, flat `- ` and `1. ` lists, fenced code, inline code, bold, links),
into a page with the site's header, footer and stylesheet. Anything else is
an error, so the subset stays honest.

--check writes nothing and exits 1 when either file would change.
--capabilities FILE checks every `batty ...` command, flag and MCP tool name
on the page against a `batty capabilities --json` listing.
Exit 0 when fine, 1 for a stale page or a capabilities miss, 2 for a bad page,
snippet or usage error. Standard library only.
"""

import argparse
import html
import json
import os
import re
import shlex
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
DOCS = REPO / "website" / "docs"
PAGE_MODE = 0o644

MARK_OPEN = re.compile(r"^<!-- generated:(\S+) -->$")
MARK_CLOSE = "<!-- /generated -->"

INFO = {
    "claude-code-plugin.txt": "sh",
    "claude-code-marketplace.txt": "text",
    "claude-code-mcp-add.txt": "sh",
    "codex-config.toml": "toml",
    "cursor-mcp.json": "json",
    "opencode.json": "json",
    "global-instructions-prompt.txt": "text",
}

# Mirrors MCPToolCatalog.excludedVerbPaths.
MCP_EXCLUDED = {"mcp", "agent install", "agent context"}


class PageError(Exception):
    pass


def _fence_for(text):
    runs = [len(m) for m in re.findall(r"`+", text)]
    return "`" * max(3, (max(runs) + 1) if runs else 3)


def refresh_markers(md, snippets, path="index.md"):
    snippets = Path(snippets)
    lines = md.split("\n")
    out, used, i = [], set(), 0
    while i < len(lines):
        line = lines[i]
        m = MARK_OPEN.match(line.strip())
        if not m:
            if line.strip() == MARK_CLOSE:
                raise PageError(f"{path}:{i + 1}: {MARK_CLOSE} without an opening marker")
            out.append(line)
            i += 1
            continue
        name, start = m.group(1), i
        if "/" in name or ".." in name or name not in INFO:
            raise PageError(f"{path}:{i + 1}: bad snippet name {name!r}")
        j = i + 1
        while j < len(lines) and lines[j].strip() != MARK_CLOSE:
            if MARK_OPEN.match(lines[j].strip()):
                raise PageError(f"{path}:{j + 1}: nested generated marker inside {name}")
            j += 1
        if j == len(lines):
            raise PageError(f"{path}:{start + 1}: generated:{name} is never closed")
        f = snippets / name
        try:
            body = f.read_bytes().decode("utf-8")
        except (OSError, UnicodeDecodeError) as e:
            raise PageError(f"{path}:{start + 1}: snippet {f}: {e}")
        body = body.rstrip("\n")
        fence = _fence_for(body)
        out.append(line)
        out.append(fence + INFO[name])
        out.extend(body.split("\n"))
        out.append(fence)
        out.append(lines[j])
        used.add(name)
        i = j + 1
    if snippets.is_dir():
        extra = sorted(p.name for p in snippets.iterdir() if p.is_file() and p.name not in used)
        if extra:
            raise PageError(f"{path}: snippets no marker uses: {', '.join(extra)}")
    return "\n".join(out)


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "section"


def _href(url):
    if not re.match(r"^[a-z][a-z0-9+.-]*:", url) and not url.startswith("#"):
        url = re.sub(r"\.md(#|$)", r".html\1", url)
    return url


INLINE = re.compile(r"`([^`]+)`|\*\*(.+?)\*\*|\[([^\]]+)\]\(([^)\s]+)\)")


def inline(text):
    out, pos = [], 0
    for m in INLINE.finditer(text):
        out.append(html.escape(text[pos:m.start()]))
        if m.group(1) is not None:
            out.append(f"<code>{html.escape(m.group(1))}</code>")
        elif m.group(2) is not None:
            out.append(f"<strong>{inline(m.group(2))}</strong>")
        else:
            out.append(f'<a href="{html.escape(_href(m.group(4)))}">{inline(m.group(3))}</a>')
        pos = m.end()
    out.append(html.escape(text[pos:]))
    return "".join(out)


FENCE = re.compile(r"^(`{3,})([A-Za-z0-9_-]*)$")
UL = re.compile(r"^- (.+)$")
OL = re.compile(r"^\d+\. (.+)$")
HEAD = re.compile(r"^(#{1,3}) (.+)$")


def render(md, path="index.md"):
    """(title, body lines). The first # heading is the title, not repeated."""
    lines = md.split("\n")
    out, title, para, i = [], None, [], 0

    def flush():
        if para:
            out.append(f"<p>{inline(' '.join(para))}</p>")
            para.clear()

    while i < len(lines):
        raw = lines[i]
        line = raw.strip()
        if line.startswith("<!--"):
            flush()
            while "-->" not in lines[i]:
                i += 1
                if i == len(lines):
                    raise PageError(f"{path}: unclosed HTML comment")
            i += 1
            continue
        fm = FENCE.match(raw)
        if fm:
            flush()
            fence, lang, body = fm.group(1), fm.group(2), []
            i += 1
            while i < len(lines) and lines[i] != fence:
                body.append(lines[i])
                i += 1
            if i == len(lines):
                raise PageError(f"{path}: unclosed code fence")
            cls = f' class="language-{lang}"' if lang else ""
            out.append(f"<pre><code{cls}>{html.escape(chr(10).join(body))}</code></pre>")
            i += 1
            continue
        if not line:
            flush()
            i += 1
            continue
        hm = HEAD.match(raw)
        if hm:
            flush()
            level, text = len(hm.group(1)), hm.group(2).strip()
            if level == 1 and title is None:
                title = text
            else:
                out.append(f'<h{level} id="{slug(text)}">{inline(text)}</h{level}>')
            i += 1
            continue
        for rx, tag in ((UL, "ul"), (OL, "ol")):
            if rx.match(raw):
                flush()
                out.append(f"<{tag}>")
                while i < len(lines) and rx.match(lines[i]):
                    out.append(f"    <li>{inline(rx.match(lines[i]).group(1))}</li>")
                    i += 1
                out.append(f"</{tag}>")
                break
        else:
            if raw.startswith(("#", ">", "|", " ", "\t", "<", "* ", "+ ")):
                raise PageError(f"{path}:{i + 1}: unsupported Markdown: {raw[:40]!r}")
            para.append(line)
            i += 1
    flush()
    if title is None:
        raise PageError(f"{path}: no # title")
    return title, out


TEMPLATE = """<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{title} — Batty</title>
    <meta name="description" content="{desc}">

    <meta property="og:title" content="Batty {title}">
    <meta property="og:description" content="{desc}">
    <meta property="og:url" content="https://batty.sstools.co/docs/">
    <meta property="og:type" content="website">

    <meta name="twitter:card" content="summary">
    <meta name="twitter:title" content="Batty {title}">
    <meta name="twitter:description" content="{desc}">

    <link rel="icon" type="image/png" sizes="32x32" href="../assets/favicon-32.png">
    <link rel="icon" href="../assets/batty-icon.png" type="image/png">
    <link rel="apple-touch-icon" href="../assets/apple-touch-icon.png">
    <link rel="stylesheet" href="../css/style.css">
</head>
<body class="page">
    <header class="page-header">
        <a class="back" href="../index.html">← Batty</a>
        <h1>{title}</h1>
    </header>

    <main class="prose docs">
        <p class="meta">Generated from <a href="index.md">index.md</a>, which agents can read as plain Markdown.</p>
{body}
    </main>

    <footer>
        <nav>
            <a href="../demo.html">Demo</a>
            <a href="../changelog.html">Changelog</a>
            <a href="../privacy.html">Privacy</a>
            <a href="https://github.com/brennanMKE/Batty/issues">Report an issue</a>
        </nav>
        <p class="copyright">© Batty contributors. Built on libghostty (Ghostty contributors, MIT) and SlidingTabs.</p>
    </footer>
</body>
</html>
"""

DESC = "How an agent running in a Batty Pane detects Batty and drives it by CLI or MCP."


def render_page(md, path="index.md"):
    title, body = render(md, path)
    # Only each block's first line is indented, so <pre> content keeps its whitespace.
    lines = ["        " + l for l in body]
    return TEMPLATE.format(title=html.escape(title), desc=html.escape(DESC), body="\n".join(lines))


def _commands(md):
    """Command strings from code spans and fenced lines that start with batty."""
    cmds = []
    for line in md.split("\n"):
        s = line.strip()
        if re.match(r"^(batty|batty-beta) ", s):
            cmds.append(s)
    for span in re.findall(r"`([^`\n]+)`", md):
        if re.match(r"^(batty|batty-beta) ", span):
            cmds.append(span)
    return cmds


def check_verbs(md, caps):
    verbs = {v["name"]: v for v in caps.get("verbs", [])}
    nouns = {n.split(" ")[0] for n in verbs}
    problems = []
    for cmd in _commands(md):
        try:
            toks = shlex.split(cmd)
        except ValueError:
            toks = cmd.split()
        rest = toks[1:]
        verb = None
        for n in range(len(rest), 0, -1):
            if " ".join(rest[:n]) in verbs:
                verb = " ".join(rest[:n])
                break
        if verb is None:
            problems.append(f"unknown command: {cmd}")
            continue
        names = set()
        for prop in (verbs[verb].get("inputSchema", {}).get("properties", {}) or {}).values():
            names.update(prop.get("names", []))
        for t in rest[len(verb.split()):]:
            if t == "--":
                break
            if re.match(r"^--?[A-Za-z]", t) and t not in names:
                problems.append(f"unknown flag {t} for `{verb}`: {cmd}")
    for span in set(re.findall(r"`([a-z]+(?:_[a-z]+)+)`", md)):
        if span.split("_")[0] not in nouns:
            continue
        name = span.replace("_", " ")
        if name not in verbs or name in MCP_EXCLUDED:
            problems.append(f"unknown MCP tool: {span}")
    return problems


def _write(path, text):
    path = Path(path)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-", suffix=path.suffix)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, PAGE_MODE)
    os.replace(tmp, path)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--md", default=str(DOCS / "index.md"))
    ap.add_argument("--html", default=str(DOCS / "index.html"))
    ap.add_argument("--snippets", default=str(DOCS / "snippets"))
    ap.add_argument("--capabilities")
    a = ap.parse_args(argv)
    md_path, html_path = Path(a.md), Path(a.html)
    try:
        old_md = md_path.read_text(encoding="utf-8")
        new_md = refresh_markers(old_md, a.snippets, md_path.name)
        page = render_page(new_md, md_path.name)
    except (OSError, UnicodeDecodeError, PageError) as e:
        print(f"build-docs-page: {e}", file=sys.stderr)
        return 2
    status = 0
    if a.capabilities:
        try:
            caps = json.loads(Path(a.capabilities).read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            print(f"build-docs-page: capabilities: {e}", file=sys.stderr)
            return 2
        for p in check_verbs(new_md, caps):
            print(f"build-docs-page: {p}", file=sys.stderr)
            status = 1
    if a.check:
        old_html = html_path.read_text(encoding="utf-8") if html_path.exists() else None
        for path, old, new in ((md_path, old_md, new_md), (html_path, old_html, page)):
            if old != new:
                print(f"build-docs-page: {path} is out of date; run python3 -I tools/build-docs-page.py",
                      file=sys.stderr)
                status = 1
        return status
    if new_md != old_md:
        _write(md_path, new_md)
    _write(html_path, page)
    return status


if __name__ == "__main__":
    sys.exit(main())
