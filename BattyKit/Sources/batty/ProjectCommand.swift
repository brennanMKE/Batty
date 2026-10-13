// ProjectCommand.swift

import ArgumentParser
import BattyXPCCore
import Foundation

/// `batty project` — the fifth noun, present only while the Projects feature
/// flag is on (`BattyCLI.subcommands(for:)`). The CLI never reads
/// `projects.json`; the app owns `ProjectStore` and answers both verbs over
/// XPC. There are deliberately no `add`, `remove` or `edit` verbs: Projects
/// are edited in the Project Editor.
struct ProjectNounCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "List or open a saved Project.",
        subcommands: [ProjectListCommand.self, ProjectOpenCommand.self]
    )
}

private nonisolated func resolveAppEndpoint() throws -> NSXPCListenerEndpoint {
    switch AppConnectDance.resolveEndpoint() {
    case .failure(.brokerUnreachable):
        fputs("batty: broker unreachable\n", stderr)
        throw ExitCode(XPCExitCode.brokerUnreachable)
    case .failure(.appUnavailable):
        fputs("batty: app unavailable\n", stderr)
        throw ExitCode(XPCExitCode.appUnavailable)
    case .failure(.appRunningUnregistered):
        fputs("batty: Batty is running but isn't responding to the broker — try relaunching it\n", stderr)
        throw ExitCode(XPCExitCode.appRunningUnregistered)
    case .failure(.appBundleUnresolved(let message)):
        fputs("batty: \(message)\n", stderr)
        throw ExitCode(XPCExitCode.appBundleUnresolved)
    case .success(let endpoint):
        return endpoint
    }
}

private nonisolated func printJSON<T: Encodable>(_ value: T, what: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
        fputs("batty: failed to encode \(what) as JSON\n", stderr)
        throw ExitCode.failure
    }
    print(text)
}

/// `batty project list` — saved Projects in the order the app lists them,
/// each with its root, Pane count and an `open` marker while a Session from
/// it is open.
struct ProjectListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the saved Projects.",
        discussion: """
        Prints each Project's name, root folder (the home folder shown as \
        `~`), Pane count, and `open` when a Session from it is open, in the \
        order Batty lists them: most recently opened first, then Projects never \
        opened in the order saved. Projects with an open Session are listed last. \
        Read-only.
        """,
        helpNames: .long
    )

    @Flag(name: .long, help: "Emit JSON instead of a plain-text table. Root paths stay absolute.")
    var json = false

    nonisolated func run() throws {
        let endpoint = try resolveAppEndpoint()
        switch AppServiceClient.projectList(endpoint: endpoint, timeout: 3.0) {
        case .success(let reply):
            if json {
                try printJSON(reply, what: "project list")
            } else {
                print(Self.table(reply.projects, home: NSHomeDirectory()))
            }
        case .unreachable:
            fputs("batty: app unavailable\n", stderr)
            throw ExitCode(XPCExitCode.appUnavailable)
        case .requestFailed(let message):
            fputs("batty: request failed — \(message)\n", stderr)
            throw ExitCode(XPCExitCode.requestFailed)
        case .appTerminated:
            fputs("batty: app terminated\n", stderr)
            throw ExitCode(XPCExitCode.sessionTerminated)
        }
    }

    static func abbreviatingHome(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func table(_ entries: [ProjectListEntry], home: String) -> String {
        guard !entries.isEmpty else { return "No saved Projects." }
        let rows = entries.map { ($0.name, abbreviatingHome($0.rootPath, home: home), String($0.paneCount), $0.isOpen) }
        let nameWidth = max("NAME".count, rows.map(\.0.count).max() ?? 0) + 2
        let rootWidth = max("ROOT".count, rows.map(\.1.count).max() ?? 0) + 2
        func pad(_ text: String, _ width: Int) -> String {
            text + String(repeating: " ", count: max(0, width - text.count))
        }
        var lines = [pad("NAME", nameWidth) + pad("ROOT", rootWidth) + "PANES"]
        for (name, root, panes, isOpen) in rows {
            lines.append(pad(name, nameWidth) + pad(root, rootWidth) + panes + (isOpen ? "  open" : ""))
        }
        return lines.joined(separator: "\n")
    }
}

