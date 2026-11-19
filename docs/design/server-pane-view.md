# Server Pane view — design (#0648)

**Status: drafted for user approval** (#0301 design-first gate). Implementation proceeds against this draft, as Process Status, Git Status, System Metrics and LM Studio did; visual sign-off happens when the user checks the `resolved` issue. The mock-up is [`server-pane-view.html`](server-pane-view.html).

Read `docs/pane-kinds.md` and `docs/pane-view-lifecycle.md` first.

## 1. What it is

A non-terminal Pane of kind `server` that watches one TCP port in one Session. It is created only by the CLI:

- `batty server start --port N -- <command…>` creates the Server Pane next to the calling Pane (Settings › General › Server Panes, or `--split right|down`), then an ordinary terminal Pane **below** the Server Pane, and types the command into that terminal's shell. Keyboard focus stays on the calling Pane.
- `batty server attach --port N [--command C --cwd D]` creates the Server Pane only, for a server started elsewhere.
- `batty server stop|restart` act on the Server Pane for a port (or by id).

There is exactly one Server Pane per (Session, port). Re-running `start` reuses it and its terminal Tab, replacing the stored command and restarting; re-running `attach` returns the existing Pane unchanged. No menu, Command Palette or Project slot creates one, because it needs a port and a command. Save Session as Project captures it as an empty terminal slot with a note.

## 2. Layout

```
┌──────────────────────────────────────────────────────────┐
│ ● Listening   http://localhost:8083/  200   [Open] [↻] [■] │  header
├──────────────────────────────────────────────────────────┤
│ PID      41823            Uptime   3m 12s                 │
│ CPU      0.4 %            Memory   18.2 MB                │  facts grid
│ Exit     —                Command  go run .               │
├──────────────────────────────────────────────────────────┤
│ Stats                                                     │
│ memstats.HeapAlloc   4.1 MB   ▁▂▃▅▃▂                      │  stats
│ memstats.NumGC       12       ▁▁▂▂▃▃                      │
│ requests             480      ▁▂▄▆█                       │
│ cmdline              /tmp/go-build…/exe/site               │
└──────────────────────────────────────────────────────────┘
```

- **Header:** a state chip (colored dot plus text), the URL, the last HTTP status, and three buttons: Open in Browser, Restart, Stop. Restart is hidden when the backend can't restart; Stop is hidden for a listener owned by another user or when nothing is running. Stop and Restart are hidden, with a one-line reason under the header, for a listener Stop may not signal (§4, decision 4).
- **Facts grid:** PID, uptime (from the listener's kernel start time), CPU % (delta-based), memory (physical footprint, never RSS, #0290), last exit code, command (the stored command, or the recovered command line of an attached process, read-only).
- **Stats:** only when `/debug/vars` (or `--stats-url`) returned a JSON object. Numeric leaves that have changed get a sparkline; constants are plain values; strings and bools are text. A non-loopback stats host is labeled "Stats from <host>".

## 3. States

| State | Chip | When |
|---|---|---|
| `starting` | gray "Starting" (attach: "Not listening") | the command was typed, or attach is waiting, and nothing listens yet |
| `listening(pid, status)` | green "Listening" | a listener was found; PID is nil when the listener belongs to another user ("Listening, owned by another user") |
| — not responding | amber "Not responding" | listening, but the last HTTP probe failed after a success |
| `stopping` | amber "Stopping" | Stop is escalating |
| `stopped(exit, requested)` | gray "Stopped" | Stop finished |
| `stopped(nil, terminalClosed)` | gray "Stopped, terminal closed" | the terminal Tab went away |
| `crashed(0)` | gray "Exited (0)" | the command exited 0 without a Stop |
| `crashed(code)` | red "Crashed (code)" | any other exit without a Stop |

## 4. Decisions and reasons

1. **Grammar.** A new noun, `batty server`, because `start` needs a trailing command and a cwd and `stop`/`restart` act on a process, not a Pane (`docs/batty-cli-design.md` §1.1).
2. **Restart for attached servers only with `--command`.** Batty never runs a command recovered from another process's argv; that would need a trust prompt.
3. **Port detection with libproc** (`PROC_PIDLISTFDS`, then `PROC_PIDFDSOCKETINFO`, TCP in `LISTEN` on the port). No `lsof`. Both modes scan every same-user pid (`PROC_RUID_ONLY`), so the Pane shows whatever listens on the port, Batty's or not. Once a second while starting; then only the known pid, with a full re-scan when it disappears. The scan runs off the main actor with a generation counter.
4. **Which PID, and what Stop may signal.** Metrics come from the listener (the compiled child under `go run .`). Stop decides from a fresh `sysctl(KERN_PROC_ALL)` snapshot (`ServerJobResolver`):
   - **Start mode** signals the listener's process group, and only when that group is a job of this Pane's own terminal Tab. The Tab's shell is Batty's same-user child, or the same-user child of Batty's root-owned `login` child. It is matched by `BATTY_TAB_ID` when its environment is readable. The kernel hides the environment of platform binaries such as `/bin/zsh`, so otherwise it must be the only such shell whose Batty child started after the moment the Tab was created. It is then cached by pid and start time. The listener must descend from that shell, and its group must differ from the shell's. Every live member of the group must also descend from the shell.
   - **Attach mode** signals the listener and its same-user descendants (a `pbi_ppid` walk), never a group, because an external process's group may hold its parent shell.
   - **Never signalled:** pid or group 0 and 1, Batty, any ancestor of Batty, or their groups. The descendant walk skips them too.
   - **Re-checked before every signal** (SIGINT, SIGTERM, SIGKILL) against a new snapshot: the shell's and the group leader's (or the tree root's) pid and start time, and group membership. A pid reused or a group that gained an outside process stops the escalation.
   - **Not provably ours:** a listener that fails these checks (another Tab's or another app's server holding the port, an ambiguous shell) still shows as Listening with its PID and metrics. Stop and Restart are unavailable, the Pane shows "Stop unavailable: <reason>", and `batty server stop|restart` fail with `stop refused: <reason>`.
5. **HTTP probe.** `http://localhost:<port>/` unless `--url`. Any response counts as answering; the status is shown. 2 s timeout, ephemeral session; self-signed certificates are trusted only for loopback hosts. On becoming listening, then every 5 s while visible.
6. **The command runs in a new terminal Pane** below the Server Pane, never a new Tab in the caller's Pane (that would replace the agent's Tab on screen).
7. **Always unique by (Session, port)**, including hidden Server Panes, which are shown again.
8. **Closing the terminal Tab** leaves the Server Pane showing "Stopped, terminal closed"; Restart makes a new terminal Pane under it.
9. **Stop escalation:** SIGINT, up to 5 s; SIGTERM, up to 3 s; SIGKILL. Aliveness is polled every 250 ms on the injected clock and the wait ends as soon as the Tab reports the command finished. **Closing the Server Pane never stops a terminal-backed server**; the terminal Pane owns the process and has its own close confirmation. A backend with no terminal (#0649) declares `stopsOnTearDown`.

Exit detection is event-driven through the Tab's OSC 133 command-finished callback, so a hidden Server Pane still records a crash. Scans, probes, metrics and stats stop while hidden (`docs/pane-view-lifecycle.md` §4); showing again refreshes once.

## 5. Accessibility identifiers

`server-pane.<paneID>`, `server-pane-state`, `server-pane-url`, `server-pane-pid`, `server-pane-open-browser`, `server-pane-restart`, `server-pane-stop`, `server-pane-stop-refused`, `server-pane-stats`.
