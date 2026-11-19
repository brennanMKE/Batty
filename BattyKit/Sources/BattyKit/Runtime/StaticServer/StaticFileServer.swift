// StaticFileServer.swift

import Foundation
import Network
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "StaticFileServer")

public nonisolated enum StaticServerError: Error, Equatable, Sendable {
    case portInUse(Int)
    case bindFailed(String)
    case notADirectory(String)

    public var message: String {
        switch self {
        case .portInUse(let port): "port \(port) is in use"
        case .bindFailed(let reason): "could not listen on 127.0.0.1: \(reason)"
        case .notADirectory(let path): "not a directory: \(path)"
        }
    }
}

public nonisolated struct StaticServerStats: Equatable, Sendable {
    public var requestCount = 0
    public var reloadClientCount = 0

    public init(requestCount: Int = 0, reloadClientCount: Int = 0) {
        self.requestCount = requestCount
        self.reloadClientCount = reloadClientCount
    }
}

/// What the in-app backend needs from a server, so its tests can use a fake
/// that never binds.
public nonisolated protocol StaticServing: AnyObject, Sendable {
    func start(port: UInt16?) async throws(StaticServerError) -> UInt16
    func stop()
    /// Returns once the port `stop()` released can be bound again.
    func waitUntilStopped() async
    func broadcastReload()
    var stats: StaticServerStats { get }
}

/// A loopback-only HTTP/1.1 static file server on `NWListener`. Binds
/// `127.0.0.1` and nothing else. Network callbacks run on `queue`; mutable
/// state is behind `state`'s lock so `stop()` can run synchronously from
/// the main actor.
public nonisolated final class StaticFileServer: StaticServing, @unchecked Sendable {
    private struct State {
        var listener: NWListener?
        var port: UInt16 = 0
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var eventClients: [ObjectIdentifier: NWConnection] = [:]
        var stopWaiters: [CheckedContinuation<Void, Never>] = []
        var isStopped = true
    }

    public let resolver: StaticFilePathResolver
    public let injectsReloadScript: Bool
    private let queue = DispatchQueue(label: "co.sstools.Batty.StaticFileServer")
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let counters = OSAllocatedUnfairLock(initialState: StaticServerStats())

    public init(resolver: StaticFilePathResolver, injectsReloadScript: Bool) {
        self.resolver = resolver
        self.injectsReloadScript = injectsReloadScript
    }

    public var stats: StaticServerStats { counters.withLock { $0 } }

    public var port: UInt16 { state.withLockUnchecked { $0.port } }

    public func start(port requested: UInt16?) async throws(StaticServerError) -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = false
        let requestedPort = NWEndpoint.Port(rawValue: requested ?? 0) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: requestedPort)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw .bindFailed(String(describing: error))
        }
        let result: Result<UInt16, StaticServerError> = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Result<UInt16, StaticServerError>) -> Void = { value in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            listener.stateUpdateHandler = { [weak self] newState in
                switch newState {
                case .ready:
                    let bound = listener.port?.rawValue ?? 0
                    self?.state.withLockUnchecked { $0.port = bound }
                    finish(.success(bound))
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    finish(.failure(Self.map(error, port: requested)))
                case .cancelled:
                    finish(.failure(.bindFailed("cancelled")))
                    self?.listenerCancelled(listener)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            state.withLockUnchecked {
                $0.listener = listener
                $0.isStopped = false
            }
            listener.start(queue: queue)
        }
        let bound = try result.get()
        logger.info("serving \(self.resolver.rootRealPath, privacy: .private) on 127.0.0.1:\(bound)")
        return bound
    }

    /// Cancels the listener, every connection and every reload client.
    public func stop() {
        let (listener, connections) = state.withLockUnchecked { state -> (NWListener?, [NWConnection]) in
            let all = Array(state.connections.values) + Array(state.eventClients.values)
            state.connections = [:]
            state.eventClients = [:]
            let listener = state.listener
            if listener == nil { state.isStopped = true }
            return (listener, all)
        }
        counters.withLock { $0.reloadClientCount = 0 }
        listener?.cancel()
        connections.forEach { $0.cancel() }
        if listener == nil { resumeStopWaiters() }
    }

    /// Returns once the listener has reported `.cancelled`, so its port is
    /// free.
    public func waitUntilStopped() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let stopped = state.withLockUnchecked { state -> Bool in
                if state.isStopped { return true }
                state.stopWaiters.append(continuation)
                return false
            }
            if stopped { continuation.resume() }
        }
    }

    public func broadcastReload() {
        let clients = state.withLockUnchecked { Array($0.eventClients.values) }
        let message = Data("data: reload\n\n".utf8)
        for client in clients {
            client.send(content: message, completion: .contentProcessed { _ in })
        }
    }

    private func listenerCancelled(_ listener: NWListener) {
        let isCurrent = state.withLockUnchecked { state -> Bool in
            guard state.listener === listener else { return false }
            state.listener = nil
            state.isStopped = true
            return true
        }
        if isCurrent { resumeStopWaiters() }
    }

    private func resumeStopWaiters() {
        let waiters = state.withLockUnchecked { state -> [CheckedContinuation<Void, Never>] in
            defer { state.stopWaiters = [] }
            return state.stopWaiters
        }
        waiters.forEach { $0.resume() }
    }

    private static func map(_ error: NWError, port: UInt16?) -> StaticServerError {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return .portInUse(Int(port ?? 0))
        }
        return .bindFailed(error.localizedDescription)
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let accepted = state.withLockUnchecked { state -> Bool in
            guard state.listener != nil else { return false }
            state.connections[key] = connection
            return true
        }
        guard accepted else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .failed, .cancelled:
                self?.forget(key)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func forget(_ key: ObjectIdentifier) {
        let count = state.withLockUnchecked { state -> Int in
            state.connections[key] = nil
            state.eventClients[key] = nil
            return state.eventClients.count
        }
        counters.withLock { $0.reloadClientCount = count }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: HTTPRequestHead.maximumSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            switch HTTPRequestHead.parse(accumulated) {
            case .success(let head):
                self.respond(to: head, on: connection)
            case .failure(.incomplete):
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: accumulated)
                }
            case .failure(.tooLarge):
                self.send(StaticHTTPResponder.simple(431), on: connection)
            case .failure(.malformed):
                self.send(StaticHTTPResponder.simple(400), on: connection)
            }
        }
    }

    private func respond(to head: HTTPRequestHead, on connection: NWConnection) {
        counters.withLock { $0.requestCount += 1 }
        let options = StaticResponderOptions(port: port, injectsReloadScript: injectsReloadScript)
        let response = StaticHTTPResponder.respond(to: head, resolver: resolver, options: options)
        guard response.kind == .eventStream else {
            send(response, on: connection)
            return
        }
        let key = ObjectIdentifier(connection)
        let count = state.withLockUnchecked { state -> Int in
            state.connections[key] = nil
            state.eventClients[key] = connection
            return state.eventClients.count
        }
        counters.withLock { $0.reloadClientCount = count }
        var payload = response.serializedHead
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in })
    }

    private func send(_ response: StaticResponse, on connection: NWConnection) {
        var payload = response.serializedHead
        payload.append(response.body)
        connection.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
