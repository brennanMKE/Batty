// ServerCommand.swift

import ArgumentParser
import BattyCLICore
import BattyXPCCore
import Foundation

/// `batty server` — the sixth noun (#0648). `start` needs a trailing
/// command and a working directory, and `stop`/`restart` act on a running
/// process rather than a Pane, so none of this fits `pane split`
/// (`docs/batty-cli-design.md` §1.1). Beta only until 1.5.0.
struct ServerNounCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "server",
        abstract: "Start, attach to, serve, stop or restart a dev server shown in a Server Pane.",
        subcommands: [ServerStartCommand.self, ServerAttachCommand.self, ServerServeCommand.self, ServerPreviewCommand.self, ServerStopCommand.self, ServerRestartCommand.self]
    )
}

private nonisolated func resolveServerEndpoint() throws -> NSXPCListenerEndpoint {
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

private nonisolated func resolveCallingPaneID(flag: String?) throws -> UUID? {
    switch BattyTargetResolver.resolve(flag: flag, environmentKey: .paneID) {
    case let .success(id):
        return id
    case let .failure(.malformedFlag(raw)):
        fputs("batty: invalid --pane id: \(raw)\n", stderr)
        throw ExitCode.failure
    }
}

/// Sends a `server` verb and prints the reply: the Server Pane id, or
/// `ServerReply` as JSON.
private nonisolated func sendServer(verb: String, request: some Encodable, json: Bool, timeout: TimeInterval) throws -> ServerReply {
    let endpoint = try resolveServerEndpoint()
    switch AppServiceClient.server(verb: verb, request: request, endpoint: endpoint, timeout: timeout) {
    case .success(let reply):
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(reply), let text = String(data: data, encoding: .utf8) else {
                fputs("batty: failed to encode server reply as JSON\n", stderr)
                throw ExitCode.failure
            }
            print(text)
        } else {
            print(reply.paneID.uuidString)
        }
        return reply
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

/// Generous enough for a Stop that escalates all the way to SIGKILL.
private nonisolated let serverStopTimeout: TimeInterval = 15

private nonisolated func validatePort(_ port: Int) throws {
    guard (1...65535).contains(port) else { throw ValidationError("--port must be between 1 and 65535") }
}

struct ServerStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Run a dev server in a terminal Pane and show a Server Pane for its port, printing the Server Pane's id.",
        discussion: """
        Example: batty server start --port 8083 -- go run .

        The command runs in a new terminal Pane below the Server Pane, in this \
        directory; the keyboard stays in the calling Pane. One argument after \
        `--` is used verbatim as shell text; several are quoted and joined. \
        Running it again for the same port reuses that Server Pane and its \
        terminal, replaces the command and restarts. --wait waits until \
        something listens on the port (exit 0), the command exits (exit 4) or \
        --timeout passes (exit 4).
        """,
        helpNames: .long
    )

    @Option(name: .long, help: "TCP port the server listens on (1-65535).")
    var port: Int

    @Option(name: .long, help: "URL to show and probe. Defaults to http://localhost:<port>/.")
    var url: String?

    @Option(name: .long, help: "JSON endpoint for stats. Defaults to /debug/vars (Go expvar) on the server.")
    var statsUrl: String?

    @Option(name: .long, help: "Where the Server Pane goes: right or down. Defaults to the Settings choice.")
    var split: ServerSplit?

    @Option(name: .long, help: "Pane whose Session gets the Server Pane. Falls back to BATTY_PANE_ID, then the focused pane.")
    var pane: String?

    @Flag(name: .long, help: "Wait until the server listens, exits, or --timeout passes.")
    var wait = false

    @Option(name: .long, help: "Seconds --wait waits. Defaults to 60.")
    var timeout: Double = 60

    @Flag(name: .long, help: "Emit JSON (paneID, terminalPaneID, tabID, url, pid, state) instead of the id.")
    var json = false

    @Argument(parsing: .postTerminator, help: "The server command, after --.")
    var command: [String] = []

    nonisolated func validate() throws {
        try validatePort(port)
        guard !command.isEmpty else { throw ValidationError("give the server command after --, for example: -- go run .") }
        guard timeout > 0 else { throw ValidationError("--timeout must be positive") }
    }

    nonisolated func request(currentDirectory: String = FileManager.default.currentDirectoryPath) throws -> ServerStartRequest {
        ServerStartRequest(
            paneID: try resolveCallingPaneID(flag: pane), port: port, command: ShellCommandJoiner.join(command),
            workingDirectory: URL(fileURLWithPath: currentDirectory).standardizedFileURL.path,
            url: url, statsURL: statsUrl, split: split, wait: wait ? true : nil, waitTimeoutSeconds: wait ? timeout : nil
        )
    }

    nonisolated func run() throws {
        _ = try sendServer(verb: XPCVerb.serverStart, request: try request(), json: json, timeout: (wait ? timeout : 0) + serverStopTimeout)
    }
}

