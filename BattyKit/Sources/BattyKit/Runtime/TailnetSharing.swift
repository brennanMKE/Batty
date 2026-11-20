// TailnetSharing.swift

import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "TailnetSharing")

public nonisolated enum TailnetStatus: Equatable, Sendable {
    /// No CLI, or `status --json` failed or couldn't be read.
    case unavailable
    case notRunning(backendState: String)
    case running(dnsName: String, httpsEnabled: Bool)

    static func parse(_ data: Data) -> TailnetStatus {
        guard let json = try? JSONDecoder().decode(TailscaleStatusJSON.self, from: data) else { return .unavailable }
        guard json.backendState == "Running" else { return .notRunning(backendState: json.backendState) }
        var dns = json.selfNode?.DNSName ?? ""
        while dns.hasSuffix(".") { dns.removeLast() }
        guard !dns.isEmpty else { return .notRunning(backendState: "NoDNSName") }
        return .running(dnsName: dns, httpsEnabled: (json.certDomains ?? []).contains(dns))
    }
}

public nonisolated enum TailnetError: Error, Equatable, Sendable {
    case notInstalled
    case statusUnreadable
    case loggedOut
    case notRunning(String)
    case noDNSName
    case httpsDisabled
    case portTaken(UInt16)
    case notOurs(UInt16)
    case commandFailed(String)
    case timedOut(String)
    case notApplied

    public var message: String {
        switch self {
        case .notInstalled: return "Tailscale isn't installed (no tailscale command found)"
        case .statusUnreadable: return "couldn't read tailscale status --json"
        case .loggedOut: return "Tailscale is logged out; log in, then try again"
        case .notRunning(let state): return "Tailscale isn't running (state: \(state))"
        case .noDNSName: return "Tailscale reports no MagicDNS name for this Mac; turn on MagicDNS in the admin console"
        case .httpsDisabled: return "HTTPS certificates aren't enabled for this tailnet; turn them on in the Tailscale admin console (DNS › HTTPS Certificates), then try again"
        case .portTaken(let port): return "tailnet port \(port) is already served by a mapping Batty didn't make; Batty won't replace it (see tailscale serve status)"
        case .notOurs(let port): return "this tailnet mapping on port \(port) wasn't created by Batty; remove it with tailscale \(TailscaleArgs.serveOff(port: port).joined(separator: " "))"
        case .commandFailed(let message): return "tailscale serve failed: \(message)"
        case .timedOut(let output): return "tailscale serve didn't finish within 20 s: \(output)"
        case .notApplied: return "tailscale serve exited 0 but serve status doesn't show the mapping"
        }
    }
}

/// Opt-in sharing of tracked servers on the user's tailnet with
/// `tailscale serve` (#0694). Batty turns off only the mappings it made.
@MainActor
@Observable
public final class TailnetSharing {
    public static let fakeEnvironmentVar = "BATTY_UI_TEST_FAKE_TAILSCALE"
    static let statusCacheSeconds: TimeInterval = 10
    /// Nonisolated so quit cleanup never needs the main actor it blocks.
    nonisolated static let commandTimeout: Duration = .seconds(20)

    public private(set) var status: TailnetStatus?

