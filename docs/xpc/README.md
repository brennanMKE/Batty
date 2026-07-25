# Building a CLI that talks to your Mac app

> **Vendored copy — not a Batty document.** Copied 2026-07-24 from
> `RemoteControl/docs/README.md` (a sibling, throwaway, read-only checkout
> at `/Users/brennan/Developer/brennanMKE/RemoteControl`) for Batty issue
> [#0267](../../issues/0267.md). It describes the RemoteControl XPC
> prototype — a different app — not Batty; the "must rename" / "copy
> verbatim" markers throughout are written for that porting exercise. The
> body below is unedited from the source, with one exception forced by the
> flat vendored layout: the "For running *this* app" paragraph's links
> (`../README.md`, `../FINDINGS.md`) pointed at the RemoteControl repo
> root — in this folder, `FINDINGS.md` is a sibling (read it as
> `FINDINGS.md`, no `../`), and `../README.md` is worse than a dead link:
> it silently resolves to **Batty's own** `docs/README.md` instead of
> erroring, because the repo-root `README.md` this pointed to was not
> vendored at all. Don't follow it expecting RemoteControl content.
>
> **Any bare `#NNNN` below is a RemoteControl issue** (that project's own
> `issues/0001`–`issues/0031` tracker), never a Batty issue — Batty's
> tracker uses the identical `#NNNN` form for a disjoint set of numbers.
> Links to files this vendoring did not copy (RemoteControl's `issues/`
> folder, its repo-root `README.md`) will not resolve; see the source
> checkout above if it still exists.

Reference material extracted from the RemoteControl prototype, written for
someone building a **different** app. Nothing here describes RemoteControl for
its own sake — where this project's names appear they are examples, and each
document marks what must change and what can be copied verbatim.

For running *this* app, see the [README](../README.md) at the repo root. For
whether the pattern was worth adopting at all, see
[FINDINGS.md](../FINDINGS.md). These documents answer a different question:
*how do I do this in my app?*

## The documents

| Document | Covers |
|---|---|
| [xpc-cli-architecture.md](xpc-cli-architecture.md) | Why a plain app cannot publish a Mach service, the broker launch agent, endpoint handoff, the protocol trio, `SMAppService` registration |
| [cli-embedding-and-install.md](cli-embedding-and-install.md) | Building the CLI in a Swift package, embedding it in the bundle, signing it, and the File-menu install action with privilege escalation |
| [swift-concurrency-and-xpc.md](swift-concurrency-and-xpc.md) | The `@Sendable` callback trap that crashes with no compiler warning, `nonisolated` helpers, moving a non-`Sendable` connection across isolation |
| [build-and-release.md](build-and-release.md) | Local install without a Developer ID or notarization, the release script, and the certificate-revocation hazard |

Read them in that order the first time. After that they stand alone.

## Decide this before you build anything

The pattern below is real work: an embedded launch agent, a user-visible
approval step, a broker process, and three `@objc` protocols. Most of that cost
buys one specific capability — **the CLI can print something the app computed**.
If your CLI does not need that, you do not need any of it.

### A URL scheme is enough when…

The CLI's job is to *tell the app to do something*. `open
"yourapp://action?param=value"` launches the app if needed, hands it
parameters, and exits. That is roughly twenty lines total: a `CFBundleURLTypes`
entry in `Info.plist`, and `application(_:open:)` in your app delegate.

It cannot return anything. The CLI exits before the app has finished, always
succeeds as far as the shell can tell, and produces no output. For `myapp open
~/Developer` that is fine and arguably correct.

### You need XPC when…

The CLI's **output is the product** — a status the app knows, a value the app
computed, progress on work the app is doing, or an exit code that reflects what
actually happened. Concretely:

- `yourctl status` printing live state, where a wrong answer is worse than none
- `yourctl build --watch` streaming progress while the app works
- anything scripted, where `if ! yourctl check; then` has to mean something

The dividing line is not "one-shot versus long-lived". It is **whether a reply
is required**. Once you need a reply you need a connection, and once you need a
connection from a process that may start before the app is running, you need
everything in
[xpc-cli-architecture.md](xpc-cli-architecture.md).

### The honest middle

Request/reply — `perform(_:reply:)` — delivers most of the value for a fraction
of the complexity of long-lived sessions. Sessions (the app calling *into* an
attached CLI, unprompted) were validated here and work, but they add a session
registry, teardown on five different paths, orphan reaping, and a reverse proxy
the app has to hold. If you are unsure, build request/reply, ship it, and add
sessions when a concrete feature demands push.

## What we would do differently

Three lessons that cost real time here and are cheap to avoid:

**Put the installer in the package from the start.** `CLIInstaller` was written
into the app target by default rather than by decision, then moved. The move is
what made its state machine testable, which is where the actual bugs were.
Anything that only touches `Bundle`, `FileManager`, and `NSAppleScript` belongs
in the package.

**Read the reference project's docs before implementing, not after.** This
project had a sibling app that had already solved CLI installation, with a
688-line write-up naming the exact mechanism. It went unread. Three divergences
resulted, two of which a user found by using the app — including installing to a
directory that is not on the default `PATH`. Worse, a code comment cited that
document as authority for a claim it does not make. If a plan names a reference,
open it.

**Treat "it compiles and the happy path works" as the start of verification.**
The two most expensive defects here — a `SIGTRAP` in the error handler, and 940
MB of RSS growth while hashing a file — were both invisible to a passing build
and a successful manual test. One needed the failure path deliberately
triggered; the other needed memory measured.
