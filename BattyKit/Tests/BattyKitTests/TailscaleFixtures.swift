// TailscaleFixtures.swift

import Foundation
import Testing
@testable import BattyKit

nonisolated enum TailscaleFixtures {
    static let dnsName = "host.tailnet.ts.net"

    static let running = #"{"BackendState":"Running","Self":{"DNSName":"host.tailnet.ts.net.","HostName":"host"},"CertDomains":["host.tailnet.ts.net"],"MagicDNSSuffix":"tailnet.ts.net"}"#
    static let runningNoHTTPS = #"{"BackendState":"Running","Self":{"DNSName":"host.tailnet.ts.net."}}"#
    static let stopped = #"{"BackendState":"Stopped","Self":{"DNSName":"host.tailnet.ts.net."}}"#
    static let loggedOut = #"{"BackendState":"NeedsLogin"}"#
    static let missingSelf = #"{"BackendState":"Running","CertDomains":["host.tailnet.ts.net"]}"#
    static let malformed = #"{"BackendState":"#

    // Unverified against real tailscale serve status --json output (#0697): replace with a captured fixture when available.
    static let emptyServe = "{}"
    static let oursOn3000 = #"{"TCP":{"3000":{"HTTPS":true}},"Web":{"host.tailnet.ts.net:3000":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}},"AllowFunnel":{}}"#
    static let foreignOn3000 = #"{"TCP":{"3000":{"HTTPS":true}},"Web":{"host.tailnet.ts.net:3000":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:4000"}}}}}"#
    static let twoHandlersOn3000 = #"{"TCP":{"3000":{"HTTPS":true}},"Web":{"host.tailnet.ts.net:3000":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"},"/api":{"Proxy":"http://127.0.0.1:5000"}}}}}"#
    static let tcpForwardOn3000 = #"{"TCP":{"3000":{"TCPForward":"127.0.0.1:3000"}}}"#
}

/// A scripted `tailscale`: canned status, a simulated serve config the on
/// and off argvs change, and a record of every argv. Flags any argv Batty
/// must never run.
nonisolated final class FakeTailscaleRunner: TailscaleCommandRunning, @unchecked Sendable {
    static let executable = URL(fileURLWithPath: "/fake/tailscale")

    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _status = TailscaleFixtures.running
    private var _serveOverride: String?
    private var _mappings: [UInt16: String] = [:]
    private var _appliesServe = true
    private var _nextServeResult: TailscaleCommandResult?

    var calls: [[String]] { lock.withLock { _calls } }
    var status: String {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    /// Replaces the simulated serve config's JSON.
    var serveOverride: String? {
        get { lock.withLock { _serveOverride } }
        set { lock.withLock { _serveOverride = newValue } }
    }
    var mappings: [UInt16: String] {
        get { lock.withLock { _mappings } }
        set { lock.withLock { _mappings = newValue } }
    }
    var appliesServe: Bool {
        get { lock.withLock { _appliesServe } }
        set { lock.withLock { _appliesServe = newValue } }
    }
    /// The result of the next on or off argv.
    var nextServeResult: TailscaleCommandResult? {
        get { lock.withLock { _nextServeResult } }
        set { lock.withLock { _nextServeResult = newValue } }
    }

    var serveCalls: [[String]] { calls.filter { $0.first == "serve" && $0 != TailscaleArgs.serveStatus } }

    func run(executable: URL, arguments: [String], timeout: Duration) async -> TailscaleCommandResult {
        if arguments.contains(where: { ["reset", "clear", "funnel", "--yes"].contains($0) }) {
            Issue.record("Batty must never run tailscale \(arguments.joined(separator: " "))")
        }
        return lock.withLock {
            _calls.append(arguments)
            if arguments == TailscaleArgs.status { return TailscaleCommandResult(exitCode: 0, stdout: _status) }
            if arguments == TailscaleArgs.serveStatus {
                return TailscaleCommandResult(exitCode: 0, stdout: _serveOverride ?? TailscaleServeConfig.json(mappings: _mappings, dnsName: TailscaleFixtures.dnsName))
            }
            guard let port = UITestTailscaleRunner.port(in: arguments) else {
                return TailscaleCommandResult(exitCode: 1, stderr: "unexpected")
            }
            if let scripted = _nextServeResult {
                _nextServeResult = nil
                return scripted
            }
            if arguments == TailscaleArgs.serveOn(port: port) {
                if _appliesServe { _mappings[port] = TailscaleArgs.localTarget(port: port) }
                return TailscaleCommandResult(exitCode: 0, stdout: "Available within your tailnet")
            }
            if arguments == TailscaleArgs.serveOff(port: port) {
                _mappings[port] = nil
                return TailscaleCommandResult(exitCode: 0)
            }
            return TailscaleCommandResult(exitCode: 1, stderr: "unexpected")
        }
    }
}
