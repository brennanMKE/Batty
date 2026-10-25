#!/usr/bin/env python3
"""Offline classification cases for tools/worklog.py.

    python3 tools/worklog-selftest.py [path/to/worklog.py]

Checks check_stage / command_stages on plain command strings and measure() on
one-call synthetic transcripts. No real runs, no git, no network.
"""

import importlib.util
import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
target = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "worklog.py"
spec = importlib.util.spec_from_file_location("worklog", target)
wl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wl)

# (name, command, expected check_stage, expected command_stages)
COMMAND_CASES = [
    ("bare build", "./build.sh", "build", {"BUILD"}),
    ("unit piped", "./build.sh unit 2>&1 | tail -40", "unit", {"UNIT"}),
    ("bare build, 2>&1 piped", "./build.sh 2>&1 | tail -20", "build", {"BUILD"}),
    ("bare build, redirected to file", "./build.sh > /tmp/b.log 2>&1; tail -3 /tmp/b.log", "build", {"BUILD"}),
    ("bare build, appended", "./build.sh >> x.log", "build", {"BUILD"}),
    ("bare build, tee", "./build.sh | tee x", "build", {"BUILD"}),
    ("verbose build piped", "./build.sh --verbose 2>&1 | tail", "build", {"BUILD"}),
    ("cd prefix, piped", "cd /x && ./build.sh 2>&1 | tail", "build", {"BUILD"}),
    ("env prefix, piped", "BATTY_CHECK_SUMMARY=0 ./build.sh 2>&1 | tail", "build", {"BUILD"}),
    ("ui-typecheck piped", "./build.sh ui-typecheck 2>&1 | tail", "build", {"UI-TYPECHECK"}),
    ("package is not a check", "./build.sh package", None, set()),
    ("release is not a check", "./build.sh release archive", None, set()),
    ("digit argument is not a redirection", "./build.sh 2 foo", None, set()),
    ("grep of the runner is not a run", "grep -n run-ui-tests-vm.sh tools/README.md", None, set()),
    ("heredoc echo of unit", "cat <<'EOF'\n./build.sh unit\nEOF", None, set()),
    ("heredoc then real unit", "cat > notes.md <<'EOF'\ntools/run-ui-tests-vm.sh\nEOF\n./build.sh unit",
     "unit", {"UNIT"}),
    ("tab-stripped heredoc", 'cat <<-"EOF"\n\t./build.sh unit\n\tEOF\n./build.sh', "build", {"BUILD"}),
    ("commit message via $(cat <<EOF)", "git commit -m \"$(cat <<'EOF'\n#0532 x\n./build.sh unit\nEOF\n)\"",
     None, set()),
    ("here-string is not a heredoc", "cat <<< x; ./build.sh unit", "unit", {"UNIT"}),
]

ROW1 = "cat > notes.md <<'EOF'\ntools/run-ui-tests-vm.sh BattyUITests/Foo\nEOF"
ROW2 = "git commit -q -F - <<'EOF'\n#0531 x\ntools/run-ui-tests-vm.sh BattyUITests/Foo\nEOF\n./build.sh unit"
ROW3 = "cat > notes.md <<'EOF'\ntools/run-ui-tests-vm.sh\nEOF\n./build.sh unit"
ROW4 = "cat <<'EOF'\n./build.sh unit\nEOF"
BG = "Command running in background with ID: abc"
VM = "tools/run-ui-tests-vm.sh BattyUITests/Foo"

# (name, command, tool_result text, background, expected subset of measure())
TRANSCRIPT_CASES = [
    ("piped bare build counts", "./build.sh 2>&1 | tail -20", "CHECK BUILD: PASSED (40s)", False,
     {"build_runs": 1}),
    ("redirected bare build counts", "./build.sh > /tmp/b.log 2>&1; tail -3 /tmp/b.log",
     "CHECK BUILD: PASSED (40s)", False, {"build_runs": 1}),
    ("heredoc runner mention in background is not a UI run", ROW1, BG, True,
     {"vm_runs": 0, "vm_background": 0}),
    ("commit heredoc does not hide a real unit run", ROW2, "CHECK UNIT: PASSED (25s)", False,
     {"unit_runs": 1, "vm_runs": 0}),
    ("unit output's Executed line is not a UI run", ROW3, "Executed 412 tests, with 0 failures\nCHECK UNIT: PASSED",
     False, {"vm_runs": 0, "unit_runs": 1}),
    ("heredoc echo of a saved log is not a unit run", ROW4, "./build.sh unit\nCHECK UNIT: PASSED (25s)", False,
     {"unit_runs": 0}),
    ("real background VM run still counts", VM, BG, True, {"vm_runs": 1}),
    ("real foreground VM run still counts", VM, "==> RESULT: PASS\nCHECK UI: PASSED", False, {"vm_runs": 1}),
    ("unit and VM in one foreground call count both", "./build.sh unit && " + VM,
     "CHECK UNIT: PASSED (25s)\nCHECK UI: PASSED", False, {"unit_runs": 1, "vm_runs": 1}),
]


def transcript(directory, name, command, result, background):
    entries = [
        {"type": "assistant", "timestamp": "2026-10-24T10:00:00Z",
         "message": {"content": [{"type": "tool_use", "id": "t1", "name": "Bash",
                                  "input": {"command": command, "run_in_background": background}}]}},
        {"type": "user", "timestamp": "2026-10-24T10:01:00Z",
         "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": result}]}},
    ]
    if background:
        entries.append({"type": "user", "timestamp": "2026-10-24T10:10:00Z",
                        "message": {"content": [{"type": "text", "text": "<task-id>abc</task-id> completed"}]}})
    path = Path(directory) / f"case-{abs(hash(name))}.jsonl"
    path.write_text("".join(json.dumps(e) + "\n" for e in entries))
    return path


def main():
    passed = total = 0
    for name, command, stage, stages in COMMAND_CASES:
        total += 1
        got = (wl.check_stage(command), wl.command_stages(command))
        if got == (stage, stages):
            passed += 1
            print(f"ok   {name}")
        else:
            print(f"FAIL {name}: got {got}; want {(stage, stages)}")
    with tempfile.TemporaryDirectory() as directory:
        for name, command, result, background, want in TRANSCRIPT_CASES:
            total += 1
            m = wl.measure(transcript(directory, name, command, result, background), {})
            got = {k: m[k] for k in want}
            if got == want:
                passed += 1
                print(f"ok   {name}")
            else:
                print(f"FAIL {name}: got {got}; want {want}")
    print(f"{passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
