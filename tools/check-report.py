#!/usr/bin/env python3
"""Classify a captured build/test log and print a short tail.

Used by build.sh (build, unit, ui-typecheck) and tools/run-ui-tests-vm.sh (ui).
The full tool output stays in the log file; stdout gets at most a failure
block, a counts line, a duration/log line and a final ALL-CAPS line:

    CHECK <STAGE>: PASSED|FAILED|ERROR [(detail)]

Exit codes: 0 passed, 1 build or test failure, 2 could not run (no tests ran,
no test summary, interrupted).

The outcome comes only from the tool's exit status and, for unit/ui, the
.xcresult test counts. Log patterns only label the failure and build the
digest: test logs carry runtime "error:" lines on passing runs, and neither
xcodebuild nor swiftc exits 0 after a compile error, so error lines are not
counted at all when the exit status is 0.
tools/check-report-selftest.py runs the classification cases offline.

On FAILED a digest of the relevant lines is written to <log>.failures.txt and
summarized by `claude -p --model haiku` (BATTY_CHECK_SUMMARY=0 disables;
BATTY_CHECK_SUMMARY_TIMEOUT sets the timeout, default 90 s). The exit code and
the final line never depend on that summary.

    tools/check-report.py --stage {build,unit,ui-typecheck,ui} --log PATH --rc N
                          [--xcresult PATH] [--duration SECS]
"""

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

DIGEST_PRINT_CAP = 60
SUMMARY_PRINT_CAP = 40
LINE_CAP = 300
KEEP_RUNS = 10

# swiftc prints absolute paths under xcodebuild and repo-relative ones when
# invoked directly (ui-typecheck), so both forms count.
LOCATED_ERROR = re.compile(r"^([^\s:][^:]*):(\d+):(\d+): (?:fatal )?error: (.+)$")
OTHER_ERROR = re.compile(
    r"^(?:(?:ld|ld64\.lld|clang|swiftc|swift-frontend|swift-driver|xcodebuild|xcrun|libtool|codesign)"
    r"(?:\[\d+\])?: )?(?:fatal )?error: ")
LOCATED_WARNING = re.compile(r"^([^\s:][^:]*):\d+:\d+: warning: .+$")
ST_ISSUE = re.compile(r"^✘ Test (.+?) recorded an issue at (\S+?):(\d+):\d+: (.+)$")
ST_RUN = re.compile(r"^[✔✘] Test run with (\d+) tests?.*?(passed|failed)")
XC_EXECUTED = re.compile(r"Executed (\d+) tests?, with (\d+) failures?")
XC_CASE_FAILED = re.compile(r"Test Case '(.+?)' failed")
FALLBACK_HINT = re.compile(r"error|failed|cannot|unable|denied|not found", re.I)
# Simulator and Xcode-internal chatter that matches FALLBACK_HINT on every run.
FALLBACK_NOISE = re.compile(r"DVTErrorPresenter|CoreSimulator|simdiskimaged|IDERunDestination|DVTDeviceOperation")
BUILD_FAILED_MARKER = re.compile(r"\*\* (?:TEST )?BUILD FAILED \*\*|The following build commands failed:")
# Framing lines inside the "The following build commands failed:" block.
FAILED_COMMANDS_FRAMING = re.compile(r"^(Building (workspace|project) |\(\d+ failures?\)$)")

PROMPT = (
    "You are summarizing a failed build or test run of Batty, a macOS Swift app, "
    "for the engineer who has to fix it. Standard input holds the error lines "
    "extracted from the log (compile errors as file:line:col, failing tests with "
    "their assertion text, and warnings in changed files). For each distinct "
    "failure write exactly one bullet: `- <test name or file:line> — <likely cause, "
    "one line> — evidence: \"<shortest quoted fragment of the input line>\"`. Merge "
    "failures that share one cause into one bullet that lists every test or "
    "location. Use only what the input shows; do not guess at code you cannot see, "
    "suggest refactors, or add any introduction or closing text. At most 15 bullets."
)


def git(cwd, *args):
    try:
        out = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    except OSError:
        return None
    return out.stdout.strip() if out.returncode == 0 else None


def plural(n, word):
    return f"{n} {word}" if n == 1 else f"{n} {word}s"


