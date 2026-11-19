// AppXPCServiceTabNewTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct AppXPCServiceTabNewTests {

    private func perform(_ store: AppStateStore, payload: Data?) async throws -> XPCResponse {
        let service = AppXPCService(store: { store })
        let requestData = try JSONEncoder().encode(XPCRequest(verb: XPCVerb.tabNew, payload: payload))
        let responseData: Data = await withCheckedContinuation { continuation in
            service.perform(requestData) { data in
                continuation.resume(returning: data)
            }
        }
        return try JSONDecoder().decode(XPCResponse.self, from: responseData)
    }

    private func perform(_ store: AppStateStore, _ request: TabNewRequest) async throws -> XPCResponse {
        try await perform(store, payload: try JSONEncoder().encode(request))
    }

    @Test func performTabNewRepliesWithSessionPaneAndTabIDs() async throws {
        let store = AppStateStore()
        let session = store.sessions[0]
        let pane = session.focusedPaneAnyKind

        let response = try await perform(store, TabNewRequest(paneID: pane.id, sourceTabID: nil, command: "top", workingDirectory: nil, background: nil))

        #expect(response.ok == true)
        let reply = try JSONDecoder().decode(TabNewReply.self, from: try #require(response.payload))
        #expect(reply.sessionID == session.id)
        #expect(reply.paneID == pane.id)
        #expect(pane.activeTabID == reply.tabID)
    }

    @Test func performTabNewWithoutAPaneIDTargetsTheFocusedPane() async throws {
        let store = AppStateStore()
        let focused = try #require(store.focusedPaneIDFallback())

        let response = try await perform(store, TabNewRequest(paneID: nil, sourceTabID: nil, command: nil, workingDirectory: nil, background: nil))

        let reply = try JSONDecoder().decode(TabNewReply.self, from: try #require(response.payload))
        #expect(reply.paneID == focused)
    }

    @Test func performTabNewOnAnUnknownPaneFails() async throws {
        let response = try await perform(AppStateStore(), TabNewRequest(paneID: UUID(), sourceTabID: nil, command: nil, workingDirectory: nil, background: nil))
        #expect(response.ok == false)
        #expect(response.error == "unknown pane id")
    }

    @Test func performTabNewOnANonTerminalPaneFails() async throws {
        let store = AppStateStore()
        let split = store.splitPane(id: store.sessions[0].focusedPaneAnyKind.id, direction: .horizontal, kind: .gitStatus, contentFactory: { _ in nil })
        let gitPaneID = try #require(split)

        let response = try await perform(store, TabNewRequest(paneID: gitPaneID, sourceTabID: nil, command: nil, workingDirectory: nil, background: nil))

        #expect(response.ok == false)
        #expect(response.error == "pane is not a terminal pane")
    }

    @Test func performTabNewWithAMalformedPayloadFails() async throws {
        let response = try await perform(AppStateStore(), payload: Data("not json".utf8))
        #expect(response.ok == false)
        #expect(response.error == "malformed tab new request")
    }
}
