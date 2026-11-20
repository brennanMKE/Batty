// ProjectCLITests.swift

import ArgumentParser
import BattyXPCCore
import Foundation
import Testing
@testable import batty

/// The `batty project` noun (#0477).
struct ProjectCLITests {
    private func verbNames() -> Set<String> {
        Set(CapabilitiesCommand.verbs().map(\.name))
    }

    // MARK: - Command tree

    @Test func theTreeContainsTheProjectNounWithListAndOpen() throws {
        let noun = try #require(BattyCLI.configuration.subcommands.first { $0.configuration.commandName == "project" })
        #expect(noun is ProjectNounCommand.Type)
        #expect(noun.configuration.subcommands.map { $0.configuration.commandName } == ["list", "open", "create", "edit"])
    }

    @Test func theShippedConfigurationContainsTheProjectNoun() {
        #expect(BattyCLI.configuration.subcommands.contains { $0 is ProjectNounCommand.Type })
    }

    @Test func theRootTreeAdvertisesProjectInItsSubcommandHelp() {
        let noun = BattyCLI.configuration.subcommands.first { $0 is ProjectNounCommand.Type }
        #expect(noun?.helpMessage().contains("list") == true)
        #expect(BattyCLI.helpMessage().lowercased().contains("project"))
    }

    // MARK: - Capabilities

    @Test func capabilitiesReportsTheProjectVerbs() {
        #expect(verbNames().isSuperset(of: ["project list", "project open"]))
    }