extension ServerSplit: ExpressibleByArgument {}

struct ServerAttachCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Show a Server Pane for a server started elsewhere, printing the Server Pane's id.",
        discussion: """
        Example: batty server attach --port 8083

        Batty never reruns a command it read from another process. Pass \
        --command (and --cwd) to make Restart available; Restart then runs \
        it in a new terminal Pane. Running attach again for the same port \
        returns the existing Server Pane unchanged.
        """,
        helpNames: .long
    )

    @Option(name: .long, help: "TCP port the server listens on (1-65535).")
    var port: Int

    @Option(name: .long, help: "URL to show and probe. Defaults to http://localhost:<port>/.")
    var url: String?

    @Option(name: .long, help: "JSON endpoint for stats. Defaults to /debug/vars (Go expvar) on the server.")
    var statsUrl: String?

    @Option(name: .long, help: "Shell command Restart runs. Without it the Server Pane has no Restart.")
    var command: String?

    @Option(name: .long, help: "Directory --command runs in. Defaults to this directory.")
    var cwd: String?

    @Option(name: .long, help: "Where the Server Pane goes: right or down. Defaults to the Settings choice.")
    var split: ServerSplit?

    @Option(name: .long, help: "Pane whose Session gets the Server Pane. Falls back to BATTY_PANE_ID, then the focused pane.")
    var pane: String?

    @Flag(name: .long, help: "Wait until the server listens or --timeout passes.")
    var wait = false

    @Option(name: .long, help: "Seconds --wait waits. Defaults to 60.")
    var timeout: Double = 60

    @Flag(name: .long, help: "Emit JSON (paneID, url, pid, state) instead of the id.")
    var json = false

    nonisolated func validate() throws {
        try validatePort(port)
        guard timeout > 0 else { throw ValidationError("--timeout must be positive") }
    }

    nonisolated func request(currentDirectory: String = FileManager.default.currentDirectoryPath) throws -> ServerAttachRequest {
        let directory = command == nil ? nil : URL(fileURLWithPath: cwd ?? ".", relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true)).standardizedFileURL.path
        return ServerAttachRequest(
            paneID: try resolveCallingPaneID(flag: pane), port: port, url: url, statsURL: statsUrl,
            command: command, workingDirectory: directory, split: split, wait: wait ? true : nil, waitTimeoutSeconds: wait ? timeout : nil
        )
    }

    nonisolated func run() throws {
        let reply = try sendServer(verb: XPCVerb.serverAttach, request: try request(), json: json, timeout: (wait ? timeout : 0) + serverStopTimeout)
        if reply.state == .starting {
            fputs("nothing is listening on port \(port) yet; the Server Pane will update when something does\n", stderr)
        }
    }
}

