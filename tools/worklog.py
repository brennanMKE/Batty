#!/usr/bin/env python3
"""Measure a subagent transcript for the issue work log (issues/Issues.md, "Token usage and cost tracking").

    tools/worklog.py <agent.jsonl> [--phase implement] [--outcome reviewed]   # prints one work-log row
    tools/worklog.py --json <agent.jsonl>...                                  # one JSON object per transcript
    tools/worklog.py --scan [<project transcripts dir>]                       # JSON for every subagent transcript

Cache read/write counts are exact. Output tokens are estimated (assistant characters / 4) because the transcript's
`usage` is the stream-start snapshot. Wall is first to last timestamp; VM is every Bash call that runs
tools/run-ui-tests-vm.sh or `./build.sh ui`, from tool_use to its tool_result (or, for a background run, to its task
notification). Build and Unit time `./build.sh` (build), `./build.sh ui-typecheck` and `./build.sh unit` runs the same
way; a foreground run counts only when its result has a `CHECK <STAGE>:` line, which also names its stage. Haiku counts
and sums the `claude -p --model haiku` failure summaries recorded in the shared build/checks/haiku-usage.jsonl whose log
path this transcript printed; Cost is model cost plus that Haiku cost. Stdlib only.
"""
import argparse
import collections
import datetime
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PRICING = ROOT / "issues" / "model-pricing.json"
# A command that runs the VM runner (optionally after `cd … &&` or env assignments), not one that greps or reads it.
VM_COMMAND = re.compile(
    r"(^|&&|;|\|\||\n|\bdo)\s*(cd \S+\s*&&\s*)?([A-Z_]+=\S+\s+)*((\S*/)?tools/run-ui-tests-vm\.sh\b|(\S*/)?build\.sh ui(?=[\s;&|)]|$))")
# Only a real run prints the runner's result line; --help, syntax checks and heredocs don't.
VM_SUMMARY = re.compile(r"==> RESULT:|Executed \d+ tests?|CHECK UI:")
# A command that runs build.sh with no action, `build`, `unit` or `ui-typecheck` (same prefix tolerance as VM_COMMAND).
CHECK_COMMAND = re.compile(
    r"(^|&&|;|\|\||\n|\bdo)\s*(cd \S+\s*&&\s*)?([A-Z_]+=\S+\s+)*(\S*/)?build\.sh"
    r"(\s+--verbose)*(?P<action>\s+(build|unit|ui-typecheck)\b|\s*($|[;&|\n)]))")
CHECK_RESULT = re.compile(r"CHECK (BUILD|UNIT|UI-TYPECHECK|UI): (PASSED|FAILED|ERROR)")
CHECK_LOG = re.compile(r"build/checks/[\w.-]+?\.log\b")
BACKGROUND_ID = re.compile(r"background with ID: (\w+)")
DEFAULT_DIR = pathlib.Path.home() / ".claude" / "projects" / "-Users-brennan-Developer-brennanMKE-Batty"


def check_stage(command):
    match = CHECK_COMMAND.search(command)
    if not match:
        return None
    return "unit" if "unit" in (match.group("action") or "") else "build"


def command_stages(command):
    """The CHECK stages a Bash command runs, so a CHECK line from anything else
    in the same call (an offline tools/check-report.py, a cat) earns no credit."""
    stages = {"UI"} if VM_COMMAND.search(command) else set()
    for match in CHECK_COMMAND.finditer(command):
        action = (match.group("action") or "").strip()
        stages.add({"unit": "UNIT", "ui-typecheck": "UI-TYPECHECK"}.get(action, "BUILD"))
    return stages


def shared_checks_dir():
    import subprocess
    try:
        common = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True).stdout.strip()
    except OSError:
        common = ""
    base = pathlib.Path(common).parent if common else ROOT
    return base / "build" / "checks"


def haiku_usage(logs):
    usage = shared_checks_dir() / "haiku-usage.jsonl"
    runs, cost = 0, 0.0
    if not logs or not usage.exists():
        return runs, cost
    for line in open(usage, encoding="utf-8"):
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if any(str(record.get("log", "")).endswith(log) for log in logs):
            runs += 1
            cost += record.get("cost_usd") or 0
    return runs, cost


