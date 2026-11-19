// ProcessSignalTests.swift

import Darwin
import Foundation
import Testing
@testable import BattyKit

@Suite(.auditsSignals)
nonisolated struct ProcessSignalTests {
    @Test func hardRefusalsCoverPidZeroAndNegativeAndGroupsZeroOneAndOurOwn() {
        #expect(ProcessSignal.refusal(for: .pid(0)) != nil)
        #expect(ProcessSignal.refusal(for: .pid(-1)) != nil)
        #expect(ProcessSignal.refusal(for: .pid(-getpgrp())) != nil)
        #expect(ProcessSignal.refusal(for: .group(0)) != nil)
        #expect(ProcessSignal.refusal(for: .group(1)) != nil)
        #expect(ProcessSignal.refusal(for: .group(-5)) != nil)
        #expect(ProcessSignal.refusal(for: .group(getpgrp())) != nil)
        #expect(ProcessSignal.refusal(for: .pid(getpid())) == nil)
    }

    @Test func aProcessThatAlreadyExitedIsNeverSignalled() async throws {
        let fixture = ChildProcessFixture()
        defer { fixture.killAndReapAll() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let exited = ChildProcessFixture.exitEvent(of: process)
        let before = SignalAudit.violations.count
        try fixture.run(process)
        #expect(await exited())
        #expect(ProcessSignal.send(SIGTERM, to: process) == ESRCH)
        #expect(SignalAudit.violations.count == before)
    }

    @Test func aRefusedSignalIsNeverDelivered() async throws {
        let canary = try TrapCanary(label: "private", argv0: "/bin/sh", ownGroup: true)
        #expect(await canary.waitUntilReady())
        SignalAudit.blockForTesting(SIGTERM, toPid: canary.child.pid)
        #expect(canary.child.signal(SIGTERM) == EPERM)
        #expect(canary.child.signal(SIGUSR1) == 0)
        #expect(await canary.child.reap() != nil)
        #expect(canary.check() == "private canary caught SIGUSR1")
    }
}

nonisolated struct SignalAuditTests {
    private func world(
        entries: [pid_t: SpawnedProcessRegistry.Entry] = [:],
        parents: [pid_t: pid_t] = [:],
        groups: [pid_t: pid_t] = [:]
    ) -> SignalAudit.World {
        SignalAudit.World(
            entry: { entries[$0] },
            parent: { parents[$0] },
            group: { groups[$0] },
            selfPid: 100_100,
            runnerGroup: 100_000
        )
    }

    @Test func aPidNoTestSpawnedIsNotPermitted() {
        let foreign = getppid()
        let verdict = SignalAudit.verdict(for: .pid(foreign), currentTest: nil, world: world(parents: [foreign: 1], groups: [foreign: foreign]))
        guard case .refused = verdict else { Issue.record("\(verdict)"); return }
    }

    @Test func aReapedOwnedChildIsNotPermitted() {
        let entry = SpawnedProcessRegistry.Entry(testID: nil, ownGroup: true, reaped: true)
        let w = world(entries: [100_500: entry], parents: [100_500: 100_100])
        guard case .refused = SignalAudit.verdict(for: .pid(100_500), currentTest: nil, world: w) else {
            Issue.record("reaped pid permitted"); return
        }
        guard case .refused = SignalAudit.verdict(for: .group(100_500), currentTest: nil, world: w) else {
            Issue.record("reaped group permitted"); return
        }
    }

    @Test func anotherTestsChildIsRecordedAsAViolation() {
        let entry = SpawnedProcessRegistry.Entry(testID: "owner", ownGroup: true)
        let w = world(entries: [100_500: entry])
        #expect(SignalAudit.verdict(for: .pid(100_500), currentTest: "owner", world: w) == .permitted)
        #expect(SignalAudit.verdict(for: .pid(100_500), currentTest: "other", world: w) == .crossTest)
        #expect(SignalAudit.verdict(for: .group(100_500), currentTest: "other", world: w) == .crossTest)
    }

    @Test func theRunnersOwnGroupIsNotPermitted() {
        let w = world(parents: [100_000: 100_100], groups: [100_000: 100_000])
        guard case .refused = SignalAudit.verdict(for: .group(100_000), currentTest: nil, world: w) else {
            Issue.record("runner group permitted"); return
        }
        guard case .refused = SignalAudit.verdict(for: .pid(100_100), currentTest: nil, world: w) else {
            Issue.record("runner pid permitted"); return
        }
    }
}

@Suite(.auditsSignals)
nonisolated struct SignalCanaryTests {
    @Test func aCanaryReportsTheSignalItCatches() async throws {
        let canary = try TrapCanary(label: "private", argv0: "/bin/sh", ownGroup: true)
        #expect(await canary.waitUntilReady())
        #expect(canary.check() == nil)
        canary.child.signal(SIGUSR1)
        #expect(await canary.child.reap() != nil)
        #expect(canary.check() == "private canary caught SIGUSR1")
    }

    @Test func aCanaryEndedBySIGKILLReportsItFromItsWaitStatus() async throws {
        let canary = try TrapCanary(label: "private", argv0: "/bin/sh", ownGroup: true)
        #expect(await canary.waitUntilReady())
        canary.child.signal(SIGKILL)
        let status = try #require(await canary.child.reap())
        #expect(status & 0x7f == SIGKILL)
        #expect(canary.check() == nil)
    }

    @Test func theRunWideCanariesAreUnsignalledAndNoViolationWasRecorded() {
        SignalAudit.ensureInstalled()
        #expect(SignalCanary.all.count == 2)
        #expect(SignalCanary.check().isEmpty)
        #expect(SignalAudit.violations.map(\.reason).isEmpty)
    }
}

@Suite(.auditsSignals)
nonisolated struct ChildProcessFixtureTests {
    @Test func theDeathReportNamesTheSignalThatEndedAChild() async throws {
        let fixture = ChildProcessFixture()
        defer { fixture.killAndReapAll() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        ChildLifetime.hold(process)
        let exited = ChildProcessFixture.exitEvent(of: process)
        try fixture.run(process)
        ProcessSignal.send(SIGKILL, to: process)
        #expect(await exited())
        let report = fixture.deathReport(for: process)
        #expect(report.contains("uncaughtSignal 9"), Comment(rawValue: report))
    }

    @Test func theDeathReportGivesTheExitStatusOfAChildThatExited() async throws {
        let fixture = ChildProcessFixture()
        defer { fixture.killAndReapAll() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 3"]
        let exited = ChildProcessFixture.exitEvent(of: process)
        try fixture.run(process)
        #expect(await exited())
        let report = fixture.deathReport(for: process)
        #expect(report.contains("exit status 3"), Comment(rawValue: report))
    }
}

/// Every real signal in BattyKit and its tests goes through `ProcessSignal`.
nonisolated struct SignalCallSiteAuditTests {
    @Test func onlyTheSeamSendsSignals() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let allowed: Set<String> = ["ProcessSignal.swift", "SignalAudit.swift", "ProcessSignalTests.swift"]
        let pattern = try NSRegularExpression(pattern: #"(?<![A-Za-z_.])(kill|killpg)\((?!\s*[^,()]+,\s*0\s*\))|\.terminate\(\)|\.interrupt\(\)"#)
        var offenders: [String] = []
        // Sources/batty is the CLI target, which no BattyKitTests test reaches.
        for directory in ["Sources/BattyKit", "Tests/BattyKitTests"] {
            let root = packageRoot.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" && !allowed.contains(url.lastPathComponent) {
                let text = try String(contentsOf: url, encoding: .utf8)
                for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    if code.hasPrefix("//") { continue }
                    let text = String(line)
                    if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                        offenders.append("\(url.lastPathComponent):\(index + 1): \(code)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "\n")))
    }
}