struct ServerServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Serve a folder from inside Batty on 127.0.0.1, printing the Server Pane's id.",
        discussion: """
        Example: batty server serve ./site --open

        The server binds 127.0.0.1 only and reloads open pages when a file \
        under the folder changes. Dotfiles and anything outside the folder \
        are never served. Running serve again on the same folder reuses its \
        Server Pane. Closing the Server Pane stops the server.
        """,
        helpNames: .long
    )

    @Argument(help: "Folder to serve. Defaults to this directory.")
    var dir: String?

    @Option(name: .long, help: "Port to listen on (1-65535). Defaults to a free port.")
    var port: Int?

    @Flag(name: .long, help: "Also open the site, in a Web Preview Pane or the browser per Settings.")
    var open = false

    @Flag(name: .long, help: "Serve files byte-for-byte, with no live-reload script in HTML.")
    var noInject = false

    @Option(name: .long, help: "Where the Server Pane goes: right or down. Defaults to the Settings choice.")
    var split: ServerSplit?

    @Option(name: .long, help: "Pane whose Session gets the Server Pane. Falls back to BATTY_PANE_ID, then the focused pane.")
    var pane: String?

    @Flag(name: .long, help: "Emit JSON (paneID, url, root, state, previewPaneID) instead of the id.")
    var json = false

    nonisolated func validate() throws {
        if let port { try validatePort(port) }
    }

    nonisolated func request(currentDirectory: String = FileManager.default.currentDirectoryPath) throws -> ServerServeRequest {
        let root = URL(fileURLWithPath: dir ?? ".", relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true)).standardizedFileURL.path
        return ServerServeRequest(
            paneID: try resolveCallingPaneID(flag: pane), root: root, port: port,
            open: open ? true : nil, inject: noInject ? false : nil, split: split)
    }

    nonisolated func run() throws {
        _ = try sendServer(verb: XPCVerb.serverServe, request: try request(), json: json, timeout: serverStopTimeout)
    }
}

struct ServerPreviewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview",
        abstract: "Show a local page in a Web Preview Pane, printing the Pane's id.",
        discussion: """
        Example: batty server preview --port 8083

        Only http(s) URLs on localhost, 127.0.0.1 or [::1] are shown. \
        Running preview again for the same origin navigates the existing \
        Web Preview Pane.
        """,
        helpNames: .long
    )

    @Option(name: .long, help: "Loopback URL to show.")
    var url: String?

    @Option(name: .long, help: "Port to show at http://127.0.0.1:<port>/ (1-65535).")
    var port: Int?

    @Option(name: .long, help: "Where the Web Preview Pane goes: right or down. Defaults to the Server Pane placement setting.")
    var split: ServerSplit?

    @Option(name: .long, help: "Pane the Web Preview Pane opens beside. Falls back to BATTY_PANE_ID, then the focused pane.")
    var pane: String?

    @Flag(name: .long, help: "Emit JSON (paneID, url, created) instead of the id.")
    var json = false

    nonisolated func validate() throws {
        _ = try targetURL()
    }

    nonisolated func targetURL() throws -> String {
        switch (url, port) {
        case (nil, nil): throw ValidationError("give --url or --port")
        case (.some, .some): throw ValidationError("give --url or --port, not both")
        case (nil, .some(let port)):
            try validatePort(port)
            return "http://127.0.0.1:\(port)/"
        case (.some(let url), nil):
            guard let parsed = URL(string: url), WebPreviewURLPolicy.isAllowedTopLevel(parsed), WebPreviewURLPolicy.origin(of: parsed) != nil else {
                throw ValidationError(WebPreviewURLPolicy.refusalMessage)
            }
            return url
        }
    }

    nonisolated func run() throws {
        let request = WebPreviewRequest(paneID: try resolveCallingPaneID(flag: pane), url: try targetURL(), split: split)
        let endpoint = try resolveServerEndpoint()
        switch AppServiceClient.webPreview(request: request, endpoint: endpoint, timeout: 15) {
        case .success(let reply):
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                guard let data = try? encoder.encode(reply), let text = String(data: data, encoding: .utf8) else {
                    fputs("batty: failed to encode preview reply as JSON\n", stderr)
                    throw ExitCode.failure
                }
                print(text)
            } else {
                print(reply.paneID.uuidString)
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
}

/// `stop` and `restart` name the Server Pane by id or by port.
private nonisolated func controlRequest(id: String?, port: Int?, pane: String?) throws -> ServerControlRequest {
    if let id {
        guard let uuid = UUID(uuidString: id) else { throw ValidationError("invalid Server Pane id: \(id)") }
        return ServerControlRequest(paneID: try resolveCallingPaneID(flag: pane), serverPaneID: uuid)
    }
    guard let port else { throw ValidationError("give --port or a Server Pane id") }
    try validatePort(port)
    return ServerControlRequest(paneID: try resolveCallingPaneID(flag: pane), port: port)
}

struct ServerStopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the server a Server Pane shows (SIGINT, then SIGTERM, then SIGKILL).",
        helpNames: .long
    )

    @Argument(help: "Server Pane id. Omit to name it by --port.")
    var id: String?

    @Option(name: .long, help: "Port of the Server Pane in the calling Pane's Session.")
    var port: Int?

    @Option(name: .long, help: "Pane whose Session is searched for --port. Falls back to BATTY_PANE_ID, then the focused pane.")
    var pane: String?

    @Flag(name: .long, help: "Emit JSON instead of the id.")
    var json = false

    nonisolated func validate() throws {
        _ = try controlRequest(id: id, port: port, pane: nil)
    }

    nonisolated func run() throws {
        _ = try sendServer(verb: XPCVerb.serverStop, request: try controlRequest(id: id, port: port, pane: pane), json: json, timeout: serverStopTimeout)
    }
}

