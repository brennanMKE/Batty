// AgentPluginTreeTests.swift

import BattyCLICore
import Foundation
import Testing

nonisolated struct AgentPluginTreeTests {
    private let claude = URL(filePath: "/fake/bin/claude")
    private static let pluginFiles = [".claude-plugin/plugin.json", ".mcp.json", "hooks/hooks.json", "skills/batty-cli/SKILL.md"]

    private func stage(_ fixture: AgentInstallFixture, beta: Bool) throws -> (AgentGuidanceIdentity, URL) {
        let installer = fixture.installer(executables: ["claude": claude])
        let identity = try fixture.identity(beta: beta)
        _ = installer.apply(installer.plan(identity: identity))
        return (identity, installer.marketplaceDirectory(for: identity))
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func publicFile(_ path: String) throws -> String {
        let files = try AgentPluginTree.publicFiles(version: "1.5.0", skill: Data(AgentInstallFixture.skill.utf8))
        return String(decoding: try #require(files.first { $0.path == path }).data, as: UTF8.self)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test(arguments: [false, true])
    func stagedMarketplaceFilesMatchPinnedBytes(beta: Bool) throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let (identity, root) = try stage(fixture, beta: beta)
        let plugin = beta ? "batty-beta" : "batty"
        let cli = identity.cliExecutablePath
        let description = "Drive the Batty terminal multiplexer: the batty-cli skill and the `\(plugin) mcp` server."
        #expect(try text(root.appending(path: ".claude-plugin/marketplace.json")) == """
        {
          "description" : "Batty's agent guidance, staged from \(plugin) 1.5.0.",
          "name" : "\(plugin)-local",
          "owner" : {
            "name" : "Batty"
          },
          "plugins" : [
            {
              "description" : "\(description)",
              "name" : "\(plugin)",
              "source" : "./\(plugin)",
              "version" : "1.5.0"
            }
          ]
        }

        """)
        #expect(try text(root.appending(path: "\(plugin)/.claude-plugin/plugin.json")) == """
        {
          "author" : {
            "name" : "Batty"
          },
          "description" : "\(description)",
          "name" : "\(plugin)",
          "version" : "1.5.0"
        }

        """)
        #expect(try text(root.appending(path: "\(plugin)/.mcp.json")) == """
        {
          "mcpServers" : {
            "\(plugin)" : {
              "args" : [
                "mcp"
              ],
              "command" : "\(cli)"
            }
          }
        }

        """)
        #expect(try text(root.appending(path: "\(plugin)/hooks/hooks.json")) == """
        {
          "description" : "Tell Claude Code it is running in a Batty Pane, and which one.",
          "hooks" : {
            "SessionStart" : [
              {
                "hooks" : [
                  {
                    "command" : "'\(cli)' agent context",
                    "timeout" : 10,
                    "type" : "command"
                  }
                ]
              }
            ]
          }
        }

        """)
        #expect(try text(root.appending(path: "\(plugin)/skills/batty-cli/SKILL.md")) == AgentInstallFixture.skill)
    }

    @Test func publicTreeDiffersFromStagedTreeOnlyInCLIPath() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let (identity, root) = try stage(fixture, beta: false)
        let files = try AgentPluginTree.publicFiles(version: identity.version, skill: Data(AgentInstallFixture.skill.utf8))
        let publicPlugin = Set(files.map(\.path).filter { $0.hasPrefix("batty/") })
        #expect(publicPlugin == Set(Self.pluginFiles.map { "batty/" + $0 }))
        for path in Self.pluginFiles {
            let staged = try text(root.appending(path: "batty/\(path)"))
                .replacingOccurrences(of: identity.cliExecutablePath, with: "batty")
            #expect(staged == (try publicFile("batty/\(path)")), "\(path)")
        }
        var staged = try object(try text(root.appending(path: ".claude-plugin/marketplace.json")))
        var published = try object(try publicFile(".claude-plugin/marketplace.json"))
        for key in ["name", "description", "owner"] {
            staged[key] = nil
            published[key] = nil
        }
        var stagedEntries = try #require(staged["plugins"] as? [[String: Any]])
        stagedEntries[0]["version"] = nil
        staged["plugins"] = stagedEntries
        #expect(try AgentPluginTree.jsonData(staged) == AgentPluginTree.jsonData(published))
    }

    @Test func publicMarketplaceFollowsClaudeCodeRules() throws {
        let marketplace = try object(try publicFile(".claude-plugin/marketplace.json"))
        let name = try #require(marketplace["name"] as? String)
        #expect(name == "batty-plugins")
        #expect(name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]*/) != nil)
        #expect(name != "batty-local" && !name.hasPrefix("claude") && !name.hasPrefix("anthropic"))
        let entries = try #require(marketplace["plugins"] as? [[String: Any]])
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        let manifest = try object(try publicFile("batty/.claude-plugin/plugin.json"))
        #expect(entry["name"] as? String == manifest["name"] as? String)
        #expect(entry["source"] as? String == "./batty")
        #expect(!((entry["source"] as? String) ?? "..").contains(".."))
        #expect(entry["version"] == nil)
        #expect(manifest["version"] as? String == "1.5.0")
        #expect(((marketplace["owner"] as? [String: String])?["name"] ?? "").isEmpty == false)
    }

    @Test func publicMCPAndHookRunBareBatty() throws {
        let mcp = try object(try publicFile("batty/.mcp.json"))
        let server = try #require((mcp["mcpServers"] as? [String: Any])?["batty"] as? [String: Any])
        #expect(server["command"] as? String == "batty")
        #expect(server["args"] as? [String] == AgentMCPConfigSnippets.serverArguments)
        let hooks = try object(try publicFile("batty/hooks/hooks.json"))
        let groups = try #require((hooks["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])
        let hook = try #require((groups.first?["hooks"] as? [[String: Any]])?.first)
        #expect(hook["command"] as? String == "'batty' agent context")
    }

    @Test func publicSkillIsTheUnrenamedSkill() throws {
        #expect(try publicFile("batty/skills/batty-cli/SKILL.md") == AgentInstallFixture.skill)
    }

    @Test func publicReadmeNamesTheInstallCommands() {
        let readme = AgentPluginTree.publicReadme(version: "1.5.0")
        for line in AgentPluginTree.marketplaceCommands { #expect(readme.contains(line)) }
        #expect(readme.contains("1.5.0"))
    }
}
