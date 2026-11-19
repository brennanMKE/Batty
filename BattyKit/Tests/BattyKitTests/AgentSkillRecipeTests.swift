// AgentSkillRecipeTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import batty

/// Every `batty` invocation in the skill's code blocks names a verb the
/// flag-on CLI ships, so a renamed or removed verb can't linger in a recipe.
/// Flags are checked by `AgentSkillFlagDriftTests`.
struct AgentSkillRecipeTests {
    private static func skillMarkdown() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: ".claude/skills/batty-cli/SKILL.md", directoryHint: .notDirectory)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func codeLines(_ markdown: String) -> [String] {
        var inFence = false
        var lines: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                inFence.toggle()
            } else if inFence {
                lines.append(line)
            }
        }
        return lines
    }

    @Test func everyBattyInvocationUsesAShippedVerbAndFlag() throws {
        let payload = CapabilitiesCommand.buildPayload(flags: .allOnForTests)
        let verbs = Dictionary(uniqueKeysWithValues: payload.verbs.map { ($0.name, $0) })
        let nouns = Set(payload.verbs.compactMap { $0.name.split(separator: " ").count == 2 ? String($0.name.split(separator: " ")[0]) : nil })
        var checked = 0
        for line in Self.codeLines(try Self.skillMarkdown()) {
            for marker in ["\"$BATTY\" ", "batty-beta ", "batty "] {
                guard let range = line.range(of: marker) else { continue }
                let rest = String(line[range.upperBound...]).replacing(/"[^"]*"/, with: "\"\"")
                let words = rest.split(separator: " ").map(String.init)
                guard let first = words.first, first.first?.isLetter == true else { break }
                let path = nouns.contains(first) && words.count > 1 ? "\(first) \(words[1])" : first
                let verb = try #require(verbs[path], "SKILL.md runs `\(path)`, which the CLI does not ship: \(line)")
                let known = Set(verb.inputSchema.properties.values.flatMap { $0.names + ($0.enumValueNames?.values.flatMap { $0 } ?? []) })
                // Words after a bare `--` are the command `server start` runs, not flags.
                for word in words.prefix(while: { $0 != "--" }) where word.hasPrefix("--") {
                    let flag = String(word.split(separator: "=")[0]).trimmingCharacters(in: CharacterSet(charactersIn: ")`;"))
                    #expect(known.contains(flag), "SKILL.md passes \(flag) to `\(path)`: \(line)")
                }
                checked += 1
                break
            }
        }
        #expect(checked >= 10)
    }

    @Test func skillNoLongerClaims1_1_0() throws {
        let markdown = try Self.skillMarkdown()
        #expect(!markdown.contains("Authored against Batty CLI `1.1.0`"))
        #expect(markdown.contains("Authored against Batty CLI `1.5.0`"))
    }
}
