// SignalAudit.swift

import Darwin
import Foundation
import OSLog
import Testing
@testable import BattyKit

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SignalAudit")

/// Every child a test spawned, by pid: which test spawned it, whether it
/// leads its own process group, and whether it has been reaped.
nonisolated enum SpawnedProcessRegistry {
    struct Entry: Sendable {
        var testID: String?
        var ownGroup: Bool
        var reaped = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [pid_t: Entry] = [:]

    static func register(_ pid: pid_t, ownGroup: Bool) {
        lock.withLock { entries[pid] = Entry(testID: Test.current.map { "\($0.id)" }, ownGroup: ownGroup) }
    }

    static func markReaped(_ pid: pid_t) {
        lock.withLock { entries[pid]?.reaped = true }
    }

    static func entry(_ pid: pid_t) -> Entry? {
        lock.withLock { entries[pid] }
    }
}

/// The test-build audit behind `ProcessSignal.audit`: a send goes through
/// only to a child this run spawned and hasn't reaped, or to a live direct
/// child of the runner (production code's own `Process` children). Anything
/// else is refused, recorded and reported as a test issue, so a stray signal
/// fails a test instead of killing something.
nonisolated enum SignalAudit {
    struct Violation: Sendable {
        let target: ProcessSignal.Target
        let signal: Int32
        let reason: String
        let test: String?
        let stack: [String]
    }

    /// What the predicate needs to know about the host, injectable so its
    /// refusals can be checked without touching real processes.
    struct World: Sendable {
        var entry: @Sendable (pid_t) -> SpawnedProcessRegistry.Entry?
        var parent: @Sendable (pid_t) -> pid_t?
        var group: @Sendable (pid_t) -> pid_t?
        var selfPid: pid_t
        var runnerGroup: pid_t

        static let live = World(
            entry: { SpawnedProcessRegistry.entry($0) },
            parent: { ProcessSignal.parent(of: $0) },
            group: { pid in
                let pgid = getpgid(pid)
                return pgid < 0 ? nil : pgid
            },
            selfPid: getpid(),
            runnerGroup: getpgrp()
        )
    }

    enum Verdict: Equatable {
        case permitted
        case refused(String)
        /// Permitted target, but spawned by a different test than the one sending.
        case crossTest
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var recorded: [Violation] = []

    nonisolated(unsafe) private static var blocked: Set<String> = []

    static var violations: [Violation] { lock.withLock { recorded } }

    /// Refuses `sig` to `pid` without recording a violation, so a test can
    /// prove a refused send is never delivered.
    static func blockForTesting(_ sig: Int32, toPid pid: pid_t) {
        _ = lock.withLock { blocked.insert("\(pid)/\(sig)") }
    }

    private static let installLock = NSRecursiveLock()

    /// Idempotent; returns once the audit and the run-wide canaries are in place.
    static func ensureInstalled() {
        installLock.withLock {
            guard !installed else { return }
            installed = true
            ProcessSignal.audit = { target, sig in
                check(target, sig)
            }
            SignalCanary.start()
        }
    }

    static func verdict(for target: ProcessSignal.Target, currentTest: String?, world: World) -> Verdict {
        switch target {
        case .pid(let pid):
            if pid == world.selfPid { return .refused("pid \(pid) is the test runner") }
            if let entry = world.entry(pid) {
                if entry.reaped { return .refused("pid \(pid) was already reaped") }
                if let currentTest, let owner = entry.testID, owner != currentTest { return .crossTest }
                return .permitted
            }
            if world.parent(pid) == world.selfPid { return .permitted }
            if let pgid = world.group(pid), pgid != world.runnerGroup,
               verdict(for: .group(pgid), currentTest: nil, world: world) == .permitted {
                return .permitted
            }
            return .refused("pid \(pid) was not spawned by this run")
        case .group(let pgid):
            if pgid == world.runnerGroup { return .refused("process group \(pgid) is the runner's") }
            if let entry = world.entry(pgid) {
                if !entry.ownGroup { return .refused("pid \(pgid) does not lead its own group") }
                if entry.reaped { return .refused("group leader \(pgid) was already reaped") }
                if let currentTest, let owner = entry.testID, owner != currentTest { return .crossTest }
                return .permitted
            }
            if world.parent(pgid) == world.selfPid, world.group(pgid) == pgid { return .permitted }
            return .refused("process group \(pgid) was not created by this run")
        }
    }

    private static func check(_ target: ProcessSignal.Target, _ sig: Int32) -> Bool {
        if case .pid(let pid) = target, lock.withLock({ blocked.contains("\(pid)/\(sig)") }) {
            return false
        }
        let current = Test.current
        let reason: String
        switch verdict(for: target, currentTest: current.map { "\($0.id)" }, world: .live) {
        case .permitted: return true
        case .refused(let why): reason = why
        case .crossTest: reason = "target belongs to another test"
        }
        let violation = Violation(
            target: target,
            signal: sig,
            reason: reason,
            test: current.map { "\($0.id)" },
            stack: Thread.callStackSymbols
        )
        lock.withLock { recorded.append(violation) }
        logger.error("refused signal \(sig, privacy: .public) to \(String(describing: target), privacy: .public): \(reason, privacy: .public)")
        if current != nil {
            Issue.record("refused signal \(sig) to \(target): \(reason)\n\(violation.stack.joined(separator: "\n"))")
        }
        return false
    }
}

/// A child spawned with `posix_spawn` and registered with the audit. Signals
/// only go to it until it has been reaped.
nonisolated final class OwnedChild: @unchecked Sendable {
    let pid: pid_t
    let ownGroup: Bool
    private let lock = NSLock()
    private var reaped = false

    init(pid: pid_t, ownGroup: Bool) {
        self.pid = pid
        self.ownGroup = ownGroup
    }

    /// Returns 0 or an errno; `ESRCH` once reaped, without sending.
    @discardableResult
    func signal(_ sig: Int32) -> Int32 {
        guard !lock.withLock({ reaped }) else { return ESRCH }
        return ProcessSignal.send(sig, toPid: pid)
    }

    /// Signals the whole group this child leads.
    @discardableResult
    func signalGroup(_ sig: Int32) -> Int32 {
        guard ownGroup, !lock.withLock({ reaped }) else { return ESRCH }
        return ProcessSignal.send(sig, toGroup: pid)
    }

    /// Blocks until the child exits; call only off the main actor or for a
    /// child already signalled to exit.
    @discardableResult
    func reapNow() -> Int32 {
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        lock.withLock { reaped = true }
        SpawnedProcessRegistry.markReaped(pid)
        return status
    }

    /// Reaps off the main actor; nil if the hang guard expired first.
    func reap() async -> Int32? {
        await awaitBoundedValue {
            await Task.detached { self.reapNow() }.value
        }
    }
}

nonisolated enum TestChildSpawner {
    /// `posix_spawn`s `executable` with `arguments` (argv[0] included). With
    /// `ownGroup`, the child leads a new process group; otherwise it joins the
    /// runner's. `stdin`/`stdout` are optional fds dup'd onto the child's.
    static func spawn(
        _ executable: String,
        arguments: [String],
        ownGroup: Bool,
        joiningGroup: pid_t? = nil,
        environment: [String]? = nil,
        stdin: Int32? = nil,
        stdout: Int32? = nil
    ) throws -> OwnedChild {
        SignalAudit.ensureInstalled()
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO)
        if let stdin {
            posix_spawn_file_actions_adddup2(&actions, stdin, STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        if let stdout {
            posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO)
        } else {
            posix_spawn_file_actions_addinherit_np(&actions, STDOUT_FILENO)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Default dispositions and an empty mask: a shell can't trap a signal
        // that was ignored when it started, and the runner's are inherited.
        // CLOEXEC_DEFAULT: only the dup'd fds reach the child, so a long-lived
        // child never holds another test's pipe open.
        var flags = Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)
        if ownGroup || joiningGroup != nil {
            flags |= Int16(POSIX_SPAWN_SETPGROUP)
            posix_spawnattr_setpgroup(&attributes, joiningGroup ?? 0)
        }
        posix_spawnattr_setflags(&attributes, flags)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var envp: [UnsafeMutablePointer<CChar>?]? = environment.map { $0.map { strdup($0) } + [nil] }
        defer { envp?.forEach { free($0) } }
        var pid: pid_t = 0
        let rc: Int32
        if envp != nil {
            rc = posix_spawn(&pid, executable, &actions, &attributes, argv, &envp!)
        } else {
            rc = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        }
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO) }
        SpawnedProcessRegistry.register(pid, ownGroup: ownGroup && joiningGroup == nil)
        return OwnedChild(pid: pid, ownGroup: ownGroup && joiningGroup == nil)
    }
}