struct ServerRestartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Stop the server and run its command again.",
        helpNames: .long
    )

    @Argument(help: "Server Pane id. Omit to name it by --port.")
    var id: String?

    @Option(name: .long, help: "Port of the Server Pane in the calling Pane's Session.")
    var port: Int?

    @Option(name: .long, help: "Pane whose Session is searched for --port. Falls back to BATTY_PANE_ID, then the focused pane.")
    var pane: String?

    @Flag(name: .long, help: "Emit JSON instead of the id.")
    var json = false

    nonisolated func validate() throws {
        _ = try controlRequest(id: id, port: port, pane: nil)
    }

    nonisolated func run() throws {
        _ = try sendServer(verb: XPCVerb.serverRestart, request: try controlRequest(id: id, port: port, pane: pane), json: json, timeout: serverStopTimeout)
    }
}

// MARK: - Capabilities

private nonisolated let splitProperty = CapabilitiesPropertyPayload(cliKind: .option, names: ["--split"], type: "string", description: "Where the Server Pane goes: right or down. Defaults to the Settings choice.", required: false, enumValues: ServerSplit.allCases.map(\.rawValue))
private nonisolated let paneProperty = CapabilitiesPropertyPayload(cliKind: .option, names: ["--pane"], type: "string", description: "Pane whose Session gets the Server Pane. Falls back to BATTY_PANE_ID, then the focused pane.", required: false)
private nonisolated let urlProperty = CapabilitiesPropertyPayload(cliKind: .option, names: ["--url"], type: "string", description: "URL to show and probe. Defaults to http://localhost:<port>/.", required: false)
private nonisolated let statsURLProperty = CapabilitiesPropertyPayload(cliKind: .option, names: ["--stats-url"], type: "string", description: "JSON endpoint for stats. Defaults to /debug/vars (Go expvar) on the server.", required: false)
private nonisolated let portProperty = CapabilitiesPropertyPayload(cliKind: .option, names: ["--port"], type: "integer", description: "TCP port the server listens on (1-65535).", required: true)
private nonisolated let timeoutProperty = CapabilitiesPropertyPayload(cliKind: .option, names: ["--timeout"], type: "number", description: "Seconds --wait waits. Defaults to 60.", required: false, defaultValue: "60")

extension ServerStartCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: [
            "port": portProperty,
            "url": urlProperty,
            "stats-url": statsURLProperty,
            "split": splitProperty,
            "pane": paneProperty,
            "wait": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--wait"], type: "boolean", description: "Wait until the server listens, exits, or --timeout passes.", required: false, defaultValue: "false"),
            "timeout": timeoutProperty,
            "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON (paneID, terminalPaneID, tabID, url, pid, state) instead of the id.", required: false, defaultValue: "false"),
            "command": CapabilitiesPropertyPayload(cliKind: .positional, type: "array", description: "The server command, after --.", required: true),
        ], required: ["port", "command"])
    }
}