def dedupe(lines):
    seen, out = set(), []
    for line in lines:
        line = line[:LINE_CAP]
        if line not in seen:
            seen.add(line)
            out.append(line)
    return out


def changed_files(root):
    if root is None:
        return set()
    names = set()
    if git(root, "rev-parse", "--verify", "-q", "main") is not None:
        names.update((git(root, "diff", "--name-only", "main...HEAD") or "").splitlines())
    names.update((git(root, "diff", "--name-only", "HEAD") or "").splitlines())
    names.update((git(root, "ls-files", "--others", "--exclude-standard") or "").splitlines())
    return {n for n in names if n}


def read_xcresult(path):
    if not path or not Path(path).exists():
        return None
    try:
        out = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", path, "--compact"],
            capture_output=True, text=True, timeout=120,
        )
        if out.returncode != 0:
            return None
        return json.loads(out.stdout)
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        return None


def parse(log_lines, stage, xcresult, root, rc):
    compile_errors, seen_keys, located_lines = [], set(), set()
    error_lines = log_lines if rc != 0 else []
    for line in error_lines:
        m = LOCATED_ERROR.match(line)
        if m:
            key = (m.group(1), m.group(2), m.group(4))
            if key not in seen_keys:
                seen_keys.add(key)
                compile_errors.append(line)
            located_lines.add(line)
    other_seen = set()
    for line in error_lines:
        if line in located_lines or LOCATED_ERROR.match(line) or LOCATED_WARNING.match(line):
            continue
        if ST_ISSUE.match(line):
            continue
        if OTHER_ERROR.search(line):
            s = line.strip()
            if s not in other_seen:
                other_seen.add(s)
                compile_errors.append(s)

    build_failed = rc != 0 and any(BUILD_FAILED_MARKER.search(l) for l in log_lines)
    failed_commands = []
    for i, line in enumerate(error_lines):
        if "The following build commands failed:" in line:
            for follow in error_lines[i + 1:i + 11]:
                if not follow.strip():
                    break
                if FAILED_COMMANDS_FRAMING.match(follow.strip()):
                    continue
                failed_commands.append(follow.strip())
            break

    tests = {"total": None, "failed": 0, "skipped": 0, "failures": [], "from_xcresult": False}
    st_issues = []
    for line in log_lines:
        m = ST_ISSUE.match(line)
        if m:
            st_issues.append((m.group(1), line))

    if stage in ("unit", "ui"):
        summary = read_xcresult(xcresult)
        if summary is not None:
            tests["from_xcresult"] = True
            tests["total"] = summary.get("totalTestCount", 0)
            tests["failed"] = summary.get("failedTests", 0)
            tests["skipped"] = summary.get("skippedTests", 0)
            for f in summary.get("testFailures", []) or []:
                ident = f.get("testIdentifierString") or f.get("testName", "?")
                tests["failures"].append(
                    (f.get("testName", ident),
                     f"{f.get('targetName', '?')}/{ident}: {' '.join((f.get('failureText') or '').split())}")
                )
        else:
            for line in log_lines:
                m = ST_RUN.match(line)
                if m:
                    tests["total"] = int(m.group(1))
            executed = None
            for line in log_lines:
                m = XC_EXECUTED.search(line)
                if m:
                    executed = (int(m.group(1)), int(m.group(2)))
            if executed and tests["total"] is None:
                tests["total"] = executed[0]
            names = []
            for name, line in st_issues:
                if name not in names:
                    names.append(name)
                    tests["failures"].append((name, line))
            for line in log_lines:
                m = XC_CASE_FAILED.search(line)
                if m and m.group(1) not in names:
                    names.append(m.group(1))
                    tests["failures"].append((m.group(1), line.strip()))
            tests["failed"] = len(names) or (executed[1] if executed else 0)

    changed = changed_files(root)
    warnings, all_warning_count = [], 0
    for line in log_lines:
        m = LOCATED_WARNING.match(line)
        if not m:
            continue
        all_warning_count += 1
        path = m.group(1)
        if root and os.path.isabs(path):
            rel = os.path.relpath(path, root)
        else:
            rel = os.path.normpath(path)
        if rel in changed:
            warnings.append(line)
    warnings = dedupe(warnings)

    return compile_errors, failed_commands, tests, st_issues, warnings, build_failed


