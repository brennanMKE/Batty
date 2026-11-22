#!/usr/bin/env python3
"""Offline cases for tools/sparkle-update-check.py.

    python3 -I tools/sparkle-update-check-selftest.py [path/to/sparkle-update-check.py]

Builds baseline/after/logs fixtures in temporary folders. No VM, no network.
"""

import contextlib
import copy
import importlib.util
import io
import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
target = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "sparkle-update-check.py"
spec = importlib.util.spec_from_file_location("sparkle_update_check", target)
suc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suc)

TRIGGER = "2026-11-21 10:00:00"
B_HASH = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
A_HASH = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HOST = 500
cases = 0

LAYOUT = {
    "schema": 1,
    "windows": [{
        "id": "W1", "frame": {"x": 0, "y": 0, "width": 800, "height": 600}, "selectedSessionID": "S1",
        "sessions": [
            {"id": "S1", "title": "SparkleTest", "focusedPaneID": "P1", "projectID": "PR1",
             "projectSymbol": "hammer", "projectSymbolName": None,
             "background": {"image": "bg.png", "opacity": 0.3, "terminalOpacity": 0.7},
             "layout": {"split": {"id": "X1", "direction": "horizontal", "ratio": 0.5,
                                  "first": {"pane": {"_0": {"id": "P1", "isHidden": False, "activeTabID": "T1",
                                                             "tabs": [{"id": "T1"}, {"id": "T2"}]}}},
                                  "second": {"pane": {"_0": {"id": "P2", "isHidden": False, "activeTabID": "T3",
                                                              "tabs": [{"id": "T3"}]}}}}}},
            {"id": "S2", "title": "s2", "focusedPaneID": "P3",
             "layout": {"pane": {"_0": {"id": "P3", "isHidden": False, "activeTabID": "T4",
                                         "tabs": [{"id": "T4"}, {"id": "T5"}]}}}},
        ],
    }],
}


def ps_row(pid, ppid, stat, tty, comm):
    return f"{pid:>5} {ppid:>5} {pid:>5} {stat:<4} {tty:<8} Sat Nov 21 09:59:00 2026 {comm}"


BASE_PS = [
    ps_row(1, 0, "Ss", "??", "/sbin/launchd"),
    ps_row(HOST, 1, "Ss", "??", "/Applications/Batty Beta.app/Contents/Resources/bin/BattyHost"),
    ps_row(601, HOST, "Ss", "ttys001", "/bin/zsh"),
    ps_row(602, HOST, "Ss", "ttys002", "/bin/zsh"),
    ps_row(603, 602, "S", "ttys002", "sleep"),
    ps_row(700, 1, "S", "??", "/Applications/Batty Beta.app/Contents/MacOS/Batty Beta"),
]


def write_snapshot(d, app_pid, version, hosts, ps, counter, final=None):
    d.mkdir(parents=True)
    (d / "terminal-layout.json").write_text(json.dumps(LAYOUT))
    (d / "topology.json").write_text("{}")
    (d / "app.txt").write_text(f"pid={app_pid}\nversion={version}\n")
    (d / "host.txt").write_text("".join(f"pid={p}\nExecutable=/x/BattyHost\nCDHash={h}\n" for p, h in hosts))
    (d / "ps.txt").write_text("\n".join(ps) + "\n")
    (d / "counter.txt").write_text("".join(f"{i}\n" for i in range(1, counter + 1)))
    if final is not None:
        (d / "counter-final.txt").write_text("".join(f"{i}\n" for i in final))
    (d / "pids").mkdir()
    (d / "pids" / "counter").write_text("602\n")
    (d / "pids" / "p1b").write_text("601\n")


def build(tmp, mutate=None):
    root = Path(tmp)
    spec_ = {
        "after_ps": list(BASE_PS[:-1]) + [ps_row(800, 1, "S", "??", "/Applications/Batty Beta.app/Contents/MacOS/Batty Beta")],
        "after_hosts": [(HOST, B_HASH)],
        "after_layout": copy.deepcopy(LAYOUT),
        "final": list(range(1, 21)),
        "logs": [f"2026-11-21 10:00:30.000 I  Batty Beta[800:1] [co.sstools.Batty.beta:HostRestore] restore: tabs=5 attach=5 exited=0 fresh=0 placed=5 helperSessions=5"],
        "write_after": True,
        "after_app": (800, "101"),
        "crash": None,
    }
    if mutate:
        mutate(spec_)
    write_snapshot(root / "baseline", 700, "100", [(HOST, A_HASH)], BASE_PS, 5)
    if spec_["write_after"]:
        write_snapshot(root / "after", *spec_["after_app"], spec_["after_hosts"], spec_["after_ps"], 10, spec_["final"])
        (root / "after" / "terminal-layout.json").write_text(json.dumps(spec_["after_layout"]))
    (root / "logs").mkdir()
    if spec_["crash"]:
        (root / "crashes").mkdir()
        (root / "crashes" / spec_["crash"]).write_text("{}")
    (root / "logs" / "restore.log").write_text(
        "2026-11-21 09:50:00.000 I  Batty Beta[700:1] restore: tabs=0 attach=0 exited=0 fresh=0\n"
        + "\n".join(spec_["logs"]) + "\n")
    return root


def run(mutate=None):
    with tempfile.TemporaryDirectory() as tmp:
        root = build(tmp, mutate)
        out, err = io.StringIO(), io.StringIO()
        argv = ["--mode", "relaunch", "--baseline", str(root / "baseline"), "--after", str(root / "after"),
                "--logs", str(root / "logs"), "--expect-build", "101", "--b-host-cdhash", B_HASH,
                "--trigger-time", TRIGGER, "--out", str(root / "out")]
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = suc.main(argv)
        checks = json.loads((root / "out" / "checks.json").read_text()) if (root / "out" / "checks.json").exists() else None
        return code, out.getvalue(), err.getvalue(), checks


