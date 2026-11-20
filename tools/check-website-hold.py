#!/usr/bin/env python3
"""Fail when a deployable website page links a path in website/.deploy-hold.

    python3 -I tools/check-website-hold.py [--site DIR] [--hold FILE]

Scans <site>/*.html (top level only), plus sitemap.xml and robots.txt when
present. Exit 0 when clean, 1 when a page links a held path, 2 when the hold
file is missing, unreadable or malformed.
"""

import argparse
import posixpath
import re
import sys
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit

SITE_HOST = "batty.sstools.co"
SKIP_PREFIXES = ("#", "mailto:", "tel:", "javascript:", "data:")


class HoldFormatError(Exception):
    pass


@dataclass(frozen=True)
class HoldEntry:
    raw: str
    path: str
    is_dir: bool


def parse_hold(text):
    entries = []
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith(("+ ", "- ")):
            raise HoldFormatError(f"line {number}: rule prefixes are not allowed: {stripped}")
        if not stripped.startswith("/"):
            raise HoldFormatError(f"line {number}: entry must start with '/': {stripped}")
        if any(c in stripped for c in "*?["):
            raise HoldFormatError(f"line {number}: wildcards are not allowed: {stripped}")
        is_dir = stripped.endswith("/")
        path = stripped.strip("/")
        if not path:
            raise HoldFormatError(f"line {number}: empty path: {stripped}")
        entries.append(HoldEntry(stripped, path, is_dir))
    return entries


def held_by(site_path, entries):
    for entry in entries:
        if entry.is_dir:
            if site_path == entry.path or site_path.startswith(entry.path + "/"):
                return entry
        elif site_path == entry.path:
            return entry
    return None


def is_held(site_path, entries):
    return held_by(site_path, entries) is not None


class _RefParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.refs = []

    def handle_starttag(self, tag, attrs):
        line = self.getpos()[0]
        values = dict(attrs)
        for name in ("href", "src", "poster", "data", "action"):
            if values.get(name):
                self.refs.append((values[name], line))
        if values.get("srcset"):
            for candidate in values["srcset"].split(","):
                parts = candidate.split()
                if parts:
                    self.refs.append((parts[0], line))
        if tag == "meta" and (values.get("http-equiv") or "").lower() == "refresh":
            match = re.search(r"url\s*=\s*['\"]?([^'\";]+)", values.get("content") or "", re.I)
            if match:
                self.refs.append((match.group(1).strip(), line))

    handle_startendtag = handle_starttag


def extract_refs(text, kind):
    """Return (ref, line) pairs."""
    if kind == "html":
        parser = _RefParser()
        parser.feed(text)
        parser.close()
        return parser.refs
    refs = []
    for number, line in enumerate(text.splitlines(), 1):
        if kind == "xml":
            refs += [(m.strip(), number) for m in re.findall(r"<loc>(.*?)</loc>", line)]
            refs += [(m, number) for m in re.findall(r"href\s*=\s*['\"]([^'\"]+)", line)]
        elif kind == "robots":
            match = re.match(r"\s*(sitemap|allow|disallow)\s*:\s*(\S+)", line, re.I)
            if match:
                refs.append((match.group(2), number))
    return refs


def resolve(ref, page_rel):
    ref = ref.strip()
    if not ref or ref.lower().startswith(SKIP_PREFIXES):
        return None
    parts = urlsplit(ref)
    if parts.scheme or parts.netloc:
        if parts.scheme not in ("http", "https") or (parts.hostname or "").lower() != SITE_HOST:
            return None
        path = parts.path or "/"
    else:
        path = parts.path
        if not path:
            return None
    if not path.startswith("/"):
        path = posixpath.join(posixpath.dirname(page_rel), path)
    if _escapes_root(path.lstrip("/")):
        return None
    normalised = posixpath.normpath("/" + path.lstrip("/")).lstrip("/")
    return normalised if normalised != "." else ""


def _escapes_root(path):
    depth = 0
    for part in path.split("/"):
        if part == "..":
            depth -= 1
            if depth < 0:
                return True
        elif part not in ("", "."):
            depth += 1
    return False


def main(argv=None):
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--site", type=Path, default=repo / "website")
    parser.add_argument("--hold", type=Path)
    args = parser.parse_args(argv)
    site = args.site
    hold = args.hold or site / ".deploy-hold"

    try:
        entries = parse_hold(hold.read_text(encoding="utf-8"))
    except OSError as error:
        print(f"error: cannot read hold file {hold}: {error}", file=sys.stderr)
        return 2
    except HoldFormatError as error:
        print(f"error: {hold}: {error}", file=sys.stderr)
        return 2

    pages = [(p, "html") for p in sorted(site.glob("*.html"))]
    for name, kind in (("sitemap.xml", "xml"), ("robots.txt", "robots")):
        if (site / name).is_file():
            pages.append((site / name, kind))

    failures = 0
    for page, kind in pages:
        page_rel = page.name
        for ref, line in extract_refs(page.read_text(encoding="utf-8"), kind):
            target = resolve(ref, page_rel)
            if target is None:
                continue
            entry = held_by(target, entries)
            if entry:
                failures += 1
                print(f"{page_rel}:{line}: links held path {target} (held by {entry.raw})", file=sys.stderr)

    if failures:
        return 1
    print(f"OK: {len(pages)} pages checked, {len(entries)} held entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
