// MCPServer.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "MCPServer")

nonisolated enum MCPJSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MCPJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: MCPJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    subscript(key: String) -> MCPJSONValue? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    var stringValue: String? {
        if case let .string(text) = self { return text }
        return nil
    }
}

nonisolated enum MCPErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
}

/// A stdio MCP server: newline-delimited JSON-RPC 2.0, one message per line.
/// Nothing but protocol messages is ever written to `output`.
actor MCPServer {
    static let supportedProtocolVersions = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]

    static let instructions = """
        You may be running inside Batty, a macOS terminal multiplexer. These tools mirror \
        the batty command-line verbs (tool name = verb path with spaces as underscores). \
        Omitted Session/Pane/Tab targets resolve to your own Pane through the BATTY_* \
        environment variables. Call capabilities for the full vocabulary.
        """

    private let catalog: MCPToolCatalog
    private let runner: MCPToolRunner
    private let serverName: String
    private let serverVersion: String
    private var inFlight: [MCPJSONValue: Task<Void, Never>] = [:]

    init(catalog: MCPToolCatalog, runner: MCPToolRunner, serverName: String, serverVersion: String) {
        self.catalog = catalog
        self.runner = runner
        self.serverName = serverName
        self.serverVersion = serverVersion
    }

    /// Returns when `input` reaches end of file, after cancelling and
    /// awaiting any calls still running.
    func serve(input: FileHandle, output: FileHandle) async {
        do {
            for try await line in input.bytes.lines {
                handle(line: line, output: output)
            }
        } catch {
            logger.error("mcp input failed: \(String(describing: error), privacy: .public)")
        }
        let remaining = Array(inFlight.values)
        for task in remaining { task.cancel() }
        for task in remaining { await task.value }
    }

    private func handle(line: String, output: FileHandle) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let message = try? JSONDecoder().decode(MCPJSONValue.self, from: Data(trimmed.utf8)) else {
            send(error: MCPErrorCode.parseError, message: "Parse error", id: .null, output: output)
            return
        }
        guard case .object = message, let method = message["method"]?.stringValue else {
            send(error: MCPErrorCode.invalidRequest, message: "Invalid Request", id: message["id"] ?? .null, output: output)
            return
        }
        let params = message["params"]
        guard let id = message["id"] else {
            handleNotification(method: method, params: params)
            return
        }
        switch method {
        case "initialize":
            send(result: initializeResult(params: params), id: id, output: output)
        case "ping":
            send(result: .object([:]), id: id, output: output)
        case "tools/list":
            send(result: .object(["tools": .array(catalog.tools.map(\.listEntry))]), id: id, output: output)
        case "tools/call":
            startCall(params: params, id: id, output: output)
        default:
            send(error: MCPErrorCode.methodNotFound, message: "Method not found: \(method)", id: id, output: output)
        }
    }

    private func handleNotification(method: String, params: MCPJSONValue?) {
        guard method == "notifications/cancelled", let requestID = params?["requestId"] else { return }
        inFlight[requestID]?.cancel()
    }

    private func initializeResult(params: MCPJSONValue?) -> MCPJSONValue {
        let requested = params?["protocolVersion"]?.stringValue
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.supportedProtocolVersions[0]
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object(["name": .string(serverName), "version": .string(serverVersion)]),
            "instructions": .string(Self.instructions),
        ])
    }

    private func startCall(params: MCPJSONValue?, id: MCPJSONValue, output: FileHandle) {
        guard let name = params?["name"]?.stringValue, catalog.tool(named: name) != nil else {
            let name = params?["name"]?.stringValue ?? "<missing>"
            send(error: MCPErrorCode.invalidParams, message: "Unknown tool: \(name)", id: id, output: output)
            return
        }
        var callArguments: [String: MCPJSONValue] = [:]
        switch params?["arguments"] {
        case nil, .null?:
            break
        case let .object(fields)?:
            callArguments = fields
        default:
            send(result: Self.toolResult(text: "invalid arguments: arguments must be an object", isError: true), id: id, output: output)
            return
        }
        let argv: [String]
        do {
            argv = try catalog.arguments(forToolName: name, callArguments: callArguments)
        } catch {
            send(result: Self.toolResult(text: "invalid arguments: \(error.description)", isError: true), id: id, output: output)
            return
        }
        let runner = runner
        inFlight[id] = Task {
            let result = await runner.run(argv)
            self.finishCall(result: result, id: id, output: output)
        }
    }

    private func finishCall(result: MCPToolRunResult, id: MCPJSONValue, output: FileHandle) {
        let cancelled = inFlight[id]?.isCancelled ?? true
        inFlight[id] = nil
        // A cancelled request gets no reply (MCP cancellation).
        guard !cancelled else { return }
        if result.exitCode == 0 {
            send(result: Self.toolResult(text: result.stdout, isError: false), id: id, output: output)
        } else {
            var text = "exit \(result.exitCode): \(catalog.exitCodeMeaning(result.exitCode))"
            if !result.stderr.isEmpty { text += "\n" + result.stderr }
            if !result.stdout.isEmpty { text += "\n" + result.stdout }
            send(result: Self.toolResult(text: text, isError: true), id: id, output: output)
        }
    }

    private static func toolResult(text: String, isError: Bool) -> MCPJSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ])
    }

    private func send(result: MCPJSONValue, id: MCPJSONValue, output: FileHandle) {
        write(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]), output: output)
    }

    private func send(error code: Int, message: String, id: MCPJSONValue, output: FileHandle) {
        write(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .int(code), "message": .string(message)]),
        ]), output: output)
    }

    private func write(_ message: MCPJSONValue, output: FileHandle) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(message) else { return }
        data.append(0x0A)
        do {
            try output.write(contentsOf: data)
        } catch {
            logger.error("mcp output failed: \(String(describing: error), privacy: .public)")
        }
    }
}
