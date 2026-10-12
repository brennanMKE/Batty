// ProjectCLITests.swift

import ArgumentParser
import BattyXPCCore
import Foundation
import Testing
@testable import batty

/// The `batty project` noun (#0477). `BattyKitTests` builds without
/// `-DBATTY_VARIANT_BETA`, so `FeatureFlags.current` is always off here;
/// every test that needs the noun passes the flag explicitly.
struct ProjectCLITests {
    private let on = FeatureFlags(projects: true)
    private let off = FeatureFlags(projects: false)

    private func verbNames(_ flags: FeatureFlags) -> Set<String> {
        Set(CapabilitiesCommand.verbs(flags: flags).map(\.name))
    }

    // MARK: - Command tree

    @Test func flagOnTreeContainsTheProjectNounWithListAndOpen() throws {
        let noun = try #require(BattyCLI.subcommands(for: on).first { $0.configuration.commandName == "project" })
        #expect(noun is ProjectNounCommand.Type)
        #expect(noun.configuration.subcommands.map { $0.configuration.commandName } == ["list", "open"])
    }

    @Test func flagOffTreeHasNoProjectNoun() {
        #expect(BattyCLI.subcommands(for: off).allSatisfy { $0.configuration.commandName != "project" })
        #expect(!BattyCLI.subcommands(for: off).contains { $0 is ProjectNounCommand.Type })
    }

    @Test func flagOffTreeIsExactlyTheTreeWithoutTheNoun() {
        let withNoun = BattyCLI.subcommands(for: on).map { String(describing: $0) }
        let without = BattyCLI.subcommands(for: off).map { String(describing: $0) }
        #expect(withNoun.filter { $0 != "ProjectNounCommand" } == without)
    }

    @Test func theShippedConfigurationFollowsTheCompileTimeFlag() {
        let expected = BattyCLI.subcommands(for: .current).map { String(describing: $0) }
        #expect(BattyCLI.configuration.subcommands.map { String(describing: $0) } == expected)
        #expect(!FeatureFlags.current.projects, "swift test builds without -DBATTY_VARIANT_BETA")
        #expect(!BattyCLI.configuration.subcommands.contains { $0 is ProjectNounCommand.Type })
    }

    @Test func theShippedRootHelpWithTheFlagOffNeverMentionsProject() {
        #expect(!FeatureFlags.current.projects)
        #expect(!BattyCLI.helpMessage().lowercased().contains("project"))
    }

    @Test func theFlagOnRootTreeAdvertisesProjectInItsSubcommandHelp() {
        let noun = BattyCLI.subcommands(for: on).first { $0 is ProjectNounCommand.Type }
        #expect(noun?.helpMessage().contains("list") == true)
    }

    // MARK: - Capabilities

    @Test func capabilitiesReportsProjectVerbsOnlyWithTheFlagOn() {
        #expect(verbNames(on).isSuperset(of: ["project list", "project open"]))
        #expect(verbNames(off).isDisjoint(with: ["project list", "project open"]))
        #expect(verbNames(on).subtracting(["project list", "project open"]) == verbNames(off))
    }

    @Test func defaultCapabilitiesUsesTheCompileTimeFlag() {
        #expect(CapabilitiesCommand.verbs().map(\.name) == CapabilitiesCommand.verbs(flags: .current).map(\.name))
        #expect(verbNames(.current).isDisjoint(with: ["project list", "project open"]))
    }

