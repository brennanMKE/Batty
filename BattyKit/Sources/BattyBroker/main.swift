// main.swift

import BattyXPCCore
import Foundation
import os

// No `@main` here: SwiftPM's implicit top-level-code entry point for a file
// literally named `main.swift` conflicts with `@main` (same reason the CLI
// target renamed its entry point away from `main.swift` in #0250). The
// broker has no arguments to parse, so plain top-level code is simplest.

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "BrokerMain")

let broker = Broker()
let delegate = BrokerListenerDelegate(exportedObject: broker)
let listener = NSXPCListener(machServiceName: ServiceNames.broker)

// #0273: only accept connections from binaries signed with the broker's own
// team identity. `currentTeamIdentifier()` is `nil` for an ad-hoc/unsigned
// local iteration build (CODE_SIGNING_ALLOWED=NO), in which case no
// requirement is set at all — see `PeerCodeSigningRequirement` for why that
// has to be the dev-mode behavior rather than a hard failure.
if let requirement = PeerCodeSigningRequirement.requirement(forTeamIdentifier: OwnCodeSigningIdentity.currentTeamIdentifier()) {
    listener.setConnectionCodeSigningRequirement(requirement)
    logger.info("peer code-signing requirement enforced")
} else {
    logger.notice("running unsigned/ad-hoc — accepting any peer (dev-only)")
}

listener.delegate = delegate
listener.resume()

logger.info("listening on \(ServiceNames.broker, privacy: .public)")

// An update replaces the bundle this process came from; clients then reject
// it (#0278's check fails with -67065 once its code is gone from disk). Exit
// on the first replacement event and launchd starts the new binary on the next
// connection; the app registers its endpoint again on the interruption.
let replacementWatcher: ExecutableReplacementWatcher? = {
    guard let path = ExecutableReplacementWatcher.ownExecutablePath() else {
        logger.error("could not resolve own executable path; not watching for replacement")
        return nil
    }
    let watcher = ExecutableReplacementWatcher(
        path: path,
        queue: DispatchQueue(label: "co.sstools.Batty.broker.executable-watch")
    ) { event in
        logger.notice("executable replaced (\(ExecutableReplacementWatcher.describe(event), privacy: .public)) — exiting so launchd starts the new broker on demand")
        exit(0)
    }
    do {
        try watcher.start()
        return watcher
    } catch {
        logger.error("could not watch own executable \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        return nil
    }
}()

// launchd started this process on demand (no RunAtLoad); it stays alive until
// launchd stops it, or until its own executable is replaced by an update (then
// it exits and launchd starts the new binary on the next connection). No other
// work happens here — see "What the broker must not be" in
// docs/xpc/xpc-cli-architecture.md.
RunLoop.main.run()
