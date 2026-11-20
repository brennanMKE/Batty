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
        abstract: "Start, share, serve, list, stop, restart, unshare or share on the tailnet a dev server listed in the toolbar's Servers.",
        subcommands: [ServerStartCommand.self, ServerShareCommand.self, ServerServeCommand.self, ServerListCommand.self, ServerStopCommand.self, ServerRestartCommand.self, ServerUnshareCommand.self, ServerTailnetCommand.self]
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

private nonisolated func failOutcome<T>(_ outcome: AppServiceClient.Outcome<T>) throws -> T {
    switch outcome {
    case .success(let value):
        return value
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

private nonisolated func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
        fputs("batty: failed to encode server reply as JSON\n", stderr)
        throw ExitCode.failure
    }
    print(text)
}

/// Sends a `server` verb and prints the reply: the server id, or
/// `ServerReply` as JSON.
private nonisolated func sendServer(verb: String, request: some Encodable, json: Bool, timeout: TimeInterval) throws -> ServerReply {
    let endpoint = try resolveServerEndpoint()
    let reply = try failOutcome(AppServiceClient.server(verb: verb, request: request, endpoint: endpoint, timeout: timeout))
    if json {
        try printJSON(reply)
    } else {
        print(reply.serverID.uuidString)
        if let tailnet = reply.tailnetURL { print(tailnet) }
    }
    if let error = reply.tailnetError {
        fputs("batty: tailnet: \(error)\n", stderr)
        throw ExitCode(XPCExitCode.requestFailed)
    }
    return reply
}

/// `tailscale serve` may run an HTTPS-certificate flow; the app bounds each
/// call at 20 s.
private nonisolated let tailnetTimeout: TimeInterval = 60

/// Generous enough for a Stop that escalates all the way to SIGKILL.
private nonisolated let serverStopTimeout: TimeInterval = 15

private nonisolated func validatePort(_ port: Int) throws {
    guard (1...65535).contains(port) else { throw ValidationError("--port must be between 1 and 65535") }
}

struct ServerStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Run a dev server in a terminal Pane and list it in the toolbar's Servers, printing the server's id.",
        discussion: """
        Example: batty server start --port 8083 -- go run .

        The command runs in a new terminal Pane split from the calling Pane, in this \
        directory; the keyboard stays in the calling Pane. One argument after \
        `--` is used verbatim as shell text; several are quoted and joined. \
        Running it again for the same port reuses that server and its \
        terminal, replaces the command and restarts. Once the port listens, a \
        Process Status Pane on the listener opens below the terminal Pane \
        (--no-process-view skips it). --wait waits until something listens \
        on the port (exit 0), the command exits (exit 4) or --timeout passes \
        (exit 4).
        """,
        helpNames: .long
    )

    @Option(name: .long, help: "TCP port the server listens on (1-65535).")
    var port: Int

    @Option(name: .long, help: "URL to copy and probe. Defaults to http://127.0.0.1:<port>/.")
    var url: String?

    @Option(name: .long, help: "Name shown in the Servers list.")
    var name: String?

    @Option(name: .long, help: "Where the terminal Pane goes: right (default) or down.")
    var split: ServerSplit?

    @Option(name: .long, help: "Pane the terminal Pane is split from. Falls back to BATTY_PANE_ID, then the focused pane.")
    var pane: String?

    @Flag(name: .long, help: "Don't open a Process Status Pane on the server's process.")
    var noProcessView = false

    @Flag(name: .long, help: "Wait until the server listens, exits, or --timeout passes.")
    var wait = false

    @Option(name: .long, help: "Seconds --wait waits, at most 86400. Defaults to 60.")
    var timeout: Double = 60

    @Flag(name: .long, help: "Emit JSON (serverID, name, kind, terminalPaneID, tabID, processPaneID, url, pid, state) instead of the id.")
    var json = false

    @Argument(parsing: .postTerminator, help: "The server command, after --.")
    var command: [String] = []

    nonisolated func validate() throws {
        try validatePort(port)
        guard !command.isEmpty else { throw ValidationError("give the server command after --, for example: -- go run .") }
        if let error = WaitTimeout.validationError(timeout) { throw ValidationError("--timeout \(error)") }
    }

    nonisolated func request(currentDirectory: String = FileManager.default.currentDirectoryPath) throws -> ServerStartRequest {
        ServerStartRequest(
            paneID: try resolveCallingPaneID(flag: pane), port: port, command: ShellCommandJoiner.join(command),
            workingDirectory: URL(fileURLWithPath: currentDirectory).standardizedFileURL.path,
            url: url, name: name, split: split, processView: noProcessView ? false : nil, wait: wait ? true : nil, waitTimeoutSeconds: wait ? timeout : nil
        )
    }

    nonisolated func run() throws {
        _ = try sendServer(verb: XPCVerb.serverStart, request: try request(), json: json, timeout: (wait ? timeout : 0) + serverStopTimeout)
    }
}

