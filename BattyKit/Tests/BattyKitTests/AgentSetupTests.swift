// AgentSetupTests.swift

@testable import BattyCLICore
import Foundation
import Testing
@testable import BattyKit

nonisolated struct AgentInstallPlanRestrictionTests {
    private let claude = URL(filePath: "/fake/bin/claude")

    @Test func actionHostsMatchTheirDestinations() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".codex")
        try fixture.mkdir(".cursor")
        let plan = fixture.installer(executables: ["claude": claude]).plan(identity: try fixture.identity())
        for action in plan.actions {
            switch action {
            case .stageMarketplace, .runClaude, .printClaudeCommands: #expect(action.host == .claudeCode)
            case let .copySkill(host, _), let .mergeMCPEntry(host, _, _, _): #expect(action.host == host)
            case .writeCodexMCPBlock, .removeCodexMCPBlock: #expect(action.host == .codex)
            case let .removeSkill(host, _), let .removeMCPEntry(host, _, _): #expect(action.host == host)
            }
        }
    }

    @Test func restrictedKeepsOnlyAcceptedHostsInOrder() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".codex")
        let plan = fixture.installer(executables: ["claude": claude]).plan(identity: try fixture.identity())
        let restricted = plan.restricted(to: [.codex, .crossTool])
        #expect(restricted.hosts == [.codex, .crossTool])
        #expect(restricted.actions == plan.actions.filter { $0.host == .codex || $0.host == .crossTool })
        #expect(plan.restricted(to: []).actions.isEmpty)
    }

    @Test func removalPlanCoversOnlyRequestedHosts() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let plan = fixture.installer(executables: ["claude": claude]).removalPlan(identity: try fixture.identity(), hosts: [.cursor, .codex])
        #expect(plan.hosts == [.cursor, .codex])
        #expect(plan.actions.allSatisfy { $0.host == .cursor || $0.host == .codex })
        #expect(plan.actions.contains { if case .removeCodexMCPBlock = $0 { true } else { false } })
        #expect(plan.actions.contains { if case .removeMCPEntry(.cursor, _, ["mcpServers", "batty"]) = $0 { true } else { false } })
    }

    @Test func removalPlanPrintsClaudeCommandsWithoutClaude() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let identity = try fixture.identity()
        let printed = fixture.installer().removalPlan(identity: identity, hosts: [.claudeCode])
        guard case let .printClaudeCommands(commands) = try #require(printed.actions.first) else {
            Issue.record("expected printed commands")
            return
        }
        #expect(commands == ["claude plugin uninstall \(identity.pluginName)@\(identity.marketplaceName)", "claude plugin marketplace remove \(identity.marketplaceName)"])
        let run = fixture.installer(executables: ["claude": claude]).removalPlan(identity: identity, hosts: [.claudeCode])
        #expect(run.actions == [
            .runClaude(executable: claude, arguments: ["plugin", "uninstall", "\(identity.pluginName)@\(identity.marketplaceName)"]),
            .runClaude(executable: claude, arguments: ["plugin", "marketplace", "remove", identity.marketplaceName]),
        ])
    }

    @Test func problemLinesListOnlyManualAndFailed() {
        let copy = AgentInstallAction.copySkill(host: .crossTool, destination: URL(filePath: "/x"))
        let report = AgentInstallReport(entries: [(copy, .done("")), (copy, .unchanged), (copy, .manual("do it")), (copy, .failed("boom"))])
        #expect(report.problemLines.count == 2)
        #expect(report.problemLines[0].hasPrefix("  manual:"))
        #expect(report.problemLines[1].hasPrefix("  FAILED:"))
    }
}

nonisolated func installedRecord(_ hosts: [AgentHost: String]) -> AgentSetupRecord {
    AgentSetupRecord(hosts: Dictionary(uniqueKeysWithValues: hosts.map { ($0.key.rawValue, AgentSetupRecord.InstalledHost(fingerprint: $0.value, version: "1.4.0")) }))
}

