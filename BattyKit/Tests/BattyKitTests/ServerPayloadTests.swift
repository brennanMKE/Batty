// ServerPayloadTests.swift

import BattyXPCCore
import Foundation
import Testing

private nonisolated func roundTripOffActor<T: Codable & Sendable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(value))
}

struct ServerPayloadTests {
    @Test func requestsRoundTripOffTheMainActor() throws {
        let start = ServerStartRequest(paneID: UUID(), port: 8083, command: "go run .", workingDirectory: "/tmp/site", url: "http://localhost:8083/app", statsURL: nil, split: .down, wait: true, waitTimeoutSeconds: 30)
        #expect(try roundTripOffActor(start) == start)
        let attach = ServerAttachRequest(port: 9000, command: "npm start", workingDirectory: "/tmp/web", split: .right)
        #expect(try roundTripOffActor(attach) == attach)
        let control = ServerControlRequest(paneID: UUID(), port: 8083)
        #expect(try roundTripOffActor(control) == control)
        let reply = ServerReply(paneID: UUID(), terminalPaneID: UUID(), tabID: UUID(), url: "http://localhost:8083/", pid: 42, state: .listening, exitCode: nil, created: true)
        #expect(try roundTripOffActor(reply) == reply)
    }

    @Test func serveRequestRoundTrips() throws {
        let serve = ServerServeRequest(paneID: UUID(), root: "/tmp/site", port: 8000, open: true, inject: false, split: .down)
        #expect(try roundTripOffActor(serve) == serve)
        let reply = ServerReply(paneID: UUID(), url: "http://127.0.0.1:8000/", state: .listening, created: true, root: "/tmp/site")
        #expect(try roundTripOffActor(reply) == reply)
    }

    @Test func replyWithoutRootDecodes() throws {
        let reply = try JSONDecoder().decode(ServerReply.self, from: Data(#"{"paneID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","url":"u","state":"listening","created":false}"#.utf8))
        #expect(reply.root == nil)
        let serve = try JSONDecoder().decode(ServerServeRequest.self, from: Data(#"{"root":"/x"}"#.utf8))
        #expect(serve.port == nil)
        #expect(serve.inject == nil)
    }

    @Test func absentOptionalKeysDecodeAsNil() throws {
        let start = try JSONDecoder().decode(ServerStartRequest.self, from: Data(#"{"port":1,"command":"x","workingDirectory":"/"}"#.utf8))
        #expect(start.paneID == nil)
        #expect(start.split == nil)
        #expect(start.wait == nil)
        let attach = try JSONDecoder().decode(ServerAttachRequest.self, from: Data(#"{"port":1}"#.utf8))
        #expect(attach.command == nil)
        #expect(attach.workingDirectory == nil)
    }
}