    @Test func capabilitiesJSONForTheFlagOffBuildHasNoProjectText() throws {
        let data = try JSONEncoder().encode(CapabilitiesCommand.buildPayload(flags: off))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.lowercased().contains("project"))
    }

    @Test func awaitingConfirmationExitCodeIsListedOnlyWithTheFlagOn() {
        let onCodes = CapabilitiesCommand.buildPayload(flags: on).exitCodes.map(\.code)
        let offCodes = CapabilitiesCommand.buildPayload(flags: off).exitCodes.map(\.code)
        #expect(onCodes.contains(XPCExitCode.awaitingConfirmation))
        #expect(!offCodes.contains(XPCExitCode.awaitingConfirmation))
        #expect(onCodes.filter { $0 != XPCExitCode.awaitingConfirmation } == offCodes)
        #expect(XPCExitCode.awaitingConfirmation == 8)
    }

    @Test func projectListIsReadOnlyAndOpenIsActivatingButNotDestructive() throws {
        let list = CapabilitiesCommand.annotations(forVerbPath: "project list")
        #expect(list.readOnlyHint)
        #expect(!list.destructiveHint)
        let open = CapabilitiesCommand.annotations(forVerbPath: "project open")
        #expect(!open.readOnlyHint)
        #expect(!open.destructiveHint)
        #expect(!open.idempotentHint, "--new opens another Session every call")
        let verb = try #require(CapabilitiesCommand.verbs(flags: on).first { $0.name == "project open" })
        #expect(verb.annotations == open)
        #expect(Set(verb.inputSchema.properties.keys) == ["name", "new", "json"])
    }

    // MARK: - Argument parsing

    @Test func openParsesANameAlone() throws {
        let command = try ProjectOpenCommand.parse(["Batty"])
        #expect(command.name == "Batty")
        #expect(!command.new)
        #expect(!command.json)
    }

    @Test func openParsesAQuotedNameWithNewAndJSON() throws {
        let command = try ProjectOpenCommand.parse(["My Project", "--new", "--json"])
        #expect(command.name == "My Project")
        #expect(command.new)
        #expect(command.json)
    }

    @Test func openWithoutANameIsAUsageError() {
        do {
            _ = try ProjectOpenCommand.parse([])
            Issue.record("parse with no name must fail")
        } catch {
            #expect(ProjectOpenCommand.exitCode(for: error) == ExitCode.validationFailure)
            #expect(ProjectOpenCommand.message(for: error).contains("name"))
        }
    }

    @Test func openWithABlankNameIsAValidationError() {
        do {
            _ = try ProjectOpenCommand.parse(["  "])
            Issue.record("a blank name must fail validation")
        } catch {
            #expect(ProjectOpenCommand.exitCode(for: error) == ExitCode.validationFailure)
        }
    }

    @Test func openHasNoWayToSkipThePrompt() {
        let help = ProjectOpenCommand.helpMessage()
        #expect(!help.contains("--yes"))
        #expect(!help.contains("--force"))
        #expect(!help.contains("--trust"))
        #expect(throws: (any Error).self) { try ProjectOpenCommand.parse(["Batty", "--yes"]) }
    }

    @Test func openHelpDocumentsThePromptBehavior() {
        let help = ProjectOpenCommand.helpMessage()
        #expect(help.contains("no option to skip the prompt"))
        #expect(help.contains("\(ProjectOpenRequest.confirmationBoundSeconds) seconds"))
        #expect(help.contains("exit status is 8"))
    }

    @Test func listParsesWithAndWithoutJSON() throws {
        #expect(try !ProjectListCommand.parse([]).json)
        #expect(try ProjectListCommand.parse(["--json"]).json)
    }

    // MARK: - Output

    private func entry(_ name: String, _ root: String, _ panes: Int, open: Bool = false) -> ProjectListEntry {
        ProjectListEntry(id: UUID(), name: name, rootPath: root, paneCount: panes, isOpen: open)
    }

    @Test func tableMatchesTheArtboardShape() {
        let table = ProjectListCommand.table([
            entry("Batty", "/Users/me/Developer/brennanMKE/Batty", 3),
            entry("Homelab", "/Users/me/Developer/Homelab", 2, open: true),
        ], home: "/Users/me")
        let lines = table.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("NAME") && lines[0].hasSuffix("PANES"))
        #expect(lines[1].contains("~/Developer/brennanMKE/Batty"))
        #expect(!lines[1].hasSuffix("open"))
        #expect(lines[2].hasSuffix("2  open"))
        let rootColumn = lines[0].range(of: "ROOT")!.lowerBound
        #expect(lines[1].distance(from: lines[1].startIndex, to: lines[1].range(of: "~/")!.lowerBound)
            == lines[0].distance(from: lines[0].startIndex, to: rootColumn))
    }

    @Test func tableKeepsStoreOrder() {
        let table = ProjectListCommand.table([entry("Zed", "/a", 1), entry("Alpha", "/b", 1)], home: "/h")
        #expect(table.range(of: "Zed")!.lowerBound < table.range(of: "Alpha")!.lowerBound)
    }

    @Test func emptyTableSaysSo() {
        #expect(ProjectListCommand.table([], home: "/h") == "No saved Projects.")
    }

    @Test func homeAbbreviationOnlyMatchesWholePathComponents() {
        #expect(ProjectListCommand.abbreviatingHome("/Users/me", home: "/Users/me") == "~")
        #expect(ProjectListCommand.abbreviatingHome("/Users/me/x", home: "/Users/me") == "~/x")
        #expect(ProjectListCommand.abbreviatingHome("/Users/medium/x", home: "/Users/me") == "/Users/medium/x")
        #expect(ProjectListCommand.abbreviatingHome("/x", home: "/") == "/x")
    }

    @Test func openedAndFocusedSentences() {
        let created = ProjectOpenReply(status: .opened, name: "Batty", sessionID: UUID(), paneID: UUID(), created: true)
        let focused = ProjectOpenReply(status: .opened, name: "Batty", sessionID: UUID(), paneID: UUID(), created: false)
        #expect(ProjectOpenCommand.sentence(for: created) == "Opened Session \"Batty\"")
        #expect(ProjectOpenCommand.sentence(for: focused) == "Focused Session \"Batty\"")
    }

    @Test func openedJSONCarriesSessionPaneAndCreated() throws {
        let session = UUID(), pane = UUID()
        let reply = ProjectOpenReply(status: .opened, name: "Batty", sessionID: session, paneID: pane, created: true)
        let data = try JSONEncoder().encode(ProjectOpenCommand.OpenedJSON(reply))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["name", "sessionID", "paneID", "created"])
        #expect(object["sessionID"] as? String == session.uuidString)
        #expect(object["paneID"] as? String == pane.uuidString)
        #expect(object["created"] as? Bool == true)
    }
}
