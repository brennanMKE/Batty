#!/usr/bin/env python3
"""Measure a subagent transcript for the issue work log (issues/Issues.md, "Token usage and cost tracking").

    tools/worklog.py <agent.jsonl> [--phase implement] [--outcome reviewed]   # prints one work-log row
    tools/worklog.py --json <agent.jsonl>...                                  # one JSON object per transcript
    tools/worklog.py --scan [<project transcripts dir>]                       # JSON for every subagent transcript

Cache read/write counts are exact. Output tokens are estimated (assistant characters / 4) because the transcript's
`usage` is the stream-start snapshot. Wall is first to last timestamp; VM is every Bash call that runs
tools/run-ui-tests-vm.sh or `./build.sh ui`, from tool_use to its tool_result (or, for a background run, to its task
notification). Stdlib only.
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
    r"(^|&&|;|\|\||\n|\bdo)\s*(cd \S+\s*&&\s*)?([A-Z_]+=\S+\s+)*((\S*/)?tools/run-ui-tests-vm\.sh|(\S*/)?build\.sh ui)\b")
# Only a real run prints the runner's result line; --help, syntax checks and heredocs don't.
VM_SUMMARY = re.compile(r"==> RESULT:|Executed \d+ tests?")
BACKGROUND_ID = re.compile(r"background with ID: (\w+)")
DEFAULT_DIR = pathlib.Path.home() / ".claude" / "projects" / "-Users-brennan-Developer-brennanMKE-Batty"


def ts(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def measure(path, pricing):
    effort = collections.Counter()
    model = collections.Counter()
    requests = {}
    chars = 0
    first = last = None
    vm_calls = {}
    vm_runs = []
    vm_background_calls = {}
    vm_tasks = {}
    vm_background = 0  # background runs whose end was not found
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
                    if block.get("name") == "Bash" and VM_COMMAND.search(command):
                        if tool_input.get("run_in_background"):
                            vm_background_calls[block.get("id")] = when
                        else:
                            vm_calls[block.get("id")] = when
        elif entry.get("type") == "user":
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_result":
                    continue
                if block.get("tool_use_id") in vm_calls:
                    started = vm_calls.pop(block["tool_use_id"])
                    if VM_SUMMARY.search(json.dumps(block.get("content", ""))):
                        vm_runs.append((when - started).total_seconds())
                elif block.get("tool_use_id") in vm_background_calls:
                    # "Command running in background with ID: <task>"; timed until that task's notification.
                    found = BACKGROUND_ID.search(json.dumps(block.get("content", "")))
                    started = vm_background_calls.pop(block["tool_use_id"])
                    if found:
                        vm_tasks[found.group(1)] = started
                    else:
                        vm_background += 1
        # A background run ends at its task notification, delivered as a user message or a queued-command attachment.
        if vm_tasks and entry.get("type") in ("user", "attachment") and stamp:
            text = json.dumps(entry)
            for task in [t for t in vm_tasks if f"<task-id>{t}</task-id>" in text]:
                vm_runs.append((when - vm_tasks.pop(task)).total_seconds())
    vm_background += len(vm_tasks) + len(vm_background_calls)

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
        "vm_runs": len(vm_runs),
        "vm_s": sum(vm_runs),
        "vm_background": vm_background,
        "turns": len(requests),
        "output_est": output,
        "cache_read": cache_read,
        "cache_write": write_5m + write_1h,
        "cost": cost,
        "pricing_fetched": pricing.get("fetched"),
    }


def minutes(seconds):
    return f"{seconds / 60:.0f}m" if seconds >= 60 else f"{seconds:.0f}s"


def row(m, phase, outcome):
    vm = "—" if not m["vm_runs"] else f"{m['vm_runs']} ({m['vm_s'] / 60:.1f}m)"
    if m["vm_background"]:
        vm += f" +{m['vm_background']} bg"
    cost = "—" if m["cost"] is None else f"${m['cost']:.2f}"
    return (f"| {m['date']} | {phase} | {m['model']} | {m['effort'] or '—'} | {minutes(m['wall_s'])} | {vm} | "
            f"{m['turns']} | ~{m['output_est']:,} | {m['cache_read']:,} | {m['cache_write']:,} | {cost} | {outcome} |")


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
