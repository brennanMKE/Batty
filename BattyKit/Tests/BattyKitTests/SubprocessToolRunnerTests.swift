// SubprocessToolRunnerTests.swift

import Foundation
import Testing
@testable import batty

@Suite(.timeLimit(.minutes(1)))
nonisolated struct SubprocessToolRunnerTests {
    private let shell = URL(filePath: "/bin/sh")

    @Test func capturesStdoutStderrAndExitCode() async {
        let runner = SubprocessToolRunner(executableURL: shell)
        let result = await runner.run(["-c", "printf out; printf err >&2; exit 3"])
        #expect(result == MCPToolRunResult(exitCode: 3, stdout: "out", stderr: "err"))
    }

    @Test func largeOutputDoesNotDeadlock() async {
        let runner = SubprocessToolRunner(executableURL: shell)
        let result = await runner.run(["-c", "yes | head -c 200000; yes | head -c 200000 >&2"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.utf8.count == 200_000)
        #expect(result.stderr.utf8.count == 200_000)
    }

    @Test func childInheritsTheGivenEnvironment() async {
        let runner = SubprocessToolRunner(executableURL: URL(filePath: "/usr/bin/env"), environment: ["BATTY_PANE_ID": "PANE-1"])
        let result = await runner.run([])
        #expect(result.stdout.contains("BATTY_PANE_ID=PANE-1"))
    }

    @Test func cancellationTerminatesTheChild() async {
        let (launched, launchedContinuation) = AsyncStream<Void>.makeStream()
        let runner = SubprocessToolRunner(executableURL: shell, onLaunch: { launchedContinuation.yield() })
        // `exec` so the signal reaches the long-running child itself.
        let call = Task { await runner.run(["-c", "exec tail -f /dev/null"]) }
        for await _ in launched { break }
        call.cancel()
        let result = await call.value
        #expect(result.exitCode == SIGTERM)
    }
}