extension ServerSplit: ExpressibleByArgument {}

struct ServerShareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "share",
        abstract: "List a server already listening on 127.0.0.1 in the toolbar's Servers and watch its process, printing the server's id.",
        discussion: """
        Example: batty server share --port 8083

        Fails when nothing of yours listens on the port. Opens a Process \
        Status Pane on the listening process beside the calling Pane \
        (--no-process-view skips it); the keyboard stays in the calling \
        Pane. Batty never stops or restarts a shared server: stop it \
        yourself, and use batty server unshare to remove it from the list. \
        Running share again for the same port returns the same server and \
        reuses its Process Status Pane. --tailnet also runs batty server \
        tailnet; if that step fails the share stands and the command exits \
        nonzero.
        """,
        helpNames: .long
    )

    @Option(name: .long, help: "TCP port the server listens on (1-65535).")
    var port: Int

    @Option(name: .long, help: "Name shown in the Servers list.")
    var name: String?

    @Option(name: .long, help: "URL to copy and probe. Defaults to http://127.0.0.1:<port>/.")
    var url: String?

    @Option(name: .long, help: "Where the Process Status Pane goes: right (default) or down.")
    var split: ServerSplit?

    @Option(name: .long, help: "Pane the Process Status Pane is split from. Falls back to BATTY_PANE_ID, then the focused pane.")
    var pane: String?

    @Flag(name: .long, help: "Don't open a Process Status Pane on the server's process.")
    var noProcessView = false

    @Flag(name: .long, help: "Also share the server on your tailnet with tailscale serve.")
    var tailnet = false

    @Flag(name: .long, help: "Emit JSON (serverID, name, kind, processPaneID, url, tailnetURL, pid, state) instead of the id.")
    var json = false

    nonisolated func validate() throws {
        try validatePort(port)
    }

    nonisolated func request() throws -> ServerShareRequest {
        ServerShareRequest(
            paneID: try resolveCallingPaneID(flag: pane), port: port, url: url, name: name,
            split: split, processView: noProcessView ? false : nil, tailnet: tailnet ? true : nil
        )
    }

    nonisolated func run() throws {
        _ = try sendServer(verb: XPCVerb.serverShare, request: try request(), json: json, timeout: tailnet ? tailnetTimeout : serverStopTimeout)
    }
}

struct ServerListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the servers in the toolbar's Servers, one per line: id, name, port, kind, state, url.",
        helpNames: .long
    )

    @Flag(name: .long, help: "Emit JSON ({ servers: [...] }) instead of lines.")
    var json = false

    nonisolated static func lines(_ reply: ServerListReply) -> [String] {
        reply.servers.map { item in
            var fields = [item.serverID.uuidString, item.name, String(item.port), item.kind.rawValue, item.state.rawValue, item.url]
            if let tailnet = item.tailnetURL { fields.append(tailnet) }
            return fields.joined(separator: "\t")
        }
    }

    nonisolated func run() throws {
        let endpoint = try resolveServerEndpoint()
        let reply = try failOutcome(AppServiceClient.serverList(endpoint: endpoint, timeout: serverStopTimeout))
        if json {
            try printJSON(reply)
        } else {
            for line in Self.lines(reply) { print(line) }
        }
    }
}