nonisolated struct AgentSetupPolicyTests {
    private func plan(_ fixture: AgentInstallFixture, claude: Bool = true) throws -> AgentInstallPlan {
        try fixture.mkdir(".codex")
        try fixture.mkdir(".cursor")
        return fixture.installer(executables: claude ? ["claude": URL(filePath: "/fake/claude")] : [:]).plan(identity: try fixture.identity())
    }

    @Test func nothingWhenNeverSetUpEvenWithHostsDetected() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let plan = try plan(fixture)
        #expect(plan.hosts.count == 4)
        #expect(AgentSetupPolicy.decide(record: nil, plan: plan, fingerprint: "f") == .nothing)
    }

    @Test func nothingWhenRecordHasNoHosts() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        #expect(AgentSetupPolicy.decide(record: AgentSetupRecord(), plan: try plan(fixture), fingerprint: "f") == .nothing)
    }

    @Test func nothingWhenEveryFingerprintMatches() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        #expect(AgentSetupPolicy.decide(record: installedRecord([.codex: "f", .cursor: "f"]), plan: try plan(fixture), fingerprint: "f") == .nothing)
    }

    @Test func refreshRestrictedToAcceptedHosts() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        guard case let .refresh(restricted) = AgentSetupPolicy.decide(record: installedRecord([.codex: "old", .crossTool: "old"]), plan: try plan(fixture), fingerprint: "new") else {
            Issue.record("expected a refresh")
            return
        }
        #expect(restricted.hosts == [.codex, .crossTool])
        #expect(!restricted.actions.contains { if case .runClaude = $0 { true } else { false } })
    }

    @Test func refreshOnlyHostsWithStaleFingerprint() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        guard case let .refresh(restricted) = AgentSetupPolicy.decide(record: installedRecord([.codex: "old", .cursor: "new"]), plan: try plan(fixture), fingerprint: "new") else {
            Issue.record("expected a refresh")
            return
        }
        #expect(restricted.hosts == [.codex])
        #expect(restricted.actions.allSatisfy { $0.host == .codex })
    }

    @Test func recordedHostNoLongerDetectedIsSkipped() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let plan = fixture.installer().plan(identity: try fixture.identity())
        #expect(AgentSetupPolicy.decide(record: installedRecord([.codex: "old"]), plan: plan, fingerprint: "new") == .nothing)
    }
}

nonisolated struct AgentSetupRecordTests {
    @Test func recordingMergesHostsInsteadOfReplacing() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".cursor")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = installedRecord([.codex: "old"])
        let plan = fixture.installer().plan(identity: try fixture.identity()).restricted(to: [.cursor])
        let record = existing.recording(plan: plan, report: AgentInstallReport(entries: []), fingerprint: "new", at: date)
        #expect(record.installed(.codex) == existing.installed(.codex))
        #expect(record.installed(.cursor) == AgentSetupRecord.InstalledHost(fingerprint: "new", version: "1.5.0", updatedAt: date))
        #expect(record.installedHosts == [.codex, .cursor])
    }

    @Test func removingDropsOnlyThatHost() {
        let record = installedRecord([.codex: "a", .cursor: "b"]).removing([.codex])
        #expect(record.installedHosts == [.cursor])
        #expect(record.installed(.cursor)?.fingerprint == "b")
    }
}

