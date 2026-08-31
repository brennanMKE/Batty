#!/usr/bin/env python3
# list-issues.py — List issues from the project's issues/ folder.

import argparse
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

FRESH_SECS = 2 * 86400   # 2 days
WEEK_SECS = 7 * 86400    # 7 days

STATUS_OPEN = {"open", "new", "todo", "reopened"}
STATUS_IN_PROGRESS = {"in-progress", "in progress", "wip"}
STATUS_RESOLVED = {
    "resolved", "closed", "done", "fixed", "complete", "completed",
    "wontfix", "won't fix", "duplicate", "invalid",
}

TITLE_RE = re.compile(r"^#\s+(\d+)\s+—\s+(.*)")
STATUS_RE = re.compile(r"\|\s*\*\*Status\*\*\s*\|\s*(.+?)\s*\|")


def human_age(secs: int) -> str:
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h"
    if secs < 604800:
        return f"{secs // 86400}d"
    if secs < 2592000:
        return f"{secs // 604800}w"
    if secs < 31536000:
        return f"{secs // 2592000}mo"
    return f"{secs // 31536000}y"


def parse_issue(path: Path) -> Optional[dict]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None

    title = "(no title)"
    issue_id = path.stem
    for line in text.splitlines():
        m = TITLE_RE.match(line)
        if m:
            issue_id = m.group(1)
            title = m.group(2).strip()
            break

    status = "?"
    for line in text.splitlines():
        m = STATUS_RE.search(line)
        if m:
            status = m.group(1).strip().lower()
            break

    try:
        mtime = path.stat().st_mtime
    except OSError:
        return None

    age_secs = int(datetime.now(timezone.utc).timestamp() - mtime)
    return {
        "id": issue_id,
        "title": title,
        "status": status,
        "age_secs": age_secs,
        "mtime": mtime,
    }


def _exists(path: Path) -> bool:
    """Path.exists() that tolerates any OSError (e.g. EINVAL under /.resolve)."""
    try:
        return path.exists()
    except OSError:
        return False


def _is_dir(path: Path) -> bool:
    """Path.is_dir() that tolerates any OSError."""
    try:
        return path.is_dir()
    except OSError:
        return False


def _is_file(path: Path) -> bool:
    """Path.is_file() that tolerates any OSError."""
    try:
        return path.is_file()
    except OSError:
        return False


def is_issues_dir(d: Path) -> bool:
    """An issues folder is identified by a guide or a machine-readable marker."""
    return any(_is_file(d / name) for name in ("project.json", "Issues.md", "Issue.md"))


def find_issues_in(base: Path) -> Optional[Path]:
    """Look for an issues folder directly inside base.

    Prefers base/issues, otherwise the first immediate subdirectory that looks
    like one, with names containing "issue" winning. The marker check on
    base/issues matters on macOS: the filesystem is case-insensitive, so a
    source folder named Issues/ would otherwise be picked up as the tracker.
    """
    direct = base / "issues"
    if _is_dir(direct) and is_issues_dir(direct):
        return direct

    try:
        candidates = [d for d in sorted(base.iterdir()) if _is_dir(d) and is_issues_dir(d)]
    except OSError:
        return None
    if not candidates:
        return None

    named = [c for c in candidates if "issue" in c.name.lower()]
    ranked = named or candidates
    # A folder that actually holds NNNN.md files beats one identified only by a
    # marker file — that's what keeps a template or docs folder carrying a
    # stray project.json from winning over the real tracker.
    populated = [c for c in ranked if _has_issue_files(c)]
    return (populated or ranked)[0]


def _has_issue_files(d: Path) -> bool:
    try:
        return any(d.glob("[0-9][0-9][0-9][0-9].md"))
    except OSError:
        return False


