// StatusJSONPayloadTests.swift

import BattyXPCCore
import Foundation
import Testing

/// Covers the `batty status --json` wire shape (#0384) — both the success
/// case (encoding the real `StatusPayload`) and at least one failure state,
/// since the whole point of `--json` on `status` is producing valid JSON on
/// stdout for the failure paths too, not just the happy path every other
/// `--json` verb only has to handle.
struct StatusJSONPayloadTests {

    private static func samplePayload() -> StatusPayload {
        StatusPayload(
            pid: 4821,
            uptimeSeconds: 132.4,
            windowCount: 1,
            sessionCount: 3,
            tabCount: 7,
            bundlePath: "/Applications/Batty.app",
            appVersion: "1.4.0"
        )
    }

    // MARK: - Success

    @Test func okStateReportsZeroExitCodeAndNoMessage() {
        let json = StatusJSONPayload.ok(Self.samplePayload())
        #expect(json.state == "ok")
        #expect(json.exitCode == 0)
        #expect(json.message == nil)
        #expect(json.status == Self.samplePayload())
    }

    @Test func okJSONTopLevelKeysOmitAbsentMessage() throws {
        let json = StatusJSONPayload.ok(Self.samplePayload())
        let data = try JSONEncoder().encode(json)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["state", "exitCode", "status"], "message must be omitted, not present as null, when absent")
        let status = try #require(raw["status"] as? [String: Any])
        #expect(status["pid"] as? Int32 == 4821)
        #expect(status["bundlePath"] as? String == "/Applications/Batty.app")
    }

    @Test func okRoundTrips() throws {
        let json = StatusJSONPayload.ok(Self.samplePayload())
        let data = try JSONEncoder().encode(json)
        let decoded = try JSONDecoder().decode(StatusJSONPayload.self, from: data)
        #expect(decoded == json)
    }

    // MARK: - Failure

    @Test func brokerUnreachableFailureMatchesXPCExitCode() {
        let json = StatusJSONPayload.failure(
            state: "brokerUnreachable",
            exitCode: XPCExitCode.brokerUnreachable,
            message: "batty: broker unreachable"
        )
        #expect(json.state == "brokerUnreachable")
        #expect(json.exitCode == XPCExitCode.brokerUnreachable)
        #expect(json.exitCode == 2)
        #expect(json.message == "batty: broker unreachable")
        #expect(json.status == nil)
    }

    @Test func failureJSONOmitsStatusKeyEntirely() throws {
        let json = StatusJSONPayload.failure(
            state: "appBundleUnresolved",
            exitCode: XPCExitCode.appBundleUnresolved,
            message: "batty: could not resolve app bundle"
        )
        let data = try JSONEncoder().encode(json)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["state", "exitCode", "message"], "status must be entirely absent on a failure state, never present as null")
        #expect(raw["state"] as? String == "appBundleUnresolved")
        #expect(raw["exitCode"] as? Int32 == XPCExitCode.appBundleUnresolved)
    }

    @Test func failureRoundTrips() throws {
        let json = StatusJSONPayload.failure(state: "appRunningUnregistered", exitCode: XPCExitCode.appRunningUnregistered, message: "batty: relaunch Batty")
        let data = try JSONEncoder().encode(json)
        let decoded = try JSONDecoder().decode(StatusJSONPayload.self, from: data)
        #expect(decoded == json)
    }

    /// Every failure `state` this type is asked to represent must carry the
    /// exact numeric code `XPCExitCode` defines for it — the pinned
    /// guarantee that the JSON never disagrees with the process's real exit
    /// code (#0384's design constraint).
    @Test func everyKnownFailureStateCarriesItsXPCExitCode() {
        let cases: [(String, Int32)] = [
            ("brokerUnreachable", XPCExitCode.brokerUnreachable),
            ("appUnavailable", XPCExitCode.appUnavailable),
            ("requestFailed", XPCExitCode.requestFailed),
            ("sessionTerminated", XPCExitCode.sessionTerminated),
            ("appRunningUnregistered", XPCExitCode.appRunningUnregistered),
            ("appBundleUnresolved", XPCExitCode.appBundleUnresolved),
        ]
        for (state, code) in cases {
            let json = StatusJSONPayload.failure(state: state, exitCode: code, message: "irrelevant")
            #expect(json.state == state)
            #expect(json.exitCode == code)
        }
    }
}
