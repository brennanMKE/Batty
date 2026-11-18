// AgentGuidanceInstallerTests.swift

import BattyCLICore
import Foundation
import os
import Testing

nonisolated final class RecordingCommandRunner: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[[String]]>(initialState: [])
    let status: (URL, [String]) -> Int32

    init(status: @escaping (URL, [String]) -> Int32 = { _, _ in 0 }) {
        self.status = status
    }

    var calls: [[String]] { lock.withLock { $0 } }

    var runner: AgentGuidanceInstaller.CommandRunner {
        { [self] executable, arguments in
            lock.withLock { $0.append([executable.lastPathComponent] + arguments) }
            return AgentCommandResult(status: status(executable, arguments), stdout: "", stderr: "boom")
        }
    }
}

/// A fake home and a fake app bundle carrying the bundled skill.
nonisolated struct AgentInstallFixture {
    let root: URL
    let home: URL
    let fileManager = FileManager.default
    static let skill = "---\nname: batty-cli\ndescription: Drive Batty.\n---\n\n# Batty CLI\n"

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "batty-0647-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func identity(beta: Bool = false) throws -> AgentGuidanceIdentity {
        let app = root.appending(path: beta ? "Batty Beta.app" : "Batty.app", directoryHint: .isDirectory)
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        let skillDirectory = contents.appending(path: "Resources/AgentGuidance/skills/batty-cli", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try Data(Self.skill.utf8).write(to: skillDirectory.appending(path: "SKILL.md"))
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.5.0"], format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        try fileManager.createDirectory(at: contents.appending(path: "Resources/bin"), withIntermediateDirectories: true)
        let cli = contents.appending(path: "Resources/bin/batty")
        fileManager.createFile(atPath: cli.path(percentEncoded: false), contents: Data())
        return try #require(AgentGuidanceIdentity.fromBundledCLI(executableURL: cli, isBeta: beta))
    }

    func mkdir(_ path: String) throws {
        try fileManager.createDirectory(at: home.appending(path: path, directoryHint: .isDirectory), withIntermediateDirectories: true)
    }

    func installer(
        runner: RecordingCommandRunner = RecordingCommandRunner(),
        environment: [String: String] = [:],
        executables: [String: URL] = [:]
    ) -> AgentGuidanceInstaller {
        AgentGuidanceInstaller(
            homeDirectory: home,
            environment: environment,
            commandRunner: runner.runner,
            executableLookup: { executables[$0] }
        )
    }

    func read(_ path: String) -> String? {
        try? String(contentsOf: home.appending(path: path), encoding: .utf8)
    }

    func json(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: home.appending(path: path))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func cleanUp() {
        try? fileManager.removeItem(at: root)
    }
}