    @Test func awaitingConfirmationExitCodeIsListed() {
        let codes = CapabilitiesCommand.buildPayload().exitCodes.map(\.code)
        #expect(codes.contains(XPCExitCode.awaitingConfirmation))
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
        let verb = try #require(CapabilitiesCommand.verbs().first { $0.name == "project open" })
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

    // MARK: - create and edit (#0700)

    private func validationFails(_ type: any ParsableCommand.Type, _ arguments: [String]) -> Bool {
        do { _ = try type.parseAsRoot(arguments); return false } catch { return true }
    }

    @Test func theTreeContainsCreateAndEdit() {
        #expect(verbNames().isSuperset(of: ["project create", "project edit"]))
    }

    @Test func createParsesTheFullSynopsis() throws {
        let command = try ProjectCreateCommand.parse([
            "--name", "Demo", "--path", "/tmp/x", "--color", "green", "--symbol", "web", "--theme", "Batty Dark",
            "--preset", "twoByTwoGrid", "--background-set", "Deep Space", "--background-image", "Nebula",
            "--opacity", "20", "--terminal-opacity", "90", "--startup-command", "ls", "--json",
        ])
        let request = try command.options.request(target: nil, cwd: "/work", environment: [:], standardInput: .nullDevice)
        #expect(request.name == "Demo" && request.rootPath == "/tmp/x" && request.color == "green" && request.symbol == "web")
        #expect(request.themeDark == "Batty Dark" && request.themeLight == "Batty Dark")
        #expect(request.layout == .preset("twoByTwoGrid"))
        #expect(request.background == .hosted(set: "Deep Space", title: "Nebula"))
        #expect(request.imageOpacityPercent == 20 && request.terminalOpacityPercent == 90)
        #expect(request.startupCommands == ["ls"])
        #expect(command.options.json)
    }

    @Test func createNeedsNameAndPathWithoutFromSession() {
        #expect(validationFails(ProjectCreateCommand.self, ["--name", "Demo"]))
        #expect(validationFails(ProjectCreateCommand.self, ["--path", "/tmp"]))
        #expect(!validationFails(ProjectCreateCommand.self, ["--from-session"]))
    }

    @Test func colorAndColorHexAreExclusive() {
        #expect(validationFails(ProjectCreateCommand.self, ["--name", "A", "--path", "/tmp", "--color", "red", "--color-hex", "#112233"]))
    }

    @Test func layoutSourcesAreExclusive() {
        #expect(validationFails(ProjectCreateCommand.self, ["--name", "A", "--path", "/tmp", "--preset", "singlePane", "--layout-json", "{}"]))
        #expect(validationFails(ProjectCreateCommand.self, ["--name", "A", "--path", "/tmp", "--layout", "-", "--from-session"]))
    }

    @Test func imageSourcesAreExclusive() {
        #expect(validationFails(ProjectCreateCommand.self, ["--name", "A", "--path", "/tmp", "--background-id", "x", "--background-digest", "y"]))
        #expect(validationFails(ProjectCreateCommand.self, ["--name", "A", "--path", "/tmp", "--background-file", "x", "--no-background"]))
    }

    @Test func noBackgroundWithOpacityIsAnError() {
        #expect(validationFails(ProjectEditCommand.self, ["Demo", "--no-background", "--opacity", "10"]))
    }

    @Test func opacityAbove100IsAValidationError() {
        #expect(validationFails(ProjectEditCommand.self, ["Demo", "--opacity", "101"]))
        #expect(!validationFails(ProjectEditCommand.self, ["Demo", "--opacity", "100"]))
    }

    @Test func negativeTerminalOpacityIsAValidationError() {
        #expect(validationFails(ProjectEditCommand.self, ["Demo", "--terminal-opacity=-1"]))
    }

    @Test func backgroundSetRequiresBackgroundImage() {
        #expect(validationFails(ProjectEditCommand.self, ["Demo", "--background-set", "Deep Space"]))
        #expect(validationFails(ProjectEditCommand.self, ["Demo", "--background-image", "Nebula"]))
    }

    @Test func sessionRequiresFromSession() {
        #expect(validationFails(ProjectEditCommand.self, ["Demo", "--session", UUID().uuidString, "--color", "red"]))
        #expect(!validationFails(ProjectEditCommand.self, ["Demo", "--session", UUID().uuidString, "--from-session"]))
    }

    @Test func relativePathResolvesAgainstTheCwd() throws {
        #expect(ProjectWriteOptions.resolvedPath("site/../app", cwd: "/work") == "/work/app")
        #expect(ProjectWriteOptions.resolvedPath("/abs", cwd: "/work") == "/abs")
        let command = try ProjectCreateCommand.parse(["--name", "A", "--path", "repo", "--background-file", "img.png"])
        let request = try command.options.request(target: nil, cwd: "/work", environment: [:], standardInput: .nullDevice)
        #expect(request.rootPath == "/work/repo")
        #expect(request.background == .file("/work/img.png"))
    }

    @Test func layoutDashReadsTheGivenHandle() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(#"{"preset":"horizontalSplit","panes":[{"kind":"terminal"},{"kind":"git-status","background":null}]}"#.utf8))
        try pipe.fileHandleForWriting.close()
        let command = try ProjectCreateCommand.parse(["--name", "A", "--path", "/tmp", "--layout", "-"])
        let request = try command.options.request(target: nil, cwd: "/work", environment: [:], standardInput: pipe.fileHandleForReading)
        guard case .document(let document)? = request.layout else { Issue.record("no document"); return }
        #expect(document.preset == "horizontalSplit" && document.panes?.count == 2)
    }

    @Test func editNeedsAtLeastOneField() {
        #expect(validationFails(ProjectEditCommand.self, ["Demo"]))
        #expect(validationFails(ProjectEditCommand.self, ["Demo", "--json"]))
        #expect(!validationFails(ProjectEditCommand.self, ["Demo", "--no-theme"]))
    }

    @Test func startupCommandRepeats() throws {
        let command = try ProjectCreateCommand.parse(["--name", "A", "--path", "/tmp", "--startup-command", "a", "--startup-command", "b"])
        #expect(command.options.startupCommand == ["a", "b"])
    }

    @Test func badLayoutJSONIsARequestFailureNamingThePath() throws {
        let command = try ProjectCreateCommand.parse(["--name", "A", "--path", "/tmp", "--layout-json", #"{"preset":"singlePane","panes":[{"kind":"terminal","tabz":[]}]}"#])
        #expect(throws: ProjectWriteCLIError("panes[0].tabz: unknown key")) {
            try command.options.request(target: nil, cwd: "/work", environment: [:], standardInput: .nullDevice)
        }
    }

    @Test func callerSessionComesFromTheEnvironment() throws {
        let id = UUID()
        let command = try ProjectCreateCommand.parse(["--from-session"])
        let request = try command.options.request(target: nil, cwd: "/", environment: ["BATTY_SESSION_ID": id.uuidString], standardInput: .nullDevice)
        #expect(request.layout == .fromSession(nil) && request.callerSessionID == id)
    }
}