struct ServerServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Serve a folder from inside Batty on 127.0.0.1, printing the server's id.",
        discussion: """
        Example: batty server serve ./site --open

        The server binds 127.0.0.1 only and reloads open pages when a file \
        under the folder changes. Dotfiles and anything outside the folder \
        are never served. Running serve again on the same folder reuses its \
        server. batty server stop stops it.
        """,
        helpNames: .long
    )

    @Argument(help: "Folder to serve. Defaults to this directory.")
    var dir: String?

    @Option(name: .long, help: "Port to listen on (1-65535). Defaults to a free port.")
    var port: Int?

    @Flag(name: .long, help: "Also open the site in the default browser.")
    var open = false

    @Flag(name: .long, help: "Serve files byte-for-byte, with no live-reload script in HTML.")
    var noInject = false

    @Option(name: .long, help: "Accepted for compatibility; has no effect.")
    var split: ServerSplit?

    @Option(name: .long, help: "Accepted for compatibility; has no effect.")
    var pane: String?

    @Flag(name: .long, help: "Emit JSON (serverID, url, root, state) instead of the id.")
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

/// `stop`, `restart` and `unshare` name the server by id or by port.
private nonisolated func controlRequest(id: String?, port: Int?, pane: String?) throws -> ServerControlRequest {
    if let id {
        guard let uuid = UUID(uuidString: id) else { throw ValidationError("invalid server id: \(id)") }
        return ServerControlRequest(paneID: try resolveCallingPaneID(flag: pane), serverID: uuid)
    }
    guard let port else { throw ValidationError("give --port or a server id") }
    try validatePort(port)
    return ServerControlRequest(paneID: try resolveCallingPaneID(flag: pane), port: port)
}

struct ServerStopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a server Batty started (SIGINT, then SIGTERM, then SIGKILL). Refused for a shared server.",
        helpNames: .long
    )

    @Argument(help: "Server id. Omit to name it by --port.")
    var id: String?

    @Option(name: .long, help: "Port of the server.")
    var port: Int?

    @Option(name: .long, help: "Accepted for compatibility; has no effect.")
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
        abstract: "Stop a server Batty started and run its command again. Refused for a shared server.",
        helpNames: .long
    )

    @Argument(help: "Server id. Omit to name it by --port.")
    var id: String?

    @Option(name: .long, help: "Port of the server.")
    var port: Int?

    @Option(name: .long, help: "Accepted for compatibility; has no effect.")
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

struct ServerUnshareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unshare",
        abstract: "Remove a shared server from the toolbar's Servers without signalling it. Refused for a server Batty started.",
        helpNames: .long
    )

    @Argument(help: "Server id. Omit to name it by --port.")
    var id: String?

    @Option(name: .long, help: "Port of the server.")
    var port: Int?

    @Option(name: .long, help: "Accepted for compatibility; has no effect.")
    var pane: String?

    @Flag(name: .long, help: "Emit JSON instead of the id.")
    var json = false

    nonisolated func validate() throws {
        _ = try controlRequest(id: id, port: port, pane: nil)
    }

    nonisolated func run() throws {
        _ = try sendServer(verb: XPCVerb.serverUnshare, request: try controlRequest(id: id, port: port, pane: pane), json: json, timeout: serverStopTimeout)
    }
}

