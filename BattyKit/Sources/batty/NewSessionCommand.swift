// NewSessionCommand.swift

import ArgumentParser
import BattyCLICore
import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "NewSessionCommand")

/// The CLI's original (and still default) behavior: `batty <path>` and bare
/// `batty` create a session. Named `new`, not `open` — `issues/0257.md`
/// pins `batty open` to mean "activate/foreground Batty" and session
/// creation to `batty session new [<path>]` in the eventual noun/verb
/// grammar; `open` would collide with that reservation, `new` doesn't (the
/// CLI has never shipped in a tagged release, so renaming here costs
/// nothing). ArgumentParser's `defaultSubcommand` still makes the bare form
/// work unchanged. One edge case this introduces: a directory literally
/// named the same as another subcommand (`new`, `ping`, `status`, `list`,
/// or `session`) now needs `batty new new` / `batty new ping` / etc. to
/// disambiguate; `batty ping` used to just try (and fail to resolve) a
/// relative path called "ping".
///
/// #0380: dispatching the `batty://` URL only proves LaunchServices accepted
/// it, not that a Session exists — so by default this command now snapshots
/// topology *before* dispatch, dispatches exactly as before, then polls
/// `list` until a Session appears whose `path` matches and whose `id` is new
/// (`NewSessionResolver`, which uses the same "path matches and id is new"
/// rule as the workaround this replaces, `docs/batty-cli-agent-workflows.md`).
/// `--no-wait` restores the original fire-and-forget behavior for callers
/// that don't care.
struct NewSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Create a new Batty session rooted at a directory, printing its id and focused pane id.",
        helpNames: .long
    )

    @Argument(help: "Directory for the new session. Defaults to the current directory.")
    var path: String = "."

    @Flag(name: .long, help: "Emit JSON instead of the two-line session id / pane id text.")
    var json = false

    @Flag(name: .long, help: "Dispatch the batty:// URL and exit immediately without confirming the new session — the original fire-and-forget behavior.")
    var noWait = false

    /// #0380 round 3 review (N7): without this, `--json --no-wait` silently
    /// printed nothing — `noWait`'s early return in `run()` happens before
    /// `json` is ever consulted, and that's not obvious from the flag help
    /// alone. Rejecting the combination up front (ArgumentParser's own
    /// `64`, "invalid command syntax") is more discoverable than a quietly
    /// empty stdout that reads like a bug.
    nonisolated func validate() throws {
        if json, noWait {
            throw ValidationError("--json has no effect with --no-wait, which exits before there is anything to report")
        }
    }

    /// One-time pre-dispatch check's own connection timeout — matches
    /// `AppConnectDance`'s `brokerTimeout` default (3 s), since this is the
    /// same kind of one-shot "is the broker/app there at all" round trip.
    private static let snapshotTimeout: TimeInterval = 3.0

    /// #0380 pinned decision: "bounded poll of roughly 5 s ... the same
    /// budget the doc's script uses (50 × 0.1 s)" — ported verbatim from
    /// the snapshot-and-poll script that doc carried before this command
    /// absorbed the pattern.
    /// This is the **warm** budget: the app was already running and
    /// registered before dispatch, so the only thing left to wait on is
    /// Session creation. `pollRequestTimeout` matches `AppConnectDance`'s
    /// `pollTimeout` default (1 s): generous enough that a single slow
    /// reply doesn't read as "not found yet," but short enough that a
    /// genuinely hung app doesn't let one attempt eat the whole budget —
    /// the same typical-case-vs-worst-case distinction
    /// `AppConnectDance.resolveEndpoint`'s doc comment already makes
    /// explicit for its own poll. Reading `pollMaxAttempts * pollInterval`
    /// alone suggests ~5 s, but each attempt is itself a round trip bounded
    /// by `pollRequestTimeout`, so the true worst case against a `list` call
    /// that hangs (rather than merely finding nothing yet) is
    /// `pollMaxAttempts * pollRequestTimeout + (pollMaxAttempts - 1) *
    /// pollInterval` — with these defaults, 50 * 1.0 + 49 * 0.1 ≈ 54.9 s.
    private static let pollMaxAttempts = 50
    private static let pollInterval: TimeInterval = 0.1
    private static let pollRequestTimeout: TimeInterval = 1.0

    /// Cold-launch budget: #0380 round 1 review found the warm budget above never
    /// gets exercised for the most common agent case (first `batty new`
    /// after a reboot, or the first one Batty's ever seen) — `open` has to
    /// launch the process, the app has to register with the broker
    /// (`AppConnectDance.resolveEndpoint`'s own doc comment budgets 20
    /// attempts × 0.25 s interval just for *that*, worst case ~25 s against
    /// an unresponsive broker), and only then does Session creation happen
    /// on top. 50 × 0.1 s (5 s) is sized for the warm case only. This bound
    /// is deliberately larger and is a judgment call, not a measurement —
    /// revisit if it proves too tight (cold launches still time out) or too
    /// slow (agents wait needlessly on a launch failure) in practice.
    ///
    /// `run()` caches the endpoint the first time `resolveEndpoint` finds
    /// one (`cachedEndpoint`), so at most *one* attempt ever pays both round
    /// trips — the broker fetch that first resolves the endpoint, plus the
    /// `list` call made with it that same attempt. Every attempt before
    /// that only pays the (bounded by `pollRequestTimeout`) broker fetch,
    /// since `list` is never called while `resolveEndpoint` returns `nil`;
    /// every attempt after only pays the `list` round trip, since the cache
    /// skips the broker fetch entirely. So the true worst case is
    /// `coldLaunchPollMaxAttempts * pollRequestTimeout + pollRequestTimeout
    /// + (coldLaunchPollMaxAttempts - 1) * coldLaunchPollInterval`, i.e.
    /// 150 * 1.0 + 1.0 + 149 * 0.1 ≈ 165.9 s, not the ~15 s a reading of
    /// `coldLaunchPollMaxAttempts * coldLaunchPollInterval` alone would
    /// suggest (round 2's estimate of ~315 s assumed every attempt paid
    /// both round trips, which round 3 review caught: caching means at most
    /// one attempt ever does). This still matches `AppConnectDance`, which
    /// likewise stops polling the broker once it has what it needs.
    private static let coldLaunchPollMaxAttempts = 150
    private static let coldLaunchPollInterval: TimeInterval = 0.1

    nonisolated func run() throws {
        let resolved = try resolvePath(path)
        guard let url = SessionURLBuilder.buildURL(absolutePath: resolved) else {
            fputs("batty: failed to build IPC URL for path: \(resolved)\n", stderr)
            throw ExitCode.failure
        }

        guard !noWait else {
            try openURL(url)
            return
        }

        // Taken *before* dispatch, deliberately non-launching
        // (`BrokerAppEndpointClient`/`RunningAppChecker` directly, not
        // `AppConnectDance`) — the `open` call right below is the one and
        // only launch path. Using the full connect dance here would let it
        // launch the app itself, racing/duplicating the launch `open` is
        // about to trigger.
        let state = Self.fetchPreDispatchState()

        try openURL(url)

        // Round-3 review (B1) also uses this, so it's declared before the
        // `switch state` rather than inside the `.notRunningYet` arm: only
        // that arm ever sets it away from `false`, since only its
        // `resolveEndpoint` ever calls `BrokerAppEndpointClient.fetchEndpoint`
        // directly (the `.ready` arm's endpoint is already known).
        var lastFetchWasBrokerUnreachable = false

        let outcome: PollOutcome
        switch state {
        case .degraded:
            fputs("batty: session created; could not confirm its id (no connection to Batty before dispatch)\n", stderr)
            return
        case .ready(let endpoint, let snapshot):
            outcome = Self.pollForNewSession(
                path: resolved,
                snapshot: snapshot,
                maxAttempts: Self.pollMaxAttempts,
                interval: Self.pollInterval,
                resolveEndpoint: { endpoint }
            )
        case .notRunningYet:
            // Nothing can predate a launch that hasn't happened yet — #0172
            // deleted workspace persistence, so there is nothing to restore
            // either — which is why an empty snapshot is exact as a
            // *before* set. It does NOT mean everything that shows up in
            // the first `list` after dispatch belongs to this request:
            // #0380 round 3 review (B1) found that a cold launch creates
            // **two** Sessions, not one — `WindowRuntime.init`'s default
            // `Session 1` at `$HOME`, plus the requested path's Session
            // (`docs/batty-cli-install.md`'s end-to-end trace documents
            // this as accepted behavior, #0251). If the requested path is
            // `$HOME` itself (`batty ~`, bare `batty`/`batty .` run from
            // home), both can qualify against this empty snapshot.
            // `pollForNewSession` handles the case where **both are
            // visible at once** (with resolved paths) by treating more
            // than one qualifying Session as "keep polling, don't guess"
            // rather than picking the first to resolve.
            //
            // #0380 round 4 review (B1): that guard does not close every
            // ordering. `Session 1`'s path can resolve, and be the *only*
            // match, before the `batty://` URL is even delivered (Apple
            // Event timing relative to broker registration and shell
            // startup is not guaranteed) — or the URL can be dropped
            // outright (`AppStateStore.addSession` returns `nil` when no
            // window is registered yet, #0251). Both leave `Session 1` as
            // the sole, unambiguous-looking match, so it is returned —
            // the original defect, narrowed rather than closed. See
            // `NewSessionResolver.findNewSessions`'s doc comment and
            // `issues/0380.md`'s pinned decision + `## Gotchas` for why
            // this residual is accepted rather than fixed here.
            //
            // `resolveEndpoint` re-fetches (still non-launching) every
            // attempt until an endpoint appears; each `nil` just means
            // "still launching/registering," not a failure. Once an
            // endpoint is found it's cached in `cachedEndpoint`
            // (`AppConnectDance.pollForEndpoint`'s closure-capture idiom,
            // `BoundedPoll.poll`'s `fetch` being non-escaping is what makes
            // this safe) so later attempts skip the broker round trip
            // entirely — see the `coldLaunchPollMaxAttempts` doc comment
            // above for the resulting worst-case budget. Caching is not
            // invalidated on a later `list` failure: if Batty crashes and
            // relaunches mid-poll under a new endpoint, a stale cached
            // endpoint yields `list -> .unreachable` (an immediate
            // `.failure`, not a retry) instead of the fresh
            // `fetchEndpoint` call that would have found the new one —
            // accepted as a narrow, rare window (#0380 round 3 review, N3)
            // rather than added complexity for it.
            var cachedEndpoint: NSXPCListenerEndpoint?
            outcome = Self.pollForNewSession(
                path: resolved,
                snapshot: TopologyPayload(pid: 0, windows: []),
                maxAttempts: Self.coldLaunchPollMaxAttempts,
                interval: Self.coldLaunchPollInterval,
                resolveEndpoint: {
                    if let cachedEndpoint {
                        return cachedEndpoint
                    }
                    switch BrokerAppEndpointClient.fetchEndpoint(timeout: Self.pollRequestTimeout) {
                    case .endpoint(.some(let endpoint)):
                        lastFetchWasBrokerUnreachable = false
                        cachedEndpoint = endpoint
                        return endpoint
                    case .endpoint(.none):
                        lastFetchWasBrokerUnreachable = false
                        return nil
                    case .unreachable:
                        // #0380 round 3 review (N8): tracked so a
                        // persistent timeout can report exit `2` (broker
                        // unreachable) instead of exit `3` (app
                        // unavailable) when the broker itself, not just
                        // app registration, is what never came up.
                        lastFetchWasBrokerUnreachable = true
                        return nil
                    }
                }
            )
        }

        switch outcome {
        case .found(let match):
            if json {
                try Self.printJSON(match)
            } else {
                print(match.sessionID)
                print(match.paneID)
            }
        case .failure(let code, let message):
            fputs("batty: \(message)\n", stderr)
            throw ExitCode(code)
        case .timedOut(let endpointEverSeen, let sawAmbiguousMatch):
            // #0380 round 2 review (B2): an endpoint that was never seen at
            // all means `list` never once succeeded — most likely a cold
            // launch that never finished registering — so there is no
            // evidence a Session was ever created, and this is the same
            // "app unavailable" state every other verb reports as exit `3`.
            // Only when an endpoint *was* live (the warm case, or a cold
            // launch that did register before the session-match poll ran
            // out) does "app rejected nothing, the Session may just not
            // have shown up yet" apply — that case keeps exit `4`.
            //
            // #0380 round 3 review (B1): a live endpoint that persistently
            // saw *more than one* qualifying Session (the `$HOME` collision
            // above) is also exit `4`, but gets its own message rather than
            // the generic "may not have been created" one, since a Session
            // (in fact, likely two) definitely *was* created here — the
            // problem is telling which one is new, not whether one exists.
            //
            // #0380 round 3 review (N8): a `!endpointEverSeen` timeout where
            // the broker itself never answered (as opposed to answering
            // "no endpoint yet") is exit `2`, matching every other verb's
            // vocabulary for "the broker is the thing that's unreachable."
            if !endpointEverSeen {
                if lastFetchWasBrokerUnreachable {
                    logger.error("run: poll timed out — broker never answered")
                    fputs("batty: broker unreachable\n", stderr)
                    throw ExitCode(XPCExitCode.brokerUnreachable)
                }
                logger.error("run: poll timed out without ever seeing an app endpoint — app unavailable")
                fputs("batty: app unavailable\n", stderr)
                throw ExitCode(XPCExitCode.appUnavailable)
            } else if sawAmbiguousMatch {
                logger.error("run: poll timed out with more than one session matching \(resolved, privacy: .public) — cannot safely pick one")
                fputs("batty: multiple sessions matched \(resolved); could not determine which one is new — this can happen on a cold launch (a default Session can share this path) or when another agent dispatched batty new against the same path concurrently (see docs/batty-cli-agent-workflows.md); refresh topology manually\n", stderr)
                throw ExitCode(XPCExitCode.requestFailed)
            } else {
                logger.notice("run: poll timed out with a live endpoint — session may not have been created in time")
                fputs("batty: session may not have been created; Batty did not report it within the poll window\n", stderr)
                throw ExitCode(XPCExitCode.requestFailed)
            }
        }
    }

    enum PreDispatchState {
        /// The app was already running and registered: `endpoint` is
        /// stable and reusable for the whole poll, `snapshot` is a real
        /// pre-dispatch topology to diff against.
        case ready(endpoint: NSXPCListenerEndpoint, snapshot: TopologyPayload)
        /// The broker is reachable but reports no registered endpoint, and
        /// no process for the resolved app bundle is running — `open` is
        /// about to cold-launch it. No Session can predate a launch that
        /// hasn't happened yet, so an empty snapshot is exact, not a guess.
        case notRunningYet
        /// Either the broker itself didn't answer, or it answered "no
        /// endpoint" while a process *is* already running (registered but
        /// not with the broker — `NoEndpointRegisteredDecision
        /// .waitForReregistration`'s case). Neither is safe to build a
        /// snapshot from, and this command must not launch anything itself
        /// to find out more — `open` stays the only launch path.
        case degraded
    }

    static func fetchPreDispatchState(
        resolveAppBundle: () -> Swift.Result<URL, AppBundleLocator.Failure> = { AppBundleLocator.resolve() },
        isAppRunning: (URL) -> Bool = { RunningAppChecker.isRunning(atBundleURL: $0) }
    ) -> PreDispatchState {
        switch BrokerAppEndpointClient.fetchEndpoint(timeout: snapshotTimeout) {
        case .unreachable:
            return .degraded
        case .endpoint(.some(let endpoint)):
            guard case .success(let payload) = AppServiceClient.list(endpoint: endpoint, includeDimensions: false, timeout: snapshotTimeout) else {
                return .degraded
            }
            return .ready(endpoint: endpoint, snapshot: payload)
        case .endpoint(.none):
            guard case .success(let bundleURL) = resolveAppBundle() else {
                return .degraded
            }
            // Same ambiguous state, and the same resolution, as
            // `AppConnectDance.resolveEndpoint`'s own launch-vs-wait branch
            // — reusing `NoEndpointRegisteredDecision` rather than
            // reinventing the running/not-running split keeps the two call
            // sites' behavior from silently drifting apart.
            switch NoEndpointRegisteredDecision.action(isAppRunning: isAppRunning(bundleURL)) {
            case .launchAndPoll:
                return .notRunningYet
            case .waitForReregistration:
                return .degraded
            }
        }
    }

    enum PollOutcome {
        case found(NewSessionMatch)
        case failure(Int32, String)
        /// `endpointEverSeen` is `true` when `resolveEndpoint` returned a
        /// non-`nil` endpoint at least once during the poll — i.e. `list`
        /// was actually reachable and simply never saw the matching
        /// Session in time. `false` means no endpoint ever came up (the
        /// warm case's `resolveEndpoint` is a fixed already-known-good
        /// endpoint, so it is always `true` there; only the cold-launch
        /// case can end up `false`). See `run()`'s handling of this case
        /// (#0380 round 2 review, B2) for why the two map to different
        /// exit codes.
        ///
        /// `sawAmbiguousMatch` is `true` when at least one attempt found
        /// *more than one* qualifying Session (#0380 round 3 review, B1) —
        /// see `NewSessionResolver.findNewSessions(before:after:path:)`'s
        /// doc comment for how that happens on a cold launch. Only
        /// meaningful when `endpointEverSeen` is also `true`, since it can
        /// only be set inside the branch that requires a live endpoint.
        case timedOut(endpointEverSeen: Bool, sawAmbiguousMatch: Bool)
    }

    /// Shared poll loop for both the warm (`resolveEndpoint` returns a
    /// fixed, already-known-good endpoint) and cold-launch
    /// (`resolveEndpoint` re-fetches, non-launching, every attempt, and
    /// returns `nil` while the app is still launching/registering) cases.
    ///
    /// Any `list` failure *after* an endpoint was obtained aborts
    /// immediately with that failure's own exit code — mirroring the shell
    /// workaround's `batty list --json || exit $?` inside its retry loop,
    /// which never tolerated a failed call as "keep trying." Only "no
    /// endpoint yet", "no matching session yet", and "more than one
    /// matching session" (see below) are reasons to keep polling.
    ///
    /// `resolveEndpoint` is not `@escaping`: `BoundedPoll.poll`'s `fetch`
    /// parameter is itself non-escaping, and `resolveEndpoint` is only ever
    /// called synchronously from inside the `fetch` closure passed to it
    /// here, so it never needs to outlive this call. Same for
    /// `fetchTopology`.
    ///
    /// `fetchTopology` exists purely so this function is testable without
    /// any live XPC connection (#0380 round 4 review, B2): its default
    /// calls the real `AppServiceClient.list`, but a test can inject a
    /// pure closure instead, needing only *some* `NSXPCListenerEndpoint`
    /// value from `resolveEndpoint` (e.g. `NSXPCListener.anonymous()
    /// .endpoint`, never actually connected to, since `fetchTopology`
    /// intercepts before any real call would happen) to exercise every
    /// branch below — including the `matches.count > 1` ambiguity branch,
    /// which round 3 review shipped with no test because reaching it
    /// looked like it required a real endpoint. It doesn't: only
    /// `fetchPreDispatchState` still reaches the genuinely non-injectable
    /// `BrokerAppEndpointClient.fetchEndpoint` (`issues/0365.md`'s gap
    /// still applies there, just not here).
    static func pollForNewSession(
        path: String,
        snapshot: TopologyPayload,
        maxAttempts: Int,
        interval: TimeInterval,
        resolveEndpoint: () -> NSXPCListenerEndpoint?,
        fetchTopology: (NSXPCListenerEndpoint) -> AppServiceClient.Outcome<TopologyPayload> = {
            AppServiceClient.list(endpoint: $0, includeDimensions: false, timeout: pollRequestTimeout)
        }
    ) -> PollOutcome {
        var endpointEverSeen = false
        var sawAmbiguousMatch = false
        let signal = BoundedPoll.poll(maxAttempts: maxAttempts, interval: interval) { () -> PollOutcome? in
            guard let endpoint = resolveEndpoint() else {
                return nil
            }
            endpointEverSeen = true
            switch fetchTopology(endpoint) {
            case .success(let payload):
                let matches = NewSessionResolver.findNewSessions(before: snapshot, after: payload, path: path)
                switch matches.count {
                case 0:
                    return nil
                case 1:
                    return .found(matches[0])
                default:
                    // #0380 round 3 review (B1): more than one qualifying
                    // Session — e.g. a cold launch's default `Session 1` at
                    // `$HOME` colliding with a `batty ~` request — means we
                    // cannot safely pick one. Keep polling rather than
                    // guess (`findNewSession`'s "first match wins" would
                    // otherwise silently hand back the wrong id); remember
                    // that this happened so a persistent timeout reports it
                    // distinctly instead of the generic "not found" message.
                    sawAmbiguousMatch = true
                    return nil
                }
            case .unreachable:
                return .failure(XPCExitCode.appUnavailable, "app unavailable")
            case .requestFailed(let message):
                return .failure(XPCExitCode.requestFailed, "request failed — \(message)")
            case .appTerminated:
                return .failure(XPCExitCode.sessionTerminated, "app terminated")
            }
        }
        return signal ?? .timedOut(endpointEverSeen: endpointEverSeen, sawAmbiguousMatch: sawAmbiguousMatch)
    }

    private static func printJSON(_ match: NewSessionMatch) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(match), let text = String(data: data, encoding: .utf8) else {
            fputs("batty: failed to encode new session as JSON\n", stderr)
            throw ExitCode.failure
        }
        print(text)
    }
}
