# System Metrics view — design (phase 1 of `#0314`)

Design proposal for `#0314`'s design-gated phase 1: the whole-system
counterpart to `#0305`'s Process Status view, a `system-metrics` Pane kind
showing thermal state plus the metrics `top`/Activity Monitor typically
show — CPU, memory, load average, the full process list. **No code ships
with this document** except the throwaway feasibility spike described in
§1, which was run in a scratch directory outside the repository and is not
part of this commit. Read `docs/pane-kinds.md` (where kind lives, how
`PaneView` branches, the terminal-host boundary) and
`docs/pane-view-lifecycle.md` (the `PaneContentLifecycle` contract this
view is a client of) first — this document assumes both and does not
re-explain them. Also read `docs/design/process-status-view.md` (`#0305`
phase 1) in full: `issues/0314.md` is explicit that this view "inherits
#0305's spike findings rather than redoing them," and this document holds
to that — §1 below cites #0305's per-pid findings instead of re-measuring
`task_for_pid`/libproc cost for a single target, and only measures what
#0305 didn't need: system-wide (non-process) metrics, and the *multiplied*
cost of sampling libproc across every process on the machine rather than
one.

Every source citation below was re-verified against the tree on
2026-08-08 while writing this document (branch `issue/0314`), and the
citations touched by review round 1's corrections (§1.3, §1.4, §1.7, and
everything downstream of them) were independently re-verified a second
time while addressing that review, including re-running the SMC probe
from scratch rather than accepting the reviewer's re-run on trust.

---

## 0. What's already decided upstream, and what this document adds

`#0302`/`#0303` settled the *shape* a non-terminal kind must fit into;
`#0304`/`#0305` phase 1 set the visual and documentation precedent this
view follows, and are the two documents this one departs from least —
`#0305` especially, since both views sample process state via libproc.
This document is the fourth thing to fill that shape in:

- **Kind identifier.** Following `docs/pane-kinds.md` §5's "one string,
  three call sites" rule (used by `#0304` for `git-status`, `#0305` for
  `process-status`), this document names the kind `system-metrics` — the
  `PaneContentKind` raw value, the CLI `--view` flag value, and the
  `TopologyPanePayload.kind` JSON value are all literally
  `"system-metrics"`.
- **The pane has no Tab bar and no `TabRuntime`s** (`docs/pane-kinds.md`
  §1) — everything below describes the single view that fills a
  `system-metrics` pane's body.
- **The conformer is model-owned**, hung off `PaneRuntime` the same way
  `docs/pane-view-lifecycle.md` §5 requires for every non-terminal kind.
  This document names the concrete conformer, `SystemMetricsPaneContent`,
  and what it holds.
- **Not built here**: the `PaneContentKind` enum case, `PaneRuntime.kind`,
  `PaneView`'s kind-switch, the CLI verb (`#0315`). This document is
  scoped to the view's own design — the spike, its metrics, its refresh
  strategy, its visual content — so `#0314`'s phase 2 and `#0315` each
  have a settled thing to wire in.
- **`#0314` is explicit that no design work happens before the spike.**
  `issues/0314.md`: "a design premised on unavailable data is a known
  failure mode for this project." §1 runs first; §§2-4 are bounded by what
  it actually found, not by what the issue's own "needs investigation"
  list hoped for.
- **Singleton-per-scope.** `docs/pane-kinds.md` §5 names `#0314`'s
  hypothetical kind (there called `.thermals`, this document's actual
  `system-metrics`) as "a plausible `true` case" for
  `PaneContentKind.isSingletonPerSession`. This document confirms that:
  two `system-metrics` panes in one Session would show the *identical*
  whole-machine state twice — there is no per-pane targeting parameter the
  way `process-status`'s pid or `git-status`'s path gives each pane a
  distinct subject. `isSingletonPerSession = true` for this kind; enforcing
  it is `#0315`'s, per `docs/pane-kinds.md` §5.

---

## 1. Feasibility spike: what's actually obtainable, measured on this machine

Spike code ran as throwaway Swift scripts (`swift <file>.swift`, no Xcode
project) in `/private/tmp/.../scratchpad/spike0314/`, outside the
repository, not part of this commit, on: **macOS 26.5.1 (build 25F80),
Swift 6.3.3 (swiftlang-6.3.3.1.3), arm64**, same unsandboxed, same-uid
process class Batty itself runs as (`CLAUDE.md`: `ENABLE_APP_SANDBOX =
NO`). This is verifiably the **same physical machine** `#0305`'s spike
ran on, not just the same OS build: a whole-system libproc sweep run for
this spike (§1.7) found Finder's `phys_footprint` at 758.4 MB, matching
`#0305`'s independently-measured 758.35 MB (`docs/design/
process-status-view.md` §1.2) almost exactly — worth naming because it
means every architecture-specific finding below (§1.4 especially) carries
the same caveat #0305 already flagged: Apple silicon only, not
independently re-verified on Intel.

### 1.1 What's inherited from `#0305`, not re-run

