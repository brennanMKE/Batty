#!/usr/bin/env python3
"""Offline classification cases for tools/check-report.py.

    python3 tools/check-report-selftest.py

Each case writes a tiny log, stubs the .xcresult summary, runs check-report's
main() and checks the exit code and the final CHECK line. No Xcode, no git, no
network (the Haiku summary is disabled).
"""

import contextlib
import importlib.util
import io
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("check_report", HERE / "check-report.py")
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)

RUNTIME_NOISE = [
    "2026-10-19 14:42:30.123 xctest[123:456] Underlying error: Error Domain=NSCocoaErrorDomain Code=4",
    "error: The data couldn't be read because it isn't in the correct format.",
    "error: Error Domain=NSPOSIXErrorDomain Code=2",
    "** TEST SUCCEEDED **",
]
PASS_2588 = {"totalTestCount": 2588, "failedTests": 0, "skippedTests": 0}

# (name, stage, rc, log lines, xcresult summary or None, expected code, expected last line)
CASES = [
    ("unit rc 0, all passed, runtime error lines", "unit", 0, RUNTIME_NOISE, PASS_2588,
     0, "CHECK UNIT: PASSED (2588 tests)"),
    ("unit rc 0, no xcresult, log claims a failure", "unit", 0,
     ["✘ Test foo() recorded an issue at A.swift:1:2: Expectation failed",
      "✔ Test run with 3 tests passed after 0.1 seconds."], None,
     0, "CHECK UNIT: PASSED (3 tests)"),
    ("unit rc 65, one failing test", "unit", 65, ["** TEST FAILED **"],
     {"totalTestCount": 5, "failedTests": 1, "skippedTests": 0,
      "testFailures": [{"testName": "t()", "targetName": "K", "failureText": "1 == 2"}]},
     1, "CHECK UNIT: FAILED (1 test, 0 compile errors)"),
    ("unit rc 65, compile error", "unit", 65,
     ["/x/A.swift:8:31: error: cannot convert value", "** TEST BUILD FAILED **"], None,
     1, "CHECK UNIT: FAILED (0 tests, 1 compile error)"),
    ("unit rc 65, build failed without an error line", "unit", 65,
     ["The following build commands failed:", "\tLd /x/Batty normal", "", "** TEST BUILD FAILED **"], None,
     1, "CHECK UNIT: FAILED (build failed)"),
    ("unit rc 0, zero tests", "unit", 0, ["** TEST SUCCEEDED **"],
     {"totalTestCount": 0, "failedTests": 0, "skippedTests": 0},
     2, "CHECK UNIT: ERROR (no tests ran)"),
    ("unit rc 70, no summary", "unit", 70, ["xcodebuild: something odd"], None,
     2, "CHECK UNIT: ERROR (no tests ran)"),
    ("unit rc 130", "unit", 130, ["Testing started"], None,
     2, "CHECK UNIT: ERROR (interrupted)"),
    ("build rc 0 with an error-looking line", "build", 0,
     ["error: The data couldn't be read.", "** BUILD SUCCEEDED **"], None,
     0, "CHECK BUILD: PASSED"),
    ("build rc 65, compile error", "build", 65,
     ["/x/A.swift:8:31: error: cannot convert value", "** BUILD FAILED **"], None,
     1, "CHECK BUILD: FAILED (1 compile error)"),
    ("build rc 1, no error line", "build", 1, ["** BUILD FAILED **"], None,
     1, "CHECK BUILD: FAILED (xcodebuild exit 1)"),
    ("ui-typecheck rc 1, relative path", "ui-typecheck", 1,
     ["BattyUITests/A.swift:3:4: error: cannot find 'x' in scope"], None,
     1, "CHECK UI-TYPECHECK: FAILED (1 compile error)"),
    ("ui-typecheck rc 0", "ui-typecheck", 0, [], None,
     0, "CHECK UI-TYPECHECK: PASSED"),
]


def run(stage, rc, lines, summary, workdir):
    log = Path(workdir) / f"{stage}-case.log"
    log.write_text("\n".join(lines) + "\n")
    cr.read_xcresult = lambda _path: summary
    argv = ["check-report.py", "--stage", stage, "--log", str(log), "--rc", str(rc)]
    if summary is not None:
        argv += ["--xcresult", str(Path(workdir) / "stub.xcresult")]
    out = io.StringIO()
    saved = sys.argv
    sys.argv = argv
    try:
        with contextlib.redirect_stdout(out):
            code = cr.main()
    finally:
        sys.argv = saved
    return code, out.getvalue().rstrip("\n").splitlines()


def main():
    os.environ["BATTY_CHECK_SUMMARY"] = "0"
    failures = 0
    for name, stage, rc, lines, summary, want_code, want_last in CASES:
        with tempfile.TemporaryDirectory() as workdir:
            code, out = run(stage, rc, lines, summary, workdir)
        last = out[-1] if out else ""
        ok = code == want_code and last == want_last
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name}" +
              ("" if ok else f": got exit {code}, {last!r}; want exit {want_code}, {want_last!r}"))
    print(f"{len(CASES) - failures}/{len(CASES)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
