# Experiment: Move PTY ownership into a launchd helper (BattyHost)

## Goal

Prove that Batty's terminal sessions can live in a separate LaunchAgent process (working name **BattyHost**) so they survive the Batty app quitting, crashing, or being updated. The app becomes a client that attaches to sessions the helper owns.

This is a throwaway prototype in its own Xcode project, not a change to the Batty codebase yet. The output is working code plus a results report that answers the questions listed under "Questions to answer".

Design everything so a future **remote client** (a MacBook attaching over Tailscale to a Mac mini) can use the same session protocol. The remote client itself is out of scope, except for the stretch phase on multiple clients and the input lease.

## Background

- Today Batty holds each PTY master in the app process. Quitting or updating the app closes the masters, and the shells get SIGHUP.
- If a long-lived helper holds the masters instead, the shells keep running whenever the app goes away. The app reconnects and reattaches.
- The helper must also keep **terminal state** (or a replay buffer), so a reattaching client gets the current screen and not a blank one.

## Architecture

```
┌──────────────┐  XPC (bootstrap + auth)   ┌──────────────────────────┐
│ Batty app    │──────────────────────────▶│ BattyHost (LaunchAgent)  │
│ (client)     │◀── FileHandle (socket) ───│  - owns PTY masters      │
│ libghostty   │                           │  - spawns shells         │
│ renderer     │◀═══ framed protocol ═════▶│  - replay buffer / VT    │
└──────────────┘     over Unix socket      │  - session registry      │
                                           └──────────────────────────┘
```

- **XPC is used only to bootstrap.** The app connects to the helper's Mach service. launchd starts the helper on demand, and both sides check each other's code signature. The helper then returns a connected Unix socket as a `FileHandle`.
- **All session traffic goes over that socket** using one framed protocol. Later, the remote client will send the same frames over TCP, so the local and remote clients share one code path.
- **The helper is a LaunchAgent, not a LaunchDaemon.** It needs the user's login session (environment, keychain, home directory).

## Project layout

Create a new Xcode project, `BattyHostExperiment`:

- `HostProtocol` (Swift package, shared): message types, framing, encoding, and the protocol version constant.
- `PTYShim` (C target): a minimal `forkpty` + `execve` wrapper. Don't call `fork` from Swift, because the process is multithreaded and only async-signal-safe code may run between fork and exec. The C function should take argv, envp, cwd, and an initial winsize, and return the master fd and the child pid.
- `BattyHost` (command-line tool): the helper.
- `HostClientApp` (macOS app): the test client. It embeds the helper and registers it with `SMAppService`.

Requirements:

- Minimum target: macOS 13 (for `SMAppService` and `NSXPCConnection.setCodeSigningRequirement`).
- No App Sandbox.
- Sign both targets with the same team ID.

## Helper registration

- Place the plist in `HostClientApp.app/Contents/Library/LaunchAgents/co.sstools.batty.host.plist`.
  - `Label`: `co.sstools.batty.host`
  - `BundleProgram`: path to the helper binary, relative to the bundle.
  - `MachServices`: `{ "co.sstools.batty.host.xpc": true }`
  - Don't set `KeepAlive`. The helper starts on demand and stays alive while it has sessions.
- Register it with `SMAppService.agent(plistName:)`. Handle the `.requiresApproval` status by showing a message that points the user to System Settings > General > Login Items.
- Sanity-check the bundle ID prefix (`co.sstools.batty`) against Batty's real bundle ID and adjust it.

## Helper responsibilities

1. **Spawn sessions.** Use a login shell (`-l`, or argv[0] prefixed with `-`) so the user's profile sets PATH. The launchd environment is minimal. Set `TERM` (and `TERMINFO`, if Batty bundles terminfo) the same way Batty does today. Each child must call `setsid` and take the slave as its controlling terminal. The shim handles this.
2. **Keep masters open** and read from them on a dispatch source. Ignore SIGPIPE.
3. **Keep state for reattach.**
   - **Phase 1:** a raw byte ring buffer per session (start at 2 MB), replayed on attach.
   - **Phase 3:** evaluate running libghostty's VT layer headless in the helper, so it can produce a true screen snapshot.
4. **Reap children** with a process-exit dispatch source. Keep the exit status so the app can show "process exited (code N)".
5. **Keep a session registry:** id, title, cwd (if it can be tracked), size, creation time, alive or exited, and an opaque `clientMetadata` blob the app owns (pane layout, custom view state). The helper stores this blob but doesn't interpret it.
6. **Stay alive while any session exists.** Exit cleanly only when there are no sessions and no clients.
7. **Log** with `os_log`, subsystem `co.sstools.batty.host`.

## Protocol (v1)

Framing: 4-byte big-endian length, 1-byte message type, then a payload (binary for data, JSON or Codable for control). Every message except the handshake carries a `sessionID`.

