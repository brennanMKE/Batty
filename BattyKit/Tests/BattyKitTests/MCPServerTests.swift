// MCPServerTests.swift

import BattyXPCCore
import Foundation
import os
import BattyCLICore
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

    /// `nil` at end of file or when `bound` passes first.
    func next(bound: TimeInterval = TestBounds.hangGuard) async -> String? {
        await awaitBoundedValue(bound: bound) { await self.nextLine() }.flatMap { $0 }
    }

    private func nextLine() async -> String? {
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

    init(runner: MCPToolRunner, flags: FeatureFlags = MCPToolCatalogTests.flagOn, environment: [String: String] = [:]) {
        let catalog = MCPToolCatalog(payload: CapabilitiesCommand.buildPayload(flags: flags))
        let server = MCPServer(
            catalog: catalog,
            runner: runner,
            serverName: "batty",
            serverVersion: "1.5.0",
            instructions: MCPInstructions.text(environment: environment, catalog: catalog, cliName: "batty")
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

    func reply(_ step: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> MCPJSONValue {
        let line = try #require(await reader.next(), "no reply for \(step) within \(TestBounds.hangGuard)s", sourceLocation: sourceLocation)
        return try JSONDecoder().decode(MCPJSONValue.self, from: Data(line.utf8))
    }

    func awaitSignal(_ stream: AsyncStream<Void>, _ step: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let signalled = await awaitBoundedValue { () -> Bool in
            for await _ in stream { return true }
            return false
        }
        try #require(signalled == true, "no signal for \(step) within \(TestBounds.hangGuard)s", sourceLocation: sourceLocation)
    }

    /// Idempotent: closes input, awaits the serve loop, then closes output.
    func close() async {
        try? input.fileHandleForWriting.close()
        let serving = serving
        let returned = await awaitBounded { await serving.value }
        if !returned {
            Issue.record("serve did not return after input closed")
            serving.cancel()
        }
        try? output.fileHandleForWriting.close()
    }

    static func withHarness<T>(
        runner: MCPToolRunner,
        flags: FeatureFlags = MCPToolCatalogTests.flagOn,
        environment: [String: String] = [:],
        _ body: (MCPHarness) async throws -> T
    ) async throws -> T {
        let harness = MCPHarness(runner: runner, flags: flags, environment: environment)
        do {
            let value = try await body(harness)
            await harness.close()
            return value
        } catch {
            await harness.close()
            throw error
        }
    }
}

@Suite(.timeLimit(.minutes(2)))
nonisolated struct MCPServerTests {
    static let ok = MCPToolRunResult(exitCode: 0, stdout: "{\"paneID\":\"P\"}\n", stderr: "")

    private func text(_ reply: MCPJSONValue) -> String? {
        guard case let .array(content)? = reply["result"]?["content"] else { return nil }
        return content.first?["text"]?.stringValue
    }

    @Test func initializeEchoesASupportedProtocolVersionAndAdvertisesTools() async throws {
        try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok)) { harness in
            harness.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
            let reply = try await harness.reply("initialize")
            #expect(reply["id"] == .int(1))
            #expect(reply["result"]?["protocolVersion"] == .string("2025-06-18"))
            #expect(reply["result"]?["capabilities"]?["tools"] != nil)
            #expect(reply["result"]?["serverInfo"]?["name"] == .string("batty"))
        }
    }

    static let sessionID = "11111111-1111-1111-1111-111111111111"
    static let tabID = "22222222-2222-2222-2222-222222222222"
    static let paneID = "33333333-3333-3333-3333-333333333333"
    static let inBatty = [
        BattyContextEnvironmentKey.sessionID.rawValue: sessionID,
        BattyContextEnvironmentKey.tabID.rawValue: tabID,
        BattyContextEnvironmentKey.paneID.rawValue: paneID,
    ]

    private func initializeInstructions(environment: [String: String]) async throws -> String {
        try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok), environment: environment) { harness in
            harness.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
            let reply = try await harness.reply("initialize")
            return try #require(reply["result"]?["instructions"]?.stringValue)
        }
    }

    @Test func initializeInstructionsNameSessionTabAndPaneInBatty() async throws {
        let text = try await initializeInstructions(environment: Self.inBatty)
        for needle in [Self.sessionID, Self.tabID, Self.paneID, "terminal Pane of Batty", "`pane_split`", "`server_start`", "`notify`", "`session_remind`"] {
            #expect(text.contains(needle), "missing \(needle)")
        }
        #expect(!text.contains("not running in a Batty Pane"))
    }

    @Test func initializeInstructionsOutsideBattySayNotAndNameNoIDs() async throws {
        let text = try await initializeInstructions(environment: [:])
        #expect(text.contains("not running in a Batty Pane"))
        #expect(text.contains("`pane_split`"))
        for id in [Self.sessionID, Self.tabID, Self.paneID] {
            #expect(!text.uppercased().contains(id))
        }
        #expect(!text.contains("Session: "))
    }

    @Test func initializeWithUnknownVersionAnswersWithLatestSupported() async throws {
        try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok)) { harness in
            harness.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
            let reply = try await harness.reply("initialize (unknown version)")
            #expect(reply["result"]?["protocolVersion"] == .string(MCPServer.supportedProtocolVersions[0]))
        }
    }

    @Test func toolsListOverStdioMatchesCatalog() async throws {
        try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok)) { harness in
            harness.send(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)
            let reply = try await harness.reply("tools/list")
            guard case let .array(tools)? = reply["result"]?["tools"] else {
                Issue.record("no tools array")
                return
            }
            let catalog = MCPToolCatalog(payload: CapabilitiesCommand.buildPayload(flags: MCPToolCatalogTests.flagOn))
            #expect(tools.compactMap { $0["name"]?.stringValue } == catalog.tools.map(\.name))
            #expect(tools == catalog.tools.map(\.listEntry))
        }
    }

    @Test func toolsCallIdRunsTheVerbWithJSONAndReturnsItsStdout() async throws {
        let runner = ScriptedRunner(result: Self.ok)
        try await MCPHarness.withHarness(runner: runner) { harness in
            harness.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"id","arguments":{}}}"#)
            let reply = try await harness.reply("tools/call id")
            #expect(text(reply) == Self.ok.stdout)
            #expect(reply["result"]?["isError"] == .bool(false))
            #expect(runner.calls.withLock { $0 } == [["id", "--json"]])
        }
    }

    @Test func toolsCallCapabilitiesReturnsTheCapabilitiesJSON() async throws {
        let payload = CapabilitiesCommand.buildPayload(flags: MCPToolCatalogTests.flagOn)
        let json = try String(decoding: JSONEncoder().encode(payload), as: UTF8.self)
        let runner = ScriptedRunner(result: MCPToolRunResult(exitCode: 0, stdout: json, stderr: ""))
        try await MCPHarness.withHarness(runner: runner) { harness in
            harness.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"capabilities"}}"#)
            let reply = try await harness.reply("tools/call capabilities")
            let returned = try #require(text(reply))
            #expect(try JSONDecoder().decode(CapabilitiesPayload.self, from: Data(returned.utf8)) == payload)
            #expect(runner.calls.withLock { $0 } == [["capabilities", "--json"]])
        }
    }

    @Test func nonZeroExitIsAToolErrorCarryingExitCodeMeaningAndStderr() async throws {
        let runner = ScriptedRunner(result: MCPToolRunResult(exitCode: 1, stdout: "", stderr: "batty: no such pane\n"))
        try await MCPHarness.withHarness(runner: runner) { harness in
            harness.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"pane_focus","arguments":{"id":"X"}}}"#)
            let reply = try await harness.reply("tools/call pane_focus")
            #expect(reply["result"]?["isError"] == .bool(true))
            let body = try #require(text(reply))
            #expect(body.hasPrefix("exit 1: CLI-side failure"))
            #expect(body.contains("batty: no such pane"))
        }
    }

    @Test func invalidArgumentsAreAToolErrorNotAProtocolError() async throws {
        let runner = ScriptedRunner(result: Self.ok)
        try await MCPHarness.withHarness(runner: runner) { harness in
            harness.send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"id","arguments":{"bogus":1}}}"#)
            let reply = try await harness.reply("tools/call bogus arguments")
            #expect(reply["result"]?["isError"] == .bool(true))
            #expect(runner.calls.withLock { $0 }.isEmpty)
        }
    }

    @Test func unknownToolIsInvalidParams() async throws {
        try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok)) { harness in
            harness.send(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"mcp"}}"#)
            let reply = try await harness.reply("tools/call unknown tool")
            #expect(reply["error"]?["code"] == .int(-32602))
        }
    }

    @Test func unknownMethodIsMethodNotFound() async throws {
        try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok)) { harness in
            harness.send(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)
            let reply = try await harness.reply("resources/list")
            #expect(reply["error"]?["code"] == .int(-32601))
            #expect(reply["id"] == .int(7))
        }
    }

    @Test func malformedLineIsParseErrorWithNullID() async throws {
        try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok)) { harness in
            harness.send("{not json")
            let reply = try await harness.reply("malformed line")
            #expect(reply["error"]?["code"] == .int(-32700))
            #expect(reply["id"] == .null)
        }
    }

    @Test func notificationsGetNoReply() async throws {
        try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok)) { harness in
            harness.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            harness.send(#"{"jsonrpc":"2.0","method":"some/unknown"}"#)
            harness.send(#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)
            let reply = try await harness.reply("ping (id 8)")
            #expect(reply["id"] == .int(8))
        }
    }

    @Test func pingAnswersEmptyResult() async throws {
        try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok)) { harness in
            harness.send(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#)
            let reply = try await harness.reply("ping (id 9)")
            #expect(reply["result"] == .object([:]))
        }
    }

    @Test func cancelledNotificationCancelsTheInFlightCall() async throws {
        let runner = SuspendingRunner()
        try await MCPHarness.withHarness(runner: runner) { harness in
            harness.send(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"id"}}"#)
            try await harness.awaitSignal(runner.started, "runner started")
            harness.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":10}}"#)
            try await harness.awaitSignal(runner.cancelled, "runner saw cancellation")
            harness.send(#"{"jsonrpc":"2.0","id":11,"method":"ping"}"#)
            let reply = try await harness.reply("ping after cancel (id 11)")
            #expect(reply["id"] == .int(11))
        }
    }

    @Test(arguments: ["\u{2028}", "\u{2029}", "\u{0085}"])
    func rawLineSeparatorInsideAStringIsOneMessage(separator: String) async throws {
        try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok)) { harness in
            harness.send(#"{"jsonrpc":"2.0","id":7,"method":"ping","params":{"x":"a"# + separator + #"b"}}"#)
            harness.send(#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)
            let first = try await harness.reply("ping with separator (id 7)")
            #expect(first["id"] == .int(7))
            #expect(first["result"] == .object([:]))
            #expect(first["error"] == nil)
            let second = try await harness.reply("ping (id 8)")
            #expect(second["id"] == .int(8))
        }
    }

    @Test func loneCarriageReturnMidLineIsNotAMessageBoundary() async throws {
        try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok)) { harness in
            harness.send("{\"jsonrpc\":\"2.0\",\r\"id\":7,\"method\":\"ping\"}")
            harness.send(#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)
            let first = try await harness.reply("ping with lone CR (id 7)")
            #expect(first["id"] == .int(7))
            #expect(first["error"] == nil)
            let second = try await harness.reply("ping (id 8)")
            #expect(second["id"] == .int(8))
        }
    }

    @Test func crlfTerminatedLineIsParsed() async throws {
        try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok)) { harness in
            harness.sendRaw(Data(#"{"jsonrpc":"2.0","id":12,"method":"ping"}"#.utf8 + [0x0D, 0x0A]))
            harness.send(#"{"jsonrpc":"2.0","id":14,"method":"ping"}"#)
            let first = try await harness.reply("CRLF ping (id 12)")
            #expect(first["id"] == .int(12))
            #expect(first["result"] == .object([:]))
            let second = try await harness.reply("ping (id 14)")
            #expect(second["id"] == .int(14))
        }
    }

    @Test func finalLineWithoutNewlineIsProcessedAtEndOfFile() async throws {
        try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok)) { harness in
            harness.sendRaw(Data(#"{"jsonrpc":"2.0","id":13,"method":"ping"}"#.utf8))
            await harness.close()
            let reply = try await harness.reply("unterminated ping (id 13)")
            #expect(reply["id"] == .int(13))
        }
    }

    @Test func serveReturnsWhenInputCloses() async throws {
        try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok)) { harness in
            await harness.close()
            #expect(harness.serving.isCancelled == false)
        }
    }

    @Test func idleInputOnOneServerDoesNotStallAnother() async throws {
        try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok)) { idle in
            idle.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
            let first = try await idle.reply("ping on A")
            #expect(first["id"] == .int(1))
            try await MCPHarness.withHarness(runner: ScriptedRunner(result: Self.ok)) { other in
                other.send(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
                let second = try await other.reply("ping on B while A idles")
                #expect(second["id"] == .int(2))
            }
        }
    }
}

nonisolated struct MCPLineFramerTests {
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