struct ServerTailnetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tailnet",
        abstract: "Share a listed server on your tailnet with tailscale serve, printing its id and tailnet URL; --off stops.",
        discussion: """
        Example: batty server tailnet --port 8083

        Runs tailscale serve --bg --https=<port> http://127.0.0.1:<port>, so \
        the server is reachable at https://<this Mac>.<tailnet>.ts.net:<port>/ \
        from your tailnet devices. Needs Tailscale running with HTTPS \
        certificates on. Batty turns off only the mappings it made: on \
        --off, when the server leaves the list, and when Batty quits. A \
        port already served by a mapping Batty didn't make is left alone.
        """,
        helpNames: .long
    )

    @Argument(help: "Server id. Omit to name it by --port.")
    var id: String?

    @Option(name: .long, help: "Port of the server.")
    var port: Int?

    @Flag(name: .long, help: "Stop sharing the server on the tailnet.")
    var off = false

    @Option(name: .long, help: "Accepted for compatibility; has no effect.")
    var pane: String?

    @Flag(name: .long, help: "Emit JSON (serverID, url, tailnetURL, state) instead of the id.")
    var json = false

    nonisolated func validate() throws {
        _ = try controlRequest(id: id, port: port, pane: nil)
    }

    nonisolated func request() throws -> ServerTailnetRequest {
        let control = try controlRequest(id: id, port: port, pane: pane)
        return ServerTailnetRequest(paneID: control.paneID, serverID: control.serverID, port: control.port, off: off ? true : nil)
    }

    nonisolated func run() throws {
        _ = try sendServer(verb: XPCVerb.serverTailnet, request: try request(), json: json, timeout: tailnetTimeout)
    }
}

// MARK: - Capabilities

private nonisolated let nameProperty = CapabilitiesPropertyPayload(cliKind: .option, names: ["--name"], type: "string", description: "Name shown in the Servers list.", required: false)
private nonisolated let noProcessViewProperty = CapabilitiesPropertyPayload(cliKind: .flag, names: ["--no-process-view"], type: "boolean", description: "Don't open a Process Status Pane on the server's process.", required: false, defaultValue: "false")
private nonisolated let ignoredSplitProperty = CapabilitiesPropertyPayload(cliKind: .option, names: ["--split"], type: "string", description: "Accepted for compatibility; has no effect.", required: false, enumValues: ServerSplit.allCases.map(\.rawValue))
private nonisolated let splitProperty = CapabilitiesPropertyPayload(cliKind: .option, names: ["--split"], type: "string", description: "Where the terminal Pane goes: right (default) or down.", required: false, enumValues: ServerSplit.allCases.map(\.rawValue))
private nonisolated let paneProperty = CapabilitiesPropertyPayload(cliKind: .option, names: ["--pane"], type: "string", description: "Pane the terminal Pane is split from. Falls back to BATTY_PANE_ID, then the focused pane.", required: false)
private nonisolated let ignoredPaneProperty = CapabilitiesPropertyPayload(cliKind: .option, names: ["--pane"], type: "string", description: "Accepted for compatibility; has no effect.", required: false)
private nonisolated let urlProperty = CapabilitiesPropertyPayload(cliKind: .option, names: ["--url"], type: "string", description: "URL to copy and probe. Defaults to http://127.0.0.1:<port>/.", required: false)
private nonisolated let portProperty = CapabilitiesPropertyPayload(cliKind: .option, names: ["--port"], type: "integer", description: "TCP port the server listens on (1-65535).", required: true)
private nonisolated let timeoutProperty = CapabilitiesPropertyPayload(cliKind: .option, names: ["--timeout"], type: "number", description: "Seconds --wait waits, at most 86400. Defaults to 60.", required: false, defaultValue: "60", maximum: Int(WaitTimeout.maximumSeconds))

