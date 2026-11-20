// ServerPayloadTests.swift

import BattyXPCCore
import Foundation
import Testing

private nonisolated func roundTripOffActor<T: Codable & Sendable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(value))
}

struct ServerPayloadTests {
    @Test func requestsRoundTripOffTheMainActor() throws {
        let start = ServerStartRequest(paneID: UUID(), port: 8083, command: "go run .", workingDirectory: "/tmp/site", url: "http://localhost:8083/app", name: "site", split: .down, processView: false, wait: true, waitTimeoutSeconds: 30)
        #expect(try roundTripOffActor(start) == start)
        let share = ServerShareRequest(paneID: UUID(), port: 9000, url: "http://localhost:9000/", name: "web", split: .right, processView: false)
        #expect(try roundTripOffActor(share) == share)
        let control = ServerControlRequest(paneID: UUID(), port: 8083)
        #expect(try roundTripOffActor(control) == control)
        let reply = ServerReply(serverID: UUID(), terminalPaneID: UUID(), tabID: UUID(), url: "http://localhost:8083/", pid: 42, state: .listening, exitCode: nil, created: true, name: "go", kind: .terminal, processPaneID: UUID())
        #expect(try roundTripOffActor(reply) == reply)
    }

    @Test func listReplyRoundTrips() throws {
        let reply = ServerListReply(servers: [
            ServerListItem(serverID: UUID(), name: "go", port: 8083, kind: .terminal, state: .listening, url: "http://127.0.0.1:8083/", pid: 42, terminalPaneID: UUID(), processPaneID: UUID()),
            ServerListItem(serverID: UUID(), name: "Port 9000", port: 9000, kind: .external, state: .starting, url: "http://127.0.0.1:9000/", tailnetURL: "https://host.tailnet.ts.net:9000/"),
            ServerListItem(serverID: UUID(), name: "site", port: 8000, kind: .static, state: .listening, url: "http://127.0.0.1:8000/"),
        ])
        #expect(try roundTripOffActor(reply) == reply)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any]
        let kinds = (object?["servers"] as? [[String: Any]])?.compactMap { $0["kind"] as? String }
        #expect(kinds == ["terminal", "external", "static"])
    }

    @Test func replyWithoutNewFieldsDecodes() throws {
        let reply = try JSONDecoder().decode(ServerReply.self, from: Data(#"{"serverID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","url":"u","state":"listening","created":true,"terminalPaneID":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}"#.utf8))
        #expect(reply.name == nil)
        #expect(reply.kind == nil)
        #expect(reply.processPaneID == nil)
    }

    @Test func serveRequestRoundTrips() throws {
        let serve = ServerServeRequest(paneID: UUID(), root: "/tmp/site", port: 8000, open: true, inject: false, split: .down)
        #expect(try roundTripOffActor(serve) == serve)
        let reply = ServerReply(serverID: UUID(), url: "http://127.0.0.1:8000/", state: .listening, created: true, root: "/tmp/site")
        #expect(try roundTripOffActor(reply) == reply)
    }

    @Test func replyWithoutRootDecodes() throws {
        let reply = try JSONDecoder().decode(ServerReply.self, from: Data(#"{"serverID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","url":"u","state":"listening","created":false}"#.utf8))
        #expect(reply.root == nil)
        let serve = try JSONDecoder().decode(ServerServeRequest.self, from: Data(#"{"root":"/x"}"#.utf8))
        #expect(serve.port == nil)
        #expect(serve.inject == nil)
    }

    @Test func replyEncodesServerIDNotPaneID() throws {
        let reply = ServerReply(serverID: UUID(), url: "http://127.0.0.1:8000/", state: .listening, created: true)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any]
        #expect(object?["serverID"] as? String == reply.serverID.uuidString)
        #expect(object?["paneID"] == nil)
    }

    @Test func controlRequestRoundTripsServerID() throws {
        let control = ServerControlRequest(serverID: UUID())
        #expect(try roundTripOffActor(control) == control)
    }

    @Test func absentOptionalKeysDecodeAsNil() throws {
        let start = try JSONDecoder().decode(ServerStartRequest.self, from: Data(#"{"port":1,"command":"x","workingDirectory":"/"}"#.utf8))
        #expect(start.paneID == nil)
        #expect(start.split == nil)
        #expect(start.wait == nil)
        #expect(start.name == nil)
        #expect(start.processView == nil)
        let share = try JSONDecoder().decode(ServerShareRequest.self, from: Data(#"{"port":1}"#.utf8))
        #expect(share.paneID == nil)
        #expect(share.name == nil)
        #expect(share.processView == nil)
    }
}
