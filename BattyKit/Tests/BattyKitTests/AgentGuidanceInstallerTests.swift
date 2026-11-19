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
        try fixture.mkdir(".codex")
        let runner = RecordingCommandRunner()
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.home.path(percentEncoded: false))
        let plan = fixture.installer(runner: runner, executables: ["claude": claude]).plan(identity: try fixture.identity())
        #expect(plan.hosts == [.claudeCode, .cursor, .codex, .crossTool])
        #expect(plan.render().contains(".cursor/skills/batty-cli"))
        #expect(plan.render().contains(".codex/config.toml"))
        #expect(runner.calls.isEmpty)
        #expect(fixture.read(".codex/config.toml") == nil)
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

    private func backups(_ fixture: AgentInstallFixture) -> [String] {
        let dir = fixture.home.appending(path: "Library/Application Support/Batty/AgentGuidanceBackups")
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
    }

    private func codexConfig(_ fixture: AgentInstallFixture) -> URL {
        fixture.home.appending(path: ".codex/config.toml")
    }

    private func configBytes(_ fixture: AgentInstallFixture) -> [UInt8]? {
        (try? Data(contentsOf: codexConfig(fixture))).map { Array($0) }
    }

    private func backupURL(_ fixture: AgentInstallFixture) -> URL {
        fixture.home.appending(path: "Library/Application Support/Batty/AgentGuidanceBackups/\(backups(fixture).first ?? "")/codex/config.toml")
    }

    private func outcome(_ report: AgentInstallReport) -> AgentInstallOutcome? {
        report.entries.first { if case .writeCodexMCPBlock = $0.action { true } else { false } }?.outcome
    }

    private static let codexFixture = "# top comment\nmodel = \"o3\"\n\n[mcp_servers.other]\ncommand = \"x\"  # keep\n\n[profiles.x]\nk = 1\n"

    @Test func codexBlockIsAppendedKeepingOtherTablesByteForByte() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".codex")
        try Data(Self.codexFixture.utf8).write(to: codexConfig(fixture))
        let installer = fixture.installer()
        let identity = try fixture.identity()
        let report = installer.apply(installer.plan(identity: identity))
        guard case .done? = outcome(report) else { Issue.record("expected done"); return }
        #expect(configBytes(fixture) == Array((Self.codexFixture + "\n" + CodexConfigBlock.block(identity: identity)).utf8))
        #expect(backups(fixture).count == 1)
        #expect(try Data(contentsOf: backupURL(fixture)) == Data(Self.codexFixture.utf8))
    }

    @Test func codexRerunReplacesOnlyItsMarkedBlock() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".codex")
        try Data(Self.codexFixture.utf8).write(to: codexConfig(fixture))
        let installer = fixture.installer()
        let identity = try fixture.identity()
        _ = installer.apply(installer.plan(identity: identity))
        let tail = "\n[profiles.after]\nk = 2\n"
        let edited = try #require(fixture.read(".codex/config.toml"))
            .replacingOccurrences(of: identity.cliExecutablePath, with: "/hand/edited") + tail
        try Data(edited.utf8).write(to: codexConfig(fixture))
        _ = installer.apply(installer.plan(identity: identity))
        #expect(configBytes(fixture) == Array((Self.codexFixture + "\n" + CodexConfigBlock.block(identity: identity) + tail).utf8))
    }

    @Test func codexRerunWithCurrentBlockIsUnchanged() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".codex")
        try Data(Self.codexFixture.utf8).write(to: codexConfig(fixture))
        let installer = fixture.installer()
        let identity = try fixture.identity()
        _ = installer.apply(installer.plan(identity: identity))
        let first = configBytes(fixture)
        let backupsBefore = backups(fixture)
        try FileManager.default.removeItem(at: fixture.home.appending(path: "Library/Application Support/Batty/AgentGuidanceBackups"))
        let report = installer.apply(installer.plan(identity: identity))
        #expect(outcome(report) == .unchanged)
        #expect(backupsBefore.count == 1)
        #expect(backups(fixture).isEmpty)
        #expect(configBytes(fixture) == first)
    }

    @Test func codexUnmarkedTableOfSameNameIsManualAndUntouched() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".codex")
        let original = "[mcp_servers.batty]\ncommand = \"mine\"\n"
        try Data(original.utf8).write(to: codexConfig(fixture))
        let installer = fixture.installer()
        let report = installer.apply(installer.plan(identity: try fixture.identity()))
        guard case let .manual(text)? = outcome(report) else { Issue.record("expected manual"); return }
        #expect(text.contains("[mcp_servers.batty]"))
        #expect(configBytes(fixture) == Array(original.utf8))
        #expect(backups(fixture).isEmpty)
    }

    @Test func codexMissingConfigIsCreated() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".codex")
        let installer = fixture.installer()
        let identity = try fixture.identity()
        let report = installer.apply(installer.plan(identity: identity))
        #expect(outcome(report) == .done(""))
        #expect(configBytes(fixture) == Array(CodexConfigBlock.block(identity: identity).utf8))
        #expect(backups(fixture).isEmpty)
    }

    @Test func codexConfigHonoursCODEX_HOME() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let codexHome = fixture.root.appending(path: "codexhome", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let installer = fixture.installer(environment: ["CODEX_HOME": codexHome.path(percentEncoded: false)])
        _ = installer.apply(installer.plan(identity: try fixture.identity()))
        #expect(FileManager.default.fileExists(atPath: codexHome.appending(path: "config.toml").path(percentEncoded: false)))
        #expect(fixture.read(".codex/config.toml") == nil)
    }

    @Test func codexConfigPermissionsArePreserved() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".codex")
        let path = codexConfig(fixture).path(percentEncoded: false)
        try Data(Self.codexFixture.utf8).write(to: codexConfig(fixture))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let installer = fixture.installer()
        _ = installer.apply(installer.plan(identity: try fixture.identity()))
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let backupPermissions = try FileManager.default.attributesOfItem(atPath: backupURL(fixture).path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(backupPermissions == 0o600)
    }

    @Test func codexCRLFRerunReplacesTheBlockWithoutADuplicateTable() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".codex")
        let original = Self.codexFixture.replacingOccurrences(of: "\n", with: "\r\n")
        try Data(original.utf8).write(to: codexConfig(fixture))
        let installer = fixture.installer()
        let identity = try fixture.identity()
        _ = installer.apply(installer.plan(identity: identity))
        let crlfBlock = CodexConfigBlock.block(identity: identity, lineEnding: "\r\n")
        #expect(configBytes(fixture) == Array((original + "\r\n" + crlfBlock).utf8))
        let tail = "\r\n[profiles.after]\r\nk = 2\r\n"
        let edited = String(decoding: try #require(configBytes(fixture)), as: UTF8.self)
            .replacingOccurrences(of: identity.cliExecutablePath, with: "/hand/edited") + tail
        try Data(edited.utf8).write(to: codexConfig(fixture))
        let report = installer.apply(installer.plan(identity: identity))
        guard case .done? = outcome(report) else { Issue.record("expected done, got \(String(describing: outcome(report)))"); return }
        let result = String(decoding: try #require(configBytes(fixture)), as: UTF8.self)
        #expect(configBytes(fixture) == Array((original + "\r\n" + crlfBlock + tail).utf8))
        #expect(result.components(separatedBy: "[mcp_servers.batty]").count == 2)
        #expect(outcome(installer.apply(installer.plan(identity: identity))) == .unchanged)
    }

    @Test func codexCRLFUnmarkedTableOfSameNameIsManualAndUntouched() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".codex")
        let original = "a = 1\r\n[mcp_servers.batty]\r\ncommand = \"mine\"\r\n"
        try Data(original.utf8).write(to: codexConfig(fixture))
        let installer = fixture.installer()
        let report = installer.apply(installer.plan(identity: try fixture.identity()))
        guard case .manual? = outcome(report) else { Issue.record("expected manual"); return }
        #expect(configBytes(fixture) == Array(original.utf8))
        #expect(backups(fixture).isEmpty)
    }

    @Test func codexBOMIsPreserved() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".codex")
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let original = bom + Array(Self.codexFixture.utf8)
        try Data(original).write(to: codexConfig(fixture))
        let installer = fixture.installer()
        let identity = try fixture.identity()
        _ = installer.apply(installer.plan(identity: identity))
        #expect(configBytes(fixture) == original + Array(("\n" + CodexConfigBlock.block(identity: identity)).utf8))
        #expect(try Data(contentsOf: backupURL(fixture)) == Data(original))
        #expect(outcome(installer.apply(installer.plan(identity: identity))) == .unchanged)
        #expect(configBytes(fixture) == original + Array(("\n" + CodexConfigBlock.block(identity: identity)).utf8))
    }

    @Test func codexConfigSymlinkIsKept() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".codex")
        let target = fixture.root.appending(path: "dotfiles/config.toml")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.codexFixture.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: codexConfig(fixture), withDestinationURL: target)
        let installer = fixture.installer()
        let identity = try fixture.identity()
        _ = installer.apply(installer.plan(identity: identity))
        let type = try FileManager.default.attributesOfItem(atPath: codexConfig(fixture).path(percentEncoded: false))[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
        #expect(try Data(contentsOf: target) == Data((Self.codexFixture + "\n" + CodexConfigBlock.block(identity: identity)).utf8))
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
        try fixture.mkdir(".codex")
        let installer = fixture.installer(executables: ["claude": claude])
        _ = installer.apply(installer.plan(identity: try fixture.identity(beta: false)))
        _ = installer.apply(installer.plan(identity: try fixture.identity(beta: true)))
        #expect(fixture.read(".agents/skills/batty-cli/SKILL.md") != nil)
        #expect(fixture.read(".agents/skills/batty-beta-cli/SKILL.md") != nil)
        #expect(fixture.read("Library/Application Support/Batty/AgentPlugin/.claude-plugin/marketplace.json") != nil)
        #expect(fixture.read("Library/Application Support/Batty Beta/AgentPlugin/.claude-plugin/marketplace.json") != nil)
        let servers = try #require(try fixture.json(".cursor/mcp.json")["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["batty", "batty-beta"])
        let codex = try #require(fixture.read(".codex/config.toml"))
        #expect(codex.components(separatedBy: "# batty:begin").count == 2)
        #expect(codex.components(separatedBy: "# batty-beta:begin").count == 2)
    }
}
