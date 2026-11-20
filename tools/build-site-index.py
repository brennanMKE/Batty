#!/usr/bin/env python3
"""Generate website/sitemap.xml, llms.txt and llms-full.txt.

    python3 -I tools/build-site-index.py [--check] [--site DIR]

sitemap.xml lists every .html page under the site that website/.deploy-hold
does not hold. llms.txt follows llmstxt.org; llms-full.txt concatenates the
agent docs with links made absolute. --check writes nothing and exits 1 when
a file is stale. Exit 2 on bad input.
"""

import argparse
import datetime
import importlib.util
import os
import posixpath
import re
import subprocess
import sys
from pathlib import Path
from xml.sax.saxutils import escape

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
BASE = "https://batty.sstools.co/"

SUMMARY = "> Batty is a native macOS terminal multiplexer built on libghostty, with an agent-facing CLI and MCP server."
INTRO = (
    "Agents running in a Batty Pane can drive Batty through the `batty` command or the `batty mcp` server: "
    "open Sessions, Panes and Tabs, show status, run dev servers, and set Reminders. "
    "Start with the agent docs, which cover detecting Batty and setting it up for each coding agent."
)
DOCS = [
    ("Agent docs", "docs/index.md", "detect Batty, CLI and MCP setup for Claude Code, Codex, Cursor and OpenCode"),
    ("CLI reference", "docs/cli/index.md", "every batty command and flag"),
    ("capabilities.json", "docs/cli/capabilities.json", "machine-readable CLI surface"),
]
SKILL_ZIP = "docs/skill/batty-cli-skill-latest.zip"
OPTIONAL = [
    ("Changelog", BASE + "changelog.html"),
    ("Source on GitHub", "https://github.com/brennanMKE/Batty"),
]
FULL_SOURCES = ["docs/index.md", "docs/cli/index.md"]

_spec = importlib.util.spec_from_file_location("check_website_hold", HERE / "check-website-hold.py")
hold = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hold)


class InputError(Exception):
    pass


class LinkError(Exception):
    pass