    @ObservationIgnored var runner: TailscaleCommandRunning
    @ObservationIgnored var locate: () -> URL?
    @ObservationIgnored var now: () -> Date = Date.init
    /// Detection runs only while this is true. Set by the store.
    @ObservationIgnored var hasTrackedServers: () -> Bool = { false }
    /// Port → the MagicDNS name, for each mapping Batty created.
    @ObservationIgnored private(set) var owned: [UInt16: String] = [:]
    /// The last operation on each port; the next one awaits it.
    @ObservationIgnored var pending: [UInt16: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// How quit cleanup waits on its semaphore; tests return at once.
    @ObservationIgnored var quitWait: @Sendable (DispatchSemaphore, TimeInterval) -> DispatchTimeoutResult = { $0.wait(timeout: .now() + $1) }

    init(runner: TailscaleCommandRunning, locate: @escaping () -> URL?) {
        self.runner = runner
        self.locate = locate
    }

    /// The production runner, or the in-memory fake under
    /// `BATTY_UI_TEST_FAKE_TAILSCALE=running|absent`.
    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> TailnetSharing {
        switch environment[fakeEnvironmentVar] {
        case "running":
            return TailnetSharing(runner: UITestTailscaleRunner(), locate: { URL(fileURLWithPath: "/fake/tailscale") })
        case "absent":
            return TailnetSharing(runner: UITestTailscaleRunner(), locate: { nil })
        default:
            return TailnetSharing(runner: ProcessTailscaleCommandRunner(), locate: { TailscaleExecutableLocator.locate() })
        }
    }

    public var offersSharing: Bool {
        if case .running = status { return true }
        return false
    }

    var ownedPorts: Set<UInt16> { Set(owned.keys) }

    // MARK: - Detection

    /// Runs `status --json` unless a result is under 10 s old or no server
    /// is tracked. Call from events and ticks only.
    @discardableResult
    public func refreshStatusIfStale() -> Task<Void, Never>? {
        guard hasTrackedServers() else { return nil }
        if let refreshTask { return refreshTask }
        if let lastRefresh, now().timeIntervalSince(lastRefresh) < Self.statusCacheSeconds { return nil }
        lastRefresh = now()
        let task = Task { [weak self] in
            guard let self else { return }
            let fresh = await self.fetchStatus()
            self.status = fresh
            self.refreshTask = nil
        }
        refreshTask = task
        return task
    }

    private func fetchStatus() async -> TailnetStatus {
        guard let executable = locate() else { return .unavailable }
        let result = await runner.run(executable: executable, arguments: TailscaleArgs.status, timeout: Self.commandTimeout)
        guard !result.timedOut else { return .unavailable }
        return TailnetStatus.parse(Data(result.stdout.utf8))
    }

    private func serveConfig(_ executable: URL) async -> TailscaleServeConfig? {
        let result = await runner.run(executable: executable, arguments: TailscaleArgs.serveStatus, timeout: Self.commandTimeout)
        guard !result.timedOut, result.exitCode == 0 else { return nil }
        return TailscaleServeConfig.parse(Data(result.stdout.utf8))
    }

    // MARK: - Share and stop

    private func chain<T: Sendable>(port: UInt16, _ operation: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = pending[port]
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        pending[port] = Task { _ = await task.value }
        return task
    }

    /// Serves the entry's port on the tailnet. Event origin only.
    public func share(entry: ServerEntry) -> Task<Result<URL, TailnetError>, Never> {
        let port = entry.port
        entry.isTailnetBusy = true
        return chain(port: port) { [weak self] in
            let result = await self?.performShare(port: port) ?? .failure(.notInstalled)
            switch result {
            case .success(let shared):
                if entry.tailnetURL != shared.url { entry.tailnetURL = shared.url }
                if entry.isTailnetAdopted != shared.adopted { entry.isTailnetAdopted = shared.adopted }
                if entry.tailnetError != nil { entry.tailnetError = nil }
            case .failure(let error):
                entry.tailnetError = error.message
            }
            entry.isTailnetBusy = false
            return result.map(\.url)
        }
    }

    private func performShare(port: UInt16) async -> Result<(url: URL, adopted: Bool), TailnetError> {
        guard let executable = locate() else {
            status = .unavailable
            return .failure(.notInstalled)
        }
        let fresh = await fetchStatus()
        status = fresh
        lastRefresh = now()
        let dnsName: String
        switch fresh {
        case .unavailable: return .failure(.statusUnreadable)
        case .notRunning("NeedsLogin"): return .failure(.loggedOut)
        case .notRunning("NoDNSName"): return .failure(.noDNSName)
        case .notRunning(let state): return .failure(.notRunning(state))
        case .running(let dns, let httpsEnabled):
            guard httpsEnabled else { return .failure(.httpsDisabled) }
            dnsName = dns
        }
        let url = TailnetURL.make(dnsName: dnsName, port: port)
        guard let before = await serveConfig(executable) else { return .failure(.commandFailed("couldn't read tailscale serve status --json")) }
        if before.isOurs(port: port, dnsName: dnsName) {
            let adopted = owned[port] == nil
            if adopted { logger.info("tailnet: adopting the existing mapping on port \(port, privacy: .public); Batty won't turn it off") }
            return .success((url, adopted))
        }
        if before.hasAnyMapping(port: port) { return .failure(.portTaken(port)) }
        let result = await runner.run(executable: executable, arguments: TailscaleArgs.serveOn(port: port), timeout: Self.commandTimeout)
        if result.timedOut { return .failure(.timedOut(result.message)) }
        if result.exitCode != 0 { return .failure(.commandFailed(result.message)) }
        guard let after = await serveConfig(executable), after.isOurs(port: port, dnsName: dnsName) else {
            return .failure(.notApplied)
        }
        owned[port] = dnsName
        logger.info("tailnet: serving port \(port, privacy: .public)")
        return .success((url, false))
    }

    /// Stops serving `port` on the tailnet when Batty made the mapping.
    /// `reportForeign` fails with `notOurs` when a mapping Batty didn't
    /// make sits on an unowned port. Event or tick origin only.
    public func unshare(port: UInt16, entry: ServerEntry?, reportForeign: Bool = false) -> Task<Result<Void, TailnetError>, Never> {
        entry?.isTailnetBusy = true
        return chain(port: port) { [weak self] in
            let result = await self?.performUnshare(port: port, adopted: entry?.isTailnetAdopted == true, reportForeign: reportForeign) ?? .success(())
            switch result {
            case .success:
                if entry?.tailnetURL != nil { entry?.tailnetURL = nil }
                if entry?.isTailnetAdopted == true { entry?.isTailnetAdopted = false }
                if entry?.tailnetError != nil { entry?.tailnetError = nil }
            case .failure(let error):
                entry?.tailnetError = error.message
            }
            entry?.isTailnetBusy = false
            return result
        }
    }

    private func performUnshare(port: UInt16, adopted: Bool, reportForeign: Bool) async -> Result<Void, TailnetError> {
        guard let dnsName = owned[port] else {
            if adopted { return .failure(.notOurs(port)) }
            guard reportForeign, let executable = locate() else { return .success(()) }
            guard let config = await serveConfig(executable) else { return .success(()) }
            var ours = false
            if case .running(let dns, _) = status { ours = config.isOurs(port: port, dnsName: dns) }
            return config.hasAnyMapping(port: port) && !ours ? .failure(.notOurs(port)) : .success(())
        }
        guard let executable = locate() else { return .failure(.notInstalled) }
        switch await Self.turnOff(port: port, dnsName: dnsName, executable: executable, runner: runner) {
        case .failure(let error):
            return .failure(error)
        case .success:
            owned[port] = nil
            return .success(())
        }
    }

    /// Runs `off` only while the port still holds exactly Batty's mapping.
    nonisolated static func turnOff(port: UInt16, dnsName: String, executable: URL, runner: TailscaleCommandRunning) async -> Result<Void, TailnetError> {
        let status = await runner.run(executable: executable, arguments: TailscaleArgs.serveStatus, timeout: commandTimeout)
        guard !status.timedOut, status.exitCode == 0, let config = TailscaleServeConfig.parse(Data(status.stdout.utf8)) else {
            return .failure(.commandFailed("couldn't read tailscale serve status --json"))
        }
        guard config.isOurs(port: port, dnsName: dnsName) else {
            logger.notice("tailnet: mapping on port \(port, privacy: .public) changed; leaving it")
            return .success(())
        }
        let result = await runner.run(executable: executable, arguments: TailscaleArgs.serveOff(port: port), timeout: commandTimeout)
        if result.timedOut { return .failure(.timedOut(result.message)) }
        if result.exitCode != 0 { return .failure(.commandFailed(result.message)) }
        logger.info("tailnet: turned off port \(port, privacy: .public)")
        return .success(())
    }

    /// The registry's `onRemove`: an entry leaving the list takes its
    /// mapping with it, including one a share still in flight creates.
    func entryRemoved(port: UInt16) {
        guard owned[port] != nil || pending[port] != nil else { return }
        _ = unshare(port: port, entry: nil)
    }

    // MARK: - Quit

    /// Turns off every mapping Batty made; a failed one stays owned.
    func removeOwnedMappingsForQuit() async {
        for port in owned.keys.sorted() {
            _ = await unshare(port: port, entry: nil).value
        }
    }

    /// Blocks the main thread for at most `timeout` while the owned
    /// mappings are turned off off the main actor. Only for
    /// `applicationWillTerminate`, where a detached task might never run.
    /// Returns false when the timeout ran out first.
    @discardableResult
    public func removeOwnedMappingsSynchronouslyForQuit(timeout: TimeInterval = 5) -> Bool {
        guard !owned.isEmpty, let executable = locate() else { return true }
        let mappings = owned.sorted { $0.key < $1.key }
        let runner = runner
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for (port, dnsName) in mappings {
                _ = await Self.turnOff(port: port, dnsName: dnsName, executable: executable, runner: runner)
            }
            done.signal()
        }
        guard quitWait(done, timeout) == .success else {
            logger.error("tailnet: quit cleanup didn't finish within \(timeout, privacy: .public) s")
            return false
        }
        return true
    }

}