/// A `/bin/sh` that reports any catchable signal it receives by name on its
/// stdout pipe and exits. Its stdin is a pipe only we write to (never), so
/// it ends by itself when the runner dies. An uncatchable death shows up as
/// EOF, and `waitpid` gives the exact signal.
nonisolated final class TrapCanary: @unchecked Sendable {
    /// `wait` (unlike a foreground `read`) is interrupted by a trapped
    /// signal, so the trap runs at once. `cat` holds stdin so the canary ends
    /// when the runner closes it or dies.
    static let script = "for s in HUP INT QUIT ABRT USR1 USR2 ALRM TERM PIPE; do trap \"echo $s; kill \\$c 2>/dev/null; exit 0\" $s; done; /bin/cat <&0 >/dev/null & c=$!; echo ready; wait $c"

    let child: OwnedChild
    let label: String
    private let output: Pipe
    private let input: Pipe
    private let lock = NSLock()
    private var finding: String?

    init(label: String, argv0: String, ownGroup: Bool) throws {
        self.label = label
        output = Pipe()
        input = Pipe()
        child = try TestChildSpawner.spawn(
            "/bin/sh",
            arguments: [argv0, "-c", Self.script],
            ownGroup: ownGroup,
            stdin: input.fileHandleForReading.fileDescriptor,
            stdout: output.fileHandleForWriting.fileDescriptor
        )
        try output.fileHandleForWriting.close()
        try input.fileHandleForReading.close()
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// Resolves once the traps are installed. Use before `check()` only on a
    /// canary nothing else reads.
    func waitUntilReady() async -> Bool {
        let fd = output.fileHandleForReading.fileDescriptor
        let ready = await awaitBoundedValue {
            await Task.detached { () -> Bool in
                var pending = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pending, 1, -1) == 1 else { return false }
                var buffer = [UInt8](repeating: 0, count: 6)
                return read(fd, &buffer, buffer.count) == 6 && buffer == Array("ready\n".utf8)
            }.value
        }
        return ready == true
    }

    /// Non-blocking. Nil while the canary is alive and has caught nothing.
    func check() -> String? {
        if let finding = lock.withLock({ finding }) { return finding }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
        var result: String?
        if count > 0 {
            let caught = String(decoding: buffer[0..<count], as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .filter { $0 != "ready" }
            if let name = caught.first {
                result = "\(label) canary caught SIG\(name)"
            }
        }
        var status: Int32 = 0
        if waitpid(child.pid, &status, WNOHANG) == child.pid {
            SpawnedProcessRegistry.markReaped(child.pid)
            let signal = status & 0x7f
            result = result ?? (signal != 0
                ? "\(label) canary died of signal \(signal) (\(String(cString: strsignal(signal))))"
                : "\(label) canary exited with status \((status >> 8) & 0xff)")
        }
        if let result { lock.withLock { finding = result } }
        return result
    }

    /// Ends the canary: closing its stdin makes the read loop exit.
    func finish() async -> Int32? {
        try? input.fileHandleForWriting.close()
        return await child.reap()
    }
}

/// Two run-wide canaries, started the first time the audit is installed:
/// one leading its own group with a path that matches the follow tests'
/// copied children (catches a pattern-based external kill), one in the
/// runner's group (catches a signal to the runner's group).
nonisolated enum SignalCanary {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var canaries: [TrapCanary] = []
    nonisolated(unsafe) private static var startError: String?

    static func start() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-0486-\(UUID().uuidString)", isDirectory: true)
        do {
            let ownGroup = try TrapCanary(
                label: "own-group",
                argv0: directory.appendingPathComponent("bt0486-canary").path,
                ownGroup: true
            )
            let runnerGroup = try TrapCanary(label: "runner-group", argv0: "/bin/sh", ownGroup: false)
            lock.withLock { canaries = [ownGroup, runnerGroup] }
        } catch {
            lock.withLock { startError = "canaries failed to start: \(error)" }
        }
    }

    static var all: [TrapCanary] { lock.withLock { canaries } }

    /// Non-blocking: what any canary has seen so far.
    static func check() -> [String] {
        let startError = lock.withLock { startError }
        return (startError.map { [$0] } ?? []) + all.compactMap { $0.check() }
    }

    /// Reports any canary finding as an issue of the current test.
    static func recordFindings() {
        for finding in check() where Test.current != nil {
            Issue.record(Comment(rawValue: finding))
        }
    }
}

/// Suite trait that installs the signal audit before the suite runs and
/// reports canary findings after each test.
nonisolated struct AuditsSignalsTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: () async throws -> Void) async throws {
        SignalAudit.ensureInstalled()
        try await function()
        if testCase != nil { SignalCanary.recordFindings() }
    }
}

extension Trait where Self == AuditsSignalsTrait {
    static var auditsSignals: Self { AuditsSignalsTrait() }
}