extension ServerAttachCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: [
            "port": portProperty,
            "url": urlProperty,
            "stats-url": statsURLProperty,
            "command": CapabilitiesPropertyPayload(cliKind: .option, names: ["--command"], type: "string", description: "Shell command Restart runs. Without it the Server Pane has no Restart.", required: false),
            "cwd": CapabilitiesPropertyPayload(cliKind: .option, names: ["--cwd"], type: "string", description: "Directory --command runs in. Defaults to this directory.", required: false),
            "split": splitProperty,
            "pane": paneProperty,
            "wait": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--wait"], type: "boolean", description: "Wait until the server listens or --timeout passes.", required: false, defaultValue: "false"),
            "timeout": timeoutProperty,
            "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON (paneID, url, pid, state) instead of the id.", required: false, defaultValue: "false"),
        ], required: ["port"])
    }
}

extension ServerServeCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: [
            "dir": CapabilitiesPropertyPayload(cliKind: .positional, type: "string", description: "Folder to serve. Defaults to this directory.", required: false),
            "port": CapabilitiesPropertyPayload(cliKind: .option, names: ["--port"], type: "integer", description: "Port to listen on (1-65535). Defaults to a free port.", required: false),
            "open": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--open"], type: "boolean", description: "Also open the site, in a Web Preview Pane or the browser per Settings.", required: false, defaultValue: "false"),
            "no-inject": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--no-inject"], type: "boolean", description: "Serve files byte-for-byte, with no live-reload script in HTML.", required: false, defaultValue: "false"),
            "split": splitProperty,
            "pane": paneProperty,
            "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON (paneID, url, root, state, previewPaneID) instead of the id.", required: false, defaultValue: "false"),
        ])
    }
}

extension ServerPreviewCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(
            properties: [
                "url": CapabilitiesPropertyPayload(cliKind: .option, names: ["--url"], type: "string", description: "Loopback URL to show.", required: false),
                "port": CapabilitiesPropertyPayload(cliKind: .option, names: ["--port"], type: "integer", description: "Port to show at http://127.0.0.1:<port>/ (1-65535).", required: false),
                "split": CapabilitiesPropertyPayload(cliKind: .option, names: ["--split"], type: "string", description: "Where the Web Preview Pane goes: right or down. Defaults to the Server Pane placement setting.", required: false, enumValues: ServerSplit.allCases.map(\.rawValue)),
                "pane": CapabilitiesPropertyPayload(cliKind: .option, names: ["--pane"], type: "string", description: "Pane the Web Preview Pane opens beside. Falls back to BATTY_PANE_ID, then the focused pane.", required: false),
                "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON (paneID, url, created) instead of the id.", required: false, defaultValue: "false"),
            ],
            conflicts: [.mutuallyExclusive(["url", "port"], description: "Give exactly one of --url or --port.")]
        )
    }
}

private nonisolated func controlSchema() -> CapabilitiesInputSchemaPayload {
    CapabilitiesInputSchemaPayload(properties: [
        "id": CapabilitiesPropertyPayload(cliKind: .positional, type: "string", description: "Server Pane id. Omit to name it by --port.", required: false),
        "port": CapabilitiesPropertyPayload(cliKind: .option, names: ["--port"], type: "integer", description: "Port of the Server Pane in the calling Pane's Session.", required: false),
        "pane": CapabilitiesPropertyPayload(cliKind: .option, names: ["--pane"], type: "string", description: "Pane whose Session is searched for --port. Falls back to BATTY_PANE_ID, then the focused pane.", required: false),
        "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON instead of the id.", required: false, defaultValue: "false"),
    ])
}

extension ServerStopCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload { controlSchema() }
}

extension ServerRestartCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload { controlSchema() }
}
