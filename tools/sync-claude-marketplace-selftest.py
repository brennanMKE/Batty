#!/usr/bin/env python3
"""Self-test for sync-claude-marketplace.sh. Temp folders only.

Each case copies the script into a scratch git repo standing in for this one,
so the "this repo" refusals are exercised without touching a real checkout.

    python3 -I tools/sync-claude-marketplace-selftest.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "sync-claude-marketplace.sh"
# No `claude` on PATH, so the script never runs `claude plugin validate` here.
ENV = {**os.environ, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}


def git(cwd, *args):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                    "-c", "init.defaultBranch=main", "-C", str(cwd), *args],
                   check=True, capture_output=True, env=ENV)


def snapshot(root):
    """Every path under root except .git internals, with file contents."""
    out = {}
    for p in sorted(Path(root).rglob("*")):
        rel = p.relative_to(root)
        if rel.parts and rel.parts[0] == ".git":
            continue
        out[str(rel)] = p.read_bytes() if p.is_file() and not p.is_symlink() else None
    return out


class Scratch:
    def __init__(self, t):
        self.t = Path(t).resolve()
        self.fake = self.t / "fake-batty"
        (self.fake / "tools").mkdir(parents=True)
        shutil.copy2(SCRIPT, self.fake / "tools" / SCRIPT.name)
        (self.fake / "work.txt").write_text("uncommitted work\n")
        git(self.fake, "init")
        git(self.fake, "add", "tools")
        git(self.fake, "commit", "-m", "init")
        self.src = self.t / "generated"
        self._write(self.src / ".claude-plugin" / "marketplace.json", json.dumps({"name": "batty-plugins"}))
        self._write(self.src / "batty" / ".claude-plugin" / "plugin.json", json.dumps({"name": "batty", "version": "9.9.9"}))
        self._write(self.src / "batty" / "skills" / "batty-cli" / "SKILL.md", "skill\n")
        self._write(self.src / "README.md", "readme\n")

    @staticmethod
    def _write(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def repo(self, name, files=None):
        d = self.t / name
        d.mkdir()
        git(d, "init")
        for rel, text in (files or {}).items():
            self._write(d / rel, text)
        return d

    def run(self, target, *extra, script_root=None):
        script = (script_root or self.fake) / "tools" / SCRIPT.name
        return subprocess.run(["/bin/zsh", str(script), str(target), "--from", str(self.src), *extra],
                              capture_output=True, text=True, env=ENV)


def expect_refusal(s, target, **kw):
    before = snapshot(target)
    for extra in ((), ("--dry-run",)):
        r = s.run(target, *extra, **kw)
        assert r.returncode == 2, (target, extra, r.returncode, r.stdout, r.stderr)
        assert "nothing was changed" in r.stderr, r.stderr
    assert snapshot(target) == before, target


def test_refuses_this_repos_main_checkout():
    with tempfile.TemporaryDirectory() as t:
        s = Scratch(t)
        expect_refusal(s, s.fake)


def test_refuses_another_worktree_of_this_repo():
    with tempfile.TemporaryDirectory() as t:
        s = Scratch(t)
        wt = s.t / "fake-batty-wt"
        git(s.fake, "worktree", "add", "-q", str(wt))
        (wt / "wt-work.txt").write_text("worktree work\n")
        expect_refusal(s, wt)
        expect_refusal(s, s.fake, script_root=wt)


def test_refuses_subdirectory_of_a_repo():
    with tempfile.TemporaryDirectory() as t:
        s = Scratch(t)
        other = s.repo("other", {"sub/keep.txt": "keep\n"})
        expect_refusal(s, other / "sub")


def test_refuses_non_empty_unrelated_repo():
    with tempfile.TemporaryDirectory() as t:
        s = Scratch(t)
        expect_refusal(s, s.repo("unrelated", {"src/main.c": "int main;\n", "LICENSE": "MIT\n"}))


def test_refuses_a_different_marketplace():
    with tempfile.TemporaryDirectory() as t:
        s = Scratch(t)
        expect_refusal(s, s.repo("theirs", {".claude-plugin/marketplace.json": json.dumps({"name": "someone-else"})}))


def test_refuses_a_folder_that_is_not_a_git_repo():
    with tempfile.TemporaryDirectory() as t:
        s = Scratch(t)
        plain = s.t / "plain"
        plain.mkdir()
        expect_refusal(s, plain)


def test_fills_an_empty_new_clone():
    with tempfile.TemporaryDirectory() as t:
        s = Scratch(t)
        clone = s.repo("new-clone", {"LICENSE": "MIT\n"})
        dry = s.run(clone, "--dry-run")
        assert dry.returncode == 0, dry.stderr
        assert snapshot(clone) == {"LICENSE": b"MIT\n"}
        r = s.run(clone)
        assert r.returncode == 0, r.stderr
        snap = snapshot(clone)
        assert snap["LICENSE"] == b"MIT\n"
        assert snap["README.md"] == b"readme\n"
        assert snap["batty/skills/batty-cli/SKILL.md"] == b"skill\n"
        assert "git -C" in r.stdout and "commit" in r.stdout


def test_updates_an_existing_marketplace_clone():
    with tempfile.TemporaryDirectory() as t:
        s = Scratch(t)
        clone = s.repo("existing", {
            ".claude-plugin/marketplace.json": json.dumps({"name": "batty-plugins", "old": True}),
            "batty/skills/old-skill/SKILL.md": "stale\n",
            "LICENSE": "MIT\n",
            "CONTRIBUTING.md": "hand written\n",
        })
        r = s.run(clone)
        assert r.returncode == 0, r.stderr
        snap = snapshot(clone)
        assert json.loads(snap[".claude-plugin/marketplace.json"]) == {"name": "batty-plugins"}
        assert "batty/skills/old-skill/SKILL.md" not in snap, "stale managed file kept"
        assert snap["CONTRIBUTING.md"] == b"hand written\n", "unmanaged file touched"
        assert snap["LICENSE"] == b"MIT\n"


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_")]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"ok   {name}")
        except Exception as e:
            failed += 1
            print(f"FAIL {name}: {e!r}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
