// MCPServerTests.swift

import BattyXPCCore
import Foundation
import os
import Testing
@testable import batty

/// Feeds newline-delimited output from a pipe as an `AsyncStream`, driven by
/// the handle's readability events.
nonisolated final class PipeLineReader: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var buffer = Data()
    let lines: AsyncStream<String>
    private var iterator: AsyncStream<String>.Iterator

    init(_ handle: FileHandle) {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        lines = stream
        iterator = stream.makeAsyncIterator()
        handle.readabilityHandler = { [lock] fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                continuation.finish()
                return
            }
            let complete: [String] = lock.withLock {
                var found: [String] = []
                self.buffer.append(data)
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    found.append(String(decoding: self.buffer[self.buffer.startIndex..<newline], as: UTF8.self))
                    self.buffer.removeSubrange(self.buffer.startIndex...newline)
                }
                return found
            }
            for line in complete { continuation.yield(line) }
        }
    }

    func next() async -> String? {
        await iterator.next()
    }
}

nonisolated struct ScriptedRunner: MCPToolRunner {
    let result: MCPToolRunResult
    let calls = OSAllocatedUnfairLock<[[String]]>(initialState: [])

    func run(_ arguments: [String]) async -> MCPToolRunResult {
        calls.withLock { $0.append(arguments) }
        return result
    }
}

/// Suspends until cancelled, signalling when it starts and when it sees the cancellation.
nonisolated final class SuspendingRunner: MCPToolRunner, @unchecked Sendable {
    let started: AsyncStream<Void>
    let cancelled: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let cancelledContinuation: AsyncStream<Void>.Continuation

    init() {
        (started, startedContinuation) = AsyncStream<Void>.makeStream()
        (cancelled, cancelledContinuation) = AsyncStream<Void>.makeStream()
    }

    func run(_ arguments: [String]) async -> MCPToolRunResult {
        let (wait, waitContinuation) = AsyncStream<Void>.makeStream()
        await withTaskCancellationHandler {
            startedContinuation.yield()
            for await _ in wait {}
        } onCancel: {
            waitContinuation.finish()
        }
        cancelledContinuation.yield()
        return MCPToolRunResult(exitCode: 143, stdout: "", stderr: "")
    }
}

