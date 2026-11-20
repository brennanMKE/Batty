// AgentMCPConfigSnippetsTests.swift

import Foundation
import Testing
@testable import BattyCLICore

nonisolated struct AgentMCPConfigSnippetsTests {
    @Test func claudeMCPAddCommandForBareName() {
        #expect(AgentMCPConfigSnippets.claudeMCPAddCommand(key: "batty", command: "batty") == "claude mcp add --scope user batty -- batty mcp")
    }

    @Test func claudeMCPAddCommandQuotesAPathWithSpaces() {
        let path = "/Applications/Batty Beta.app/Contents/Resources/bin/batty"
        #expect(AgentMCPConfigSnippets.claudeMCPAddCommand(key: "batty-beta", command: path) == "claude mcp add --scope user batty-beta -- '\(path)' mcp")
    }

    @Test func codexSnippetForwardsAllThreeBattyVariables() throws {
        let codex = try #require(try AgentMCPConfigSnippets.siteFiles().first { $0.name == "codex-config.toml" })
        let list = CodexConfigBlock.forwardedVariables.map { "\"\($0)\"" }.joined(separator: ", ")
        #expect(list == "\"BATTY_SESSION_ID\", \"BATTY_TAB_ID\", \"BATTY_PANE_ID\"")
        #expect(codex.contents.contains("env_vars = [\(list)]"))
    }

    @Test func siteFilesUseTheBareCommandNeverAnAppPath() throws {
        for file in try AgentMCPConfigSnippets.siteFiles() {
            #expect(file.contents.contains("batty"), "\(file.name)")
            #expect(!file.contents.contains(".app/"), "\(file.name)")
            #expect(!file.contents.contains("Contents/Resources"), "\(file.name)")
        }
    }

    @Test func siteFilesEndWithOneNewline() throws {
        for file in try AgentMCPConfigSnippets.siteFiles() {
            #expect(file.contents.hasSuffix("\n") && !file.contents.hasSuffix("\n\n"), "\(file.name)")
        }
    }

    @Test func cursorDocumentMatchesInstallerFreshWrite() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".cursor")
        let identity = try fixture.identity()
        let installer = fixture.installer()
        _ = installer.apply(installer.plan(identity: identity))
        let written = try Data(contentsOf: fixture.home.appending(path: ".cursor/mcp.json"))
        let expected = try AgentMCPConfigSnippets.configDocument(keyPath: ["mcpServers", "batty"], entry: AgentMCPConfigSnippets.mcpServersEntry(command: identity.cliExecutablePath))
        #expect(written == expected)
    }

    @Test func openCodeDocumentMatchesInstallerFreshWrite() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".config/opencode")
        let identity = try fixture.identity()
        let installer = fixture.installer()
        _ = installer.apply(installer.plan(identity: identity))
        let written = try Data(contentsOf: fixture.home.appending(path: ".config/opencode/opencode.json"))
        let expected = try AgentMCPConfigSnippets.configDocument(keyPath: ["mcp", "batty"], entry: AgentMCPConfigSnippets.openCodeEntry(command: identity.cliExecutablePath))
        #expect(written == expected)
    }

    @Test func codexDocumentMatchesInstallerFreshWrite() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".codex")
        let identity = try fixture.identity()
        let installer = fixture.installer()
        _ = installer.apply(installer.plan(identity: identity))
        let written = try String(contentsOf: fixture.home.appending(path: ".codex/config.toml"), encoding: .utf8)
        #expect(written == AgentMCPConfigSnippets.codexBlock(key: identity.pluginName, cliCommandName: identity.cliCommandName, command: identity.cliExecutablePath))
    }

    @Test func claudePluginMCPJSONUsesTheSharedEntry() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        try fixture.mkdir(".claude")
        let identity = try fixture.identity()
        let installer = fixture.installer()
        _ = installer.apply(installer.plan(identity: identity))
        let mcp = try fixture.json("Library/Application Support/Batty/AgentPlugin/batty/.mcp.json")
        let server = try #require((mcp["mcpServers"] as? [String: Any])?["batty"] as? NSDictionary)
        let expected = AgentMCPConfigSnippets.mcpServersEntry(command: identity.cliExecutablePath).foundation as? NSDictionary
        #expect(server == expected)
    }
}
