// ProcessInspectorTests.swift

import Darwin
import Foundation
import Testing
@testable import BattyKit

/// Covers `ProcessInspector` (`#0305`) against real, live processes — the
/// unit-testable slice of `docs/design/process-status-view.md`'s spike:
/// same-uid reads succeed, a different-uid target (`launchd`, pid 1)
/// distinguishes `EPERM` from `ESRCH`, and identity data (`proc_pidpath`)
/// keeps working where metrics data doesn't (§1.6's "looser permission
/// tier" finding). These are live-process assertions, not mocked — the
/// same headless-safe shape the spike itself used, run against the test
/// executor's own process and the kernel's own `launchd`.
@MainActor
struct ProcessInspectorTests {

    // MARK: - Core metrics: same-uid succeeds

    @Test func coreMetricsSucceedsForSelfWithPlausibleValues() {
        let result = ProcessInspector.coreMetrics(pid: getpid())
        guard case .success(let metrics) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(metrics.residentBytes > 0)
        #expect(metrics.physFootprintBytes > 0)
        #expect(metrics.threadCount >= 1)
    }

    @Test func coreMetricsFailsProcessNotFoundForANeverAllocatedPid() {
        let result = ProcessInspector.coreMetrics(pid: 999_999)
        guard case .failure(let failure) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(failure == .processNotFound)
    }

    /// §1.4: an exited pid gives `ESRCH`, distinguishable from `EPERM` —
    /// spawns a real short-lived process, waits for it to exit, then
    /// samples the now-stale pid, mirroring the spike's own methodology.
    @Test func coreMetricsFailsProcessNotFoundAfterTheTargetExits() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.05"]
        try process.run()
        let pid = process.processIdentifier
        process.waitUntilExit()

