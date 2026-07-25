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

// launchd started this process on demand (no RunAtLoad); it stays alive to
// answer requests until launchd stops it. No other work happens here — see
// "What the broker must not be" in docs/xpc/xpc-cli-architecture.md.
RunLoop.main.run()