def _git(site, *args):
    r = subprocess.run(["git", *args], cwd=site, capture_output=True, text=True)
    if r.returncode != 0:
        raise InputError(f"git {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout


def now():
    return datetime.datetime.now(datetime.timezone.utc)


def _utc_day(moment):
    return moment.astimezone(datetime.timezone.utc).date().isoformat()


# Both sides of lastmod are UTC days. git's %cs prints the committer's own
# offset, so a page regenerated (UTC today) and committed the same evening in
# a negative-offset zone would read back as the previous day and --check would
# fail.
def lastmod(site, rel):
    today = _utc_day(now())
    if _git(site, "status", "--porcelain", "--", rel).strip():
        return today
    stamp = _git(site, "log", "-1", "--format=%ct", "--", rel).strip()
    if not stamp:
        return today
    return _utc_day(datetime.datetime.fromtimestamp(int(stamp), datetime.timezone.utc))


def load_hold(site):
    path = site / ".deploy-hold"
    if not path.exists():
        return []
    try:
        return hold.parse_hold(path.read_text())
    except (OSError, UnicodeDecodeError, hold.HoldFormatError) as e:
        raise InputError(f"{path}: {e}")


def build_sitemap(site, entries):
    if _git(site, "rev-parse", "--is-inside-work-tree").strip() != "true":
        raise InputError(f"{site} is not in a git work tree")
    pages = []
    for p in sorted(site.rglob("*.html")):
        rel = p.relative_to(site).as_posix()
        if any(part.startswith(".") for part in rel.split("/")):
            continue
        if hold.held_by(rel, entries):
            continue
        if rel == "index.html":
            loc = BASE
        elif rel.endswith("/index.html"):
            loc = BASE + rel[: -len("index.html")]
        else:
            loc = BASE + rel
        pages.append((loc, lastmod(site, rel)))
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    for loc, mod in pages:
        lines.append(f"  <url><loc>{escape(loc)}</loc><lastmod>{mod}</lastmod></url>")
    lines.append("</urlset>")
    return "\n".join(lines) + "\n"


def latest_dmg(site):
    path = site / "appcast.xml"
    try:
        text = path.read_text()
    except OSError as e:
        raise InputError(f"{path}: {e}")
    m = re.search(r'<enclosure\s[^>]*?url="([^"]+)"[^>]*?sparkle:shortVersionString="([^"]+)"', text)
    if not m:
        raise InputError(f"{path}: no <enclosure url=… sparkle:shortVersionString=…>")
    return m.group(1), m.group(2)


def build_llms(site):
    dmg_url, version = latest_dmg(site)
    lines = ["# Batty", "", SUMMARY, "", INTRO, "", "## Docs", ""]
    for text, rel, note in DOCS:
        lines.append(f"- [{text}]({BASE + rel}): {note}")
    lines += ["", "## Downloads", ""]
    if (site / SKILL_ZIP).is_file():
        lines.append(f"- [batty-cli skill]({BASE + SKILL_ZIP}): Agent Skill zip for Claude and other skill-aware agents")
    lines.append(f"- [Batty {version} for macOS]({dmg_url})")
    lines += ["", "## Optional", ""]
    for text, url in OPTIONAL:
        lines.append(f"- [{text}]({url})")
    out = "\n".join(lines) + "\n"
    for url in re.findall(r"\]\((https://[^)]+)\)", out):
        if url == dmg_url or not url.startswith(BASE):
            continue
        if not (site / url[len(BASE):]).is_file():
            raise LinkError(f"llms.txt links {url}, but {url[len(BASE):]} is not under {site}")
    return out


_LINK = re.compile(r"\]\(([^)\s]+)\)")


def _absolute(target, src_dir):
    if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target) or target.startswith(("#", "/")):
        return target
    path, frag = (target.split("#", 1) + [""])[:2]
    url = BASE + posixpath.normpath(posixpath.join(src_dir, path)).lstrip("./")
    return url + ("#" + frag if frag else "")


def build_full(site):
    parts = []
    for rel in FULL_SOURCES:
        path = site / rel
        try:
            text = path.read_text()
        except OSError as e:
            raise InputError(f"{path}: {e}")
        src_dir = posixpath.dirname(rel)
        out, fence = [], None
        for line in text.splitlines():
            s = line.lstrip()
            m = re.match(r"(`{3,}|~{3,})", s)
            if m:
                if fence is None:
                    fence = m.group(1)
                elif s.startswith(fence) and not s[len(fence):].strip():
                    fence = None
                out.append(line)
                continue
            if fence is None:
                if s.startswith("<!-- generated:") or s.startswith("<!-- /generated"):
                    continue
                line = _LINK.sub(lambda mm: "](" + _absolute(mm.group(1), src_dir) + ")", line)
            out.append(line)
        parts.append(f"Source: {BASE + rel}\n\n" + "\n".join(out).strip("\n") + "\n")
    return "# Batty documentation\n\n" + SUMMARY + "\n\n" + "\n---\n\n".join(parts)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--site", default=str(REPO / "website"))
    args = ap.parse_args(argv)
    site = Path(args.site).resolve()
    try:
        entries = load_hold(site)
        outputs = {
            "sitemap.xml": build_sitemap(site, entries),
            "llms.txt": build_llms(site),
            "llms-full.txt": build_full(site),
        }
    except InputError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    except LinkError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    stale = []
    for name, content in outputs.items():
        path = site / name
        current = path.read_text() if path.exists() else None
        if current == content:
            continue
        stale.append(name)
        if not args.check:
            path.write_text(content)
            os.chmod(path, 0o644)
    if args.check and stale:
        for name in stale:
            print(f"stale: {site / name} (run python3 -I tools/build-site-index.py)", file=sys.stderr)
        if "sitemap.xml" in stale:
            print("note: sitemap lastmod is each page's last commit day (UTC); a squash-merge on a later "
                  "day moves it, so regenerate and commit on main after merging a page change", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