        let result = ProcessInspector.coreMetrics(pid: pid)
        guard case .failure(let failure) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(failure == .processNotFound)
    }

    /// §1.2/§1.5: `launchd` (pid 1, root-owned) fails every metrics call
    /// with `EPERM`, never `ESRCH` — it exists, this process just can't
    /// read it. Assumes the test runner is not itself root.
    @Test func coreMetricsFailsPermissionDeniedForARootOwnedProcess() {
        let result = ProcessInspector.coreMetrics(pid: 1)
        guard case .failure(let failure) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(failure == .permissionDenied)
    }

    // MARK: - Identity: a looser permission tier than metrics (§1.6)

    @Test func identityResolvesNameAndPathForSelf() {
        let identity = ProcessInspector.identity(pid: getpid())
        #expect(identity.name != nil)
        #expect(identity.executablePath != nil)
    }

    /// The central §1.6 finding this view's permission-denied banner
    /// depends on: `proc_pidpath` succeeds for a root-owned target even
    /// though every metrics call against the same pid fails `EPERM`.
    @Test func identityResolvesExecutablePathForARootOwnedProcessEvenThoughMetricsFail() {
        let identity = ProcessInspector.identity(pid: 1)
        #expect(identity.executablePath != nil)
    }

    // MARK: - Command line: same permission tier as metrics (§1.6)

    @Test func commandLineSucceedsForSelf() {
        let result = ProcessInspector.commandLine(pid: getpid())
        guard case .success(let commandLine) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(!commandLine.isEmpty)
    }

    @Test func commandLineFailsForARootOwnedProcess() {
        let result = ProcessInspector.commandLine(pid: 1)
        guard case .failure = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
    }

    // MARK: - On-demand disclosures

    @Test func listOpenFileDescriptorsSucceedsForSelf() {
        let descriptors = ProcessInspector.listOpenFileDescriptors(pid: getpid())
        #expect(descriptors != nil)
    }

    @Test func listOpenFileDescriptorsFailsForARootOwnedProcess() {
        let descriptors = ProcessInspector.listOpenFileDescriptors(pid: 1)
        #expect(descriptors == nil)
    }

    @Test func childrenOfPidFindsARealSpawnedChildProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["2"]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        let children = ProcessInspector.children(ofPid: getpid())
        #expect(children.contains { $0.id == process.processIdentifier })
    }

    @Test func allSameUserProcessesIncludesSelf() {
        let processes = ProcessInspector.allSameUserProcesses()
        #expect(processes.contains { $0.id == getpid() })
    }

    // MARK: - CPU time unit conversion (review round 1, B1)

    /// `rusage_info_v4.ri_user_time`/`ri_system_time` are mach-absolute-
    /// time ticks, not nanoseconds, despite their field names and despite
    /// some Apple documentation implying otherwise. Measured on this
    /// machine while fixing round 1: `numer=125 denom=3` (41.667
    /// ns/tick). This pins the conversion directly rather than only
    /// indirectly through a live CPU% computation.
    /// `#0314` merge note: `MachTimebase` is now the shared type from
    /// `ProcessCPUDeltaTracker.swift` (its own `nanosecondsPerTick` only —
    /// no `nanoseconds(fromTicks:)` convenience method, so the multiply is
    /// inlined here instead of calling one).
    @Test func machTimebaseConvertsTicksToTheMeasuredNanosecondsPerTickRatio() {
        let oneSecondOfTicksAtMeasuredRatio = UInt64(1_000_000_000 / MachTimebase.nanosecondsPerTick)
        let converted = UInt64((Double(oneSecondOfTicksAtMeasuredRatio) * MachTimebase.nanosecondsPerTick).rounded())
        // Allow a small rounding tolerance — the point is "close to 1s of
        // nanoseconds," not exact integer division round-tripping.
        #expect(abs(Int64(converted) - 1_000_000_000) < 1_000_000)
    }

    /// `#0314` merge note: `CoreMetrics` now carries raw mach ticks
    /// (`cpuTicksUser`/`cpuTicksSystem`), not pre-converted nanoseconds —
    /// this test's own bounds are unchanged (round 2 review: this test's
    /// looseness doesn't catch a unit-conversion regression and a
    /// follow-up is filed separately for it; this is a mechanical field
    /// rename only, not a strengthening).
    @Test func coreMetricsCpuTimeIsPlausibleAfterConversionNotOffByAMachTimebaseFactor() {
        // #0290's own "never trust a self-reported number without an
        // independent second source" pattern, applied to this reading:
        // the test process has been running for at least the duration of
        // this test suite so far, so its cumulative CPU time must be a
        // real, small-but-nonzero number of nanoseconds — not the ~42x
        // smaller value B1's raw-ticks-as-nanoseconds bug would have
        // produced for the same underlying counter, and not something
        // absurdly large either (which an inverse mistake, e.g.
        // multiplying instead of the raw value, would produce).
        guard case .success(let metrics) = ProcessInspector.coreMetrics(pid: getpid()) else {
            Issue.record("expected coreMetrics to succeed for self")
            return
        }
        let totalTicks = metrics.cpuTicksUser &+ metrics.cpuTicksSystem
        let totalNanoseconds = Double(totalTicks) * MachTimebase.nanosecondsPerTick
        #expect(totalNanoseconds > 0)
        // Looser upper bound than a tight timing assertion would need —
        // this only needs to rule out a gross unit error, not pin an
        // exact value under parallel-test-suite scheduling variance.
        #expect(totalNanoseconds < 60_000_000_000) // 60s of cumulative CPU
    }

    /// Review round 3, B1: neither test above catches a corrupted
    /// `MachTimebase.nanosecondsPerTick`. The ratio test above is
    /// `x / y * y ≈ x`, tautological for any non-zero `y` — it cancels
    /// out an error *in* the constant it multiplies by. The plausibility
    /// bound above is 60s, wide enough that a ~42x under-report (this
    /// issue's own B1: `nanosecondsPerTick` collapsed to `1.0`, the
    /// original ticks-as-nanoseconds bug) sails through undetected —
    /// proven: forcing it to `1.0` left `main`'s full suite at 1 failure
    /// (only `ProcessStatusPaneContentTests`'s live CPU% test, which
    /// re-derives its expectation using this same constant and is
    /// therefore just as circular against a bug *in* it).
    ///
    /// This is the non-circular pin: `mach_absolute_time()` is exactly
    /// the counter `mach_timebase_info` (and so `nanosecondsPerTick`)
    /// converts — the same doc comment on `MachTimebase` says so.
    ///
    /// `#0431`: no interval needed at all, per `docs/async-test-seams.md`
    /// §5 Q2 — `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` is documented
    /// (`clock_gettime(3)`) to be `mach_absolute_time()` "after the
    /// appropriate `mach_timebase` conversion is applied," i.e. already in
    /// nanoseconds. So instead of bracketing a real sleep with two
    /// independently-implemented clocks and comparing elapsed intervals,
    /// this takes one `mach_absolute_time()` reading and one
    /// `CLOCK_UPTIME_RAW` reading back-to-back and compares
    /// `Double(mach_absolute_time()) * MachTimebase.nanosecondsPerTick`
    /// (this codebase's own conversion) directly against the raw
    /// `CLOCK_UPTIME_RAW` nanosecond value the kernel already converted —
    /// both are absolute values since boot, not a bracketed delta, so a
    /// corrupted constant (this issue's ~42x, or an inverted conversion)
    /// produces a huge disagreement between them with no wait required.
    @Test func machTimebaseNanosecondsPerTickAgreesWithAnIndependentClock() {
        let ticks = mach_absolute_time()
        let independentNanoseconds = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        let computedNanoseconds = Double(ticks) * MachTimebase.nanosecondsPerTick

        #expect(independentNanoseconds > 0, "expected CLOCK_UPTIME_RAW to report nonzero time since boot")
        let ratio = computedNanoseconds / Double(independentNanoseconds)
        // #0431 round 2, B1: a 2x band is far too loose — a reviewer
        // multiplied `nanosecondsPerTick` by 2, 1.5, and 1.9, and all three
        // still passed it. Back-to-back reads of these two absolute
        // since-boot clocks agree to within about 166ns out of well over
        // 1e11 (measured on this host), so a ~1e-3 relative tolerance
        // still comfortably absorbs that gap while a corrupted constant —
        // this issue's ~42x, or a smaller 1.5x/1.9x/2x tamper — misses by
        // orders of magnitude more than that. The two reads are not
        // guaranteed to be nanoseconds apart: a preempted thread can be
        // descheduled between them for milliseconds under load, but that
        // gap is still negligible against a since-boot value that's
        // ordinarily minutes to hours (many orders of magnitude larger),
        // which is what keeps the ratio inside this tighter band.
        #expect(
            abs(ratio - 1) < 1e-3,
            "MachTimebase.nanosecondsPerTick (\(MachTimebase.nanosecondsPerTick)) converts mach_absolute_time() (\(ticks)) to \(computedNanoseconds)ns, but CLOCK_UPTIME_RAW independently reports \(independentNanoseconds)ns since boot — the conversion constant itself looks wrong"
        )
    }

    // MARK: - `parseProcArgs2` argv/environment boundary (review round 1, F1)

    /// Builds a synthetic `KERN_PROCARGS2`-shaped buffer by hand — argc,
    /// the saved exec path, then `argc` NUL-terminated argv strings, one
    /// of them deliberately zero-length, followed by a fake environment
    /// string that must never appear in the result. This is a direct,
    /// deterministic test of the exact defect: the previous parser only
    /// decremented its remaining-arg counter when the current argument
    /// was non-empty, so a genuinely empty argv element left the loop one
    /// terminator short of `argc` and it kept consuming bytes straight
    /// into the environment block that follows argv in this same buffer.
    @Test func parseProcArgs2StopsExactlyAtArgcAndNeverLeaksPastAZeroLengthArgument() {
        var buffer: [UInt8] = []
        var argc: Int32 = 3
        withUnsafeBytes(of: &argc) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: Array("/bin/prog".utf8))
        buffer.append(0) // saved exec path terminator
        buffer.append(contentsOf: [0, 0, 0]) // alignment padding, arbitrary count
        buffer.append(contentsOf: Array("/bin/prog".utf8))
        buffer.append(0) // argv[0] terminator
        buffer.append(0) // argv[1]: a genuinely zero-length argument
        buffer.append(contentsOf: Array("afterward".utf8))
        buffer.append(0) // argv[2] terminator
        buffer.append(contentsOf: Array("SECRET_TOKEN=leaked-if-broken".utf8))
        buffer.append(0)

        let result = ProcessInspector.parseProcArgs2(buffer)

        #expect(result == "/bin/prog  afterward")
        #expect(!result.contains("SECRET"))
    }

    @Test func parseProcArgs2HandlesATrailingZeroLengthArgumentTheSameWay() {
        var buffer: [UInt8] = []
        var argc: Int32 = 2
        withUnsafeBytes(of: &argc) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: Array("/bin/prog".utf8))
        buffer.append(0)
        buffer.append(contentsOf: Array("/bin/prog".utf8))
        buffer.append(0) // argv[0] terminator
        buffer.append(0) // argv[1]: zero-length, and the last one
        buffer.append(contentsOf: Array("SECRET_TOKEN=leaked-if-broken".utf8))
        buffer.append(0)

        let result = ProcessInspector.parseProcArgs2(buffer)

        #expect(result == "/bin/prog ")
        #expect(!result.contains("SECRET"))
    }

    /// **Round 2's finding**: a zero-length `argv[0]` specifically is not
    /// caught by the two fixtures above, because both hand-place their
    /// empty argument at index ≥ 1 — never at index 0, the one position
    /// the old padding-skip loop was blind to (an empty `argv[0]`'s own
    /// terminator is indistinguishable from padding by *value* alone;
    /// only the kernel's real 8-byte alignment distinguishes them by
    /// *position*). A hand-built buffer that merely "looks like" the
    /// format encodes this same implementer's own model of it — exactly
    /// what let the bug through review round 1 — so this derives the
    /// buffer from an actually-spawned process instead: `posix_spawn`
    /// (not `Foundation.Process`, which does not offer a way to set a
    /// literal empty `argv[0]`) a real same-uid child with `argv = {"",
    /// "2"}` and an environment containing a marker secret, then reads
    /// that child's own real `KERN_PROCARGS2` buffer back through the
    /// production `commandLine(pid:)` path — not a copy of the parser,
    /// the actual function every other caller uses.
    @Test func commandLineHandlesARealProcessWithAZeroLengthArgvZeroWithoutLeakingItsEnvironment() throws {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(""), strdup("2"), nil]
        var envp: [UnsafeMutablePointer<CChar>?] = [strdup("SECRET_TOKEN=supersecretvalue"), strdup("PATH=/usr/bin:/bin"), nil]
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        let spawnRC = posix_spawn(&pid, "/bin/sleep", nil, nil, &argv, &envp)
        #expect(spawnRC == 0)
        guard spawnRC == 0 else { return }
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        // No wait needed here (`#0431`, `docs/async-test-seams.md` §5 Q1):
        // XNU's exec path lays out argv/envp on the new image's stack
        // (`exec_copyout_strings`, the same data `KERN_PROCARGS2` reads
        // back) synchronously as part of bringing up the new image, before
        // `posix_spawn` returns to userspace — so `KERN_PROCARGS2` is
        // already queryable the instant `posix_spawn` succeeds.
        guard case .success(let commandLine) = ProcessInspector.commandLine(pid: pid) else {
            Issue.record("expected commandLine to succeed for a same-uid child process")
            return
        }

        #expect(!commandLine.contains("SECRET_TOKEN"), "a zero-length argv[0] must not cause the parser to overrun into the environment block — got \(commandLine)")
        #expect(commandLine == " 2", "the empty argv[0] should be preserved as an empty element, not skipped as padding")
    }

    // MARK: - fd listing grows past its initial capacity (review round 1, S2)

    /// The hardcoded 4096-entry cap the previous version used truncated
    /// silently. This opens enough real descriptors to plausibly exceed
    /// whatever the size-probe-derived initial capacity guessed, and
    /// confirms `openFileDescriptorCount` still reports (at least) all of
    /// them — proving the grow-and-retry path actually runs rather than
    /// silently dropping anything past its first allocation.
    @Test func openFileDescriptorCountGrowsPastItsInitialCapacityWhenNeeded() {
        let targetExtra = 1500
        var raisedLimit = rlimit(rlim_cur: 0, rlim_max: 0)
        if getrlimit(RLIMIT_NOFILE, &raisedLimit) == 0 {
            let desired = rlim_t(targetExtra + 256)
            if raisedLimit.rlim_cur < desired {
                raisedLimit.rlim_cur = min(desired, raisedLimit.rlim_max)
                _ = setrlimit(RLIMIT_NOFILE, &raisedLimit)
            }
        }

        var openedFDs: [Int32] = []
        openedFDs.reserveCapacity(targetExtra)
        for _ in 0..<targetExtra {
            let fd = open("/dev/null", O_RDONLY)
            guard fd >= 0 else { break }
            openedFDs.append(fd)
        }
        defer {
            for fd in openedFDs { close(fd) }
        }

        // If the environment's rlimit wouldn't even allow opening a
        // useful number of extra descriptors, this test can't exercise
        // growth meaningfully — but on any normal macOS dev/CI machine it
        // should comfortably allow well past the old 4096-entry cap once
        // combined with whatever the process already had open.
        guard openedFDs.count > 600 else {
            Issue.record("could only open \(openedFDs.count) extra descriptors — environment too constrained to exercise the growth path meaningfully")
            return
        }

        let count = ProcessInspector.openFileDescriptorCount(pid: getpid())
        #expect((count ?? 0) >= openedFDs.count)
    }
}