def ts(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def measure(path, pricing):
    effort = collections.Counter()
    model = collections.Counter()
    requests = {}
    chars = 0
    first = last = None
    calls = {}  # tool_use id -> (kind, started); kind is "vm", "build" or "unit"
    background_calls = {}
    tasks = {}
    runs = {"vm": [], "build": [], "unit": []}
    unfinished = collections.Counter()  # background runs whose end was not found
    logs = set()
    for line in open(path, encoding="utf-8"):
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        stamp = entry.get("timestamp")
        if stamp:
            when = ts(stamp)
            first = first or when
            last = when
        message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
        content = message.get("content") if isinstance(message.get("content"), list) else []
        if entry.get("type") == "assistant":
            if entry.get("effort"):
                effort[entry["effort"]] += 1
            if message.get("model"):
                model[message["model"]] += 1
            if entry.get("requestId") and message.get("usage"):
                requests[entry["requestId"]] = message["usage"]
            for block in content:
                if not isinstance(block, dict):
                    continue
                kind = block.get("type")
                if kind == "text":
                    chars += len(block.get("text", ""))
                elif kind == "thinking":
                    chars += len(block.get("thinking", ""))
                elif kind == "tool_use":
                    tool_input = block.get("input", {})
                    chars += len(json.dumps(tool_input))
                    command = tool_input.get("command", "") if isinstance(tool_input, dict) else ""
                    kind = None
                    if block.get("name") == "Bash":
                        kind = "vm" if VM_COMMAND.search(command) else check_stage(command)
                    if kind:
                        target = background_calls if tool_input.get("run_in_background") else calls
                        target[block.get("id")] = (kind, when, command_stages(command))
        elif entry.get("type") == "user":
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_result":
                    continue
                text = json.dumps(block.get("content", ""), ensure_ascii=False)
                logs.update(CHECK_LOG.findall(text))
                if block.get("tool_use_id") in calls:
                    kind, started, allowed = calls.pop(block["tool_use_id"])
                    if kind == "vm":
                        if VM_SUMMARY.search(text):
                            runs["vm"].append((when - started).total_seconds())
                    else:
                        stages = [r for r in CHECK_RESULT.findall(text) if r[0] in allowed]
                        for stage, _ in stages:
                            key = "vm" if stage == "UI" else "unit" if stage == "UNIT" else "build"
                            runs[key].append((when - started).total_seconds() / len(stages))
                elif block.get("tool_use_id") in background_calls:
                    # "Command running in background with ID: <task>"; timed until that task's notification.
                    found = BACKGROUND_ID.search(text)
                    kind, started, _ = background_calls.pop(block["tool_use_id"])
                    if found:
                        tasks[found.group(1)] = (kind, started)
                    else:
                        unfinished[kind] += 1
        # A background run ends at its task notification, delivered as a user message or a queued-command attachment.
        if tasks and entry.get("type") in ("user", "attachment") and stamp:
            text = json.dumps(entry)
            for task in [t for t in tasks if f"<task-id>{t}</task-id>" in text]:
                kind, started = tasks.pop(task)
                runs[kind].append((when - started).total_seconds())
    for kind, *_ in list(tasks.values()) + list(background_calls.values()):
        unfinished[kind] += 1
    haiku_runs, haiku_cost = haiku_usage(logs)

    cache_read = sum(u.get("cache_read_input_tokens", 0) for u in requests.values())
    write_5m = write_1h = 0
    for u in requests.values():
        split = u.get("cache_creation") or {}
        if split:
            write_5m += split.get("ephemeral_5m_input_tokens", 0)
            write_1h += split.get("ephemeral_1h_input_tokens", 0)
        else:
            write_5m += u.get("cache_creation_input_tokens", 0)
    input_tokens = sum(u.get("input_tokens", 0) for u in requests.values())
    output = chars // 4
    name = model.most_common(1)[0][0] if model else None
    rates = pricing.get("models", {}).get(name) if name else None
    cost = None
    if rates:
        cost = (input_tokens * rates["input"] + output * rates["output"] + cache_read * rates["cache_read"]
                + write_5m * rates["cache_write_5m"]
                + write_1h * rates.get("cache_write_1h", rates["cache_write_5m"])) / 1e6
    meta_path = pathlib.Path(str(path)[:-len(".jsonl")] + ".meta.json")
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    return {
        "transcript": str(path),
        "description": meta.get("description"),
        "date": first.astimezone().date().isoformat() if first else None,
        "start": first.isoformat() if first else None,
        "model": name,
        "effort": effort.most_common(1)[0][0] if effort else None,
        "wall_s": (last - first).total_seconds() if first else 0,
        "vm_runs": len(runs["vm"]),
        "vm_s": sum(runs["vm"]),
        "vm_background": unfinished["vm"],
        "build_runs": len(runs["build"]),
        "build_s": sum(runs["build"]),
        "build_background": unfinished["build"],
        "unit_runs": len(runs["unit"]),
        "unit_s": sum(runs["unit"]),
        "unit_background": unfinished["unit"],
        "haiku_runs": haiku_runs,
        "haiku_cost": haiku_cost,
        "turns": len(requests),
        "output_est": output,
        "cache_read": cache_read,
        "cache_write": write_5m + write_1h,
        "cost": cost,
        "total_cost": None if cost is None else cost + haiku_cost,
        "pricing_fetched": pricing.get("fetched"),
    }


def minutes(seconds):
    return f"{seconds / 60:.0f}m" if seconds >= 60 else f"{seconds:.0f}s"


def timed(m, kind):
    cell = "—" if not m[f"{kind}_runs"] else f"{m[f'{kind}_runs']} ({m[f'{kind}_s'] / 60:.1f}m)"
    if m[f"{kind}_background"]:
        cell += f" +{m[f'{kind}_background']} bg"
    return cell


def row(m, phase, outcome):
    cost = "—" if m["total_cost"] is None else f"${m['total_cost']:.2f}"
    haiku = "—" if not m["haiku_runs"] else f"{m['haiku_runs']} (${m['haiku_cost']:.3f})"
    return (f"| {m['date']} | {phase} | {m['model']} | {m['effort'] or '—'} | {minutes(m['wall_s'])} | "
            f"{timed(m, 'build')} | {timed(m, 'unit')} | {timed(m, 'vm')} | "
            f"{m['turns']} | ~{m['output_est']:,} | {m['cache_read']:,} | {m['cache_write']:,} | {haiku} | {cost} | "
            f"{outcome} |")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="*")
    parser.add_argument("--phase", default="implement")
    parser.add_argument("--outcome", default="—")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--scan", action="store_true", help="measure every subagents/agent-*.jsonl under the directory")
    args = parser.parse_args()
    pricing = json.loads(PRICING.read_text()) if PRICING.exists() else {}
    if args.scan:
        base = pathlib.Path(args.paths[0]) if args.paths else DEFAULT_DIR
        paths = sorted(base.glob("*/subagents/agent-*.jsonl"))
    else:
        paths = [pathlib.Path(p) for p in args.paths]
    if not paths:
        parser.error("no transcripts")
    for path in paths:
        m = measure(path, pricing)
        print(json.dumps(m) if args.json or args.scan else row(m, args.phase, args.outcome))


if __name__ == "__main__":
    sys.exit(main())