def resolve_issues_dir(arg: Optional[str]) -> Path:
    """Honor an explicit DIR verbatim; otherwise search $PWD, then each parent."""
    base = Path.cwd()
    if arg is not None:
        p = Path(arg)
        return p if p.is_absolute() else base / p

    home = Path.home()
    d = base
    while True:
        found = find_issues_in(d)
        if found is not None:
            return found
        # A repo root is the boundary — climbing past it would reach sideways
        # into a parent folder holding unrelated projects. Checked *after* the
        # scan above, so a repo root's own issues/ is still found when the
        # command runs from a subdirectory.
        if _exists(d / ".git"):
            break
        # Don't wander above the user's home directory into the filesystem root,
        # where special dirs like /.resolve make stat() fail with EINVAL.
        if d == home or d == d.parent:
            break
        d = d.parent

    return base / "issues"


def classify(status: str, age_secs: int) -> int:
    terminal = status in STATUS_RESOLVED
    if age_secs <= FRESH_SECS:
        return 1 if terminal else 0
    if not terminal:
        return 2
    if age_secs <= WEEK_SECS:
        return 3
    return 4


def status_glyph(status: str) -> str:
    if status in STATUS_RESOLVED:
        return "✓"
    if status in STATUS_IN_PROGRESS:
        return "◐"
    if status in STATUS_OPEN:
        return "○"
    return "•"


def status_color(status: str) -> str:
    if status in STATUS_RESOLVED:
        return "\033[32m"
    if status in STATUS_IN_PROGRESS:
        return "\033[36m"
    if status in STATUS_OPEN:
        return "\033[33m"
    return "\033[35m"


def age_color(secs: int) -> str:
    if secs <= FRESH_SECS:
        return "\033[32m\033[1m"
    if secs <= WEEK_SECS:
        return "\033[33m"
    return "\033[2m"


def section_label(rank: int) -> str:
    if rank in (0, 1):
        return "⚡ Fresh · last 2 days"
    if rank == 2:
        return "○ Open · needs attention"
    if rank == 3:
        return "✓ Resolved · past week"
    return "✓ Stale resolved · older than a week"


def render_issues(issues: list[dict], limit: int, show_all: bool, use_color: bool) -> None:
    if not use_color:
        render_plain(issues, limit, show_all)
        return

    reset = "\033[0m"
    dim = "\033[2m"
    bold = "\033[1m"
    blue = "\033[34m"
    gray = "\033[90m"

    shown = 0
    hidden = 0
    prev_section = ""

    for iss in issues:
        if limit > 0 and shown >= limit:
            break
        rank = classify(iss["status"], iss["age_secs"])
        if rank == 4 and not show_all:
            hidden += 1
            continue

        sect = section_label(rank)
        if sect != prev_section:
            if shown > 0:
                print()
            print(f"{bold}{blue}{sect}{reset}")
            prev_section = sect

        glyph = status_glyph(iss["status"])
        scolor = status_color(iss["status"])
        acolor = age_color(iss["age_secs"])
        tcolor = dim if iss["status"] in STATUS_RESOLVED else reset

        statusf = f"{glyph} {iss['status']}"
        print(
            f"  {gray}{iss['id']}{reset}  "
            f"{scolor}{statusf:<14s}{reset}  "
            f"{acolor}{human_age(iss['age_secs']):>5s}{reset}  "
            f"{tcolor}{iss['title']}{reset}"
        )
        shown += 1

    footer = f"{shown} shown"
    if hidden > 0:
        footer += f" · {hidden} stale resolved hidden (-a to show)"
    print(f"\n{dim}{footer}{reset}")


def render_plain(issues: list[dict], limit: int, show_all: bool) -> None:
    shown = 0
    hidden = 0
    for iss in issues:
        if limit > 0 and shown >= limit:
            break
        rank = classify(iss["status"], iss["age_secs"])
        if rank == 4 and not show_all:
            hidden += 1
            continue
        print(f"{iss['id']}  {iss['status']:<12s}  {human_age(iss['age_secs']):>5s}  {iss['title']}")
        shown += 1

    if hidden > 0:
        print(f"\n{hidden} stale resolved hidden (-a to show)")


