// MCPInputTests.swift

import Foundation
import Testing
@testable import batty

@Suite(.timeLimit(.minutes(2)))
nonisolated struct MCPInputTests {
    private func collect(_ handle: FileHandle) async throws -> Data {
        let stream = MCPInput.chunks(from: handle)
        return try #require(await awaitBoundedValue {
            var all = Data()
            for await chunk in stream { all.append(chunk) }
            return all
        }, "chunks did not finish at end of file")
    }

    @Test func pipeChunksArriveAndFinishAtEndOfFile() async throws {
        let pipe = Pipe()
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let writer = pipe.fileHandleForWriting
        let writing = Task.detached {
            writer.write(payload)
            try? writer.close()
        }
        let received = try await collect(pipe.fileHandleForReading)
        await writing.value
        #expect(received == payload)
    }

    @Test func regularFileIsReadToEndOfFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("input.jsonl")
        let payload = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8 + [0x0A])
        try payload.write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        #expect(try await collect(handle) == payload)
    }

    @Test func cancellingTheConsumerClearsTheReadabilityHandler() async {
        let pipe = Pipe()
        let handle = pipe.fileHandleForReading
        let stream = MCPInput.chunks(from: handle)
        #expect(handle.readabilityHandler != nil)
        let consumer = Task {
            for await _ in stream {}
        }
        consumer.cancel()
        await consumer.value
        #expect(handle.readabilityHandler == nil)
        try? pipe.fileHandleForWriting.close()
    }
}