Per `issues/0314.md`'s own instruction, this spike does not re-measure:
`task_for_pid` failing for every target (`docs/design/
process-status-view.md` §1.1); libproc (`proc_pidinfo`, `proc_pid_rusage`,
`PROC_PIDLISTFDS`, `proc_pidpath`, `sysctl(KERN_PROCARGS2)`) succeeding for
same-uid at ~0.03 ms combined per process (§1.2/§1.3); `ps` costing 65 ms
and `top -l 1` costing 400 ms per call (§1.3); `ESRCH` vs `EPERM`
distinguishing exited from permission-denied (§1.4); `proc_name` and
`KERN_PROCARGS2` failing for a different-uid target while `proc_pidpath`
succeeds (§1.6). §1.7 below builds directly on these — it is the same set
of libproc calls, multiplied across every pid on the machine instead of
one — and independently re-confirms the permission-tier finding **at
whole-system scale** (§1.7's name-vs-path table), which #0305 established
only for a single target.

### 1.2 `ProcessInfo.processInfo.thermalState` — works, coarse, negligible cost; notification unobserved

```swift
let state = ProcessInfo.processInfo.thermalState
```

Observed: `.nominal` (`rawValue = 0`) on this machine at spike time — an
idle Mac mini, as expected. Cost: **100,000 reads in 12.4 ms, 0.00012
ms/call** — free at any plausible sampling interval.

`NotificationCenter.default.addObserver(forName:
ProcessInfo.thermalStateDidChangeNotification, ...)` registers without
error. **What this spike did *not* observe**: an actual firing. The
observer was live for 5 seconds of idle wall-clock time and the
notification did not fire — expected, since nothing forced a genuine
thermal-state transition (no sustained CPU load was run deliberately,
because doing so on a machine this session doesn't own the thermal
history of is not a reasonable thing for a throwaway spike script to
attempt). **This is a real, named gap, not glossed over**: registration
working and delivery working are different claims, and only the first is
directly observed here. The API is Apple's own public, documented
notification (not a private or undocumented one, unlike everything in
§1.4), so the residual risk is low, but §2 states plainly that "the
notification fires" is carried from Apple's documentation, not
independently reproduced by this spike, the same honesty standard
`docs/design/process-status-view.md` §1.5 applied to the
`task_for_pid`-allow entitlement claim it also couldn't test.

### 1.3 IOKit / `ioreg` — no readable value *in the registry itself*; this does not mean nothing is readable at all

`ioreg -l` (full registry dump, 41,266 lines on this machine, re-confirmed
at 41,317 lines on a later run — process/device churn between runs, not a
discrepancy) was grepped for every plausible thermal-adjacent term:

- **`fan`** (case-insensitive): **zero matches anywhere in the entire
  dump**, confirmed on two separate runs. A Mac mini M4 does have a fan;
  nothing about it is an `ioreg`-visible **property**.
- **`thermal`**: matches only `thermalmonitord`'s own `IOUserClientCreator`
  strings and a `"ThermalThrottlingSupported" = Yes` capability flag — not
  a live reading.
- **`temperature`/`temp`**: no readable numeric value anywhere in the
  dump. The one substantive hit: `pmgr` (`AppleT6041PMGR`,
  `AppleARMIODevice`) publishes 70 `AppleARMPMUTempSensor` and 151
  `AppleARMPMUPowerSensor` child service nodes (`ioreg -rn
  AppleARMPMUTempSensor -d 2`, confirmed by direct count via `grep -c`) —
  device metadata only, no streamed value in the property dump.

**This section's observation is true and stands unchanged from round 1.
Round 1 of this document then drew a false inference from it — that
because `ioreg` exposes no readable thermal/fan value, *no unprivileged
API* exposes one — and used that inference to rule out SMC access
entirely in §1.4. That inference does not follow, and review round 1
caught it: `ioreg` enumerates the IORegistry's *device tree and
properties*; SMC keys (§1.4) are not IORegistry properties at all — they
live behind the `AppleSMC` service's own request/response protocol,
reached via `IOConnectCallStructMethod` after `IOServiceOpen`, a
completely different access path that `ioreg` has no visibility into
either direction. "Absent from `ioreg`" was never evidence about SMC
specifically; round 1 treated it as corroboration for a still-unconfirmed
SMC finding, which was itself wrong (§1.4). The `ioreg` finding above is
kept, accurately scoped: **no fan or temperature value is an IORegistry
property on this machine.** It says nothing about §1.4's separate
protocol, and this document no longer implies that it does.

### 1.4 SMC via IOKit — round 2: temperature and fan RPM ARE readable, unprivileged; round 1's negative result was a bug in the spike script, not a fact about this machine

**This reverses round 1's central finding, on review.** Round 1 reported
every SMC key read failing and built a load-bearing "possibly an
Apple-silicon transport difference" theory on top of that failure. Review
round 1 re-ran the identical technique, unprivileged, on the same
hardware, and got real temperature and fan readings back. This document's
own re-verification (required before rewriting this section, not taken on
the reviewer's word alone) reproduces that success independently and
identifies the exact bug — two bugs, actually, fixed one at a time below —
so the record is precise about what was wrong rather than just replacing
one assertion with another.

**Round 1's bug: a struct-size mismatch, misread as a permission denial.**
Round 1's hand-rolled Swift `SMCParamStruct` measured, via
`MemoryLayout<SMCParamStruct>.size`/`.stride`, at **76 bytes** (re-measured
directly for this rewrite: `size=76 stride=76 alignment=4`,
`SMCKeyInfoData size=9 stride=12` on its own). The real IOKit driver's C
struct — the classic reference used by every public SMC-reading tool since
the Intel era — is **80 bytes** under ordinary C struct-alignment rules:
`SMCKeyInfoData`'s 9 real bytes (`dataSize: UInt32`, `dataType: UInt32`,
`dataAttributes: UInt8`) round up to a 12-byte member stride once embedded
in the outer struct (alignment-4 padding after the trailing `UInt8`), and
a second, smaller gap exists between `vers` and `pLimitData`. Swift's
automatic layout for the hand-rolled nested-struct version did not
reproduce this — sending a 76-byte buffer where the kernel driver expects
80 fails the driver's own argument-size check. **`-536870206` is not an
unidentifiable code, and round 1 was wrong to say review couldn't name
it**: as an unsigned 32-bit value it is `0xe00002c2`, and `IOReturn.h:102`
— the header lives inside the SDK, not at a bare `/System/Library/...`
path (`$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/
IOKit.framework/Versions/A/Headers/IOReturn.h`; confirmed by `find`
against both locations for this correction — the bare path does not
exist on this machine, only the SDK-rooted one does) — reads `#define
kIOReturnBadArgument iokit_common_err(0x2c2) // invalid argument` — one
line below `IOReturn.h:101`'s `kIOReturnNotPrivileged` (`0x2c1`), which is
exactly what round 1 quoted from the same header while guessing at a
neighboring, wrong constant.
**`kIOReturnBadArgument` means "your struct size argument is wrong," not
"you're not allowed."** The Apple-silicon-transport theory round 1 built
on top of this misreading (`AppleSMCKeysEndpoint`/`RTBuddyEndpointService`
somehow rejecting the classic protocol) is **retracted, not softened** —
§1.4's own evidence for it was a permission-code misidentification, and
once the actual struct size is sent, the classic protocol works
unmodified against this exact service, on this exact machine (below).

**Fixing the struct size (alone) was not sufficient — a second, distinct
bug remained.** Building the request as a raw, hand-offset 80-byte buffer
(bypassing Swift struct layout entirely, so there is no ambiguity about
padding) still failed every key identically, this time with
`kern_return_t = 0` (`KERN_SUCCESS` — the IOKit call itself now succeeds)
but `smcResult = 132` (`0x84`, the SMC-internal "key not found" code) for
every single candidate key, including ones independently confirmed to
work. Root cause: the reference technique (`smc.c`, the tool this whole
class of third-party reader is derived from) builds the key field as a
plain `UInt32` assignment with **no explicit byte-swap** — the wire format
is "the arithmetic value produced by packing the four ASCII bytes
MSB-first, stored in the caller's native byte order," not "the four ASCII
bytes in reading order." On this little-endian arm64 host those are
different byte sequences in memory; an intermediate version of this
rewrite's spike wrote literal reading-order ASCII bytes, which does not
match a native-little-endian store of the packed arithmetic value and
produced the uniform "key not found" result. Writing the same packed
`UInt32` value via a native (non-byte-swapped) memory write — matching
what a native Swift or C struct-field assignment actually does on this
architecture — fixed it.

**With both bugs fixed, every candidate key succeeds:**

```
keyInfo(Tp09) -> kr=0 smcResult=0 dataSize=4 dataType=flt
  readBytes(Tp09) -> kr=0 smcResult=0 bytes=[00 00 20 42]   ->  40.0
keyInfo(Te05) -> kr=0 smcResult=0 dataSize=4 dataType=flt
  readBytes(Te05) -> kr=0 smcResult=0 bytes=[00 56 6c 42]   ->  59.08
keyInfo(Tg05) -> kr=0 smcResult=0 dataSize=4 dataType=flt
  readBytes(Tg05) -> kr=0 smcResult=0 bytes=[9a c9 68 42]   ->  58.20
keyInfo(TW0P) -> kr=0 smcResult=0 dataSize=4 dataType=flt
  readBytes(TW0P) -> kr=0 smcResult=0 bytes=[38 27 1d 42]   ->  39.29
keyInfo(FNum) -> kr=0 smcResult=0 dataSize=1 dataType=ui8
  readBytes(FNum) -> kr=0 smcResult=0 bytes=[01]            ->  1 fan
keyInfo(F0Ac) -> kr=0 smcResult=0 dataSize=4 dataType=flt
  readBytes(F0Ac) -> kr=0 smcResult=0 bytes=[00 00 7a 44]   ->  1000.0 RPM
keyInfo(F0Mx) -> kr=0 smcResult=0 dataSize=4 dataType=flt
  readBytes(F0Mx) -> kr=0 smcResult=0 bytes=[00 20 99 45]   ->  4900.0 RPM
RESULT: anySucceeded=true
```

(Float values decoded little-endian, verified independently against
Python's `struct.unpack('<f', ...)` for each byte sequence above — the
big-endian interpretation of the same bytes produces physically
nonsensical values like `1.15e-41`, confirming little-endian is the
correct reading, not an assumption.) **These numbers independently
corroborate the reviewer's own re-run** (`Tp09 = 62.52`, `Te05 = 60.15`,
`Tg05 = 60.68`, `TW0P = 40.06`, `F0Ac`/`F0Mx` = `1000.00`/`4900.00` RPM):
`F0Ac`/`F0Mx`/`FNum` match exactly (fan speed and count don't drift with
CPU load the way core temperatures do), and the temperature keys read
lower here than in the reviewer's run — expected, not a discrepancy, since
this machine was idle at spike time and the reviewer's own numbers came
from a different sample taken under different load.

**Cost, measured directly, not assumed:** a single `readBytes` call for
one already-known key (`dataSize`/`dataType` cached from one prior
`keyInfo` call, the way a real sampler would avoid repeating it every
tick) costs **142.6 ms over 1000 calls, 0.143 ms/call** — roughly 5-25×
`#0305`'s measured libproc-call cost (§1.1), still three orders of
magnitude under a 1-second budget. A full sweep of all 12 candidate keys
(`keyInfo` + `readBytes` each, 24 `IOConnectCallStructMethod` calls) costs
**677.9 ms over 200 sweeps, 3.39 ms/sweep** — comparable in order of
magnitude to §1.7's whole-system process sweep, and still negligible
against 1 second.

