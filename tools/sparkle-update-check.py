#!/usr/bin/env python3
"""Checks one mode of a tools/run-sparkle-update-vm.sh run (#0715).

    python3 -I tools/sparkle-update-check.py --mode relaunch \\
        --baseline <guest>/baseline --after <guest>/after --logs <guest>/logs \\
        --expect-build <B> --b-host-cdhash <hash> --trigger-time 'YYYY-MM-DD HH:MM:SS' \\
        [--crashes <guest>/crashes] [--out <dir>]

Each snapshot folder is what tools/vm-guest-sparkle.sh `snapshot` writes:
terminal-layout.json, ps.txt, host.txt, app.txt, pids/<label>, counter.txt,
and in `after` also counter-final.txt.

Prints one line per check (`PASS <name>` or `FAIL <name>: <detail>`), writes
the same lines to <out>/checks.txt and a list to <out>/checks.json. The checks
run in a fixed order and the first failure is the run's CHECK detail. Exit 0
when every check passed, 1 when one failed, 2 when an input is missing or
unreadable.
"""

import argparse
import json
import re
import sys
from pathlib import Path

CHECK_ORDER = [
    "app-version",
    "helper-connection",
    "restore-attach",
    "host-binary",
    "host-pid",
    "topology",
    "project-link",
    "shell-pids",
    "counter",
    "orphans",
    "crashes",
    "broker-fresh",
]

# Focus, selection, sizes and titles legitimately change across a relaunch;
# the topology check compares ids and nesting only.
STRUCTURE_KEEP = {"id", "direction"}
TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})")


class InputError(Exception):
    pass


def read_text(path):
    try:
        return Path(path).read_text(errors="replace")
    except OSError as e:
        raise InputError(f"missing {path}: {e.strerror}")


def read_optional(path):
    p = Path(path)
    return p.read_text(errors="replace").strip() if p.is_file() else ""


def read_json(path):
    try:
        return json.loads(read_text(path))
    except json.JSONDecodeError as e:
        raise InputError(f"unparseable {path}: {e}")


def read_kv(path):
    out = {}
    for line in read_text(path).splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out.setdefault(k.strip(), v.strip())
    return out


def parse_ps(path):
    """pid -> (ppid, stat, tty, comm) from `ps -A -o pid=,ppid=,pgid=,stat=,tty=,lstart=,comm=`."""
    procs = {}
    for line in read_text(path).splitlines():
        parts = line.split(None, 10)
        if len(parts) < 11 or not parts[0].isdigit():
            continue
        pid, ppid, _pgid, stat, tty = parts[:5]
        procs[int(pid)] = (int(ppid), stat, tty, parts[10])
    return procs


def parse_host(path):
    """[(pid, cdhash or None)] from host.txt: `pid=N` lines, each followed by
    that pid's `codesign -dvvv` output."""
    hosts = []
    for line in read_text(path).splitlines():
        if line.startswith("pid="):
            hosts.append([int(line[4:].strip()), None])
        elif line.startswith("CDHash=") and hosts and hosts[-1][1] is None:
            hosts[-1][1] = line[7:].strip()
    return [tuple(h) for h in hosts]


def structure(node):
    if isinstance(node, dict):
        return {k: structure(v) for k, v in sorted(node.items())
                if k in STRUCTURE_KEEP or isinstance(v, (dict, list))}
    if isinstance(node, list):
        return [structure(v) for v in node]
    return node


def walk(node):
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)


def tab_ids(layout):
    ids = []
    for d in walk(layout):
        tabs = d.get("tabs")
        if isinstance(tabs, list):
            ids += [t.get("id") for t in tabs if isinstance(t, dict)]
    return ids


def project_sessions(layout):
    out = {}
    for w in layout.get("windows", []):
        for s in w.get("sessions", []):
            if s.get("projectID"):
                out[s["id"]] = {k: s.get(k) for k in ("projectID", "projectSymbol", "projectSymbolName", "background")}
    return out


def log_lines_after(logs_dir, trigger):
    lines = []
    for f in sorted(Path(logs_dir).glob("*.log")):
        for line in f.read_text(errors="replace").splitlines():
            m = TS_RE.match(line)
            if m and m.group(1) >= trigger:
                lines.append(line)
    return lines


