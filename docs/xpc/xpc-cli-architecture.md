# The XPC CLI↔app architecture

> **Vendored copy — not a Batty document.** Copied 2026-07-24 from
> `RemoteControl/docs/xpc-cli-architecture.md` (a sibling, throwaway,
> read-only checkout at `/Users/brennan/Developer/brennanMKE/RemoteControl`)
> for Batty issue [#0267](../../issues/0267.md). It describes the
> RemoteControl XPC prototype — a different app — not Batty; the
> "must rename" / "copy verbatim" markers throughout are written for that
> porting exercise. The body below is unedited from the source.
>
> **Any bare `#NNNN` below is a RemoteControl issue** (that project's own
> `issues/0001`–`issues/0031` tracker), never a Batty issue — Batty's
> tracker uses the identical `#NNNN` form for a disjoint set of numbers.
> Links to files this vendoring did not copy (RemoteControl's `issues/`
> folder, its repo-root `README.md`) will not resolve; see the source
> checkout above if it still exists.

How a command-line tool holds a real connection to your running GUI app, gets
replies, and can be called back by the app unprompted.

Throughout, substitute your own names for these:

| This project | Yours | Constraint |
|---|---|---|
| `RemoteControl` | your app | — |
| `remotectl` | your CLI | any name; it becomes the binary name |
| `BridgeKit` | your package | holds the shared contract |
| `BrokerAgent` | your agent | a second executable in the same bundle |
| `co.sstools.RemoteControl.broker` | `com.example.yourapp.broker` | reverse-DNS; see [The four-string rule](#the-four-string-rule) |

## Why this is harder than it looks

The obvious design — the app publishes a Mach service, the CLI connects to it —
does not work, for a reason that is not obvious until you hit it:

> **A plain application cannot publish a named Mach service.**

Publishing a name means holding the *receive right* for it, and only **launchd**
hands those out. launchd hands one to a process it started, from a job whose
plist declares a `MachServices` key. An app you launched from Finder was not
started that way, so it has no name to be found at, and `NSXPCListener(machServiceName:)`
from an app fails at runtime with nothing useful to say about why.

This single fact generates the entire architecture. You need *something* launchd
started to own the name. That something is a small **broker launch agent** shipped
inside the app bundle.

The second fact that shapes everything:

> **`NSXPCListenerEndpoint` is a live Mach right, not an address.**

An app *can* create an anonymous listener (`NSXPCListener.anonymous()`), which
yields an `NSXPCListenerEndpoint` that anyone holding it can connect to. But an
endpoint is not data. It cannot be written to a file, put in `UserDefaults`,
printed, or passed on a command line. It can only be *sent over an existing XPC
connection*, because handing it over is a Mach right transfer that the kernel
mediates.

So the CLI cannot be told where the app is. Something both processes can already
reach has to hold the endpoint and hand it over. That is the broker's whole job.

## The shape

```
                    ┌──────────────────────────────────────┐
                    │  YourApp.app                         │
                    │                                      │
   launchd ────────▶│  Contents/MacOS/BrokerAgent          │
   (owns the        │    NSXPCListener(machServiceName:)   │
    mach name)      │    holds: appEndpoint                │
                    │              ▲         │             │
                    │   register   │         │  hand over  │
                    │              │         ▼             │
                    │  Contents/MacOS/YourApp              │
                    │    NSXPCListener.anonymous()         │
                    └──────────────────────────────────────┘
                                   ▲
                                   │  direct connection,
                                   │  broker no longer involved
                                   │
                    ┌──────────────┴───────────────────────┐
                    │  yourctl  (any process, any time)    │
                    └──────────────────────────────────────┘
```

Read it as three steps:

1. **App starts** → creates an anonymous listener → connects to the broker's
   Mach service → sends its endpoint.
2. **CLI starts** → connects to the broker's Mach service (launchd starts the
   broker on demand if it isn't running) → asks for the app's endpoint.
3. **CLI connects directly to that endpoint.** From here the broker is out of
   the path entirely. It is a bootstrap, not a router — no traffic, no latency,
   no failure mode in the middle of a session.

That last point is worth being deliberate about. It is tempting to have the
broker proxy messages, since it is already there and already reachable. Don't:
you would double every hop, add a process that can die mid-request, and have to
re-implement reply plumbing the direct connection gives you for free.

### What the broker must *not* be

Keep it as close to empty as you can. This one is 150 lines and has exactly
three responsibilities: answer a liveness ping, store one endpoint, hand it out.
No app logic, no state that matters, nothing worth persisting. Being restartable
without consequence is what makes the whole arrangement robust — `launchctl
kickstart -k` on the broker is survivable, and the app notices and
re-registers.

## The protocol trio

Put all three in your shared package so the app, the agent, and the CLI compile
against the same declarations. These are `@objc` protocols because
`NSXPCConnection` requires it.

**Copyable nearly verbatim** — rename and adjust the payloads:

```swift
/// What the broker exposes on its mach service.
@objc public protocol BrokerProtocol {
    /// Liveness check that does not depend on the app running at all.
    func brokerPing(reply: @escaping @Sendable (String) -> Void)
    /// Called by the app after it creates its anonymous listener.
    func registerAppEndpoint(_ endpoint: NSXPCListenerEndpoint)
    /// Called by the CLI. Replies `nil` when no app has registered.
    func appEndpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void)
}

/// What the app exposes to a connected CLI over the direct connection.
@objc public protocol AppServiceProtocol {
    func ping(reply: @escaping @Sendable (String) -> Void)
    /// One-shot request/reply. Both are JSON-encoded.
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Begins a long-lived session; events flow back over CLIClientProtocol.
    func startSession(_ request: Data, reply: @escaping @Sendable (String) -> Void)
    func endSession(_ sessionID: String)
}

/// The CLI's callback surface, set as `exportedObject` on the CLI side.
/// This is what makes the connection bidirectional.
@objc public protocol CLIClientProtocol {
    func event(_ payload: Data)
    func sessionDidEnd(_ sessionID: String, message: String)
}
```

Three decisions in there are load-bearing.

### Mark every reply block `@escaping @Sendable`

Do this from the first line of code you write. XPC invokes reply blocks on its
own queues; if the closure type is not `@Sendable`, a closure literal written
inside a `@MainActor` type inherits main-actor isolation and **traps at
runtime**. Declaring it in your own protocol makes the compiler enforce the
correct thing at every call site you own.

This is not hypothetical. It is the single most expensive defect in this
project's history, and the reason it only hit the *Foundation-supplied* handlers
(which you cannot annotate) is that the protocols above were declared this way
on day one. Full treatment in
[swift-concurrency-and-xpc.md](swift-concurrency-and-xpc.md).

### Send structured payloads as JSON-encoded `Data`

Not as classes conforming to `NSSecureCoding`. The alternative means an
`@objc` class per message type, a `classesForSelector` allowlist on every
interface, and debugging silent decode failures across a process boundary.
`Data` plus `Codable` structs gives you:

```swift
public struct BridgeRequest: Codable, Sendable { … }
public struct BridgeResponse: Codable, Sendable { … }
public struct BridgeEvent: Codable, Sendable { … }
```

which are ordinary Swift value types, testable without XPC, and printable when
something goes wrong. The cost is one encode/decode per message, which is
irrelevant next to the IPC itself.

### Route interfaces through a factory

```swift
public enum XPCInterfaces {
    public static var broker: NSXPCInterface { NSXPCInterface(with: BrokerProtocol.self) }
    public static var appService: NSXPCInterface { NSXPCInterface(with: AppServiceProtocol.self) }
    public static var cliClient: NSXPCInterface { NSXPCInterface(with: CLIClientProtocol.self) }
}
```

Both sides must configure `remoteObjectInterface` and `exportedInterface` with
matching interfaces **before** `resume()`. Mismatch it and calls fail *silently*
— no error, no reply, no crash, nothing in the log. A factory is the cheapest
available defence against a typo you would otherwise spend an hour finding.

## The launch agent plist

Ships at `Contents/Library/LaunchAgents/<label>.plist` inside your bundle.

```xml
<key>Label</key>
<string>com.example.yourapp.broker</string>

<!-- Relative to the bundle root, NOT absolute. Program with an absolute path
     breaks the moment the app moves, and in development it lives in DerivedData. -->
<key>BundleProgram</key>
<string>Contents/MacOS/BrokerAgent</string>

<!-- The key that makes this possible: launchd reserves the name and hands
     this process the receive right. An app cannot do this for itself. -->
<key>MachServices</key>
<dict>
    <key>com.example.yourapp.broker</key>
    <true/>
</dict>
```

Note there is no `RunAtLoad`. You do not want one — launchd starts the agent
**on demand** when someone connects to the Mach service, which is exactly the
behaviour that lets `yourctl ping` work with the app never having been launched.

### The four-string rule

These four must be the identical string:

1. the plist's **filename** — `com.example.yourapp.broker.plist`
2. the plist's **`Label`**
3. the **`MachServices`** key
4. the name your code connects to

Get any one wrong and launchd **silently declines** to reserve the name. There
is no error at install time, no warning at registration, nothing in the log.
It surfaces much later as an unexplained "connection invalid" in the CLI, at
which point you are debugging the wrong layer.

Defend against it in code — derive everything from one constant:

```swift
public enum ServiceNames {
    public static let broker = "com.example.yourapp.broker"
    public static let agentLabel = broker
    public static let agentPlistName = "\(agentLabel).plist"
    public static let agentBundleProgram = "Contents/MacOS/BrokerAgent"
}
```

That collapses three of the four to one edit. Only the plist file can still
drift, so put a comment in it saying so.

**Sandboxing:** an unsandboxed app can use any reverse-DNS string. A sandboxed
one must prefix the Mach service name with an application-group identifier.
This project is unsandboxed and did not exercise that path.

### Getting the plist into the bundle

A Copy Files build phase with `dstSubfolderSpec` pointing at
`Contents/Library/LaunchAgents`. **Watch this specific trap:**
`dstSubfolderSpec = 1` is the `.app` **root**, not `Contents/`. Setting it to 1
with `dstPath = Library/LaunchAgents` puts the folder at
`YourApp.app/Library/LaunchAgents`, and code signing then fails with *"unsealed
contents present in the bundle root"* — a message that says nothing about what
you actually did. Use `dstPath = Contents/Library/LaunchAgents`.

## Registering the agent

```swift
let service = SMAppService.agent(plistName: ServiceNames.agentPlistName)
try service.register()
```

The user sees the agent in **System Settings ▸ General ▸ Login Items &
Extensions**, and can disable it there. First registration may land in
`.requiresApproval`, which is a normal state and not an error — your UI should
say so rather than reporting failure.

### `SMAppService.status` can lie

The single most confusing behaviour in this area:

> `SMAppService.status` reports what *it* believes, which can disagree with what
> launchd actually has.

Observed directly: after `launchctl bootout` removed the job, `status` still
returned `.enabled` while `launchctl print` reported `Could not find service`.
Any `registerIfNeeded()` that short-circuits on `.enabled` can therefore never
repair itself — it believes it is fine while nothing is listening.

Two defences, and you want both:

**1. Confirm registration with a round trip, not a return.** One-way XPC calls
return as soon as the message is *queued*. `registerAppEndpoint(_:)` returning
tells you nothing. Follow it with a ping and only treat yourself as registered
inside the reply:

```swift
proxy.registerAppEndpoint(listener.endpoint)
proxy.brokerPing { @Sendable [weak self] description in
    Task { @MainActor [weak self] in
        self?.isRegisteredWithBroker = true    // only here
        self?.log.success("endpoint registered and confirmed — \(description)")
    }
}
```

**2. Repair by unregistering first.** When the broker turns out unreachable,
call `unregister()` (tolerating a throw — expected when launchd has already lost
the job) and then `register()` again. Guard it with a flag so a genuinely broken
environment produces one clear error instead of a loop, and reset the flag on a
confirmed registration.

Measured self-heal from a deliberately wedged state, start to finish in 88 ms:

```
[app]    launched — pid 42219
[agent]  already enabled — launchd owns …broker      ← the stale claim
[xpc]    anonymous listener resumed
[xpc]    broker connection invalidated
[xpc]    broker unreachable: Couldn't communicate with a helper application.
[agent]  re-registering agent (unregister, then register)
[agent]  status Enabled → Not registered
[agent]  status Not registered → Enabled
[broker] listening on …broker (pid 42222)
[broker] app endpoint registered
[xpc]    endpoint registered and confirmed — broker pid 42222
```

## Request/reply

The path to build first. Round trip measured at **0.3 ms**, so treat the IPC
cost as free relative to anything you do around it.

CLI side, with the two things that are easy to get wrong:

```swift
let connection = NSXPCConnection(machServiceName: ServiceNames.broker)
connection.remoteObjectInterface = XPCInterfaces.broker
connection.resume()
```

**Always attach an error handler and always use a timeout.** A CLI that hangs
forever because the app is wedged is worse than one that exits 3. Two patterns
carried this project:

- **`ResumeOnce`** — a small wrapper guaranteeing a continuation resumes exactly
  once. Without it, an error handler *and* a reply both firing traps with
  `SWIFT TASK CONTINUATION MISUSE`, and a timeout racing a reply is exactly that
  situation.
- **Timeout invalidates the connection.** Just abandoning the wait leaves the
  connection alive and the process may not exit. Invalidate it as part of timing
  out.

Give each failure mode its own exit code so scripts can tell them apart:

| Code | Meaning |
|---|---|
| 2 | broker unreachable — agent not registered, or awaiting approval |
| 3 | broker answered but no app endpoint, and the app could not be started |
| 4 | delivered, app replied `ok: false` |
| 5 | app went away while a session was attached |

### Launching the app on demand

When the broker reports no registered endpoint, the CLI can start the app
(`NSWorkspace`, or `open -b <bundle-id>`) and poll the broker until an endpoint
appears. Bound the wait and exit 3 when it expires. This is what makes `yourctl
status` work as the first thing a user types after a reboot.

## Long-lived sessions

Optional, and genuinely more work. What it buys: the app calls **into** the CLI,
unprompted, for as long as the CLI stays attached.

The mechanism is one line on the CLI's connection:

```swift
connection.exportedInterface = XPCInterfaces.cliClient
connection.exportedObject = WatchClient(…)
```

Now the app can obtain a `CLIClientProtocol` proxy from the incoming connection
and push whenever it likes. Everything else is bookkeeping:

- a **session registry** in the app, keyed by session id, each holding its proxy
- **teardown on every path** — CLI detaches, CLI is `kill -9`ed, app quits,
  broker restarts, connection invalidates
- **orphan reaping**, because a `kill -9`ed CLI leaves a session the app must
  notice via the connection's invalidation handler
- a **signal source** in the CLI (`DispatchSourceSignal` for SIGINT) so Ctrl-C
  tells the app to end the session rather than dropping the connection

Validated here: two concurrent sessions ran **3 min 50 s**, each receiving **22
consecutive heartbeats**, surviving a broker restart and a `kill -9` of a third
session. Ending one left the other attached. Session count returned to zero
after every teardown path.

### Streaming work, and the trap in it

The convincing demo is streaming progress on real work — hashing a large file,
with `progress` events and a final `result` the CLI prints. Two findings:

**Wrap the read loop body in `autoreleasepool`.** `FileHandle.read(upToCount:)`
returns `NSData`-backed `Data`, which lands in the enclosing autorelease pool.
In a tight loop that pool is not drained until the whole operation finishes, so
every chunk stays alive to the end. Hashing 1 GB grew RSS by **~940 MB** — the
exact unbounded growth streaming exists to avoid, and invisible unless you
measure it. With the pool inside the loop: **+5.4 MB across 2.3 GB**.

```swift
while true {
    let done = try autoreleasepool {                 // inside the loop
        guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty
        else { return true }
        hasher.update(data: chunk)
        return false
    }
    if done { break }
}
```

**Throttle progress events, then don't panic at the result.** A 100 ms throttle
on a fast SSD produced only three progress lines for 250 MB, because the whole
digest took 0.2 s. That looks broken and is correct.

## The URL scheme baseline, and one gotcha worth stealing

Even if you build the XPC path, keep a URL scheme for fire-and-forget actions —
it is twenty lines and it is the right tool for `yourctl open <path>`.

One trap, because it took three attempts here: in a SwiftUI app, **handle the
URL in `application(_:open:)` on your `NSApplicationDelegate`, and also add
`.handlesExternalEvents(matching: [])` to your `WindowGroup`.** Using SwiftUI's
`.onOpenURL` opens a *new window per URL* — the count climbs 1, 2, 3 and
persists across launches through window restoration. Neither change alone was
sufficient: the delegate handles the event, and the modifier stops the
`WindowGroup` from also claiming it.

## Where the cost actually is

For calibration, from this project's own accounting: the XPC path took roughly
ten times the effort of the URL scheme, and **almost none of that was the XPC
API itself**. It was the launch agent (getting the plist into the bundle
correctly, `SMAppService` states, the four-string rule) and Swift 6 concurrency
(the `@Sendable` trap, isolation on helpers). Budget accordingly: if you have
done launch agents before, this is much smaller than it looks; if you have not,
the XPC calls are the easy part.
