// InAppStaticServerBackend.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "InAppStaticServerBackend")

/// `batty server serve` (#0649): a static file server inside Batty, listed in
/// the toolbar's Servers with no terminal. `batty server stop` stops it.
@MainActor
public final class InAppStaticServerBackend: InProcessServerBackend {
    public typealias ServerFactory = @MainActor (_ resolver: StaticFilePathResolver, _ injects: Bool) -> StaticServing
    public typealias WatcherFactory = @MainActor (_ rootRealPath: String) -> DirectoryChangeWatching

    public let resolver: StaticFilePathResolver
    public let injectsReloadScript: Bool
    public let broadcaster = StaticReloadBroadcaster()
    public private(set) var port: UInt16?
    public private(set) var isServing = false

    private let makeServer: ServerFactory
    private let makeWatcher: WatcherFactory
    private let debouncer: StaticReloadDebouncer
    private var server: StaticServing?
    /// The server `stopServing()` stopped, until its listener has released
    /// the port. `NWListener.cancel()` only requests the release.
    private var releasingServer: StaticServing?
    private var watcher: DirectoryChangeWatching?

    public init(
        resolver: StaticFilePathResolver,
        injectsReloadScript: Bool,
        clock: any SchedulingClock = SystemClock(),
        makeServer: @escaping ServerFactory = { StaticFileServer(resolver: $0, injectsReloadScript: $1) },
        makeWatcher: @escaping WatcherFactory = { FSEventsDirectoryWatcher(root: $0) }
    ) {
        self.resolver = resolver
        self.injectsReloadScript = injectsReloadScript
        self.makeServer = makeServer
        self.makeWatcher = makeWatcher
        debouncer = StaticReloadDebouncer(clock: clock, broadcaster: broadcaster)
        broadcaster.onBroadcast = { [weak self] in self?.server?.broadcastReload() }
    }

    public var root: String { resolver.rootRealPath }
    public var kind: ServerBackendKind { .inApp }
    public var canRestart: Bool { true }
    public var canStop: Bool { true }
    public var stopsOnTearDown: Bool { true }
    public var command: String? { nil }
    public var workingDirectory: String? { root }
    public var isAvailable: Bool { true }

    public var servingFacts: ServingFacts {
        let stats = server?.stats ?? StaticServerStats()
        return ServingFacts(
            root: root, requestCount: stats.requestCount, reloadClientCount: stats.reloadClientCount,
            lastChangeAt: broadcaster.lastChangeAt, injectsReloadScript: injectsReloadScript)
    }

    /// Binds `127.0.0.1:port` (an ephemeral port when nil) and starts
    /// watching the root. Called by the store before the Pane exists.
    @discardableResult
    public func startServing(port requested: UInt16?) async throws(StaticServerError) -> UInt16 {
        let server = makeServer(resolver, injectsReloadScript)
        let bound = try await server.start(port: requested)
        self.server = server
        port = bound
        isServing = true
        let watcher = makeWatcher(root)
        watcher.start { [weak self] _ in
            Task { @MainActor in self?.fileChanged() }
        }
        self.watcher = watcher
        return bound
    }

    /// Rebinds the same port, after the stopped listener has released it.
    public func resumeServing() async throws(StaticServerError) {
        if let releasing = releasingServer {
            await releasing.waitUntilStopped()
            if releasingServer === releasing { releasingServer = nil }
        }
        guard !isServing else { return }
        try await startServing(port: port)
    }

    /// Synchronous: the listener, every connection and the watcher are
    /// cancelled before this returns. The port is free only once the
    /// listener reports `.cancelled`, which `resumeServing()` awaits.
    public func stopServing() {
        guard isServing || server != nil else { return }
        isServing = false
        debouncer.stop()
        watcher?.stop()
        watcher = nil
        server?.stop()
        releasingServer = server
        server = nil
        logger.info("stopped serving on port \(self.port ?? 0, privacy: .public)")
    }

    func fileChanged() {
        guard isServing else { return }
        debouncer.noteChange()
    }

    public var pendingReload: Task<Void, Never>? { debouncer.pending }

    public func start(events: @escaping (ServerBackendEvent) -> Void) {}
    public func rerun() -> Bool { false }
    public func detach() {}

    public func stopDecision(listenerPid: pid_t?, table: ProcessTableReading) -> ServerStopDecision { .nothing }
}
