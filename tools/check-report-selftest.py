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
    ("unit rc 0, all skipped", "unit", 0, ["** TEST SUCCEEDED **"],
     {"totalTestCount": 3, "failedTests": 0, "skippedTests": 3},
     2, "CHECK UNIT: ERROR (no tests ran (3 skipped; slow tests need --full))"),
    ("ui rc 0, all skipped", "ui", 0, ["** TEST SUCCEEDED **"],
     {"totalTestCount": 3, "failedTests": 0, "skippedTests": 3},
     2, "CHECK UI: ERROR (no tests ran (3 skipped; on-request UI tests need their opt-in env, e.g. BATTY_UI_DEMO=1))"),
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

SUMMARY_106 = "\t Executed 106 tests, with 1 test skipped and 1 failure (0 unexpected) in 1859.831 (1859.883) seconds"
SUMMARY_117 = "\t Executed 117 tests, with 8 tests skipped and 0 failures (0 unexpected) in 796.353 (796.410) seconds"
SUMMARY_52 = "\t Executed 52 tests, with 2 failures (0 unexpected) in 796.682 (796.707) seconds"
SUITE_FAILED = "Test Suite 'Selected tests' failed at 2026-11-22 18:20:01.680."

# (line, expected parse_executed result)
EXECUTED_CASES = [
    (SUMMARY_106, (106, 1, 1, 0)),
    (SUMMARY_117, (117, 8, 0, 0)),
    (SUMMARY_52, (52, 0, 2, 0)),
    ("\t Executed 1 test, with 1 failure (0 unexpected) in 20.1 (20.1) seconds", (1, 0, 1, 0)),
    ("\t Executed 1 test, with 0 failures (0 unexpected) in 20.1 (20.1) seconds", (1, 0, 0, 0)),
    ("\t Executed 3 tests, with 1 failure (0 unexpected) in 20.1 (20.1) seconds", (3, 0, 1, 0)),
    ("\t Executed 4 tests, with 1 test skipped and 2 failures (0 unexpected) in 9.0 (9.1) seconds", (4, 1, 2, 0)),
    ("\t Executed 9 tests, with 2 tests skipped and 1 failure (0 unexpected) in 50.0 (50.1) seconds", (9, 2, 1, 0)),
    (SUITE_FAILED, None),
]

LOG_0722 = [
    "Test Case '-[BattyUITests.SessionReminderTests testSuggestionIsSelectedSoTypingReplacesIt]' skipped (0.055 seconds).",
    "Test Case '-[BattyUITests.TabRenameTests testRenameActiveTabUpdatesChipTitle]' failed (20.447 seconds).",
    SUITE_FAILED, SUMMARY_106, "** TEST EXECUTE FAILED **",
]

# (name, stage, rc, log lines or None for no log file, extra argv,
#  expected code, expected last line, substrings the output must contain,
#  substrings it must not contain[, xcresult summary stub])
UI_CASES = [
    ("ui rc 65, no xcresult, skipped-and-failed summary (#0722)", "ui", 65, LOG_0722, [],
     1, "CHECK UI: FAILED (1 test, 0 compile errors)", ["==> ui: 106 tests, 1 failed, 1 skipped"], []),
    ("ui rc 65, no xcresult, summary count only", "ui", 65,
     [l for l in LOG_0722 if "failed (" not in l], [],
     1, "CHECK UI: FAILED (1 test, 0 compile errors)", [], []),
    ("ui rc 0, no xcresult, skipped and 0 failures", "ui", 0,
     [SUMMARY_117, "** TEST EXECUTE SUCCEEDED **"], [],
     0, "CHECK UI: PASSED (117 tests)", ["8 skipped"], []),
    ("ui rc 65, no xcresult, plain 2 failures", "ui", 65,
     [SUMMARY_52, "** TEST EXECUTE FAILED **"], [],
     1, "CHECK UI: FAILED (2 tests, 0 compile errors)", [], []),
    ("ui rc 65, log and xcresult not retrieved", "ui", 65, None,
     ["--missing", "xcodebuild.log", "--missing", "UITests.xcresult"],
     2, "CHECK UI: ERROR (results not retrieved from guest: xcodebuild.log, UITests.xcresult)",
     ["==> not retrieved from the guest:"], ["No tests ran"]),
    ("ui rc 65, xcresult not retrieved, log has the failure", "ui", 65, LOG_0722,
     ["--missing", "UITests.xcresult"],
     1, "CHECK UI: FAILED (1 test, 0 compile errors)", ["not retrieved from the guest: UITests.xcresult"], []),
    ("ui rc 65, xcresult not retrieved, truncated log", "ui", 65,
     ["Test Case '-[BattyUITests.TabRenameTests testA]' started."], ["--missing", "UITests.xcresult"],
     2, "CHECK UI: ERROR (results not retrieved from guest: UITests.xcresult)", [], []),
    ("ui rc 65, build log only, build failed", "ui", 65,
     ["/x/A.swift:8:31: error: cannot convert value", "** TEST BUILD FAILED **"], [],
     1, "CHECK UI: FAILED (0 tests, 1 compile error)", [], []),
    # The runner passes --missing for a pass that failed twice even when it left
    # a partial file on disk.
    ("ui rc 0, logs pass failed, partial xcodebuild.log", "ui", 0,
     ["Test Case '-[BattyUITests.TabRenameTests testA]' started."], ["--missing", "xcodebuild.log"],
     2, "CHECK UI: ERROR (results not retrieved from guest: xcodebuild.log)",
     ["==> not retrieved from the guest: xcodebuild.log"], ["No tests ran"]),
    ("ui rc 65, bundle pass failed, partial bundle not read", "ui", 65, LOG_0722,
     ["--missing", "UITests.xcresult"],
     1, "CHECK UI: FAILED (1 test, 0 compile errors)",
     ["==> ui: 106 tests, 1 failed, 1 skipped", "not retrieved from the guest: UITests.xcresult"], [],
     {"totalTestCount": 3, "failedTests": 0, "skippedTests": 0, "testFailures": []}),
]


def run(stage, rc, lines, summary, workdir, extra_argv=()):
    log = Path(workdir) / ("xcodebuild.log" if lines is None else f"{stage}-case.log")
    if lines is not None:
        log.write_text("\n".join(lines) + "\n")
    cr.read_xcresult = lambda path: summary if path else None
    argv = ["check-report.py", "--stage", stage, "--log", str(log), "--rc", str(rc), *extra_argv]
    if summary is not None:
        argv += ["--xcresult", str(Path(workdir) / "UITests.xcresult")]
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
    for line, want in EXECUTED_CASES:
        got = cr.parse_executed(line)
        ok = got == want
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} parse_executed {line.strip()[:60]!r}" +
              ("" if ok else f": got {got}, want {want}"))
    for name, stage, rc, lines, extra, want_code, want_last, must, must_not, *stub in UI_CASES:
        with tempfile.TemporaryDirectory() as workdir:
            code, out = run(stage, rc, lines, stub[0] if stub else None, workdir, extra)
        last = out[-1] if out else ""
        text = "\n".join(out)
        ok = (code == want_code and last == want_last
              and all(m in text for m in must) and not any(m in text for m in must_not))
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name}" +
              ("" if ok else f": got exit {code}, {last!r}; want exit {want_code}, {want_last!r}\n{text}"))
    total = len(CASES) + len(EXECUTED_CASES) + len(UI_CASES)
    print(f"{total - failures}/{total} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
