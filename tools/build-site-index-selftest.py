#!/usr/bin/env python3
"""Self-test for build-site-index.py. Temp folders only.

    python3 -I tools/build-site-index-selftest.py
"""

import contextlib
import datetime
import importlib.util
import io
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent


def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gen = _load("build_site_index", "build-site-index.py")
holdcheck = _load("check_website_hold", "check-website-hold.py")

FIXED = "2026-01-02T03:04:05+00:00"
APPCAST = (
    '<rss><channel><item><enclosure url="https://batty.sstools.co/downloads/Batty-9.9.0.dmg" '
    'sparkle:version="2" sparkle:shortVersionString="9.9.0" type="x" /></item>'
    '<item><enclosure url="https://batty.sstools.co/downloads/Batty-9.8.0.dmg" '
    'sparkle:version="1" sparkle:shortVersionString="9.8.0" type="x" /></item></channel></rss>\n'
)


def _today():
    return datetime.datetime.now(datetime.timezone.utc).date().isoformat()


def _git(d, *args, date=FIXED, tz=None):
    env = dict(os.environ, GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
    if tz:
        env["TZ"] = tz
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@e", "-c", "commit.gpgsign=false", *args],
                   cwd=d, env=env, check=True, capture_output=True)


def _fixture(d, hold="/docs/\n/llms.txt\n/llms-full.txt\n"):
    site = Path(d)
    files = {
        ".deploy-hold": hold,
        "index.html": "<p>i</p>\n",
        "demo.html": "<p>d</p>\n",
        "changelog.html": "<p>c</p>\n",
        "appcast.xml": APPCAST,
        "docs/index.html": "<p>x</p>\n",
        "docs/index.md": "# Docs\n\nSee [CLI](cli/index.md) and [web](https://e.com/a.md).\n\n"
                         "<!-- generated:x.txt -->\n```sh\nbatty\n```\n<!-- /generated -->\n",
        "docs/cli/index.html": "<p>y</p>\n",
        "docs/cli/index.md": "# CLI\n\nBack to [docs](../index.md#top), [json](capabilities.json), [h](#here).\n",
        "docs/cli/capabilities.json": "{}\n",
    }
    for rel, text in files.items():
        p = site / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    _git(site, "init", "-q")
    _git(site, "add", ".")
    _git(site, "commit", "-q", "-m", "f")
    return site


def _run(*argv):
    with contextlib.redirect_stderr(io.StringIO()):
        return gen.main(list(argv))


def _build(site):
    assert _run("--site", str(site)) == 0
    return {n: (site / n).read_text() for n in ("sitemap.xml", "llms.txt", "llms-full.txt")}


def test_sitemap_skips_held_paths():
    with tempfile.TemporaryDirectory() as d:
        sm = _build(_fixture(d))["sitemap.xml"]
        assert "docs/" not in sm, sm
        assert "<loc>https://batty.sstools.co/</loc>" in sm
        assert "demo.html" in sm


def test_removing_hold_entry_adds_page():
    with tempfile.TemporaryDirectory() as d:
        site = _fixture(d)
        _build(site)
        (site / ".deploy-hold").write_text("")
        sm = _build(site)["sitemap.xml"]
        assert "<loc>https://batty.sstools.co/docs/</loc>" in sm, sm
        assert "<loc>https://batty.sstools.co/docs/cli/</loc>" in sm, sm


def test_held_file_entry():
    with tempfile.TemporaryDirectory() as d:
        sm = _build(_fixture(d, hold="/demo.html\n"))["sitemap.xml"]
        assert "demo.html" not in sm and "docs/cli/" in sm, sm


def test_lastmod_from_git_commit_date():
    with tempfile.TemporaryDirectory() as d:
        site = _fixture(d)
        sm = _build(site)["sitemap.xml"]
        assert "demo.html</loc><lastmod>2026-01-02</lastmod>" in sm, sm
        (site / "demo.html").write_text("<p>changed</p>\n")
        sm = _build(site)["sitemap.xml"]
        assert f"demo.html</loc><lastmod>{_today()}</lastmod>" in sm, sm


def test_lastmod_round_trip_across_utc_day_boundary():
    # 20:00 Pacific on Jan 1 is 04:00 UTC on Jan 2: local and UTC days differ.
    evening = "2026-01-01T20:00:00-0800"
    pacific = datetime.timezone(datetime.timedelta(hours=-8))
    saved_now, saved_tz = gen.now, os.environ.get("TZ")
    gen.now = lambda: datetime.datetime(2026, 1, 1, 20, 0, tzinfo=pacific)
    os.environ["TZ"] = "America/Los_Angeles"
    try:
        with tempfile.TemporaryDirectory() as d:
            site = _fixture(d)
            _build(site)
            _git(site, "add", ".")
            _git(site, "commit", "-q", "-m", "gen")
            (site / "demo.html").write_text("<p>evening edit</p>\n")
            sm = _build(site)["sitemap.xml"]
            assert "demo.html</loc><lastmod>2026-01-02</lastmod>" in sm, sm
            _git(site, "add", ".", date=evening, tz="America/Los_Angeles")
            _git(site, "commit", "-q", "-m", "edit", date=evening, tz="America/Los_Angeles")
            assert _run("--check", "--site", str(site)) == 0, (site / "sitemap.xml").read_text()
    finally:
        gen.now = saved_now
        if saved_tz is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = saved_tz


