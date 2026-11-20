// UITestTailscaleRunner.swift

import Foundation

/// `BATTY_UI_TEST_FAKE_TAILSCALE`'s runner: a Running node with HTTPS
/// certificates and an in-memory serve config that the on and off argvs
/// change. Never spawns a process.
nonisolated final class UITestTailscaleRunner: TailscaleCommandRunning, @unchecked Sendable {
    static let dnsName = "batty-vm.example.ts.net"

    private let lock = NSLock()
    private var mappings: [UInt16: String] = [:]

    func run(executable: URL, arguments: [String], timeout: Duration) async -> TailscaleCommandResult {
        lock.withLock {
            if arguments == TailscaleArgs.status {
                return TailscaleCommandResult(exitCode: 0, stdout: """
                {"BackendState":"Running","Self":{"DNSName":"\(Self.dnsName)."},"CertDomains":["\(Self.dnsName)"]}
                """)
            }
            if arguments == TailscaleArgs.serveStatus {
                return TailscaleCommandResult(exitCode: 0, stdout: TailscaleServeConfig.json(mappings: mappings, dnsName: Self.dnsName))
            }
            if let port = Self.port(in: arguments) {
                if arguments == TailscaleArgs.serveOn(port: port) {
                    mappings[port] = TailscaleArgs.localTarget(port: port)
                    return TailscaleCommandResult(exitCode: 0)
                }
                if arguments == TailscaleArgs.serveOff(port: port) {
                    mappings[port] = nil
                    return TailscaleCommandResult(exitCode: 0)
                }
            }
            return TailscaleCommandResult(exitCode: 1, stderr: "unexpected arguments")
        }
    }

    static func port(in arguments: [String]) -> UInt16? {
        arguments.lazy.compactMap { $0.hasPrefix("--https=") ? UInt16($0.dropFirst("--https=".count)) : nil }.first
    }
}
