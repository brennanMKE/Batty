// StaticReloadBroadcaster.swift

import Foundation

/// Main-actor fan-out of "a file under the root changed", after the
/// debounce. The server's reload clients and Batty's own preview Panes both
/// hang off it.
@MainActor
public final class StaticReloadBroadcaster {
    public var onBroadcast: (@MainActor () -> Void)?
    public private(set) var changeCount = 0
    public private(set) var lastChangeAt: Date?
    private var observers: [UUID: @MainActor () -> Void] = [:]

    public init() {}

    public var observerCount: Int { observers.count }

    @discardableResult
    public func addObserver(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    public func broadcast(at date: Date) {
        changeCount += 1
        lastChangeAt = date
        onBroadcast?()
        for observer in Array(observers.values) { observer() }
    }
}

/// A trailing-edge debounce on the injected clock: a burst of changes
/// broadcasts once, `quietPeriod` after the last one.
@MainActor
public final class StaticReloadDebouncer {
    private let clock: any SchedulingClock
    private let quietPeriod: Duration
    private let broadcaster: StaticReloadBroadcaster
    /// The pending fire, exposed so tests can await it after advancing the
    /// clock.
    public private(set) var pending: Task<Void, Never>?

    public init(clock: any SchedulingClock, broadcaster: StaticReloadBroadcaster, quietPeriod: Duration = .milliseconds(150)) {
        self.clock = clock
        self.broadcaster = broadcaster
        self.quietPeriod = quietPeriod
    }

    public func noteChange() {
        pending?.cancel()
        let clock = clock
        let quietPeriod = quietPeriod
        pending = Task { [weak self] in
            await clock.sleep(for: quietPeriod)
            guard !Task.isCancelled, let self else { return }
            self.broadcaster.broadcast(at: clock.now)
        }
    }

    public func stop() {
        pending?.cancel()
        pending = nil
    }
}