extension ServerStartCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: [
            "port": portProperty,
            "url": urlProperty,
            "name": nameProperty,
            "split": splitProperty,
            "pane": paneProperty,
            "no-process-view": noProcessViewProperty,
            "wait": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--wait"], type: "boolean", description: "Wait until the server listens, exits, or --timeout passes.", required: false, defaultValue: "false"),
            "timeout": timeoutProperty,
            "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON (serverID, name, kind, terminalPaneID, tabID, processPaneID, url, pid, state) instead of the id.", required: false, defaultValue: "false"),
            "command": CapabilitiesPropertyPayload(cliKind: .positional, type: "array", description: "The server command, after --.", required: true),
        ], required: ["port", "command"])
    }
}

extension ServerShareCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: [
            "port": portProperty,
            "name": nameProperty,
            "url": urlProperty,
            "split": CapabilitiesPropertyPayload(cliKind: .option, names: ["--split"], type: "string", description: "Where the Process Status Pane goes: right (default) or down.", required: false, enumValues: ServerSplit.allCases.map(\.rawValue)),
            "pane": CapabilitiesPropertyPayload(cliKind: .option, names: ["--pane"], type: "string", description: "Pane the Process Status Pane is split from. Falls back to BATTY_PANE_ID, then the focused pane.", required: false),
            "no-process-view": noProcessViewProperty,
            "tailnet": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--tailnet"], type: "boolean", description: "Also share the server on your tailnet with tailscale serve.", required: false, defaultValue: "false"),
            "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON (serverID, name, kind, processPaneID, url, tailnetURL, pid, state) instead of the id.", required: false, defaultValue: "false"),
        ], required: ["port"])
    }
}

extension ServerListCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: [
            "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON ({ servers: [...] }) instead of lines.", required: false, defaultValue: "false"),
        ])
    }
}

extension ServerServeCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: [
            "dir": CapabilitiesPropertyPayload(cliKind: .positional, type: "string", description: "Folder to serve. Defaults to this directory.", required: false),
            "port": CapabilitiesPropertyPayload(cliKind: .option, names: ["--port"], type: "integer", description: "Port to listen on (1-65535). Defaults to a free port.", required: false),
            "open": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--open"], type: "boolean", description: "Also open the site in the default browser.", required: false, defaultValue: "false"),
            "no-inject": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--no-inject"], type: "boolean", description: "Serve files byte-for-byte, with no live-reload script in HTML.", required: false, defaultValue: "false"),
            "split": ignoredSplitProperty,
            "pane": ignoredPaneProperty,
            "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON (serverID, url, root, state) instead of the id.", required: false, defaultValue: "false"),
        ])
    }
}

private nonisolated func controlSchema() -> CapabilitiesInputSchemaPayload {
    CapabilitiesInputSchemaPayload(properties: [
        "id": CapabilitiesPropertyPayload(cliKind: .positional, type: "string", description: "Server id. Omit to name it by --port.", required: false),
        "port": CapabilitiesPropertyPayload(cliKind: .option, names: ["--port"], type: "integer", description: "Port of the server.", required: false),
        "pane": CapabilitiesPropertyPayload(cliKind: .option, names: ["--pane"], type: "string", description: "Accepted for compatibility; has no effect.", required: false),
        "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON instead of the id.", required: false, defaultValue: "false"),
    ])
}

extension ServerStopCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload { controlSchema() }
}

extension ServerRestartCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload { controlSchema() }
}

extension ServerUnshareCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload { controlSchema() }
}

extension ServerTailnetCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: [
            "id": CapabilitiesPropertyPayload(cliKind: .positional, type: "string", description: "Server id. Omit to name it by --port.", required: false),
            "port": CapabilitiesPropertyPayload(cliKind: .option, names: ["--port"], type: "integer", description: "Port of the server.", required: false),
            "off": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--off"], type: "boolean", description: "Stop sharing the server on the tailnet.", required: false, defaultValue: "false"),
            "pane": CapabilitiesPropertyPayload(cliKind: .option, names: ["--pane"], type: "string", description: "Accepted for compatibility; has no effect.", required: false),
            "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON (serverID, url, tailnetURL, state) instead of the id.", required: false, defaultValue: "false"),
        ])
    }
}
