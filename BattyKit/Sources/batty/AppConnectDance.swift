// AppConnectDance.swift

import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppConnectDance")

/// The CLI's five-step connect dance
/// (`docs/xpc/xpc-cli-architecture.md`): connect to the broker, ask for the
/// app's endpoint, launch the app on a miss, poll until it registers, hand
/// back the endpoint for the caller to connect to directly. The broker is
/// out of the path after this returns.
nonisolated enum AppConnectDance {
    enum Failure: Error {
        /// The broker's own Mach service didn't answer — agent not
        /// registered, or `SMAppService`'s `requiresApproval` state.
        case brokerUnreachable
        /// The broker answered but no app endpoint ever appeared, whether
        /// because the launch itself failed or the poll bound was
        /// exhausted waiting for the launched app to register.
        case appUnavailable
    }

    /// Poll defaults follow the measured reference point in the issue
    /// (`docs/xpc/xpc-cli-architecture.md`'s cited cold start: 0.284 s
    /// total, one 250 ms poll): 250 ms between attempts, bounded at 20
    /// attempts. Each attempt is itself a round trip bounded by
    /// `pollTimeout`, so the true worst case against a broker that accepts
    /// connections but never replies (wedged, not merely absent) is
    /// `pollMaxAttempts * pollTimeout + (pollMaxAttempts - 1) *
    /// pollInterval` — with these defaults, 20 * 1.0 + 19 * 0.25 ≈ 24.8 s,
    /// not the ~5 s a reading of `pollMaxAttempts * pollInterval` alone
    /// would suggest. Still bounded, which is the property that matters:
    /// the CLI exits `3` rather than hanging forever.
    static func resolveEndpoint(
        brokerTimeout: TimeInterval = 3.0,
        pollTimeout: TimeInterval = 1.0,
        pollMaxAttempts: Int = 20,
        pollInterval: TimeInterval = 0.25,
        launch: (String) -> Bool = { AppLauncher.launch(bundleIdentifier: $0) }
    ) -> Swift.Result<NSXPCListenerEndpoint, Failure> {
        switch BrokerAppEndpointClient.fetchEndpoint(timeout: brokerTimeout) {
        case .unreachable:
            logger.notice("resolveEndpoint -> broker unreachable")
            return .failure(.brokerUnreachable)
        case .endpoint(.some(let endpoint)):
            logger.info("resolveEndpoint -> endpoint already registered, no launch needed")
            return .success(endpoint)
        case .endpoint(.none):
            break
        }

        logger.info("resolveEndpoint: no app registered, launching \(ServiceNames.appBundleIdentifier, privacy: .public)")
        guard launch(ServiceNames.appBundleIdentifier) else {
            // Short-circuits rather than burning the full poll bound: a
            // failed launch (bad bundle id, LaunchServices rejection) will
            // never produce a registration, so waiting out the bound only
            // delays the exit-3 the caller is going to get anyway.
            logger.error("resolveEndpoint -> launch failed, not polling")
            return .failure(.appUnavailable)
        }

        // A broker that goes briefly unreachable mid-poll (e.g. mid-restart)
        // is treated the same as "no endpoint yet" and simply retried until
        // the bound is exhausted — distinguishing it further is #0272's
        // lifecycle-hardening scope, not this child's.
        var attempt = 0
        let endpoint = BoundedPoll.poll(maxAttempts: pollMaxAttempts, interval: pollInterval) { () -> NSXPCListenerEndpoint? in
            attempt += 1
            if case .endpoint(.some(let endpoint)) = BrokerAppEndpointClient.fetchEndpoint(timeout: pollTimeout) {
                logger.info("resolveEndpoint: poll attempt \(attempt, privacy: .public) -> endpoint registered")
                return endpoint
            }
            return nil
        }

        guard let endpoint else {
            logger.error("resolveEndpoint -> app unavailable after \(attempt, privacy: .public) poll attempts")
            return .failure(.appUnavailable)
        }
        return .success(endpoint)
    }
}
