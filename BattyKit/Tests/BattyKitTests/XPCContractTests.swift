// XPCContractTests.swift

import Foundation
import Testing
@testable import BattyKit

// MARK: - Off-actor compile-time isolation guards
//
// Every `@Test` below runs on the MainActor — this test target inherits the
// package's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` swiftSettings
// (`Package.swift`) — so none of them would notice a future edit that drops
// `nonisolated` from `XPCRequest`/`XPCResponse` or a protocol requirement in
// `XPCProtocols.swift`: a MainActor caller compiles fine against
// main-actor-isolated declarations too. These free functions exist purely
// to fail to *compile* if that discipline regresses — merely including them
// in this file is the guard for the protocol call sites; the round-trip
// helpers are additionally exercised by a `@Test` below so the behavior
// (not just the compile) is checked.

private nonisolated func roundTripOffActor(_ request: XPCRequest) throws -> XPCRequest {
    let data = try JSONEncoder().encode(request)
    return try JSONDecoder().decode(XPCRequest.self, from: data)
}

private nonisolated func roundTripOffActor(_ response: XPCResponse) throws -> XPCResponse {
    let data = try JSONEncoder().encode(response)
    return try JSONDecoder().decode(XPCResponse.self, from: data)
}

private nonisolated func callOffActor(_ broker: any BrokerProtocol) {
    broker.brokerPing { _ in }
}

private nonisolated func callOffActor(_ appService: any AppServiceProtocol) {
    appService.perform(Data()) { _ in }
}

/// No XPC involved — pure round-trip and constant-derivation checks for the
/// shared contract in `BattyXPCCore` (#0269).
struct XPCContractTests {

    // MARK: - XPCRequest / XPCResponse round trips

    @Test func xpcRequestRoundTripsWithoutPayload() throws {
        let request = XPCRequest(verb: "status")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(XPCRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.verb == "status")
        #expect(decoded.payload == nil)
    }

    @Test func xpcRequestRoundTripsWithPayload() throws {
        let payload = Data("{\"foo\":1}".utf8)
        let request = XPCRequest(verb: "example", payload: payload)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(XPCRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.payload == payload)
    }

    @Test func xpcResponseRoundTripsSuccess() throws {
        let payload = Data("{\"pid\":123}".utf8)
        let response = XPCResponse(ok: true, payload: payload)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(XPCResponse.self, from: data)
        #expect(decoded == response)
        #expect(decoded.ok)
        #expect(decoded.error == nil)
    }

    @Test func xpcResponseRoundTripsFailure() throws {
        let response = XPCResponse(ok: false, error: "app unavailable")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(XPCResponse.self, from: data)
        #expect(decoded == response)
        #expect(!decoded.ok)
        #expect(decoded.payload == nil)
        #expect(decoded.error == "app unavailable")
    }

    @Test func xpcRequestRoundTripsOffActor() throws {
        let decoded = try roundTripOffActor(XPCRequest(verb: "status"))
        #expect(decoded.verb == "status")
    }

    @Test func xpcResponseRoundTripsOffActor() throws {
        let decoded = try roundTripOffActor(XPCResponse(ok: true))
        #expect(decoded.ok)
    }

    // MARK: - ServiceNames derivation

    @Test func serviceNamesAgentLabelEqualsBroker() {
        #expect(ServiceNames.agentLabel == ServiceNames.broker)
    }

    @Test func serviceNamesPlistNameIsDerivedFromAgentLabel() {
        // Asserts the actual derivation relationship (plist name = label +
        // ".plist"), not just that the two happen to hold equal literals —
        // recomputing it here from `agentLabel` catches a future edit that
        // reintroduces an independently repeated literal for one of the
        // three constants.
        #expect(ServiceNames.agentPlistName == "\(ServiceNames.agentLabel).plist")
        #expect(ServiceNames.agentPlistName == "\(ServiceNames.broker).plist")
    }

    @Test func serviceNamesAllFourDerivedStringsAreIdentical() {
        // The "four strings" are: plist filename, plist Label, MachServices
        // key, and the connect-time name. The plist filename and Label are
        // represented here by `agentPlistName`/`agentLabel`; the
        // MachServices key and connect-time name are both `broker` itself
        // (the same constant used at both call sites, not two literals).
        let plistFilenameStem = ServiceNames.agentPlistName.replacingOccurrences(of: ".plist", with: "")
        #expect(plistFilenameStem == ServiceNames.agentLabel)
        #expect(ServiceNames.agentLabel == ServiceNames.broker)
    }

    // MARK: - XPCExitCode

    @Test func xpcExitCodeVocabulary() {
        #expect(XPCExitCode.brokerUnreachable == 2)
        #expect(XPCExitCode.appUnavailable == 3)
        #expect(XPCExitCode.requestFailed == 4)
        #expect(XPCExitCode.sessionTerminated == 5)
    }

    @Test func xpcExitCodesAreDistinct() {
        let codes: Set<Int32> = [
            XPCExitCode.brokerUnreachable,
            XPCExitCode.appUnavailable,
            XPCExitCode.requestFailed,
            XPCExitCode.sessionTerminated,
        ]
        #expect(codes.count == 4)
    }
}
