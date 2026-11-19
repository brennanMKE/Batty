// TabCommand.swift

import ArgumentParser
import BattyCLICore
import BattyXPCCore
import Foundation

/// `batty tab` — `focus` (#0381) and `new` (#0667). `tab rename` and
/// `tab close` stay unbuilt until scheduled.
struct TabNounCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tab",
        abstract: "Open, focus or otherwise control a Batty tab.",
        subcommands: [TabFocusCommand.self, TabNewCommand.self]
    )
}

/// `batty tab focus` — #0381: one of the three "show the human what I did"
/// verbs, over XPC request/reply following #0282's mutation-verb pattern.
///
/// **`surface` is an accepted alias for `tab`** (#0257's 2026-07-27
/// terminology amendment), but this command is registered only under the
/// `tab` noun — `surface` is an alias for the noun in conversation and
/// documentation, not a second `ParsableCommand` subtree to keep in sync.
///
/// Selects the target tab if it isn't already selected, and implies
/// focusing its containing pane — the terminology amendment's pinned
/// semantics, distinct from `pane focus`, which never re-selects tabs.
/// **Activating**, like `session focus`/`pane focus`: selects the tab's
/// owning session and brings its window forward, the CLI's one sanctioned
/// exception to "a mutation aimed at a background session must not switch
/// the active session."
struct TabFocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Focus a tab by id, selecting it, its pane, and its session, and activating its window.",
        discussion: """
        Selects the target tab if it isn't already its pane's active tab, \
        focuses that pane, selects its owning session, and brings the \
        session's window forward. Unlike `pane focus`, this verb changes \
        which tab is selected — that's the whole point of focusing a tab \
        rather than a pane. Only id-based targeting is implemented; \
        index-based targeting (`<n>`) is not.
        """,
        helpNames: .long
    )

    @Argument(help: "Tab id to focus. Falls back to BATTY_TAB_ID, then the focused tab, when omitted.")
    var id: String?

    nonisolated func run() throws {
        let targetTabID = try resolveTargetTabID(flag: id)

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
            switch AppServiceClient.tabFocus(endpoint: endpoint, tabID: targetTabID, timeout: 3.0) {
            case .success:
                break
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
    }

    /// `<id>` argument → `BATTY_TAB_ID` env → `nil` (let the app resolve
    /// the focused tab). Same chain shape as `NotifyCommand`'s
    /// `resolveTargetTabID`, driven by a positional argument rather than a
    /// `--tab` flag — see `PaneFocusCommand`'s doc for why focus verbs use
    /// a positional id.
    private nonisolated func resolveTargetTabID(flag: String?) throws -> UUID? {
        switch BattyTargetResolver.resolve(flag: flag, environmentKey: .tabID) {
        case let .success(id):
            return id
        case let .failure(.malformedFlag(raw)):
            fputs("batty: invalid tab id: \(raw)\n", stderr)
            throw ExitCode.failure
        }
    }
}

extension TabFocusCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: [
            "id": CapabilitiesPropertyPayload(cliKind: .positional, type: "string", description: "Tab id to focus. Falls back to BATTY_TAB_ID, then the focused tab, when omitted.", required: false),
        ])
    }
}