**Two open questions this spike does not close, kept open rather than
resolved by assertion, per review's explicit instruction:**

1. **Not yet re-verified inside the notarized, hardened-runtime app
   bundle.** Every read above — round 1's failure and round 2's success —
   ran as an ad-hoc `swift <file>.swift` script, the same throwaway-spike
   class `#0305`'s own precedent uses, not the actual signed `Batty.app`.
   Hardened Runtime can restrict IOKit user-client access differently for
   a notarized app than for an ad-hoc script under some entitlement
   configurations; nothing in this spike rules that difference in or out.
   **Phase 2 must re-run this exact probe inside the built, signed app
   bundle before relying on it.**
2. **SMC key names are model-specific, not universal.** `Tp09`/`Te05`/
   `Tg05`/`TW0P`/`F0Ac`/`F0Mx`/`FNum` are the keys that resolved on *this*
   Mac mini M4. Apple has changed SMC key naming across chip generations
   and product lines historically (the very fact round 1's Intel-era
   `TC0P`/`TC0D` guesses failed cleanly with `kSMCKeyNotFound`, not a
   protocol error, once the struct size was fixed, is itself evidence of
   this — those keys plausibly just don't exist on this SoC). A phase-2
   implementation cannot hardcode one fixed key list and expect it to
   resolve on every Mac Batty runs on; it needs either a per-model key
   table (maintained against Apple's own naming pattern, which is
   only partially documented publicly) or a runtime discovery pass
   (`kSMCGetKeyCount`/`kSMCGetKeyFromIndex`, not spiked here) that finds
   the right keys on whatever machine it's running on. Neither is designed
   further here — named as real, unresolved phase-2 work, not glossed
   over.

### 1.5 `powermetrics` — confirmed to require root, exact failure recorded

```
$ /usr/bin/powermetrics -n 1 -i 1000
powermetrics must be invoked as the superuser
```

Exit code **1**, run as `uid=501` (confirmed via `id`, not assumed) —
matching `issues/0313.md`'s prior note that this tool is unavailable to a
user-level process, now independently reproduced rather than carried
forward as an assumption.

### 1.6 System-wide non-thermal metrics — all freely available, all negligible cost

| Metric | API | Observed value | Cost |
|---|---|---|---|
| Load average (1/5/15 min) | `getloadavg(3)` | `[3.37, 3.54, 4.15]` | 1000 calls in 0.39 ms, **0.0004 ms/call** |
| Physical memory total | `sysctlbyname("hw.memsize")` | 68,719,476,736 bytes = 64.0 GiB | negligible, one-shot |
| Per-core CPU utilization | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, delta over two samples | 12 cores; a 0.5s-delta sample read `[25.0, 12.5, 6.1, 2.0, 12.0, 24.0, 16.0, 12.0, 34.0, 38.8, 16.3, 30.0]`% | 1000 calls in 5.88 ms, **0.0059 ms/call** |
| Memory pressure breakdown (free/active/inactive/wired/compressed/purgeable) | `host_statistics64(HOST_VM_INFO64)` × `host_page_size` | free 4.32 GiB, active 26.87 GiB, inactive 25.97 GiB, wired 3.62 GiB, **compressed 2.50 GiB**, purgeable 0.09 GiB (of 64.0 GiB) | 1000 calls in 0.68 ms, **0.0007 ms/call** |
| Memory pressure level (coarse) | `sysctlbyname("kern.memorystatus_vm_pressure_level")` | `1` (normal; kernel convention: 1=normal, 2=warn, 4=critical) | negligible, one-shot |

All five are **three to four orders of magnitude cheaper** than any
plausible refresh interval, the same conclusion `#0305`'s §1.3 reached for
per-pid libproc calls. `getloadavg` is used over the equivalent
`sysctlbyname("vm.loadavg")` — an attempt at the raw sysctl in this spike
failed with a struct-sizing bug in the throwaway script itself (`errno`
-1, byte-count mismatch), not a permission problem; `getloadavg(3)` is the
documented libc wrapper over the identical kernel data and is what's
specified below, so the sizing bug in the spike script doesn't affect the
design.

**This directly answers one of `#0313`'s deferred items.** `#0313`'s LM
Studio dashboard design (`issues/0313.md`) named GPU/memory utilization as
deferred to "system-level tooling" because `powermetrics`/`ioreg` looked
unavailable for it; §1.5 confirms `powermetrics` specifically is a dead
end (root-only), but **memory utilization is not** — `host_statistics64`
gives system-wide memory (not per-GPU-process) freely, and that is exactly
what this view's memory tile (§2) uses. GPU-specific utilization
(per-process or aggregate GPU busy %) was not separately spiked here and
remains unresolved — nothing in `#0313`'s existing deferral is overturned
for that specific number, only for system memory generally.

### 1.7 Whole-system process list — the number that decides full-list viability

This is the multiplied cost `issues/0314.md` calls out specifically:
`#0305` measured one pid's libproc cost; a system-wide list multiplies
that across every process. Measured directly, not assumed:

```
proc_listallpids: 805 pids in 0.25 ms
Full sweep (PROC_PIDTASKINFO + proc_pid_rusage(V4) + proc_name) over 805 pids:
  2.91 ms total, 0.0036 ms/pid average
5 repeat full sweeps: [2.16, 2.08, 2.10, 2.06, 2.06] ms — avg 2.09 ms, min 2.05, max 2.16
```

**A full-system sweep — enumerate every pid, then read task info +
rusage + name for each — costs ~2-3 ms end to end**, not the "roughly
O(system size)" caveat `#0305`'s §1.3/§1.7 attached to child-process
*discovery* specifically (that cost class is about walking every pid just
to filter by parent; this is that same walk, but every row is wanted, not
filtered away). 805 pids is close to but not identical to `#0305`'s own
measured "~820 processes" (§1.3 of that document) — a small, expected
session-to-session variance on the same machine (processes churn), not a
different order of magnitude; both numbers support the same conclusion.

**Cross-checked against two independent tools, the same pattern `#0305`
used**: the top `phys_footprint` entry found by this sweep, `pid 44799`
(`node`, 37,776.7 MB), matches `/usr/bin/footprint 44799`'s own report of
"37 GB" exactly, and `ps -o rss -p 44799` reported 9,657,984 KB = 9,431.6
MB, matching the libproc `resident_size` read of 9,431.6 MB exactly — the
same footprint/resident **4.0× gap** #0290's RSS-undercount trap predicts,
reproduced live, per-row, at whole-system scale for the first time in this
codebase (§1.6/§2 below).

**A whole-system list also needs delta-based CPU%, which needs a value
this document hadn't yet confirmed exists on `proc_taskinfo`**: `struct
proc_taskinfo` (via `Mirror` reflection against a live populated instance,
and a direct field read against this spike's own process) has
`pti_total_user`/`pti_total_system` — cumulative mach-absolute-time units
since process start, exactly the fields §1.6's per-core delta computation
needs applied per-process. Confirmed present and readable (`pti_total_user
= 2,683,748`, `pti_total_system = 858,652` for the spike script's own
process) — this is the field CPU% in §2's process list is computed from,
by the same "delta over the refresh interval, not cumulative" rule
`#0305`'s §3.2 already established for its own single-process CPU%.

**The permission-tier finding from `#0305`'s §1.6, reproduced at full
scale — corrected here after review round 1 found the first pass
over-generalized from too small a sample.** An earlier version of this
section claimed every `proc_name` failure on this machine was
`/usr/bin/login`, generalizing from the first few printed examples. A
fuller re-run, printing the *entire* failure distribution rather than a
5-example prefix, shows that was wrong:

```
total pids=802 (proc_listallpids, including pid 0)
proc_name failures: 280
proc_pidpath failures: 1 — pid 0 only
name-fail basename distribution: 213 distinct basenames
  login: 26, distnoted: 21, cfprefsd: 15, softwareupdated: 2, ... 209 more
  basenames appearing exactly once, e.g.: screensharingd, applekeystored,
  MTLCompilerService, ReportCrash, PerfPowerServices, rapportd, launchd
```

`/usr/bin/login` is the single largest *basename* bucket (26 of 280 — a
process can `fork`/`exec` `login` more than once), but it is **26 of 280,
not 280 of 280** — the remaining 254 failures span 212 other distinct
system daemons and helpers (`screensharingd`, `applekeystored`,
`MTLCompilerService`, `ReportCrash`, `PerfPowerServices`, `rapportd`,
`launchd`, and 206 more), every one of them a root-owned system
process by path (`/usr/libexec/…`, `/System/Library/…`,
`/usr/sbin/…`), not a Batty-specific pty artifact. **The actual boundary
is ownership (uid), the same conclusion `#0305`'s §1.5/§1.6 already drew
from its own `/usr/bin/login`-and-`launchd` examples** — this document's
error was treating one visible instance of that boundary (a pty session
leader) as if it were the *entire* boundary, when it is one example among
hundreds of a much larger and more ordinary category: "processes this uid
doesn't own." Corrected now, everywhere this document or its mockup
repeats the claim.

**`proc_pidpath` is not failure-free either — one exception, found by
checking specifically rather than trusting `fail=0` from a filtered
scan.** An earlier version of this section additionally over-filtered its
own pid list (`.filter { $0 > 0 }`, silently dropping pid 0 before ever
testing it) and then reported "zero blank-name rows" as if that had been
verified for every pid `proc_listallpids` returns. Re-run without that
filter: `proc_listallpids` does return pid 0 (`kernel_task`) on this
machine, and **`proc_pidpath(0, ...)` fails**, alongside `proc_name` and
`PROC_PIDTBSDINFO` — the one pid where the path-basename fallback (§1.6's
"looser permission tier" finding, otherwise still correct: `proc_pidpath`
resolved for all 801 other pids) has nothing to fall back to either.
**§2's never-blank guarantee needs a third, final fallback specifically
for this one well-known case**: pid 0 is always the kernel on Darwin, a
fixed constant, not something that needs discovery — a hardcoded label
("kernel_task") when `pid == 0` and both `proc_name`/`proc_pidpath` fail
closes the gap without inventing a general "when everything fails, do X"
rule for a case that has exactly one instance, always at the same pid,
on every macOS system.

### 1.8 What this rules in and out for §2

**Ruled in, at negligible-to-cheap cost, every refresh tick:** `ProcessInfo
.thermalState`'s four-state coarse reading (§1.2); load average, per-core
CPU%, system memory breakdown, memory pressure level (§1.6); a full,
un-truncated process list with name (falling back to path-basename, then
to a hardcoded `"kernel_task"` label for the one pid — 0 — where even that
fails, §1.7), pid, CPU% (delta-computed, same-uid only), memory
(`phys_footprint`, compressed-aware, same-uid only) (§1.7); **CPU
temperature and fan RPM/count via the classic SMC struct-method protocol**
(§1.4 — reversed from round 1's finding; costs more than the other reads,
0.14 ms/key read, 3.4 ms for a 12-key sweep, but still far under budget).

**Ruled out, with the SMC reversal narrowing this list to what's actually
unavailable:** per-process GPU utilization (not spiked; `#0313`'s existing
deferral stands, unresolved by this document); `powermetrics`-sourced
anything (§1.5 — confirmed root-only, not assumed). Numeric temperature
and fan speed are **no longer on this list** — §1.4 found both readable.

**Genuinely uncertain, flagged rather than either assumed or ruled out:**
whether `thermalStateDidChangeNotification` actually fires on a real
transition (§1.2 — registration works, delivery unobserved in this
spike's 5-second idle window); whether §1.4's SMC reads succeed
identically inside the notarized hardened-runtime app bundle, not just an
ad-hoc script (§1.4 — phase 2 must re-check before relying on it); whether
the specific SMC key names found here (`Tp09`, `Te05`, `Tg05`, `TW0P`,
`F0Ac`, `F0Mx`, `FNum`) resolve on any Mac other than this one (§1.4 —
model-specific by Apple's own historical pattern, not verified elsewhere).

---

## 2. Which metrics, at what fidelity

Bounded strictly by §1. Deciding, not surveying, per each of `#0314`'s
three named questions:

### Thermal state: the coarse chip, *plus* numeric temperature and fan RPM — reversed from this document's own round 1

**Decision, corrected after review round 1: show the coarse
`ProcessInfo.thermalState` chip (Nominal/Fair/Serious/Critical) *and* a
numeric CPU temperature tile *and* a fan tile (RPM + count), all three,
sourced the way §1.2/§1.4 respectively proved obtainable.** An earlier
version of this document decided the numeric routes were ruled out and
built the entire thermal section — and the mockup's "Temperature
Unavailable" state — on that premise. §1.4's re-verification found the
premise false: this document's own round-1 negative SMC result was a
struct-layout bug in the spike script, not a fact about what's readable on
this machine, and round 2 read real temperature and fan values
successfully. **Shipping the "ruled out, not shown" design after that
correction would itself be the exact defect this issue's own review
process exists to catch — a design decided on a disproven premise** — so
this section is rewritten, not patched.

The numeric CPU temperature tile reads from whichever performance-core SMC
temperature key(s) resolve on the running machine (`Tp09`/`Tp0T`/`Tp01`/
`Tp05`-class keys on this Mac mini M4, §1.4) — **not a single hardcoded
key**, because §1.4's second open question is explicit that SMC key names
are model-specific and this design does not assume the exact key set found
on one Apple silicon Mac mini generalizes to every Mac Batty runs on. Phase
2 needs a small per-model key table or a runtime discovery pass (§1.4);
this document specifies the tile's *content* (a representative CPU
temperature, in °C) and its *fallback* (§7 below), not the exact key
resolution algorithm — that's implementation work the design doesn't need
to finish to be approvable, the same way `#0304`'s design named FSEvents
as the watching mechanism without writing the debounce implementation.
The Fan tile shows RPM (`F0Ac` — current speed — on this machine) and fan
count (`FNum`) the same way. The thermal-state chip is kept alongside the
numeric tiles, not replaced by them — it is still the cheapest,
best-understood signal (§1.2, ~0.0001 ms/read, a public documented API)
and it is what correlates with actual OS-level throttling behavior, which
a raw temperature number by itself doesn't tell the user directly.

**The two caveats §1.4 named are carried into the UI, not resolved by
assertion**: phase 2 must re-verify these reads succeed inside the signed,
notarized, hardened-runtime app bundle (not just an ad-hoc script) before
shipping, and the exact SMC keys this document names are confirmed only on
this one Mac. Mockup state 4 (§ below) is dedicated to stating both
caveats visibly, in the UI itself, rather than only in this prose — the
same "shown honestly" standard this document's own earlier (wrong)
"unavailable" framing claimed to meet and didn't.

The thermal-state chip reads live off `thermalStateDidChangeNotification`
where available and re-checks the current value on every §3 refresh tick
regardless, so even in the unverified case that the notification never
fires (§1.2), the polled read on the next tick is a bounded-staleness
fallback, not a silent gap.

### CPU: per-core bars plus one aggregate number, delta-computed

**Decision: a small per-core utilization bar (12 bars on this machine,
`host_processor_info`-driven, §1.6) plus one aggregate percentage above
them, refreshed every tick.** Per-core is what `top`'s own `-a`/interactive
mode and Activity Monitor's CPU history both lean on to answer "is one
core pegged or is load spread out" — a question an aggregate-only number
can't answer and the issue's own framing ("metrics `top` typically shows")
points at directly. The aggregate is a simple average of the per-core
percentages, not a second API call.

### Memory: system-wide breakdown, never RSS, matching #0290's convention at a new scale

**Decision: active + wired + compressed as the headline "Used" figure
(matching this spike's own `host_statistics64` computation, §1.6), free
and compressed shown as secondary figures, physical total as the
denominator, plus the coarse pressure-level chip
(`kern.memorystatus_vm_pressure_level`).** This is the system-wide
counterpart to `#0290`'s `phys_footprint` rule and `#0305`'s per-process
application of it: **compressed pages count as used memory, never quietly
dropped**, the same binding rule `issues/0290.md`'s Gotchas state — "any
future memory work must read `phys_footprint`" (or, at the system level,
must fold `compressor_page_count` into "used," which `active_count +
wire_count` alone would not).

### Process list: full, not top-N — the spike's own numbers argue against truncating

**Decision: the full, un-truncated process list (805-ish rows on this
machine), sortable by column (name / pid / CPU% / memory), rendered in a
virtualized SwiftUI `List` (or `Table`), not a fixed top-N.** `#0314`'s own
design-phase question 1 asks "top-N process list vs full list" as open;
§1.7 answers it with a number, not a preference: **the entire sampling
sweep costs 2-3 ms for ~805 processes**, roughly three orders of magnitude
under any plausible refresh interval (§3). SwiftUI's `List`/`Table`
already virtualizes row rendering — only visible rows are materialized —
so there is no rendering-cost argument for truncating either, the same way
a native `Table` with 800 rows is unremarkable in Finder or Activity
Monitor itself. **Every row's memory figure is `phys_footprint`
(compressed-aware), never `resident_size`/RSS as the primary number** —
`issues/0290.md`'s binding rule, restated because §1.7 found the exact
class of error it warns about (a 4.0× footprint/resident gap) reproduced
live in this spike's own data. **CPU%** is delta-computed from
`pti_total_user`/`pti_total_system` between consecutive ticks (§1.7),
never a cumulative since-launch figure — matching `#0305`'s §3.2 rule for
its own single-process reading, applied per row here. **A defensive cap is
still worth stating, not because the measured numbers demand one but
because nothing in this spike ran on a machine with a much larger process
count** (a heavily loaded CI box, hundreds of containers): if a future
implementation observes the sweep or the render regressing on such a
machine, capping at a fixed large number (e.g. 2,000 rows, an order of
magnitude past what was measured here) with a "showing top N of M" note is
the fallback — not designed further here because nothing measured
justifies designing it now.

**Per-row availability, following §1.7's tier finding exactly, including
its round-2 correction:** name resolves via `proc_name` where it
succeeds, falls back to the executable path's basename via `proc_pidpath`
where `proc_name` fails (§1.7 — 280 of ~802 processes on this machine at
spike time, spanning 213 distinct system daemons, `/usr/bin/login` being
the largest single bucket at 26 but not remotely the only one), and falls
back a second time to a hardcoded `"kernel_task"` label for pid 0
specifically, the one pid where `proc_pidpath` itself also fails (§1.7) —
three tiers, not two, so the row is genuinely never blank rather than
"never blank except for one case this document didn't check for." CPU%
and memory show a dash/"—" for rows outside the current uid (the same
`EPERM` boundary `#0305`'s §1.5 named, and the general ownership boundary
§1.7's corrected distribution confirms — not a narrow pty-specific
pattern) rather than a zero, which would misrepresent "denied" as
"measured at zero." No per-row disclosure, diff peek, or context menu
beyond what
`#0305`'s own per-process view already offers in more depth — **this
view's job is the overview, not the inspector**; clicking a row is this
view's one interactive affordance (see §5's shared-infrastructure note on
why that composes cleanly with `#0305` rather than duplicating it).

---

## 3. Sampling interval

**Decision: fixed 1-second interval for every metric in this view — the
same default `#0305`'s §4 picked, for the same reason, with the
system-wide multiplication explicitly checked against the actual number
rather than assumed to still be fine.**

`#0314`'s question 2 asks fixed, configurable, or adaptive, "e.g. slower
when nothing changes." **Adaptive is rejected outright**: nothing in §1's
measurements justifies the complexity. §1.6's system-wide metrics cost
roughly 0.01 ms combined; §1.7's full process sweep costs 2-3 ms; §1.4's
SMC sweep (temperature + fan, added after review round 1's correction)
costs a further ~3.4 ms. Even summing every category at its *slowest*
measured number, the combined per-tick cost (~6.5 ms) is under 0.7% of a
1-second budget — there is no "nothing changed, back off" case to build
for, because the always-on cost was never close to the budget in the
first place, even after adding the SMC category this document's round-1
mistakenly believed didn't exist. This is the same reasoning `#0305`'s §4
used ("refresh cadence is therefore a UX choice, not a cost constraint")
applied to a workload two to three orders of magnitude larger, and it
still holds: **the multiplication `#0314`'s own Description worried about
turned out not to change the answer.**

**Configurable is also rejected, deliberately, not by default-and-move-on.**
Activity Monitor itself offers a refresh-rate menu (Very Often / Often /
Normal), which could be read as precedent for exposing one here. This
document doesn't build it: nothing in the umbrella's user quotes asks for
tunable cadence, `#0304`/`#0305` didn't add one for their own refresh
loops, and adding a preference is new UI surface (a picker, a persisted
default, a settings row) for a knob the measured cost data gives no reason
to need — the same "nothing asks for it, keep phase 1 small" reasoning
`docs/design/git-status-view.md` §2 used to defer diff-highlighting.
**1 second, fixed, matching Activity Monitor's own default and `#0305`'s
existing precedent**, because a `system-metrics` pane is, by construction,
something the user has open and is looking at — contrasted, the same way
`#0305`'s §4 contrasts, with `#0290`'s own 60-second `FootprintMonitor`
sampling interval, which is a background health check nobody is watching
live (`BattyKit/Sources/BattyKit/Runtime/FootprintMonitor.swift:86`,
`public static let sampleInterval: Duration = .seconds(60)`).

**One tick does four things, all at the measured cost, in whatever order
is convenient**: re-read `thermalState` (§1.2), re-sample the five
system-wide numbers (§1.6), re-sweep the process list (§1.7), and re-read
the SMC temperature/fan keys (§1.4 — the most expensive single category
at ~3.4 ms, still negligible against the 1-second interval). Row
*reordering* in the process table is not throttled separately from
value refresh — nothing measured argues for the added complexity of a
"values update every tick, sort order updates less often" split, and
Activity Monitor's own default behavior re-sorts every tick too, so this
design doesn't invent a smoother behavior than the app it's modeled on
already has.

---

## 4. Hidden-pane history: discard, not keep

**Decision: discard. A hidden or suspended `system-metrics` pane retains
nothing — no ring buffer, no last-known snapshot beyond what naturally
survives in `@Observable` properties until the next write. `setVisible(true)`
performs one immediate fresh full sample (all three of §3's categories),
exactly matching `docs/pane-view-lifecycle.md` §4's "showing resumes and
refreshes" rule.**

`#0314`'s question 3 frames this as an open trade: continuity on re-show
versus zero growth while hidden. §1.7's own numbers make this an easy call
rather than a real trade-off: **because a fresh full sample costs ~2-3 ms,
the "continuity" a kept history would buy is imperceptible** — the gap
between "instantly redraw the last-known state" and "redraw after a ~3 ms
resample" is not a gap a user can see. There is no equivalent here to
`#0305`'s tombstone state (§2 of that document), where keeping the
*last-known values visible after the underlying process is gone forever*
is genuinely load-bearing — a `system-metrics` pane's subject (the whole
machine) never "exits," so there is no state analogous to "the pid is gone,
show what it was" to preserve. Discarding is also the simpler
implementation of `docs/pane-view-lifecycle.md` §4's "suspended costs
zero periodic work" requirement: nothing to cap, prune, or reason about
growing while hidden, which matters given `#0303`'s own framing names
`#0285`'s 8.4 GB retrofit as the cautionary context this design should not
need a retrofit of its own.

**Concrete consequence for CPU%'s delta computation** (§2): the
previous-tick `pti_total_user`/`pti_total_system` map this view keeps for
delta computation is exactly the kind of state that gets discarded on
hide. The first tick after `setVisible(true)` therefore has no prior
sample to delta against for any pid — every row's CPU% reads as
unavailable ("—", not `0%`, the same "denied is not zero" convention §2
already uses for permission-denied rows) for that one tick, then resolves
normally from the second tick onward. This is a one-tick, ~1-second
cosmetic gap on every show, not a defect to design around — stated
explicitly here so a future implementer doesn't "fix" it by keeping the
delta map alive across suspend, which would be exactly the kind of
paused-but-still-allocated state §1 of `docs/pane-view-lifecycle.md`
argues against.

**What "suspended" costs, concretely, per `docs/pane-view-lifecycle.md`
§4:** literally zero — no running `Task`, no timer, no retained sample
buffer, no delta map. Identical in shape to `#0305`'s own answer
(`docs/design/process-status-view.md` §4, "no `FileDescriptor`, subprocess,
or kernel-level handle survives between one sampling call and the next"),
because this view spawns nothing external either (§1 found no subprocess
route was needed anywhere — the same conclusion #0305 reached for its own
narrower scope).

---

## 5. Shared infrastructure with `#0305`

`issues/0314.md`'s own Relation section commits to this: "whichever ships
first should factor its sampler for reuse by the other." §1's spike makes
the shared surface concrete rather than aspirational:

**What's genuinely shared** — a per-pid sampling primitive, because both
views read the identical libproc calls against the identical struct
layouts:

- `proc_pidinfo(pid, PROC_PIDTASKINFO, ...)` → `pti_threadnum`,
  `pti_resident_size`, and (new to this document, §1.7) `pti_total_user`/
  `pti_total_system` for CPU% delta computation — `#0305`'s design didn't
  need the CPU delta fields because its own metrics row (`docs/design/
  process-status-view.md` §3.2) is presumably driven by the identical
  struct once implemented, just not spelled out at the field level there.
- `proc_pid_rusage(pid, RUSAGE_INFO_V4, ...)` → `ri_phys_footprint`, the
  one number both views are contractually required to lead memory with
  (`issues/0290.md`'s binding rule, cited independently by both design
  documents).
- `proc_name`/`proc_pidpath` with the same fallback rule both documents
  now state identically: prefer `proc_name`, fall back to
  `proc_pidpath`'s basename when it fails — §1.7 of this document
  reproduces `#0305`'s §1.6 finding at whole-system scale, so the fallback
  isn't a per-view judgment call, it's the same observed permission tier
  in both places.
- `sysctl(KERN_PROCARGS2)` for full command-line/argv (`#0305`'s bonus
  "Command Line" row) — not used by this view's own process-list rows
  (a command-line column would make an already-wide table wider for
  marginal value at overview scale), but the same primitive, worth sharing
  from the same file regardless of which view's phase 2 calls it first.
- `proc_listallpids` — `#0305` uses this today only for its own
  child-process disclosure (`docs/design/process-status-view.md` §2,
  "Child Processes… immediate children only," filtered by `pbi_ppid`) and
  its "Pick a Running Process…" picker; this view uses the *same* full
  enumeration as its primary data source, not a filtered subset. One
  shared enumeration primitive, two different consumers of its output.

**The shared type this design names, not builds**: a
`ProcessMetricsReader` or `ProcessSampler` (naming left to phase 2 — this
document isn't the one that ships either view's Swift source, so it
doesn't force a name onto a symbol neither issue has written yet),
analogous in spirit to `FootprintReader`
(`BattyKit/Sources/BattyKit/Runtime/FootprintReader.swift`) but for
*another* process's stats rather than the caller's own — a single
`struct ProcessSample { pid, name, path, threadCount, physFootprint,
residentSize, cpuTicksUser, cpuTicksSystem }` plus two entry points,
`sample(pid:) -> ProcessSample?` (what `#0305`'s pinned/following mode
calls once per tick against one pid) and `sampleAll() -> [ProcessSample]`
(what this view's process list calls once per tick against every pid,
§1.7). CPU% itself stays a caller-side delta computation in both views
(each needs its own previous-tick state — `#0305`'s is one prior sample,
this view's is a per-pid map, per §4's discard rule) rather than living
inside the shared reader, the same way `#0290`'s `FootprintReader` itself
stays a stateless one-shot read and `FootprintMonitor` (a separate type)
owns the timing/state around it.

**What's `#0314`-only, not shared**: `ProcessInfo.thermalState` (§1.2),
`host_processor_info`/`host_statistics64`/`getloadavg` (§1.6), and — after
§1.4's round-2 correction — the SMC temperature/fan read path, which now
**does** work but is still `#0314`-only rather than shared: it is
whole-machine state (one CPU temperature, one set of fans), not
per-process, so nothing in `#0305`'s per-process scope has a reason to
call it, the same reasoning that already applied to the other three
whole-machine sources in this list. (An earlier version of this paragraph
said the SMC investigation "produced no working read path" and used that
as the reason it wasn't shared — that premise was wrong, per §1.4, but the
conclusion — not shared with `#0305` — still holds, for the correct
reason: scope, not failure.)

---

## 6. Lifecycle wiring — the `PaneContentLifecycle` contract, concretely

`SystemMetricsPaneContent` conforms to `PaneContentLifecycle`
(`BattyKit/Sources/BattyKit/Runtime/PaneContentLifecycle.swift:110-138`,
confirmed current) via a `PaneLifecycleController`
(`PaneContentLifecycle.swift:146-161`), the same shape `#0304`/`#0305`
commit to:

| Contract method | What it does here |
|---|---|
| `setUp(visible: Bool)` (`PaneContentLifecycle.swift:123`) | Takes one `thermalState` read and one system-wide-metrics read immediately (§1.2/§1.6 — both sub-millisecond, so the header/tiles have something to show the instant the pane exists, per `docs/pane-view-lifecycle.md` §4's "setup must not create work it would immediately have to suspend" — a single non-repeating read is not periodic work, the same reasoning `#0305`'s own `setUp` table applies to its one-time identity lookup). If `visible == true`: additionally runs the first full process-list sweep (§1.7) and the first SMC read (§1.4 — its own self-contained open/read/close cycle, below) and starts the 1s periodic `Task` (§3). If `visible == false`: stops there — no `Task`, no process sweep, no SMC connection opened at all, matching the direct `notSetUp → suspended` edge `docs/pane-view-lifecycle.md` §3's state diagram requires. |
| `setVisible(true)` (`suspended → active`, `PaneContentLifecycle.swift:130`) | (Re)starts the 1s periodic `Task` and performs one immediate full sample across all four categories (§3), per §4's "discard, then refresh on show" decision — the CPU-delta map starts empty, so the first tick's CPU% column reads "—" for every row as §4 describes. |
| `setVisible(false)` (`active → suspended`) | `Task.cancel()`, drop the reference, drop the CPU-delta map (§4 — nothing kept). No subprocess exists anywhere in this design (§1 found none needed, mirroring `#0305`'s own finding), and — per the correction below — no persistent SMC connection either, so there is nothing else to release; no bounded wait needed, unlike `#0304`'s `git status` subprocess teardown. |
| `tearDown()` (`PaneContentLifecycle.swift:137`) | Same cancellation as `setVisible(false)`, idempotent per the state machine's `.noOp` handling of a repeated tear down (`docs/pane-view-lifecycle.md` §3). Nothing else to release — no watcher, no cache beyond the discarded delta map, no subprocess, no held connection. |

**SMC access is per-tick open/read/close, not a persistent connection —
corrected after review round 2 found the persistent-connection design was
built on an unmeasured, and wrong, cost claim.** An earlier version of
this section held the `AppleSMC` connection open across ticks (opened in
`setUp`/`setVisible(true)`, explicitly `IOServiceClose`d in
`setVisible(false)`/`tearDown()`, with a double-close guard and a
close-race guard in the tick loop) on the stated basis that "the
connection, not the individual key reads, is the expensive-to-repeat
part." **That claim was never measured when it was written, and it is
backwards.** Measured directly for this correction (200 iterations each):
a full `IOServiceGetMatchingService` + `IOServiceOpen` + `IOServiceClose`
cycle costs **0.050 ms**; `IOServiceOpen`/`IOServiceClose` alone (service
already matched) cost **0.043 ms**. A single `readBytes` key read costs
**0.10-0.14 ms** across repeated measurements in this document (§1.4,
this correction). **The connection is cheaper than one key read, not more
expensive than every key read combined** — opening and closing it fresh
every tick costs about 0.05 ms against a 3.4 ms twelve-key sweep, roughly
1.5% of it, and about 0.005% of the 1-second interval.

With the actual cost data in hand, the simpler design is also the
cheaper one: **`SystemMetricsPaneContent`'s SMC read is a self-contained
`IOServiceGetMatchingService` → `IOServiceOpen` → (`keyInfo` + `readBytes`
per key) → `IOServiceClose` sequence, run once per tick and holding
nothing between ticks** — no connection field on the conformer, no
`setVisible(false)`/`tearDown()` release step for it, no double-close
guard, no close-race guard in the tick loop. This restores, for the whole
design and not just the non-SMC parts of it, the property an earlier
version of this section stated and then carved an exception into: **every
call this view's sampling loop makes — `proc_listallpids`,
`proc_pidinfo`, `proc_pid_rusage`, `host_statistics64`,
`host_processor_info`, `getloadavg`, `ProcessInfo.thermalState`, and now
the SMC open/read/close sequence — opens nothing and holds nothing open
between calls.** `Task.cancel()`'s usual imprecision (it returns
synchronously, but the sampling loop's body only observes the
cancellation flag the next time it resumes from `Task.sleep`, a later
turn of the run loop, not something `tearDown()` can observe having
already happened) is therefore not a leak risk here the way it would be
for a held connection: a cancellation that lands mid-loop, before the next
sweep's `IOServiceOpen`, simply means that sweep never runs; a
cancellation that lands after a sweep's own `IOServiceClose` has already
returned finds nothing open to leak either way. The sampling loop must
still check `Task.isCancelled` before performing each tick's sweep, the
same "don't run one extra pass after teardown was asked to stop it"
reason `#0305`'s §4 names — this is a correctness/tidiness guard against
doing avoidable work after cancellation, not a resource-leak guard,
because there is no cross-tick handle left to race against.

**One narrowing on the concurrency reasoning, not a defect**: an earlier
version of this paragraph warned about "a racing `setVisible(false)`"
interrupting a held connection mid-tick, phrased broadly enough to imply
a data race. Batty's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
(`CLAUDE.md`) means both the sampling loop's body and `setVisible(false)`
run on the main actor, so the loop can only be interrupted at an actual
suspension point (`Task.sleep`, `await`), not preemptively mid-statement —
the `Task.isCancelled` check before each sweep is correct and sufficient
on its own; there was never a narrower race than that to guard against,
and the per-tick open/close design removes even the resource this
paragraph was originally worried about racing.

**What "suspended" costs**: zero periodic work and zero open kernel
handles — no `Task`, no delta map, no cached sample, and (now, simply
because none is ever held for longer than one tick) no open `AppleSMC`
connection. A hidden `system-metrics` pane costs nothing beyond its own
model object's few bytes, the same conclusion both prior non-terminal-view
design documents reach for the same structural reason
(`docs/pane-view-lifecycle.md` §1: a non-terminal kind has no
GPU-swap-chain equivalent forcing a "stop rendering but keep the resource"
compromise) — and, per the correction above, this document's own SMC
connection turned out not to need the exception to that reasoning an
earlier version carved out for it.

**Where the calls come from**: unresolved by this document, the same way
`#0304`/`#0305` both leave it — `docs/pane-view-lifecycle.md` §5's open
item on `showPane`'s asymmetry (`WindowRuntime.hidePane` at
`BattyKit/Sources/BattyKit/Runtime/WindowRuntime.swift:405-433` drives the
terminal path directly; `showPane` at `WindowRuntime.swift:438-445` relies
on remount instead) is phase 2's wiring question, shared across every
non-terminal kind, not re-litigated per view. `SystemMetricsPaneContent
.setVisible` must be safe to call redundantly or via a remount-driven
path, because `docs/pane-view-lifecycle.md` §3 requires `.noOp` idempotence
at the state-machine level regardless of caller — the same commitment
`#0304`/`#0305` each make.

---

## 7. What it shows (layout, see the HTML mockup for the concrete visual)

1. **Header row** — "System Metrics" kind chip, a right-aligned manual
   refresh button (matching `#0304`'s convenience affordance for forcing a
   re-scan without waiting for the tick), **plus the same pane-level drag
   handle and hide (eye) button every terminal Pane, the Git Status pane,
   and the Process Status pane already have** — the identical relocation
   `docs/design/git-status-view.md` §2 and `docs/design/
   process-status-view.md` §3 already justify, restated here because this
   is the third view to need it, not a new justification
   (`BattyKit/Sources/BattyKit/Views/PaneView.swift:80-119`, the
   `if hasSiblingPanes { paneDragHandle }` / `paneEyeButton` block at
   `PaneView.swift:113-118`, confirmed current — those two mouse
   affordances live inside the tab-bar `HStack` that only exists in
   `PaneView`'s `.terminal` arm per `docs/pane-kinds.md` §2). No "Choose
   Process…"/"Change Directory…" equivalent — §0's singleton/no-subject
   finding means there is nothing to retarget; the pane's subject is
   always "this machine."
2. **Thermal chip** — a single colored state pill (Nominal/Fair/Serious/
   Critical, §1.2/§2).
3. **CPU Temperature and Fan tiles** — numeric °C (from whichever SMC
   temperature key(s) resolve on the running Mac, §1.4/§2) and RPM + fan
   count (`F0Ac`/`FNum`-class keys, §1.4). Shown alongside the thermal
   chip, not instead of it — corrected from an earlier version of this
   design that ruled both tiles out on a since-retracted premise (§1.4,
   §2's "Thermal state" section). Carries the two open caveats from §1.4
   visibly (see mockup state 4): not yet re-verified inside the signed app
   bundle, and the specific SMC keys are confirmed on this one Mac only.
4. **CPU row** — aggregate percentage plus per-core bars (§2), refreshed
   every tick.
5. **Memory row** — Used (active+wired+compressed, headline), Free,
   Compressed (secondary figures), physical total as the scale reference,
   plus the pressure-level chip (§2). "Compressed" is shown, not hidden,
   specifically because it's the figure `issues/0290.md`'s trap is about —
   surfacing it is part of the point of this view, not an implementation
   detail to bury.
6. **Load average row** — 1/5/15-minute figures (§1.6), plain text, no
   graph (a load-average sparkline is exactly the kind of "historical/
   graphed... over time" feature `docs/design/process-status-view.md` §2
   already deferred for its own CPU%; the same reasoning applies here —
   nothing in the issue's framing asks for a chart, and §4 already decided
   against keeping the history a chart would need).
7. **Process list** — full, sortable, virtualized table (§2): Name, PID,
   CPU%, Memory (`phys_footprint`), each row clickable. Clicking a row
   does **not** open an inline inspector in this view (`#0314`'s own scope
   is the overview) — it opens a `system-metrics`-pane-owned action,
   "Watch in Process Status," that creates (or focuses, if one already
   exists targeting that pid) a `process-status` pane pinned to that pid,
   the cross-view composition §5's shared sampler exists to make cheap.
   This mirrors the "Watch this instead" affordance
   `docs/design/process-status-view.md` §3.4 already gives its own Child
   Processes disclosure, extended to every row here since every row in
   this view already *is* a process. Rows the current uid doesn't own show
   "—" for CPU%/Memory (§2), never a fabricated zero; pid 0 shows the
   hardcoded `"kernel_task"` label (§1.7/§2 — the one pid where even the
   path-basename fallback fails).
8. **Non-mutating context menu** on a process row: "Copy PID," "Reveal
   Executable in Finder" — matching `#0305`'s own read-only decision and
   its own explicit reasoning (killing a process is a materially different
   risk class than reading its state); no "Kill," no "Renice," not
   designed or stubbed here.

### What's deliberately not shown in phase 1

Per-process GPU utilization (not spiked, `#0313`'s deferral stands); a
CPU/memory/temperature history graph (§4/§7.6 — no kept history to graph);
any process-list inline inspector beyond the pivot-to-`process-status`
action (§7.7 — `#0305`'s job, not duplicated here); any mutating action on
a process row (§7.8). **No longer on this list**: numeric temperature and
fan speed, which an earlier version of this document ruled out here and
which §1.4's correction now shows in the metrics grid instead (item 3
above).

---

## Summary table (quick reference for phase 2)

| Question | Answer | Section |
|---|---|---|
| Feasibility — thermals | **Corrected after review round 1.** `ProcessInfo.thermalState` works, costs ~0.0001 ms/read, coarse four states; notification registers but firing wasn't observed in this spike's window. `ioreg` shows zero fan keys and no readable temperature value *as an IORegistry property* — but that says nothing about the separate SMC protocol. The classic SMC struct-method technique **is readable, unprivileged**: round 1's negative result was a spike-script struct-size bug (76 bytes sent, 80 expected — `kern_return_t 0xe00002c2` is `kIOReturnBadArgument`, `IOReturn.h:102`, not a permission code) compounded by a second key-byte-order bug; fixed and re-verified independently, reading real temperatures (e.g. `Tp09 = 40.0°C` idle) and fan data (`F0Ac = 1000.0 RPM`, `FNum = 1`) matching the reviewer's own numbers. Cost: 0.14 ms/key read, 3.4 ms for a 12-key sweep. Two open caveats carried forward, not resolved: not yet re-verified inside the signed/notarized app bundle; SMC key names are model-specific. `powermetrics` confirmed root-only (exit 1, "must be invoked as the superuser"). | §1.2-§1.5 |
| Feasibility — non-thermal system + whole-process-list cost | Load average, per-core CPU, memory breakdown (compressed-aware), physical total: all free, sub-millisecond. Full-system libproc sweep (~802-805 pids on this machine, two separate spike runs — process count fluctuates run to run, not a discrepancy): 2-3 ms total, cross-checked against `footprint`/`ps`. **Corrected after review round 1:** `proc_pidpath` fails for exactly one pid (0, `kernel_task`) rather than zero; `proc_name` fails for 280 pids spanning 213 distinct root-owned system daemons (`/usr/bin/login` is the largest single bucket at 26, not the only one at 280) — the boundary is process ownership generally, not a narrow pty-specific pattern. | §1.6/§1.7 |
| 1. Which metrics, at what fidelity? | **Corrected after review round 1:** numeric CPU temperature and fan RPM/count tiles, sourced from SMC keys (§1.4), shown alongside — not instead of — the coarse 4-state thermal chip, with both open caveats stated in the UI (mockup state 4). Per-core + aggregate CPU. Compressed-aware system memory breakdown + pressure chip. Full (not top-N) sortable process list, `phys_footprint` per row, "—" not `0` for permission-denied rows, three-tier name fallback (`proc_name` → `proc_pidpath` basename → hardcoded `"kernel_task"` for pid 0). | §2 |
| 2. Sampling interval? | Fixed 1 second, matching Activity Monitor and `#0305`'s own default — a UX choice, not a cost constraint, since even the full per-tick cost across all four categories (process list + SMC + system-wide + thermal) is under 1% of the interval budget. Adaptive and configurable both explicitly rejected as unjustified complexity. | §3 |
| 3. Hidden-pane history? | Discard. A hidden pane keeps nothing (no ring buffer, no delta map); `setVisible(true)` re-samples everything fresh in a few milliseconds, an imperceptible cost that makes "keep for continuity" not worth its complexity. The SMC connection is never held across ticks in the first place (§6 — opened, read, and closed once per tick, cheaper than a single key read), so there is nothing hide-specific to release there either. One documented consequence: CPU% reads "—" for one tick after every show, since the delta baseline restarts. | §4 |
| Shared infrastructure with `#0305`? | A per-pid libproc sampling primitive (task info, rusage, name/path with the same fallback tier, argv) is genuinely shared; whole-machine metrics (thermal, CPU, memory, load average, and — now — SMC temperature/fan) are `#0314`-only. Named, not built: a `ProcessMetricsReader`-shaped type with `sample(pid:)` and `sampleAll()`. | §5 |

---

## Verification for this issue

**Documentation and a static HTML mockup only — no Swift source changed,
no `PaneRuntime`/`PaneView`/`PaneContentKind` touched.** The feasibility
spike (§1) ran as standalone Swift scripts outside the repository and is
not part of this commit.

```
scripts/build.sh unit
```

`Configuration/Active.xcconfig` read `#include "Prod.xcconfig"` before
running — Prod, not Beta. Baseline check only, since this document
introduces no Swift source at all.

The companion mockup, `docs/design/system-metrics-view.html`, is a
self-contained (no network requests, no external resources) HTML file
matching `docs/design/process-status-view.html`'s visual language,
covering: nominal/healthy state with numeric temperature/fan tiles and a
mid-size process list; thermal pressure (Serious and Critical, both, since
the issue names "thermal pressure (serious/critical)" as a state to cover
explicitly); the two open SMC caveats from §1.4 — not yet re-verified
inside the signed app bundle, and model-specific key names — stated
directly in the UI rather than only in this prose (this state replaced an
earlier "Temperature — unavailable" state built on this document's own
disproven round-1 finding); and the process list at a size near what
§1.7 actually measured (~800 rows, scrolled), not a token 5-row
placeholder.

### What phase 2 additionally owes, made visible before approval

Identical obligation `docs/design/git-status-view.md` and `docs/design/
process-status-view.md` already name for their own phase 2, because all
three land in the same shared `PaneView`/`PaneRuntime` path: **whichever
issue first lands the `PaneContentKind` field and `PaneView`'s
kind-switch** must re-run the full manual checklist in
`docs/terminal-pane-requirements.md` §6 on **terminal** panes generally,
and again on a **terminal** pane in a **mixed-kind session** — this
document's phase 2, if it lands after `#0304`/`#0305`'s, inherits the
already-paid cost for the mechanism itself but should still verify a
terminal pane alongside a `system-metrics` pane specifically, per that
document's own "fine in isolation, wrong in composition" reasoning.
**Additionally specific to this view, both carried from §1.4 rather than
resolved here**: phase 2 must re-run the SMC probe inside the actual
signed, notarized, hardened-runtime `Batty.app` before shipping — every
read in §1.4 ran as an ad-hoc script, and Hardened Runtime can gate IOKit
user-client access differently than an unsigned script; and phase 2 needs
either a per-model SMC key table or a runtime key-discovery pass, since
this document's key list is confirmed on exactly one Mac. Phase 2 should
also re-verify §1.2's open notification-delivery question against a real
thermal-state transition if one can be induced safely (e.g. sustained
build load), since this design's phase 1 spike could not responsibly force
one.

---

*Document version: 3 — 2026-08-08. Written for `#0314` phase 1. No code
changes accompany this document except the throwaway feasibility spike
(§1), which was run outside the repository and is not part of this
commit. Phase 2 (implementation) is gated on user approval of this
document and its companion mockup, per the `#0301` umbrella's design-first
gate.*

*Version 2 (review round 1): reversed §1.4's central finding — SMC
temperature and fan RPM reads ARE obtainable, unprivileged, on this
machine; round 1's negative result was a struct-size bug in the spike
script (76 bytes sent, 80 expected) compounded by a key byte-order bug,
not a fact about the machine or a permission gate, and the
Apple-silicon-transport theory built on top of it is retracted. §1.4's
error code is now correctly identified as `kIOReturnBadArgument`
(`IOReturn.h:102`), not left as "unidentifiable." §2's thermal decision,
§7's layout, the "not shown in phase 1" list, and the mockup's states 1-4
are rewritten accordingly, with two open caveats (signed-app-bundle
re-verification, model-specific key names) carried forward explicitly
rather than resolved by assertion. §1.7's `proc_name`-failure claim is
corrected from "only `/usr/bin/login`" (a 5-example over-generalization)
to the actual 213-basename distribution, and a third name fallback
(hardcoded `"kernel_task"` for pid 0, the one pid where `proc_pidpath`
itself also fails) is added — both found by re-running the spike without
the filtering/truncation the round-1 script applied. §1.3's inference
that an empty `ioreg` scan implies nothing is SMC-readable is retracted as
a non sequitur — SMC keys are not IORegistry properties. §6's lifecycle
table now accounts for the SMC `io_connect_t` as a real kernel handle this
design holds and must explicitly `IOServiceClose` on hide/teardown, a
resource class the rest of this design (all stateless per-call reads)
didn't need until §1.4's correction introduced one.*

*Version 3 (review round 2): §6's justification for a persistent SMC
connection ("the connection... is the expensive-to-repeat part") was
never measured and turned out to be backwards — a full open+close cycle
costs ~0.05ms, cheaper than a single ~0.1-0.14ms key read. §6 is rewritten
to open, read, and close the SMC connection fresh every tick instead,
removing the connection field, the `setVisible(false)`/`tearDown()` close
step, the double-close guard, and the close-race guard the persistent
design needed — this also restores, for the SMC path too, this document's
own "every call opens nothing and holds nothing open between calls"
property. Narrowed the concurrency reasoning: under `SWIFT_DEFAULT_ACTOR_
ISOLATION = MainActor`, the sampling loop and `setVisible(false)` can only
interleave at a suspension point, so the prescribed `Task.isCancelled`
check is correct and sufficient on its own, not a guard against a broader
race. Fixed a stray assertion-dressed-as-measurement citation on
`setVisible(true)`'s row (moot now that the connection isn't held, but
corrected regardless). Fixed §1.4's `IOReturn.h` path — the header lives
inside the SDK, not at the bare `/System/Library/...` path this document
previously claimed to have grepped directly. Reconciled the process-count
range (~802-805, the two numbers §1.7 actually measured) across this
document, its summary table, and `docs/README.md` — an earlier version
carried a stray "~812" that didn't trace to anything in this document's
own body. Removed now-dead `.metric-tile.unavailable` CSS from the
mockup.*