def test_squash_on_later_day_reports_stale_with_hint():
    with tempfile.TemporaryDirectory() as d:
        site = _fixture(d)
        _build(site)
        _git(site, "add", ".")
        _git(site, "commit", "-q", "-m", "gen")
        (site / "demo.html").write_text("<p>squashed</p>\n")
        _git(site, "add", ".", date="2026-03-04T12:00:00+00:00")
        _git(site, "commit", "-q", "-m", "squash", date="2026-03-04T12:00:00+00:00")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            assert gen.main(["--check", "--site", str(site)]) == 1
        assert "stale:" in err.getvalue() and "squash-merge" in err.getvalue(), err.getvalue()
        assert "demo.html</loc><lastmod>2026-03-04</lastmod>" in _build(site)["sitemap.xml"]


def test_untracked_and_unknown():
    with tempfile.TemporaryDirectory() as d:
        site = _fixture(d)
        (site / "new.html").write_text("<p>n</p>\n")
        sm = _build(site)["sitemap.xml"]
        assert f"new.html</loc><lastmod>{_today()}</lastmod>" in sm, sm
    with tempfile.TemporaryDirectory() as d:
        site = Path(d)
        (site / "index.html").write_text("x")
        (site / "appcast.xml").write_text(APPCAST)
        assert _run("--site", str(site)) == 2


def test_llms_structure():
    with tempfile.TemporaryDirectory() as d:
        lines = _build(_fixture(d))["llms.txt"].splitlines()
        assert lines[0] == "# Batty"
        assert lines[2].startswith("> ")
        heads = [l for l in lines if l.startswith("## ")]
        assert heads == ["## Docs", "## Downloads", "## Optional"], heads
        for l in lines:
            if l.startswith("- "):
                assert re.match(r"^- \[[^\]]+\]\(https://[^)]+\)(: .+)?$", l), l


def test_llms_broken_link_fails():
    with tempfile.TemporaryDirectory() as d:
        site = _fixture(d)
        (site / "docs/cli/capabilities.json").unlink()
        assert _run("--site", str(site)) == 1


def test_skill_link_only_when_committed():
    with tempfile.TemporaryDirectory() as d:
        site = _fixture(d)
        assert "skill" not in _build(site)["llms.txt"]
        zip_ = site / gen.SKILL_ZIP
        zip_.parent.mkdir(parents=True)
        zip_.write_bytes(b"PK")
        assert _run("--check", "--site", str(site)) == 1
        assert gen.BASE + gen.SKILL_ZIP in _build(site)["llms.txt"]


def test_dmg_from_appcast():
    with tempfile.TemporaryDirectory() as d:
        site = _fixture(d)
        llms = _build(site)["llms.txt"]
        assert "- [Batty 9.9.0 for macOS](https://batty.sstools.co/downloads/Batty-9.9.0.dmg)" in llms, llms
        (site / "appcast.xml").write_text("<rss></rss>\n")
        assert _run("--site", str(site)) == 2


def test_full_rewrites_relative_links_and_drops_markers():
    with tempfile.TemporaryDirectory() as d:
        full = _build(_fixture(d))["llms-full.txt"]
        assert "](https://batty.sstools.co/docs/index.md#top)" in full, full
        assert "](https://batty.sstools.co/docs/cli/index.md)" in full
        assert "](https://batty.sstools.co/docs/cli/capabilities.json)" in full
        assert "](https://e.com/a.md)" in full and "](#here)" in full
        assert "<!-- generated" not in full and "<!-- /generated" not in full
        lines = full.splitlines()
        i = lines.index("Source: https://batty.sstools.co/docs/index.md")
        j = lines.index("Source: https://batty.sstools.co/docs/cli/index.md")
        assert lines[i + 2] == "# Docs" and lines[j + 2] == "# CLI" and i < j
        assert "---" in lines[i:j]


def test_check_detects_drift_and_writes_nothing():
    with tempfile.TemporaryDirectory() as d:
        site = _fixture(d)
        _build(site)
        assert _run("--check", "--site", str(site)) == 0
        before = {n: (site / n).stat().st_mtime_ns for n in ("sitemap.xml", "llms.txt", "llms-full.txt")}
        (site / "more.html").write_text("<p>m</p>\n")
        assert _run("--check", "--site", str(site)) == 1
        after = {n: (site / n).stat().st_mtime_ns for n in before}
        assert before == after


def test_repo_files_current():
    assert _run("--check") == 0


def test_repo_hold_check_passes():
    assert (REPO / "website/robots.txt").exists() and (REPO / "website/sitemap.xml").exists()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        assert holdcheck.main([]) == 0


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_")]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"pass {name}")
        except Exception as e:
            failed += 1
            print(f"FAIL {name}: {e!r}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
