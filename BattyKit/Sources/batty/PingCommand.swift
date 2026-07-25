// PingCommand.swift

import ArgumentParser
import BattyXPCCore
import Foundation

struct PingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "Check whether the Batty broker is reachable."
    )

    nonisolated func run() throws {
        let outcome = BrokerPingClient.ping(timeout: 3.0)
        guard outcome.reachable else {
            fputs("batty: broker unreachable\n", stderr)
            throw ExitCode(XPCExitCode.brokerUnreachable)
        }
        if let message = outcome.message {
            print("batty: broker reachable — \(message)")
        } else {
            print("batty: broker reachable")
        }
    }
}
