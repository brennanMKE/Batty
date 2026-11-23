#!/usr/bin/env python3
"""Offline cases for scripts/release-cleanup.sh and its use in release.sh.

    python3 -I tools/release-cleanup-selftest.py

Builds throwaway build/ trees in a temp dir; never runs release.sh.
"""

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent / "scripts"
HELPER = SCRIPTS / "release-cleanup.sh"
RELEASE = SCRIPTS / "release.sh"
cases = 0
failures = 0

OWNED = ["Batty.xcarchive", "Export", "exportOptions.plist", "app-entitlements.plist"]
FOREIGN = {
    "ui-tests/R1/xcodebuild.log": "ui log\n",
    "sparkle-tests/R2/summary.txt": "sparkle\n",
    "checks/unit-x.log": "check\n",
    "demo/D/x": "demo\n",
}


def expect(name, cond, info=""):
    global cases, failures
    cases += 1
    if cond:
        print(f"ok   {name}")
    else:
        failures += 1
        print(f"FAIL {name}\n{info}")


def write(path, text="x\n"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def make_owned(build):
    write(build / "Batty.xcarchive/Products/Applications/Batty.app/Contents/Info.plist")
    write(build / "Export/Batty.app/Contents/Info.plist")
    write(build / "exportOptions.plist")
    write(build / "app-entitlements.plist")


def make_foreign(build):
    for rel, text in FOREIGN.items():
        write(build / rel, text)


def run(build_dir, *paths):
    return subprocess.run(
        ["zsh", "-c", f'source "{HELPER}"; release_clean_owned_artifacts "$@"', "_", build_dir, *paths],
        capture_output=True, text=True,
    )


def owned_args(build):
    return [str(build / p) for p in OWNED]


def foreign_intact(build):
    return all((build / rel).is_file() and (build / rel).read_text() == t for rel, t in FOREIGN.items())


def main():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp).resolve()

        b = tmp / "a/build"
        make_owned(b)
        make_foreign(b)
        r = run(str(b), *owned_args(b))
        apps = [p for p in b.rglob("Batty.app")]
        expect("removes_owned_paths",
               r.returncode == 0 and not any((b / p).exists() for p in OWNED)
               and not apps and foreign_intact(b),
               r.stderr + str(apps))

        b = tmp / "b/build"
        write(b / "ui-tests/R1/xcodebuild.log", "ui log\n")
        r = run(str(b), *owned_args(b))
        expect("missing_owned_paths_ok",
               r.returncode == 0 and (b / "ui-tests/R1/xcodebuild.log").read_text() == "ui log\n", r.stderr)

        b = tmp / "c/build"
        make_owned(b)
        r = run(str(b), *owned_args(b))
        expect("removes_empty_build_dir", r.returncode == 0 and not b.exists(), r.stderr)

        b = tmp / "d/build"
        r = run(str(b), *owned_args(b))
        expect("no_build_dir", r.returncode == 0, r.stderr)

        b = tmp / "e/build"
        make_owned(b)
        r = run(str(b), str(b))
        expect("refuses_build_dir_itself",
               r.returncode != 0 and all((b / p).exists() for p in OWNED), r.stderr)

        b = tmp / "f/build"
        make_owned(b)
        elsewhere = tmp / "f/elsewhere"
        write(elsewhere / "keep")
        r1 = run(str(b), *owned_args(b), str(elsewhere))
        r2 = run(str(b), *owned_args(b), str(b) + "/../elsewhere")
        expect("refuses_outside_path",
               r1.returncode != 0 and r2.returncode != 0 and elsewhere.exists()
               and all((b / p).exists() for p in OWNED), r1.stderr + r2.stderr)

        b = tmp / "g/build"
        make_owned(b)
        r1 = run("", *owned_args(b))
        r2 = run(str(b), str(b / "Export"), "")
        expect("refuses_empty_args",
               r1.returncode != 0 and r2.returncode != 0 and (b / "Export").exists(), r1.stderr + r2.stderr)

    src = RELEASE.read_text()
    owned = re.search(r"^RELEASE_OWNED=\((.*)\)$", src, re.M)
    expect("release_sh_uses_helper",
           'rm -rf "$BUILD_DIR"' not in src
           and re.search(r'^source "\$SCRIPT_DIR/release-cleanup\.sh"$', src, re.M) is not None
           and len(re.findall(r"^\s*release_clean_owned_artifacts ", src, re.M)) == 2
           and owned is not None
           and all(f"${v}" in owned.group(1) for v in ("ARCHIVE_PATH", "EXPORT_DIR", "EXPORT_PLIST", "ENTITLEMENTS_PLIST")))

    print(f"{cases - failures}/{cases} cases ok")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