def classify(stage, rc, compile_errors, tests, build_failed=False):
    """Decide the outcome from rc and test counts; compile_errors only labels it."""
    n_err = len(compile_errors)
    if stage not in ("unit", "ui"):
        if rc == 0:
            return "PASSED", None, 0
        if rc in (129, 130, 143) and n_err == 0:
            return "ERROR", "interrupted", 2
        if n_err:
            return "FAILED", plural(n_err, "compile error"), 1
        return "FAILED", f"{'xcodebuild' if stage == 'build' else 'swiftc'} exit {rc}", 1
    total = tests["total"] or 0
    failed = tests["failed"]
    # Without an .xcresult the counts come from the log, which cannot
    # overrule a zero exit status.
    if failed and (rc != 0 or tests["from_xcresult"]):
        return "FAILED", f"{plural(failed, 'test')}, {plural(n_err, 'compile error')}", 1
    if rc == 0:
        if total == 0:
            return "ERROR", "no tests ran", 2
        return "PASSED", plural(total, "test"), 0
    if rc in (129, 130, 143) and n_err == 0:
        return "ERROR", "interrupted", 2
    if n_err or build_failed:
        return "FAILED", f"0 tests, {plural(n_err, 'compile error')}" if n_err else "build failed", 1
    if total == 0:
        return "ERROR", "no tests ran", 2
    return "ERROR", f"exit {rc}, no test summary", 2


def build_digest(compile_errors, failed_commands, tests, st_issues, warnings, log_lines):
    # The failed-command list only adds evidence when no error line was found
    # (linker, signing, script phases); otherwise it repeats the compile errors.
    lines = list(compile_errors) + ([] if compile_errors else list(failed_commands))
    for name, line in tests["failures"]:
        lines.append(line)
        base = name.split("/")[-1]
        for st_name, st_line in st_issues:
            if st_line != line and (st_name == name or st_name == base or base in st_name):
                lines.append("    " + st_line)
    lines += warnings
    return dedupe(lines)


def fallback_digest(log_lines):
    nonblank = [l for l in log_lines
                if l.strip() and not l[0].isspace() and not FALLBACK_NOISE.search(l)]
    hits = [l for l in nonblank if FALLBACK_HINT.search(l)]
    return dedupe(hits[-15:] if hits else nonblank[-5:])


def shared_root(root):
    if root is None:
        return None
    common = git(root, "rev-parse", "--path-format=absolute", "--git-common-dir")
    return Path(common).parent if common else Path(root)


def haiku_summary(digest_text, stage, log_path, root):
    if os.environ.get("BATTY_CHECK_SUMMARY", "1") == "0":
        return None, "disabled"
    claude = shutil.which("claude")
    if claude is None:
        return None, "claude not found"
    try:
        timeout = float(os.environ.get("BATTY_CHECK_SUMMARY_TIMEOUT", "90"))
    except ValueError:
        timeout = 90.0
    env = dict(os.environ)
    env.pop("CLAUDECODE", None)
    workdir = tempfile.mkdtemp(prefix="batty-check-")
    try:
        proc = subprocess.run(
            [claude, "-p", PROMPT, "--model", "haiku", "--output-format", "json",
             "--tools", "", "--no-session-persistence"],
            input=digest_text, capture_output=True, text=True, timeout=timeout,
            cwd=workdir, env=env,
        )
    except subprocess.TimeoutExpired:
        return None, f"timed out after {int(timeout)}s"
    except OSError as e:
        return None, f"could not run claude: {e}"
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None, f"claude exit {proc.returncode}, no JSON"
    if not isinstance(data, dict):
        return None, "unexpected JSON"
    ok = proc.returncode == 0 and not data.get("is_error") and bool((data.get("result") or "").strip())
    record_usage(data, ok, stage, log_path, root)
    if not ok:
        return None, f"claude exit {proc.returncode}" + (", is_error" if data.get("is_error") else "")
    return data["result"].strip(), None


