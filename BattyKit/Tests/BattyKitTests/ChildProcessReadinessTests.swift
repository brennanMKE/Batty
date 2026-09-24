// ChildProcessReadinessTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Direct coverage of `ChildProcessReadiness` (#0428) — both entry points,
/// and the hang-guard expiry path neither one is supposed to rely on to
/// succeed.
struct ChildProcessReadinessTests {
    @Test func waitForDataResolvesTrueOnceTheChildWritesToThePipe() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo ready"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()

        let ready = await ChildProcessReadiness.waitForData(on: pipe, bound: 5)

        #expect(ready)
        process.waitUntilExit()
    }

    @Test func waitForDataResolvesFalseWithinTheBoundWhenNothingIsEverWritten() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec sleep 30"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        defer { process.terminate() }

        // No elapsed-time assertion here (AGENTS.md "Asynchronous tests"):
        // under heavy parallel load elsewhere in the suite, the hang
        // guard's own `DispatchQueue.global().asyncAfter` can legitimately
        // fire much later than its nominal bound without ever hanging —
        // `await` returning at all, with `ready == false`, is the
        // meaningful signal; how long it took isn't.
        let ready = await ChildProcessReadiness.waitForData(on: pipe, bound: 0.2)

        #expect(ready == false, "no writer ever produced data — this must resolve false, not hang")
    }

    @Test func waitForFIFOReadyResolvesTrueOnceTheChildWritesToTheFIFO() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-0428-fifo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifoPath = directory.appendingPathComponent("ready").path
        ChildProcessReadiness.makeFIFO(at: fifoPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo ready > '\(fifoPath)'"]
        try process.run()

        let ready = await ChildProcessReadiness.waitForFIFOReady(at: fifoPath, bound: 5)

        #expect(ready)
        process.waitUntilExit()
    }

    @Test func waitForFIFOReadyResolvesFalseWithinTheBoundWhenNoWriterEverOpensIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-0428-fifo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifoPath = directory.appendingPathComponent("ready").path
        ChildProcessReadiness.makeFIFO(at: fifoPath)

        // No elapsed-time assertion — see the pipe variant's twin test above.
        let ready = await ChildProcessReadiness.waitForFIFOReady(at: fifoPath, bound: 0.2)

        #expect(ready == false)
    }

    @Test func waitForFIFOReadyResolvesFalseImmediatelyWhenThePathDoesNotExist() async {
        let ready = await ChildProcessReadiness.waitForFIFOReady(at: "/nonexistent/batty-0428/no-such-fifo", bound: 5)
        #expect(ready == false)
    }
}