def mode_status(issues: list[dict], limit: int, show_all: bool, use_color: bool) -> None:
    """Filter to open, in-progress, and recently resolved."""
    filtered = [
        iss for iss in issues
        if iss["status"] in STATUS_OPEN
        or iss["status"] in STATUS_IN_PROGRESS
        or (iss["status"] in STATUS_RESOLVED and iss["age_secs"] <= WEEK_SECS)
    ]
    if not filtered:
        print("no matching issues", file=sys.stderr)
        return

    filtered.sort(key=lambda i: (i["age_secs"], -i["mtime"]))
    if limit > 0:
        filtered = filtered[:limit]

    render_issues(filtered, 0, True, use_color)


def mode_brief(issues: list[dict], limit: int = 20, show_all: bool = False, use_color: bool = False) -> None:
    """List most recently updated issues."""
    sorted_issues = sorted(issues, key=lambda i: -i["mtime"])[:limit]
    render_issues(sorted_issues, 0, True, use_color)


def mode_full(issues: list[dict], limit: int = 0, show_all: bool = True, use_color: bool = False) -> None:
    """List all issues in order of number."""
    sorted_issues = sorted(issues, key=lambda i: int(i["id"]))[:limit] if limit > 0 else issues
    render_issues(sorted_issues, 0, True, use_color)


def should_use_color(force: Optional[bool] = None) -> bool:
    if force is True:
        return True
    if force is False or os.environ.get("NO_COLOR"):
        return False
    if sys.stdout.isatty():
        return True
    return False


def main() -> None:
    parser = argparse.ArgumentParser(
        description="List issues from the project's issues/ folder.",
    )
    parser.add_argument(
        # No choices= here: it lets `list-issues.py <dir>` work without naming
        # a mode, which argparse would otherwise reject as an invalid choice.
        # Validated after parsing instead.
        "mode",
        nargs="?",
        default="status",
        metavar="{status,brief,full}",
        help="Display mode: status (open/in-progress/recently resolved), "
             "brief (most recently updated, top 20), or full (all issues by number). Default: status.",
    )
    parser.add_argument(
        "-n", "--limit", type=int, default=20,
        help="Maximum number of issues to show (default: 20). Use 0 for no limit.",
    )
    parser.add_argument(
        "-a", "--all", action="store_true", dest="show_all",
        help="Include stale resolved issues (older than 1 week).",
    )
    parser.add_argument(
        "--color", action="store_true", dest="force_color",
        help="Force colored output even when piped.",
    )
    parser.add_argument(
        "--no-color", action="store_true", dest="no_color",
        help="Force plain columnar output.",
    )
    parser.add_argument(
        "dir", nargs="?", default=None,
        help="Issues directory (relative to cwd or absolute path).",
    )

    args = parser.parse_args()

    MODES = ("status", "brief", "full")
    if args.mode not in MODES:
        # A single positional that isn't a mode is the issues directory.
        if args.dir is None:
            args.mode, args.dir = "status", args.mode
        else:
            parser.error(
                f"invalid mode: {args.mode!r} (choose from {', '.join(MODES)})"
            )

    force_color = None
    if args.force_color:
        force_color = True
    elif args.no_color:
        force_color = False

    issues_dir = resolve_issues_dir(args.dir)
    if not issues_dir.is_dir():
        if args.dir is None:
            # Nothing to list here; not an error.
            print("no issues directory found", file=sys.stderr)
            sys.exit(0)
        print(f"error: {issues_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    issue_files = sorted(issues_dir.glob("[0-9][0-9][0-9][0-9].md"))
    if not issue_files:
        print(f"no issue files in {issues_dir}", file=sys.stderr)
        sys.exit(0)

    issues = []
    for f in issue_files:
        parsed = parse_issue(f)
        if parsed is not None:
            issues.append(parsed)

    if not issues:
        print(f"no parseable issue files in {issues_dir}", file=sys.stderr)
        sys.exit(1)

    use_color = should_use_color(force_color)

    if args.mode == "status":
        mode_status(issues, args.limit, args.show_all, use_color)
    elif args.mode == "brief":
        mode_brief(issues, args.limit, args.show_all, use_color)
    elif args.mode == "full":
        mode_full(issues, args.limit, args.show_all, use_color)


if __name__ == "__main__":
    main()