extension ProjectListCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: [
            "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON instead of a plain-text table. Root paths stay absolute.", required: false, defaultValue: "false"),
        ])
    }
}

/// `batty project open <name>` — opens a saved Project as a Session, or
/// focuses its Session when one is already open. **Activating**, like the
/// `focus` verbs, and not destructive.
///
/// **Startup commands are never run without the user's consent, and this
/// verb has no way to skip the prompt.** When the Project's commands are new
/// or have changed, Batty shows its approval sheet and no Session exists
/// until the user answers; the reply is held until then. If the sheet goes
/// unanswered for `ProjectOpenRequest.confirmationBoundSeconds` Batty
/// withdraws it, opens nothing, and this command exits
/// `XPCExitCode.awaitingConfirmation` (8). A sheet the user dismisses is an
/// ordinary failed request (exit 4).
struct ProjectOpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a saved Project as a Session, or focus its Session if one is open.",
        discussion: """
        <name> matches a saved Project's name case-insensitively, exactly. \
        Prints `Opened Session "<name>"`, or `Focused Session "<name>"` when \
        a Session from the Project was already open; --new always opens \
        another copy. An unknown name exits 4 and lists the close matches.

        If the Project has startup commands Batty has not seen before, or \
        they changed, Batty asks the user to approve them first and this \
        command waits for the answer (there is no option to skip the \
        prompt). If nobody answers within \(ProjectOpenRequest.confirmationBoundSeconds) \
        seconds Batty withdraws the prompt, nothing is opened, and the exit \
        status is 8. Answer the prompt in Batty and run the command again.
        """,
        helpNames: .long
    )

    @Argument(help: "Name of the saved Project (case-insensitive).")
    var name: String

    @Flag(name: .long, help: "Open another Session even if one from this Project is already open.")
    var new = false

    @Flag(name: .long, help: "Emit JSON (sessionID, paneID, created, name) instead of a sentence.")
    var json = false

    nonisolated func validate() throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("the Project name must not be empty")
        }
    }

    nonisolated func run() throws {
        let endpoint = try resolveAppEndpoint()
        let timeout = TimeInterval(ProjectOpenRequest.confirmationBoundSeconds + 10)
        switch AppServiceClient.projectOpen(endpoint: endpoint, name: name, openNew: new, timeout: timeout) {
        case .success(let reply):
            switch reply.status {
            case .opened:
                if json {
                    try printJSON(OpenedJSON(reply), what: "opened Project")
                } else {
                    print(Self.sentence(for: reply))
                }
            case .awaitingConfirmation:
                fputs("batty: Batty is waiting for you to approve the startup commands for \"\(reply.name)\"; the prompt went unanswered and was withdrawn, so nothing was opened. Answer it in Batty next time, or run the command again\n", stderr)
                throw ExitCode(XPCExitCode.awaitingConfirmation)
            }
        case .unreachable:
            fputs("batty: app unavailable\n", stderr)
            throw ExitCode(XPCExitCode.appUnavailable)
        case .requestFailed(let message):
            fputs("batty: request failed — \(message)\n", stderr)
            throw ExitCode(XPCExitCode.requestFailed)
        case .appTerminated:
            fputs("batty: app terminated\n", stderr)
            throw ExitCode(XPCExitCode.sessionTerminated)
        }
    }

    static func sentence(for reply: ProjectOpenReply) -> String {
        "\(reply.created ? "Opened" : "Focused") Session \"\(reply.name)\""
    }

    struct OpenedJSON: Encodable, Equatable {
        let name: String
        let sessionID: UUID?
        let paneID: UUID?
        let created: Bool

        init(_ reply: ProjectOpenReply) {
            name = reply.name
            sessionID = reply.sessionID
            paneID = reply.paneID
            created = reply.created
        }
    }
}

extension ProjectOpenCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: [
            "name": CapabilitiesPropertyPayload(cliKind: .positional, type: "string", description: "Name of the saved Project (case-insensitive).", required: true),
            "new": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--new"], type: "boolean", description: "Open another Session even if one from this Project is already open.", required: false, defaultValue: "false"),
            "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON (sessionID, paneID, created, name) instead of a sentence.", required: false, defaultValue: "false"),
        ])
    }
}
