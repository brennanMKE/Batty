// AgentHelpDocsTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import batty

struct AgentHelpDocsTests {
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func helpFolder() -> URL {
        repoRoot().appending(path: "BattyKit/Sources/BattyKit/Help", directoryHint: .isDirectory)
    }

    private static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private static func agentsPage() throws -> String {
        try read(helpFolder().appending(path: "12-ai-agents.md", directoryHint: .notDirectory))
    }

    private static func helpPages() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: helpFolder(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
    }

    private static func cliDocs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: repoRoot().appending(path: "docs", directoryHint: .isDirectory), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("batty-cli-") && $0.pathExtension == "md" }
    }

    /// Inline code spans and fenced lines that start with `batty `.
    private static func invocations(_ markdown: String) -> [String] {
        var result: [String] = []
        var inFence = false
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence {
                if line.hasPrefix("batty ") { result.append(line) }
                continue
            }
            for match in line.matches(of: /`(batty [^`]+)`/) {
                result.append(String(match.1))
            }
        }
        return result
    }

    @Test func everyBattyCommandInTheAgentsPageIsAShippedVerb() throws {
        let payload = CapabilitiesCommand.buildPayload(flags: .allOnForTests)
        let verbs = Dictionary(uniqueKeysWithValues: payload.verbs.map { ($0.name, $0) })
        let nouns = Set(payload.verbs.compactMap { $0.name.split(separator: " ").count == 2 ? String($0.name.split(separator: " ")[0]) : nil })
        var checked = 0
        for line in Self.invocations(try Self.agentsPage()) {
            let rest = String(line.dropFirst("batty ".count)).replacing(/"[^"]*"/, with: "\"\"")
            let words = rest.split(separator: " ").map(String.init)
            guard let first = words.first, first.first?.isLetter == true else { continue }
            let second = words.count > 1 && !words[1].hasPrefix("<") ? words[1] : nil
            let path = nouns.contains(first) && second != nil ? "\(first) \(second!)" : first
            let verb = try #require(verbs[path], "Help runs `\(path)`, which the CLI does not ship: \(line)")
            let known = Set(verb.inputSchema.properties.values.flatMap { $0.names + ($0.enumValueNames?.values.flatMap { $0 } ?? []) })
            for word in words.prefix(while: { $0 != "--" }) where word.hasPrefix("--") {
                let flag = String(word.split(separator: "=")[0]).trimmingCharacters(in: CharacterSet(charactersIn: ")`;,."))
                #expect(known.contains(flag), "Help passes \(flag) to `\(path)`: \(line)")
            }
            checked += 1
        }
        #expect(checked >= 10)
    }

    @Test func helpPagesNameNoRetiredServerFeatures() throws {
        for url in try Self.helpPages() where url.lastPathComponent != "09-third-party-licenses.md" {
            let text = try Self.read(url)
            for retired in ["Server Pane", "Web Preview", "server preview", "server attach"] {
                #expect(!text.contains(retired), "\(url.lastPathComponent) names \(retired)")
            }
        }
    }

    @Test func helpAndAgentDocsSayNoBetaOnlyForShippedNouns() throws {
        for url in try Self.helpPages() + Self.cliDocs() {
            for line in try Self.read(url).components(separatedBy: "\n") {
                let lower = line.lowercased()
                guard lower.contains("beta only") else { continue }
                for noun in ["server", "mcp", "agent"] {
                    #expect(!lower.contains(noun), "\(url.lastPathComponent): \(line)")
                }
            }
        }
    }

    @Test func agentsPageCarriesTheWebdriverRule() throws {
        let page = try Self.agentsPage()
        #expect(page.contains("safaridriver"))
        #expect(page.contains("no web view"))
    }

    @Test func agentsPageNamesTheSettingsSection() throws {
        #expect(try Self.agentsPage().contains("Command Line and AI Agents"))
    }

    @Test func workflowDocNoLongerListsTabNewAsMissing() throws {
        let doc = try Self.read(Self.repoRoot().appending(path: "docs/batty-cli-agent-workflows.md", directoryHint: .notDirectory))
        #expect(doc.contains("tab new -c"))
        #expect(!doc.contains("creating a Tab"))
    }
}