nonisolated struct AgentGuidanceInstallerTests {
    private let claude = URL(filePath: "/fake/bin/claude")

    private func skillCopies(_ plan: AgentInstallPlan) -> [AgentHost] {
        plan.actions.compactMap { if case let .copySkill(host, _) = $0 { host } else { nil } }
    }

    @Test func dryRunPlanListsEveryDetectedHostAndWritesNothing() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".cursor")
        let runner = RecordingCommandRunner()
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.home.path(percentEncoded: false))
        let plan = fixture.installer(runner: runner, executables: ["claude": claude]).plan(identity: try fixture.identity())
        #expect(plan.hosts == [.claudeCode, .cursor, .crossTool])
        #expect(plan.render().contains(".cursor/skills/batty-cli"))
        #expect(runner.calls.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path(percentEncoded: false)) == before)
    }

    @Test func detectsHostsFromHomeDirectoriesAndEnvironment() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".claude")
        try fixture.mkdir(".cursor")
        try fixture.mkdir("xdg/opencode")
        try fixture.mkdir("codexhome")
        let environment = [
            "XDG_CONFIG_HOME": fixture.home.appending(path: "xdg").path(percentEncoded: false),
            "CODEX_HOME": fixture.home.appending(path: "codexhome").path(percentEncoded: false),
        ]
        let plan = fixture.installer(environment: environment).plan(identity: try fixture.identity())
        #expect(plan.hosts == [.claudeCode, .openCode, .cursor, .codex, .crossTool])
        #expect(plan.actions.contains(.copySkill(host: .codex, destination: fixture.home.appending(path: "codexhome/skills/batty-cli", directoryHint: .isDirectory))))
        #expect(plan.actions.contains(.copySkill(host: .openCode, destination: fixture.home.appending(path: "xdg/opencode/skills/batty-cli", directoryHint: .isDirectory))))
    }

    @Test(arguments: [false, true])
    func stagedMarketplaceUsesVariantNames(beta: Bool) throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let installer = fixture.installer(executables: ["claude": claude])
        let identity = try fixture.identity(beta: beta)
        _ = installer.apply(installer.plan(identity: identity))
        let support = beta ? "Library/Application Support/Batty Beta/AgentPlugin" : "Library/Application Support/Batty/AgentPlugin"
        let marketplace = try fixture.json("\(support)/.claude-plugin/marketplace.json")
        #expect(marketplace["name"] as? String == (beta ? "batty-beta-local" : "batty-local"))
        let plugin = beta ? "batty-beta" : "batty"
        let manifest = try fixture.json("\(support)/\(plugin)/.claude-plugin/plugin.json")
        #expect(manifest["name"] as? String == plugin)
        #expect(fixture.read("\(support)/\(plugin)/skills/batty-cli/SKILL.md") == AgentInstallFixture.skill)
    }

    @Test func pluginMCPEntryRunsTheBundledCLIWithMcp() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let installer = fixture.installer(executables: ["claude": claude])
        let identity = try fixture.identity()
        _ = installer.apply(installer.plan(identity: identity))
        let mcp = try fixture.json("Library/Application Support/Batty/AgentPlugin/batty/.mcp.json")
        let server = try #require((mcp["mcpServers"] as? [String: Any])?["batty"] as? [String: Any])
        #expect(server["command"] as? String == identity.cliExecutablePath)
        #expect(identity.cliExecutablePath.hasSuffix("Batty.app/Contents/Resources/bin/batty"))
        #expect(server["args"] as? [String] == ["mcp"])
    }

    @Test func pluginVersionIsTheCLIVersion() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let installer = fixture.installer(executables: ["claude": claude])
        _ = installer.apply(installer.plan(identity: try fixture.identity()))
        let manifest = try fixture.json("Library/Application Support/Batty/AgentPlugin/batty/.claude-plugin/plugin.json")
        #expect(manifest["version"] as? String == "1.5.0")
    }

    @Test func claudeCodeInstallRunsMarketplaceAddThenPluginInstall() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let runner = RecordingCommandRunner()
        let installer = fixture.installer(runner: runner, executables: ["claude": claude])
        let report = installer.apply(installer.plan(identity: try fixture.identity()))
        let marketplace = installer.marketplaceDirectory(for: try fixture.identity()).path(percentEncoded: false)
        #expect(runner.calls == [
            ["claude", "plugin", "marketplace", "add", marketplace],
            ["claude", "plugin", "install", "batty@batty-local"],
        ])
        #expect(!report.hasFailures)
    }

    @Test func claudeCodeRerunUpdatesInPlace() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let runner = RecordingCommandRunner()
        let installer = fixture.installer(runner: runner, executables: ["claude": claude])
        let identity = try fixture.identity()
        _ = installer.apply(installer.plan(identity: identity))
        let second = installer.apply(installer.plan(identity: identity))
        #expect(!second.hasFailures)
        // Both claude commands are idempotent (checked against claude 2.x), so a re-run repeats them.
        #expect(runner.calls.count == 4)
        #expect(Array(runner.calls[2...]) == Array(runner.calls[..<2]))
        #expect(second.entries.contains { $0.outcome == .unchanged })
    }

    @Test func missingClaudeBinaryStagesAndPrintsTheCommands() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".claude")
        let runner = RecordingCommandRunner()
        let installer = fixture.installer(runner: runner)
        let plan = installer.plan(identity: try fixture.identity())
        let printed = plan.actions.compactMap { if case let .printClaudeCommands(commands) = $0 { commands } else { nil } }.first
        #expect(printed?.count == 2)
        #expect(printed?.last == "claude plugin install batty@batty-local")
        _ = installer.apply(plan)
        #expect(runner.calls.isEmpty)
        #expect(fixture.read("Library/Application Support/Batty/AgentPlugin/.claude-plugin/marketplace.json") != nil)
    }

    @Test func claudeIsFoundOutsidePATH() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".local/bin")
        let claude = fixture.home.appending(path: ".local/bin/claude")
        FileManager.default.createFile(atPath: claude.path(percentEncoded: false), contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let lookup = AgentGuidanceInstaller.pathLookup(homeDirectory: fixture.home, environment: ["PATH": "/nonexistent"])
        #expect(lookup("claude")?.standardizedFileURL == claude.standardizedFileURL)
    }

    @Test func skillCopyReplacesADifferentCopyAndBacksItUpOutsideTheSkillsRoot() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".agents/skills/batty-cli")
        try Data("old".utf8).write(to: fixture.home.appending(path: ".agents/skills/batty-cli/SKILL.md"))
        let installer = fixture.installer()
        let report = installer.apply(installer.plan(identity: try fixture.identity()))
        #expect(!report.hasFailures)
        #expect(fixture.read(".agents/skills/batty-cli/SKILL.md") == AgentInstallFixture.skill)
        let skillsRoot = try FileManager.default.contentsOfDirectory(atPath: fixture.home.appending(path: ".agents/skills").path(percentEncoded: false))
        #expect(skillsRoot == ["batty-cli"])
        let backups = fixture.home.appending(path: "Library/Application Support/Batty/AgentGuidanceBackups")
        let stamps = try FileManager.default.contentsOfDirectory(atPath: backups.path(percentEncoded: false))
        let stamp = try #require(stamps.first)
        #expect(fixture.read("Library/Application Support/Batty/AgentGuidanceBackups/\(stamp)/agents/batty-cli/SKILL.md") == "old")
    }

    @Test func identicalSkillIsNotRewritten() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let installer = fixture.installer()
        let identity = try fixture.identity()
        _ = installer.apply(installer.plan(identity: identity))
        let second = installer.apply(installer.plan(identity: identity))
        #expect(second.entries.map(\.outcome) == [.unchanged])
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appending(path: "Library/Application Support/Batty/AgentGuidanceBackups").path(percentEncoded: false)))
    }

    @Test func betaSkillDirectoryAndFrontmatterNameAreRenamed() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let installer = fixture.installer()
        _ = installer.apply(installer.plan(identity: try fixture.identity(beta: true)))
        let text = try #require(fixture.read(".agents/skills/batty-beta-cli/SKILL.md"))
        #expect(text.contains("\nname: batty-beta-cli\n"))
        #expect(!text.contains("\nname: batty-cli\n"))
    }

    @Test func cursorMCPEntryIsMergedKeepingOtherServers() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".cursor")
        try Data(#"{"mcpServers":{"other":{"command":"x"}},"theme":"dark","temperature":0.2}"#.utf8).write(to: fixture.home.appending(path: ".cursor/mcp.json"))
        let installer = fixture.installer()
        let identity = try fixture.identity()
        _ = installer.apply(installer.plan(identity: identity))
        let config = try fixture.json(".cursor/mcp.json")
        let servers = try #require(config["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil)
        #expect((servers["batty"] as? [String: Any])?["command"] as? String == identity.cliExecutablePath)
        #expect(config["theme"] as? String == "dark")
        let raw = try #require(fixture.read(".cursor/mcp.json"))
        #expect(raw.contains("0.2"))
        #expect(!raw.contains("0.200"))
        let backups = fixture.home.appending(path: "Library/Application Support/Batty/AgentGuidanceBackups")
        let stamp = try #require(try FileManager.default.contentsOfDirectory(atPath: backups.path(percentEncoded: false)).first)
        #expect(fixture.read("Library/Application Support/Batty/AgentGuidanceBackups/\(stamp)/cursor/mcp.json")?.contains("\"other\"") == true)
    }

    @Test func openCodeConfigThatIsNotStrictJSONIsLeftAloneAndReported() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".config/opencode")
        let jsonc = "{\n  // my settings\n  \"mcp\": {}\n}\n"
        try Data(jsonc.utf8).write(to: fixture.home.appending(path: ".config/opencode/opencode.json"))
        let installer = fixture.installer()
        let report = installer.apply(installer.plan(identity: try fixture.identity()))
        #expect(fixture.read(".config/opencode/opencode.json") == jsonc)
        let outcome = report.entries.first { if case .mergeMCPEntry(.openCode, _, _, _) = $0.action { true } else { false } }?.outcome
        guard case let .manual(text)? = outcome else {
            Issue.record("expected a manual outcome, got \(String(describing: outcome))")
            return
        }
        #expect(text.contains("\"batty\""))
    }

    @Test func codexMCPEntryIsPrintedNotWritten() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".codex")
        let installer = fixture.installer()
        let identity = try fixture.identity()
        let plan = installer.plan(identity: identity)
        let printed = plan.actions.compactMap { if case let .printMCPEntry(.codex, text) = $0 { text } else { nil } }.first
        #expect(printed?.contains("[mcp_servers.batty]") == true)
        #expect(printed?.contains(identity.cliExecutablePath) == true)
        _ = installer.apply(plan)
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appending(path: ".codex/config.toml").path(percentEncoded: false)))
    }

    @Test func oneFailedDestinationDoesNotAbortTheRest() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let runner = RecordingCommandRunner { _, arguments in arguments.contains("marketplace") ? 1 : 0 }
        let installer = fixture.installer(runner: runner, executables: ["claude": claude])
        let report = installer.apply(installer.plan(identity: try fixture.identity()))
        #expect(report.hasFailures)
        #expect(runner.calls.count == 2)
        #expect(fixture.read(".agents/skills/batty-cli/SKILL.md") == AgentInstallFixture.skill)
    }

    @Test func prodAndBetaInstallsDoNotCollide() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".cursor")
        let installer = fixture.installer(executables: ["claude": claude])
        _ = installer.apply(installer.plan(identity: try fixture.identity(beta: false)))
        _ = installer.apply(installer.plan(identity: try fixture.identity(beta: true)))
        #expect(fixture.read(".agents/skills/batty-cli/SKILL.md") != nil)
        #expect(fixture.read(".agents/skills/batty-beta-cli/SKILL.md") != nil)
        #expect(fixture.read("Library/Application Support/Batty/AgentPlugin/.claude-plugin/marketplace.json") != nil)
        #expect(fixture.read("Library/Application Support/Batty Beta/AgentPlugin/.claude-plugin/marketplace.json") != nil)
        let servers = try #require(try fixture.json(".cursor/mcp.json")["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["batty", "batty-beta"])
    }
}
