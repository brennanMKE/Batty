#!/usr/bin/env python3
"""Packages the bundled batty-cli skill as zips and renders the public Claude
Code plugin marketplace repo contents. Run on release day from the release's
sources.

    python3 -I tools/build-agent-downloads.py [--check] [--version X.Y.Z]
        [--skill-out DIR] [--marketplace-out DIR] [--no-marketplace | --no-skill]

Writes website/docs/skill/batty-cli-skill-<V>.zip and batty-cli-skill-latest.zip
(identical bytes, stored, fixed timestamps, so a re-run gives the same bytes),
then runs the BattyAgentPackages Swift target into build/claude-marketplace/.
--check writes nothing and compares both zips with --skill-out.
--version defaults to MARKETING_VERSION in Configuration/App.xcconfig.

Never writes under website/ except --skill-out, never deploys, never runs git.
Exit codes: 0 ok, 1 drift or failure, 2 usage or bad input.
"""

import argparse
import io
import os
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SKILL_DIR = REPO / ".claude" / "skills" / "batty-cli"
APP_XCCONFIG = REPO / "Configuration" / "App.xcconfig"
CAPABILITIES = REPO / "BattyKit" / "Sources" / "batty" / "CapabilitiesCommand.swift"
LATEST_URL_TAIL = "/docs/skill/batty-cli-skill-latest.zip"
DEFAULT_SKILL_OUT = REPO / "website" / "docs" / "skill"
DEFAULT_MARKETPLACE_OUT = REPO / "build" / "claude-marketplace"
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
EPOCH = (1980, 1, 1, 0, 0, 0)
FOLDER = "batty-cli"


class InputError(Exception):
    pass


def skill_files(skill_dir=SKILL_DIR):
    skill_dir = Path(skill_dir)
    if not (skill_dir / "SKILL.md").is_file():
        raise InputError(f"{skill_dir}/SKILL.md not found")
    files = []
    for p in sorted(skill_dir.rglob("*")):
        if p.is_symlink():
            raise InputError(f"symlink in skill folder: {p}")
        if p.is_file():
            files.append((p.relative_to(skill_dir).as_posix(), p.read_bytes()))
    return files


def _info(name, mode):
    info = zipfile.ZipInfo(name, date_time=EPOCH)
    info.compress_type = zipfile.ZIP_STORED
    info.create_system = 3
    info.external_attr = mode
    return info


def skill_zip(files):
    """files: [(relative posix path, bytes)], or bytes for a lone SKILL.md."""
    if isinstance(files, (bytes, bytearray)):
        files = [("SKILL.md", bytes(files))]
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as z:
        dirs = {FOLDER + "/"}
        for rel, _ in files:
            parts = rel.split("/")[:-1]
            for i in range(1, len(parts) + 1):
                dirs.add(FOLDER + "/" + "/".join(parts[:i]) + "/")
        for d in sorted(dirs):
            z.writestr(_info(d, (0o40755 << 16) | 0x10), b"")
        for rel, data in sorted(files):
            z.writestr(_info(f"{FOLDER}/{rel}", 0o100644 << 16), data)
    return buf.getvalue()


def default_version():
    try:
        text = APP_XCCONFIG.read_text(encoding="utf-8")
    except OSError as e:
        raise InputError(f"{APP_XCCONFIG}: {e}")
    m = re.search(r"^\s*MARKETING_VERSION\s*=\s*(\S+)", text, re.M)
    if not m:
        raise InputError(f"no MARKETING_VERSION in {APP_XCCONFIG}")
    return m.group(1)


def check_url():
    try:
        text = CAPABILITIES.read_text(encoding="utf-8")
    except OSError as e:
        raise InputError(f"{CAPABILITIES}: {e}")
    if LATEST_URL_TAIL not in text:
        raise InputError(f"{CAPABILITIES.name} no longer links {LATEST_URL_TAIL}; the zip name and the URL have drifted")


def zip_names(version):
    return [f"batty-cli-skill-{version}.zip", "batty-cli-skill-latest.zip"]


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main(argv=None):
    ap = argparse.ArgumentParser(description="Package the batty-cli skill and the Claude Code marketplace.")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--version")
    ap.add_argument("--skill-out", type=Path, default=DEFAULT_SKILL_OUT)
    ap.add_argument("--marketplace-out", type=Path, default=DEFAULT_MARKETPLACE_OUT)
    group = ap.add_mutually_exclusive_group()
    group.add_argument("--no-marketplace", action="store_true")
    group.add_argument("--no-skill", action="store_true")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return 0 if e.code == 0 else 2
    try:
        version = args.version or default_version()
        if not VERSION_RE.match(version):
            raise InputError(f"bad version {version!r}; expected X.Y.Z")
        check_url()
        files = skill_files()
    except InputError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    data = skill_zip(files)
    if args.check:
        drift = False
        for name in zip_names(version):
            p = args.skill_out / name
            if not p.is_file():
                print(f"missing {name}")
                drift = True
            elif p.read_bytes() != data:
                print(f"differs {name}")
                drift = True
        if drift:
            print("run python3 -I tools/build-agent-downloads.py to regenerate", file=sys.stderr)
            return 1
        return 0

    if not args.no_skill:
        for name in zip_names(version):
            p = args.skill_out / name
            write_atomic(p, data)
            print(f"wrote {p}")
    if not args.no_marketplace:
        cmd = ["swift", "run", "--quiet", "--package-path", str(REPO / "BattyKit"), "BattyAgentPackages",
               "--skill", str(SKILL_DIR / "SKILL.md"), "--version", version, "--output", str(args.marketplace_out)]
        r = subprocess.run(cmd)
        if r.returncode != 0:
            print(f"error: BattyAgentPackages exited {r.returncode}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