def first_fail(checks):
    return next((c for c in checks if not c["passed"]), None)


def expect(name, cond, info=""):
    global cases
    cases += 1
    if not cond:
        print(f"FAIL {name} {info}")
        sys.exit(1)
    print(f"ok   {name}")


code, out, err, checks = run()
expect("all_checks_pass", code == 0 and all(c["passed"] for c in checks), out + err)


def helper_unavailable(s):
    s["logs"] = ["2026-11-21 10:00:20.000 E  Batty Beta[800:1] setCodeSigningRequirement failed: -67065",
                 "2026-11-21 10:00:21.000 N  Batty Beta[800:1] restore: helper unavailable; 5 restored tabs start fresh"]
    s["after_hosts"] = [(HOST, A_HASH)]
code, out, err, checks = run(helper_unavailable)
ff = first_fail(checks)
expect("helper_unavailable_fails_helper_connection_first",
       code == 1 and ff["name"] == "helper-connection" and ff["detail"] == "helper unavailable after update: -67065", out)


def counter_gap(s):
    s["final"] = [1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12]
code, out, _, checks = run(counter_gap)
expect("counter_gap_fails", code == 1 and first_fail(checks)["name"] == "counter", out)


def counter_stuck(s):
    s["final"] = list(range(1, 11))
code, out, _, checks = run(counter_stuck)
expect("counter_not_growing_fails", code == 1 and first_fail(checks)["name"] == "counter", out)


def reparented(s):
    s["after_ps"] = [r if not r.lstrip().startswith("602 ") else ps_row(602, 1, "Ss", "ttys002", "/bin/zsh") for r in s["after_ps"]]
code, out, _, checks = run(reparented)
expect("shell_reparented_to_launchd_fails", code == 1 and first_fail(checks)["name"] == "shell-pids", out)


def zombie(s):
    s["after_ps"] = s["after_ps"] + [ps_row(650, HOST, "Z", "??", "<defunct>")]
code, out, _, checks = run(zombie)
expect("zombie_row_fails", code == 1 and first_fail(checks)["name"] == "orphans", out)


def second_host(s):
    s["after_ps"] = s["after_ps"] + [ps_row(501, 1, "Ss", "??", "/Applications/Batty Beta.app/Contents/Resources/bin/BattyHost")]
code, out, _, checks = run(second_host)
expect("second_battyhost_fails", code == 1 and first_fail(checks)["name"] == "orphans", out)


def topology_changed(s):
    s["after_layout"]["windows"][0]["sessions"].pop()
code, out, _, checks = run(topology_changed)
expect("topology_changed_fails", code == 1 and first_fail(checks)["name"] == "topology", out)


def project_lost(s):
    sess = s["after_layout"]["windows"][0]["sessions"][0]
    sess["projectID"] = None
    sess["projectSymbol"] = None
code, out, _, checks = run(project_lost)
expect("project_link_lost_fails", code == 1 and first_fail(checks)["name"] == "project-link", out)


def cdhash_mismatch(s):
    s["after_hosts"] = [(HOST, A_HASH)]
code, out, _, checks = run(cdhash_mismatch)
expect("host_cdhash_mismatch_fails", code == 1 and first_fail(checks)["name"] == "host-binary", out)


def no_after(s):
    s["write_after"] = False
code, out, err, checks = run(no_after)
expect("missing_after_snapshot_is_error_exit_2", code == 2 and checks is None and "missing" in err, err)


def app_pid_unchanged(s):
    s["after_app"] = (700, "101")
code, out, _, checks = run(app_pid_unchanged)
expect("app_pid_unchanged_fails_app_version", code == 1 and first_fail(checks)["name"] == "app-version", out)


def wrong_build(s):
    s["after_app"] = (800, "100")
code, out, _, checks = run(wrong_build)
expect("wrong_build_fails_app_version", code == 1 and first_fail(checks)["name"] == "app-version", out)


def fresh_tabs(s):
    s["logs"] = ["2026-11-21 10:00:30.000 I  Batty Beta[800:1] [co.sstools.Batty.beta:HostRestore] restore: tabs=5 attach=3 exited=0 fresh=2 placed=5 helperSessions=3"]
code, out, _, checks = run(fresh_tabs)
expect("restore_line_fresh_tabs_fails_restore_attach", code == 1 and first_fail(checks)["name"] == "restore-attach", out)


def no_restore(s):
    s["logs"] = []
code, out, _, checks = run(no_restore)
expect("no_restore_line_fails_restore_attach", code == 1 and first_fail(checks)["name"] == "restore-attach", out)


def crash(s):
    s["crash"] = "BattyHost-2026-11-21-100040.ips"
code, out, _, checks = run(crash)
expect("crash_report_fails_crashes", code == 1 and first_fail(checks)["name"] == "crashes", out)


def everything_wrong(s):
    helper_unavailable(s)
    counter_gap(s)
    topology_changed(s)
code, out, _, checks = run(everything_wrong)
names = [c["name"] for c in checks]
fails = [c["name"] for c in checks if not c["passed"]]
expect("checks_run_in_fixed_order",
       names == suc.CHECK_ORDER and fails[0] == "helper-connection"
       and fails.index("topology") < fails.index("counter")
       and out.splitlines()[0] == "PASS app-version", out)

print(f"{cases} cases passed")