def ancestors(procs, pid):
    seen = []
    while pid in procs and pid not in seen and pid > 1:
        seen.append(pid)
        pid = procs[pid][0]
    return seen + [pid]


def read_counter(path):
    vals = []
    for line in read_text(path).splitlines():
        line = line.strip()
        if line:
            if not line.isdigit():
                raise InputError(f"non-numeric counter line in {path}: {line!r}")
            vals.append(int(line))
    return vals


def run_checks(a):
    base, after = Path(a.baseline), Path(a.after)
    for d in (base, after):
        if not d.is_dir():
            raise InputError(f"missing snapshot folder {d}")
    if not Path(a.logs).is_dir():
        raise InputError(f"missing logs folder {a.logs}")
    b_layout = read_json(base / "terminal-layout.json")
    a_layout = read_json(after / "terminal-layout.json")
    b_app, a_app = read_kv(base / "app.txt"), read_kv(after / "app.txt")
    b_hosts, a_hosts = parse_host(base / "host.txt"), parse_host(after / "host.txt")
    a_procs = parse_ps(after / "ps.txt")
    final = read_counter(after / "counter-final.txt")
    at_after = read_counter(after / "counter.txt")
    pid_files = {}
    pids_dir = base / "pids"
    if not pids_dir.is_dir():
        raise InputError(f"missing {pids_dir}")
    for f in sorted(pids_dir.iterdir()):
        txt = f.read_text().strip()
        if not txt.isdigit():
            raise InputError(f"bad pid file {f}")
        pid_files[f.name] = int(txt)
    logs = log_lines_after(a.logs, a.trigger_time)
    broker_state = read_text(after / "broker.txt").strip()
    b_broker_pid = read_optional(base / "broker-pid.txt")
    a_broker_pid = read_optional(after / "broker-pid.txt")

    results = {}

    # 1. app-version
    if b_app.get("pid") == a_app.get("pid"):
        results["app-version"] = f"app pid unchanged ({a_app.get('pid')}): no relaunch"
    elif a_app.get("version") != str(a.expect_build):
        results["app-version"] = f"on-disk CFBundleVersion {a_app.get('version')} != {a.expect_build}"
    else:
        results["app-version"] = None

    # 2. helper-connection
    detail = None
    if any("-67065" in l for l in logs):
        detail = "helper unavailable after update: -67065"
    else:
        for phrase in ("terminal helper connection: unavailable", "restore: helper unavailable"):
            if any(phrase in l for l in logs):
                detail = f"helper unavailable after update: {phrase}"
                break
    results["helper-connection"] = detail

    # 3. restore-attach
    n = len(tab_ids(b_layout))
    restore = [l for l in logs if "restore: tabs=" in l]
    if not restore:
        results["restore-attach"] = "restore-attach: no `restore: tabs=` line after the trigger"
    else:
        m = re.search(r"restore: tabs=(\d+) attach=(\d+) exited=(\d+) fresh=(\d+)", restore[-1])
        if not m:
            results["restore-attach"] = f"restore-attach: unparseable line: {restore[-1]}"
        else:
            tabs, attach, exited, fresh = map(int, m.groups())
            ok = tabs == n and attach == n and exited == 0 and fresh == 0
            results["restore-attach"] = None if ok else (
                f"restore-attach: tabs={tabs} attach={attach} exited={exited} fresh={fresh}, expected {n} attached")

    # 4. host-binary
    if len(a_hosts) != 1:
        results["host-binary"] = f"host-binary: {len(a_hosts)} BattyHost processes after the update"
    elif a_hosts[0][1] != a.b_host_cdhash:
        results["host-binary"] = f"host-binary: running cdhash {a_hosts[0][1]} != B's {a.b_host_cdhash}"
    else:
        results["host-binary"] = None

    # 5. host-pid
    b_pid = b_hosts[0][0] if b_hosts else None
    a_pid = a_hosts[0][0] if a_hosts else None
    results["host-pid"] = None if (b_pid is not None and b_pid == a_pid and len(a_hosts) == 1) else (
        f"host-pid: baseline {b_pid}, after {[h[0] for h in a_hosts]}")

    # 6. topology
    results["topology"] = None if structure(b_layout) == structure(a_layout) else (
        "topology: Session, Pane, Tab ids or the split tree changed")

    # 7. project-link
    bp, ap = project_sessions(b_layout), project_sessions(a_layout)
    if not bp:
        results["project-link"] = "project-link: no Project Session in the baseline"
    elif bp != ap:
        lost = sorted(k for k in bp if bp[k] != ap.get(k))
        results["project-link"] = f"project-link: lost or changed for Session(s) {', '.join(lost)}"
    else:
        results["project-link"] = None

    # 8. shell-pids
    bad = []
    for label, pid in pid_files.items():
        if pid not in a_procs:
            bad.append(f"{label}({pid}) gone")
        elif a_pid is None or a_pid not in ancestors(a_procs, pid):
            bad.append(f"{label}({pid}) not under BattyHost {a_pid}")
    if not pid_files:
        bad.append("no pid files in the baseline")
    results["shell-pids"] = None if not bad else "shell-pids: " + "; ".join(bad)

    # 9. counter
    if not final:
        results["counter"] = "counter: counter-final.txt is empty"
    elif final != list(range(1, len(final) + 1)):
        gap = next(i + 1 for i, v in enumerate(final) if v != i + 1)
        results["counter"] = f"counter: gap or repeat at line {gap}"
    elif at_after and final[-1] <= at_after[-1]:
        results["counter"] = f"counter: not growing after the update (stuck at {final[-1]})"
    else:
        results["counter"] = None

    # 10. orphans
    bad = []
    zombies = [p for p, (_, stat, _, _) in a_procs.items() if stat.startswith("Z")]
    if zombies:
        bad.append(f"zombies {sorted(zombies)}")
    for p, (_, _, tty, comm) in sorted(a_procs.items()):
        if tty.startswith("ttys") and (a_pid is None or a_pid not in ancestors(a_procs, p)):
            bad.append(f"{p} {comm.rsplit('/', 1)[-1]} on {tty} outside BattyHost")
    host_procs = [p for p, v in a_procs.items() if v[3].rsplit("/", 1)[-1] == "BattyHost"]
    if len(host_procs) > 1:
        bad.append(f"{len(host_procs)} BattyHost processes")
    results["orphans"] = None if not bad else "orphans: " + "; ".join(bad[:5])

    # 11. crashes
    crashes_dir = Path(a.crashes) if a.crashes else Path(a.logs).parent / "crashes"
    crashes = sorted(p.name for p in crashes_dir.glob("*.ips") if p.name.startswith("Batty")) if crashes_dir.is_dir() else []
    results["crashes"] = None if not crashes else f"crashes: {', '.join(crashes)}"

    # 12. broker-fresh
    if broker_state == "broker-stale":
        results["broker-fresh"] = "broker-stale: batty ping failed after the update until the broker was restarted"
    elif b_broker_pid and a_broker_pid and b_broker_pid == a_broker_pid:
        results["broker-fresh"] = f"broker pid unchanged ({a_broker_pid}): the old broker is still serving"
    else:
        results["broker-fresh"] = None

    return [(name, results[name]) for name in CHECK_ORDER]


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--mode", required=True)
    p.add_argument("--baseline", required=True)
    p.add_argument("--after", required=True)
    p.add_argument("--logs", required=True)
    p.add_argument("--expect-build", required=True)
    p.add_argument("--b-host-cdhash", required=True)
    p.add_argument("--trigger-time", required=True)
    p.add_argument("--crashes")
    p.add_argument("--out")
    a = p.parse_args(argv)
    try:
        results = run_checks(a)
    except InputError as e:
        print(f"ERROR {a.mode}: {e}", file=sys.stderr)
        return 2
    lines = [f"PASS {n}" if d is None else f"FAIL {n}: {d}" for n, d in results]
    print("\n".join(lines))
    if a.out:
        out = Path(a.out)
        out.mkdir(parents=True, exist_ok=True)
        (out / "checks.txt").write_text("\n".join(lines) + "\n")
        (out / "checks.json").write_text(json.dumps(
            [{"name": n, "passed": d is None, "detail": d} for n, d in results], indent=2) + "\n")
    return 0 if all(d is None for _, d in results) else 1


if __name__ == "__main__":
    sys.exit(main())
