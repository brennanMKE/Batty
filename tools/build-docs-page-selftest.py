#!/usr/bin/env python3
"""Self-test for build-docs-page.py. Temp folders only.

    python3 -I tools/build-docs-page-selftest.py
"""

import html.parser
import importlib.util
import re
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
DOCS = REPO / "website" / "docs"

spec = importlib.util.spec_from_file_location("build_docs_page", HERE / "build-docs-page.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)


def _raises(fn):
    try:
        fn()
    except gen.PageError:
        return True
    return False


def test_render_subset():
    md = "# T\n\nOne\ntwo <a> & \"q\"\n\n## A b!\n\n- `x<y>` **bold**\n- [l](http://e.com)\n\n1. one\n2. two\n"
    title, body = gen.render(md)
    out = "\n".join(body)
    assert title == "T"
    assert "<p>One two &lt;a&gt; &amp; &quot;q&quot;</p>" in out, out
    assert '<h2 id="a-b">A b!</h2>' in out
    assert "<li><code>x&lt;y&gt;</code> <strong>bold</strong></li>" in out
    assert '<a href="http://e.com">l</a>' in out
    assert "<ol>" in out and "<li>two</li>" in out
    assert "<h1" not in out


def test_long_fence_keeps_inner_fence():
    with tempfile.TemporaryDirectory() as d:
        Path(d, "global-instructions-prompt.txt").write_text("hi\n```markdown\n## X\n```\n")
        md = gen.refresh_markers("# T\n<!-- generated:global-instructions-prompt.txt -->\n<!-- /generated -->\n", d)
        assert "````text\nhi\n```markdown\n## X\n```\n````" in md, md
        out = "\n".join(gen.render(md)[1])
        assert "```markdown\n## X\n```</code></pre>" in out, out


def test_md_link_rewritten_absolute_untouched():
    out = "\n".join(gen.render("# T\n\n[a](cli/index.md) [b](https://x.co/g.md) [c](../c.html)\n")[1])
    assert 'href="cli/index.html"' in out
    assert 'href="https://x.co/g.md"' in out
    assert 'href="../c.html"' in out


def test_marker_refresh_replaces_and_is_idempotent():
    with tempfile.TemporaryDirectory() as d:
        Path(d, "cursor-mcp.json").write_text("{}\n")
        src = "# T\n<!-- generated:cursor-mcp.json -->\nstale\n<!-- /generated -->\nafter"
        once = gen.refresh_markers(src, d)
        assert "stale" not in once and "```json\n{}\n```" in once
        assert gen.refresh_markers(once, d) == once


def test_marker_errors():
    with tempfile.TemporaryDirectory() as d:
        Path(d, "cursor-mcp.json").write_text("{}\n")
        o, c = "<!-- generated:cursor-mcp.json -->", "<!-- /generated -->"
        assert _raises(lambda: gen.refresh_markers(f"{o}\nx", d))
        assert _raises(lambda: gen.refresh_markers(f"{o}\n{o}\n{c}", d))
        assert _raises(lambda: gen.refresh_markers(f"<!-- generated:../x -->\n{c}", d))
        assert _raises(lambda: gen.refresh_markers(f"<!-- generated:opencode.json -->\n{c}", d))  # missing file
        assert _raises(lambda: gen.refresh_markers("# T\n", d))  # unreferenced snippet
        assert _raises(lambda: gen.refresh_markers(c, d))


def test_unsupported_markdown_rejected():
    for bad in ("> quote", "| a | b |", "#### deep", "<div>raw</div>"):
        assert _raises(lambda: gen.render(f"# T\n\n{bad}\n")), bad


def test_check_detects_snippet_edit():
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        shutil.copytree(DOCS / "snippets", d / "snippets")
        shutil.copy(DOCS / "index.md", d / "index.md")
        args = ["--md", str(d / "index.md"), "--html", str(d / "index.html"), "--snippets", str(d / "snippets")]
        assert gen.main(args) == 0
        assert gen.main(args + ["--check"]) == 0
        snip = d / "snippets" / "claude-code-plugin.txt"
        snip.write_text(snip.read_text() + "# edited\n")
        before = (d / "index.md").read_text(), (d / "index.html").read_text()
        assert gen.main(args + ["--check"]) == 1
        assert ((d / "index.md").read_text(), (d / "index.html").read_text()) == before
        assert gen.main(args) == 0
        assert gen.main(args + ["--check"]) == 0


def test_check_verbs():
    caps = {"verbs": [
        {"name": "server serve", "inputSchema": {"properties": {"port": {"names": ["--port"]}}}},
        {"name": "server start", "inputSchema": {"properties": {"port": {"names": ["--port"]}}}},
        {"name": "agent install", "inputSchema": {"properties": {}}},
    ]}
    assert gen.check_verbs("`batty server serve site --port 1` `server_serve`", caps) == []
    assert gen.check_verbs("`batty server start --port 1 -- npm --x`", caps) == []
    assert gen.check_verbs("`batty-beta server serve --port 1`", caps) == []
    assert gen.check_verbs("`batty frob`", caps)
    assert gen.check_verbs("`batty server serve --nope`", caps)
    assert gen.check_verbs("`server_nope`", caps)
    assert gen.check_verbs("`agent_install`", caps)
    assert gen.check_verbs("```sh\nbatty server serve --nope\n```", caps)


class _Balance(html.parser.HTMLParser):
    VOID = {"meta", "link", "br", "img", "hr", "input"}

    def __init__(self):
        super().__init__()
        self.stack, self.errors = [], []

    def handle_starttag(self, tag, attrs):
        if tag not in self.VOID:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if not self.stack or self.stack.pop() != tag:
            self.errors.append(tag)


def test_html_well_formed():
    p = _Balance()
    p.feed((DOCS / "index.html").read_text())
    assert not p.errors and not p.stack, (p.errors, p.stack)


def test_repo_page_current():
    assert gen.main(["--check"]) == 0


def test_no_live_page_links_docs():
    for page in (REPO / "website").glob("*.html"):
        assert not re.search(r'href="[^"]*docs/', page.read_text()), page


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