/// `batty tab new`: opens a terminal Tab in a Pane over XPC. Selects the
/// new Tab (unless `--background`) but never moves keyboard focus to
/// another Pane, Session or window.
struct TabNewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Open a new terminal tab in the calling/target pane, printing the tab's id.",
        helpNames: .long
    )

    @Option(name: .long, help: "Pane id to add the tab to. Falls back to BATTY_PANE_ID, then the focused pane, when omitted.")
    var pane: String?

    @Option(name: [.customShort("c"), .long], help: "Run this command in the new tab in place of the default shell; the tab stays open after it exits. With --wait it is typed into the shell instead.")
    var command: String?

    @Option(name: .long, help: "Working directory for the new tab. Defaults to the calling tab's, else the pane's active tab's.")
    var cwd: String?

    @Flag(name: .long, help: "Add the tab without selecting it.")
    var background: Bool = false

    @Flag(name: .long, help: "Emit JSON (sessionID, paneID, tabID, and with --wait exitCode, durationMs, waitResult) instead of the id.")
    var json: Bool = false

    @Flag(name: .long, help: ArgumentHelp(stringLiteral: CommandWaitCLI.waitDescription))
    var wait: Bool = false

    @Option(name: .long, help: ArgumentHelp(stringLiteral: CommandWaitCLI.timeoutDescription))
    var timeout: Double?

    enum CwdError: Error, Equatable {
        case notADirectory(String)
    }

    /// Absolute, standardized path, or an error when it isn't an existing
    /// directory: libghostty would otherwise silently start the shell in
    /// its default directory.
    nonisolated static func resolveWorkingDirectory(_ raw: String, currentDirectory: String) -> Result<String, CwdError> {
        let expanded = (raw as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true))
        let path = url.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.notADirectory(path))
        }
        return .success(path)
    }

    nonisolated func validate() throws {
        if let timeout, let error = WaitTimeout.validationError(timeout) {
            throw ValidationError("--timeout \(error)")
        }
    }

    nonisolated func run() throws {
        if let message = CommandWaitCLI.validationError(wait: wait, timeout: timeout, command: command) {
            fputs("batty: \(message)\n", stderr)
            throw ExitCode.failure
        }
        let targetPaneID = try resolveTargetPaneID(flag: pane)
        let sourceTabID: UUID?
        if case let .success(id) = BattyTargetResolver.resolve(flag: nil, environmentKey: .tabID) {
            sourceTabID = id
        } else {
            sourceTabID = nil
        }
        var workingDirectory: String?
        if let cwd {
            switch Self.resolveWorkingDirectory(cwd, currentDirectory: FileManager.default.currentDirectoryPath) {
            case let .success(path):
                workingDirectory = path
            case let .failure(.notADirectory(path)):
                fputs("batty: --cwd is not a directory: \(path)\n", stderr)
                throw ExitCode.failure
            }
        }
        let request = TabNewRequest(paneID: targetPaneID, sourceTabID: sourceTabID, command: command, workingDirectory: workingDirectory, background: background, wait: wait ? true : nil, waitTimeoutSeconds: wait ? (timeout ?? CommandWaitDefaults.timeoutSeconds) : nil)

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
            switch AppServiceClient.tabNew(endpoint: endpoint, request: request, timeout: CommandWaitCLI.clientTimeout(wait: wait, timeout: timeout)) {
            case .success(let reply):
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    let data = try encoder.encode(reply)
                    print(String(decoding: data, as: UTF8.self))
                } else {
                    print(reply.tabID.uuidString)
                }
                let outcome = CommandWaitCLI.exit(for: reply.waitResult, exitCode: reply.exitCode, timeoutSeconds: timeout ?? CommandWaitDefaults.timeoutSeconds)
                if let message = outcome.message { fputs("batty: \(message)\n", stderr) }
                if outcome.status != 0 { throw ExitCode(outcome.status) }
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
    }
}

extension TabNewCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: ([
            "pane": CapabilitiesPropertyPayload(cliKind: .option, names: ["--pane"], type: "string", description: "Pane id to add the tab to. Falls back to BATTY_PANE_ID, then the focused pane, when omitted.", required: false),
            "command": CapabilitiesPropertyPayload(cliKind: .option, names: ["-c", "--command"], type: "string", description: "Run this command in the new tab in place of the default shell; the tab stays open after it exits. With --wait it is typed into the shell instead.", required: false),
            "cwd": CapabilitiesPropertyPayload(cliKind: .option, names: ["--cwd"], type: "string", description: "Working directory for the new tab. Defaults to the calling tab's, else the pane's active tab's.", required: false),
            "background": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--background"], type: "boolean", description: "Add the tab without selecting it.", required: false, defaultValue: "false"),
            "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON (sessionID, paneID, tabID, and with --wait exitCode, durationMs, waitResult) instead of the id.", required: false, defaultValue: "false"),
        ] as [String: CapabilitiesPropertyPayload]).merging(CommandWaitCLI.waitProperties()) { current, _ in current }, conflicts: CommandWaitCLI.waitConflicts)
    }
}