nonisolated struct AgentSetupStatusTests {
    private func plan(_ fixture: AgentInstallFixture) throws -> AgentInstallPlan {
        try fixture.mkdir(".codex")
        return fixture.installer().plan(identity: try fixture.identity())
    }

    private func status(_ host: AgentHost, record: AgentSetupRecord? = nil) throws -> AgentHostStatus.State {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let statuses = AgentHostStatus.statuses(plan: try plan(fixture), record: record, fingerprint: "f")
        return try #require(statuses.first { $0.host == host }).state
    }

    @Test func undetectedUnrecordedHostIsNotFound() throws {
        #expect(try status(.cursor) == .notFound)
    }

    @Test func detectedHostIsNotInstalled() throws {
        #expect(try status(.codex) == .notInstalled)
        #expect(try status(.crossTool) == .notInstalled)
    }

    @Test func recordedHostWithMatchingFingerprintIsInstalledWithVersion() throws {
        #expect(try status(.codex, record: installedRecord([.codex: "f"])) == .installed(version: "1.4.0"))
    }

    @Test func recordedHostWithStaleFingerprintHasUpdate() throws {
        #expect(try status(.cursor, record: installedRecord([.cursor: "old"])) == .updateAvailable(version: "1.4.0"))
    }

    @Test func statusesAreInFixedHostOrder() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let statuses = AgentHostStatus.statuses(plan: try plan(fixture), record: nil, fingerprint: "f")
        #expect(statuses.map(\.host) == [.claudeCode, .codex, .cursor, .openCode, .crossTool])
        #expect(statuses.map(\.writes).allSatisfy { !$0.isEmpty })
    }
}

@MainActor
final class AgentSetupCoordinatorTests {
    private let testDefaults = TestDefaults()
    private let fixture: AgentInstallFixture
    private let runner: RecordingCommandRunner
    private nonisolated static let date = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        fixture = try AgentInstallFixture()
        runner = RecordingCommandRunner()
        try fixture.mkdir(".codex")
    }

    @MainActor deinit {
        testDefaults.tearDown()
        fixture.cleanUp()
    }

    private var store: AgentSetupRecordStore { AgentSetupRecordStore(defaults: testDefaults.defaults) }

    private func coordinator(runner: RecordingCommandRunner? = nil) throws -> AgentSetupCoordinator {
        let identity = try fixture.identity()
        let installer = fixture.installer(runner: runner ?? self.runner, executables: ["claude": URL(filePath: "/fake/claude")])
        return AgentSetupCoordinator(identity: { identity }, installer: { installer }, store: store, now: { Self.date })
    }

    private func fingerprint() throws -> String {
        try #require(AgentGuidanceFingerprint.make(identity: try fixture.identity()))
    }

    private func homeContents() -> [String] {
        (FileManager.default.enumerator(atPath: fixture.home.path(percentEncoded: false))?.allObjects as? [String] ?? []).sorted()
    }

    @Test func launchCheckWithNoRecordDoesNothing() async throws {
        let before = homeContents()
        #expect(try await coordinator().runLaunchCheck() == .nothing)
        #expect(homeContents() == before)
        #expect(runner.calls.isEmpty)
        #expect(store.load() == nil)
    }

    @Test func launchCheckRefreshesSilentlyWhenFingerprintDiffers() async throws {
        store.save(installedRecord([.codex: "old", .crossTool: "old"]))
        let decision = try await coordinator().runLaunchCheck()
        guard case .refresh = decision else { Issue.record("expected refresh, got \(decision)"); return }
        #expect(runner.calls.isEmpty)
        #expect(fixture.read(".agents/skills/batty-cli/SKILL.md") != nil)
        let record = try #require(store.load())
        for host in [AgentHost.codex, .crossTool] {
            #expect(record.installed(host) == AgentSetupRecord.InstalledHost(fingerprint: try fingerprint(), version: "1.5.0", updatedAt: Self.date))
        }
    }

    @Test func refreshNeverWritesGlobalInstructionFilesOrTheCLISymlink() async throws {
        store.save(installedRecord([.claudeCode: "old", .codex: "old", .crossTool: "old"]))
        try await coordinator().runLaunchCheck()
        #expect(runner.calls.allSatisfy { $0.first == "claude" })
        for name in ["CLAUDE.md", "AGENTS.md"] {
            #expect(!homeContents().contains { $0.hasSuffix(name) })
        }
        #expect(!homeContents().contains { $0.hasSuffix("bin/batty") })
    }

    @Test func refreshRunsClaudeOnlyWhenClaudeCodeAccepted() async throws {
        store.save(installedRecord([.claudeCode: "old"]))
        try await coordinator().runLaunchCheck()
        #expect(runner.calls.count == 2)
        #expect(runner.calls.allSatisfy { $0.first == "claude" })
    }

    @Test func refreshFailureIsRecordedNotRetried() async throws {
        store.save(installedRecord([.claudeCode: "old"]))
        let failing = RecordingCommandRunner { _, _ in 1 }
        let coordinator = try coordinator(runner: failing)
        await coordinator.runLaunchCheck()
        let record = try #require(store.load())
        #expect(!record.lastProblems.isEmpty)
        #expect(record.installed(.claudeCode)?.fingerprint == (try fingerprint()))
        #expect(await coordinator.runLaunchCheck() == .nothing)
    }

    @Test func recordStoreRoundTripsAndIgnoresGarbage() {
        let record = AgentSetupRecord(hosts: ["Codex": .init(fingerprint: "f", version: "1", updatedAt: Self.date)], lastProblems: ["x"])
        store.save(record)
        #expect(store.load() == record)
        testDefaults.defaults.set(Data("nope".utf8), forKey: AgentSetupRecordStore.key)
        #expect(store.load() == nil)
    }

    @Test func fingerprintChangesWithVersionPathOrSkill() throws {
        let identity = try fixture.identity()
        let base = try #require(AgentGuidanceFingerprint.make(identity: identity))
        let versioned = AgentGuidanceIdentity(isBeta: false, cliExecutablePath: identity.cliExecutablePath, version: "9.9.9", guidanceRoot: identity.guidanceRoot)
        let moved = AgentGuidanceIdentity(isBeta: false, cliExecutablePath: "/elsewhere/batty", version: identity.version, guidanceRoot: identity.guidanceRoot)
        #expect(AgentGuidanceFingerprint.make(identity: versioned) != base)
        #expect(AgentGuidanceFingerprint.make(identity: moved) != base)
        try Data("changed".utf8).write(to: identity.skillSourceDirectory.appending(path: "SKILL.md"))
        #expect(AgentGuidanceFingerprint.make(identity: identity) != base)
    }
}

