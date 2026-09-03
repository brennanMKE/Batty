// AppXPCServicePaneSplitUniqueTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `AppXPCService.perform`'s `paneSplit` case (#0383 review) — the
/// only tests anywhere in `BattyKitTests` that exercise `AppXPCService`
/// directly rather than `AppStateStore` alone.
///
/// `AppXPCService.perform` hardcodes `AppStateStore.shared`, not an
/// injectable store (unlike `AppStateStore`'s own methods, which every
/// other pane-split test exercises via a throwaway `AppStateStore()`), so
/// reaching this handler at all means mutating the process-wide singleton.
/// Reviewed twice:
///
/// - **Round 1** shipped `@Suite(.serialized)` with both tests reading
///   `sessions[0]`. That is *not* sufficient, only accidentally
///   flake-free: `.serialized` only serializes *within this suite* — a
///   throwaway adversarial suite that also splits panes on `.shared`
///   (simulating any future test touching it, directly or transitively
///   through `AppXPCService`, `BattyShortcuts`, `BattyCommands`,
///   `WindowIDRegistrar.registerNSWindow`, `TerminalClickFocusMonitor`,
///   `RootWindowView`, or `CommandPaletteView`) reproduced the exact same
///   race against `sessions[0]` with `.serialized` still in place.
/// - **Round 2** (this version) gives each test its **own** Session via
///   `AppStateStore.shared.addSession(title:)!` — the same pattern
///   `AppStateStorePaneSplitTests`' `findUniquePaneDoesNotMatchAcrossSessions`
///   already uses — and asserts against that session object instead of
///   `sessions[0]`. `.serialized` is removed entirely: two tests that
///   never share a Session cannot race each other on Session/Pane state
///   regardless of execution order, and this suite makes no assumption
///   about `.shared`'s pane *count* at all, only about the Session it
///   created for itself. Verified green twice with the round-1
///   adversarial probe suite still present and running unserialized
///   alongside it.
struct AppXPCServicePaneSplitUniqueTests {

    private func performPaneSplit(_ request: PaneSplitRequest) async throws -> XPCResponse {
        let service = AppXPCService()
        let requestData = try JSONEncoder().encode(XPCRequest(verb: XPCVerb.paneSplit, payload: try JSONEncoder().encode(request)))
        let responseData: Data = await withCheckedContinuation { continuation in
            service.perform(requestData) { data in
                continuation.resume(returning: data)
            }
        }
        return try JSONDecoder().decode(XPCResponse.self, from: responseData)
    }

    @Test func performPaneSplitWithUniqueMatchReturnsTheExistingPaneAndCreatesNothing() async throws {
        let session = AppStateStore.shared.addSession(title: "AppXPCServicePaneSplitUniqueTests-match")!
        let target = session.focusedPaneAnyKind.id
        let existing = AppStateStore.shared.splitPane(id: target, direction: .horizontal, kind: .gitStatus, contentFactory: { _ in nil })
        let beforeCount = session.tree.allPanes.count

        let response = try await performPaneSplit(PaneSplitRequest(paneID: target, direction: .horizontal, kind: .gitStatus, unique: true))

        #expect(response.ok == true)
        let reply = try JSONDecoder().decode(PaneSplitReply.self, from: try #require(response.payload))
        #expect(reply.paneID == existing)
        #expect(reply.created == false)
        #expect(session.tree.allPanes.count == beforeCount,
                "a matched --unique must not create a new pane")
    }

    @Test func performPaneSplitWithUniqueTrueAndTerminalKindFallsThroughToCreating() async throws {
        let session = AppStateStore.shared.addSession(title: "AppXPCServicePaneSplitUniqueTests-terminal")!
        let target = session.focusedPaneAnyKind.id
        let beforeCount = session.tree.allPanes.count

        // `kind` omitted (nil) means terminal, matching the CLI's own
        // default-to-terminal encoding — `findUniquePane` guards `kind !=
        // .terminal`, so this must fall through to an ordinary create
        // rather than matching the target pane itself.
        let response = try await performPaneSplit(PaneSplitRequest(paneID: target, direction: .horizontal, unique: true))

        #expect(response.ok == true)
        let reply = try JSONDecoder().decode(PaneSplitReply.self, from: try #require(response.payload))
        #expect(reply.paneID != target, "must actually split, not return the caller's own pane id")
        #expect(reply.created == true)
        #expect(session.tree.allPanes.count == beforeCount + 1)
    }

    /// Tidiness item from #0383's own Notes: "an existing test asserting
    /// that omitting `--view` keeps every split a terminal split must
    /// still pass, and a `--view` split without `--unique` must still
    /// produce a second Pane." The model-layer tests
    /// (`AppStateStorePaneSplitTests`) and the fall-through case above
    /// cover this implicitly; this is the explicit XPC-layer version with
    /// `unique` left `nil` altogether (not merely `false`), matching what
    /// the CLI actually sends when `--unique` is omitted.
    @Test func performPaneSplitWithUniqueNilAlwaysCreates() async throws {
        let session = AppStateStore.shared.addSession(title: "AppXPCServicePaneSplitUniqueTests-nil")!
        let target = session.focusedPaneAnyKind.id
        let beforeCount = session.tree.allPanes.count

        let response = try await performPaneSplit(PaneSplitRequest(paneID: target, direction: .horizontal, kind: .gitStatus))

        #expect(response.ok == true)
        let reply = try JSONDecoder().decode(PaneSplitReply.self, from: try #require(response.payload))
        #expect(reply.paneID != target)
        #expect(reply.created == true)
        #expect(session.tree.allPanes.count == beforeCount + 1)

        // Running the identical request again must create a *second* new
        // pane, not find-or-create it — `unique: nil` never dedupes.
        let secondResponse = try await performPaneSplit(PaneSplitRequest(paneID: target, direction: .horizontal, kind: .gitStatus))
        let secondReply = try JSONDecoder().decode(PaneSplitReply.self, from: try #require(secondResponse.payload))
        #expect(secondReply.paneID != reply.paneID)
        #expect(secondReply.created == true)
        #expect(session.tree.allPanes.count == beforeCount + 2)
    }
}
