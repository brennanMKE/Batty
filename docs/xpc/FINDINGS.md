# FINDINGS: URL scheme vs XPC for Batty's CLI

> **Vendored copy — not a Batty document.** Copied 2026-07-24 from
> `RemoteControl/FINDINGS.md` (a sibling, throwaway, read-only checkout at
> `/Users/brennan/Developer/brennanMKE/RemoteControl`) for Batty issue
> [#0267](../../issues/0267.md). RemoteControl was a throwaway prototype
> built specifically to decide **Batty's** CLI transport — it had no app of
> its own — so every "Batty" in the body below is a genuine reference to
> this repo (`docs/cli-tool-install.md`, the 372-test build-graph gate,
> `BattyKit`, etc.), not a placeholder. The one thing to hold in mind: the
> body describes Batty's state as of 2026-07-24 and predates any of
> #0265's children landing. Batty's own decision record and child-issue
> index for the outcome described here live at
> [`issues/0265.md`](../../issues/0265.md). The body
> below is unedited from the source, with one exception forced by the flat
> vendored layout: the closing link `[docs/](docs/README.md)` assumed a
> nested `docs/README.md` — in this folder it is a sibling, read it as
> `README.md`.
>
> **Any bare `#NNNN` below is a RemoteControl issue** (that project's own
> `issues/0001`–`issues/0031` tracker, referenced via its `issues/`
> folder and `issues/Issues.md` throughout), never a Batty issue — Batty's
> tracker uses the identical `#NNNN` form for a disjoint set of numbers.
> The lone exception is `#0249`, cited near the end of this document —
> that one genuinely is a Batty issue (CLI install plumbing), correctly
> referenced from the source project. Links to files this vendoring did
> not copy (RemoteControl's `issues/` folder, its repo-root `README.md`)
> will not resolve; see the source checkout above if it still exists.

Written after building both transports end to end in this repo. Every claim below is backed by something in `issues/` — the verification sections there record the actual commands and outputs.

**Recommendation up front: use a hybrid.** Keep the URL scheme for fire-and-forget commands. Add XPC only for the commands that genuinely need data back or streaming. Do not replace the URL scheme with XPC wholesale — the machinery is real and it buys nothing for `open this path`.

---

## What each transport can actually do

| | URL scheme | XPC |
|---|---|---|
| Launch the app if not running | ✅ trivially, LaunchServices does it | ⚠️ manual: fetch endpoint → launch by bundle id → poll for registration |
| Pass parameters in | ✅ (percent-encoded query items) | ✅ (typed, JSON payloads) |
| Get a reply | ❌ **nothing** | ✅ typed request/reply |
| Report a failure the app detected | ❌ | ✅ with a distinct exit code |
| Stream progress | ❌ | ✅ |
| App pushes events unprompted | ❌ | ✅ — the app calls into the CLI |
| Session that survives minutes | ❌ | ✅ verified 3+ min, 18 heartbeats |
| Works with a sandboxed app | ✅ | ⚠️ needs an app-group-prefixed service name |
| Extra binaries to ship | none | a launch agent, embedded and signed |
| User-visible setup step | none | possible Login Items approval |

The single sharpest illustration, same app and same bad path:

```
$ remotectl open ~/NoSuchDirectory
remotectl: no such path: /Users/you/NoSuchDirectory      exit 4

$ remotectl open ~/NoSuchDirectory --via-url
opened remotecontrol://cli?action=open&param1=…          exit 0
```

Only the app can know the path does not exist. Over the URL scheme the CLI reports success anyway, because success means "macOS accepted the URL". That is not a fixable defect — there is no reply channel to fix.

---

## Launch behaviour

**URL scheme wins outright, and it is not close.** `NSWorkspace.shared.open(url)` launches the app, or delivers to it if already running. One call, no bookkeeping.

**XPC requires a dance**, because the app's endpoint only exists once the app is running and has registered it:

1. connect to the broker's Mach service (launchd starts the agent on demand),
2. ask for the app's endpoint,
3. if `nil`, launch the app by bundle identifier,
4. **poll** the broker until it registers — app registration races app launch,
5. open `NSXPCConnection(listenerEndpoint:)`.

Measured cold-start for `remotectl status` with the app not running: **0.284 s, one 250 ms poll.** So it is fast, and the bounded-poll loop is about 30 lines. But those 30 lines are load-bearing: without the bound, a broken app hangs the CLI forever, and without the retry, a nil endpoint immediately after launch looks like a failure when it is normal.

One genuine bonus: `remotectl ping` reaches the broker **with the app never launched**, because launchd starts the agent on demand. That gives a health check that is independent of the app — worth more than it sounds when debugging.

## Data return

This is the whole reason to consider XPC, and it delivers. `remotectl status` returns the app's real pid, uptime, visible window count, connected client count, and broker registration state — read out of the live process:

```
$ remotectl status
app status
  brokerRegistered  true
  clients           1
  pid               42219
  sessions          0
  uptime            151.4s
```

Structured payloads cross as JSON-encoded `Data` inside `@objc` protocol methods, which keeps `NSSecureCoding` class allowlisting entirely out of the picture. That decision (issue #0002) cost nothing and saved a category of problem — worth repeating in Batty.

Exit codes carry the outcome too — `2` broker unreachable, `3` app unavailable, `4` request failed, `5` app terminated the session. Scripts can branch without scraping stderr. The URL scheme has exactly one exit code: whether LaunchServices accepted the URL.

## Streaming

Works, and it is the capability with no URL-scheme analogue whatsoever. The CLI sets an object as its connection's `exportedObject`, and the app holds a proxy it can call at any time.

Verified: a session held open **3+ minutes** receiving an app-initiated heartbeat every 10 s, plus events triggered from the app; a 1 GB file hashed in 1 MiB chunks with progress streaming back and the final SHA-256 **matching `shasum -a 256`**; events fanning out to two concurrent sessions.

The cost is that streaming exposes every lifecycle edge at once — see below.

## Lifecycle complexity — the real price

This is where the honest accounting lives. The happy path took about a third of the effort; the rest went on states that only exist because a long-lived connection between three processes can fail in more ways than a one-shot URL can.

**What had to be handled explicitly:**

- `interruptionHandler` vs `invalidationHandler` on every connection, with different responses — interruption means the peer died but the connection object is reusable (re-register); invalidation means it is permanently dead (rebuild). Conflating them gives either a reconnect loop or a permanently broken connection.
- Broker restart under a running app → detect and re-register automatically.
- CLI killed with `kill -9` → the app must reap the orphaned session; there is no other signal.
- App quits mid-session → tell attached CLIs before invalidating, or they only learn from the connection dropping.
- Two concurrent sessions → fan-out, and ending one must not disturb the other.
- One-way calls give **no delivery confirmation**. `registerAppEndpoint` returns `Void`, so it returns whether or not the broker received it. Confirmation has to come from a subsequent round trip.

**Four bugs that only exist because of XPC**, all found by testing rather than review:

1. **A `SIGTRAP` crash on the failure path** (#0016). On a target built with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, closures passed to `remoteObjectProxyWithErrorHandler` / `interruptionHandler` / `invalidationHandler` inherit main-actor isolation, because Foundation types those parameters as plain non-`Sendable` closures. Swift emits an isolation assertion at the closure's entry; XPC calls it on its own queue; the process dies. **There is no compiler warning** — strict concurrency is fully satisfied. The fix is marking each closure `@Sendable`. The symptom was worse than the bug: the crash happened *inside the handler that would have logged the error*, so failures produced no output at all.
2. **`SMAppService.status` reporting `.enabled` while launchd had no such service**, which made the app unable to repair its own registration (#0016).
3. **A segfault printing events** — `String(format:)` with `%s` and a Swift `String`. Generic Swift, but it landed in the event-printing path and killed the CLI on the *first* event, which made it look like the session never started.
4. **~940 MB of RSS growth hashing a 1 GB file** — `FileHandle.read` returns `NSData`-backed `Data` that accumulates in an enclosing autorelease pool the read loop never drains. An `autoreleasepool` inside the loop takes it to +5 MB across 2.3 GB hashed.

**In fairness, the URL scheme produced a bug too** (#0003): SwiftUI's `.onOpenURL` inside a `WindowGroup` treats each incoming URL as a request for a *new window*, so window count climbed 1 → 2 → 3 per `open`, and macOS persisted them so later launches restored the accumulation. The fix was handling URLs in the AppKit delegate and adding `.handlesExternalEvents(matching: [])`. So the URL scheme is not free of surprises — it is just that its surprises are confined to one process.

**Non-obvious build and packaging traps, all XPC-side:**

- `dstSubfolderSpec = 1` ("Wrapper") in a Copy Files phase is the `.app` root, **not** `Contents/`. Getting it wrong fails code signing with `unsealed contents present in the bundle root`, which names neither the file nor the phase.
- Xcode does not sign Mach-O files a script phase drops into the bundle. An unsigned nested binary breaks the seal, and launchd refuses to start an improperly signed agent — surfacing as an opaque registration failure.
- A binary in `Contents/Resources/bin/` is sealed as a **resource**, not as nested code, so `codesign --deep --strict` never mentions it. It looks unsigned when it is not.
- Xcode rewrites `project.pbxproj` while it has the project open — mid-edit it deleted the build configurations for a newly hand-added target and left a dangling build file, surfacing as `error: SWIFT_VERSION '' is unsupported`.

## Setup and distribution burden

- **A user-visible approval step may appear.** `SMAppService.register()` can land in `requiresApproval`, requiring the user to enable the app under System Settings → General → Login Items & Extensions. Until then every CLI command fails. On the development machine it went straight to `enabled` with no prompt — but that is not something to rely on, and it means you cannot even test the approval path reliably.
- **A launch agent is now part of the product.** It must be embedded, signed with the same team identity, and its plist `Label`, filename, `MachServices` key, and the Swift constant must all be the same string.
- **`SMAppService` state outlives builds** and is keyed to the bundle, so multiple copies of the app on disk confuse launchd. Recovering a wedged state can mean `sfltool resetbtm` and a reboot. This is the single most annoying thing about developing against it.
- **Sandboxing changes the design.** A sandboxed app can only use Mach service names prefixed with an app-group identifier. Batty is unsandboxed today, so this is fine — but it is a constraint to remember, not a detail.

## Effort actually spent

From this repo's per-issue work logs (`issues/Issues.md`). Wall clock is agent time, so treat it as relative rather than as an estimate for a human. Costs are accurate to about the nearest dollar — work that spilled across a commit boundary lands in the neighbouring bucket.

| Phase | Issues | Cost |
|---|---|---:|
| Scaffolding (build settings, shared package) | #0001, #0002 | $3.03 |
| **Phase 0 — URL scheme baseline** | #0003, #0004 | **$9.08** |
| Phase 1 — broker agent, registration, ping | #0006, #0007, #0008 | $11.50 |
| Phase 2 — endpoint handoff, status | #0009, #0010 | $10.95 |
| Bug from the XPC failure path | #0016 | $3.45 |
| CLI embedding | #0005 | $4.49 |
| Phases 3–4 — sessions, digest, hardening, docs | #0011–#0015 | $22.12 |
| **Phases 1–4 — XPC total** | #0005–#0013, #0016 | **~$52** |
| CLI install action, then moving it to `/usr/local/bin` | #0023, #0024 | $16.46 |
| Signing incident, diagnosis, and guards | — | $27.43 |
| Release script and the remaining issue backlog | #0017–#0031 | $21.94 |
| Reference docs, Batty reconciliation, installer move | #0025–#0029 | $12.45 |
| **Whole session** | | **$149.25** |

The Phase 0 number is inflated: #0003 also built the status UI and the message log that every later phase reports into, and it absorbed the window-leak debugging. The transport itself was a couple of hundred lines. **XPC cost roughly 5–6× the URL scheme** and produced four times the bugs.

Three things about this table are worth more than the ratio:

**An earlier version of it read "~$28 for XPC" and was wrong**, because it was computed from a cost table that stopped at #0010 and reported a snapshot as a total. The real XPC figure is about $52.

**The single most expensive line is not feature work.** The signing incident — diagnosing why certificates were being revoked, then writing the guards — cost $27.43, more than half the entire XPC implementation. None of it was necessary to the experiment; all of it was caused by running repeated *signed* builds against an Automatic-signing project. Unsigned builds (`CODE_SIGNING_ALLOWED=NO`) would have avoided the whole line item.

**Cost tracked conversation length, not difficulty.** Cache reads were 99% of billed tokens and 79% of cost across the session; output tokens — the actual code — came to $10.84 of $149.25. The same class of work cost $1.27–$2.11 early, $11.33 late, and $1.10–$3.81 again after the context was compacted. For anyone budgeting a port: the number to control is session length, not scope.

## Recommendation for Batty

**Adopt a hybrid, and let the command decide the transport.**

**Use the URL scheme when** the command is fire-and-forget and the user will see the result in the app anyway — open a path, focus a window, start something. `batty open ~/Developer` does not need a reply; the app coming to the front *is* the reply. Paying for an embedded launch agent to return `ok: true` would be silly.

**Use XPC when** the CLI's own output is the product:

- `batty status` — anything printing live app state to a terminal or feeding a shell pipeline.
- Anything scripted, where exit codes must reflect what the app actually did.
- Long-running operations where progress matters.
- Anything that should stream, or that the app should be able to push to.

**Concretely:** ship the URL scheme first because it is nearly free, and add the XPC layer when the first command genuinely needs a reply. Do not build the broker speculatively.

**If you adopt XPC, budget for the lifecycle work, not the transport.** Connecting two processes is an afternoon. Making it survive a broker restart, a `kill -9`, an app quit, a wedged `SMAppService` registration, and two concurrent clients is the actual project — and on a `MainActor`-default target you will hit the `@Sendable` crash described above, with no compiler help, on the failure path where it is hardest to see.

**Do not skip the health check.** `remotectl ping` talking only to the agent, never the app, was the most valuable diagnostic in this repo. If it passes, launchd owns the name; if it fails, nothing app-side is worth looking at. Build the equivalent early.

**Consider whether you need a session at all.** Request/reply (Phase 2) delivered most of the value — real data back, real exit codes — for a fraction of the complexity of Phase 3's long-lived sessions. If Batty has no streaming use case, stopping at request/reply is a defensible and much cheaper endpoint.

## What would change when porting into Batty

- **BattyKit owns** `XPCProtocols.swift`, `Messages.swift`, `ServiceNames.swift`, and the `batty` CLI target — the same split as `BridgeKit` here. The protocols must be shared, and BattyKit is already the shared library.
- **The app target owns** the agent embedding: the `BrokerAgent`-equivalent executable target, the two Copy Files phases, and the `SMAppService` registration plus its status UI. None of this can live in the package, because `SMAppService.agent(plistName:)` resolves relative to the *calling* bundle.
- **Keep the CLI out of the Xcode package product graph.** Embed it with a Run Script phase that runs `swift build` and then signs the copied binary explicitly, exactly as `#0005` does. Adding the `executableTarget` as a package product dependency is what broke Batty's own 372-test gate: it pulls the executable into the scheme's build graph, after which the `xcodebuild` test runner can no longer resolve BattyKit's `Bundle.module` resource bundle and every test crashes at launch. `swift test` does not reproduce it. (This repo previously described that as a "deadlock" — it is not, and the mistake came from citing `docs/cli-tool-install.md` without having read it. See #0027.)
- **Reuse `ServiceNames` as the single source of truth**, with the launchd `Label` and plist filename *derived* from the service name rather than repeated. The four-strings-must-match problem is the plan's most expensive gotcha and deriving them halves the places it can go wrong.
- **Reuse the exit-code vocabulary** — distinguishing "broker unreachable" from "app not running" from "app said no" is what makes the CLI scriptable, and it costs nothing to define up front.
- **Port the app-side repair path** (#0016). Do not trust `SMAppService.status`; drive re-registration from a failed call, once per launch.
- **`log stream` with a shared subsystem across app, agent, and CLI** was the only practical way to watch a handoff. Wire it in from the first commit, not when something breaks.
- **Batty had already solved CLI installation** in #0249, with a 688-line write-up at `docs/cli-tool-install.md` naming the exact mechanism — and this project did not read it, producing three divergences including installing to a directory that is not on the default `PATH`. **That is a finding in its own right**, and the more general one is: check whether a sibling project has already solved the sub-problem *before* building it, not after a user asks why you did it differently. The reconciliation is in #0027; two of this repo's improvements (`isBundleDurable`, and a four-state install inspection instead of a boolean) are worth porting *back* into Batty.
- **Take `docs/` with you.** [docs/](docs/README.md) is the transferable form of everything above — architecture, embedding and install, the Swift 6 concurrency traps, and build/release — written for a different app rather than as a description of this one. It is a better starting point for the port than this file or the README.