| Message | Direction | Purpose |
|---|---|---|
| `hello {protocolVersion, clientKind}` | C→H | First frame. The helper rejects incompatible versions with `error`. |
| `helloAck {protocolVersion, helperVersion, helperPID}` | H→C | |
| `listSessions` / `sessions [...]` | C↔H | Registry contents, including `clientMetadata`. |
| `create {argv?, cwd?, env?, cols, rows}` | C→H | Returns `created {sessionID}`. |
| `attach {sessionID}` | C→H | The helper sends `snapshot` (replay bytes), then streams `output`. |
| `detach {sessionID}` | C→H | |
| `input {bytes}` | C→H | Written to the master. |
| `output {bytes}` | H→C | |
| `resize {cols, rows}` | C→H | `TIOCSWINSZ` on the master. |
| `setMetadata {blob}` | C→H | |
| `exited {status}` | H→C | |
| `kill {sessionID, signal}` | C→H | |
| `heartbeat` | both | Every 5 s. Drop the peer after 3 missed beats. |
| `error {code, message}` | H→C | |

Backpressure: if a client's socket send buffer stays full, stop reading from that session's master. Don't buffer without limit. Record whether `cat` on a large file stays responsive.

## Client app

- Use Batty's real libghostty surface if possible (see Phase 0). Otherwise, use a minimal fallback so the experiment can continue.
- On launch: register the agent, connect over XPC, receive the socket, send `hello`, send `listSessions`, and attach to every live session. If none exist, create one.
- Include a small debug panel showing the helper PID, protocol versions, session list, and a "Kill helper" button.

## Phases

### Phase 0: libghostty feasibility (do this first, then report back)

libghostty's embedded surface may expect to spawn and own its own PTY. Find out whether a surface can be fed **external** bytes (output from the helper) and can hand keystrokes and resizes back to the host app, so the surface never touches a PTY itself. Look at the termio/backend code and the embedding API. Report what you find before continuing. If it can't, document which libghostty changes would be needed, use a fallback renderer for the rest of the experiment, and flag this prominently as a blocker for the real change.

### Phase 1: Helper owns PTYs

- Build the shim, helper, protocol, and client.
- Create a session, run an interactive shell, check that typing, ^C, and resize (run `stty size` after resizing the window) all work through the helper.

### Phase 2: Survival across app restarts

Run each test with `top` running in one session and a `sleep 600; echo done` in another:

1. Quit the app normally, then relaunch. The sessions are still there, `top` is still updating, and the helper PID is unchanged.
2. `kill -9` the app, then relaunch. Same result.
3. While the app is gone, generate output (`for i in $(seq 1 5000); do echo $i; done`), then relaunch. The replay shows the tail of the output correctly.

### Phase 3: Snapshot quality

- Test replay with a full-screen TUI running (vim, htop) and with the ring buffer overflowed. Document any garbled screens.
- Prototype headless VT state in the helper (libghostty's VT layer, if it can be built without the renderer) that writes the current grid back out as escape sequences on attach. Compare it with raw replay.

### Phase 4: Simulated app update

- While sessions are running, replace `HostClientApp.app` on disk with a newly built copy the way Sparkle does: move the new bundle into place, then relaunch.
- Check whether the helper PID survives. Check what happens to the agent when the bundle is replaced, and when `SMAppService.register()` is called again from the new app.
- Test a protocol mismatch: an app built with v2 against a running v1 helper. The app shows a clear "helper needs restart" state and doesn't crash.

### Phase 5 (stretch): Helper handoff

- A new helper version takes over from the old one without killing sessions. The old helper sends each master fd to the new helper over a Unix socket using `SCM_RIGHTS`, along with the serialized registry and buffers, then exits.
- Verify that the shells never get SIGHUP. Check that children reparented away from the exited helper are still reaped and that exit status reaches the new helper (they reparent to launchd, so the new helper may need to poll with `kqueue`/`EVFILT_PROC`).

### Phase 6 (stretch): Multiple clients and the input lease

- Allow two clients to attach to one session (launch a second client instance, or write a tiny CLI client).
- Add the messages `leaseRequest`, `leaseGrant`, and `leaseRelease`. Only the lease holder's `input` and `resize` frames are applied. On a disconnect or missed heartbeats, the lease returns to the default (local) client, and the helper re-applies that client's size.

## Questions to answer

Write the answers in `EXPERIMENT_RESULTS.md`:

1. Can libghostty render a PTY it doesn't own? If not, what has to change?
2. Does the helper survive an app quit, a `kill -9`, and a bundle replacement? Include PIDs and logs as evidence.
3. How does `SMAppService` behave when the bundle is replaced and when `register()` is called again?
4. How good is raw replay compared with a VT snapshot? What breaks?
5. Throughput and latency: echo latency for a keystroke, and time to `cat` a 100 MB file, both compared with a PTY held in-process.
6. Is the fd handoff practical? What are the edge cases?
7. What is the recommended path for moving this into Batty, and what belongs in the public MIT code versus private code?

## Acceptance criteria

- Phases 0 through 4 completed, with the results report.
- Quitting or crashing the app never kills a session.
- After a relaunch, every live session is visible and usable within 1 second.
- No unbounded memory growth in the helper under sustained output (check over 10 minutes with `yes`).

## Out of scope

- Network transport, Tailscale, and authentication for the remote client.
- Restoring sessions across reboot or logout (Batty's separate window-restore replacement covers that).
- Changes to the real Batty repo.
