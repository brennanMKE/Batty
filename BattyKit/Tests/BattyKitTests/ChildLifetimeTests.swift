// ChildLifetimeTests.swift

import Darwin
import Foundation
import Testing
@testable import BattyKit

nonisolated struct ChildLifetimeTests {

    /// Arms `process`'s `terminationHandler`, so call it before `run()`. The
    /// returned closure awaits the exit as an event, `false` only on the hang guard.
    private static func exitEvent(of process: Process) -> () async -> Bool {
        let stream = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield()
                continuation.finish()
            }
        }
        return {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let once = ResumeOnce(continuation)
                let timeout = DispatchWorkItem { once.resume(false) }
                once.setOnResumed { timeout.cancel() }
                Task {
                    for await _ in stream { break }
                    once.resume(true)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + TestBounds.hangGuard, execute: timeout)
            }
        }
    }

    @Test func aHeldChildExitsWhenItsStdinCloses() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo ready; \(ChildLifetime.holdCommand)"]
        ChildLifetime.hold(process)
        let readyPipe = Pipe()
        process.standardOutput = readyPipe
        let exited = Self.exitEvent(of: process)
        let fixture = ChildProcessFixture()
        defer { fixture.killAndReapAll() }
        try fixture.run(process)

        guard await ChildProcessReadiness.waitForData(on: readyPipe) else {
            Issue.record("the held child never started")
            return
        }
        try (process.standardInput as? Pipe)?.fileHandleForWriting.close()

        guard await exited() else {
            Issue.record("the held child outlived its stdin")
            return
        }
        #expect(process.terminationReason == .exit)
    }

    @Test func aHeldChildIgnoringSIGTERMStillDiesOnSIGKILL() async throws {
        let (directory, cleanup) = try LMStudioSIGTERMIgnoringFixture.makeReadyDirectory(callerTag: "child-lifetime")
        defer { cleanup() }
        let readyURL = directory.appendingPathComponent("ready")
        let process = LMStudioSIGTERMIgnoringFixture.makeProcess(readyFileURL: readyURL)
        let exited = Self.exitEvent(of: process)
        let fixture = ChildProcessFixture()
        defer { fixture.killAndReapAll() }
        try fixture.run(process)

        guard await LMStudioSIGTERMIgnoringFixture.waitForReadyFile(readyURL) else {
            Issue.record("the child never installed its SIGTERM trap")
            return
        }
        ProcessSignal.send(SIGTERM, toPid: process.processIdentifier)
        ProcessSignal.send(SIGKILL, toPid: process.processIdentifier)

        guard await exited() else {
            Issue.record("the child survived SIGKILL")
            return
        }
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
    }
}
