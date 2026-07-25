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
listener.delegate = delegate
listener.resume()

logger.info("listening on \(ServiceNames.broker, privacy: .public)")

// launchd started this process on demand (no RunAtLoad); it stays alive to
// answer requests until launchd stops it. No other work happens here — see
// "What the broker must not be" in docs/xpc/xpc-cli-architecture.md.
RunLoop.main.run()
