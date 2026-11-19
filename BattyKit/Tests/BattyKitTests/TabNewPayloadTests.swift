// TabNewPayloadTests.swift

import BattyXPCCore
import Foundation
import Testing

struct TabNewPayloadTests {

    @Test nonisolated func requestRoundTripsOffTheMainActor() throws {
        let request = TabNewRequest(paneID: UUID(), sourceTabID: UUID(), command: "make test", workingDirectory: "/tmp", background: true)
        let decoded = try JSONDecoder().decode(TabNewRequest.self, from: try JSONEncoder().encode(request))
        #expect(decoded == request)
    }

    @Test nonisolated func replyRoundTripsOffTheMainActor() throws {
        let reply = TabNewReply(sessionID: UUID(), paneID: UUID(), tabID: UUID())
        let decoded = try JSONDecoder().decode(TabNewReply.self, from: try JSONEncoder().encode(reply))
        #expect(decoded == reply)
    }

    @Test nonisolated func replyDecodesWhenALaterBuildAddsFields() throws {
        let ids = (UUID(), UUID(), UUID())
        let json = #"{"sessionID":"\#(ids.0)","paneID":"\#(ids.1)","tabID":"\#(ids.2)","exitCode":0}"#
        let decoded = try JSONDecoder().decode(TabNewReply.self, from: Data(json.utf8))
        #expect(decoded == TabNewReply(sessionID: ids.0, paneID: ids.1, tabID: ids.2))
    }

    @Test nonisolated func xpcVerbTabNewLiteral() {
        #expect(XPCVerb.tabNew == "tabNew")
    }
}
