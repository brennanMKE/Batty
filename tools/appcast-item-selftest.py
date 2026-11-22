#!/usr/bin/env python3
"""Offline cases for scripts/appcast-item.sh.

    python3 -I tools/appcast-item-selftest.py [path/to/appcast-item.sh]

Builds a tiny DMG holding Fake.app/Contents/Info.plist with hdiutil and passes
`--sign-update <stub>`, a script that records its argv and prints a fixed
signature line. The Keychain is never read.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / "scripts" / "appcast-item.sh"
cases = 0

PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>9.8.7</string>
<key>CFBundleVersion</key><string>202611211200</string>
</dict></plist>
"""


def expect(name, cond, info=""):
    global cases
    cases += 1
    if not cond:
        print(f"FAIL {name}\n{info}")
        sys.exit(1)
    print(f"ok   {name}")


def main():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        src = tmp / "src"
        (src / "Fake.app" / "Contents").mkdir(parents=True)
        (src / "Fake.app" / "Contents" / "Info.plist").write_text(PLIST)
        dmg = tmp / "Fake.dmg"
        subprocess.run(["hdiutil", "create", "-quiet", "-volname", "Fake", "-srcfolder", str(src),
                        "-format", "UDZO", str(dmg)], check=True)
        size = dmg.stat().st_size
        argv_log = tmp / "argv.txt"
        stub = tmp / "sign_update"
        stub.write_text(
            "#!/bin/zsh\n"
            f"print -rl -- \"$@\" > '{argv_log}'\n"
            f"print -r -- 'sparkle:edSignature=\"U1RVQg==\" length=\"{size}\"'\n")
        stub.chmod(0o755)
        key = tmp / "ed25519.key"
        key.write_text("A" * 43 + "=")
        key.chmod(0o600)

        def run(*opts):
            argv_log.unlink(missing_ok=True)
            p = subprocess.run(["/bin/zsh", str(SCRIPT), "--sign-update", str(stub), *opts, str(dmg)],
                               capture_output=True, text=True)
            args = argv_log.read_text().splitlines() if argv_log.exists() else []
            return p, args

        p, args = run()
        expect("default_uses_keychain_account_and_site_url",
               p.returncode == 0 and args[:2] == ["--account", "Batty"]
               and 'url="https://batty.sstools.co/downloads/Batty-9.8.7.dmg"' in p.stdout
               and "<sparkle:releaseNotesLink>https://batty.sstools.co/changelog.html#v9-8-7</sparkle:releaseNotesLink>" in p.stdout
               and 'sparkle:version="202611211200"' in p.stdout,
               p.stdout + p.stderr + repr(args))

        p, args = run("--ed-key-file", str(key))
        expect("key_file_never_passes_account",
               p.returncode == 0 and "--account" not in args and args[:2] == ["--ed-key-file", str(key)]
               and 'sparkle:edSignature="U1RVQg=="' in p.stdout,
               p.stdout + p.stderr + repr(args))

        url = "http://127.0.0.1:47912/Batty-Beta-B.dmg"
        p, args = run("--ed-key-file", str(key), "--enclosure-url", url)
        expect("enclosure_url_replaces_url_and_drops_release_notes",
               p.returncode == 0 and f'url="{url}"' in p.stdout and "batty.sstools.co" not in p.stdout
               and "releaseNotesLink" not in p.stdout and "TEST" in p.stderr,
               p.stdout + p.stderr)

        p, args = run("--ed-key-file", str(tmp / "missing.key"))
        expect("missing_key_file_exits_nonzero", p.returncode != 0 and not args, p.stdout + p.stderr)

    print(f"{cases} cases passed")


if __name__ == "__main__":
    main()