def record_usage(data, ok, stage, log_path, root):
    base = shared_root(root)
    if base is None:
        return
    model_usage = data.get("modelUsage") or {}
    record = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "stage": stage,
        "log": str(Path(log_path).resolve()),
        "worktree": str(root),
        "ok": ok,
        "cost_usd": data.get("total_cost_usd", 0),
        "duration_ms": data.get("duration_ms"),
        "usage": data.get("usage"),
        "model": next(iter(model_usage), "haiku"),
    }
    try:
        out_dir = base / "build" / "checks"
        out_dir.mkdir(parents=True, exist_ok=True)
        with open(out_dir / "haiku-usage.jsonl", "a") as f:
            f.write(json.dumps(record) + "\n")
    except OSError:
        pass


def prune(log_path, stage):
    directory = Path(log_path).parent
    runs = sorted(directory.glob(f"{stage}-*.log"), key=lambda p: p.stat().st_mtime, reverse=True)
    for old in runs[KEEP_RUNS:]:
        old.unlink(missing_ok=True)
        Path(str(old) + ".failures.txt").unlink(missing_ok=True)
    bundles = sorted(directory.glob(f"{stage}-*.xcresult"), key=lambda p: p.stat().st_mtime, reverse=True)
    for old in bundles[KEEP_RUNS:]:
        shutil.rmtree(old, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", required=True, choices=["build", "unit", "ui-typecheck", "ui"])
    ap.add_argument("--log", required=True)
    ap.add_argument("--rc", required=True, type=int)
    ap.add_argument("--xcresult")
    ap.add_argument("--duration", type=float)
    args = ap.parse_args()

    log_path = Path(args.log)
    try:
        log_lines = log_path.read_text(errors="replace").splitlines()
    except OSError:
        log_lines = []
    root_s = git(log_path.parent.resolve() if log_path.parent.exists() else Path.cwd(),
                 "rev-parse", "--show-toplevel")
    root = Path(root_s) if root_s else None

    compile_errors, failed_commands, tests, st_issues, warnings, build_failed = parse(
        log_lines, args.stage, args.xcresult, root, args.rc)
    outcome, detail, code = classify(args.stage, args.rc, compile_errors, tests, build_failed)

    def rel(p):
        try:
            return os.path.relpath(Path(p).resolve(), root) if root else str(p)
        except ValueError:
            return str(p)

    stage_upper = args.stage.upper()
    out = []
    failures_path = Path(str(log_path) + ".failures.txt")
    if outcome != "PASSED":
        digest = build_digest(compile_errors, failed_commands, tests, st_issues, warnings, log_lines)
        if detail == "no tests ran":
            digest.insert(0, "No tests ran: the test filter matched nothing, or the test bundle never executed.")
        elif not digest:
            digest = fallback_digest(log_lines)
        try:
            failures_path.write_text("\n".join(digest) + "\n")
        except OSError:
            pass
        capped = digest[:DIGEST_PRINT_CAP]
        more = len(digest) - len(capped)
        summary, reason = (None, None)
        if outcome == "FAILED":
            summary, reason = haiku_summary("\n".join(capped) + "\n", args.stage, log_path, root)
        if summary is not None:
            out.append(f"==> failure summary (haiku; raw digest: {rel(failures_path)})")
            out += summary.splitlines()[:SUMMARY_PRINT_CAP]
        else:
            if outcome == "FAILED":
                out.append(f"==> haiku summary unavailable ({reason}); raw digest:")
            else:
                out.append("==> digest:")
            out += capped
            if more > 0:
                out.append(f"… {more} more lines in {rel(failures_path)}")

    warn = f"{plural(len(warnings), 'warning')} in changed files"
    errs = plural(len(compile_errors), "compile error")
    if args.stage in ("unit", "ui"):
        total = tests["total"] or 0
        out.append(f"==> {args.stage}: {plural(total, 'test')}, {tests['failed']} failed, "
                   f"{tests['skipped']} skipped; {errs}; {warn}")
    else:
        out.append(f"==> {args.stage}: {errs}; {warn}")
    tail = f"==> {args.duration:.0f}s · " if args.duration is not None else "==> "
    tail += f"log {rel(log_path)}"
    if outcome != "PASSED":
        tail += f" · digest {rel(failures_path)}"
    out.append(tail)
    out.append(f"CHECK {stage_upper}: {outcome}" + (f" ({detail})" if detail else ""))

    print("\n".join(out), flush=True)
    try:
        prune(log_path, args.stage)
    except OSError:
        pass
    return code


if __name__ == "__main__":
    sys.exit(main())
