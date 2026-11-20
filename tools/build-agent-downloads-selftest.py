#!/usr/bin/env python3
"""Self-test for build-agent-downloads.py. Temp folders only.

    python3 -I tools/build-agent-downloads-selftest.py
"""

import contextlib
import importlib.util
import io
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
BUNDLED = REPO / ".claude" / "skills" / "batty-cli" / "SKILL.md"

spec = importlib.util.spec_from_file_location("build_agent_downloads", HERE / "build-agent-downloads.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)


def _run(argv):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return gen.main(argv)


def test_zip_is_reproducible():
    assert gen.skill_zip(b"x") == gen.skill_zip(b"x")
    assert gen.skill_zip(gen.skill_files()) == gen.skill_zip(gen.skill_files())


def test_zip_layout_and_times():
    z = zipfile.ZipFile(io.BytesIO(gen.skill_zip(b"hello\n")))
    assert z.namelist() == ["batty-cli/", "batty-cli/SKILL.md"], z.namelist()
    assert z.read("batty-cli/SKILL.md") == b"hello\n"
    for info in z.infolist():
        assert info.date_time == (1980, 1, 1, 0, 0, 0), info.date_time
        assert info.compress_type == zipfile.ZIP_STORED


def test_check_detects_drift():
    with tempfile.TemporaryDirectory() as t:
        out = Path(t) / "skill"
        args = ["--version", "9.9.9", "--skill-out", str(out)]
        assert _run(args + ["--check"]) == 1
        assert _run(args + ["--no-marketplace"]) == 0
        assert (out / "batty-cli-skill-9.9.9.zip").read_bytes() == (out / "batty-cli-skill-latest.zip").read_bytes()
        assert _run(args + ["--check"]) == 0
        latest = out / "batty-cli-skill-latest.zip"
        b = bytearray(latest.read_bytes())
        b[-1] ^= 1
        latest.write_bytes(bytes(b))
        assert _run(args + ["--check"]) == 1


def test_bad_version_is_usage_error():
    with tempfile.TemporaryDirectory() as t:
        assert _run(["--version", "1.5", "--skill-out", t, "--no-marketplace"]) == 2


def test_extract_matches_bundled_skill():
    with tempfile.TemporaryDirectory() as t:
        zipfile.ZipFile(io.BytesIO(gen.skill_zip(gen.skill_files()))).extractall(t)
        assert (Path(t) / "batty-cli" / "SKILL.md").read_bytes() == BUNDLED.read_bytes()


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"pass {t.__name__}")
        except Exception as e:
            failed += 1
            print(f"FAIL {t.__name__}: {e!r}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
