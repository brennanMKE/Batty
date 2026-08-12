// AppEventWatcher.swift

import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppEventWatcher")

/// #0145: Observer for runtime mutations that convert them into watch events.
///
/// `AppStateStore` is the source of truth for all session/pane/tab state. This type
/// observes that store via `@ObservationIgnored` bindings — because the store is
/// already a global singleton and mutation routes through `AppStateStore`, not
/// the individual windows — and dispatches JSON-encoded events to registered
/// watchers.
@MainActor
final class AppEventWatcher {
    static let shared = AppEventWatcher()

    /// A registered watcher: records which event types it wants and how to deliver them.
    struct Subscription {
        let id: UUID
        var events: Set<String>
        var replyBlock: @Sendable (WatchEventPayload) -> Void

        func notify(eventType: String, payload eventData: WatchEventPayload) {
            if events.contains("*") || events.contains(eventType) {
                replyBlock(eventData)
            } else {
                logger.debug("watch: event \u{2018}\(eventType)\u{2019} skipped (not in filters)")
            }
        }
    }

    private var subscriptions: [UUID: Subscription] = [:]
    private let lock = NSLock()

    func subscribe(events: [String], replyBlock: @escaping @Sendable (WatchEventPayload) -> Void) -> UUID {
        lock.lock()
        let id = UUID()
        subscriptions[id] = Subscription(id: id, events: Set(events), replyBlock: replyBlock)
        lock.unlock()

        logger.info("watch: subscribed id=\(id, privacy: .public) events=\(events.count)")
        return id
    }

    func unsubscribe(id: UUID) {
        lock.lock()
        _ = subscriptions.removeValue(forKey: id)
        lock.unlock()

        logger.info("watch: unsubscribed id=\(id, privacy: .public)")
    }

    func send(eventType: String, payload event: WatchEventPayload) {
        lock.lock()
        let subs = subscriptions.values.filter { $0.events.contains("*") || $0.events.contains(eventType) }
        lock.unlock()

        for sub in subs {
            sub.notify(eventType: eventType, payload: event)
        }
    }

    func removeAll() {
        lock.lock()
        subscriptions.removeAll()
        lock.unlock()

        logger.info("watch: removed all subscriptions")
    }
}
