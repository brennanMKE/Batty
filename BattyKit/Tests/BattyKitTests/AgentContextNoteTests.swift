// AgentContextNoteTests.swift

import BattyCLICore
import Foundation
import Testing

nonisolated struct AgentContextNoteTests {
    static let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let tabID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let paneID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let context = BattyIdentityContext(sessionID: sessionID, paneID: paneID, tabID: tabID)
    static let full: [String: String] = [
        "BATTY_SESSION_ID": sessionID.uuidString,
        "BATTY_TAB_ID": tabID.uuidString,
        "BATTY_PANE_ID": paneID.uuidString,
    ]

    private func keys(_ json: String?) throws -> [String: Any] {
        let data = try #require(json?.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func fullEnvironmentResolvesInBatty() {
        #expect(AgentContextNote.resolve(environment: Self.full) == .inBatty(Self.context))
    }

    @Test func fullEnvironmentPrintsTheNoteWithAllThreeIDs() throws {
        let output = AgentContextNote.render(environment: Self.full, cliName: "batty", json: false)
        let stdout = try #require(output.stdout)
        for id in [Self.sessionID, Self.tabID, Self.paneID] {
            #expect(stdout.contains(id.uuidString))
        }
        #expect(stdout.contains("terminal Pane of Batty"))
        #expect(output.stderr == nil)
    }

    @Test(arguments: ["batty", "batty-beta"])
    func noteNamesTheVariantCLI(cliName: String) {
        let text = AgentContextNote.text(context: Self.context, cliName: cliName)
        #expect(text.contains("`\(cliName) capabilities`"))
        #expect(text.contains("`\(cliName) notify`"))
    }

    @Test func noteContainsEverySharedRuleLine() {
        let text = AgentContextNote.text(context: Self.context, cliName: "batty")
        let lines = AgentContextNote.ruleLines(cliName: "batty")
        for line in lines {
            #expect(text.contains(line))
        }
        #expect(lines.contains { $0.hasPrefix("- Close the Panes and Sessions you open") })
    }

    @Test func noteStaysShort() {
        #expect(AgentContextNote.text(context: Self.context, cliName: "batty-beta").count < 1_200)
    }

    @Test func emptyEnvironmentIsSilent() {
        #expect(AgentContextNote.render(environment: [:], cliName: "batty", json: false) == .init(stdout: nil, stderr: nil))
    }

    @Test func unrelatedVariablesAreSilent() {
        let env = ["PATH": "/usr/bin", "HOME": "/tmp"]
        #expect(AgentContextNote.render(environment: env, cliName: "batty", json: false) == .init(stdout: nil, stderr: nil))
    }

    @Test func emptyStringValuesAreSilent() {
        let env = ["BATTY_SESSION_ID": "", "BATTY_TAB_ID": "", "BATTY_PANE_ID": ""]
        #expect(AgentContextNote.render(environment: env, cliName: "batty", json: false) == .init(stdout: nil, stderr: nil))
    }

    @Test(arguments: BattyContextEnvironmentKey.allCases)
    func partialEnvironmentWritesOneStderrLineOnly(missing: BattyContextEnvironmentKey) throws {
        var env = Self.full
        env[missing.rawValue] = nil
        let output = AgentContextNote.render(environment: env, cliName: "batty", json: false)
        #expect(output.stdout == nil)
        let stderr = try #require(output.stderr)
        #expect(!stderr.contains("\n"))
        #expect(stderr.contains(missing.rawValue))
    }

    @Test func malformedValueWritesOneStderrLineOnly() throws {
        var env = Self.full
        env["BATTY_PANE_ID"] = "not-a-uuid"
        let output = AgentContextNote.render(environment: env, cliName: "batty", json: false)
        #expect(output.stdout == nil)
        #expect(try #require(output.stderr).contains("BATTY_PANE_ID"))
    }

    @Test func jsonInBattyHasExactKeys() throws {
        let output = AgentContextNote.render(environment: Self.full, cliName: "batty-beta", json: true)
        let object = try keys(output.stdout)
        #expect(Set(object.keys) == ["inBatty", "sessionID", "tabID", "paneID", "cli", "note"])
        #expect(object["inBatty"] as? Bool == true)
        #expect(object["cli"] as? String == "batty-beta")
        #expect(object["note"] as? String == AgentContextNote.text(context: Self.context, cliName: "batty-beta"))
        #expect(output.stderr == nil)
    }

    @Test func jsonOutsideBattyIsOnlyInBattyFalse() throws {
        let output = AgentContextNote.render(environment: [:], cliName: "batty", json: true)
        let object = try keys(output.stdout)
        #expect(Set(object.keys) == ["inBatty"])
        #expect(object["inBatty"] as? Bool == false)
        #expect(output.stderr == nil)
    }

    @Test func jsonIncompleteIsInBattyFalseWithStderr() throws {
        var env = Self.full
        env["BATTY_TAB_ID"] = nil
        let output = AgentContextNote.render(environment: env, cliName: "batty", json: true)
        #expect(Set(try keys(output.stdout).keys) == ["inBatty"])
        #expect(output.stderr != nil)
    }
}
