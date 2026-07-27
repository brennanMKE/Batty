// BattyTargetResolverTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers the explicit-flag → `BATTY_*` env → focused-element (`nil`)
/// chain (#0257 Foundation §2, built by #0281) — env injected for
/// hermeticity. `session info` (#0274 retrofit), and later `pane split`/
/// `pane close` (#0282/#0283), all consume this same logic.
struct BattyTargetResolverTests {

    @Test func explicitFlagWinsOverEnv() {
        let flagID = UUID()
        let envID = UUID()
        let result = BattyTargetResolver.resolve(
            flag: flagID.uuidString,
            environmentKey: .sessionID,
            environment: ["BATTY_SESSION_ID": envID.uuidString]
        )
        guard case let .success(resolved) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(resolved == flagID)
    }

    @Test func envUsedWhenNoFlag() {
        let envID = UUID()
        let result = BattyTargetResolver.resolve(
            flag: nil,
            environmentKey: .paneID,
            environment: ["BATTY_PANE_ID": envID.uuidString]
        )
        guard case let .success(resolved) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(resolved == envID)
    }

    @Test func fallsThroughToNilWhenNeitherFlagNorEnvPresent() {
        let result = BattyTargetResolver.resolve(flag: nil, environmentKey: .tabID, environment: [:])
        guard case let .success(resolved) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(resolved == nil)
    }

    @Test func malformedFlagErrors() {
        let result = BattyTargetResolver.resolve(
            flag: "not-a-uuid",
            environmentKey: .sessionID,
            environment: [:]
        )
        #expect(result == .failure(.malformedFlag("not-a-uuid")))
    }

    @Test func malformedEnvFallsThroughToNilRatherThanErroring() {
        let result = BattyTargetResolver.resolve(
            flag: nil,
            environmentKey: .sessionID,
            environment: ["BATTY_SESSION_ID": "garbage"]
        )
        guard case let .success(resolved) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(resolved == nil)
    }

    // MARK: - `batty session info` retrofit (#0274's seam, closed by #0281)

    @Test func sessionInfoRetrofitTargetsEnvSessionWhenNoFlag() {
        let envSessionID = UUID()
        let result = BattyTargetResolver.resolve(
            flag: nil,
            environmentKey: .sessionID,
            environment: ["BATTY_SESSION_ID": envSessionID.uuidString]
        )
        guard case let .success(resolved) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(resolved == envSessionID)
    }

    @Test func sessionInfoRetrofitFlagWinsOverEnvSession() {
        let flagSessionID = UUID()
        let envSessionID = UUID()
        let result = BattyTargetResolver.resolve(
            flag: flagSessionID.uuidString,
            environmentKey: .sessionID,
            environment: ["BATTY_SESSION_ID": envSessionID.uuidString]
        )
        guard case let .success(resolved) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(resolved == flagSessionID)
        #expect(resolved != envSessionID)
    }

    @Test func eachEnvironmentKeyIsResolvedIndependently() {
        let sessionID = UUID(), paneID = UUID(), tabID = UUID()
        let env = [
            "BATTY_SESSION_ID": sessionID.uuidString,
            "BATTY_PANE_ID": paneID.uuidString,
            "BATTY_TAB_ID": tabID.uuidString,
        ]
        for (key, expected) in [
            (BattyContextEnvironmentKey.sessionID, sessionID),
            (.paneID, paneID),
            (.tabID, tabID),
        ] {
            let result = BattyTargetResolver.resolve(flag: nil, environmentKey: key, environment: env)
            guard case let .success(resolved) = result else {
                Issue.record("expected .success, got \(result)")
                continue
            }
            #expect(resolved == expected)
        }
    }
}
