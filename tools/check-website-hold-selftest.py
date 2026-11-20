#!/usr/bin/env python3
"""Offline cases for tools/check-website-hold.py.

    python3 -I tools/check-website-hold-selftest.py [path/to/check-website-hold.py]

Builds small site fixtures in temporary folders. No rsync, no network.
"""

import contextlib
import importlib.util
import io
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
target = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "check-website-hold.py"
spec = importlib.util.spec_from_file_location("check_website_hold", target)
cwh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cwh)

REAL_SITE = HERE.parent / "website"
DEFAULT_HOLD = "/docs/\n/llms.txt\n/llms-full.txt\n"
cases = 0


def run(files, hold=DEFAULT_HOLD, extra=None):
    with tempfile.TemporaryDirectory() as tmp:
        site = Path(tmp)
        if hold is not None:
            (site / ".deploy-hold").write_text(hold)
        for name, text in files.items():
            (site / name).parent.mkdir(parents=True, exist_ok=True)
            (site / name).write_text(text)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cwh.main(["--site", str(site)] + (extra or []))
        return code, out.getvalue(), err.getvalue()


def expect(name, files, want, **kwargs):
    global cases
    code, out, err = run(files, **kwargs)
    assert code == want, f"{name}: exit {code}, want {want}\nstdout: {out}\nstderr: {err}"
    cases += 1
    return err


def page(body):
    return f"<!doctype html><html><body>\n{body}\n</body></html>\n"


expect("clean_site_passes", {"index.html": page(
    '<a href="changelog.html">c</a><link href="css/site.css"><a href="https://github.com/x/y">g</a><a href="#top">t</a>'
)}, 0, hold="/docs/\n")

err = expect("relative_link_to_held_page_fails", {"index.html": page('<a href="docs/index.html">d</a>')}, 1)
assert "index.html" in err and "docs/index.html" in err, f"relative_link_to_held_page_fails: stderr {err!r}"

expect("root_relative_and_directory_link_fails", {"index.html": page('<a href="/docs/">d</a>')}, 1)
expect("absolute_site_url_fails", {"index.html": page('<a href="https://batty.sstools.co/docs/cli/index.md">d</a>')}, 1)
expect("absolute_site_url_http_fails", {"index.html": page('<a href="http://batty.sstools.co/docs/">d</a>')}, 1)
expect("other_host_ignored", {"index.html": page('<a href="https://example.com/docs/index.html">d</a>')}, 0)
expect("query_and_fragment_stripped", {"index.html": page('<a href="llms.txt?x=1#y">l</a>')}, 1)
expect("similar_name_not_held", {"index.html": page(
    '<a href="docs.html">a</a><a href="docsearch/x.html">b</a><a href="llms.txt.bak">c</a>'
)}, 0)
expect("escaping_root_ignored", {"index.html": page('<a href="../docs/index.html">a</a>')}, 0)
expect("src_checked", {"index.html": page('<img src="docs/a.png">')}, 1)
expect("srcset_checked", {"index.html": page('<img srcset="ok.png 1x, docs/b.png 2x">')}, 1)
expect("meta_refresh_checked", {"index.html": page('<meta http-equiv="refresh" content="0; url=docs/">')}, 1)
expect("sitemap_loc_fails", {"sitemap.xml": "<urlset>\n<url><loc>https://batty.sstools.co/docs/index.html</loc></url>\n</urlset>\n"}, 1)
expect("robots_allow_checked", {"robots.txt": "User-agent: *\nAllow: /docs/\n"}, 1)
expect("robots_sitemap_only_passes", {"robots.txt": "User-agent: *\nSitemap: https://batty.sstools.co/sitemap.xml\n"}, 0)
expect("pages_inside_held_dir_not_scanned", {"docs/index.html": page('<a href="cli/index.html">c</a>')}, 0)

for bad in ("docs/\n", "/docs/*.md\n", "- /docs/\n"):
    expect(f"bad_hold_entry_rejected {bad.strip()!r}", {"index.html": page("")}, 2, hold=bad)

entries = cwh.parse_hold("# header\n\n  # indented comment\n/docs/\n\n/llms.txt\n")
assert [e.raw for e in entries] == ["/docs/", "/llms.txt"], f"comments_and_blanks_ignored: {entries}"
assert cwh.is_held("docs", entries) and cwh.is_held("docs/a/b.md", entries) and not cwh.is_held("llms.txt.bak", entries)
cases += 1

expect("missing_hold_file_errors", {"index.html": page("")}, 2, hold=None)

out, err = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
    code = cwh.main(["--site", str(REAL_SITE)])
assert code == 0, f"real_repo_passes: exit {code}\n{err.getvalue()}"
# #0688 updates this set when it empties the hold list on 1.5.0 release day.
real = {e.raw for e in cwh.parse_hold((REAL_SITE / ".deploy-hold").read_text())}
assert real == {"/docs/", "/llms.txt", "/llms-full.txt"}, f"real_repo_passes: hold entries {real}"
cases += 1

print(f"OK: {cases} cases")