@MainActor
final class AgentIntegrationModelSetupTests {
    private let testDefaults = TestDefaults()
    private let fixture: AgentInstallFixture
    private let runner = RecordingCommandRunner()
    private nonisolated static let date = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        fixture = try AgentInstallFixture()
        try fixture.mkdir(".codex")
        try fixture.mkdir(".cursor")
    }

    @MainActor deinit {
        testDefaults.tearDown()
        fixture.cleanUp()
    }

    private var store: AgentSetupRecordStore { AgentSetupRecordStore(defaults: testDefaults.defaults) }

    private func model() throws -> AgentIntegrationModel {
        let identity = try fixture.identity()
        let installer = fixture.installer(runner: runner, executables: ["claude": URL(filePath: "/fake/claude")])
        return AgentIntegrationModel(identity: { identity }, installer: { installer }, recordStore: store, now: { Self.date })
    }

    private func homeContents() -> [String] {
        (FileManager.default.enumerator(atPath: fixture.home.path(percentEncoded: false))?.allObjects as? [String] ?? []).sorted()
    }

    private func install(_ model: AgentIntegrationModel, _ hosts: Set<AgentHost>) async {
        model.selectedHosts = hosts
        await model.beginInstall(hosts: model.selectedHosts)
        await model.confirmInstall()
    }

    @Test func installsOnlyCheckedHosts() async throws {
        let none = try model()
        await none.beginInstall(hosts: [])
        #expect(none.state == .idle)
        #expect(store.load() == nil)

        let one = try model()
        await install(one, [.codex])
        #expect(store.load()?.installedHosts == [.codex])
        #expect(fixture.read(".codex/config.toml") != nil)
        #expect(fixture.read(".cursor/mcp.json") == nil)
        #expect(fixture.read(".agents/skills/batty-cli/SKILL.md") == nil)
        #expect(runner.calls.isEmpty)
        #expect(one.selectedHosts.isEmpty)

        let two = try model()
        await install(two, [.cursor, .crossTool])
        #expect(store.load()?.installedHosts == [.codex, .cursor, .crossTool])
        #expect(fixture.read(".cursor/mcp.json") != nil)
        #expect(fixture.read(".agents/skills/batty-cli/SKILL.md") != nil)
        #expect(runner.calls.isEmpty)
    }

    @Test func updateRestrictsToThatHost() async throws {
        store.save(installedRecord([.codex: "old", .cursor: "old"]))
        let model = try model()
        await model.beginInstall(hosts: [.codex])
        guard case let .previewing(plan) = model.state else { Issue.record("expected a preview"); return }
        #expect(plan.hosts == [.codex])
        await model.confirmInstall()
        #expect(store.load()?.installed(.cursor)?.fingerprint == "old")
        #expect(store.load()?.installed(.codex)?.fingerprint != "old")
    }

    @Test func removeUndoesOnlyThatHostAndForgetsIt() async throws {
        let model = try model()
        await install(model, [.codex, .cursor])
        let cursorConfig = fixture.home.appending(path: ".cursor/mcp.json")
        var cursor = try fixture.json(".cursor/mcp.json")
        var servers = try #require(cursor["mcpServers"] as? [String: Any])
        servers["other"] = ["command": "/bin/other"]
        cursor["mcpServers"] = servers
        try JSONSerialization.data(withJSONObject: cursor).write(to: cursorConfig)
        let codexConfig = fixture.home.appending(path: ".codex/config.toml")
        let codexText = try #require(fixture.read(".codex/config.toml"))
        try Data(("[profile]\nmodel = \"x\"\n\n" + codexText).utf8).write(to: codexConfig)

        await model.beginRemove(host: .cursor)
        guard case .previewingRemoval = model.state else { Issue.record("expected a removal preview"); return }
        await model.confirmRemove()
        let remaining = try #require(try fixture.json(".cursor/mcp.json")["mcpServers"] as? [String: Any])
        #expect(remaining.keys.sorted() == ["other"])
        #expect(fixture.read(".cursor/skills/batty-cli/SKILL.md") == nil)
        #expect(fixture.read(".codex/skills/batty-cli/SKILL.md") != nil)
        #expect(store.load()?.installedHosts == [.codex])

        await model.beginRemove(host: .codex)
        await model.confirmRemove()
        #expect(fixture.read(".codex/config.toml") == "[profile]\nmodel = \"x\"\n")
        #expect(fixture.read(".codex/skills/batty-cli/SKILL.md") == nil)
        #expect(homeContents().contains { $0.contains("AgentGuidanceBackups") && $0.hasSuffix("codex/batty-cli/SKILL.md") })
        #expect(store.load()?.installedHosts == [])
        #expect(runner.calls.isEmpty)
    }

    @Test func removeLeavesUnrelatedConfigWhenBlockMissing() async throws {
        let codexConfig = fixture.home.appending(path: ".codex/config.toml")
        try Data("[profile]\nmodel = \"x\"\n".utf8).write(to: codexConfig)
        let model = try model()
        await model.beginRemove(host: .codex)
        await model.confirmRemove()
        guard case let .finished(report) = model.state else { Issue.record("expected a report"); return }
        #expect(report.entries.allSatisfy { $0.outcome == .unchanged })
        #expect(fixture.read(".codex/config.toml") == "[profile]\nmodel = \"x\"\n")
    }

    @Test func loadStatusReadsNothingBeyondDetection() async throws {
        let before = homeContents()
        let model = try model()
        await model.loadStatus()
        #expect(model.statuses.count == 5)
        #expect(model.setupNote == nil)
        #expect(runner.calls.isEmpty)
        #expect(homeContents() == before)
    }

    @Test func setupNoteShowsLastProblems() async throws {
        store.save(AgentSetupRecord(hosts: [:], lastProblems: ["  FAILED: boom"]))
        let model = try model()
        await model.loadStatus()
        #expect(model.setupNote == "  FAILED: boom")
    }
}
