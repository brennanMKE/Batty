// TailscaleCLI.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "TailscaleCLI")

public nonisolated struct TailscaleCommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    /// The tool's own words, stderr first, trimmed to 400 characters.
    var message: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = err.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : err
        return String(text.prefix(400))
    }
}

/// Every `tailscale` invocation goes through this seam, so tests and UI
/// tests never run the real CLI.
public nonisolated protocol TailscaleCommandRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: Duration) async -> TailscaleCommandResult
}

/// Runs the CLI with stdin on `/dev/null`, so an interactive prompt (the
/// HTTPS-enable flow, the multi-handler `off` confirmation) reads EOF
/// instead of waiting on the user.
public nonisolated struct ProcessTailscaleCommandRunner: TailscaleCommandRunning {
    public init() {}

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    private struct ProcessBox: @unchecked Sendable { let process: Process }

    public func run(executable: URL, arguments: [String], timeout: Duration) async -> TailscaleCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let (exited, exitedContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            exitedContinuation.yield(finished.terminationStatus)
            exitedContinuation.finish()
        }
        do {
            try process.run()
        } catch {
            logger.error("tailscale launch failed: \(error.localizedDescription, privacy: .public)")
            return TailscaleCommandResult(exitCode: -1, stderr: error.localizedDescription)
        }
        // Both pipes drain concurrently so a full pipe can't wedge the child.
        let outReader = out.fileHandleForReading, errReader = err.fileHandleForReading
        let stdoutTask = Task.detached { outReader.readDataToEndOfFile() }
        let stderrTask = Task.detached { errReader.readDataToEndOfFile() }
        let timedOut = Flag()
        let box = ProcessBox(process: process)
        let killer = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            timedOut.set()
            ProcessSignal.send(SIGTERM, to: box.process)
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            ProcessSignal.send(SIGKILL, to: box.process)
        }
        var status: Int32 = -1
        for await code in exited { status = code }
        killer.cancel()
        let stdout = String(decoding: await stdoutTask.value, as: UTF8.self)
        let stderr = String(decoding: await stderrTask.value, as: UTF8.self)
        return TailscaleCommandResult(exitCode: status, stdout: stdout, stderr: stderr, timedOut: timedOut.isSet)
    }
}

/// A Finder-launched app's PATH lacks `/usr/local/bin` and
/// `/opt/homebrew/bin`, so those and the app bundle's CLI are checked too.
public nonisolated enum TailscaleExecutableLocator {
    static let fallbacks = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    public static func locate(
        environmentPATH: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let fromPATH = (environmentPATH ?? "").split(separator: ":").filter { !$0.isEmpty }.map { "\($0)/tailscale" }
        return (fromPATH + fallbacks).first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }
}

/// The only argvs Batty ever passes to `tailscale`.
public nonisolated enum TailscaleArgs {
    public static let status = ["status", "--json"]
    public static let serveStatus = ["serve", "status", "--json"]

    public static func serveOn(port: UInt16) -> [String] {
        ["serve", "--bg", "--https=\(port)", localTarget(port: port)]
    }

    /// The docs: add `off` to the command that turned it on.
    public static func serveOff(port: UInt16) -> [String] {
        serveOn(port: port) + ["off"]
    }

    static func localTarget(port: UInt16) -> String {
        "http://127.0.0.1:\(port)"
    }
}

/// The parts of `tailscale status --json` Batty reads.
nonisolated struct TailscaleStatusJSON: Decodable {
    struct Node: Decodable {
        let DNSName: String?
    }

    let backendState: String
    let selfNode: Node?
    let certDomains: [String]?

    enum CodingKeys: String, CodingKey {
        case backendState = "BackendState"
        case selfNode = "Self"
        case certDomains = "CertDomains"
    }
}

/// The parts of `tailscale serve status --json` (`ipn.ServeConfig`) Batty
/// reads. Unknown keys are ignored.
public nonisolated struct TailscaleServeConfig: Decodable, Sendable, Equatable {
    struct TCPHandler: Decodable, Sendable, Equatable {
        let HTTPS: Bool?
        let HTTP: Bool?
        let TCPForward: String?
    }

    struct HTTPHandler: Decodable, Sendable, Equatable {
        let Proxy: String?
    }

    struct WebServer: Decodable, Sendable, Equatable {
        let Handlers: [String: HTTPHandler]?
    }

    let TCP: [String: TCPHandler]?
    let Web: [String: WebServer]?

    static func parse(_ data: Data) -> TailscaleServeConfig? {
        try? JSONDecoder().decode(TailscaleServeConfig.self, from: data)
    }

    /// Exactly Batty's form: HTTPS on `port`, one `/` handler proxying to
    /// `http://127.0.0.1:<port>`.
    func isOurs(port: UInt16, dnsName: String) -> Bool {
        guard TCP?["\(port)"]?.HTTPS == true, TCP?["\(port)"]?.TCPForward == nil else { return false }
        let webKeys = (Web ?? [:]).keys.filter { $0.hasSuffix(":\(port)") }
        guard webKeys == ["\(dnsName):\(port)"], let handlers = Web?["\(dnsName):\(port)"]?.Handlers,
              handlers.count == 1, var proxy = handlers["/"]?.Proxy else { return false }
        while proxy.hasSuffix("/") { proxy.removeLast() }
        return proxy == TailscaleArgs.localTarget(port: port)
    }

    func hasAnyMapping(port: UInt16) -> Bool {
        TCP?["\(port)"] != nil || (Web ?? [:]).keys.contains { $0.hasSuffix(":\(port)") }
    }

    /// The JSON Tailscale prints for `mappings` (port → proxy target), each
    /// on HTTPS with a single `/` handler. For the fakes.
    static func json(mappings: [UInt16: String], dnsName: String) -> String {
        guard !mappings.isEmpty else { return "{}" }
        let ports = mappings.keys.sorted()
        let tcp = ports.map { "\"\($0)\":{\"HTTPS\":true}" }.joined(separator: ",")
        let web = ports.map { "\"\(dnsName):\($0)\":{\"Handlers\":{\"/\":{\"Proxy\":\"\(mappings[$0]!)\"}}}" }.joined(separator: ",")
        return "{\"TCP\":{\(tcp)},\"Web\":{\(web)}}"
    }
}

public nonisolated enum TailnetURL {
    public static func make(dnsName: String, port: UInt16) -> URL {
        URL(string: port == 443 ? "https://\(dnsName)/" : "https://\(dnsName):\(port)/")!
    }
}
