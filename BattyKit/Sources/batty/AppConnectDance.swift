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
    enum Failure: Error, Equatable {
        /// The broker's own Mach service didn't answer — agent not
        /// registered, or `SMAppService`'s `requiresApproval` state.
        case brokerUnreachable
        /// The broker answered but no app endpoint ever appeared, whether
        /// because the launch itself failed or the poll bound was
        /// exhausted waiting for the launched app to register. Only
        /// reached when no process at the resolved app bundle was running
        /// — see `appRunningUnregistered` for the case where one is.
        case appUnavailable
        /// The app is already running at the resolved bundle path, but the
        /// broker has no registered endpoint for it and it did not
        /// re-register within the poll bound (#0361) — most likely an
        /// exhausted `BrokerReconnectBudget`, or a broker restart the app
        /// hasn't caught up with yet. Launching here would spawn a
        /// duplicate process alongside the one already running, which is
        /// exactly the defect this case exists to prevent: the caller
        /// reports this distinctly and tells the user to check/relaunch
        /// Batty, rather than silently launching another instance.
        case appRunningUnregistered
        /// #0361 round 2: could not determine, deterministically, which
        /// on-disk app bundle to target — see `AppBundleLocator.Failure`.
        /// Carries a human-readable diagnostic naming the expected path and
        /// any other bundles Spotlight knows claim the same identifier,
        /// rather than falling through to LaunchServices' own ambiguous
        /// bundle-id resolution.
        case appBundleUnresolved(String)
    }

    /// Poll defaults for `.launchAndPoll` follow the measured reference
    /// point in the issue (`docs/xpc/xpc-cli-architecture.md`'s cited cold
    /// start: 0.284 s total, one 250 ms poll): 250 ms between attempts,
    /// bounded at 20 attempts. Each attempt is itself a round trip bounded
    /// by `pollTimeout`, so the true worst case against a broker that
    /// accepts connections but never replies (wedged, not merely absent) is
    /// `pollMaxAttempts * pollTimeout + (pollMaxAttempts - 1) *
    /// pollInterval` — with these defaults, 20 * 1.0 + 19 * 0.25 ≈ 24.8 s,
    /// not the ~5 s a reading of `pollMaxAttempts * pollInterval` alone
    /// would suggest. That headroom is deliberate: a cold `NSApplication`
    /// launch genuinely can take seconds.
    ///
    /// `.waitForReregistration` (#0361) waits on a *different* thing: a
    /// process that is already running but unregistered — there is no
    /// cold-launch case to give it headroom for, so it gets its own, much
    /// tighter bound via `reregistrationPoll*`.
    ///
    /// `AppXPCCoordinator` (`BattyKit/Sources/BattyKit/XPC/AppXPCCoordinator.swift`)
    /// is what this arm is actually waiting on, and its recovery is
    /// two-phased, not a single "notices quickly or never" event:
    /// `handleBrokerSignal` retries immediately (no delay) for as long as
    /// `BrokerReconnectBudget` has attempts left (5 by default) — that burst
    /// has no artificial delay built in, only whatever the real connection
    /// and registration round trips cost. Once the burst is exhausted,
    /// recovery becomes a *scheduled* retry via
    /// `BrokerReconnectBackoff.interval(forAttempt:)`: 5 s, then 10, 20, 40,
    /// capped at 60. Only the *first* of those gaps is a flat 5 s — later
    /// ones grow, and `attemptRepairIfNeeded` schedules no backoff retry at
    /// all when `SMAppService` isn't `.enabled` (the user hasn't opted in).
    /// This arm is sized only for the first case — a burst-exhausted app
    /// whose very next attempt is 5 s away; an app stuck behind a longer
    /// backoff gap, or one with no scheduled retry at all, is exactly what
    /// exit `6`'s "check or relaunch Batty" messaging is for.
    ///
    /// `reregistrationPoll*`'s defaults (13 attempts, 0.5 s apart) deliberately
    /// span past that first 5 s gap: assuming each round trip completes near
    /// instantly (the common, healthy-broker case), the 13th (last) attempt
    /// fires at `(reregistrationPollMaxAttempts - 1) *
    /// reregistrationPollInterval` = 12 * 0.5 = 6.0 s — a 1 s margin past
    /// the retry — so an app that re-registers there is caught as a success
    /// instead of exhausting the bound into exit `6`.
    ///
    /// `reregistrationPollTimeout` (0.5 s) is deliberately **not** shortened
    /// to match the tight interval: each poll attempt opens a fresh
    /// `NSXPCConnection(machServiceName:)` — a Mach service lookup,
    /// `OutgoingCodeSigningEnforcement`'s requirement check, and the broker
    /// listener's own peer check — not just a message send, and the
    /// broker's `LaunchAgent` plist sets no `ProcessType`, so
    /// it isn't exempted from macOS's normal scheduling throttling under
    /// load. The `docs/xpc/xpc-cli-architecture.md` "0.3 ms" figure is a
    /// vendored reference from a different project's request/reply
    /// benchmark, not a measurement of connection setup on this path — it is
    /// not a safe basis for a sub-100 ms timeout here. `reregistrationPollTimeout`
    /// is kept equal to `.launchAndPoll`'s connection-setup budget divided in
    /// half (`pollTimeout` is 1.0) rather than cut further, so a slow-but-healthy
    /// broker under load is not misread as unregistered. That leaves this
    /// arm's absolute worst case (every attempt actually consuming its full
    /// timeout) at `reregistrationPollMaxAttempts * reregistrationPollTimeout
    /// + (reregistrationPollMaxAttempts - 1) * reregistrationPollInterval` —
    /// with these defaults, 13 * 0.5 + 12 * 0.5 ≈ 12.5 s: roughly half of
    /// `.launchAndPoll`'s ~24.8 s, not the few seconds the common-case
    /// arithmetic above suggests. There is no measured reference point for
    /// how long a live app takes to re-register beyond the backoff schedule
    /// itself, so covering exactly the first retry (rather than some other
    /// number) is the judgment call this bound rests on.
    ///
    /// `fetchEndpoint` and `sleep` are injection seams alongside
    /// `resolveAppBundle`/`launch`/`isAppRunning` (#0361): without them, no
    /// test can drive this past the initial broker round trip without a
    /// live `BattyBroker` Mach service, or without actually sleeping out
    /// the poll bound (#0365).
    static func resolveEndpoint(
        brokerTimeout: TimeInterval = 3.0,
        pollTimeout: TimeInterval = 1.0,
        pollMaxAttempts: Int = 20,
        pollInterval: TimeInterval = 0.25,
        reregistrationPollTimeout: TimeInterval = 0.5,
        reregistrationPollMaxAttempts: Int = 13,
        reregistrationPollInterval: TimeInterval = 0.5,
        fetchEndpoint: (TimeInterval) -> BrokerAppEndpointClient.Result = { BrokerAppEndpointClient.fetchEndpoint(timeout: $0) },
        resolveAppBundle: () -> Swift.Result<URL, AppBundleLocator.Failure> = { AppBundleLocator.resolve() },
        launch: (URL) -> Bool = { AppLauncher.launch(bundleURL: $0) },
        isAppRunning: (URL) -> Bool = { RunningAppChecker.isRunning(atBundleURL: $0) },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Swift.Result<NSXPCListenerEndpoint, Failure> {
        switch fetchEndpoint(brokerTimeout) {
        case .unreachable:
            logger.notice("resolveEndpoint -> broker unreachable")
            return .failure(.brokerUnreachable)
        case .endpoint(.some(let endpoint)):
            // #0361: a registered endpoint is used exactly as handed to us
            // by the broker — no bundle resolution, no path comparison.
            // Whichever process registered it *is* the one the caller
            // wants; the ambiguity this issue fixes only exists on the
            // launch-decision path below, never here.
            logger.info("resolveEndpoint -> endpoint already registered, no launch needed")
            return .success(endpoint)
        case .endpoint(.none):
            break
        }

        // #0361: "no endpoint registered" is ambiguous — it means either
        // "nothing is running" or "something is running but hasn't
        // registered." Conflating the two used to launch a duplicate
        // process every time the app was running but temporarily
        // unregistered (an exhausted `BrokerReconnectBudget`, a broker
        // restart). `NoEndpointRegisteredDecision` makes the branch explicit
        // and unit-testable; only the `.launchAndPoll` arm may call `launch`.
        //
        // Round 2: which app that decision is even *about* was itself
        // ambiguous — `open -b <bundle-id>` and
        // `NSRunningApplication.runningApplications(withBundleIdentifier:)`
        // both delegate to LaunchServices' own bundle-id resolution, which
        // silently picks among every bundle sharing the identifier
        // (DerivedData debug builds, stale DMG mounts, ...). `resolveAppBundle`
        // (`AppBundleLocator`) resolves one specific bundle path first, and
        // every decision below is about that exact bundle, not the identifier.
        let bundleURL: URL
        switch resolveAppBundle() {
        case .failure(let failure):
            logger.error("resolveEndpoint -> could not resolve which app bundle to target: \(failure.diagnosticMessage, privacy: .public)")
            return .failure(.appBundleUnresolved(failure.diagnosticMessage))
        case .success(let resolved):
            bundleURL = resolved
            logger.info("resolveEndpoint: targeting app bundle \(resolved.path, privacy: .public)")
        }

        let appAlreadyRunning = isAppRunning(bundleURL)
        switch NoEndpointRegisteredDecision.action(isAppRunning: appAlreadyRunning) {
        case .launchAndPoll:
            logger.info("resolveEndpoint: no app registered and none running at \(bundleURL.path, privacy: .public), launching")
            guard launch(bundleURL) else {
                // Short-circuits rather than burning the full poll bound: a
                // failed launch (missing bundle, LaunchServices rejection)
                // will never produce a registration, so waiting out the
                // bound only delays the exit-3 the caller is going to get
                // anyway.
                logger.error("resolveEndpoint -> launch failed, not polling")
                return .failure(.appUnavailable)
            }
            return pollForEndpoint(maxAttempts: pollMaxAttempts, interval: pollInterval, pollTimeout: pollTimeout, notRegisteredFailure: .appUnavailable, fetchEndpoint: fetchEndpoint, sleep: sleep)
        case .waitForReregistration:
            logger.notice("resolveEndpoint: app already running at \(bundleURL.path, privacy: .public) but not registered with the broker — waiting for it to re-register instead of launching a duplicate")
            return pollForEndpoint(maxAttempts: reregistrationPollMaxAttempts, interval: reregistrationPollInterval, pollTimeout: reregistrationPollTimeout, notRegisteredFailure: .appRunningUnregistered, fetchEndpoint: fetchEndpoint, sleep: sleep)
        }
    }

    // A broker that goes briefly unreachable mid-poll (e.g. mid-restart) is
    // treated the same as "no endpoint yet" and simply retried until the
    // bound is exhausted — distinguishing it further is #0272's
    // lifecycle-hardening scope, not this child's.
    private static func pollForEndpoint(
        maxAttempts: Int,
        interval: TimeInterval,
        pollTimeout: TimeInterval,
        notRegisteredFailure: Failure,
        fetchEndpoint: (TimeInterval) -> BrokerAppEndpointClient.Result,
        sleep: (TimeInterval) -> Void
    ) -> Swift.Result<NSXPCListenerEndpoint, Failure> {
        var attempt = 0
        let endpoint = BoundedPoll.poll(maxAttempts: maxAttempts, interval: interval, sleep: sleep) { () -> NSXPCListenerEndpoint? in
            attempt += 1
            if case .endpoint(.some(let endpoint)) = fetchEndpoint(pollTimeout) {
                logger.info("resolveEndpoint: poll attempt \(attempt, privacy: .public) -> endpoint registered")
                return endpoint
            }
            return nil
        }

        guard let endpoint else {
            logger.error("resolveEndpoint -> \(String(describing: notRegisteredFailure), privacy: .public) after \(attempt, privacy: .public) poll attempts")
            return .failure(notRegisteredFailure)
        }
        return .success(endpoint)
    }
}