nonisolated struct MCPHarness {
    let input = Pipe()
    let output = Pipe()
    let reader: PipeLineReader
    let serving: Task<Void, Never>

    init(runner: MCPToolRunner, flags: FeatureFlags = MCPToolCatalogTests.flagOn) {
        let server = MCPServer(
            catalog: MCPToolCatalog(payload: CapabilitiesCommand.buildPayload(flags: flags)),
            runner: runner,
            serverName: "batty",
            serverVersion: "1.5.0"
        )
        reader = PipeLineReader(output.fileHandleForReading)
        let inputHandle = input.fileHandleForReading
        let outputHandle = output.fileHandleForWriting
        serving = Task.detached {
            await server.serve(input: inputHandle, output: outputHandle)
        }
    }

    func send(_ line: String) {
        input.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    func sendRaw(_ bytes: Data) {
        input.fileHandleForWriting.write(bytes)
    }

    func reply() async throws -> MCPJSONValue {
        let line = try #require(await reader.next())
        return try JSONDecoder().decode(MCPJSONValue.self, from: Data(line.utf8))
    }

    func close() async {
        try? input.fileHandleForWriting.close()
        await serving.value
    }
}

@Suite(.timeLimit(.minutes(1)))
struct MCPServerTests {
    static let ok = MCPToolRunResult(exitCode: 0, stdout: "{\"paneID\":\"P\"}\n", stderr: "")

    private func text(_ reply: MCPJSONValue) -> String? {
        guard case let .array(content)? = reply["result"]?["content"] else { return nil }
        return content.first?["text"]?.stringValue
    }

    @Test func initializeEchoesASupportedProtocolVersionAndAdvertisesTools() async throws {
        let harness = MCPHarness(runner: ScriptedRunner(result: Self.ok))
        harness.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        let reply = try await harness.reply()
        #expect(reply["id"] == .int(1))
        #expect(reply["result"]?["protocolVersion"] == .string("2025-06-18"))
        #expect(reply["result"]?["capabilities"]?["tools"] != nil)
        #expect(reply["result"]?["serverInfo"]?["name"] == .string("batty"))
        await harness.close()
    }

    @Test func initializeWithUnknownVersionAnswersWithLatestSupported() async throws {
        let harness = MCPHarness(runner: ScriptedRunner(result: Self.ok))
        harness.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        let reply = try await harness.reply()
        #expect(reply["result"]?["protocolVersion"] == .string(MCPServer.supportedProtocolVersions[0]))
        await harness.close()
    }

    @Test func toolsListOverStdioMatchesCatalog() async throws {
        let harness = MCPHarness(runner: ScriptedRunner(result: Self.ok))
        harness.send(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)
        let reply = try await harness.reply()
        guard case let .array(tools)? = reply["result"]?["tools"] else {
            Issue.record("no tools array")
            return
        }
        let catalog = MCPToolCatalog(payload: CapabilitiesCommand.buildPayload(flags: MCPToolCatalogTests.flagOn))
        #expect(tools.compactMap { $0["name"]?.stringValue } == catalog.tools.map(\.name))
        #expect(tools == catalog.tools.map(\.listEntry))
        await harness.close()
    }

    @Test func toolsCallIdRunsTheVerbWithJSONAndReturnsItsStdout() async throws {
        let runner = ScriptedRunner(result: Self.ok)
        let harness = MCPHarness(runner: runner)
        harness.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"id","arguments":{}}}"#)
        let reply = try await harness.reply()
        #expect(text(reply) == Self.ok.stdout)
        #expect(reply["result"]?["isError"] == .bool(false))
        #expect(runner.calls.withLock { $0 } == [["id", "--json"]])
        await harness.close()
    }

    @Test func toolsCallCapabilitiesReturnsTheCapabilitiesJSON() async throws {
        let payload = CapabilitiesCommand.buildPayload(flags: MCPToolCatalogTests.flagOn)
        let json = try String(decoding: JSONEncoder().encode(payload), as: UTF8.self)
        let runner = ScriptedRunner(result: MCPToolRunResult(exitCode: 0, stdout: json, stderr: ""))
        let harness = MCPHarness(runner: runner)
        harness.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"capabilities"}}"#)
        let reply = try await harness.reply()
        let returned = try #require(text(reply))
        #expect(try JSONDecoder().decode(CapabilitiesPayload.self, from: Data(returned.utf8)) == payload)
        #expect(runner.calls.withLock { $0 } == [["capabilities", "--json"]])
        await harness.close()
    }

    @Test func nonZeroExitIsAToolErrorCarryingExitCodeMeaningAndStderr() async throws {
        let runner = ScriptedRunner(result: MCPToolRunResult(exitCode: 1, stdout: "", stderr: "batty: no such pane\n"))
        let harness = MCPHarness(runner: runner)
        harness.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"pane_focus","arguments":{"id":"X"}}}"#)
        let reply = try await harness.reply()
        #expect(reply["result"]?["isError"] == .bool(true))
        let body = try #require(text(reply))
        #expect(body.hasPrefix("exit 1: CLI-side failure"))
        #expect(body.contains("batty: no such pane"))
        await harness.close()
    }

    @Test func invalidArgumentsAreAToolErrorNotAProtocolError() async throws {
        let runner = ScriptedRunner(result: Self.ok)
        let harness = MCPHarness(runner: runner)
        harness.send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"id","arguments":{"bogus":1}}}"#)
        let reply = try await harness.reply()
        #expect(reply["result"]?["isError"] == .bool(true))
        #expect(runner.calls.withLock { $0 }.isEmpty)
        await harness.close()
    }

    @Test func unknownToolIsInvalidParams() async throws {
        let harness = MCPHarness(runner: ScriptedRunner(result: Self.ok))
        harness.send(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"mcp"}}"#)
        let reply = try await harness.reply()
        #expect(reply["error"]?["code"] == .int(-32602))
        await harness.close()
    }

    @Test func unknownMethodIsMethodNotFound() async throws {
        let harness = MCPHarness(runner: ScriptedRunner(result: Self.ok))
        harness.send(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)
        let reply = try await harness.reply()
        #expect(reply["error"]?["code"] == .int(-32601))
        #expect(reply["id"] == .int(7))
        await harness.close()
    }

    @Test func malformedLineIsParseErrorWithNullID() async throws {
        let harness = MCPHarness(runner: ScriptedRunner(result: Self.ok))
        harness.send("{not json")
        let reply = try await harness.reply()
        #expect(reply["error"]?["code"] == .int(-32700))
        #expect(reply["id"] == .null)
        await harness.close()
    }

    @Test func notificationsGetNoReply() async throws {
        let harness = MCPHarness(runner: ScriptedRunner(result: Self.ok))
        harness.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        harness.send(#"{"jsonrpc":"2.0","method":"some/unknown"}"#)
        harness.send(#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)
        let reply = try await harness.reply()
        #expect(reply["id"] == .int(8))
        await harness.close()
    }

    @Test func pingAnswersEmptyResult() async throws {
        let harness = MCPHarness(runner: ScriptedRunner(result: Self.ok))
        harness.send(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#)
        let reply = try await harness.reply()
        #expect(reply["result"] == .object([:]))
        await harness.close()
    }

    @Test func cancelledNotificationCancelsTheInFlightCall() async throws {
        let runner = SuspendingRunner()
        let harness = MCPHarness(runner: runner)
        var started = runner.started.makeAsyncIterator()
        var cancelled = runner.cancelled.makeAsyncIterator()
        harness.send(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"id"}}"#)
        _ = await started.next()
        harness.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":10}}"#)
        _ = await cancelled.next()
        harness.send(#"{"jsonrpc":"2.0","id":11,"method":"ping"}"#)
        let reply = try await harness.reply()
        #expect(reply["id"] == .int(11))
        await harness.close()
    }

    @Test(arguments: ["\u{2028}", "\u{2029}", "\u{0085}"])
    func rawLineSeparatorInsideAStringIsOneMessage(separator: String) async throws {
        let harness = MCPHarness(runner: ScriptedRunner(result: Self.ok))
        harness.send(#"{"jsonrpc":"2.0","id":7,"method":"ping","params":{"x":"a"# + separator + #"b"}}"#)
        harness.send(#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)
        let first = try await harness.reply()
        #expect(first["id"] == .int(7))
        #expect(first["result"] == .object([:]))
        #expect(first["error"] == nil)
        let second = try await harness.reply()
        #expect(second["id"] == .int(8))
        await harness.close()
    }

    @Test func loneCarriageReturnMidLineIsNotAMessageBoundary() async throws {
        let harness = MCPHarness(runner: ScriptedRunner(result: Self.ok))
        harness.send("{\"jsonrpc\":\"2.0\",\r\"id\":7,\"method\":\"ping\"}")
        harness.send(#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)
        let first = try await harness.reply()
        #expect(first["id"] == .int(7))
        #expect(first["error"] == nil)
        let second = try await harness.reply()
        #expect(second["id"] == .int(8))
        await harness.close()
    }

    @Test func crlfTerminatedLineIsParsed() async throws {
        let harness = MCPHarness(runner: ScriptedRunner(result: Self.ok))
        harness.sendRaw(Data(#"{"jsonrpc":"2.0","id":12,"method":"ping"}"#.utf8 + [0x0D, 0x0A]))
        harness.send(#"{"jsonrpc":"2.0","id":14,"method":"ping"}"#)
        let first = try await harness.reply()
        #expect(first["id"] == .int(12))
        #expect(first["result"] == .object([:]))
        let second = try await harness.reply()
        #expect(second["id"] == .int(14))
        await harness.close()
    }

    @Test func finalLineWithoutNewlineIsProcessedAtEndOfFile() async throws {
        let harness = MCPHarness(runner: ScriptedRunner(result: Self.ok))
        harness.sendRaw(Data(#"{"jsonrpc":"2.0","id":13,"method":"ping"}"#.utf8))
        await harness.close()
        let reply = try await harness.reply()
        #expect(reply["id"] == .int(13))
    }

    @Test func serveReturnsWhenInputCloses() async {
        let harness = MCPHarness(runner: ScriptedRunner(result: Self.ok))
        await harness.close()
        #expect(harness.serving.isCancelled == false)
    }
}

struct MCPLineFramerTests {
    private func frame(_ bytes: [UInt8]) -> (lines: [Data], rest: Data?) {
        var framer = MCPLineFramer()
        let lines = bytes.compactMap { framer.append($0) }
        return (lines, framer.finish())
    }

    @Test func splitsOnlyOnLineFeed() {
        let result = frame(Array("a\u{2028}b\nc\u{2029}d\u{0085}e\n".utf8))
        #expect(result.lines == [Data("a\u{2028}b".utf8), Data("c\u{2029}d\u{0085}e".utf8)])
        #expect(result.rest == nil)
    }

    @Test func dropsOneTrailingCarriageReturn() {
        #expect(frame(Array("x\r\r\n".utf8)).lines == [Data("x\r".utf8)])
        #expect(frame(Array("a\rb\n".utf8)).lines == [Data("a\rb".utf8)])
    }

    @Test func finishReturnsUnterminatedRemainderOrNil() {
        #expect(frame(Array("ab".utf8)).rest == Data("ab".utf8))
        #expect(frame(Array("ab\n".utf8)).rest == nil)
    }
}
